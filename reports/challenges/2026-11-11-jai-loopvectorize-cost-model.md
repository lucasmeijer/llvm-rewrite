# LoopVectorize cost model: a decision-diff tool against the assertions opt made it tractable; the unit is now split

- **Date / implementation / unit:** 2026-11-11 / jai / L1.vectorize.loop
- **What happened:** ported the LoopVectorize cost model (legacy getInstructionCost family, VPlan recipe costs,
  computeBestVF, selectInterleaveCount), call widening, replicate regions, interleave groups and tail folding:
  173 -> 283 of the unit's 468 `::opt` checks, 0 silent differences in every `--passes loop-vectorize` sweep. Two
  things would have cost a lot without the assertions build of opt: (1) LLVM 23's InstructionCost is fixed point
  (granularity 4, "Scalar loop costs: 8.5"); a port that keeps costs in integers picks different VFs only on loops
  with predicated blocks, which no forced-VF test shows. (2) A shared analysis difference (IVDescriptors matched
  select-based integer min/max as SMax; LLVM 23 only matches the intrinsics) only surfaced once tail folding made a
  test reach code generation.
- **Time or effort lost:** little thanks to `-debug-only=loop-vectorize`: a per-recipe cost diff pointed at the one
  wrong recipe (a missing insert overhead on scalarized loads) in minutes. Some time went into races with other agents
  while pushing (origin moved during the 2-minute full check three times in a row).
- **What would have helped:** the generated X86 cost tables silently dropped the interleaved-access tables (keyed by a
  factor instead of an ISD opcode: the generator's regexp matched nothing and wrote empty arrays). A generator that
  fails on a table it cannot parse would have avoided a silent wrong cost.
- **What you did instead:** `impl/jai/tools/lv_cost_compare.py` (decision lines and per-recipe costs, ours vs the
  assertions opt, per `; @opt:` line) and `JAI_LV_DEBUG=1`; the generator now parses factor-keyed tables. Split
  L1.vectorize.loop into sub-units (x86, interleave, tail-folding, epilogue, reductions, outer) with their own exit
  selectors, as the previous two reports suggested; the parent unit keeps its full selector.
