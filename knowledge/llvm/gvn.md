# GVN, MemoryDependenceAnalysis, VNCoercion, PHITransAddr

Facts about LLVM 23.1.5's `gvn` that decide output, found while porting it (impl/jai, L1.gvn). Verified with the
unit tests (`tests/imported/llvm/Transforms/GVN`) and `sweep --passes gvn` / `gvn<memoryssa>` (whole files and
`--per-function`), unless a source line is given.

## Options and analyses

- `gvn<memoryssa>` sets AllowMemorySSA and *clears* AllowMemDep (`parseGVNOptions`, PassBuilder.cpp:1415-1422);
  `gvn<memdep>` the reverse. `-enable-gvn-memoryssa` alone keeps MemDep on too (both are then live: calls are still
  numbered through MemDep in `lookupOrAddCall`, loads use MemorySSA).
- A *cached* MemorySSA (e.g. `require<memoryssa>,gvn`) is updated by GVN even in MemDep mode (MSSAU is non-null
  whenever MSSA is), and GVN preserves it.
- `-disable-basic-aa` has no effect under the new pass manager: it is only read by the legacy
  `AAResultsWrapperPass` (AliasAnalysis.cpp:838). `require<phi-values>` computes an analysis nobody reads any more.
- MemoryDependenceResults are not preserved by a changing GVN; each GVN run that changes IR starts from empty caches.

## Value numbering

- Expression equality also requires call attributes to be intersectable (`Expression::operator==`); the hash
  ignores attributes. The table is never erased from, so a lookup meets equal-hash entries in insertion order.
- `ExprIdx[V] == 0` is the "no expression" marker, but the *first* expression ever created also gets index 0, so
  `phiTranslateImpl` never translates value number of the first expression of an iteration.
- `phiTranslateImpl`'s `ExpressionNumbering[Exp]` inserts a 0-valued entry when the translated expression is new.
- `extractvalue (x.with.overflow a, b), 0` numbers like `op a, b` with the operands *unsorted* and not commutative.
- `createGEPExpr` uses `GEPOperator::collectOffset`: only a scalar `ConstantInt` index is a constant offset; a
  `splat (i64 1)` vector index is a variable offset keyed by the constant vector (Operator.cpp:244), so
  `gep <16 x i32>, ptr %p, i64 1` and the same GEP with a splat index are different values (GVN/opaque-ptr.ll).

## Loads

- MemDep's EarliestEscapeAnalysis lives as long as the MemoryDependenceResults: an object's earliest capture is
  computed at the first query and cached, and only `removeInstruction` of the capturing instruction drops it.
  Capture tracking gives up ("captured") after 100 uses; the answer is computed on the IR *at the first query*,
  so loads that GVN later deletes still count. Recomputing per query forwards more loads than LLVM
  (e2e/O2/.../sumarraymalloc.ll: a malloc'd buffer with >100 uses across a call). The MemorySSA path
  (`findReachingValuesForLoad`) builds a fresh EEA (with LoopInfo) per load.
- `findLoadToHoistIntoPred` rejects predecessors whose terminator `isSpecialTerminator()`, which includes
  `invoke`, `resume` and `callbr` (Instruction.h:419), so an invoke predecessor gets its critical edge split
  instead (GVN/PRE/pre-load.ll).
- `Type::isScalableTy` is true for a target extension type whose layout type is scalable (`aarch64.svcount`), so
  VNCoercion refuses to forward such stores (GVN/svcount-access.ll).
- After PHI construction `V->takeName(Load)`: when the load has no name, a pre-existing phi *loses* its own name
  (Value::takeName drops the destination's name first).
- The scalar-PRE clone has no name, so the inserted instruction is `%.pre` and the phi `%<name>.pre-phi`.
- NonLocalDepEntry sorts by BasicBlock pointer. No sweep difference came from it with blocks ordered by creation.

- `AnalyzeLoadAvailability` for a clobbering load uses MemDep's `ClobberOffsets` (filled by the *last*
  `getDependency`/non-local query: `getDependency` clears the map first) in MemDep mode, and the offset carried in
  the ReachingMemVal (from `scanMemoryAccessesUsers`' PartialAlias) in MemorySSA mode.
- The MemDep caches (`NonLocalDepInfo`) hold one entry per block, so any sort by block gives the same order: an
  O(n) radix sort on block ids is equivalent to `llvm::sort`. LLVM sorts a lot here (`removeInstruction` re-sorts
  every pointer cache that mentioned the removed instruction): ~0.8 G instructions of introsort on
  `tests/perf/scaling/allocas/n2000.ll` (callgrind), so a slow comparison sort doubles GVN's time there.
- PHITransAddr's GEP lookup scans every user of the translated base pointer, with a dominance query each: GVN is
  quadratic in LLVM too on many GEPs of one base (`scaling/loops-many`: 6x the instructions for 4x the size,
  ~55% in `translateSubExpr`). The order of the checks matters only because `DominatorTree::dominates` counts
  slow queries (visible in a later `print<domtree>`): keep LLVM's order (types, operand count, function,
  dominance, then the operands).

## Interaction with other analyses

- The AssumptionCache follows GVN's `replaceAllUsesWith`s through its AffectedValueCallbackVH: when an assume's
  condition mentions a value that GVN replaces (instsimplify of `lshr x, x` -> 0, `shl x, 0` -> x), the
  replacement inherits the assume, and `simplifyInstruction` of a later compare can then fold it with known bits
  from that assume (InstCombine/assume.ll `assumption_conflicts_with_known_bits` under `-passes=gvn`: the
  first assume becomes `assume(false)`, i.e. `store i8 poison, ptr null`). An implementation that RAUWs without
  updating its assumption cache keeps the compare and propagates the wrong equality instead.
- `processAssumeIntrinsic` of `assume(false)` inserts `store i8 poison, ptr null` (align 1) *before* the assume
  (adopting its debug records), then erases the assume only when its bundles are all `ignore` (or absent).

## CFG

- The initial MergeBlockIntoPredecessor loop uses a *lazy* DomTreeUpdater: all updates are applied in one
  `applyUpdates` batch after the loop and the merged blocks stay in the function (holding only `unreachable`)
  until then.
- Critical-edge splitting from PerformLoadPRE does not preserve loop-simplify form; the edges queued by scalar PRE
  are split with default options (LoopSimplify preserved).
