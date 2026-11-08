# L1.indvars can't reach COMPLETE without passes from later units

- **Date / implementation / unit:** 2026-11-08 / jai / L1.indvars
- **What happened:** after porting SCEVExpander, SimplifyIndVar and IndVarSimplify, 211/223 `::opt` checks pass and
  every sweep of `loop(indvars)` is identical, but the remaining 12 tests run `loop-deletion` (9),
  `simple-loop-unswitch<nontrivial>`, and `inline,function-attrs` with `-disable-nounwind-inference`. LoopDeletion
  is in L1.loop-misc, whose roadmap deps *include* L1.indvars, so the dependency is circular in practice; the unit's
  exit selector (`Transforms/IndVarSimplify/*`) can't be met by an indvars port alone.
- **Time or effort lost:** little; some time deciding whether porting LoopDeletion (≈600 lines) was in scope.
- **What would have helped:** an exit selector that excludes tests needing passes of later units (or a
  "needs" list per unit, like the SKIPPED.md the importer writes), or the roadmap noting that L1.indvars and
  L1.loop-misc complete together. Also: no `@perf` benchmark times indvars, so the "run perf on the benchmarks that
  time your pass" step had nothing to run; I timed `loops`/`loops-many` by hand.
- **What you did instead:** stopped at the indvars port, listed the blockers in NOTES.md, and measured perf manually.
