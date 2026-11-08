# Goose layout work: the perf harness couldn't measure goose (instr) and measures nobody's RSS

- **Date / implementation / unit:** 2026-11-08 / goose / layout experiment (index types, pools, hot/cold split)
- **What happened:**
  1. `perf --instr` had never produced a single goose instruction count (the history has none): under valgrind
     every goose run dies with "goose runtime error: cannot reserve data stack address space". Goose reserves
     2 GB of address space per data stack and opt has ~490 of them (one per global resizable array); valgrind
     gives a client ~128 GB. The table shows it as `exit 1: goose runtime error: cannot r` (cut at 30 columns),
     which looks like a crash of the program, not of the measuring setup.
  2. The `rss` column is the harness's own size, for every implementation: `timed()` takes `ru_maxrss` from
     `wait4` on a child of the ~160 MB Python process, and Linux keeps the pre-exec high-water mark, so every
     tool that peaks below ~160 MB shows the same number as LLVM (goose: 1.00x on all 46 rows, both with and
     without `--instr`). The real numbers were 0.4x (parse) to 3.1x (sroa on SPASS) of LLVM's. Under `--instr`
     the column is additionally valgrind's RSS.
  3. Instruction counts drift by a few tenths of a percent with every commit other agents push to shared files,
     so "after vs baseline" needs a baseline rebuilt from the exact parent commit (a second worktree) each time.
- **Time or effort lost:** about an hour on 1 and 2 (finding the cause, writing a fork+wait4 helper, rebuilding
  binaries with smaller reservations, discovering 256M is still too much for valgrind on the big inputs).
- **What would have helped:** the harness printing the whole first stderr line for a failed perf row; RSS
  measured through a small helper process (or `/proc/<pid>/status` VmHWM polled before exit) instead of `wait4`
  from Python; a `perf --baseline <commit>` that builds and measures the parent commit in a temporary worktree.
- **What you did instead:** `GOOSE_STACK_RESERVE=128M` in impl/goose/build.sh (default unchanged);
  `impl/goose/tools/rss.c` for RSS/CPU; my own cachegrind script over 8 fixed workloads, against binaries built
  from the parent commit in `/work-wt/goose_layout_base`. The harness RSS fix is a shared-file change (needs every
  implementation's check), so I left it for whoever owns the harness.
