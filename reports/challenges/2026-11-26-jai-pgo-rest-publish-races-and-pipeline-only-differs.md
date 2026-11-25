# Publishing under load races other agents; pipeline sweeps surface analysis-state bugs that unit sweeps never see

- **Date / implementation / unit:** 2026-11-26 / jai / L1.extra.pgo.instr, L1.extra.sample-profile
- **What happened:** (1) The full `check --update` takes 6-10 minutes under load; origin/main moved during almost every
  run, so each publish needed 2-4 rebase + recheck rounds (and once a `port-progress.txt` conflict every time, because
  every agent appends to its end). Twice I chained `git rebase ... ; ./harness/run check --update` and the check ran
  on a half-rebased tree with conflict markers. (2) The new `-O2 -pgo-kind=pgo-instr-gen-pipeline` sweep found 7
  differs, none in the PGO passes: a SROA global array whose temp-allocated buffer survived `reset_temporary_storage`
  between SCCs (corrupted DT updates), a missing LastUnique bump in removeUnwindEdge, a DILocation used as
  `!llvm.loop`, plus three AssumptionCache / SCEV-cache state divergences that only show up in a pipeline (the pass
  agrees with LLVM standalone).
- **Time or effort lost:** ~1.5 h on publish rounds; ~1 h bisecting pipeline-only differs (opt-bisect-limit + module
  reduction scripts written ad hoc).
- **What would have helped:** a harness `publish` command that does fetch/rebase/build/check/push atomically and stops
  on a conflict; a `bisect` mode for `--extra` pipelines on sweep failures that also reduces the module to the
  functions needed (I wrote /tmp scripts for both); appending to port-progress.txt in sorted order to avoid the
  end-of-file conflict.
- **What you did instead:** a small publish loop script (stop on conflict, retry when origin moved), and a function
  ddmin over llvm-extract pieces to get two-function repros. The analysis-state differs are written down in
  impl/jai/NOTES.md (profile family section).
