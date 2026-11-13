# Publishing loop and other agents' sweep diffs eat time in a busy repo

- **Date / implementation / unit:** 2026-11-29 / jai / L0.print-imported, L1.verifier, L1.instcombine (ppc_fp128,
  DI nodes, x86 auto-upgrades, --preserve-ll-uselistorder)
- **What happened:** (1) "Rerun `check --update` on the exact rebased tree, then push" takes ~6 minutes of check per
  attempt, and several jai agents push to main that often: pushes got rejected twice in a row, and once I pushed
  right after a rebase without the rerun (the check afterwards was clean). (2) The sweeps the task asked for
  (instcombine/sroa, with and without `--preserve-ll-uselistorder`) showed differs in GlobalSplit/*, DataFlowSanitizer
  bad-ir and SampleProfile/* (sroa debug-record order) that also reproduce on origin/main without my changes; telling
  "mine" from "someone else's recent regression" needed a second worktree and build of origin/main.
  (3) The oracle (`/opt/llvm-23.1.5/bin/opt`) occasionally failed under load in my ad-hoc comparison loops
  (14 parallel jobs) and passed on rerun, which looked like test failures.
- **Time or effort lost:** ~20 minutes of repeated full checks; ~10 minutes on the foreign diffs; a few minutes on the
  flaky oracle runs.
- **What would have helped:** a harness mode that checks only the tests affected by the incoming commits after a
  rebase (or a lock/queue for pushes per implementation); a published "known differs on main" sweep baseline per pass
  so a sweep result can be compared against main rather than against zero.
- **What you did instead:** a loop (fetch, rebase, check --update, push) that stops on regressions; a throwaway
  worktree of origin/main to attribute diffs; reruns for oracle failures. The foreign diffs are listed in my final
  report instead of being fixed.
