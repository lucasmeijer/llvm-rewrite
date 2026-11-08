# The simplifycfg "regression" was never clean; loud stubs hid silent debug-record bugs everywhere

- **Date / implementation / unit:** 2026-11-13 / goose / debug-info infrastructure (task from /root, no roadmap unit)
- **What happened:** I was asked to bisect a regression: `sweep --passes simplifycfg` "earlier was 0, now ~11
  differs". Bisecting showed the `%or.cond3` vs `%or.cond1` mismatch at every goose commit back to the SimplifyCFG
  port: it was an old bug (FoldBranchToCommonDest only renamed *named* bonus instructions to `.old`; LLVM renames
  unnamed ones to `.old` too, which bumps the symbol table's unique counter). The two dbg-value differs came from the
  trailing-records commit (b154269), which made a previously-dropped case reach a different code path. Nobody had
  recorded a sweep table for simplifycfg, so "earlier it was 0" was a guess.
  The bigger issue: debug-record handling was done per pass with local workarounds (per-pass record lists in
  scratch slot VS_PASS1, `m2r_insert_before_adopting` vs `inst_insert_before` with different semantics, local
  `scf_adopt_records`/`cu_prepend_records` patches), and every unported spot failed loudly. Once the central
  infrastructure removed those loud failures, ~1500 silent `differs` appeared in `debugify,instcombine` that had
  nothing to do with debug records per se (wrong `!dbg` on folded selects because `SelectInst::Create(..., MDFrom)`
  was ported as IRBuilder::CreateSelect, wrong head bits at `getFirstInsertionPt` insertion sites).
- **Time or effort lost:** ~1 hour on the bisect before checking whether the "clean" baseline ever existed; the rest
  was real work, but much of it was re-deriving LLVM's iterator head-bit rules site by site.
- **What would have helped:** (1) keep a per-implementation sweep baseline file (pipeline -> counts, commit) that
  agents update, so "regression" claims can be checked in seconds; (2) for infrastructure like debug records, a
  roadmap unit that lands the central mechanism *before* passes start porting around it; (3) a `debugify,<pass>`
  sweep in the exit criteria of every pass unit: without debug info in the input, a whole class of metadata and
  insertion-point bugs is invisible.
- **What you did instead:** ported the LLVM mechanisms centrally (ReplaceableMetadataImpl tracking, head-bit
  insertion API, BasicBlock::splice debug-info rules), documented the rules for pass authors in
  impl/goose/NOTES.md "Debug records (central)" and knowledge/llvm/debug-info.md, and recorded before/after sweep
  numbers in NOTES.md.
