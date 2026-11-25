# The SandboxVectorizer framework commit the task built on was not on main

- **Date / implementation / unit:** 2026-11-29 / jai / L1.extra.sandbox-vectorizer
- **What happened:** the task said to read NOTES.md / DESIGN.md "SandboxVectorizer" and the challenge report
  2026-11-28-jai-extras-d-unit-sizes.md, but none of them existed on origin/main: the framework commit (bd41595e,
  "framework ... 7/24 opt") only lived on the local branch `jai_extras_d` of an earlier worktree and was never pushed.
  I found it with `git log --all --grep=sandbox` and cherry-picked it.
- **Time or effort lost:** ~10 minutes of confusion; it would have been much more had the branch been deleted.
- **What would have helped:** a publish step that fails loudly when a task ends with unpushed commits (the new
  `scripts/publish.sh` should make this rarer), or the task message naming the commit to start from.
- **What you did instead:** cherry-picked the commit and published it together with the rest of the unit.
- **Also:** LLVM's own output is nondeterministic for this pass on 15 corpus files (DenseMap<BasicBlock *> order
  in BottomUpVec::tryEraseDeadInstrs, see knowledge/llvm/vectorizers.md); the sweep reports them as loud failures of
  ours, which is right, but a sweep option to re-run LLVM a few times and flag such files would save the manual check.
