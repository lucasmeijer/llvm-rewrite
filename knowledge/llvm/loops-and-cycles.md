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
