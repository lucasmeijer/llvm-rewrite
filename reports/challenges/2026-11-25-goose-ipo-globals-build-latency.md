# Goose IPO port: a 4-9 minute build per iteration, and a misleading "unknown function" for module-private helpers

- **Date / implementation / unit:** 2026-11-25 / goose / L2.globals, L2.ipo-args (resumed after a crashed agent)
- **What happened:** The port itself went smoothly (all sweeps at 0 differs on the first or second build), but
  every `./build.sh` took 4-9 minutes of wall time on the shared machine (load average 25-35 from other agents'
  sweeps), so each edit-test cycle was dominated by the C compile of the whole program. `goose check` (~20 s) catches
  type errors, but not behaviour. Twice a build started before an edit finished after it, so `build.sh`'s
  timestamp check (`find -newer bin/opt`) considered the binary up to date and the next test silently ran the old
  code (fixed by `touch`ing the edited file). Separately, calling `aset_remove_incompatible`,
  `lsa_get_or_enforce_known_alignment` or `ic_constant_fold_instruction` from a new file failed with "unknown
  function" even with `import ic_calls;`: they belong to the multi-file module `ic` and need `ic::name(...)`; the
  error message doesn't say the function exists under another module.
- **Time or effort lost:** about an hour of waiting on builds; ~10 minutes on the stale binary; ~10 minutes on the
  `ic::` qualification.
- **What would have helped:** `build.sh` recording the newest source mtime it compiled (or a content hash) instead of
  comparing against the binary's mtime; a note in impl/goose/NOTES.md "Goose traps" that the `ic_*` files form one
  module `ic` whose functions are called as `ic::f` from outside (now visible in NOTES via the examples in
  inline_function.goose, but only by grepping).
- **What you did instead:** batched several passes per build (wrote GlobalDCE/ConstantMerge/StripDeadPrototypes/
  ElimAvailExtern together, then DAE/Internalize, then GlobalOpt+Evaluator, then ArgumentPromotion), ran builds in a
  tmux session while reading the next LLVM file, and touched sources before rebuilding when an edit overlapped a
  build. The resume itself cost nothing: the crashed agent had committed nothing, so the worktree was rebased and
  the work started from origin/main.
