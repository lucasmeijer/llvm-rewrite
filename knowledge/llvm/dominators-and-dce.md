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
- `print<domtree>` always shows `DFSNumbers invalid` and `{4294967295,4294967295}` right after a fresh computation.
  `IDFCalculator::calculate` calls `updateDFSNumbers()`, so a tree that ADCE used and preserved would print real
  DFS numbers (no test shows it yet).
- After `break-crit-edges`, the cached tree is updated with `applyUpdates` (incremental, `InsertEdge`/`DeleteEdge`
  on a `GraphDiff` view), which can give a different child order than recomputing. Implementations that recompute
  fail `tests/analysis/domtree/after_transform.ll`.

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
