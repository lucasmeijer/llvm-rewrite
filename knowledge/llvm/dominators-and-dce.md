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
