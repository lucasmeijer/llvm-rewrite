# Default-flag sweeps hid silent LoopVectorize bugs; pushing raced with frequent upstream commits

- **Date / implementation / unit:** 2026-11-13 / jai / L1.vectorize.loop (all sub-units)
- **What happened:** the prescribed sweeps (`--passes loop-vectorize`, `--with-test-flags`, `--per-function`, o2
  inputs) were all at 0 differs before I started, yet sweeping with *extra* flags (`--extra='-tail-folding-policy=
  prefer-fold-tail -force-target-supports-masked-memory-ops'`, `-mtriple=x86_64 -mattr=+avx2`,
  `-prefer-inloop-reductions`, ...) immediately found 8 silent mismatches (wrong folder in epilogue resume values,
  int truncation of getPtrStride, the local-vs-CM EpilogueLowering in isOutsideLoopWorkProfitable, ...). Feature
  flags of LV are only exercised by the handful of tests that pass them, so whole-corpus sweeps with feature
  flags are where the bugs are.
  Separately: other agents pushed every few minutes; a full `check --update` took 7-10 minutes at load ~220, so the
  tree moved under every check. Once I ran `git push origin HEAD:main` while a rebase had stopped on a conflict
  (HEAD detached in the middle of the series), which published a prefix of my commits.
- **Time or effort lost:** ~1 hour of check/rebase/push loops; the mid-rebase push was harmless only by luck.
- **What would have helped:** a documented list of "feature-flag sweeps" per pass (for LV: the tail-folding styles,
  in-loop/ordered reductions, scalable widths, native path, alias masking, avx2/avx512 triples); a push helper
  script that refuses to push when a rebase is in progress and re-runs the ratchet only when the upstream diff
  touches `impl/<lang>/`, `harness/` or `tests/`.
- **What you did instead:** ran ~30 extra-flag sweeps (listed in impl/jai/NOTES.md); after each fetch checked
  `git diff --name-only HEAD...origin/main` and re-ran the check whenever jai files had changed.
