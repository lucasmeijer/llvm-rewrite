# L2.globals / L2.ipo-args: two small harness frictions (perf "Errno 26", "passing.txt updated" with no change)

- **Date / implementation / unit:** 2026-11-09 / jai / L2.globals, L2.ipo-args
- **What happened:** (1) The first `./harness/run perf --impl jai 'tests/perf/scaling/globals/*'` in a fresh
  worktree reported every jai row as `error │ could not execute: [Errno 26]` / `[Errno 2]` and "no benchmark
  completed" after 168 s; an immediate rerun worked (3 s). The optimized build had just been installed into
  `impl/jai/bin/` while the benchmarks were being started, so the first runs hit a binary that was still being
  written or replaced. (2) `check --update` prints "impl/jai/passing.txt updated" even when the file did not change
  (`git status` clean), which made me double-check after every rebase whether my newly passing tests were recorded.
- **Time or effort lost:** ~5 minutes in total.
- **What would have helped:** `perf` waiting for `build.sh` to finish installing before timing (or retrying a run
  that fails with ETXTBSY/ENOENT once), and `--update` saying "unchanged" when nothing was added.
- **What you did instead:** reran `perf`; checked `git show origin/main:impl/jai/passing.txt` for the new lines.

Not a friction but worth knowing for whoever designs the units: L2.globals (five passes plus Evaluator, CtorUtils,
GlobalStatus; ~4500 lines of LLVM) and L2.ipo-args went quickly because the shared infrastructure (constant folding,
MemoryBuiltins, AA, mem2reg, the CGSCC pass manager, debug-record RAUW) was already there; the only cross-cutting
surprise was that a `blockaddress` is a user of its function in the Jai IR but not in LLVM 23 (30 silent mismatches
in the first globalopt sweep, all from that), now recorded in knowledge/llvm/ipo-globals-and-arguments.md.
