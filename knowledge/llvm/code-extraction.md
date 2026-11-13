# Code extraction: CodeExtractor, HotColdSplitting, LoopExtractor, BlockExtractor, PartialInlining

Facts about LLVM 23.1.5's lib/Transforms/Utils/CodeExtractor.cpp and its users, found while porting them (impl/jai,
L1.extra.code-extraction). Verified with the unit tests (tests/imported/llvm/Transforms/{CodeExtractor,HotColdSplit,
PartialInlining}) and sweeps of `hotcoldsplit` (also `-hotcoldsplit-threshold=-1`, `--per-function`,
`--with-test-flags`), `loop-extract`, `function(loop-simplify),loop-extract` (also `--per-function`), `extract-blocks`
and `partial-inliner` (also `-skip-partial-inlining-cost-analysis`, `-min-block-execution=1`,
`-pi-force-live-exit-outline`), each with 0 differences.

## CodeExtractor

- The constructor's `VoidReturnWithSingleOutput` defaults to **true**: a region with exactly one output and a common
  exit block returns the output only when the caller passes false. PartialInlining and HotColdSplitting pass false,
  LoopExtractor, BlockExtractor and IROutliner keep the default (one output goes through a `.out` pointer, with a
  `.loc` alloca, lifetime markers and a `.reload`).
- More than two exit blocks give an `i16` return value and a `switch` on the call: the default destination is the
  *last* exit and its case is removed (`SwitchInst::removeCase`), cases 0..N-2 go to the other exits.
- Splits that start at `getFirstNonPHIIt()` (severSplitPHINodesOfEntry, findOrCreateBlockForHoisting) carry the head
  bit, so the debug records in front of the first non-phi move to the new block. The store of an output inserted at
  `std::next(Output)` (no head bit) adopts the records attached to that position, so it is printed *after* them.
  Sunk allocas / lifetime markers are moved with `moveBefore(BB, getFirstInsertionPt())` (head bit): their own records
  stay behind on the next instruction.
- Debug info (fixupDebugInfoPostExtraction): without a DISubprogram on the old function, the new function is
  stripped (`stripDebugInfo(Function&)`) and records in the old function that refer to moved instructions are
  erased. With one, the new subprogram is `distinct !DISubprogram(name = linkageName = the new name, scope: null,
  file/unit of the old one, type: !DISubroutineType(types: !{}), spFlags: LocalToUnit | Definition | Optimized)`.
  Its `retainedNodes` becomes `!{}` only if at least one variable was recreated (DIBuilder's
  `getSubprogramNodesTrackingVector` creates the tracking entry even with AlwaysPreserve = false); otherwise the field
  is absent. Recreated variables are `createAutoVariable` (arg number and flags dropped) in a scope chain cloned by
  `cloneScopeForSubprogram` (distinct lexical blocks come back uniqued). Records whose location is inlined keep
  their variable; labels likewise. New records for inputs used by records of the old function are inserted before the
  new entry block's terminator with an empty DIExpression, in findDbgUsers order. `replaceInlinedAtSubprogram` drops
  atom group/rank. The entry branch gets the first `!dbg` of the region's blocks (in block-set order), the call the
  branch's location, or `!DILocation(line: 0, scope: <old SP>)` if none.
- `updateLoopMetadataDebugLocations` walks `drop_begin(LoopID->operands())`: when an `!llvm.loop` attachment is a
  DILocation (IndVarSimplify/X86/indvar-debug-value.ll), a DILocation without inlinedAt has a single operand, so the
  rebuilt loop ID is `distinct !{!self}`.

## HotColdSplitting

- `markFunctionCold(OutF, /*UpdateEntryCount=*/true)` is called for every outlined function: `cold minsize` and
  `!prof !{!"function_entry_count", i64 0}` even without a profile. The call gets `noinline`; TTI's
  `useColdCCForColdCall` is false on X86.
- `HotColdSplitting::run` iterates `for (Function &F : M)` while outlining appends functions; they are cold and are
  skipped. The cold-branch threshold is the complement of TTI's predictable-branch threshold (1/100 by default).
- The DominatorTree / PostDominatorTree are local to the pass (built lazily on the first cold block); the CodeExtractor
  gets no BFI/BPI, but the cached AssumptionCache.

## LoopExtractor / BlockExtractor

- LoopExtractor visits the functions present when it starts (`E = --M.end()`), uses the analysis manager's DT and
  LoopInfo, `LI.erase(L)` before extracting, and preserves LoopAnalysis. `loop-extract<single>` stops after one loop.
- BlockExtractor without `-extract-blocks-file` only runs `splitLandingPadPreds` on every function.

## PartialInlining multi-region

- `computeOutliningColdRegionsInfo` needs an instrumentation profile; the cold-edge threshold is
  `BranchProbability(int(ColdBranchRatio * MinBlockCounterExecution), MinBlockCounterExecution)` and the minimum
  region cost `int64(float(OverallCost) * MinRegionSizeRatio)` (float arithmetic). Regions are `DT.getDescendants`
  (a worklist: last child first).
- In `doMultiRegionFunctionOutlining` the Inputs/Outputs/Sinks sets live outside the region loop, so once one region
  has an output every later region is skipped (unless `-pi-force-live-exit-outline`).
- Varargs are forwarded (InlineFunction's ForwardVarArgsTo) only for single-region outlining.
