# The per-function sweep can't see target-specific folds, and every rebase costs a 15-minute ratchet

- **Date / implementation / unit:** 2026-11-21 / goose / L1.instcombine (TargetLibraryInfo, LibCallSimplifier,
  X86InstCombineIntrinsic)
- **What happened:** the task said "use the per-function sweep before/after, 0 differs at the end". For
  LibCallSimplifier that works well. For X86TTIImpl::instCombineIntrinsic it barely helps: almost every test under
  `InstCombine/X86/` gets its target from `-mtriple` on the RUN line, and `sweep --passes instcombine` passes no
  such flag, so those modules have no triple, get the NoTTIImpl and never reach the code being ported (about 7 of
  70k functions did). The real signal was `check 'tests/imported/llvm/Transforms/InstCombine/X86/*::opt'` (9 -> 53
  of 55 passing). Separately, each push needed: full ratchet (~15 min), fetch/rebase, and, when another goose agent
  had pushed in between (three times), another full ratchet on the rebased tree. A goose rebuild is ~2 min of the
  same budget.
- **Time or effort lost:** ~1 hour of ratchet runs that only re-confirmed results; no time lost on the sweep gap
  because the task description warned about it, but a reader of the sweep numbers alone would think the X86 port is
  untested.
- **What would have helped:** a sweep option that adds the test's own RUN-line flags (`-mtriple`, `-mattr`) to
  each piece, or a note in docs/testing.md that target-intrinsic work must be judged by `check` on the target's
  test directory. For the ratchet: a way to rerun only the tests affected by the files the rebase brought in (or
  only the `::opt` checks of the impl when only impl/<lang>/src changed on main).
- **What you did instead:** used `check` on the X86 directory as the measure for task 3, the sweep for
  regressions (0 identical -> non-identical between the first and the last sweep), and ran the full ratchet before
  every push as required.
