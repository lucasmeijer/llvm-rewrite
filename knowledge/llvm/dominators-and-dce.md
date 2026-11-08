# Dominator trees, DCE/ADCE/BDCE, DemandedBits: behaviour that decides output

Verified against opt 23.1.5 with the Goose port (`impl/goose/src/domtree.goose`, `adce.goose`, `bdce.goose`,
`demandedbits.goose`) passing `tests/analysis/{domtree,postdomtree,demanded-bits}`, LLVM's
`Analysis/{Dominators,PostDominators,DemandedBits}` and `Transforms/{DCE,ADCE,BDCE}` tests.

## Dominator tree construction (`GenericDomTreeConstruction.h`, SemiNCA)

- **Child order** = order of tree-node creation = DFS preorder number (`attachNewSubtree` walks `NumToNode`).
  Children are appended to the idom's child vector.
- **The DFS** (`runDFS`) uses a LIFO worklist. Forward edges (dominators) push `successors` **reversed**, so they are
  visited in successor order. Reverse edges (post-dominators) push `predecessors` in pred order, **not reversed**,
  so the *last* predecessor is visited first. `predecessors(BB)` is the block's use list filtered to terminator
  users: head first, one entry per edge. So the post-dominator tree depends on use-list order.
- Every popped worklist entry (also already-visited ones) adds a reverse-child record; SemiNCA's `eval` uses them.
- **Post-dominator roots** (`FindRoots`): first every block without successors, in function order, each followed by
  a reverse DFS from it. Then for each still-unvisited block in function order: a forward DFS (successors sorted by
  function position, `SuccOrder`) from it; the *last* block numbered becomes a root; the forward DFS numbering is
  discarded and a reverse DFS from that root follows. If any non-trivial root was added, `RemoveRedundantRoots`
  drops roots forward-reachable from another root (swap with last, pop). The virtual root `<<exit node>>` gets the
  roots as children in DFS order.
- `print<domtree>` prints `DFSNumbers invalid: <SlowQueries> slow queries.` and `{4294967295,4294967295}` only
  while `DFSInfoValid` is false. `updateDFSNumbers()` makes them valid (pre-order numbering, `{in,out}` with out =
  the next number after the subtree) and resets SlowQueries; LoopAnalysis (`LoopInfoBase::analyze`) and every IDF
  computation (`IDFCalculatorBase::calculate`: mem2reg, ADCE on the PDT) call it, so `print<loops>,print<domtree>`
  or `mem2reg,print<domtree>` show real numbers (`tests/analysis/domtree/dfs_numbers_after_loops.ll`). Any
  incremental update (InsertEdge, a DeleteEdge that changes something, addNewBlock, changeImmediateDominator,
  eraseNode) sets DFSInfoValid = false but leaves the old numbers in the nodes, so a preserved tree can print stale
  numbers with "invalid" (`tests/analysis/postdomtree/after_adce.ll`). `dominates(A, B)` counts a slow query when it
  needs a tree walk; the 33rd slow query calls updateDFSNumbers.

## Incremental updates (`applyUpdates`, `GraphDiff`, `DomTreeUpdater`)

Verified with impl/goose (domtree.goose, dtu.goose) against random CFGs (`impl/goose/tools/fuzz_cfg.py`) and the
break-crit-edges/adce/loop-simplify tests.

- Child lists are intrusive in LLVM 23 (`FirstChild`/`Sibling`): `addChild` appends, `setIDom` unlinks from the old
  parent and appends to the new one, `eraseNode` unlinks. (Older LLVMs used a vector with swap-remove; not 23.)
- `applyUpdates(Updates)` builds a `GraphDiff` with `LegalizeUpdates`: per edge (swapped for post-dominators) the
  insertions minus deletions; edges netting 0 vanish; the rest are ordered by the index of each edge's *last*
  update, descending, and popped from the back, so they apply in the order of their last occurrence. One legalized
  update takes a fast path without the snapshot. With more, the tree is recalculated first when
  `NumLegalized > DomTreeNodes.size()` (trees of at most 100 nodes) or `> size/40`; `DomTreeNodes.size()` is
  indexed by block number + 1 and grows to `max(Function::getMaxBlockNumber(), Idx + 1)`, so it counts blocks ever
  numbered, not live nodes.
- During a batch, the DFS sees the CFG *before* the not-yet-applied updates: successors reversed (LIFO), the
  snapshot's deleted children removed (all copies), its inserted children appended in insertion order.
- `InsertReachable`'s bucket queue is a `std::priority_queue` on node level (libstdc++ binary heap); ties pop in
  heap order, and the order of `Affected` decides the new child order. Port push/pop_heap exactly.
- break-crit-edges (`SplitKnownCriticalEdge`) creates the branch before inserting the block (its use of the
  destination goes to the head of the use list), names the block `<pred>.<succ>_crit_edge`, and applies
  `{Insert pred→new, Insert new→succ, Delete pred→succ (if no edge left)}` to the cached DT only (the new-PM pass
  never has a PDT); it preserves DT and LoopInfo, not CFGAnalyses.
- ADCE deletes the edges of dead branches with an eager DomTreeUpdater on the cached DT and the PDT (edges in
  per-block insertion order of a `SmallPtrSet`; LLVM's order is only deterministic for <= 4 removed successors per
  block) and preserves both trees even when the CFG changed (LoopInfo is invalidated).
- `DomTreeUpdater` (lazy) applies pending updates in runs: plain updates as one `applyUpdates` batch, critical-edge
  splits through `splitDTCriticalEdges` (addNewBlock + changeImmediateDominator) for the DT and as updates for the
  PDT; deleted blocks are erased only once no updates are pending.

## DCE / ADCE / BDCE

- **Names**: removing an instruction removes its name from the function's symbol table, so a later new value can
  reuse it. BDCE's `sext -> zext` creates the zext while the sext still exists, so it is named `<name>1`
  (`%ext1`; `tests/imported/llvm/Transforms/BDCE/sext_multi_uses.ll`).
- BDCE calls `wouldInstructionBeTriviallyDead(&I)` **without TLI**: library allocation/free functions and
  `isMathLibCallNoop` don't count there, only `allockind` attributes. DCE passes TLI.
- `malloc`/`calloc` are not in MemoryBuiltins' `AllocationFnData` in LLVM 23 (only `new`/`delete` variants and
  `strdup`/`strndup`); C allocators are recognised through `allockind("alloc")`. `isMathLibCallNoop` evaluates
  `tan`/`pow` with the host libm and checks the FP exception flags (`calls-errno.ll`).
- `PHINode::removeIncomingValue` in LLVM 23 moves the **last** entry into the removed slot (not a shift).
- ADCE `makeUnconditional` inserts the new `br` before the old terminator, copies its `!dbg`, then erases the old one;
  `removePredecessor` runs first for every non-preferred successor (may fold PHIs to a constant value).
  The preferred successor is the one with the highest post-order number of the reverse CFG
  (`inverse_post_order_ext` from each block without successors, in function order, numbering from 0).
- ADCE drops a debug record unless its `DebugLoc` scope is in `AliveScopes`, which is filled from the `!dbg` of every
  instruction marked live (scope chain up to the `DISubprogram`, and `inlinedAt` chains)
  (`ADCE/debug-info-intrinsic.ll`).

## DemandedBits

- `print<demanded-bits>` lines: `DemandedBits: 0x<lower-case hex> for <instruction as printed by opt>` and, per
  operand, `DemandedBits: 0x… for <operand as operand, no type> in <instruction>`. Order is a DenseMap's (tests
  compare sorted lines).
- The context instruction for the known-bits queries inside DemandedBits is the *user*, which matters for
  `isImpliedByDomCondition` (single predecessor's branch condition) in `computeKnownBitsAddSub` for `sub nsw`.

## More facts (verified with the Jai port, `impl/jai/src/domtree.jai`, `demanded_bits.jai`, `print_util.jai`)

- **ApplyUpdates' recalculation threshold uses `DomTreeNodes.size()`**, a vector indexed by block number + 1
  (`GraphHasNodeNumbers<BasicBlock*>`). It is resized only when a node is *inserted* whose index doesn't fit, to
  `max(F.getMaxBlockNumber(), Idx + 1)`. So it lags behind the function's block count: blocks that never get a tree
  node (e.g. split edges out of unreachable blocks) don't grow it. With `size <= 100` the tree is recomputed when
  `NumLegalized > size`, otherwise when `NumLegalized > size / 40`. Getting this wrong changes child order after
  `break-crit-edges` on a ~100-block function (`SLPVectorizer/X86/many-uses-parent-node.ll` with
  `require<domtree>,break-crit-edges,print<domtree>`).
- **Block numbers** (`BasicBlock::getNumber`) are assigned when the block is created with a parent. LLParser creates a
  block at its first mention: its label, or earlier an operand (`br`, `switch`, phi incoming block, ...) that names it.
  So numbers follow first-mention order, not layout order.
- **`LegalizeUpdates`** keys updates by the (From, To) pair (swapped for post-dominators), drops pairs whose
  inserts and deletes cancel, and sorts by the index of the pair's *last* update, descending; updates are then popped
  from the back, i.e. applied in order of last occurrence. A pair key built from two 32-bit ids must not collide.
- **`print<demanded-bits>` widths come from the DataLayout** (`getTypeSizeInBits` of the scalar type): a pointer in
  addrspace(1) with `p1:16:16` prints `0xffff`; labels are pointer-sized. `getLimitedValue()` caps the hex at
  `0xffffffffffffffff` for wider values.
- **Analysis printers print instructions with a fresh SlotTracker each time** (`Value::print`):
  metadata numbering restarts per printed function (only that function's metadata, after globals and named
  metadata), unless the instruction is an intrinsic call with an MDNode operand (`isReferencingMDNode`), in which
  case every function's metadata is numbered first, in module order. So `!tbaa !0` in one function's printer output
  can be `!3` in the module printer.
- `print<demanded-bits>` on a call with a `token` operand reads `getTypeSizeInBits(token)`, which is
  `llvm_unreachable` (prints garbage in a release build); don't write tests for it.
