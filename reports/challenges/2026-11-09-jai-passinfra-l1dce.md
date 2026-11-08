# Jai pass infrastructure: L1.dce can't be COMPLETE alone, shared worktree, Jai precedence trap

- **Date / implementation / unit:** 2026-11-09 / jai / pass infrastructure, L1.analysis.domtree (COMPLETE), L1.dce
- **What happened:**
  1. Same as the goose report of the same day: 10 of the 56 L1.dce `::opt` checks run pipelines with passes from
     other units (`simplifycfg`, `sroa`, `gvn`, `loop-mssa(licm)`, `instcombine`, `module(debugify)`,
     `redundant-dbg-inst-elim`) or need unrelated features (`--preserve-ll-uselistorder` printing,
     `--enable-knowledge-retention` = AssumeBundleBuilder), and 7 files fail `::roundtrip` on debug-info metadata
     (parser work owned by another agent). "Work until COMPLETE" wasn't achievable; I stopped at "every check that
     only needs dce/adce/bdce passes".
  2. Two agents in the same `impl/jai` working tree: the other agent's uncommitted edits (opt.jai, new files) were
     in my builds, and a broken intermediate state of theirs would break my compiles and ratchet runs. I moved to a
     private `git worktree` (`/tmp/wpi`) early, which fixed it; later both agents defined helpers with the same
     global names (`call_arg`, `strip_pointer_casts`, `is_int_or_int_vector`), which only surfaced as compile errors
     after rebasing.
  3. `cast(u64) a << 32` in Jai casts the *result* of the shift (u32 shift → 0). That made LegalizeUpdates merge
     different edges into one key and silently skip dominator-tree updates; it took a while to find because the
     symptom was "the incremental update didn't run" rather than a crash.
  4. The corpus doesn't exercise some exactness requirements: `DomTreeNodes.size()` (which lags the block count and
     depends on LLParser's block numbering) decides whether `applyUpdates` recalculates; only a 91-block function in
     an unrelated SLPVectorizer test showed the difference. I found it by running my passes and printers over all
     6635 round-tripping imported tests against the oracle (a script, not the harness).
- **Time or effort lost:** ~20 min on the precedence bug, ~15 min on the shared tree before moving to a worktree,
  ~20 min on the vector-size threshold.
- **What would have helped:**
  - Exit selectors restricted to tests runnable with the unit's own passes (or a separate "integration" list).
  - A harness mode that runs an arbitrary pipeline over every file that round-trips and compares with the oracle
    (`./harness/run sweep --impl jai -- -passes=adce`): far more coverage than a pass's own imported tests, and it
    caught 6 real bugs here that the unit's tests didn't.
  - Instructions to use one worktree per agent from the start when two agents share an implementation, and a
    naming convention (prefix per file/area) for top-level Jai procedures.
  - A roadmap unit for ValueTracking/KnownBits shared by BDCE/DemandedBits, InstSimplify and InstCombine: a partial
    computeKnownBits is not even conservative for BDCE (fewer known bits can make an operand look dead).
- **What you did instead:** private worktree + `git push origin HEAD:main` after rebasing; ported everything
  runnable; partial computeKnownBits documented in `impl/jai/NOTES.md`; the sweep scripts are described in NOTES so
  the next agent can reproduce them.
