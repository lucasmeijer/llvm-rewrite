# Single-pass sweeps miss state that leaks between passes; two-pass sweeps found real bugs

- **Date / implementation / unit:** 2026-11-14 / goose / L1.licm (+ MemorySSAUpdater, LoopRotate)
- **What happened:** `sweep --passes licm` and `--per-function` were at 0 differs early. Only pipelines that put a
  printer or another pass *after* LICM showed bugs that no single-pass sweep can see: (1) `loop-mssa(licm),
  print<scalar-evolution>` differed because ScalarEvolution's pointer range asked ValueTracking with whatever
  context instruction the previous pass had left in a global (`kb_cxt`); (2) `loop-mssa(licm),print<memoryssa>`
  differed in attribute-group numbers because the printer's module slot numbering was cached across passes and a
  pass had added a declaration; (3) MemorySSA was silently rebuilt instead of preserved after `early-cse<memssa>`
  and `lcssa`, because the implementation treated AAManager as invalidated by every pass (it is "preserved when
  stateless"). None of these are in the LICM code, and none show up in the unit's exit tests.
- **Time or effort lost:** ~1 hour finding (1) and (2); (3) was found by reading MemorySSAAnalysis::invalidate.
- **What would have helped:** a documented "pipeline sweep matrix" for a pass unit: the pass alone, the pass
  followed by the printers of the analyses it preserves (`print<memoryssa>`, `print<scalar-evolution>`), and the
  pass after the passes that hand it a preserved analysis (`early-cse<memssa>,loop-mssa(licm)`). The analysis-mode
  sweep makes these cheap (seconds once LLVM's side is cached).
- **What you did instead:** ran those combinations by hand (`sweep --analysis --passes 'loop-mssa(licm),print<...>'`,
  `-verify-memoryssa` on, whole file and per function) and fixed the shared code. Also: another agent changed the
  meaning of `inst_insert_before` (now adopts debug records, `_head` variants don't) while this work was in flight;
  they adapted my already-pushed LICM code, but a call site written afterwards would have silently kept the old
  meaning. Announcing such semantic flips to the agents working in the same impl would have avoided the risk.
