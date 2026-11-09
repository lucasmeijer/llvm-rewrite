# A "test flag" sweep is the wrong tool to verify a representation flag; a whole-corpus `--extra` sweep is

- **Date / implementation / unit:** 2026-11-09 / goose / shared infrastructure (vector-typed ConstantInt splats,
  demanded-elements masks as APInt, ppc_fp128 survey)
- **What happened:** the task said to verify with `--with-test-flags` sweeps. Those exercise
  `-use-constant-int-for-fixed-length-splat` on only the ~35 runs whose RUN lines carry it, and LLVM's output is the
  same in both modes for all but six of them, so they say little about whether the ~100 `isa<ConstantInt>` sites
  in goose that carried a `!ty_is_vector` guard behave like LLVM. What found the real problems (a parser crash on
  splat shuffle masks, wide splats losing their words in `splat_value`, an unfolded `bitcast (<1 x i64> splat ..
  to double)`, SCCP not folding `select <4 x i1> splat (i1 true)`) was sweeping the *whole* corpus with
  `--extra='-use-constant-int-for-fixed-length-splat -use-constant-int-for-scalable-splat'`: LLVM's output barely
  changes with the flag, so every difference is a goose bug. Two smaller frictions: background jobs started with
  `(setsid nohup … &)` died when the same tool call ran other commands after them (it worked when the launch was
  the only command), and a `goose build --debug` binary used to get a backtrace stops first on debug-only
  `as`-conversion range checks (`-1 as u64` in gvn.goose hashing), which are not the release-build failure.
- **Time or effort lost:** ~30 min on the background-job and debug-build detours; the audit itself was the work.
- **What would have helped:** a line in docs/testing.md (Sweeps) saying that a flag which changes the IR
  *representation* (not a pass option) should be checked with a whole-corpus `--extra` sweep, since LLVM is its
  own reference in both modes; and a note that a debug build's first failure can be a debug-only check.
- **What you did instead:** used both kinds of sweep (whole-corpus with the flags: 0 differs, 0 crashes for
  instsimplify, instcombine, sccp, gvn, reassociate), wrote the rule for porters into impl/goose/NOTES.md
  ("Vector infrastructure"), and launched long sweeps as the only command of a tool call.
