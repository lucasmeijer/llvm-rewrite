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
```

The `.ll` files in `O0/`, `O2/`, `pipeline/` and `imported/` are generated. Regenerate them, never edit them by hand.

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
```

`check` runs `impl/<lang>/build.sh` first (skip with `--no-build`). For every failing check it writes artifacts to
`.harness-out/<impl>/<test path>/<check>/`: `message.txt`, `expected.ll` and `actual.ll` (canonicalized), `diff.txt`,
`input.ll`, `out.s`, `expected.stdout` and `actual.stdout`, `stderr.txt`.

`from-c` rejects programs that are nondeterministic, time out (10 s), or behave differently between clang `-O0`,
`-O2` and `-O1 -fsanitize=address,undefined`, because that indicates UB and the test would be meaningless.

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
