# L1.loop-misc is six passes plus two analyses; long commands die with the tool call

- **Date / implementation / unit:** 2026-11-09 / goose / L1.loop-misc (+ L1.analysis.laa)
- **What happened:** the unit is LoopDeletion, LoopInstSimplify, LoopSimplifyCFG, LoopIdiomRecognize (+
  HashRecognize), LoopLoadElimination, LoopDistribute, and through them LoopAccessAnalysis, PredicatedScalarEvolution,
  LoopVersioning, SCEVExpander's predicate expansion and loop cloning: about 9000 lines of LLVM, ~7000 lines of Goose.
  The roadmap lists it as one unit with one exit selector, so "COMPLETE" was only reachable at the very end, and the
  passes that need LoopVersioning (LLE, LoopDistribute) block on a utility that belongs to no unit. Separately, two
  things cost wall-clock time: a full Goose build is ~3 minutes (longer when other agents' sweeps load the machine),
  and a build started in the background with `( ... &)` inside a Bash tool call was killed when the call returned
  (no output, no binary), as was one `./harness/run check` whose terminal "disappeared". Per-function sweeps of a
  loop pass take 10-20 minutes each on a loaded machine; the unit needed ~30 sweeps.
- **Time or effort lost:** ~10 minutes waiting for builds that never ran; sweeps dominated the elapsed time (they ran
  in tmux while I wrote the next pass, so little was lost there).
- **What would have helped:** splitting the unit (e.g. L1.loop-misc.simple = deletion/instsimplify/simplifycfg/idiom
  and L1.loop-misc.laa-users = LLE/distribute/versioning with L1.analysis.laa as a dependency); a note in AGENTS.md
  that long-running commands must go into a tmux session (`tmux new-session -d -s x "cmd > log 2>&1"`) or
  `nohup setsid`, never a plain `&`; a harness option to build to a side path so sweeps can keep using the old binary
  while the next build runs.
- **What you did instead:** builds to `/tmp/opt.new` with `tools/gb.sh src/opt.goose /tmp/opt.new` while sweeps used
  `--no-build` on the old binary, quick comparisons with small shell scripts against /tmp/opt.new, and every sweep
  batch in its own tmux session writing to a log.
