# goose builds of opt took ~5.5 minutes, almost all of it one single-threaded clang -O2

- **Date / implementation / unit:** 2026-11-13 / goose / build tooling (no unit)
- **What happened:** asked to speed up the goose edit→build→check cycle. Measured: the goose frontend is ~50 s
  single-threaded (45 s of it typecheck, no knob changes it), then `goose build` compiles one 64 MB, 1.74 M-line C
  file with clang -O2 in ~255 s on one core. Nothing in the goose docs offers splitting the C, so build.sh now
  splits the generated C itself (tools/splitc.py, relying on goose v2026.4's fixed C layout, with a fallback to
  the whole file) and links with ThinLTO: 72 s cold, ~70 s per edit, 0 s when unchanged or cached.
  Two side findings:
  - The first `./harness/run perf` in a fresh worktree reported 22 benchmarks as
    `could not execute: [Errno 26]` (ETXTBSY). That's the harness's RSS helper (`harness/lrh/perf.py`
    `rss_helper()`): its parallel timing threads each find the helper missing, build it and `os.replace` it while
    another thread is already executing it. The second run was clean. A lock (or building it before starting the
    threads) would fix it; I didn't touch harness/.
  - perf numbers on this shared box move ±10% geomean between two identical runs (load 10-20 from other agents),
    so a "the split build is x% slower" claim needs the same benchmark run back to back several times.
- **Time or effort lost:** ~1 hour of waiting on baseline builds and perf runs; ~10 minutes on the ETXTBSY errors.
- **What would have helped:** the build cost being visible earlier (the challenge reports complained for weeks);
  a `goose build` option to emit several translation units.
- **What you did instead:** see impl/goose/NOTES.md "Build". If goose gets a split-C option, drop tools/splitc.py.
