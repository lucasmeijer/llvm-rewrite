# Finding a ScalarEvolution "history" difference with only a release opt

- **Date / implementation / unit:** 2026-11-22 / jai / L1.loop-unroll
- **What happened:** an extra sweep with `-unroll-force-peel-count=2` showed a single extra `nsw` on a peeled loop's
  counter. The only way LLVM can produce a different flag on the same IR is SCEV state (query order, uniqued nodes
  and their flags). The LLVM install is a release build: no `-debug` / `-debug-only=scalar-evolution`, so there is
  no way to see which query LLVM made or what it concluded. I bisected on our side instead (an assert on the moment
  the flag is set, fresh-SE experiments, dumping use lists and comparing them with `-preserve-ll-uselistorder`
  output), which eventually pointed at proveNoWrapByVaryingStart and an `unsigned Delta : {-2, -1, 1, 2}` quirk in
  LLVM that our SCEV port had "fixed" by using signed deltas.
- **Time or effort lost:** about an hour on this one difference, most of it ruling out stale-cache hypotheses that a
  single `-debug-only` trace from LLVM would have excluded immediately.
- **What would have helped:** an assertions/debug build of `opt` (even just `opt`, at
  `/opt/llvm-23.1.5-debug/bin/opt`) so that `-debug-only=<type>` traces can be diffed against the port's own
  debug prints. Also a harness option to print use-list orders of both tools (our printer does not support
  `-preserve-ll-uselistorder`), since use-list order is a common cause of such differences.
- **What you did instead:** temporary asserts and prints in the port, removed before committing. Worth writing
  down as a standard recipe: "flag differs → assert where the flag is set on the matching node → read the stack".
- **Also:** three concurrent jai agents adding rows to the same enum/table/`#load` lists made every rebase conflict in
  `passes.jai`, `opt.jai`, `loop_pm.jai` (always resolvable by taking both sides), and a helper I added
  (`fn_has_profile_data`) collided with an identical one another agent pushed an hour later (a compile error after
  rebase, not before). A per-pass registration file, or a convention of appending at distinct anchors, would avoid both.
