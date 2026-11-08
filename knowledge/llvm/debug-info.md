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
- `BasicBlock::splitBasicBlock(I)` with an `Instruction*` leaves I's records in the old block (spliceDebugInfo with
  First.HeadBit = false); they end up before the new unconditional branch.
- `IRBuilder::Insert(I)` with no name calls `I->setName("")`: a name set on an unlinked instruction before
  `Builder.Insert(I)` is dropped (Negator's select swap `.neg`, foldSignExtendingValue's `.sext`).
- findDbgUsers order (Metadata.cpp getAllDbgVariableRecordUsers): direct ValueAsMetadata users by descending
  tracking index, then for each DIArgList containing the value (descending index in the value's use map) its
  users. A record changing location re-tracks (new index); handleRAUW onto a value that already has a
  ValueAsMetadata moves the users over with new indices in their old order.
- `#dbg_value` on a phi is invalid IR (`PHI Node must not have any attached DbgRecords`): an LLVM phi inserted
  before a block's records always uses a head-bit iterator.

## Salvaging (lib/Transforms/Utils/Local.cpp, lib/IR/DIExpressionOptimizer.cpp)

- salvageDebugInfoForDbgValues `break`s out of the loop over users at the first user it can't salvage; only if
  nothing was salvaged are all users killed (poison). Casts other than trunc/zext/sext/inttoptr/ptrtoint (and
  no-op casts, which salvage to the operand) are not salvaged; loads never are.
- GEP salvage uses GEPOperator::collectOffset: variable indices become `DW_OP_LLVM_arg n, DW_OP_constu stride,
  DW_OP_mul, DW_OP_plus` with the index as an extra DIArgList value.
- Every salvaged expression goes through `foldConstantMath`, which turns `plus_uconst` into `constu, plus`, folds
  constant pairs and commutative chains, and turns `constu 0` into `lit0` and `constu C, plus` back into
  `plus_uconst C`.
- RemoveRedundantDbgInstrs' backward scan resets its seen-set at every instruction (records attached to one
  instruction are one "sequence"); the forward scan keys on (variable, inlinedAt) without fragment.
