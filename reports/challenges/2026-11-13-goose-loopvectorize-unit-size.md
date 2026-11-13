# LoopVectorize + VPlan is far larger than one task; the useful tooling lived in another implementation's directory

- **Date / implementation / unit:** 2026-11-13 / goose / L1.vectorize.loop
- **What happened:** the task asked for four milestones (legality, VPlan construction/execution, the cost model,
  reductions / recurrences / if-conversion / replicate regions / interleave groups / tail folding / epilogue) plus four
  sweep modes after each. LoopVectorize.cpp + VPlan*.cpp + LoopVectorizationLegality/Planner + IVDescriptors +
  InterleavedAccessInfo is ~35k lines of LLVM. In one task (with one context compaction) goose got milestones 1-3
  and the common half of milestone 4 (plain reductions, interleaving, scalar interleaving): 808 of 919 -O2
  loop-vectorize inputs identical, 74 of 607 imported LoopVectorize runs. If-conversion, replicate regions,
  interleave groups, tail folding, runtime checks and epilogue vectorization are still loud failures.
- **Time or effort lost:** roughly a third of the effort went into reading LLVM code paths that the first unported
  feature then cut off (e.g. the full cost model is useless for -O2 until InterleavedAccessInfo runs, because X86
  enables it for every inner loop; then most -O2 loops need reductions or runtime checks).
- **What would have helped:** splitting L1.vectorize.loop into roadmap units with their own exit selectors, ordered by
  what -O2 hits first: (1) InterleavedAccessInfo analysis + the cost model + computeBestVF / selectInterleaveCount
  for straight-line loops, (2) plain reductions + unrollByUF, (3) runtime checks, (4) interleave groups, (5)
  predication / replicate regions / tail folding, (6) epilogue vectorization. The best prioritisation tool,
  `impl/jai/tools/o2_lv_inputs.py` (collects the IR -O2 hands loop-vectorize and compares two opts on it), and the
  cost-line differ `impl/jai/tools/lv_cost_compare.py` live in the jai tree and read `JAI_*` variables; they work for
  any implementation and belong in `harness/` or `scripts/`.
- **What you did instead:** used the jai tools with `JAI_OPT=impl/goose/bin/opt` and a `GOOSE_LV_DEBUG=1` trace that
  prints the same lines; kept a ranked next-steps list in impl/goose/NOTES.md. Goose-specific friction worth knowing:
  function names are global across modules (two files defining `lv_cmp_result_type` is an "ambiguous call" error far
  from either file), and `table[f()]` with an `f` that grows `table` indexes out of bounds.
