# L1.instsimplify is several units in one, and recalled LLVM behaviour was wrong more often than expected

- **Date / implementation / unit:** 2026-11-09 / jai / L1.instsimplify
- **What happened:** The unit's exit selector (all of `Transforms/InstSimplify/*`) needs much more than
  InstructionSimplify.cpp: all of ValueTracking (known bits, non-zero, sign bits, implied conditions, ranges,
  poison reasoning), KnownFPClass + computeKnownFPClass + ConstantFPRange + fcmpImpliesClass, ConstantFolding.cpp
  including the ~3000 lines of call folding (host libm, a TargetLibraryInfo subset), and an APFloat with rounding
  modes (fma, roundToIntegral, next, remainder, scalbn/frexp, convertToInteger). About 15k lines of Jai. 11 of the
  249 opt checks can't pass in this unit at all: they run instcombine (5), early-cse with `-earlycse-debug-hash`
  (3), loop-unroll, jump-threading or always-inline in the same RUN line. The unit can never be COMPLETE on its own.
- **Time or effort lost:** Most debugging time went to places where I *assumed* LLVM's behaviour instead of reading
  the 23.1.5 source: `BinaryOp_match` no longer matching constant expressions, `isManifestConstant` excluding undef,
  `getNullValue` of FP vectors being a vector ConstantFP, `ICmpInst::isEquality` vs `CmpInst::isEquality` in
  constant folding, `hasPoisonGeneratingAttributes` ignoring declaration attributes, `m_SMax` no longer matching
  selects. Each was a one-line fix after a long diff hunt. The full-corpus sweep (instsimplify on all 6994
  round-tripping imported files vs the oracle) found ~15 bugs the unit tests didn't; it is cheap (40 s) and should
  be mandatory.
- **What would have helped:** (1) Splitting the unit: L1.analysis.valuetracking (with print<...> style checks or
  the ValueTracking imported tests), L1.constfold (ConstProp/* tests), L1.fpclass, then L1.instsimplify. (2) Marking
  tests whose RUN line needs another pass as belonging to that pass's unit, so "COMPLETE" is reachable. (3) A
  standing instruction "grep the 23.1.5 source for every matcher/helper you use; LLVM 23 changed many of them".
  (4) The sweep script in the harness (`harness/run sweep --pass instsimplify`) instead of each agent rewriting
  cmp.sh.
- **What you did instead:** Ported everything into reusable modules (documented in impl/jai/NOTES.md and
  DESIGN.md), recorded the surprising facts in knowledge/llvm/instsimplify-and-value-tracking.md, and failed
  loudly for what isn't ported (salvageDebugInfo expression rewriting, ppc_fp128 arithmetic).
