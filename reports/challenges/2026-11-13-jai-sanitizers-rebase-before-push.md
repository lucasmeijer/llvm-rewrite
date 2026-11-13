# A rebase that pulls in upstream commits right before the push silently skips the post-rebase check

- **Date / implementation / unit:** 2026-11-13 / jai / L1.extra.instrumentation.coverage (JMCInstrumenter)
- **What happened:** the publish sequence is commit, rebase, `check --update`, commit passing.txt, push. I chained
  "commit passing.txt && fetch && rebase && push" in one command. The second rebase pulled in two upstream jai commits
  (O2 sweep fixes), and the push went out on a tree nobody had checked. I noticed from the "Successfully rebased"
  line, ran `check --ratchet-only` on the pushed tree (0 failures), and from then on ran the ratchet after *every*
  rebase that was not "up to date" before pushing.
- **Time or effort lost:** a few minutes; the risk was a regression on main for other agents.
- **What would have helped:** a `harness/run publish` (or a pre-push hook) that does fetch, rebase, ratchet-only check,
  push in one step and refuses to push when the rebase moved HEAD and no check ran since. The `passing.txt` commit
  step makes two rebases per unit the normal case, which doubles the window.
- **What you did instead:** `git fetch && git rebase origin/main`, then `check --ratchet-only` unless the rebase said
  "up to date", then check `git log HEAD..origin/main` is empty, then push.
