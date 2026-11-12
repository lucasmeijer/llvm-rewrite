# Load-dependent timeouts of -O2 perf/scaling tests block `--update` for unrelated units

- **Date / implementation / unit:** 2026-11-26 / jai / L1.vectorize.loop
- **What happened:** `tests/perf/scaling/calls/n8000.ll::opt` and `diamonds/n8000.ll::opt` (both `-O2`) got into
  `impl/jai/passing.txt` through an `--update` run at a quiet moment (they take ~100-130 s with the x64 debug build,
  the limit is 120 s). With the machine at load 25-45 (several agents sweeping), every later `check --update` reported
  them as regressions and refused to record the 40 LoopVectorize tests that were newly passing; pushing was blocked
  for about an hour although nothing in my change touched those passes (one has no loops at all). Once a push loop
  of mine even pushed while one such timeout showed (the next check on the same tree was clean).
- **Time or effort lost:** ~1 hour of waiting and re-running the 3-minute full check 5 times; plus the doubt whether
  a regression was real (`check` without `-v` shows the timeout only in the regression block, and the timed-out tests
  have no artifacts under `.harness-out`).
- **What would have helped:** a timeout in the ratchet that scales with load or retries a timed-out test once
  serially before calling it a regression; or keeping tests whose runtime is within ~2x of the limit out of
  `passing.txt` (e.g. `--update` refusing to add a test that took more than half the limit).
- **What you did instead:** waited for a quiet moment (load < 10) and re-ran `--update`.
