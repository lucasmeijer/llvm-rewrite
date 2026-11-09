# A composed-pipeline sweep difference blamed on InstCombine was a pass-manager feature; parallel agents duplicate helpers

- **Date / implementation / unit:** 2026-11-08 / jai / L1.loop-misc (+ L1.analysis.laa)
- **What happened:** The task said `sroa,instcombine,loop-mssa(loop-rotate,licm),loop(indvars),instcombine` differs
  on ~37 more files than without indvars "while the indvars output is identical, i.e. InstCombine bugs". Running
  InstCombine alone on the post-indvars IR gave LLVM's *other* answer: the real cause was LLVM's
  LastRunTrackingAnalysis skipping the second InstCombine (indvars changed flags but reported no change). Nothing in
  the jai port modelled LastRunTracking. Separately, while I ported LoopVersioning (CloneBasicBlock,
  remapInstructionsInBlocks), another agent landed `clone_function.jai` / `value_mapper.jai` with the same LLVM
  functions. My copies compiled next to theirs because Jai overloads by parameter type (`*Table` vs `*Value_Map`), so
  the "duplicate name is a compile error" safety net did not fire; I only noticed by reading `git log`.
- **Time or effort lost:** ~20 minutes on the InstCombine hypothesis (reduction showed "no diff when run alone");
  ~15 minutes rewriting LoopVersioning onto the other agent's cloning utilities.
- **What would have helped:** (1) a note in docs/testing.md "Sweeps" that a difference which disappears when the
  last pass runs alone on LLVM's intermediate IR is a pass-manager/analysis-caching effect (LastRunTracking,
  cached LAA/SCEV), with `-disable-last-run-tracking` as the first thing to try; (2) a short shared list of "utility
  ports in progress" per implementation (or a rule to `git fetch` + grep for the LLVM function name, not just the
  helper name, before porting a utility file).
- **What you did instead:** ported LastRunTracking into the jai pass manager; switched my LoopVersioning code to the
  shared Value_Map / clone_basic_block and deleted my copies before pushing.
