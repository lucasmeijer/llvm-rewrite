# Goose: a 3-minute build per iteration, and scalar passes that stop at other units' cost-model gaps

- **Date / implementation / unit:** 2026-11-24 / goose / L1.reassociate, L1.constraint-elimination, L1.aggressive-instcombine
- **What happened:** every edit of any `.goose` file means a full `goose build` of the whole program (~3 minutes on a
  loaded machine), because the program is compiled as one C translation unit. `goose check src/opt.goose` (~30 s)
  catches type, lifetime and borrow errors (e.g. "cannot call c_false, which shrinks cst_tab ... evaluated earlier in
  the statement") without a build, so the loop that worked was: write the whole port from LLVM's source, `goose
  check` until clean, then one build + unit check + sweeps. The three ports passed 78/82, 104/104 and 43/44 on their
  first build. What was left was not in the passes: the last AggressiveInstCombine test (X86/fptosisat.ll) needs
  X86 RecipThroughput costs of half-precision casts and of vector fptosi.sat expansions (the vector cost model being
  ported by another agent at the same time), and three Reassociate tests run `inline` (no CGSCC pipeline yet).
  Two concurrent agents edited the same shared lines (`KNOWN_FLAGS` in flags.goose, the pass-id block of
  passmgr.goose) and one changed my just-pushed reassociate.goose (vector-typed ConstantInt splats); every rebase
  conflicted on flags.goose.
- **Time or effort lost:** ~25 minutes of builds per unit; ~15 minutes resolving the same flags.goose conflict
  three times.
- **What would have helped:** (1) one `KNOWN_FLAGS` entry per line, sorted, or a per-pass flag list next to each pass,
  so concurrent additions don't touch adjacent lines; (2) pass ids allocated per agent range in a comment in
  passmgr.goose; (3) a note in the roadmap that L1.aggressive-instcombine's X86 tests depend on the X86 cost model
  (RecipThroughput casts and BasicTTIImpl's type-based intrinsic costs).
- **What you did instead:** `goose check` before every build; small, separate commits; scalar fptosi.sat costs only,
  with the rest left loud (the cost queries fail with "not ported yet", never silently).
