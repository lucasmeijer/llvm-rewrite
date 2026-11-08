# L0.print-imported needs TableGen output and part of the Verifier, and two agents rebuilt the same tables

- **Date / implementation / unit:** 2026-11-09 / jai / L0.print-imported (done: 6994/6994, starting from 6237)
- **What happened:**
  - About half of the remaining failures were AutoUpgrade at parse time. That needs every intrinsic's type
    signature (Intrinsic::getIntrinsicInfoTableEntries, which reads the TableGen-generated IIT_Table) to match
    signatures, mangle names (`@llvm.smin(` -> `@llvm.smin.i32`) and remangle declarations. The workspace has no
    `llvm-tblgen` and no `IntrinsicImpl.inc`. I wrote a small lazy TableGen evaluator in Python
    (`impl/jai/gen/gen_iit.py`, about 600 lines) that emits the decoded IIT descriptors.
  - At the same time the Goose agent solved the same problem differently: it built `llvm-min-tblgen` from source
    into `/persistent/llvm-rewrite/min-tblgen` (`impl/goose/tools/build_min_tblgen.sh`). I only found out from the
    git log after my generator worked. Intrinsic *attributes* are still read from oracle runs in both
    implementations; with the real `IntrinsicImpl.inc` that table could be exact and complete.
  - The debug-info part of the unit (about 215 files) turned out to depend on the IR Verifier. UpgradeDebugInfo
    runs `verifyModule` when the module has "Debug Info Version" 3 and strips debug info it considers broken
    (two imported tests do this). I ported only the one check those tests need.
  - The unit also pulls in a long tail of x86 intrinsic upgrades (upgradeX86IntrinsicCall is ~1800 lines). Only 13
    files needed them; I ported those cases and made the rest fail loudly.
- **Time or effort lost:** about an hour on the TableGen evaluator, which duplicated the Goose agent's work.
  About 20 minutes finding out why debug info disappeared in the memprof tests (the Verifier).
- **What would have helped:**
  - One shared, pre-generated `IntrinsicImpl.inc` (or a JSON dump of the intrinsic records) in the workspace image
    or in `/persistent`, mentioned in AGENTS.md "Workspace facts". All five implementations need it.
  - A `knowledge/llvm/` page listing which parts of TableGen output the IR core needs: IIT table, intrinsic
    attributes, the ImmArg printers, DWARF tables. Agents could then check that page before writing generators.
  - A note in the roadmap that L0.print-imported includes AutoUpgrade, ConstantFold, the full debug-info metadata
    model, and a sliver of the Verifier. The unit is much bigger than its name suggests.
- **What you did instead:** `gen/gen_iit.py` (evaluator, kept and documented), `gen/gen_dwarf.py` (Dwarf.def
  tables), a ported subset of the Verifier's debug-info checks, and fail-loudly errors for the unported x86 upgrades.
  Suggestion: switch every implementation's intrinsic generators to the min-tblgen output now that it exists.
