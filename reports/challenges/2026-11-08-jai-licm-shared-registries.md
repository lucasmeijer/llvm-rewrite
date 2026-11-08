# Shared registries in passes.jai conflict on every parallel rebase; unit exit set mostly gated on other passes

- **Date / implementation / unit:** 2026-11-08 / jai / L1.licm (+ MemorySSAUpdater for L1.analysis.memoryssa)
- **What happened:** `cl_opts()` in impl/jai/src/passes.jai builds one array whose size and offsets are a hand-written
  sum (`14 + AA_CL_OPT_COUNT + ... + SCFG_CL_OPT_COUNT`). Two agents each adding a group of `cl::opt`s (debugify and
  LICM) edit the same two lines, so every rebase conflicts there; resolving it means re-deriving the offsets by hand.
  Separately, 22 of the 134 L1.licm exit tests can't pass without other passes (gvn, loop-deletion, loop-unroll,
  simple-loop-unswitch, reassociate, loop-simplifycfg, loop-sink which needs BlockFrequencyInfo, early-cse<memssa>,
  make-guards-explicit), and 2 of the 7 remaining L1.analysis.memoryssa tests need simple-loop-unswitch, so neither
  unit can reach COMPLETE from its own work.
- **Time or effort lost:** ~10 minutes on the conflict; some time triaging which failures are in scope.
- **What would have helped:** a registration pattern without shared arithmetic (e.g. each file appending its options
  to a list), and roadmap exit selectors (or a documented "blocked by" list) that separate tests gated on unported
  passes from the unit's own tests.
- **What you did instead:** merged the offsets by hand; listed the out-of-scope failures in impl/jai/NOTES.md.
- Also worth knowing: Jai only type-checks procedures that are reachable, so a freshly written file "compiles" until
  the first caller is wired in — errors show up late, one at a time. Wiring the entry point early saves a round trip.
