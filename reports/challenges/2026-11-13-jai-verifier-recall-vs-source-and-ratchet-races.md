# Verifier port: details recalled instead of read cost regressions; 9-minute ratchets race other pushers

- **Date / implementation / unit:** 2026-11-13 / jai / L1.verifier
- **What happened:** The Verifier runs on *every* opt invocation (input and output), so any check that is wrong by
  a hair turns passing tests into failures across the whole corpus. The first full ratchet after wiring it in had
  ~600 regressions, nearly all from details I wrote from memory instead of reading the LLVM source: castIsValid
  (pointers may be bitcast to byte types), IntrinsicInst::mayLowerToFunctionCall (only ObjC ARC calls, not
  memcpy), DominatorTree::dominates for callbr (no special case), FuncletPadInst operand layout (parent last),
  StructType::isSized's Visited set, ModuleSlotTracker's default `ShouldInitializeAllMetadata = true` (which
  decides every `!N` in the messages). Each was a one-line fix once found, but each needed a 6-9 minute ratchet
  run to discover on this loaded machine (load 40-80 on 16 cores).
  Separately, `check --update` takes ~9 minutes here, and origin/main moved during three of four of those runs
  (other jai agents push every few minutes), so the "rerun on the exact rebased tree, then push" rule became a
  loop. The last move was a docs-only commit; I pushed without a fourth run.
- **Time or effort lost:** ~1.5 hours of ratchet waiting and re-runs; ~30 minutes on the Jai macro detail that a
  `,,` named argument inside a `$x: Code` macro argument does not resolve.
- **What would have helped:** (1) a rule in port-pass/AGENTS.md: "for any function you port, open its LLVM
  definition; never write a predicate from memory" — obvious, but the pressure of an 8000-line file pushes towards
  recall. (2) A fast "every file's ::roundtrip" subset run (no passes) as the first gate for parser/verifier work:
  it finds input-verification false positives in a fraction of the full ratchet. (3) A push lock or a
  "docs-only rebase needs no rerun" exception in AGENTS.md, so agents don't loop.
- **What you did instead:** ran the ratchet in tmux and fixed by failure group (first line of message.txt
  aggregated over `.harness-out`), then reran only the failing files before the full ratchet. For the race:
  rebased, rebuilt and reran until only a docs-only commit was in between.
