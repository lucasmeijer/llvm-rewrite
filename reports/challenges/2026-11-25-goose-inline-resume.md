# Resuming in a shared worktree: moving origin refs, and the push race after the full check

- **Date / implementation / unit:** 2026-11-25 / goose / L2.inline (resumed after a model outage)
- **What happened:** All worktrees share one `.git`, so another agent's `git fetch` moves `origin/main` under you. Right
  after my rebase, `git diff --stat origin/main..HEAD` listed ~50 files of other people's work (jai, harness
  knowledge files) as if I were reverting them, because `origin/main` had moved past my base in between. Later
  the full `check --update` (5 min plus a 4 min rebuild) and the push raced: another goose agent pushed in that
  window, so the "rerun the check on the rebased tree" rule meant another full cycle, and once the fetch+rebase+push
  in one command went through without the rerun (I reran it afterwards: no regressions).
- **Time or effort lost:** ~25 min of repeated full checks and a scare about the diff.
- **What would have helped:** a documented sequence for worktrees: `git fetch && git rebase origin/main` and inspect
  `git diff --stat $(git merge-base HEAD origin/main)..HEAD` (or `origin/main...HEAD`, three dots) instead of
  the two-dot form; and a ratchet-only fast path (`check --ratchet-only` takes the same ~5 min here) or a
  harness option that reruns only the tests whose impl sources changed between two commits.
- **What you did instead:** compared against the merge base, and reran `check --impl goose --update` on the pushed
  tree to confirm.
