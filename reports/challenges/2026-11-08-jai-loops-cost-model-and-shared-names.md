# Loop infrastructure: LoopRotate needs the x86 cost model, and concurrent agents collide on global helper names

- **Date / implementation / unit:** 2026-11-08 / jai / L1.analysis.loops, L1.loop-canonical (LoopInfo, CycleInfo,
  LoopSimplify, LCSSA, loop pass manager, LoopRotate)
- **What happened:**
  1. LoopRotate's decision to rotate depends on `TTI.getInstructionCost(I, TCK_CodeSize)` summed over the header
     (CodeMetrics) and compared with a threshold of 16. Nothing in the roadmap says that LoopRotate (in
     L1.loop-canonical) depends on the x86 cost model (L1.analysis.cost-model, not ported by anyone). I used
     lower/upper bounds per instruction (exact for calls/branches/free intrinsics, an assumed [0, 2] for scalar
     arithmetic, compares, casts, loads/stores, unbounded otherwise) and fail loudly when the bounds straddle the
     threshold. The [0, 2] bound is read from X86TTIImpl/BasicTTIImpl, not ported, so it is a documented risk.
  2. Several agents add helpers to the same Jai program at the same time. Jai procedure names are global, so after
     a rebase my build broke twice with "matches 2 possible overloads" (`block_unique_predecessor`,
     `drop_ub_implying_attrs_and_metadata`, added by jai_instcombine on the same day with the same semantics).
     Grepping before adding helpers doesn't help when the other agent hasn't pushed yet.
  3. A failed Jai compile run from `impl/jai/` leaves `impl/jai/.build/` behind (only `src/.build` and `bin/.build`
     are in .gitignore); `git add -A impl/jai` committed it once. I caught it before pushing.
  4. `L1.loop-canonical`'s exit selector is mostly tests whose pipelines need other passes (licm, indvars,
     simple-loop-unswitch, loop-deletion, instcombine, simplifycfg, debugify, SCEV verifiers) and MemorySSAUpdater
     (`loop-mssa(...)`), so the unit can't be COMPLETE before most of the loop units are; 58/92 `::opt` is the
     ceiling for loop-simplify/lcssa/loop-rotate alone right now.
- **Time or effort lost:** ~20 min on the cost-model question (reading X86TTIImpl to justify the bound), ~15 min on
  the name collisions and the rebase, a few minutes on the .build directory.
- **What would have helped:** a roadmap dep from L1.loop-canonical (LoopRotate) to the cost model, or a note in
  the unit that header-size decisions need TTI code-size costs; a naming convention per area for shared Jai helpers
  (e.g. prefix by file) or a shared "utilities" file that agents announce changes to; `impl/jai/.build/` in
  .gitignore (or build.sh cleaning it).
- **What you did instead:** bounds + fail loudly (pass_loop_rotate.jai `tti_code_size_bounds`, documented in
  impl/jai/NOTES.md); deleted my duplicates and reused the ic_core.jai versions; removed .build before committing.
  Sweeps (`impl/jai/tools/sweep.py`) over ~7780 files show no output differences for loop-simplify, lcssa and
  loop(loop-rotate).
