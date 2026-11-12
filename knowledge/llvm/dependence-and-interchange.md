# DependenceAnalysis, Delinearization, LoopInterchange (LLVM 23.1.5)

Verified by the jai port (impl/jai/src/dependence_analysis.jai, delinearization.jai, pass_loop_interchange.jai)
against tests/imported/llvm/Analysis/DependenceAnalysis (72/72), Analysis/Delinearization (23/23) and
Transforms/LoopInterchange (62/63).

- `loop-interchange` is in `default<O1..O3>` (`-enable-loopinterchange` defaults to true), as a LoopNest pass in the
  second loop pipeline after indvars. Its default profitability rules are `instorder,vectorize`; `cache`
  (LoopCacheAnalysis / CacheCost) is only used with `-loop-interchange-profitabilities=cache`. A `cl::list` with
  `list_init`: the first command-line value replaces the defaults. Every nest of depth >= 2 with computable
  backedge-taken counts queries DependenceInfo::depends for each pair of loads/stores (not load/load).
- LLVM 23's DependenceAnalysis has no constraint propagation and no symbolic RDIV test any more: ZIV, strong /
  weak-crossing / exact / weak-zero SIV, exact RDIV, GCD MIV, Banerjee MIV (Banerjee is off unless
  `-da-enable-dependence-test=all|banerjee-miv`). Subscripts must be AddRecs with `nsw`; offsets must be a known
  multiple of the access size (otherwise a runtime predicate, which only `print<da>` accepts:
  `UnderRuntimeAssumptions` is true there and false for LoopInterchange).
- `print<da>` prints every pair (Src, Dst) with Dst at or after Src in instruction order, including Src == Dst,
  for any instruction that may read or write memory (calls give `confused`). Instructions are printed with
  Instruction::print's two leading spaces (`Src:  store ...`).
- `findArrayDimensions` first sorts the parametric terms by SCEV pointer value (`array_pod_sort`), then
  `llvm::sort`s them by number of factors. Pointer order is creation order within a BumpPtrAllocator slab, so an
  implementation can approximate it by SCEV creation order; with libstdc++ the second sort is an insertion sort
  (stable) up to 16 elements.
- `printDelinearization` stops the whole function at the first access whose pointer base is not a SCEVUnknown
  (`break`, not `continue`) and prints no newline after the last instruction.
- `SimplifyCFGPass::run` calls `F.renumberBlocks()` after any change (DT->updateBlockNumbers() too). Block numbers
  are otherwise creation order; mem2reg sorts PHI blocks by number, so the renumbering is visible in the `.N`
  suffixes of later SROA phis (tests/e2e/pipeline/.../fbench.ll at -O2).
