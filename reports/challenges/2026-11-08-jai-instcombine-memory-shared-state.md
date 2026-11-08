# Porting InstCombine memory/vector files alongside two other agents: shared helpers and a moving sweep baseline

- **Date / implementation / unit:** 2026-11-08 / jai / L1.instcombine.memory
- **What happened:** Three agents ported InstCombine files concurrently (memory+vector ops, casts+calls,
  SimplifyCFG). Many helpers these files need live in shared analyses that were only partly ported or ported
  twice under different names (pass_sroa.jai already had a fatal-heavy isSafeToLoadUnconditionally; MemoryBuiltins
  tables were split over inst_props.jai, basic_aa.jai and aa.jai; `common_alignment`, `alloca_is_static`,
  `inst_indices`, `do_phi_translation`, `sv_mask`, `ctz64` already existed). Jai reports a duplicate global
  procedure only as an "ambiguous overload" at a call site, so every new file needed a duplicate-name scan
  (`grep "^name ::"` over all files) before it built. The visitCallInst/visitReturn boundaries were edited from
  both sides (I briefly re-did a change the calls agent had already made).
  The "compare the sweep with main before your work" rule was hard to apply: main moved by thousands of
  identical files during the task because the other agents pushed, so the comparison mixes everyone's changes.
- **Time or effort lost:** ~1 hour on duplicate names and on coordinating who owns which LLVM function; a
  latent shared bug (shuffle masks read through a view into a growing pool) cost another hour to find because it
  only showed up as garbage masks in a per-function diff.
- **What would have helped:** a generated index of existing procedures with their LLVM names (e.g. a
  `tools/symbols.py` that lists `name :: (` with the `// LLVMName` comment above it), and an ownership table per
  LLVM function in DESIGN.md that agents update when they start, not when they finish. For sweeps: keep the
  baseline per agent as "origin/main with my commits reverted" (a script that builds that tree), or let the
  sweep tool compare against a saved results.tsv and print only transitions caused by files you touched.
- **What you did instead:** a second worktree at origin/main for the baseline sweep, a python transition counter
  over the two results.tsv files, and messages to the other agents naming every helper I added.
