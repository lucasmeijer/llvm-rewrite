# Three Layer-1b units in one task: the SandboxVectorizer did not fit

- **Date / implementation / unit:** 2026-11-28 / jai / L1.extra.load-store-vectorizer, L1.extra.codegen-ir-misc, L1.extra.sandbox-vectorizer
- **What happened:** the task bundled three units. LoadStoreVectorizer (one 2000-line file) and codegen-ir-misc
  (eight passes, ~7000 lines of LLVM including X86InterleavedAccess and IntegerDivision) were completed with
  0-differs sweeps, but they used most of the session. SandboxVectorizer is not one pass but a second IR
  (SandboxIR: ~4200 lines of wrappers, a Tracker with revert, callbacks) plus ~3100 lines of vectorizer
  (DependencyGraph, Scheduler, Legality, BottomUpVec, LoadStoreVec, PackReuse). Only its framework (pass
  manager, regions, seed collection up to the first slice) was ported; 17 of its 24 opt tests fail loudly.
- **Time or effort lost:** none lost, but the third unit's estimate was off by a large factor; a unit whose roadmap
  line reads like "one pass" hides a whole IR layer.
- **What would have helped:** splitting L1.extra.sandbox-vectorizer in the roadmap (framework + regions; DAG +
  scheduler; bottom-up-vec + legality; load-store-vec / pack-reuse) and giving it its own task. Also a note in the
  roadmap that the new-PM GlobalMergePass ignores -global-merge-max-offset (half of its RUN lines are no-ops).
- **What you did instead:** ported the framework faithfully with loud failures for every unported region pass,
  documented the data-oriented design and the remaining work in DESIGN.md / NOTES.md, and recorded the partial
  fractions in port-progress.txt.
