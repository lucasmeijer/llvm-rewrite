# mem2reg/SROA needed ValueTracking that another agent was porting at the same time

- **Date / implementation / unit:** 2026-11-09 / jai / L1.mem2reg, L1.sroa
- **What happened:** mem2reg calls `isGuaranteedNotToBePoison`, `isKnownNonZero` and `simplifyInstruction`, and
  SROA builds on IRBuilder/ConstantFolder, GEP offset helpers and SSAUpdater. The Jai ValueTracking/InstSimplify
  port (agent jai_instsimplify) was in flight and unpushed, with names it asked me not to use. I wrote an
  interim copy (`m2r_poison.jai`), renamed ~20 of my helpers after a name-collision exchange, and then deleted the
  copy once their work landed. Two merges hit ambiguous-overload errors (Jai procedure names are global, and
  only checked when reachable, so a collision shows up only after rebase).
- **Time or effort lost:** ~1-2 hours on the interim port, renames and merge fix-ups.
- **What would have helped:** roadmap deps listing analyses, not just units (L1.mem2reg depends on
  "ValueTracking poison/nonzero + InstSimplify PHI" which belong to L1.instsimplify); or a convention that shared
  analyses get their own small unit that lands first. A per-impl list of "who owns which shared file / name
  prefix" would have avoided the collisions.
- **What you did instead:** messaged the other agent for the exact names, used prefixed names (`m2r_`, `sv_`,
  `irb_`, `sroa_`) for everything in my files, and switched to the shared API as soon as it was pushed.
