# Whole-pipeline perf tests in the ratchet are recorded by whoever happens to finish them under 120 s

- **Date / implementation / unit:** 2026-11-12 / jai / L2.pipeline-O2 (resumed after a model outage)
- **What happened:** porting the default pipelines made `-O2` run end to end on tests/perf/scaling. Whichever agent
  ran `check --update` while the machine was quiet recorded `diamonds/n8000::opt` and `calls/n8000::opt` in
  passing.txt (my resumed --update did one, a vectorizer agent's the other). Both take 100-130 s on the x64 debug
  build (LLVM: 1.6 s and 4.8 s), so under load they "regressed" in everybody's ratchet and blocked unrelated
  pushes; three agents spent time profiling the same two files. diamonds was a real quadratic in SLP (fixed by the
  SLP agent); calls is the inliner's cost analysis plus instcombine known-bits queries, the same amount of work
  LLVM does (46k CallAnalyzer runs on n500 in both), i.e. the debug backend's per-call overhead.
- **Time or effort lost:** ~2 hours across three agents (profiling, messages, reruns of --update that hit the
  timeout).
- **What would have helped:** a rule that a test whose runtime is within 2x of the tool timeout does not get
  recorded by --update (or is recorded as "slow" and checked with the optimized build). The harness change to CPU
  time plus one retry (c6e862b) already removed most of the load dependence.
- **What you did instead:** callgrind on n500/n2000 (no single hotspot), inlined the hottest small IR/pattern
  helpers, made `tli_are_inline_compatible` word-wise and the libfunc name lookup hashed: -18% instructions;
  calls/n8000 now ~100 s CPU. Further gains need the optimized build for checks or broad work on known-bits.
- **Also:** in Jai, `is_constant(x)` is a compiler builtin (compile-time constness) and silently compiled where I
  meant isa<Constant> (`is_const` in this codebase); worth a line in DESIGN.md's naming conventions. And two agents
  added the same SCEVParameterRewriter kind at the same time (rebase conflict in scev_create.jai); a short "who
  owns SCEV" note would avoid that.
