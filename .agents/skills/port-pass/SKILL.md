---
name: port-pass
description: Port an LLVM optimization pass (or analysis) into your implementation so its output matches opt exactly. Use when working on an L1/L2 roadmap unit.
---

# Porting a pass

## Prepare

1. Find the unit in `docs/roadmap.md`. Its exit selector is usually
   `tests/imported/llvm/Transforms/<Pass>/*::opt`. If the directory isn't imported yet, run
   `./harness/run import-llvm Transforms/<Pass>`, check `--impl llvm` on it, commit the import on its own first.
   Read the generated `SKIPPED.md` to see what was left out.
2. Read `knowledge/llvm/` for the pass and its analyses, and your implementation's `DESIGN.md`.
3. Read the source: `/opt/llvm-project-23.1.5/llvm/lib/Transforms/<…>/<Pass>.cpp`, its header in `llvm/include`, and
   the analyses it queries. Note every `cl::opt` the pass reads (its defaults matter), and every place where
   iteration order shows up in the output: worklists, use-list walks, block order, map iteration.
4. List the analyses it needs (DominatorTree, LoopInfo, AA, SCEV, TTI, TLI…). Missing analyses are part of this
   unit. Port them faithfully as well. Target queries come from the x86-64 TTI and TLI for
   `x86_64-unknown-linux-gnu`.

## Implement

- Register the pass under LLVM's exact pass name and parameter syntax, so `-passes=` strings work unchanged.
- Port the transforms in the source's own order. Start with the smallest test files: `wc -l` the selected tests and
  work up.
- Iterate: `./harness/run check --impl <lang> 'tests/imported/llvm/Transforms/<Pass>/*' -v`, then
  `./harness/run show <test> --impl <lang>` and the files in `.harness-out/`.
- If a test exposes an unrelated missing feature (an instruction you don't parse yet, another pass in its RUN line),
  either implement it or move on. Don't fake it.

## Exactness traps

- Output order: new instructions are inserted at specific points. Names come from `IRBuilder` name arguments
  (`%x.neg`, `.fr`, `%spec.select`) and get uniquified with numeric suffixes.
- Metadata and attributes are preserved, dropped or merged by specific helpers (`combineMetadata`,
  `copyMetadata`, `dropUnknownNonDebugMetadata`). Follow them exactly.
- Flags (`nsw`, `nuw`, `exact`, `disjoint`, `nneg`, fast-math flags) are often recomputed. Check when they're kept.
- Pipelines inside `-passes=` (`function(…)`, `loop(…)`, `cgscc(…)`) need LLVM's adaptor semantics, including when
  analyses are invalidated.
- When stuck on one test, run `./harness/run bisect` (for multi-pass RUN lines) or reduce the input by hand. Write
  down what you learn in `knowledge/llvm/<pass>.md`.

## Finish

Sweep the pass over the whole corpus: `./harness/run sweep --impl <lang> --passes '<pass>'` (with `--analysis` for
an analysis printer; see "Sweeps" in `docs/testing.md`). This is expected before a pass unit is finished: the exit
tests miss many bugs that a sweep over ~7800 files finds. Every `differs`/`bad-ir` file is a silent wrong output:
fix it, or, if it comes from someone else's code, make it fail loudly or write it down in `NOTES.md`. Note the sweep
result (identical / failed counts, main failure groups) in `NOTES.md`. While many files still fail loudly on some
unported construct, add `--per-function`: it splits every file into one module per function, so the functions you do
support get compared too (often several times as many comparisons; see "--per-function" in `docs/testing.md`). Also sweep the pipelines from your unit's RUN
lines that combine your pass with others, if the others already work. If your pass has target-specific or
flag-controlled code (TTI hooks, X86 intrinsic folds, cost models, a pass `cl::opt`), also sweep with
`--with-test-flags`: a plain sweep passes no `-mtriple`/`-mattr`/`-mcpu`, so most modules have no target and that
code never runs; `--with-test-flags` adds each file's own RUN-line flags (see "--with-test-flags" in
`docs/testing.md`).

Look at compile time: `./harness/run perf --impl <lang> 'tests/perf/scaling/*'` (and `tests/perf/compile/*` once
`-O2` works). If a shape that runs your pass scales worse than LLVM (exponent k clearly higher), you probably used a
simpler data structure than LLVM does; fix it or note it in `NOTES.md`. If no shape exercises your pass, add one to
`harness/lrh/perfgen.py` and rerun `gen-perf`.


Follow "Working on a unit" in `AGENTS.md`: unit COMPLETE, full ratchet with `--update`, knowledge notes, challenge
report if needed, rebase, recheck, push.
