# SimplifyCFG + X86 TTI: shared-helper bugs surface as "my" regressions, and debug-info correctness only shows in a sweep nobody runs by default

- **Date / implementation / unit:** 2026-11-10 / jai / L1.simplifycfg (288/289) + L1.analysis.cost-model (122/122)
- **What happened:** (1) Two tests that had passed (merge-deopt-bundle-constants.ll, merge-compatible-invokes-of-
  landingpad.ll) crashed after a rebase. The cause was an old bug in a shared helper (`ic_clone_inst` copied one
  u32 per operand bundle instead of three) that my new mergeCompatibleInvokes path started to exercise; a similar
  shared bug (`drop_unknown_non_debug_metadata` dropping `!DIAssignID`) blocked a conditional-faulting test. Both
  were found by reading stack traces, not by the harness pointing at the helper. (2) The unit's 289 opt tests
  were green, but `sweep --passes 'debugify,simplifycfg'` (suggested by another agent) found 61 debug-record
  mismatches: almost all were a wrong "head bit" on an insertion point — a semantic of LLVM's RemoveDIs that no
  imported SimplifyCFG test checks directly. (3) The unit asks for a TTI "with all cost kinds"; the cost-model unit
  needed the whole BasicTTIImpl intrinsic/reduction/shuffle machinery, which was much bigger than the X86 tables.
- **Time or effort lost:** ~1 hour on the bundle/DIAssignID helper bugs; a few hours on the debugify sweep; a
  background sweep I started was silently killed with the tool call, costing a 20-minute wait.
- **What would have helped:** listing `debugify,<pass>` sweeps in the unit's finish checklist for every pass
  unit (it is cheap and found real bugs); a harness hint when a crash's top frames are in files other than the
  ones the current commit touched; a note in AGENTS.md that background jobs don't survive a tool call.
- **What you did instead:** fixed the helpers in place (they are shared, so I ran the full ratchet), added the
  head-bit rule to knowledge/llvm/simplifycfg.md and impl/jai/NOTES.md, ran sweeps in the foreground.
