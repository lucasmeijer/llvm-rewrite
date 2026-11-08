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
   (`run`). Assembly may differ.
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
9. **Layers.** L0 IR core → L1 -O0 codegen → L2 codegen for optimized IR → L3 analyses and scalar/loop/vector passes
   → L4 IPO, the full O2 pipeline, LTO → L5 backend optimization (measured against llc, not matched). Units with test
   exit selectors are in `docs/roadmap.md`.
10. **Coordination without GitHub features.** No PRs, issues or CI. Agents push to `main` when a unit of work is
    complete and locally verified (full ratchet green on the rebased tree). The loop that assigns work to agents is
    designed separately. The repo gives it `docs/roadmap.md` plus `./harness/run status` and `check --unit`.
11. **Notes.** `knowledge/llvm/<topic>.md` (shared, curated LLVM facts), `impl/<lang>/NOTES.md` (findings for one
    implementation), `reports/challenges/` (one file per process-friction report, for the human designing the loop).
12. **Workspace image.** `.agents-in-the-cloud/Dockerfile` bakes in LLVM 23.1.5 (pruned to the tools we use), its
    source, llvm-test-suite, Zig and Goose, so every workspace starts ready. Jai's download URL is private, so
    `scripts/ensure-jai.sh` installs Jai at runtime from `$JAI_COMPILER_URL` into `/persistent`, once per template.

## Not decided yet (later lplan rounds)

- Instruction-selection architecture for L2/L5 (SelectionDAG-like, GlobalISel-like, or our own).
- Harness support for analysis-printer tests (`L3.harness-analysis`), multi-module LTO tests (`L4.lto`) and
  performance measurement (`L5.harness-perf`).
- Fuzzing and automatic reduction (`llvm-reduce` with our tools as the interestingness test).
- Alive2-based refinement checking for passes where we deliberately diverge.
