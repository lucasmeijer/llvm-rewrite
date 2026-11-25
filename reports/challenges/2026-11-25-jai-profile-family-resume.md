# Resuming a crashed agent's large uncommitted profile-family work; a jai opt without -print-after-all

- **Date / implementation / unit:** 2026-11-25 / jai / L1.extra.sample-profile, L1.extra.pgo.instr
- **What happened:** I resumed a worktree with ~4000 lines of uncommitted sample-profile work (8 new files), one
  of them (sample_profile_inference.jai) written but never `#load`ed, a stub with the same procedure name still
  active, and a `passing.txt` already modified by an earlier `--update` (to be discarded). Working out which files
  were live, which were stubs and which were dead took a while; a stub file (`sample_prof_stubs.jai`) mixed real
  helpers (the binary magic check, with an operator-precedence bug that made every binary profile
  "Unrecognized") with fail-loudly stubs. Later, a silent differ in `thinlto-pre-link<O2>` with a sample profile
  needed a pass-level bisect: the jai opt has no `-print-after-all`, and `-opt-bisect-limit` on the default
  pipeline is useless because required passes (assign-guid) differ at limit 1. What worked: print LLVM's
  pipeline with `-print-pipeline-passes`, drop the required tail passes, run it as `-passes=` on both tools, and
  bisect `-opt-bisect-limit` on that; then feed LLVM's IR at the found limit to the single pass.
- **Time or effort lost:** ~30 minutes on the resume archaeology, ~20 minutes on the bisect recipe.
- **What would have helped:** for resumes, a rule that WIP commits (even unbuilt) are pushed to a private branch
  so the next agent sees a history instead of a dirty tree; a short `bisect-pipeline` script (or `harness/run
  bisect` accepting arbitrary opt arguments instead of a test path) that does the recipe above.
- **What you did instead:** committed the WIP locally first, rebased, wired the dead file in, and did the bisect by
  hand (recipe in this report; it should become a harness command).
