# L2.pipeline-O2 is mostly gated by other units' loud gaps; a "vectorizers off" comparison and an args-bisect tool made it tractable

- **Date / implementation / unit:** 2026-11-13 / goose / L2.pipeline-O2 (also L2.phase-ordering, L2.perf-corpus)
- **What happened:** the pass-manager port itself (PassBuilderPipelines.cpp) took a fraction of the time and matched
  `-print-pipeline-passes` on the first try. The rest went into ~30 loud "not ported yet" stops and ~8 real bugs in
  *other* units' code (inliner PHI trimming order, GlobalsAA noipa, BlockAddress lifetime, an inliner off-by-one,
  ConstantFPRange for x86_fp80, InstCombine visitors), each reached only through the full pipeline. The unit's exit
  selector can't tell "blocked by the vectorizers, owned by someone else" from "blocked by something I should fix":
  every remaining failure is just "opt exited with 1".
- **Time or effort lost:** an hour before finding a clean way to separate the two; `harness/run bisect` only bisects a
  test's own @opt line, so bisecting `-O2 -vectorize-slp=false ...` or a perf file needed a separate tool; each
  bisect of SPASS.ll (325k bisect points) takes ~4 minutes.
- **What would have helped:** (1) a documented "vectorizers off" variant of the pipeline-O2 comparison (sweep
  `--extra='-O2 -vectorize-slp=false -vectorize-loops=false -interleave-loops=false'` over tests/e2e/pipeline,
  tests/function/pipeline and tests/perf): it showed at once that 241/241 and 27/27 match when the vectorizers are
  off, i.e. the unit is exactly "vectorizers + the gaps the sweep lists". (2) `harness/run bisect --extra ARGS FILE`
  for arbitrary arguments. (3) Shared-code bugs found this way are in files owned by finished units (inliner,
  GlobalsAA): a note in the roadmap that pipeline units are expected to fix shared code would have removed the
  hesitation about touching them.
- **What you did instead:** `impl/goose/tools/obisect.py FILE -- ARGS` (binary search on -opt-bisect-limit, writes the
  failing pass's input to /tmp/obisect/), then reran the single pass standalone on that input; every divergence
  reproduced standalone, so it could be fixed in the pass with a small reproducer. Both the vectorizers-off sweep and
  obisect.py are documented in impl/goose/NOTES.md "Default pipelines"; the bisect tool would be worth moving into
  the harness for all implementations.
