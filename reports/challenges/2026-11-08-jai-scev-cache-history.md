# ScalarEvolution: unit tests only check fresh analyses; the cache-history bugs needed a hand-made sweep

- **Date / implementation / unit:** 2026-11-10 / jai / L1.analysis.scev (+ the 4 print<loopnest> checks of
  L1.analysis.loops)
- **What happened:** the port of ScalarEvolution.cpp (~16k lines of C++, ~9k lines of Jai) passed 233/239 of the
  unit's analysis checks on the first full build, and a sweep of `print<scalar-evolution>` over all ~7780
  round-tripping files was clean too. But the task also asked for SCEV in the loop pass manager, and none of the
  unit's tests exercise a ScalarEvolution that survives a transform. Two real bugs only showed up with a pipeline I
  made up, `print<scalar-evolution>,loop(loop-rotate),print<scalar-evolution>`: (1) our pass manager frees and
  rebuilds the AssumptionCache when a pass doesn't preserve it, while LLVM's AssumptionCache never invalidates
  itself, so ScalarEvolution was being dropped after every loop pass; (2) Loop::makeLoopInvariant has an `SE`
  parameter (forgetBlockAndLoopDispositions) that the earlier LoopSimplify port had no reason to keep. Both change
  printed no-wrap flags / trip counts, because SCEV nodes keep their flags across queries.
- **Time or effort lost:** ~1 hour finding and bisecting these; little otherwise. Separately, ~6 rebuilds for
  procedure-name collisions with other agents' files (Select_Pattern, is_const_int, block_unique_successor, ...).
- **What would have helped:** a few tests per analysis that print it twice around a transform (LLVM's own
  Analysis/ScalarEvolution tests almost never do), or a roadmap note that "preserved analyses" must be tested through
  their printer after the passes that preserve them. For the name collisions, a one-line `grep -n "^name ::"` habit
  is enough; a lint in build.sh that lists duplicate top-level names would catch them before Jai's "ambiguous
  overload" error, which points at the call site and not the new definition.
- **What you did instead:** added `SWEEP_FAILS=1` to impl/jai/tools/sweep.py (lists every failing file) and swept
  the double-print pipeline, `verify<scalar-evolution>` after loop-rotate, print<loopnest>, print<iv-users> and
  scev-aa. Documented the cache-history facts in knowledge/llvm/scalar-evolution.md. The sweep pipelines are listed
  in impl/jai/NOTES.md so the next pass that runs with a ScalarEvolution can rerun them.
