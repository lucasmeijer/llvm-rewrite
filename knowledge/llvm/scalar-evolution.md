# ScalarEvolution (print<scalar-evolution>, print<loopnest>, print<iv-users>, scev-aa)

Facts verified while porting llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5) for impl/jai; each one was needed
to make the printer output byte-identical on tests/imported/llvm/Analysis/ScalarEvolution and in sweeps over every
round-tripping file.

## Output depends on cache history

- **No-wrap flags are sticky on uniqued nodes** and only ever grow. A node printed before its range is computed can
  show `<nw>` and the same node printed later `<nuw>` (getRangeRef of an affine AddRec calls
  `setNoWrapFlags(getRangeForAffineAR(...).second)` on it, without clearing caches). So
  `print<scalar-evolution>,loop(loop-rotate),print<scalar-evolution>` legitimately differs from
  `loop(loop-rotate),print<scalar-evolution>`: the second print reuses the cached ScalarEvolution and its nodes.
  Reproducer: a two-level loop nest with `%idx = add %i, %j` (tests/analysis/domtree/loop_nest.ll).
- **getBackedgeTakenInfo inserts an empty BackedgeTakenInfo first** (try_emplace), so recursive queries made while
  computing a loop's trip count see "unknown" (all CouldNotCompute). After computing, if the info has anything, it
  calls `forgetMemoizedResults(LoopUsers[L])` (every AddRec of L) and drops ConstantEvolutionLoopExitValue of the
  header PHIs: ranges and flags of those AddRecs are recomputed later with the trip count known.
- **createAddRecFromPHI** maps the PHI to SCEVUnknown(PHI) while analysing the backedge value, then
  `forgetMemoizedResults({SymbolicName})` (transitively through SCEVUsers, which also erases the ValueExprMap entries
  of values whose SCEV used the unknown). A port without SCEVUsers/ExprValueMap gets different results.
- **FoldCache** (zext/sext results keyed by (kind, op, type)) entries are only removed when the *result* is
  forgotten (FoldCacheUser), not the operand.

## Ordering details

- **GroupByComplexity uses llvm::stable_sort = std::stable_sort**, and CompareSCEVComplexity is not a strict weak
  order (it returns "unknown" past `scalar-evolution-max-scev-compare-depth`, treated as not-less). The oracle is
  built with GCC 12's libstdc++ (`strings /opt/llvm-23.1.5/bin/opt | grep GCC`), whose stable_sort with a full buffer
  is: two `__merge_sort_with_buffer` halves (chunk insertion sort of 7, then pairwise `__merge_sort_loop`), then
  `__merge_adaptive`. Reproduce that algorithm to be safe.
- CompareValueComplexity orders by: pointer type last, `Value::getValueID()` (Value.def order: UndefValue=0,
  PoisonValue, ConstantAggregateZero, ConstantDataArray, ConstantDataVector, ConstantInt, ConstantByte, ConstantFP,
  ConstantTargetNone, ConstantPointerNull, ConstantTokenNone, ConstantArray, ConstantStruct, ConstantVector,
  Function=14, GlobalAlias, GlobalIFunc, GlobalVariable, BlockAddress, ConstantExpr, DSOLocalEquivalent, NoCFIValue,
  ConstantPtrAuth, Argument=23, BasicBlock, MetadataAsValue, InlineAsm, MemoryUse/Def/Phi, Instruction=30+opcode),
  argument number, linkage then name (only for non-private/internal globals), loop depth of the block, operand
  count, then operands recursively (`scalar-evolution-max-value-compare-depth`, default 2).
- **SCEVTraversal::visitAll stops pushing a node's remaining operands as soon as the visitor isDone()** (not only
  between worklist pops). SCEVMinMaxExprContains depends on it (its `follow` overwrites `Found` for every node):
  without the early stop, `select (x == 0), 0, umin(y, x)` is not recognised as `x umin_seq y`
  (Analysis/ScalarEvolution/logical-operations.ll).
- The printer prints the instruction, then the SCEV, then computes and prints U/S ranges, then getSCEVAtScope of
  the instruction's loop, then the exit value at the parent loop and the loop dispositions (own loop and parents
  upward, then the subloops in depth-first preorder). CmpInsts are skipped. Ranges print as signed `[lo,hi)`,
  `full-set`, `empty-set`. Trip counts that are constants get a type prefix (`i32 7`).

## Pass manager interaction

- FunctionToLoopPassAdaptor always computes ScalarEvolution (LoopStandardAnalysisResults has `SE` by reference) in
  the order AA, AssumptionCache, DominatorTree, LoopInfo, ScalarEvolution, TLI, TTI. So every loop pass has an SE:
  `loop-rotate<check-exit-count>` (profitableToRotateLoopExitingLatch calls `SE->getExitCount`) depends on SCEV.
- LoopSimplifyPass and LCSSAPass only use a *cached* SE (getCachedResult) and preserve it. LoopSimplify calls
  forgetLoop before separating a nested loop, forgetValue on a header PHI it simplifies, forgetTopmostLoop when it
  changed anything, and Loop::makeLoopInvariant calls forgetBlockAndLoopDispositions(I) on every hoisted
  instruction. LCSSA calls `SE->getSCEV(PN)` on each new LCSSA PHI when the original value had a cached SCEV.
  LoopRotate: forgetTopmostLoop + forgetBlockAndLoopDispositions() before rotating, forgetValue on each rewritten
  header value, forgetBlockAndLoopDispositions() after simplifyLoopLatch merges the latch.
- ScalarEvolution::invalidate: invalidated unless preserved, or when AssumptionAnalysis / DominatorTree / LoopInfo
  are invalidated. AssumptionCache::invalidate always returns false, so in practice only DT and LoopInfo matter.
- Value handles: deleting a value erases it from ValueExprMap (and ConstantEvolutionLoopExitValue); RAUW calls
  forgetValue(old). A SCEVUnknown whose value is deleted or RAUW'd is forgotten (forgetMemoizedResults), removed
  from the uniquing set, and keeps the new value (or null).

## Small things

- `print<loopnest>` uses Loop::getName(): the header's name, or `<unnamed loop>`. IsPerfect compares
  getMaxPerfectDepth with the nest depth; Loops are in breadth-first order.
- IVUsers' PostIncLoops is a SmallPtrSet with inline capacity 2: printed in insertion order for up to 2 loops.
- SCEVAA recurses on the base values with `LocationSize::beforeOrAfterPointer()` and empty AA tags.
- LLVM 23's SCEVUse (a SCEV pointer with use-specific NUW/NSW bits) exists, but nothing in 23.1.5 constructs a use
  with flags (grep `SCEVUse(` in lib/), so every SCEV is its own canonical and operands can be plain pointers.
