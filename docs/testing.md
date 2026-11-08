# Testing

The harness compares an implementation against LLVM 23.1.5. All of it is `./harness/run <command>`
(source in `harness/lrh/`, Python 3, standard library only).

## Test files and checks

A test is any `.ll` file under `tests/`. Directives in its leading comment block decide which checks it has:

```llvm
; @opt: -passes=instcombine     IR->IR check (repeatable for imported tests: all must match)
; @analysis: -passes='print<domtree>'               analysis-printer check (repeatable: all must match)
; @analysis-unordered: -passes='print<demanded-bits>'   the same, comparing lines as a sorted multiset
; @llc: -O0                     enables ::isel-ir and ::run
; @driver: tests/function/src/abi/x.driver.c    C file linked in for ::run (function tests)
; @source: tests/e2e/src/arith/x.c              the C the IR came from (informational)
; @origin / @generated          provenance (informational)
```

A test ID is `<repo-relative path>::<check>`, e.g. `tests/e2e/O0/calls/varargs.ll::run`.

| Check | Every file? | What must match |
| --- | --- | --- |
| `roundtrip` | yes | `opt -S in.ll` with no passes: our printed text is **byte-identical** to LLVM's. Tests the parser and printer. |
| `opt` | if `@opt` | `opt <args> -S`: both outputs canonicalized via `llvm-as \| llvm-dis` (so value numbering etc. can't cause false failures), then identical. Our output must also pass LLVM's verifier. |
| `analysis` | if `@analysis` | `opt <args> -disable-output in.ll`: exit status 0, and stdout and stderr **byte-identical** to LLVM's (see below). |
| `isel-ir` | if `@llc` | The IR that reaches instruction selection, `llc <args> -stop-before=x86-isel`. Input is LLVM's opt output, so this is isolated from `opt`. Canonicalized and identical. |
| `run` | if `@llc` | Full pipeline with *our* tools (our opt if `@opt`, then our llc), linked by clang with `-no-pie`, executed: stdout and exit code identical to the LLVM-built program. |

Outcomes: `pass`, `fail`, or `invalid`. `invalid` means LLVM itself fails on the test, so the test is broken.

### Analysis printers (`::analysis`)

An analysis is checked through LLVM's printer pass for it: `print<domtree>`, `print<postdomtree>`, `print<loops>`,
`print<cycles>`, `print<scalar-evolution>`, `print<memoryssa>`, `print<demanded-bits>`, `print<lazy-value-info>`,
`print<branch-prob>`, `print<block-freq>`, `print<access-info>`, `print<cost-model>`, `aa-eval`, … Printers write to
stderr. The `<args>` of an `@analysis` line are ordinary opt arguments and may contain transforms before the printer
(`-passes='require<domtree>,break-crit-edges,print<domtree>'`) and the flags that control what a printer prints
(`-aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info`). The harness appends `-disable-output`, so no
IR is written and the transforms in the line are checked only through what the printers show.

Canonicalization: none. Printer output shows names the way the IR printer does (`%5`, `%entry`), so it already depends
on the implementation getting the IR exactly right. The one exception is `@analysis-unordered`, for printers that
iterate a map keyed by pointers (`print<demanded-bits>`; LLVM's own tests use `CHECK-DAG` for them): both outputs are
compared after sorting their lines. Per-function headers are sorted along with everything else there, so keep such
tests to lines that are unique on their own.

Determinism: LLVM's output is computed twice (once, then cached); if the runs differ, the test is `invalid`, with a
hint to use `@analysis-unordered` when only the order changed. Two runs can agree by chance, so when you write an
analysis test for a new printer, run LLVM's opt on it a few times yourself. `import-llvm` runs each printer line six
times and picks `@analysis`, `@analysis-unordered` or (when the content itself changes, e.g. printed addresses as in
`print<alias-sets>` or `print-callgraph`) skips it.

## Corpus layout

```
tests/roundtrip/<area>/*.ll          hand-written IR for parser/printer work (roundtrip only)
tests/e2e/src/<area>/*.c             C programs (source of truth; not tests themselves)
tests/e2e/O0/<area>/*.ll             clang -O0 -Xclang -disable-O0-optnone; @llc -O0
tests/e2e/O2/<area>/*.ll             clang -O2;                              @llc -O2
tests/e2e/pipeline/<area>/*.ll       clang -O2 -Xclang -disable-llvm-passes; @opt -O2, @llc -O2
tests/function/src/<area>/x.c + x.driver.c    same three configurations, with @driver
tests/analysis/<printer>/*.ll        hand-written IR for analysis printers; @analysis
tests/imported/llvm/Transforms/<Pass>/*.ll    LLVM's regression tests, original paths kept; SKIPPED.md per dir
tests/imported/llvm/Analysis/<Dir>/*.ll       LLVM's analysis tests: @analysis for printer RUN lines, @opt for the rest
tests/perf/compile/<program>.ll      whole llvm-test-suite programs, one linked module each; @opt -O2, @perf
tests/perf/scaling/<shape>/n<N>.ll   synthetic IR of one shape at three sizes; @opt per pass, @perf, @perf-size
```

The `.ll` files in `O0/`, `O2/`, `pipeline/`, `imported/` and `perf/` are generated (`perf/` by `gen-perf`). Regenerate them, never edit them by hand.

## Commands

```bash
./harness/run check --impl rust                          # everything; enforces the ratchet
./harness/run check --impl rust --unit L1.sroa           # a unit's exit tests; reports COMPLETE or not
./harness/run check --impl rust 'tests/e2e/O0/calls/*'   # by glob (path or test ID; * matches /)
./harness/run check --impl rust --ratchet-only           # only tests already in passing.txt (fast)
./harness/run check --impl rust --update                 # record newly passing tests in passing.txt
./harness/run check --impl rust -v                       # print failure details
./harness/run show tests/e2e/O0/calls/varargs.ll --impl rust     # one file (or one ::check), full details
./harness/run bisect tests/e2e/pipeline/misc/sieve.ll --impl rust  # first pass where an @opt pipeline diverges
./harness/run status                                     # unit x implementation scoreboard (runs nothing)
./harness/run sweep --impl rust --passes sroa            # one pipeline over the whole corpus, vs LLVM (see Sweeps)
./harness/run check --impl llvm                          # self-test: LLVM against itself; finds invalid tests

./harness/run from-c tests/e2e/src/<area>/x.c            # C -> three .ll tests, with UB validation
./harness/run import-llvm Transforms/LICM                # import LLVM's tests for a pass
./harness/run import-llvm Analysis/ScalarEvolution       # or for an analysis (printer RUN lines become @analysis)
./harness/run import-test-suite SingleSource/UnitTests   # import llvm-test-suite programs

./harness/run perf --impl rust                           # compile-time report vs LLVM, ~25 s (see Performance)
./harness/run perf --impl rust --instr                   # plus exact instruction counts (valgrind; slow, cached)
./harness/run perf --impl rust,zig 'tests/perf/scaling/allocas/*'   # several impls side by side, some benchmarks
./harness/run gen-perf                                   # regenerate tests/perf
```

`check` runs `impl/<lang>/build.sh` first (skip with `--no-build`). For every failing check it writes artifacts to
`.harness-out/<impl>/<test path>/<check>/`: `message.txt`, `expected.ll` and `actual.ll` (canonicalized), `diff.txt`,
`input.ll`, `out.s`, `expected.stdout` and `actual.stdout`, `stderr.txt`; for `::analysis`, `args.txt`,
`expected.stderr`, `actual.stderr`, `diff.stderr.txt` (and the same for stdout if it differs).

`from-c` rejects programs that are nondeterministic, time out (10 s), or behave differently between clang `-O0`,
`-O2` and `-O1 -fsanitize=address,undefined`, because that indicates UB and the test would be meaningless.

## Sweeps (one pipeline over the whole corpus; report only)

A unit's exit tests are a few hundred files written for that pass. Running the pass over *every* file the
implementation can parse and print and comparing with LLVM finds many bugs they miss (wrong results on IR the pass's
own tests never contain, shared ValueTracking/printer bugs). `sweep` does that:

```bash
./harness/run sweep --impl rust --passes sroa                          # IR mode: like ::opt
./harness/run sweep --impl rust --passes 'function(loop-mssa(licm))' 'tests/imported/*'   # only some files
./harness/run sweep --impl rust --passes 'print<scalar-evolution>' --analysis           # like ::analysis
./harness/run sweep --impl rust --passes 'print<demanded-bits>' --unordered             # like @analysis-unordered
./harness/run sweep --impl rust --passes aa-eval --analysis --extra='-aa-pipeline=basic-aa -print-all-alias-modref-info'
./harness/run sweep --impl rust --extra=-O2                             # no --passes: any opt arguments
./harness/run sweep --impl llvm --passes sroa                          # self-test: everything identical
./harness/run sweep --impl rust --passes instcombine --per-function    # one module per defined function (below)
```

Files: by default every file whose `::roundtrip` is in `impl/<lang>/passing.txt` (for `--impl llvm`, and with
`--all-files`, every corpus file), except the big `tests/perf/` files; globs restrict the set (and can select
`tests/perf/` files). For each file it runs `opt <args> -S` (IR mode) or `opt <args> -disable-output`
(`--analysis`) with LLVM (cached in the oracle cache) and with the implementation, in parallel (`-j`), and compares
exactly like the `::opt` check (both canonicalized through `llvm-as | llvm-dis`, ours must pass the verifier) or the
`::analysis` check (exit status, stdout and stderr byte-identical; sorted lines with `--unordered`). Outcomes:

| Outcome | Meaning |
| --- | --- |
| `identical` | same output |
| `differs` | **silent mismatch**: our opt exited 0 with different output. The worst kind; listed first, fix these first |
| `bad-ir` | also silent: our opt exited 0 but its output fails `llvm-as` (parser or verifier) |
| `failed` | loud: nonzero exit, crash or timeout (`--timeout`, default 60 s). Grouped by the first error line (file name and line numbers taken out), most frequent first |
| `llvm-failed` | LLVM's opt itself fails on the file with these arguments (or, in analysis mode, prints different output on two runs): skipped |

Artifacts go to `.harness-out/sweep/<impl>/<args>/` (replaced on every run of the same arguments): `results.tsv`
(status, file, error group for every file), `summary.json` (counts, silent mismatches, failure groups with all their
files), and `<test path>/` for every non-identical file with `message.txt` and the same files `check` writes
(`expected.ll`, `actual.ll`, `diff.txt`, `stderr.txt`, `expected.stderr`, …). `-v` prints the diff of each silent
mismatch. `sweep` never touches `passing.txt` and exits 0; it is a report. A full sweep of ~7800 files takes well
under a minute on 16 cores once LLVM's outputs are cached. Expected before finishing a pass unit (see the `port-pass`
skill): no silent mismatches, or ones that are understood and written down in `NOTES.md`.

### `--per-function`

A file is one comparison, and an implementation stops at the first construct it hasn't ported, so a whole-file sweep
compares only the files whose *every* function is supported. `--per-function` cuts each selected file into one module
per defined function and compares every piece on its own, so the supported functions of a file still get compared
(InstCombine on the corpus: ~7700 files become ~70000 functions). Everything else is as above (same file selection,
IR or `--analysis` mode, outcomes, failure groups), counted per function:

- **Splitting**: `llvm-extract --keep-const-init --func=<name>` on the file. The piece keeps the function, declarations
  of what it calls (other functions become declarations; calls between functions are fine), the globals it
  references (initializers only of constants), the metadata it uses, attributes, datalayout and triple. Unnamed
  functions (`@0`) cannot be named for llvm-extract, so for those the file first goes through
  `opt -passes=name-anon-globals` (the piece then calls them `@anon.<hash>.<n>`).
- **Each piece is a new input, not a slice of the old output.** llvm-extract changes linkage (internal/private become
  external `hidden`, linkonce becomes weak), drops module inline asm, unreferenced globals and non-constant
  initializers. LLVM and the implementation both run on the same piece, so the comparison stays exact, but the
  result is not the function's part of the whole-file output: anything that depends on other function bodies or on
  linkage (inlining, IPSCCP, globalopt, function-attrs of callers, dead-function removal) sees a different module.
  For module and CGSCC passes a per-function sweep is still a valid comparison, just on less interesting inputs.
- The piece is run as `input.ll` in a temporary directory with the cwd there, so outputs don't contain paths.
- `llvm-failed` also covers pieces llvm-extract can't make valid (aliases whose type no longer fits, `llvm.localrecover`
  of a function that became a declaration; a handful in the corpus) and files LLVM can't parse.
- Splitting and LLVM's results on every piece are cached in the oracle cache. The first InstCombine sweep over the
  corpus takes ~10 minutes on 16 cores; after that ~1 minute plus the implementation's own time (worker processes,
  `-j`).

Artifacts go to `.harness-out/sweep/<impl>/per-function_<args>/`: `results.tsv` has four columns (status, file,
function as `@name`, error group), `summary.json` lists silent mismatches and failure groups as `<file> @<function>`,
and every non-identical function has `<test path>/<n>-<function>/` (`n` = its position among the file's
definitions) with `input.ll` (the piece; reproduce with `opt <args> -S input.ll` in that directory), `message.txt`
and the usual `expected.ll`, `actual.ll`, `diff.txt`, `stderr.txt`. A whole-file and a per-function sweep of the same
arguments don't overwrite each other.

## Performance (compile time; report only)

`./harness/run perf --impl <lang>[,<lang>…]` measures how fast our tools are compared with LLVM's. It never fails and
doesn't touch `passing.txt`; correctness is still `check`'s job. Every `; @perf: <tool> <args>` line in `tests/perf/`
is one benchmark: `opt` alone is parse + print, `opt -O2` or `opt -passes=…` times a pipeline, `llc -O2` times the
backend on LLVM's `opt` output for the file's first `@opt`.

| Column | Meaning |
| --- | --- |
| `llvm cpu s` | LLVM's CPU time (user + system), the minimum over the runs |
| `cpu` | our CPU time ÷ LLVM's |
| `rss` | our peak memory ÷ LLVM's |
| `instr` | only with `--instr`: our executed instructions ÷ LLVM's (see below) |
| `Δprev` | change in our ratio to LLVM since the previous `perf` run of this implementation (from the history); `=` within the noise (10% for cpu, 0.05% for instr) |
| `ok` | whether we pass the correctness check for that output (`::roundtrip` or `::opt`, from `passing.txt`); `-` if none |

Below the table: the geometric mean of the ratios, and for `tests/perf/scaling/` a fitted exponent k (cost ~ n^k,
over three sizes, after subtracting the cost of the same command on an empty module). A k well above LLVM's means an
algorithm with worse complexity than LLVM's, even when the absolute numbers are still small. `(k)` in parentheses
means there was too little work above process startup to measure. LLVM's own k isn't always 1 (e.g. `-O2` on many
sequential loops is about 2).

**Speed and noise.** Runs go in parallel on half the cores (`-j`), LLVM and implementations in the same batch, biggest
first; each benchmark repeats until it has about a second of samples (at most 15 runs, `--reps N` to fix it), and
the minimum counts. The whole corpus takes about 25 s (6 s for `tests/perf/compile/*` with stub implementations).
Measured with LLVM against itself: half the rows are within 3% of 1.00x, 90% within 10%, the worst about 20%. So
read single-row differences under ~15% as noise; the geomean is good to a few percent.

**Exact numbers: `--instr`.** Adds instructions executed, counted with `valgrind --tool=cachegrind` (the VM exposes
no hardware counters). Repeatable to the instruction, so it shows 1% differences, but valgrind is about 40 times
slower: a full run with a freshly built implementation takes several minutes. Counts are cached by (binary, args,
input), so LLVM's are paid once and an unchanged binary is free. With `--instr`, scaling exponents and `Δprev` use
instruction counts.

Results: `.harness-out/perf/<impl>.json`; every run is appended to `/persistent/llvm-rewrite/perf-history/<impl>.jsonl`
(with commit and dirty flag) unless `--no-history`.

## The CLI contract for our tools

`impl/<lang>/build.sh` must produce `impl/<lang>/bin/{opt,llc,llvm-link}`. The harness invokes them exactly like this
(the same command lines it uses for LLVM's tools):

```
opt <args> -S <in.ll> -o <out.ll>               # <args> empty = parse and print only (roundtrip)
llc <args> -stop-before=x86-isel <in.ll> -o <out>   # write the module as textual IR (LLVM writes MIR; either is accepted)
llc <args> <in.ll> -o <out.s>                   # AT&T assembly for x86_64-unknown-linux-gnu
opt <args> -opt-bisect-limit=<N> -S <in> -o <out>   # used by `bisect`; count passes exactly like LLVM
opt <args> -disable-output <in.ll>              # ::analysis: printers write to stderr; no IR is written
```

`<args>` come from `@opt`, `@analysis` and `@llc` lines and from LLVM's own RUN lines: `-passes=<pipeline>`, `-O0`…`-O3`,
`-mtriple=…`, `-mattr=…`, and occasionally pass-specific `cl::opt` flags. An implementation that doesn't support a
flag must exit nonzero with a clear message. The working directory is the repository root, and `<in.ll>` is a
repo-relative path (it shows up in `; ModuleID = '…'`).
