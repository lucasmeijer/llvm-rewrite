# Sweep-up: a 20-minute ratchet against a main that moves every few minutes, and hidden order bugs

- **Date / implementation / unit:** 2026-11-13 / jai / sweep of L0-L2 remainders (instcombine, analysis.misc,
  loop units, pipeline-O2, perf-corpus, ...)
- **What happened:**
  - The full jai ratchet takes 8-25 minutes depending on load; main moved (often with jai source changes from
    other agents) during almost every run, so each push needed rebase + another full run, up to three rounds.
    Once I pushed right after a rebase that pulled in harness/tests/passing.txt changes without rerunning; the
    ratchet-only run right afterwards passed, but it broke the rule.
  - A large test import landed meanwhile and turned 264 jai roundtrips red (L0.print-imported dropped from done
    to 9632/9896); the fix was just rerunning gen_intrinsics.py plus a few x86 upgrades, but nobody owned it.
  - `check --no-build` after my own `build.sh` reported results of an older binary once (the vscale_load
    failure that was already fixed), which cost a confused round.
  - The two hardest "nondeterminism" items (oggenc, sqlite3) turned out not to be nondeterministic at all: one is
    provably order-independent (mergeConditionalStores never changes IR with 2+ common addresses), the other is
    order-independent in practice and can be checked by permutation. linpack-pc was a plain argument-order bug
    (`f(scev(b), scev(a))`), found only by tracing createSCEV in the release `opt` with gdb.
- **Time or effort lost:** ~1.5 h of waiting on re-runs after main moved; ~30 min on the stale `--no-build`
  result; the linpack investigation would have been minutes with a documented gdb recipe.
- **What would have helped:** a ratchet mode that only reruns tests affected by the commits pulled in by the
  rebase (or a per-file dependency hint), or a merge queue that serializes pushes per implementation; an owner for
  "regenerate generated tables after an import"; a note in docs/testing.md that the oracle `opt` has symbols and
  can be traced with gdb (`Value::getName` callable), which makes "LLVM's query order" questions answerable.
- **What you did instead:** looped rebase -> full check -> push until main stood still; wrote the gdb recipe into
  knowledge/llvm/scalar-evolution.md and kept a `-jai-trace-create-scev` flag for the jai side.
