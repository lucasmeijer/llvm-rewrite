# InstCombine select/phi: the unit's tests mostly measure other visitors

- **Date / implementation / unit:** 2026-11-10 / jai / L1.instcombine.select (+ InstCombinePHI.cpp)
- **What happened:** InstCombineSelect.cpp and InstCombinePHI.cpp are now ported completely, but only 27/49 of the
  unit's `::opt` checks pass. Every remaining failure was traced to a *different* visitor (casts, calls/min-max,
  GEP canonicalization, loads/stores, shufflevector, extract/insertvalue). The select tests are whole-file
  `-passes=instcombine` runs, so a file passes only when all of InstCombine is done. Porting select also required
  pieces owned by nobody: the vector half of InstCombineSimplifyDemanded.cpp (SimplifyDemandedVectorElts), the FP
  half of ValueTracking's matchSelectPattern, CondContext in SimplifyQuery, combineMetadataForCSE (Local.cpp).
- **Time or effort lost:** ~1 h triaging failures that turned out to belong to other files; ~30 min on a crash
  caused by a shared helper (`const_is_element_wise_equal`) that silently built constant expressions over
  instructions; ~15 min because another agent overwrote my files in the shared `/tmp`.
- **What would have helped:** (1) a per-function view of a test file's diff ("which functions differ, and which
  visitor last touched them") — LLVM's `-debug-only=instcombine` is not available because the oracle is a release
  build; an assertions-enabled LLVM build in the workspace would make triage much faster. (2) Exit selectors for
  instcombine sub-units that are reachable without the rest of InstCombine (e.g. per-function checks or a list of
  functions), or simply making all L1.instcombine.* one unit. (3) A note in AGENTS.md that /tmp is shared between
  agents (use a private subdirectory).
- **What you did instead:** compared `sweep --passes instcombine` results file-by-file against a sweep of main
  built in a second worktree (no identical file regressed; +136 files identical), and used llvm-extract to cut
  single functions out of test files.
