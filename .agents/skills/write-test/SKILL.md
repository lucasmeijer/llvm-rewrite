---
name: write-test
description: Add a new test to the shared corpus (C program, function test with a C driver, hand-written IR, or imported LLVM tests) and land it as pending. Use when you need a test that targets a specific behaviour, edge case or roadmap unit.
---

# Writing a test

A new test isn't in anyone's `passing.txt`, so adding one never breaks the ratchet. Add tests freely, and make
each one target exactly one thing.

## Pick the kind

| You want to test… | Write |
| --- | --- |
| A program's behaviour through the whole backend | `tests/e2e/src/<area>/<name>.c` (has `main`, prints results, deterministic) |
| A function's ABI/semantics, many inputs, called from clang-compiled code | `tests/function/src/<area>/<name>.c` + `<name>.driver.c` |
| Parser/printer fidelity on specific IR syntax | `tests/roundtrip/<area>/<name>.ll` (hand-written IR, no directives needed) |
| One pass on a specific IR edge case | `tests/pass/<pass>/<name>.ll` with `; @opt: -passes=<pass>` |
| The rest of LLVM's tests for a pass | `./harness/run import-llvm Transforms/<Pass>` |
| One analysis, through its printer | `tests/analysis/<printer>/<name>.ll` with `; @analysis: -passes='print<…>'` |
| LLVM's tests for an analysis | `./harness/run import-llvm Analysis/<Dir>` |

`<area>` should match a roadmap unit's selector (e.g. `calls`, `structs`, `float`), or add a unit/selector to
`docs/roadmap.md` that covers it.

## C tests

1. Write the `.c` file. Rules: deterministic output (no time, addresses, uninitialised memory, `rand` without a fixed
   seed), no stdin or arguments, runs in well under 10 s, no undefined behaviour. Print what you compute; a test that
   only returns 0 checks very little.
2. `./harness/run from-c tests/e2e/src/<area>/<name>.c` generates `tests/e2e/{O0,O2,pipeline}/<area>/<name>.ll`. It
   rejects UB (outputs differ between -O0, -O2 and the sanitizer build), nondeterminism and timeouts. Fix the C rather
   than forcing it through. After editing the C, rerun with `--force`.
3. For function tests the driver declares the functions itself (no shared header) and prints every result. Exercise
   boundary values, but guard the driver against UB too (no `INT_MIN / -1`, no oversized shifts).

## Hand-written IR tests

- The file must be valid for `opt` 23.1.5. Check with `./harness/run check --impl llvm <path>`: it must pass, not
  be `invalid`.
- For pass tests, write the smallest input that shows the behaviour, and say in a leading comment what it targets.
  Multiple `; @opt:` lines are allowed. All must match.
- For analysis tests, run LLVM's opt on the file a few times (`opt <args> -disable-output f.ll`): if the line order
  changes between runs, use `@analysis-unordered`; if the content changes (addresses), the printer can't be tested.
  A new `tests/analysis/<printer>/` directory needs a selector in the matching `L1.analysis.*` unit.
- When you add the first file in `tests/pass/<pass>/`, add `tests/pass/<pass>/*::opt` to the exit line of that pass's
  unit in `docs/roadmap.md`.

## Land it

- `./harness/run check --impl llvm <new test paths>`: everything passes.
- Commit the C sources and the generated `.ll` files together: `tests: <area>: <what it covers>`.
- If you wrote the test to reproduce a bug in your implementation, the fix and the test can go in the same commit.
