# goose L0.print-imported: shared working tree, no TableGen binary, and a parse unit that is really "port AutoUpgrade"

- **Date / implementation / unit:** 2026-11-09 / goose / L0.print-imported (5955 -> 6979 of 6994)
- **What happened:**
  - Two (later three) agents edited `impl/goose` in the same checkout `/work`. A plain `git add impl/goose/src`
    committed another agent's half-finished files; later another agent's commit reverted three of my fixes
    (restored by them). Their uncommitted edits also broke my builds for a while (`knownbits.goose` errors while
    I was building `opt`), so a failing build did not tell me whether *my* change was wrong.
  - The unit needs LLVM's intrinsic tables (names, IIT signatures, attributes), which come from TableGen; the
    workspace has the LLVM sources but no `llvm-tblgen` and no top-level `cmake/` or `third-party/` directory, so
    the CMake build cannot run. The previous goose agent had worked around it by asking the oracle for each
    intrinsic used in the corpus (incomplete and not a port).
  - "Print imported tests" turned out to mean porting large parts of AutoUpgrade.cpp, DebugInfoMetadata (every
    `!DI*` node, its field defaults, its *internal operand order* for slot numbering), debug records,
    ConstantFold.cpp, the Verifier's debug-info stripping, ODR type uniquing and more. The remaining 15 tests need
    the x86 intrinsic upgrades (thousands of lines of IRBuilder code in AutoUpgrade.cpp).
  - Goose compile times: a generated file with ~60k array-literal elements took 4m43s to compile; the same data
    as hex strings compiles in seconds.
- **Time or effort lost:** ~30 min on the shared-tree problems (stray commit, rebuild confusion, re-checking that
  nothing of mine was lost); ~20 min getting llvm-min-tblgen to build by hand (worth it); ~10 min on the compile
  time surprise.
- **What would have helped:** separate worktrees per agent from the start (the root switched to `/work-wt/` later);
  a prebuilt `llvm-tblgen`/`llvm-min-tblgen` (or the full llvm-project tree) in `/opt`; splitting
  L0.print-imported into sub-units (core syntax, debug info, AutoUpgrade-generic, AutoUpgrade-x86, constant
  folding) so an agent knows the x86 upgrades are optional work rather than "the last 0.2%".
- **What you did instead:** `impl/goose/tools/build_min_tblgen.sh` builds llvm-min-tblgen (~15 s) into
  `/persistent/llvm-rewrite/min-tblgen`, and `tools/gen_intrinsics.py` turns IntrinsicImpl.inc into Goose tables;
  any implementation can reuse the script. Commits list explicit paths and are pushed with `git pull --rebase
  --autostash` + `git push origin HEAD:main`.
