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
  (stable) up to 16 elements. Slabs are malloc'd, so across slabs the order is not creation order. The order among
  terms with the same factor count only matters through findArrayDimensionsRec dividing by the last term: in the
  corpus (`print<delinearization>`, `print<da>` sweeps) reversing every such group never changed the result.
- `printDelinearization` stops the whole function at the first access whose pointer base is not a SCEVUnknown
  (`break`, not `continue`) and prints no newline after the last instruction.
- `SimplifyCFGPass::run` calls `F.renumberBlocks()` after any change (DT->updateBlockNumbers() too). Block numbers
  are otherwise creation order; mem2reg sorts PHI blocks by number, so the renumbering is visible in the `.N`
  suffixes of later SROA phis (tests/e2e/pipeline/.../fbench.ll at -O2).

## Other pipeline-state facts found while matching -O2 on tests/perf/compile (jai, 2026-11)

- `CloneAndPruneIntoFromInst` trims PHIs of blocks whose predecessors changed with `PHINode::removeIncomingValueIf`,
  which walks the entries backwards and moves the last entry into each hole (it does not compact in order); the
  predicate (a per-predecessor count) therefore sees the entries in decreasing index order (SPASS.ll, inliner).
- `CommonPointerBase::compute` leaves `LHSNW`/`RHSNW` at `GEPNoWrapFlags::all()` when one side has no GEPs (the
  other pointer is the base itself), so `foldGEPICmp`'s "(gep Ptr, OFFSET1) cmp (gep Ptr, OFFSET2)" fold applies to
  `icmp ugt %a, (gep %a, %i)` and transformToIndexedCompare (which renames to `.ptr`) is not reached (lua.ll).
- ExpandMemCmp finds memcmp/bcmp with `TargetLibraryInfo::getLibFunc(CallBase)`, which checks the name and the
  prototype but not availability: `bcmp` is expanded on `x86_64-unknown-unknown` too. X86's options:
  MaxNumLoads 2 (also at optsize), NumLoadsPerBlock 2, overlapping loads, load sizes 64/32/16 (zero-equality only,
  by preferred vector width and AVX512/AVX/SSE2), 8 (64-bit), 4, 2, 1; no AllowedTailExpansions.
  `optimiseLoadSequence` passes `emplace_back(PreLast.Offset, LoadSize)` to a (LoadSize, Offset) constructor
  (swapped), harmless on X86 because the tail-expansion list is empty.
- mergeConditionalStores iterates a `SmallPtrSet<Value *, 4>` of common store addresses; past 4 elements it is a
  hash set iterated in pointer-hash order, which only matters when two or more addresses are common.

## Also verified by impl/goose (DA 72/72, Delinearization 23/23, LoopInterchange 61/62, corpus sweeps 0 differences)

- DependenceAnalysis's underlyingObjectsAlias calls getUnderlyingObject with the default MaxLookup =
  MaxLookupSearchDepth = 10 (ValueTracking.h:51); with 6, BasicAA/2014-03-18-Maxlookup-reached.ll prints `confused`
  instead of `none`.
- `print<da>` prints its header before the subtarget feature warnings ('+mpx' is not a recognized feature ...),
  i.e. the target is first touched inside the dependence queries.
- LocationSize::toRaw keeps the scalable bit: DA passes it as the element size to isKnownMultipleOf for scalable
  accesses (no special case).
- tryDelinearize: when tryDelinearizeFixedSize fails after the Src access delinearized, SrcSubscripts stays filled,
  and computeAccessFunctions returns early without clearing it when Sizes is empty.
- LoopInterchange uses `InductionDescriptor::isInductionPHI(Phi, L, SE, D)`, the overload without FP inductions; an
  `fadd reassoc` accumulator is a reduction there (debug-record-after-phi.ll), not an FP induction.
- The MoveInstructions clones are unnamed (Instruction::clone); SplitBlock names the new latch `<latch>.split`.
- **InstructionCost is fixed point** (Support/InstructionCost.h: CostGranularity = 4; the stored Value is 4 x the
  cost, `*` divides the product by 4, `/ CostType` divides the stored value, comparisons with a CostType scale it).
  LoopCacheAnalysis prints it with fractions (`2305843009213693951.75` for a saturated cost,
  interchange-refcost-overflow.ll), and DFAJumpThreading's `NumInsts / CondBranches > CostThreshold` is
  `floor(4*N/cb) > 4*T`, not `floor(N/cb) > T`.
- X86TTIImpl has no cache model: TTI::getCacheLineSize() is 0 on x86-64 unless `-cache-line-size` is given, so
  LoopCacheAnalysis never finds consecutive accesses there and spatial reuse means a negative last-subscript
  difference. CacheCost loops print as `<unnamed loop>` when the header has no name.
