# GVN for Goose: IR-mode sweeps hide unfolded constants, and no perf row times GVN

- **Date / implementation / unit:** 2026-11-14 / goose / L1.gvn
- **What happened:** Three things cost time or needed guessing.
  1. The IR-mode sweeps (`sweep --passes gvn`, also `--per-function`) were clean, but `gvn<memoryssa>,print<memoryssa>`
     in `--analysis` mode showed `ret b8 bitcast (i8 42 to b8)` where LLVM prints `ret b8 42`, and `f0xBFF8...` where
     LLVM prints `-snan(0x7B)`. The `::opt` check and IR sweeps send both outputs through `llvm-as | llvm-dis`,
     which folds the constant expression and reprints the float, so constant-folding and APFloat bugs in shared code
     (constfold.goose, apfloat.goose) were invisible there. They were old bugs, not GVN's, found only by chance.
  2. No `@perf` benchmark in tests/perf times `-passes=gvn`, so `./harness/run perf` had nothing to say about the
     pass. I measured by hand (tools/rss.c, callgrind on tests/perf/scaling/*) and found two problems that the
     harness would have shown: a quadratic switch-edge count and a slow comparison sort (2.2x LLVM on allocas).
  3. Each rebase conflicted in passmgr.goose (pass ids, class names, the subtarget list) and breakcrit.goose with the
     concurrent goose agents (CVP/jump-threading, LICM): same lines, different passes. Resolution is mechanical
     (union) but needs care every time, and a full ratchet run afterwards (~1 minute plus a 2-minute build).
- **Time or effort lost:** about an hour on the perf investigation that a perf row would have made obvious; the
  hidden constant-folding bugs were found by luck (an extra sweep I chose to run).
- **What would have helped:** (1) a note in docs/testing.md that IR-mode comparison canonicalizes constants, and a
  recommended "printer" sweep (e.g. `<pass>,print<memoryssa>` or any `--analysis` printer that echoes IR) for
  passes that create constants; or a non-canonicalizing IR sweep mode (`--raw`). (2) `gen-perf` rows for gvn
  (and the other big L1 passes) on the scaling shapes. (3) passmgr.goose's per-pass tables split per pass (e.g.
  one row per pass in one table), so parallel pass ports touch different lines.
- **What you did instead:** ran the printer sweeps by hand and fixed what they found (constfold.goose int<->byte
  bitcasts, apfloat.goose x87 unnormals); measured GVN with tools/rss.c and callgrind and wrote the numbers in
  impl/goose/NOTES.md.
