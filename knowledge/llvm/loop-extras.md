# The Layer-1b loop passes: IRCE, guards, loop fusion / flatten, loop-misc extras, strength reduction

Facts that decide output, verified by the Jai port (`impl/jai/src/pass_irce.jai`, ...) against the imported tests and
whole-corpus sweeps.

## IRCE (`irce`, InductiveRangeCheckElimination.cpp + Utils/LoopConstrainer.cpp)

- A function pass. Before the worklist it runs `simplifyLoop(L, ..., PreserveLCSSA=false)` and
  `formLCSSARecursively(*L)` on every top-level loop with `for (const auto &L : LI)`: `L` is a *reference to the
  TopLevelLoops slot*, so when simplifyLoop separates a nested loop (separateNestedLoop → changeTopLevelLoop) LCSSA is
  formed for the new outer loop, not for the loop simplifyLoop was called on. Visible as extra `.lcssa` phis in the
  outer loop (sweep: IndVarSimplify/lcssa-preservation.ll, ValueTracking/phi-self.ll).
- The new pass manager always gives IRCE a GetBFI, so `estimatedTripCount` is header freq / preheader freq from BFI,
  never the latch-probability formula. The BPI it holds is computed once and survives every `AM.invalidate` (PA =
  all minus BFI), so after simplifyLoop it is stale: new blocks get the uniform 1/n probability; BFI recomputed later
  uses that stale BPI. `InvertBranch` of a range check also swaps the BPI edge probabilities.
- `LPMAddNewLoop(NL, false)` calls `appendLoopsToWorklist(*NL, ...)` with the *Loop* as the range, i.e. its subloops,
  and the new loop has none yet (createClonedLoopStructure adds them afterwards): the pre/post loops are never
  revisited. They also get `!loop_constrainer.loop.clone !{}` on the latch terminator and a distinct loop ID
  `!{self, !{"llvm.loop.unroll.disable"}, !{"llvm.loop.vectorize.enable", i1 false},
  !{"llvm.loop.licm_versioning.disable"}, !{"llvm.loop.distribute.enable", i1 false}}`.
- `setName("indvar.start")`, `"exit.preloop.at"`, `"exit.mainloop.at"` rename whatever SCEVExpander returned, which
  may be an existing argument or instruction; on a constant it does nothing.
- Cloned blocks are RemapInstruction'ed only: their debug records keep referring to the original loop's values (as
  in LLVM, RemapInstruction does not touch DbgRecords).
- `-irce-print-*` output goes to stderr and is not part of the `::opt` check.

## Guards (`loop-predication`, `guard-widening`, `lower-guard-intrinsic`, `lower-widenable-condition`, `make-guards-explicit`)

- `IRBuilder::CreateAnd(LHS, RHS)` only constant-folds when both operands are constants: `and %x, true` is *not*
  folded (IRBuilder.h:1570). LoopPredication's `CreateAnd(FirstIterationCheck, LimitCheck)` with a `LimitCheck` that
  `expandCheck` proved `true` keeps the `and ..., true` (sweep: IndVarSimplify/post-inc-range.ll).
- LoopPredication's profitability threshold is `LatchExitProbability * ScaleFactor` with a `float` ScaleFactor: there
  is no `BranchProbability * float`, so the float converts to `uint32_t` (`operator*(uint32_t)`, saturating at 1):
  `-loop-predication-latch-probability-scale=1.9` scales by 1, the default 2.0 by 2.
- `guard-widening` is both a FUNCTION_PASS and a LOOP_PASS (PassRegistry.def); inside `loop(...)`/`loop-mssa(...)`
  the loop version runs (root = loop predecessor or header, blocks filtered to root + loop, no post-dominator tree).
- None of these passes (nor IRCE / LoopConstrainer / SCEVExpander) call `salvageKnowledge`, so
  `-enable-knowledge-retention` changes nothing for them.
