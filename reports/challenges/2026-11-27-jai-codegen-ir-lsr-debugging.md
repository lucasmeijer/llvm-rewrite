# Debugging LoopStrengthReduce's solver without LLVM's -debug-only output, and a shared binary under a running check

- **Date / implementation / unit:** 2026-11-27 / jai / L1.codegen-ir
- **What happened:** LSR (7300 lines) picks among thousands of candidate formulae with a cost model; a wrong choice
  shows up only as a different but valid loop. The LLVM in /opt is a release build, so `opt -debug-only=loop-reduce`
  (which prints the uses, formulae, cost and chosen solution) is unavailable. Each mismatch had to be reduced by hand
  to a 20-line loop and then explained by reasoning from our own dumps against the C++ source. The three real bugs
  were Jai traps rather than misread LLVM: `defer i += 1` in a `while` also runs on `break`; `cast(u64) x >> 63`
  parses as `cast(u64)(x >> 63)`; `it_index` inside a nested `for` refers to the inner loop.
  Separately, I rebuilt `bin/opt` while a 10-minute `check --update` was running in tmux (the check uses whatever
  binary is on disk at each test), with a temporary debug print in it; that run had to be thrown away.
  Builds were also OOM-killed (exit 137) twice while other agents' clang/goose builds filled the 30 GB machine.
- **Time or effort lost:** about an hour on the three solver mismatches (each needed a reduction plus a dump
  facility), a lost full check (~10 min), two retried builds.
- **What would have helped:** an LLVM build with assertions (`-debug-only=...`) in the image, even for opt only;
  that would turn every LSR/CGP/SLP cost-model mismatch into a diff of two dumps. A harness option that copies the
  impl binaries to a private directory at the start of `check` (so rebuilding during a long check is safe), or a
  warning in docs/testing.md that `--no-build` checks read bin/ live.
- **What you did instead:** `JAI_LSR_DEBUG=1` prints LLVM-format use/formula lists, cross-use work items, baseline
  cost and solution (lsr_rewrite.jai); reduced tests in /tmp; never rebuild while a check runs.
