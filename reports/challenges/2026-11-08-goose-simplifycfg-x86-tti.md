# SimplifyCFG's X86 tests quietly require a large slice of the X86 backend (TTI + type legalization)

- **Date / implementation / unit:** 2026-11-08 / goose / L1.simplifycfg
- **What happened:** ~25 of the 289 SimplifyCFG opt tests run with `-mtriple=x86_64` (plus `-mcpu`/`-mattr`).
  Their results depend on X86TTIImpl costs, which depend on the X86 subtarget feature model (X86.td
  implications, CPU lists, per-function attributes), on TargetLoweringBase type legalization, and on ~2300
  cost-table entries. None of that is a roadmap unit, and the unit text says only "x86 TTI cost queries". I also
  found that opt rewrites every function's attributes from `-mcpu/-mattr` (visible in the output), which no doc
  mentioned. Separately, another agent had meanwhile added `subtarget.goose` with its own x86 feature parser
  (for warnings), so there are now two.
- **Time or effort lost:** a large share of the unit: understanding which TTI paths matter, writing a generator
  for the cost tables / features (tools/gen_x86costs.py) and porting the legalization logic. Also time on debug
  records: Goose's `inst_insert_before` doesn't model LLVM's "adopt the records at the insertion point" rule,
  which silently dropped or misplaced `#dbg_value`s in several tests.
- **What would have helped:** a separate roadmap unit "x86 TTI + subtarget" (shared by SimplifyCFG, LoopVectorize,
  SLP, LoopUnroll, inlining) with its own tests, scheduled before the passes that need it; a note in DESIGN.md
  about debug-record placement semantics on insertion; a shared-module registry so two agents don't each write an
  x86 feature parser.
- **What you did instead:** generated the tables from the LLVM sources, ported the SizeAndLatency/CodeSize paths
  and made every other path fail loudly (`x86_np`); compensated for the record-adoption rule inside
  SimplifyCFG/cfgutil only, and documented it in NOTES.md.
