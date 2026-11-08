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
