# Two agents picked overlapping pass ids in passmgr.goose; the ratchet recorded wrong-pass "passes"

- **Date / implementation / unit:** 2026-11 / goose / L1.scalar-misc, L1.o2-gaps
- **What happened:** to avoid merge conflicts in passmgr.goose I registered my ~40 small passes in a separate file
  with ids 400..599 dispatched from passmgr's default branch. Concurrently the SLP/vector-combine agent added
  `P_VECTOR_COMBINE = 420`, `P_SLP_VECTORIZER = 421` in passmgr. After rebasing, `loop-sink` silently ran
  vector-combine and `mergeicmps` ran the SLP vectorizer. Four LoopSink tests (where LLVM changes nothing) were
  recorded in passing.txt with the wrong pass; once fixed they turned into "regressions" that forced a full LoopSink
  port before I could push.
- **Time or effort lost:** ~1 hour (diagnosis of "SLPVectorizer: ... not ported" on mergeicmps tests, then the port).
- **What would have helped:** a single registry of pass ids (or names as keys) that rejects duplicates at build
  time; or the harness flagging a pass that "passes" while the output is byte-identical to the input for a test whose
  oracle also leaves it unchanged (weak evidence).
- **What you did instead:** moved my ids to 1400..1599 with a comment in passmgr.goose reserving the range.

Also: a full `./harness/run check --impl goose` plus a few sweeps no longer fits a 10-minute tool call when the build
is cold (the goose build alone is ~4.5 minutes); I ran them separately with longer timeouts.
