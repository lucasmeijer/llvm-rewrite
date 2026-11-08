# Shared CFG infrastructure: unit boundaries hide cross-unit dependencies, and parallel agents duplicate helpers

- **Date / implementation / unit:** 2026-11-09 / goose / L1.analysis.domtree, L1.analysis.loops, L1.loop-canonical
  (assigned as one task: incremental dominator updates, break-crit-edges, LoopInfo/CycleInfo, LoopSimplify/LCSSA).
- **What happened:**
  1. `L1.analysis.loops` includes `Analysis/LoopNestAnalysis` (`print<loopnest>`). That printer is a *loop* pass, so
     it needs the loop pass manager (with LoopSimplify + LCSSA canonicalization in the adaptor) and
     ScalarEvolution (`Loop::getBounds`). But `L1.analysis.scev` depends on `L1.analysis.loops`. So the unit can't
     reach COMPLETE until a later unit is done; it sits at 24/28 with LoopInfo and CycleInfo fully passing.
  2. LoopSimplify needs pieces of three other areas: `simplifyPHINode` (InstSimplify), `isSafeToSpeculativelyExecute`
     and `isGuaranteedNotToBePoison` (ValueTracking), and `foldBranchToCommonDest` (SimplifyCFG). Two of those
     were being ported by other agents at the same moment, in unmerged branches. I wrote minimal local versions that
     fail loudly outside the cases I ported, and left the SimplifyCFG transform as a loud "not ported".
  3. While I worked, the mem2reg agent added `BasicBlock` numbering to `ir.goose` with the same names as my numbering
     in `irutil.goose` (`fn_next_bnum`, `block_number`). Theirs was better placed, so I dropped mine at rebase; the
     preserved-set constants (`PA_CFG`, `A_*`) had the same problem. Each agent needed the same small piece of
     shared infrastructure at the same time, and nothing showed who owned it.
  4. The dominator tree has hidden, printed state: `print<domtree>` shows the DFS numbers and the slow-query count,
     and LoopInfo, every IDF computation and `dominates()` itself change them. So a pass that is "correct" can still
     fail a later printer. mem2reg (another agent's pass) is affected: `mem2reg,print<domtree>` differs until it calls
     `dt_update_dfs_numbers`. I messaged that agent and documented it in knowledge/llvm/dominators-and-dce.md.
- **Time or effort lost:** about 30 minutes on the rebase conflicts and on finding out who had block numbers. Some
  time on reading SimplifyCFG/ValueTracking code only to decide what to stub. Nothing went in circles.
- **What would have helped:** a roadmap check that a unit's exit tests don't need a later unit (loopnest → scev).
  A short "shared infrastructure owners" list per implementation (block numbering, preserved sets, InstSimplify
  entry points, ValueTracking), so parallel agents put one helper in one place. A harness command for differential
  random-input testing of analyses/passes: `impl/goose/tools/fuzz_cfg.py` found more than the corpus did and
  checks byte-identical output, including use-list order through the `; preds =` comments, which the `::opt`
  canonicalization hides.
- **What you did instead:** fail-loudly stubs with a note in NOTES.md naming what to switch to once
  InstSimplify/SimplifyCFG land; a per-impl fuzz script (`impl/goose/tools/fuzz_cfg.py`, about 5000 comparisons per
  run, 0 differences); direct `-S` comparisons on the four `tests/perf/compile` programs (byte-identical for
  loop-simplify, lcssa, break-crit-edges and adce).
