# Debug info: debugify, debug records, salvaging

Facts verified against LLVM 23.1.5 (sources named per item; checked by `sweep --passes 'debugify,<pass>'` against
the oracle unless noted).

## debugify (lib/Transforms/Utils/Debugify.cpp, synthetic mode)

- Skips the module (prints `ModuleDebugify: Skipping module with debug info` unless `-debugify-quiet`) when
  `!llvm.dbg.cu` exists. Otherwise: one `DIFile(filename: <module id>, directory: "/")`, one distinct
  `DICompileUnit(DW_LANG_C, producer "debugify", isOptimized, FullDebug)` appended to `!llvm.dbg.cu`, then per
  function that is a definition with an exact definition (not available_externally / linkonce_odr / weak_odr /
  interposable / `nobuiltin`): a distinct `DISubprogram(name = linkageName = function name, scope null, line =
  scopeLine = next line, type !DISubroutineType(types: !{}), spFlags Definition|Optimized [|LocalToUnit for
  private/internal])`.
- Every instruction gets `!DILocation(line: N, column: 1)` with N counting up across the module. Every non-void
  instruction before the block's terminating instruction (a musttail or deoptimize call counts as the terminator)
  gets a `#dbg_value` of itself with a fresh `DILocalVariable(name: "<k>", line: <its line>, type:
  DIBasicType("ty<alloc size in bits>", DW_ATE_unsigned))`, appended to the records before the next instruction;
  phis' (and EH pads') records all go before the first insertion point. EH-pad blocks get no records. A function
  without any record gets one `#dbg_value(i32 0, ...)` before the entry block's terminator. The variables are the
  subprogram's `retainedNodes` (DIBuilder::finalizeSubprogram, creation order).
- `!llvm.debugify = !{!{i32 <lines>}, !{i32 <vars>}}`, and `!{i32 2, !"Debug Info Version", i32 3}` is appended to
  `!llvm.module.flags` if missing. `check-debugify` only prints (stderr) unless Strip.
- "Exact definition" also excludes `noipa` functions (GlobalValue::isInterposable(CheckNoIPA = true), Globals.cpp)
  and, with the `SemanticInterposition` module flag, non-dso_local ones (*/noipa.ll in the sweep).
- With `-debugify-level=locations` (or a function without records) the subprogram's retainedNodes stays the
  temporary `!{}` from createFunction, which the printer omits: no `retainedNodes:` field.
- `-enable-debugify` adds NewPMDebugifyPass before and NewPMCheckDebugifyPass after the `-passes` pipeline
  (NewPMDriver.cpp); `-strip-debug` runs StripDebugInfo right after parsing (optdriver.cpp).
  Verified: goose `sweep --passes debugify` and `debugify,check-debugify --analysis` identical on 7595 files.

## Debug records

- **Head bit.** `BasicBlock::begin()`, `getFirstNonPHIIt()`, `getFirstInsertionPt()` and
  `getInsertionPointAfterDef()` return iterators with the head bit set: an instruction inserted there comes before
  the records attached to that position. `I->getIterator()` (and `Instruction*` insert points) has it clear: the
  new instruction adopts the records in front of `I` (Instruction::insertBefore, Instruction.cpp:150). `++It`
  clears the bit.
- `Instruction::moveBefore(It)` (not `moveBeforePreserving`) leaves the moved instruction's records at its old
  place (they go to the next instruction) and absorbs the records at the destination unless the head bit is set
  (Instruction::moveBeforeImpl). InstCombine's `foldShiftedShift` relies on it: `and` is created at the outer shift
  and moved before the inner one.
- **Trailing records.** Erasing the last instruction of a block (usually the terminator) moves its records to the
  block's trailing marker (DbgMarker::removeMarker, DebugProgramInstruction.cpp:646); the next instruction inserted
  at end() adopts them, and inserting a terminator flushes them onto it (flushTerminatorDbgRecords). So
  "erase the terminator, then create a new branch" keeps the records (simplifycfg with debugify).
- `BasicBlock::splitBasicBlock(I)` with an `Instruction*` leaves I's records in the old block (spliceDebugInfo with
  First.HeadBit = false); they end up before the new unconditional branch.
- `IRBuilder::Insert(I)` with no name calls `I->setName("")`: a name set on an unlinked instruction before
  `Builder.Insert(I)` is dropped (Negator's select swap `.neg`, foldSignExtendingValue's `.sext`).
- findDbgUsers order (DebugInfo.cpp findDbgIntrinsics, Metadata.cpp getAllDbgVariableRecordUsers /
  getAllArgListUsers): direct ValueAsMetadata users by **descending** tracking index, then the DIArgLists containing
  the value in **ascending** index order (`getAllArgListUsers` sorts `<`), each with its record users by descending
  index; a record is listed once. Every ReplaceableMetadataImpl (a VAM, a DIArgList) has its own NextIndex. A record
  changing location re-tracks (new index); handleRAUW onto a value that already has a ValueAsMetadata moves the
  users over with new indices in their old (ascending) order; RAUW onto a value without one updates the VAM in
  place (users keep their indices). Local -> constant RAUW gives the records the ConstantAsMetadata; a deleted
  value (`~Value`, handleDeletion) gives records `poison` of its type (DebugValueUser::handleChangedValue) and
  DIArgList arguments poison (DIArgList::handleChangedOperand). DIArgList::handleChangedOperand mutates the list in
  place (same object, users keep indices, args re-tracked) unless an equal list already exists, then RAUWs onto it.
  `Value::replaceAllUsesWith` does all this itself (`isUsedByMetadata`); goose: `rauw` and the erase functions call
  dinfo.goose's `vam_handle_rauw` / `vam_handle_deletion`, so passes need no per-pass record lists.
- Insertion iterators (head bit): `getFirstInsertionPt()` always sets it, also after skipping an EH pad
  (BasicBlock.cpp:366, set after `++`); `getFirstNonPHIIt()` and `begin()` set it; `getFirstNonPHIOrDbgOrAlloca()`
  clears it (BasicBlock.cpp:392); `getInsertionPointAfterDef()` sets it (also for `std::next(this)`);
  InstCombine's freezeOtherUses then clears it again (`MoveBefore.setHeadBit(false)`, InstructionCombining.cpp:5384):
  the moved freeze ends up after the records. `Instruction::insertAfter` is a plain list insertion (no adoption):
  the records at the next instruction stay there, after the new one. `moveAfter` uses `std::next` with the head
  bit. `BasicBlock::insertDbgRecordBefore(DR, It)` inserts at the head of the marker iff It has the head bit (so
  ConvertDebugDeclareToDebugValue at a PHI's getFirstInsertionPt goes in front of existing records);
  `insertDbgRecordAfter(DR, I)` at the head of the next position's marker.
- `BasicBlock::splice` moves records per spliceDebugInfo (BasicBlock.cpp:737-960): MergeBlockIntoPredecessor's
  `splice(PTI, BB, begin(), STI)` puts STI's records at PTI (they end up on the moved terminator via the trailing
  marker and flushTerminatorDbgRecords); MergeBasicBlockIntoOnlyPred's `splice(begin(), PredBB)` puts PredBB's
  trailing records (of its erased terminator) at the head of DestBB's first instruction, before its own.
- Inserting a terminator flushes the block's trailing records onto it, after its own (flushTerminatorDbgRecords).
- SimplifyCFG: FoldBranchToCommonDest clones each bonus instruction's records and remaps their locations through
  the clone map (RemapDbgRecordRange, RF_IgnoreMissingLocals: unmapped locals stay), and the branch's records onto
  the predecessor's terminator; FoldCondBranchOnValueKnownInPredecessor clones records of cloned and folded-away
  instructions (SrcDbgCursor) **without** remapping. simplifyUnreachable flushes trailing records, drops the
  unreachable's own records and those of every instruction it deletes before it.
- `SelectInst::Create(..., MDFrom)` copies every attachment of MDFrom including `!dbg` (copyMetadata); IRBuilder's
  `CreateSelect(..., MDFrom)` copies only `!prof` and `!unpredictable`. Visible only with debug info: a fold that
  returns `SelectInst::Create(C, A, B, "", nullptr, SI)` keeps SI's location (InstCombineLoadStoreAlloca.cpp:1169).
- InstCombine lowers `#dbg_declare` by default (`-instcombine-lower-dbg-declare` is `cl::init(true)`): LowerDbgDeclare
  (Local.cpp) for scalar, constant-size allocas without volatile accesses, then RemoveRedundantDbgInstrs on every block.
- `#dbg_value` on a phi is invalid IR (`PHI Node must not have any attached DbgRecords`): an LLVM phi inserted
  before a block's records always uses a head-bit iterator.

## Salvaging (lib/Transforms/Utils/Local.cpp, lib/IR/DIExpressionOptimizer.cpp)

- Who salvages: ADCE (every dead instruction, reverse order, before dropAllReferences), BDCE (reverse worklist),
  DCE, EarlyCSE, RecursivelyDeleteTriviallyDeadInstructions (so SimplifyCFG's dead conditions and InstSimplify),
  InstCombine's eraseInstFromFunction and its prepareWorklist DCE, SimplifyDemandedBits/FPClass (the replaced
  operand). Not: mem2reg, SROA, InstCombine's constant-folding in prepareWorklist, plain `eraseFromParent`.
- `CastInst::isNoopCast` for ptrtoaddr compares the *pointer* size (getIntPtrType), like ptrtoint, not the index
  size (Instructions.cpp:2860), so a ptrtoaddr to the address size of a `pe1:64:64:64:32` pointer is not salvaged.
- salvageDebugInfoForDbgValues `break`s out of the loop over users at the first user it can't salvage; only if
  nothing was salvaged are all users killed (poison). Casts other than trunc/zext/sext/inttoptr/ptrtoint (and
  no-op casts, which salvage to the operand) are not salvaged; loads never are.
- GEP salvage uses GEPOperator::collectOffset: variable indices become `DW_OP_LLVM_arg n, DW_OP_constu stride,
  DW_OP_mul, DW_OP_plus` with the index as an extra DIArgList value.
- Every salvaged expression goes through `foldConstantMath`, which turns `plus_uconst` into `constu, plus`, folds
  constant pairs and commutative chains, and turns `constu 0` into `lit0` and `constu C, plus` back into
  `plus_uconst C`.
- RemoveRedundantDbgInstrs' backward scan resets its seen-set at every instruction (records attached to one
  instruction are one "sequence") and keys on (variable, fragment, inlinedAt), declares included; the forward scan
  skips declares and keys on (variable, inlinedAt) without fragment, comparing the list of location values (a
  one-element DIArgList equals the plain value) and the expression. `redundant-dbg-inst-elim` (DCE.cpp) runs it on
  every block and preserves the CFG.
