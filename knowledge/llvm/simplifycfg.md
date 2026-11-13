# SimplifyCFG and the X86 cost model

Facts verified while porting `llvm/lib/Transforms/Utils/SimplifyCFG.cpp` (LLVM 23.1.5) against
`tests/imported/llvm/Transforms/SimplifyCFG` (563/578 matching in the Goose port).

## Pass behaviour

- `isSafeToSpeculativelyExecute` defaults to `IgnoreUBImplyingAttrs = true` in 23.x: a `speculatable` call
  with `noundef`/`nonnull`/... is still speculatable; the attributes are dropped on hoisting
  (`dropUBImplyingAttrsAndMetadata`). (ValueTracking.h signature; SimplifyCFG/speculate-*.ll.)
- `use-dereferenceable-at-point-semantics` defaults to **true** (Value.cpp:40): `dereferenceable(N)` on an
  argument or a call result only helps if the pointer can't be freed between its definition and the context
  instruction (`willNotFreeBetween`, at most 32 instructions, single-predecessor chain). With no context
  instruction (e.g. foldBranchToCommonDest with two predecessors, `CxtI = nullptr`) a `dereferenceable` argument
  does **not** make a load speculatable unless the function is `nofree` or the argument `nofree`/`readonly` +
  `noalias`. (fold-branch-to-common-dest.ll `load_derefable_two_preds`.)
- Assume bundles `"dereferenceable"(p, n)` / `"align"(p, a[, off])` are used through
  `getKnowledgeForValue`, in AssumptionCache order, each bundle filtered by `isValidAssumeForContext`.
- `isWidenableBranch` is GuardUtils' `parseWidenableBranch`: the condition must have one use and be the
  `widenable.condition()` call itself or an `and` (not a logical-and select) with a one-use widenable call.
- `simplifySwitchOfPowersOfTwo` asks `getIntrinsicInstrCost(cttz(C, true))` with argument values; without BMI
  x86 costs it as `CTTZ_ZERO_POISON` (cheap), so the transform fires on plain x86-64.
- The new conditional branch of `simplifySwitchOfPowersOfTwo` gets weights `{D - W/2, W/2}` and the case weights
  are rescaled through a `double` and truncated to `uint32_t`.
- MemProf/callsite metadata merge (`getMergedMemProfMetadata`/`getMergedCallsiteMetadata`) just keeps K's node,
  else J's (MemoryProfileInfo.cpp:648).
- Debug records: `hoistLockstepIdenticalDbgVariableRecords` hoists identical records from *every* successor, so
  duplicates appear in the output (hoist-dbgvalue.ll). Records compare without their DebugLoc. A RAUW updates
  records first, so records that differed only in the replaced value become identical before the terminator is
  hoisted. Inserting an instruction before `I` (no head bit, e.g. IRBuilder::SetInsertPoint(I)) makes it adopt
  `I`'s records; `splice(Dest, Src, begin(), Term)` puts Dest's records in front of the moved range.
- Deleting a block whose address is taken replaces the BlockAddress's uses with `inttoptr (i32 1 to ptr)`;
  RAUW of the block retargets the BlockAddress (or folds it into the new block's existing one).

## opt and the target

- With `-mcpu`/`-mattr`, opt adds `"target-cpu"`/`"target-features"` to **every** function, declarations and
  intrinsics included, appending to existing features with a comma (codegen::setFunctionAttributes,
  optdriver.cpp:714), whenever the module triple names an architecture. Visible in the printed IR.
- opt infers the DataLayout from the triple when the module has none (optdriver.cpp SetDataLayout).
- The X86 subtarget is per function: CPU from `"target-cpu"` else -mcpu else `"generic"`; tune CPU from
  `"tune-cpu"`, else `"generic"` for `x86-64`, else the CPU, and `"i586"` when the CPU is empty
  (X86Subtarget::initSubtargetFeatures). x86_64 triples add `+64bit-mode,-32bit-mode,-16bit-mode,+sse2`; 32-bit
  ones also strip the 64-bit-only features (`cf`, `egpr`, ...). `RequiredVectorWidth` is UINT32_MAX without
  `"min-legal-vector-width"`, so `useAVX512Regs()` is just `hasAVX512()` for x86-64-v4.
- X86 TTI for the cost kinds SimplifyCFG uses (TCK_SizeAndLatency, TCK_CodeSize): `getCFInstrCost` PHI 0 else 1;
  `getBranchMispredictPenalty` 14; `getMemoryOpCost` 1, but 2 for a store whose pointer is a GEP with a
  non-constant index; cast costs collapse to 0/1 (AdjustCost) after the conversion tables; arithmetic and
  intrinsic costs come from the per-feature tables (`{1}` entries have no SizeAndLatency cost and fall through to
  the next table, CostTableLookup stops at the first matching entry). `shouldBuildLookupTables` is true (BRIND is
  Legal), `getMinimumLookupTableEntryBitWidth` 8, relative lookup tables only with PIC (Darwin/Windows x86-64 by
  default).

## More pass facts (verified in the Jai port, all of tests/imported/llvm/Transforms/SimplifyCFG but `-O1`)

- **`PHINode::removeIncomingValueIf` is not stable**: it walks the entries backwards and moves the current *last*
  entry into each removed slot (like `removeIncomingValue`). removeSwitchAfterSelectFold on
  `phi [-1, %switch], [0, %a], [%y, %entry]` gives `[%y, %entry], [0, %a]` before adding `[%sel, %switch]`
  (SCCP/switch.ll after an O2-like pipeline; verified by the goose port's pipeline sweeps).
- `IRBuilder::CreateInBoundsGEP`/`CreateInBoundsPtrAdd` use `GEPNoWrapFlags::inBounds()` = inbounds **and** nusw.
  An implementation that tracks nusw separately must set both, or a later InstCombine never infers `nuw` from
  `inbounds` + a non-negative offset (AggressiveInstCombine's strcmp expansion, then instcombine).

- foldCondBranchOnValueKnownInPredecessor clones debug records into the threaded edge block **without**
  remapping them (no RemapDbgRecordRange there): the clones keep naming the original values (`%x`, not `%x.c`).
  foldBranchToCommonDest's bonus-instruction cloning *does* remap them (SimplifyCFG.cpp:1206, :3664-3705;
  `debugify,simplifycfg` sweep, unprofitable-pr.ll, jump-threading.ll).
- `dropUnknownNonDebugMetadata` (hence `dropUBImplyingAttrsAndMetadata`) never drops `!DIAssignID`
  (Metadata.cpp:1713). Conditional-faulting hoisting then deletes the store's `#dbg_assign` markers and the
  attachment itself (hoistConditionalLoadsStores, hoist-loads-stores-with-cf.ll `debug_metadata_diassign`).
- mergeConditionalStoreToAddress builds the merged condition with `QB` at `PostBB->getFirstInsertionPt()`
  (head bit set): the new xor/or go in front of PostBB's leading records, and SplitBlockAndInsertIfThen at that
  iterator keeps the records with the tail block.
- changeToCall inserts the call at `II->getIterator()`, so the call adopts the invoke's debug records.
- EliminateDuplicatePHINodes and mergeCompatibleInvokes use plain RAUW, which also rewrites debug records
  (ValueAsMetadata::handleRAUW) — the duplicate's records keep a value instead of turning into poison.
- combineMetadata: `!mmra` is merged with MMRAMetadata::combine (tags of each side whose prefix the other side
  also has) even when only one side has it; the tag sets are DenseSets, so with more than one tag per side the
  output order is hash order (the Jai port fails loudly there). `!captures` is the union of the two capture-component
  sets (missing = all); `!noalias.addrspace` intersects the two range lists. `MMRAMetadata(I1) != MMRAMetadata(I2)`
  compares tag *sets* (hoisting/sinking stop at different MMRAs).
- AttributeList::intersectWith (hoisting/sinking/merging calls): per attribute kind the Attributes.td property
  decides — IntersectAnd kept only if both have it, IntersectMin takes the minimum, IntersectCustom: align min,
  memory/captures union, nofpclass and, range union (dropped when full); IntersectPreserve and string attributes
  must be equal, and a missing preserve attribute fails the whole intersection; `byval` makes alignment
  must-preserve.

## print<cost-model> (L1.analysis.cost-model, all 122 tests)

- `-costmodel-reduxcost` is declared in TargetTransformInfo.cpp but read nowhere: accept and ignore it.
- One-element **scalable** vectors are not "scalar" (ElementCount::isScalar needs a fixed count), so
  getPreferredVectorAction promotes/widens them and they end up TypeScalarizeScalableVector: their legalization
  cost is Invalid (`and <vscale x 1 x i32>` prints `Invalid cost` for throughput, while CodeSize may still be 1).
- isNoopAddrSpaceCast compares `TM.getPointerSize(AS)` — the X86 TargetMachine's own DataLayout (p270/p271 32
  bits, p272 64, else the default), not the module's: a module `p7:32:32` still gets a free `addrspacecast`.
- isLegalAddressingMode with a global base follows X86Subtarget::classifyGlobalReference: Darwin x86-64 and
  Win64 default to PIC (getEffectiveRelocModel), so a non-dso_local global is a GOT/stub reference (not foldable)
  on ELF x86-64, but `shouldAssumeDSOLocal` is true for strong definitions on MachO and for most globals on COFF.
- ShuffleVectorInst::isInsertSubvectorMask accepts either source as the in-place one, so `<0, 3>` on two
  `<2 x float>` is an insert of `<1 x float>` at index 0 (cost 1 via the MOVSS/INSERTPS rule), not a select.
  isIdentityWithPadding runs isIdentityMaskImpl over the whole mask, so `<2,3,poison,poison>` (second operand in
  place) is free.
- X86 reduction costs build the per-level shuffle types with `ValVTy->isFloatingPointTy()`, which is false for a
  vector type: float reductions are costed with `<2 x i64>` / `<4 x i32>` shuffles.
- BasicTTI's getMinMaxReductionCost and the vector-reduce cases call `getIntrinsicInstrCost` virtually (X86's
  override), getTypeBasedIntrinsicInstrCost's default case scalarizes and asks for the scalar intrinsic cost again.
- cttz/ctlz are TCC_Basic for scalars when X86TargetLowering::isCheapToSpeculateCttz/Ctlz holds:
  `hasBitScanPassThrough()` is just `is64Bit()`, so on x86-64 always.
- opt prints `warning: ignoring debug info with an invalid version (N) in <file>` when UpgradeDebugInfo strips
  debug info from a module without `"Debug Info Version" 3`; the verifier's "inlinable function call ... must have
  a !dbg location" message is followed by the offending call on its own line.
- FoldBranchToCommonDest renames every bonus instruction it clones: the clone takes the name, the original gets
  `NewBonusInst->getName() + ".old"` unconditionally (SimplifyCFG.cpp:1210), so an *unnamed* bonus instruction is
  named `.old`, `.old1`, ... Each collision bumps the function symbol table's LastUnique counter (ValueSymbolTable
  makeUniqueName), which is why a later `%or.cond` can come out as `%or.cond3` in unnamed (-O0, clang) IR. Verified
  on tests/e2e/O0/test-suite/SingleSource/Regression/C/PR640.ll with `-passes=simplifycfg`.
- `isa<IntrinsicInst>` is true for a call of *any* function whose name starts with `llvm.` (Function::isIntrinsic
  = HasLLVMReservedName), known intrinsic or not: getInstructionCost then takes the intrinsic path with
  `Intrinsic::not_intrinsic` and ends in getTypeBasedIntrinsicInstrCost's default case (cost 1 for scalars), not
  the call path (`TCC_Basic * (params + 1)`). Verified with the Goose port on GlobalOpt/metadata.ll
  (`@llvm.foo`), Reassociate/factorize-again.ll (`@llvm.rsqrt.f32`), SimplifyCFG/dbginfo.ll
  (`@llvm.dbg.func.start`) under `print<cost-model>`.
- getGEPCost's stripPointerCasts guards against cycles (a value seen twice ends the walk): unreachable
  `%p2 = gep %p1, 0` / `%p1 = gep %p2, 0` loops terminate (GVN/unreachable_block_infinite_loop.ll).
- X86 doesn't override useFPRegsForHalfType (false), so an illegal f16's NumRegisters/RegisterType come from i16
  in computeRegisterProperties, while its TransformToType is f32 (TypeSoftPromoteHalf).
- BasicTTI's vp.scatter / vp.gather costing passes `VarMask = isa<Constant>(mask)` (the opposite of the
  masked.* intrinsics' `!isa<Constant>`); VP binops cost as the functional opcode on the return type with
  default operand infos, VP reductions drop the start value except for fadd/fmul (BasicTTIImpl.h getIntrinsicInstrCost).
- The X86 CPU list LLVM accepts is exactly the `Processor` records of X86.td (136 names in 23.1.5);
  `llvm-min-tblgen --print-records -I include -I lib/Target/X86 lib/Target/X86/X86.td` evaluates their
  `!listconcat`/`!listremove` feature lists, and every `SubtargetFeature` record's `FieldName`/`Value` gives the
  X86Subtarget getter (`hasCMOV()` = `HasCMOV`; `TuningPreferNoGather` sets `PreferGather = false`, so
  `preferGather()` defaults to true).

- isSafeToSpeculateStore (SpeculativelyExecuteBB) accepts a preceding simple load of the same pointer/type/alignment
  only if the underlying object is writable (alloca, byval, noalias+writable argument, noalias call), not captured
  (PointerMayBeCaptured with CaptureComponents::Provenance, without return captures), and, for writable arguments,
  dereferenceable with IgnoreFree; the load itself then becomes the select's other value (impl/goose, -O2 corpus).
