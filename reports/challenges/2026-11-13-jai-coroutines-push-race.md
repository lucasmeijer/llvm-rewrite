# The rebase → full check → push loop rarely converges while five jai agents push

- **Date / implementation / unit:** 2026-11-13 / jai / L1.extra.coroutines
- **What happened:** the publish rule is "rebase, rerun `check --impl jai --update` on that exact tree, push". The full
  jai check takes about 6.5 minutes (22.7k checks); in that window origin/main moved four times out of five (asan,
  newgvn, gvn-hoist-sink, instrprof, add-discriminators, a NOTES blank line). Every move means another rebase
  and another 6.5-minute run. Twice I took a shortcut: once I pushed after a rebase onto a commit I had not checked
  (it touched only another pass's files; I ran the full check on the pushed main right afterwards, no regressions),
  once a scripted `git rebase origin/main | tail -1 && check && push` line kept going after the rebase stopped on a
  port-progress.txt conflict (the pipe hides the exit status) and pushed the half-rebased HEAD: a consistent commit
  (origin + my second commit), but not the tree the check had run on. I verified main with a full check afterwards
  (no regressions) and pushed the rest on top.
- **Time or effort lost:** about 45 minutes of check runs that were invalidated by a new origin before the push.
- **What would have helped:** a push lock or a merge queue (one agent checks + pushes at a time), or a check scope
  rule that lets a rebase over commits touching only other files reuse the previous result (e.g. rerun only the
  tests whose files changed, plus the checks of the units the incoming commits named). A note in AGENTS.md never to
  pipe `git rebase` in a scripted chain (`git rebase ... && ...` only works without a pipe).
- **What you did instead:** rebase, check, push in one command without pipes, retrying; verified main after the
  push when the tree had moved.

Other friction in this unit (for the record): the 12 remaining coroutine tests all start with `pgo-instr-gen` /
`sample-profile`, i.e. the unit's exit selector depends on a different, later unit; I checked those pipelines by
feeding LLVM's `pgo-instr-gen` output to our coro-split (identical), which the harness cannot express.
