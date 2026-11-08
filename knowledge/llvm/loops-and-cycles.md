# LoopInfo, CycleInfo, LoopSimplify, LCSSA: behaviour that decides output

Verified against opt 23.1.5 with the Goose port (`impl/goose/src/{loopinfo,cycleinfo,loopsimplify,lcssa}.goose`)
passing `tests/analysis/{loops,cycles}`, `Analysis/{LoopInfo,CycleInfo}` and the loop-simplify/lcssa tests that
need nothing else, plus random CFGs (`impl/goose/tools/fuzz_cfg.py`).

## LoopInfo (`GenericLoopInfoImpl.h`)

- `analyze` walks the dominator tree in reverse pre-order (after `DT.updateDFSNumbers()`, which makes a later
  `print<domtree>` show valid DFS numbers); a header's backedges are its predecessors (use-list order) that it
  dominates. `discoverAndMapSubloop` is a LIFO worklist seeded with the backedges in order, pushing all
  predecessors of each newly mapped block.
- Block and subloop vectors are filled by one `post_order(entry)` walk (successor order): blocks are appended in
  post-order and, when a header is reached, its loop's blocks after `[0]` and its subloops are reversed. Result:
  `Blocks[0]` is the header, then reverse post-order; subloops in program order; **top-level loops in reverse
  program order** (pushed in post-order, never reversed). `print<loops>` prints them in that stored order.
- A loop's header *is* `Blocks[0]`: `moveToHeader` swaps a block into slot 0 (SplitBlockPredecessors and
  separateNestedLoop rely on it).
- `print<loops>`: `Loop info for function 'f':`, then per loop `Loop at depth N containing: ` and the blocks as
  operands joined by `,`, each followed by `<header>`, `<latch>` (any predecessor of the header), `<exiting>`; nested
  loops indented by 4 more spaces per level (`Depth*2` with Depth += 2). `Parallel ` prefixes loops whose
  `llvm.loop` ID (the same node on every latch, self-referencing) has `llvm.loop.parallel_accesses` covering every
  memory instruction's `llvm.access.group`, or whose instructions carry `llvm.mem.parallel_loop_access` listing it.
- LoopAnalysis, CycleAnalysis, DominatorTreeAnalysis and PostDominatorTreeAnalysis are all invalidated unless
  preserved explicitly or through `preserveSet<CFGAnalyses>`.

## CycleInfo (`GenericCycleImpl.h`)

- DFS from the entry: successors pushed in order onto a stack and visited LIFO (so the *last* successor is visited
  first); pre-order list; headers are candidates in reverse pre-order with a predecessor that is a DFS descendant.
- A new cycle's blocks are discovered backwards (LIFO, predecessors in use-list order); a block already in a cycle
  pulls that cycle's top-level ancestor in as a child (moved out of the top-level list by swap-with-last-and-pop,
  so the top-level order changes) and its entries' predecessors are processed. A predecessor outside the DFS
  subtree that is reachable makes the block an additional entry.
- `print<cycles>`: `CycleInfo for function: f`, then per cycle (top-level list order, pre-order inside)
  `"    " * depth` + `depth=D: entries(<entries, space separated>)` + ` <block>` for each non-entry block in
  discovery order. Blocks print as their bare name, or the slot number when unnamed (no `%`).

## LoopSimplify and LCSSA

- `loop-simplify` processes each top-level loop (stored order) with a worklist of the loop and all nested loops
  (breadth-first append, processed from the back: innermost last-added first). New blocks: `<header>.preheader`
  (placed after the out-of-loop predecessor that falls into the loop, else after the first one), `<exit>.loopexit`,
  `<header>.backedge` (moved after the last backedge block), `<header>.outer` (separateNestedLoop), PHIs
  `<phi>.ph` / `<phi>.be`. SplitBlockPredecessors creates the block *before* the split block and branches to it
  before redirecting predecessors; PHI entries are removed by LLVM 23's swap-last-into-hole rule.
- The new-PM LoopSimplifyPass preserves DT, LoopInfo, SCEV, BPI (not the PDT, not CFGAnalyses); it updates the DT
  with `DT->splitBlock` (legacy, not DomTreeUpdater), whose `dominates` calls count slow queries.
- Header PHIs are simplified with `simplifyInstruction` (only `simplifyPHINode` matters): all incoming values equal
  ignoring self-references, poison and undef; with undef/poison inputs the value must dominate the PHI (and not be
  poison if an input was undef).
- LCSSA inserts `<name>.lcssa` PHIs at the start of each exit block the definition dominates (one incoming per
  predecessor, in use-list order), rewrites outside uses to the PHI of their exit block or to the single new PHI,
  and needs the SSAUpdater only when several exit PHIs exist and the use is elsewhere; unused new PHIs are erased.
  The pass preserves CFGAnalyses.

## Loop pass manager (`loop(...)`, `loop-mssa(...)`)

Verified with the Jai port (`impl/jai/src/loop_pm.jai`) against `-opt-bisect-limit` output and the LoopRotate tests.

- `FunctionToLoopPassAdaptor::run` first runs its LoopCanonicalizationFPM (`loop-simplify`, then `lcssa`) as
  ordinary function passes: both are counted by `-opt-bisect-limit` and skipped on `optnone`, and each one's
  PreservedAnalyses invalidates the function analyses before the next. The adaptor itself and a `LoopPassManager`
  are "required" (not counted). If the function has no loops after canonicalization, the adaptor returns the
  canonicalization's PreservedAnalyses unchanged (no extra DT/LoopInfo preservation).
- OptBisect describes a loop as `loop %<header name> in function <f>` (`<unnamed loop>` for an unnamed header):
  `BISECT: running pass (4) loop-rotate on loop %outer in function f`.
- Worklist order: `appendLoopsToWorklist(LI)` walks the top-level loops in LoopInfo's stored order (= reverse program
  order), builds each nest's preorder with a LIFO walk (subloops pushed in order, so the *last* subloop is visited
  first) and inserts the sequence into a SmallPriorityWorklist that is popped from the back. Net effect for
  `f` with nest outer{inner} followed by a sibling `second`: inner, outer, second.
- A bare loop pass in a function pipeline (`-passes=dce,loop-rotate`) gets its own adaptor with UseMemorySSA =
  false; a pipeline whose first element is a loop pass becomes `function(loop(...))` (`loop-mssa` for `licm`).
- With `loop-mssa`, MemorySSA is computed by the adaptor (getResult) and every loop pass must preserve it, else
  `LLVM ERROR: Loop pass manager using MemorySSA contains a pass that does not preserve MemorySSA`.
- LoopStandardAnalysisResults includes ScalarEvolution (always computed by the adaptor); nothing observable
  depends on that unless a pass queries it (LoopRotate only with `<check-exit-count>`).

## LoopRotate

Verified with `tests/imported/llvm/Transforms/LoopRotate` and a sweep of `loop(loop-rotate)` over every
round-tripping file (identical output on all ~7750 files that don't hit an unported path).

- The header-size check is `CodeMetrics::analyzeBasicBlock` = sum of `TTI.getInstructionCost(I, TCK_CodeSize)`
  over non-ephemeral instructions, compared with `-rotation-max-header-size` (16). On x86: PHIs and free intrinsics
  (lifetime, assume, noalias.scope.decl, ...) cost 0, branches/returns/switches 1, a direct call to a non-intrinsic
  `numParams + 1` (1 for libm-like names that are not "lowered to calls"), scalar arithmetic/compares/casts/loads
  1 (or 2 for custom-lowered operations). Threshold 0 (`<no-header-duplication>`, or `minsize` functions) never
  rotates, because the header's conditional branch alone costs 1.
- `simplifyLoopLatch` runs first (folds a latch that only holds one "increment" plus casts into its single
  exiting predecessor via `MergeBlockIntoPredecessor(..., PredecessorWithTwoSuccessors=true)`), then
  `rotateLoop`. Hoisting vs cloning of header instructions: hoisted if the operands are loop invariant and it
  neither reads nor writes memory, isn't a terminator or alloca; clones are `simplifyInstruction`ed with
  `SimplifyQuery{DL, TLI, DT, AC}` (no context instruction) and keep the original's name (so get a numeric suffix).
- Debug records: `Instruction::moveBefore` (not `moveBeforePreserving`) leaves the moved instruction's records
  behind (they fall onto the next instruction) and the moved instruction absorbs the records at the insertion
  point; `insertBefore(It)` without the head bit does the same absorption. The preheader branch's records end up
  appended to the cloned terminator (erase + `flushTerminatorDbgRecords`). `cloneDebugInfoFrom` only clones the
  records an instruction had originally (records that "fell down" from hoisted instructions are skipped), and after
  the first cloned instruction no later cloned instruction gets its records cloned until a hoist resets the range.
- `MergeBlockIntoPredecessor`'s splice: the predecessor terminator's records move to the front of the first moved
  instruction's records, the merged block's terminator records move onto the predecessor terminator; an empty
  block (only a terminator) appends its terminator's records to the predecessor terminator's.

## LoopSimplify details

- `isSafeToSpeculativelyExecute`'s `IgnoreUBImplyingAttrs` defaults to true, so `makeLoopInvariant` hoists a
  speculatable call with `dereferenceable`/`noundef` arguments and then strips those attributes
  (`dropUBImplyingAttrsAndUnknownMetadata`, keeping `!prof` only when hoisting from the header);
  `tests/imported/llvm/Transforms/LoopSimplify/drop-ub-attributes.ll`.
- Exit merging calls SimplifyCFG's `foldBranchToCommonDest` with no TTI: the exiting block's compare is *cloned*
  into the predecessor (taking the name, the original becomes `<name>.old` before the block is deleted), the
  conditions are joined with `or`/`and` when `impliesPoison(BICond, PBICond)`, else with a `select` named
  `or.cond`; branch weights are combined as in SimplifyCFG and set with `ElideAllZero`.

## LICM

Verified with the jai port (impl/jai/src/pass_licm.jai) on Transforms/LICM and sweeps of `licm`, `loop-mssa(lnicm)`,
`licm -licm-control-flow-hoisting=1` over the corpus (identical output).

- Order: sinkRegion over `collectChildrenInLoop` (DT breadth-first list of in-loop blocks) in reverse, instructions
  bottom-up; then hoistRegion over LoopBlocksRPO, instructions top-down with early increment; then promotion repeated
  until nothing is promoted, then `formLCSSARecursively`. Subloop blocks are skipped except in LNICM.
- hoistArithmetics and promotion re-read `getLoopPreheader()` (the ControlFlowHoister may have made a new one);
  hoistRegion's speculation context is the preheader terminator from when hoistRegion started.
- Sinking splits exit predecessors with a *lazy* DomTreeUpdater; `SplitBlockPredecessors` flushes it inside
  UpdateAnalysisInformation (`DTU->getDomTree()`), so the tree gets `{Insert New->BB, Insert P->New, Delete P->BB}`
  through applyUpdates, not `DT->splitBlock`.
- Promotion stores go at each exit's first insertion point captured *before* any promotion (head bit: before the
  block's debug records); later promotions' stores come after earlier ones. The preheader load is named
  `<ptr>.promoted` and loses its debug location; stores get the merged location of all promoted accesses.
- `-use-dereferenceable-at-point-semantics` only affects getPointerDereferenceableBytes' CanBeFreed out-parameter,
  which only Loads.cpp and LoopAccessAnalysis request (BasicAA passes nullptr).
- With only loop-nest passes (`loop-mssa(lnicm)`), the adaptor visits just the top-level loops; `lnicm` in a mixed
  pipeline runs on the outermost loop of every visited loop.
- LICM's only TTI query is isFoldableInLoop's `getInstructionCost(GEP, TCK_SizeAndLatency)` (sinking); a port can
  set the TTI up lazily. Its isSafeToSpeculativelyExecute gets DT *and* TLI, so allocation calls count as
  dereferenceable through getObjectSize with TLI (verified with the goose port, `sweep --passes licm`).
- Loop-nest mode: an adaptor whose LoopPassManager has only loop-nest passes (`loop-mssa(lnicm)`) puts just the
  top-level loops (LoopInfo order) into the worklist; in a mixed manager a loop-nest pass runs only when the
  current loop is top-level (`LoopPassManager::run`). A bare `lnicm`/`licm` in a function pipeline gets an adaptor
  without MemorySSA and stops with `LLVM ERROR: L(N)ICM requires MemorySSA (loop-mssa)`; at the top level of
  `-passes=` both are wrapped in `function(loop-mssa(...))`.
- ICFLoopSafetyInfo's per-block first-special-instruction caches are filled lazily and only reset by
  insertInstructionTo of a special instruction or removeInstruction of the cached one (InstructionPrecedenceTracking);
  a port must reproduce the staleness, not recompute.

## Loop deletion, loop-simplifycfg, loop-instsimplify, loop-idiom (verified by the Jai port, L1.loop-misc)

- `Loop::makeLoopInvariant` hoists with `I->moveBefore(InsertPt->getIterator())` (not moveBeforePreserving): the
  hoisted instruction's debug records stay behind on the next instruction, and it is inserted after the records
  attached to the preheader terminator (`debugify,function(loop-simplify)` on LICM/hoist-metadata.ll).
- `deleteDeadLoop` (LoopUtils.cpp): the preheader first gets `br i1 false, header, exit` (DT insert edge), then
  `br exit` (DT delete edge to the header); exit phis keep only entry 0, renamed to the preheader; uses outside the
  loop become poison; one debug record per DebugVariable moves to the exit's first insertion point, in original
  order before that instruction's records; the loop and all its subloops are destroyed (no relinking). A deleted
  block whose address is taken leaves `inttoptr (i32 1 to ptr)` behind (LoopDeletion/blockaddress.ll).
- `breakLoopBackedge`: an exiting conditional latch becomes `br exit` after `Header->removePredecessor(Latch,
  /*KeepOneInputPHIs=*/true)`; other latches are split (SplitEdge) and the new block made unreachable; then
  `LI.erase(L)` and LCSSA is rebuilt for the outermost loop if L was nested.
- LoopSimplifyCFG's foldTerminators collects dead successors in a `SmallPtrSet<BasicBlock *, 2>` and pushes one DT
  delete update per entry: with more than two dead successors the order is pointer order (not reproducible). The
  resulting tree is the same; only child order could differ. The current loop is never deleted (it gives up).
- LoopInstSimplify replaces uses with `Use::set` (no RAUW): debug records keep pointing at the old instruction and
  are salvaged when it is deleted by RecursivelyDeleteTriviallyDeadInstructions.
- LoopIdiomRecognize: once SCEVExpander has expanded the base pointer, the pass reports a change even when the
  idiom is then rejected and the expansion is cleaned up (SCEVExpanderCleaner). `optimizeCRCLoop`'s result is
  ignored: a loop where only the CRC table rewrite happened still returns PreservedAnalyses::all().
  HashRecognize runs on every countable loop (unless optimizing for size), so its getSCEV /
  getSmallConstantTripCount calls happen even when nothing is rewritten.
- `getAtomicMemIntrinsicMaxElementSize` is 16 for X86 and 0 without a target (unordered atomic memcpy idiom only
  with a triple); `getPopcntSupport(32)` is FastHardware only with the POPCNT feature (`-mcpu=corei7`).
- opt clears `-mcpu`/`-mattr` when the module triple has no known architecture: no `"target-cpu"` attribute is
  added to functions of a triple-less module (optdriver.cpp).
- In a module pipeline (`debugify,loop-idiom`), each loop pass gets its own
  `ModuleToFunctionPassAdaptor(FunctionToLoopPassAdaptor(pass, /*UseMemorySSA=*/false))` (PassBuilder
  parseModulePass, LOOP_PASS).
- ScalarEvolution's range of a pointer SCEVUnknown with dereferenceable(_or_null) bytes uses
  `isKnownNonZero(V, DL)` (DataLayout only: no context instruction, DT or AC) to raise the minimum to the alignment
  (ScalarEvolution::getRangeRef); a dominating `icmp eq %p, null` branch doesn't count
  (`tests/e2e/O2/test-suite/SingleSource/Benchmarks/CoyoteBench/lpbench.ll`, `loop-mssa(licm),print<scalar-evolution>`).
