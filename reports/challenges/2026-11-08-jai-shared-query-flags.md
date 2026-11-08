# A shared "no TLI" flag meant two things; only a whole-corpus sweep exposed it

- **Date / implementation / unit:** 2026-11-08 / jai / L1.reassociate, L1.constraint-elimination, L1.aggressive-instcombine
- **What happened:** all three units passed their imported tests on the first full build, so the unit tests gave
  almost no signal. The real bugs came from sweeps: AggressiveInstCombine's final `SimplifyInstructionsInBlock(BB)`
  runs with `TLI = nullptr`, but the Jai `Simplify_Query.have_tli = false` that other passes set is used both for
  "LLVM passes no TLI" and "this port doesn't bother passing one", so library calls kept being constant-folded
  (5 silent mismatches in e2e libm tests and InstCombine/constant-fold-nextafter*). Reassociate had the same kind of
  issue (`isInstructionTriviallyDead` without TLI keeps dead `log(1.0)` calls; DCE/calls-errno.ll).
- **Time or effort lost:** ~30 minutes; small, because the sweep pointed straight at the files.
- **What would have helped:** a note in the port-pass skill that "which analyses LLVM passes as nullptr" (TLI, AC,
  DT, CxtI in SimplifyQuery) is a frequent source of silent mismatches, and that flags like `have_tli` in shared
  query structs should mean exactly the LLVM pointer being null.
- **What you did instead:** added a separate `no_tli_libcalls` field (default off) instead of changing the meaning of
  `have_tli`, so no other pass changes behaviour; documented it in impl/jai/NOTES.md. Auditing every `have_tli =
  false` caller against LLVM would be a worthwhile small task.
