# Agent instructions

We are rewriting LLVM's middle and back end: textual LLVM IR in, x86-64 assembly out, including the full optimization
pipeline and whole-program (LTO) optimization. No frontend. Several independent implementations, one per language,
live side by side in `impl/<lang>/` (`c`, `rust`, `zig`, `goose`, `jai`) and share one test harness and one test corpus.

**The golden rule: LLVM 23.1.5 is always right.** Every check compares an implementation against the real LLVM tools
in `/opt/llvm-23.1.5`. Up to the input of instruction selection, our IR must be *identical* to LLVM's. After that
(instruction selection, register allocation, assembly), the program only has to *behave* identically.

Background and the decisions behind all this: [docs/plan.md](docs/plan.md).

## Repository map

| Path | What |
| --- | --- |
| `docs/roadmap.md` | Units of work; each has an exit selector of tests that must pass |
| `docs/testing.md` | Test format, the five checks, harness commands, the CLI contract our tools must follow |
| `harness/run` | The harness (Python, standard library only) |
| `tests/` | Shared corpus. `e2e/`, `function/`, `roundtrip/`, `imported/llvm/…` (LLVM's own tests) |
| `impl/<lang>/` | One implementation: `build.sh`, `DESIGN.md`, `NOTES.md`, `passing.txt`, sources |
| `knowledge/llvm/` | Facts about LLVM's behaviour, shared by all implementations |
| `reports/challenges/` | Process friction reports, one file per report, read by the human running the agents |
| `.agents/skills/` | Task skills: `write-test`, `port-pass`, `debug-mismatch`, `codegen`, `lplan` |

Workspace facts: LLVM binaries `/opt/llvm-23.1.5/bin`, LLVM source (llvm/ only) `/opt/llvm-project-23.1.5/llvm`,
llvm-test-suite `/opt/llvm-test-suite-23.1.5`, Zig `/opt/zig-0.17.1` and Goose `/opt/goose-v2026.4` (both on PATH),
Rust via `~/.cargo/bin`, Jai via `scripts/ensure-jai.sh` (installs into `/persistent/toolchains/jai` from the
`JAI_COMPILER_URL` environment variable; that URL is private, so never write it anywhere in the repo). The shared
oracle cache is `/persistent/llvm-rewrite/oracle-cache` (safe to delete; it refills).

## Working on a unit

1. Pick a unit from `docs/roadmap.md` for your implementation (or the one you were assigned). Check
   `./harness/run status` for what's done.
2. Read `impl/<lang>/DESIGN.md` and `impl/<lang>/NOTES.md`, and the `knowledge/llvm/` files relevant to the area.
3. Port faithfully. Read the LLVM source for what you're implementing (`/opt/llvm-project-23.1.5/llvm/lib/...`) and
   reproduce its behaviour, including heuristics and the order in which it does things. Reference the LLVM file you
   ported from in a comment at the top of your file.
4. Iterate with `./harness/run check --impl <lang> --unit <ID>` (and `show`, `bisect`; see `docs/testing.md`).
5. A unit is complete when that command reports `COMPLETE`. Then finish:
   - `./harness/run check --impl <lang> --update`: the full ratchet must pass, and newly passing tests get recorded
     in `impl/<lang>/passing.txt`.
   - Update `knowledge/` and `NOTES.md` with what you learned that someone will need later.
   - Keep `impl/<lang>/port-progress.txt` honest: for every LLVM `.cpp` your file headers name but you ported only
     partly, add `lib/<path>.cpp <fraction>` (0.0–1.0, your best estimate of the share of that file's code ported).
     `scripts/port-progress.py` uses it to report the share of LLVM pass code ported.
   - For a pass unit, run `./harness/run perf --impl <lang>` on the benchmarks that time your pass (report only).
     Note a scaling exponent well above LLVM's, or a large slowdown, in `NOTES.md`.
   - If anything got in your way, write a challenge report (see below).
   - Commit, then `git pull --rebase`, then rerun the check on the rebased tree, then `git push origin main`. If the
     push is rejected, repeat. On a conflict in `passing.txt`, take the union of both sides and rerun the check.

You may push smaller steps before a unit is complete (for example, a parser that passes half of `L0.print-basic`), as
long as the full ratchet passes for your implementation. Never push a regression.

## Rules

- **The ratchet.** A test listed in `impl/<lang>/passing.txt` must keep passing. Never remove a line to make a check
  pass. Only `--update` edits the file, and it refuses to while there are regressions.
- **Stay in your lane.** Change only `impl/<your lang>/` plus shared files you have a reason to touch. A commit that
  changes `harness/`, `tests/` or `docs/roadmap.md` can break other implementations: run the check for every
  implementation before pushing it.
- **Data-oriented, no OOP.** No classes, inheritance, virtual dispatch or visitor hierarchies. Use whatever
  data-oriented features your language offers. The specific design is in `impl/<lang>/DESIGN.md`; follow it, and
  update it when you change the design.
- **Tests are evidence, not obstacles.** Don't edit an imported LLVM test to make it pass. If the oracle itself fails
  on a test (`invalid`), fix or delete the test and say why in the commit message. Add tests freely (skill
  `write-test`); a new test simply isn't passing yet for anyone.
- **Fail loudly.** Unsupported IR or flags must produce a clear error and a nonzero exit, never wrong output.
- **No new dependencies** without a note in the impl's `NOTES.md` explaining why. Never hand-edit generated
  files (`tests/**/O0|O2|pipeline/*.ll`, `tests/imported/**`); regenerate them with the harness instead.
- Commit messages start with the area: `rust: L1.sroa: …`, `zig: …`, `harness: …`, `tests: …`, `docs: …`.

## Notes for later: three places

- **`knowledge/llvm/<topic>.md`**: verified facts about LLVM's behaviour that any implementation needs, e.g. "opt
  prints attribute groups in first-use order". Organised by topic, curated: fix or delete wrong claims instead of
  piling on. Say how you verified a fact (a test, a source file and line).
- **`impl/<lang>/NOTES.md`**: things specific to one implementation or language (build quirks, design debts, traps).
- **`reports/challenges/<YYYY-MM-DD>-<lang>-<slug>.md`**: for the human who designs the agent loop. These are about the
  *process*, not the compiler: unclear instructions, a unit that was too big, a misleading harness message, missing
  tools, time lost going in circles, a guess you had to make. Use `reports/challenges/TEMPLATE.md`. Be concrete
  and honest; these reports are how the process improves.
