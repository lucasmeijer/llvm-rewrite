# Multi-pass pipeline sweeps take 1.5 h a round, and the split-adaptor SCEV gap forced a loud-vs-coverage trade-off

- **Date / implementation / unit:** 2026-11-12 / goose / pipeline sweeps (resumed after a model-outage crash)
- **What happened:** the resumed task had no record of the crashed agent's sweep numbers except its raw journal, so
  the "before" column had to be scraped out of main.jsonl tool output. A full run of `tools/pipeline_sweeps.sh`
  (14 pipelines x corpus/split/perf/perf-fn, with and without debugify) takes about 1.5 h, and goose builds take
  5 min, so each fix-and-verify round was long. While a sweep runs, `bin/opt` must not be rebuilt (I built into /tmp
  and copied it in between runs). The split-adaptor sweeps found that LLVM reuses each function's ScalarEvolution
  across `function(...)` adaptors; goose has one instance. The honest fix (fail loudly when that could matter)
  turns ~400-1000 previously identical split-sweep files per loop pipeline into loud failures.
- **Time or effort lost:** ~1 h reconstructing earlier results; ~4 h wall clock waiting on sweeps.
- **What would have helped:** agents writing intermediate sweep tables to a file in the worktree (or NOTES.md) as
  they go, so a resume doesn't need the journal; a harness option to run several sweeps in parallel against one
  pinned binary copy; a decision from the human on whether split-adaptor pipelines matter enough to port
  per-function SCEV/LoopInfo caches.
- **What you did instead:** loud failure in `scev_get` (documented in DESIGN §8.7 and NOTES), results table in NOTES.
