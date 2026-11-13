# Testing

The harness compares an implementation against LLVM 23.1.5. All of it is `./harness/run <command>`
(source in `harness/lrh/`, Python 3, standard library only).

## Test files and checks

A test is any `.ll` file under `tests/` (or a directory with a `test.lto` manifest: multi-module tests, below). Directives in its leading comment block decide which checks it has:

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
| `link` | LTO tests | See "Multi-module (LTO) tests" below. |

Outcomes: `pass`, `fail`, or `invalid`. `invalid` means LLVM itself fails on the test, so the test is broken.

### Multi-module (LTO) tests (`::link`, and `::opt` / `::run` on the linked program)

Whole-program optimization is LLVM's full LTO: every translation unit goes through the pre-link pipeline, the
modules are linked, and the post-link pipeline runs on the result (docs/plan.md, decision 6). A multi-module test is a
**directory** containing a manifest `test.lto` plus its modules; the test ID's path is the directory
(`tests/lto/split/sieve::opt`). The manifest uses the same directive syntax:

```llvm
; @modules: main.ll sieve.ll        link order (required); paths relative to the directory (Inputs/x.ll is fine)
; @link: -only-needed              extra llvm-link arguments (optional)
; @opt: -passes='internalize,lto<O2>' -internalize-public-api-list=main     the post-link pipeline (repeatable)
; @llc: -O2                         enables ::run
; @source / @origin / @generated    provenance (informational)
```

The modules are ordinary test files as well: each has its own `::roundtrip`, and a C-generated module carries the
pre-link pipeline as its `@opt` line (`-passes='lto-pre-link<O2>'`), so the pre-link pipeline is an ordinary `::opt`
check of that file.

| Check | When | What must match |
| --- | --- | --- |
| `link` | always | `llvm-link <@link> -S <modules>`, run in a scratch directory on relative names. Inputs: LLVM's `opt` output of each module's first `@opt` (its pre-link pipeline), or the module itself if it has none. Canonicalized, identical. |
| `opt` | if `@opt` | `opt <args> -S` on **LLVM's** linked module (isolated from `::link`, like `::isel-ir`). Canonicalized, identical. |
| `run` | if `@llc` | Everything with our tools: pre-link `opt` per module, our `llvm-link`, our `opt <@opt>`, our `llc`, then clang links and runs. Same stdout and exit code as the LLVM-built program. |

Why the post-link line is `internalize,lto<O2>` with `-internalize-public-api-list=main`: a linker doing full LTO for
an executable tells LLVM which symbols are visible outside the IR (only `main` here) and internalizes the rest
(lib/LTO/LTO.cpp, `runRegularLTO`) before it runs `lto<O2>`; `opt -passes=lto<O2>` alone keeps every external
symbol, so cross-module inlining could never delete the callee. Clang's `-O2 -flto` is
`clang -O2 -flto -Xclang -disable-llvm-passes` followed by `lto-pre-link<O2>` (verified on the corpus: identical
IR except two module flags, `ThinLTO` and `EnableSplitLTOUnit`, and the module summary clang appends when writing
LTO output; the summary is ignored by full LTO and our parser has no summary support).

Where they come from: `tests/lto/<area>/<name>/` from C (`./harness/run from-c tests/lto/src/<area>/<name>/`: a
directory of at least two `.c` translation units plus headers, optional `cflags` file with extra clang flags such as
`-g`; validated like every C test, compiled all together), `tests/lto/link/*` hand-written IR for linker features,
and `tests/imported/llvm/Linker/<test>[.runN]/` from LLVM's own linker tests (`./harness/run import-llvm Linker`: one
directory per usable `llvm-link` RUN line, inputs `%s`, `%p/Inputs/*.ll`, `%t` files made by `llvm-as` from those
or from `echo "..." | llvm-as`; skipped RUN lines are listed in its `SKIPPED.md`). `bisect` on an LTO test bisects
the post-link pipeline on LLVM's linked module.

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
tests/lto/src/<area>/<name>/*.c      multi-TU C programs (source of truth)
tests/lto/<area>/<name>/             one multi-module test: test.lto + one .ll per TU (@opt lto-pre-link<O2>)
tests/lto/link/<name>/               hand-written multi-module IR for linker features
tests/imported/llvm/Linker/<test>/   LLVM's linker tests, one directory per llvm-link RUN line
tests/imported/llvm/Transforms/<Pass>/*.ll    LLVM's regression tests, original paths kept; SKIPPED.md per dir
tests/imported/llvm/Analysis/<Dir>/*.ll       LLVM's analysis tests: @analysis for printer RUN lines, @opt for the rest
tests/imported/llvm/Instrumentation/<Dir>/*.ll  LLVM's instrumentation tests (sanitizers, coverage, profiling)
tests/perf/compile/<program>.ll      whole llvm-test-suite programs, one linked module each; @opt -O2, @perf
tests/perf/scaling/<shape>/n<N>.ll   synthetic IR of one shape at three sizes; @opt per pass, @perf, @perf-size
```

How `import-llvm` turns a RUN line into an `@opt` line: `opt … -S < %s | FileCheck` keeps the opt arguments;
`2>&1` is dropped (the check compares the IR; stderr is ignored); legacy pass flags (`-safe-stack`, `-structurizecfg`,
`-lowerswitch`, …, list in `harness/lrh/gen.py`) become `-passes=` when the line has none; `-flag=%S/Inputs/<file>`
(sample profiles, devirtualization summaries, IR2Vec vocabularies) points at a copy in the test's directory,
`-flag=tests/imported/llvm/<Dir>/Inputs/<file>`, a path relative to the repository, which is the tools' working
directory. Lines that need `%t` files, other tools, other targets, or `REQUIRES: asserts` are skipped, and so are lines
whose oracle run creates files in its working directory (GCOVProfiling's `.gcno`): the checks run in the repository.
Every kept line is run through LLVM's opt first; one that fails is listed in `SKIPPED.md` as `oracle fails`.
Re-importing a directory imported before these rules existed can add `@opt` lines to files already in a `passing.txt`.

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

`check` runs `impl/<lang>/build.sh` first (skip with `--no-build`), then the checks in `-j` worker processes (default:
all cores). Timing, 16 cores, warm oracle cache: the goose ratchet (`--ratchet-only`, ~10700 checks) takes 10-20 s and
the whole goose check (`--update`, ~16500) under a minute; with a cold cache (after a cache wipe, or where many
outputs changed) under a minute too. The build is usually the larger part (goose ~2 min from scratch), and both scale
with how loaded the machine is (other agents' sweeps). For every failing check it writes artifacts to
`.harness-out/<impl>/<test path>/<check>/`: `message.txt`, `expected.ll` and `actual.ll` (canonicalized), `diff.txt`,
`input.ll`, `out.s`, `expected.stdout` and `actual.stdout`, `stderr.txt`; for `::analysis`, `args.txt`,
`expected.stderr`, `actual.stderr`, `diff.stderr.txt` (and the same for stdout if it differs).

`from-c` rejects programs that are nondeterministic, time out (10 s), or behave differently between clang `-O0`,
`-O2` and `-O1 -fsanitize=address,undefined`, because that indicates UB and the test would be meaningless.

## Timeouts

Our tools (`impl/<lang>/bin/opt`, `llc`, in `check` and `sweep`) are limited by **CPU time** (user+sys), not wall
time: 240 CPU seconds per invocation in `check` (`LRH_CPU_LIMIT=<s>` overrides it), `--timeout` (default 60) in
`sweep`. CPU time barely changes with machine load, so a slow but correct input passes or times out the same way at
load 1 and at load 40; a wall-clock limit made such tests flap. The limit is `RLIMIT_CPU`, set before the tool starts
and inherited by anything it starts (SIGXCPU at the limit, SIGKILL 5 s later). A **wall-clock backstop** of 4x the
limit (960 s in `check`) kills a tool that hangs without computing (sleep, deadlock, blocked read). The tool runs in
its own process group; a timeout kills the whole group. Messages say which limit hit, distinct from a failure:
`opt timeout (cpu 240s)` or `opt timeout (wall 960s; cpu 3s used)` instead of `opt exited with N`; `sweep` groups
them under `[timeout (cpu 60s)]`.

A ratchet test (in `passing.txt`) that times out is **retried once** before it counts as a regression (`retrying N
timed-out ratchet test(s) once`). A test that times out twice is a real regression: something got slower.
`check` also lists newly passing tests whose slowest tool run used more than half the CPU limit (they are still
recorded): a modest slowdown would turn them into regressions, so speed them up or keep an eye on them.

LLVM's own tools (the oracle side, and `--impl llvm`), clang, and the compiled test programs (10 s) keep plain
wall-clock limits; `perf` has no limit.

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
./harness/run sweep --impl rust --passes instcombine --with-test-flags # plus each file's own -mtriple/-mattr/... (below)
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
| `failed` | loud: nonzero exit, crash or timeout (`--timeout`, default 60 CPU seconds; see Timeouts). Grouped by the first error line (file name and line numbers taken out), most frequent first |
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

### `--with-test-flags`

A sweep runs every file with only the sweep's arguments, so a module without a `target triple` gets no target and
code behind `-mtriple`/`-mattr`/`-mcpu` (TTI hooks such as X86 intrinsic folds, cost models) or behind a pass
`cl::opt` is never exercised: those tests set it on their RUN line. `--with-test-flags` runs each file once per
distinct *flag set* of its own directives and reports one outcome per (file, flag set) (per (function, flag set)
with `--per-function`; works with `--analysis` too):

- **Which directives**: every `@opt`, `@analysis` and `@analysis-unordered` of the file (in IR and in analysis mode
  alike: the flags describe the context the module is meant to be compiled in). Each directive gives one flag set;
  identical sets are run once. A file without directives, or whose directives carry no flags, is run once without
  flags (as in a plain sweep). Files are not run additionally without their flags; a plain sweep does that.
- **Which flags are carried**: everything except the pipeline and the output mode, which the sweep supplies:
  `-passes`/`--passes`/`-p` (also `-passes X`), `-O0`…`-O3`/`-Os`/`-Oz`, `-S`, `-o`, `-disable-output`, `-f`, and the
  pass-selection/debug-output flags `-opt-bisect-limit`, `-run-twice`, `-debug-pass-manager`, `-print-after-all`,
  `-print-before-all`, `-print-changed`, `-time-passes`. So `-mtriple`, `-mattr`, `-mcpu`, `-data-layout`,
  `-aa-pipeline`, `-disable-builtin`, `-verify-*` and every pass `cl::opt` are carried, in their original order and
  spelling (`-mtriple x86_64` stays two tokens). An option the sweep's own arguments already set (`--extra=-mattr=…`)
  is not taken from the test (no duplicate options).
- The flags are appended after the sweep's arguments. An implementation that doesn't support one of them must fail
  loudly; such runs show up as a `failed` group (e.g. "unknown option -cost-kind"), not as mismatches.
- Over the corpus: ~7800 files give ~10000 runs (most files have one set; cost-model tests up to 16), ~1300 distinct
  flag sets. LLVM's results are cached per argument string, so the first such sweep runs LLVM again on the files
  that have flags.

Artifacts go to `.harness-out/sweep/<impl>/[per-function_]with-test-flags_<args>/`; `results.tsv` gets a flags
column after the file (empty = no flags), `summary.json` and the printed lists show `<file> [<flags>]`, and the
artifact directory of a non-identical run is `<test path>/with-<flags slug>/` (then `<n>-<function>/` per
function); its `message.txt` starts with the flags. To reproduce: `opt <sweep args> <flags> -S <file>`.

## Performance (compile time; report only)

`./harness/run perf --impl <lang>[,<lang>…]` measures how fast our tools are compared with LLVM's. It never fails and
doesn't touch `passing.txt`; correctness is still `check`'s job. Every `; @perf: <tool> <args>` line in `tests/perf/`
is one benchmark: `opt` alone is parse + print, `opt -O2` or `opt -passes=…` times a pipeline, `llc -O2` times the
backend on LLVM's `opt` output for the file's first `@opt`.

| Column | Meaning |
| --- | --- |
| `llvm cpu s` | LLVM's CPU time (user + system), the minimum over the runs |
| `cpu` | our CPU time ÷ LLVM's |
| `rss` | our peak resident memory ÷ LLVM's (max over the runs; never under valgrind) |
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

**How RSS is measured.** Each timed run goes through a tiny C helper (source in `harness/lrh/perf.py`, built once
with LLVM's clang into `.harness-out/perf/rss-helper-<hash>`) that forks the tool and reports the tool's own `wait4`
rusage: CPU time and `ru_maxrss`. Taking `wait4` directly from the harness doesn't work: Linux carries a process's
pre-exec memory high-water mark over `exec`, so a child forked from the ~160 MB harness Python process reports at
least 160 MB whatever it runs (before 2026-11, every row read ~1.00x because of this). The helper's floor is under
1 MB. `RUSAGE_CHILDREN` isn't used either: it's the maximum over all children, not this one.

**Per-implementation environment: `impl/<lang>/perf.env`.** Optional; `KEY=VALUE` lines (`#` comments, no quoting
or expansion). `perf` sets these variables for that implementation's `build.sh` and for every run it measures
(timed and valgrind), so all perf numbers of a run come from one binary. Instruction counts are cached with the
environment as part of the key. Use it for settings valgrind needs, e.g. goose's `GOOSE_STACK_RESERVE=128M` (its
~490 data stacks reserve 2 GB of address space each by default, more than valgrind gives a client). Note that a
build-time variable makes `check`'s next build rebuild with the default.

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
llvm-link <args> -S <a.ll> <b.ll> ... -o <out.ll>   # ::link, ::run of LTO tests; cwd = a scratch dir with the modules
```

`<args>` come from `@opt`, `@analysis` and `@llc` lines and from LLVM's own RUN lines: `-passes=<pipeline>`, `-O0`…`-O3`,
`-mtriple=…`, `-mattr=…`, and occasionally pass-specific `cl::opt` flags. An implementation that doesn't support a
flag must exit nonzero with a clear message. The working directory is the repository root, and `<in.ll>` is a
repo-relative path (it shows up in `; ModuleID = '…'`).
