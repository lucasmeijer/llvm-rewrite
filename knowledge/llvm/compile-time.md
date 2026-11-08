# Compile time (LLVM 23.1.5)

How fast LLVM's own tools are, as a reference for `./harness/run perf`. All numbers are from `harness/run perf --impl
llvm` (with `--instr` for instruction counts) on the 16-core workspace VM; instruction counts are exact (cachegrind),
times approximate.

- **Executed-instruction counts are deterministic.** Two cachegrind runs of `opt -O2` on `tests/perf/compile/lua.ll`
  gave the same count to the instruction (4,540,937,588), so a ratio of counts is a fair comparison even under load.
  Hardware counters are not available: `perf_event_open` fails with `EPERM` in the container.
- **CPU time (user + system) holds up under parallel load; wall time doesn't.** Running `opt -O2` on lua 16 times at
  parallelism 1, 4, 8 and 16 gave median CPU times of 1.06, 1.04, 1.07 and 1.12 s. Up to half the cores the median is
  within a few percent of a solo run, which is why `perf` defaults to `-j` = cores/2.
- **Process startup is ~10 M instructions** for `opt` on an empty module. That's why `perf` subtracts an empty-module
  baseline before fitting scaling exponents; at the smallest sizes it's a large share of the total.
- **Most passes scale linearly on the synthetic shapes** (k between 0.85 and 1.1): parse+print, instcombine,
  early-cse, simplifycfg, mem2reg, sroa, inline, globalopt.
- **`opt -O2` is about quadratic in the number of sequential loops in one function** (`scaling/loops`, k ≈ 1.8–2.1):
  10 → 40 → 160 loops costs 36 M → 258 M → 8,451 M instructions, and 800 loops took 157 s. An implementation matching
  k ≈ 2 there is faithful, not slow. Which pass causes it hasn't been investigated.
- **mem2reg output is quadratic if the number of promoted slots grows with the number of blocks** (every slot needs a
  phi in every join block). The `allocas` shape keeps 32 slots for that reason.
- **Real programs** (`tests/perf/compile/`, pre-pipeline IR from clang): `opt -O2` takes 1–4.6 s and 4.5–17 G
  instructions; `llc -O2` on the optimized IR costs about as much as `opt -O2` itself (0.9–2.8 s).
