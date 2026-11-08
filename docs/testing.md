# Testing

The harness compares an implementation against LLVM 23.1.5. All of it is `./harness/run <command>`
(source in `harness/lrh/`, Python 3, standard library only).

## Test files and checks

A test is any `.ll` file under `tests/`. Directives in its leading comment block decide which checks it has:

```llvm
; @opt: -passes=instcombine     IR->IR check (repeatable for imported tests: all must match)
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
| `isel-ir` | if `@llc` | The IR that reaches instruction selection, `llc <args> -stop-before=x86-isel`. Input is LLVM's opt output, so this is isolated from `opt`. Canonicalized and identical. |
| `run` | if `@llc` | Full pipeline with *our* tools (our opt if `@opt`, then our llc), linked by clang with `-no-pie`, executed: stdout and exit code identical to the LLVM-built program. |

Outcomes: `pass`, `fail`, or `invalid`. `invalid` means LLVM itself fails on the test, so the test is broken.

## Corpus layout

```
tests/roundtrip/<area>/*.ll          hand-written IR for parser/printer work (roundtrip only)
tests/e2e/src/<area>/*.c             C programs (source of truth; not tests themselves)
tests/e2e/O0/<area>/*.ll             clang -O0 -Xclang -disable-O0-optnone; @llc -O0
tests/e2e/O2/<area>/*.ll             clang -O2;                              @llc -O2
tests/e2e/pipeline/<area>/*.ll       clang -O2 -Xclang -disable-llvm-passes; @opt -O2, @llc -O2
tests/function/src/<area>/x.c + x.driver.c    same three configurations, with @driver
tests/imported/llvm/Transforms/<Pass>/*.ll    LLVM's regression tests, original paths kept; SKIPPED.md per dir
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
./harness/run check --impl llvm                          # self-test: LLVM against itself; finds invalid tests

./harness/run from-c tests/e2e/src/<area>/x.c            # C -> three .ll tests, with UB validation
./harness/run import-llvm Transforms/LICM                # import LLVM's tests for a pass
./harness/run import-test-suite SingleSource/UnitTests   # import llvm-test-suite programs

./harness/run perf --impl rust                           # compile-time report vs LLVM, ~25 s (see Performance)
./harness/run perf --impl rust --instr                   # plus exact instruction counts (valgrind; slow, cached)
./harness/run perf --impl rust,zig 'tests/perf/scaling/allocas/*'   # several impls side by side, some benchmarks
./harness/run gen-perf                                   # regenerate tests/perf
```

`check` runs `impl/<lang>/build.sh` first (skip with `--no-build`). For every failing check it writes artifacts to
`.harness-out/<impl>/<test path>/<check>/`: `message.txt`, `expected.ll` and `actual.ll` (canonicalized), `diff.txt`,
`input.ll`, `out.s`, `expected.stdout` and `actual.stdout`, `stderr.txt`.

`from-c` rejects programs that are nondeterministic, time out (10 s), or behave differently between clang `-O0`,
`-O2` and `-O1 -fsanitize=address,undefined`, because that indicates UB and the test would be meaningless.

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
```

`<args>` come from `@opt` and `@llc` lines and from LLVM's own RUN lines: `-passes=<pipeline>`, `-O0`…`-O3`,
`-mtriple=…`, `-mattr=…`, and occasionally pass-specific `cl::opt` flags. An implementation that doesn't support a
flag must exit nonzero with a clear message. The working directory is the repository root, and `<in.ll>` is a
repo-relative path (it shows up in `; ModuleID = '…'`).
