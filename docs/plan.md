# Plan and decisions

The project's direction, decided in an lplan session before any code was written. Change it deliberately, not by drift.

## Goal

A rewrite of LLVM from textual IR to x86-64 assembly: the IR core, the full `opt` pipeline (scalar, loop, vector and
interprocedural passes), whole-program optimization, and a backend. No frontend. Several independent attempts in
different languages, all data-oriented, so they can be compared.

## Decisions

1. **Faithful port, fixed oracle.** We port LLVM's algorithms one pass at a time from the C++ source and reproduce
   their observable behaviour, heuristics included. The oracle is the latest official release at project start,
   **LLVM 23.1.5** (release tarball, pinned sha256). Upgrading is a deliberate, separate unit of work.
2. **Two kinds of correctness.** Everything up to the input of instruction selection must produce *identical IR*,
   including the IR passes llc runs before isel. Checks: `roundtrip`, `opt`, `isel-ir`. The backend after that is
   judged by *behaviour*: the program built by our tools must print and exit exactly like the one LLVM builds
   (`run`). Assembly may differ. Analyses are also checked on their own, through LLVM's printer passes
   (`print<domtree>`, `print<scalar-evolution>`, …): the stderr of `opt -disable-output` must be identical (`analysis`;
   decided in `L1.harness-analysis`, with no canonicalization except sorting lines for printers that iterate in pointer
   order).
3. **Several implementations, one harness.** `impl/c`, `impl/rust`, `impl/zig`, `impl/goose`, `impl/jai` share the harness, the corpus, the
   roadmap and `knowledge/`. Each produces `bin/{opt,llc,llvm-link}` with LLVM's command-line conventions.
4. **Data-oriented design, no OOP.** Each implementation uses whatever data-oriented features its language offers,
   and documents its own design in `impl/<lang>/DESIGN.md` (that's unit `L0.design`). There's no shared layout and
   no global DOD rulebook. The design must say how it reproduces the orders LLVM's output depends on (use lists,
   worklists, value numbering, name uniquing).
5. **One target.** x86-64 SysV Linux (`x86_64-unknown-linux-gnu`), AT&T `.s` text, assembled and linked by clang
   against glibc. Textual IR input only.
6. **Same command lines as LLVM.** `opt -passes=… -S`, `llc -O<n>`, `llvm-link`, `-opt-bisect-limit`. The harness runs
   identical command lines against both toolchains. Whole-program optimization is link-then-`lto<O2>`, the same as
   LLVM's full LTO.
7. **Live oracle, shared cache, ratchet.** LLVM's results are computed live and cached by content hash in
   `/persistent/llvm-rewrite/oracle-cache`. No golden files. Each implementation has a sorted `passing.txt`; a listed
   test must never fail again.
8. **Corpus sources.** Agent-written C compiled to IR in three configurations (O0, O2, pre-pipeline), LLVM's own
   `llvm/test/Transforms` tests imported per pass, llvm-test-suite programs, and later fuzzing (Csmith/YARPGen) with
   reduction. C sources pass a UB guard before becoming tests.
9. **Layers, middle end first.** L0 IR core → L1 analyses and scalar/loop/vector passes, one pass at a time (plus
   llc's IR-level passes) → L2 IPO, the full O2 pipeline, LTO (exact IR) → L3 -O0 codegen → L4 codegen for optimized
   IR, then end-to-end runs of our opt + our llc → L5 backend optimization (measured against llc, not matched). The
   IR → asm backend was moved after the optimizer (it was originally L1/L2) so that early work concentrates on
   porting passes, which only need the IR core and exact-IR checks. Units with test exit selectors are in
   `docs/roadmap.md`.
10. **Coordination without GitHub features.** No PRs, issues or CI. Agents push to `main` when a unit of work is
    complete and locally verified (full ratchet green on the rebased tree). The loop that assigns work to agents is
    designed separately. The repo gives it `docs/roadmap.md` plus `./harness/run status` and `check --unit`.
11. **Notes.** `knowledge/llvm/<topic>.md` (shared, curated LLVM facts), `impl/<lang>/NOTES.md` (findings for one
    implementation), `reports/challenges/` (one file per process-friction report, for the human designing the loop).
12. **Workspace image.** `.agents-in-the-cloud/Dockerfile` bakes in LLVM 23.1.5 (pruned to the tools we use), its
    source, llvm-test-suite, Zig, Goose and valgrind, so every workspace starts ready. Jai's download URL is private, so
    `scripts/ensure-jai.sh` installs Jai at runtime from `$JAI_COMPILER_URL` into `/persistent`, once per template.
13. **Compile-time performance is measured and reported, not gated.** `./harness/run perf` compares our tools'
    CPU time (parallel runs, ~25 s for everything, ~10% noise per row) and peak memory against LLVM's, optionally
    with exact executed-instruction counts (`--instr`, valgrind; the VM has no hardware counters), on `tests/perf/`: whole llvm-test-suite programs plus synthetic inputs at three sizes,
    whose fitted growth exponent exposes worse algorithms early. No ceiling and no ratchet; a history in
    `/persistent` shows trends. The speed of the *generated code* is a later unit (L5).

## Not decided yet (later lplan rounds)

- Instruction-selection architecture for L3–L5 (SelectionDAG-like, GlobalISel-like, or our own).
- Harness support for multi-module LTO tests (`L2.lto`) and measuring the speed of generated programs
  (`L5.harness-perf`).
- Whether compile-time performance should ever block a push (a ratchet on instruction counts is possible).
- Fuzzing and automatic reduction (`llvm-reduce` with our tools as the interestingness test).
- Alive2-based refinement checking for passes where we deliberately diverge.
