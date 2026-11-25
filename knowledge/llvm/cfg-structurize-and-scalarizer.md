# StructurizeCFG, RegionInfo, LowerSwitch, FixIrreducible, UnifyLoopExits, Scalarizer, ScalarizeMaskedMemIntrin

Facts verified while porting these passes for impl/jai (`L1.extra.cfg-structurize`, `L1.extra.scalarizer`). Each
was found by a whole-corpus sweep against LLVM 23.1.5 (`./harness/run sweep`), unless a test is named.

## Pass manager traits

- `StructurizeCFGPass` and `UnifyLoopExitsPass` derive from `RequiredPassInfoMixin`: they run on `optnone`
  functions (`CodeExtractor/PartialInlineAttributes.ll` has one). `LowerSwitchPass`, `FixIrreduciblePass`,
  `ScalarizerPass` (`OptionalPassInfoMixin`) and `ScalarizeMaskedMemIntrinPass` are skipped there. `grep -l
  RequiredPassInfoMixin llvm/include/llvm/Transforms` lists the others (HipStdPar, FatLTOCleanup,
  LowerMatrixIntrinsics, the sanitizers, AddDiscriminators, ...).

## RegionInfo (`print<regions>`)

- `createRegion` calls `updateStatistics`, whose `++numSimpleRegions` is compiled out in a release build, but the
  condition `R->isSimple()` is still evaluated: `getEnteringBlock` / `getExitingBlock` (find_singleton over the
  predecessors, stopping at the second match) make `contains()` calls, i.e. dominance queries. They count as slow
  queries of the DominatorTree and show in a later `print<domtree>` ("DFSNumbers invalid: N slow queries"); so do
  the `properlyDominates` calls of `DominanceFrontierBase::analyze`. A port that skips them prints a different N.
- The dominance frontier sets (`SetVector`) are only queried with `contains` / all-of loops, so their order does not
  matter for the region tree.
- `createRegion` uses `BBtoRegion.insert` (does not overwrite): the first (smallest) region with an entry wins.

## StructurizeCFG

- Its DenseMap walks over predecessors (`insertConditions`, `isPredictableTrue`, `dominatesPredicates`,
  `simplifyConditions`, `mergeIfCompatible`'s reassigned incoming list) give the same IR in any order. Two things do
  depend on pointer order:
  - `SSAUpdaterBulk::RewriteAndOptimizeAllUses` → `deduplicatePass` iterates a `SmallDenseMap<BasicBlock *,
    unsigned>`. Deduplicating the new phis of one block can make the new phis of another block identical, so the
    result depends on which block comes first (`JumpThreading/loop-phi.ll`: LLVM keeps two identical phis in
    `Flow1`). impl/jai fails loudly there.
  - `all_of` / early exits over `Predicates` change how many dominance queries run, i.e. only the slow-query count
    of `print<domtree>`. impl/jai fails loudly when printing such a tree with invalid DFS numbers.
- `EliminateNewDuplicatePHINodes(BB, FirstExistingPN)`: `FirstExistingPN` may be `phis().end()` (the first
  non-phi); the loops stop there, they never compare non-phi instructions.
- `User::replaceUsesOfWith(From, To)` returns at once when `From == To` (no `Use::set`, so the use does not move to
  the front of its use list). `changeExit` calls it with OldExit == NewExit, and the use-list order of the exit
  block's predecessors then decides phi entry order in the next region.
- `changeExit` walks `make_early_inc_range(predecessors(OldExit))`: the next use is taken before the body; a use
  that the body moves to NewExit's list continues the walk on NewExit's list.
- `getNextFlow` creates `Flow` blocks before `Order.back()->getEntry()` (or before the region exit); `needPrefix`
  reuses the previous block when it is a plain block (its terminator is killed first).

## UnifyLoopExits, FixIrreducible, ControlFlowHub

- The guard blocks are appended at the end of the function (`BasicBlock::Create(..., F)`), named
  `<prefix>.guard`; `reconnectPhis` inserts `<phi>.moved` at `FirstGuardBlock->begin()`, so the later outgoing
  block's phis come first. Boolean guards are `Guard.<block>` phis appended to the first guard block; with more than
  `-max-booleans-in-control-flow-hub` (32) outgoing blocks UnifyLoopExits uses an `i32` `merged.bb.idx` phi.
- `reconnectChildLoops` uses `std::partition` (libstdc++'s bidirectional algorithm, not stable).
- `CycleInfo::addBlockToCycle` appends to the cycle and all its parents and overwrites the block's BlockMap entry.

## LowerSwitch

- `ConstantInt::get(Ty, V)` results are compared by pointer (`Leaf.Low == LowerBound`), which is value equality for
  uniqued constants.
- `FixPhis(..., UnsignedMax)` uses `APInt::getMaxValue(BitWidth)`: for an `i1` switch only 1 extra entry is removed.
- `DeleteList` is a `SmallPtrSet<BasicBlock *, 8>`: insertion order up to 8 blocks (impl/jai fails loudly beyond).

## Scalarizer

- `ConstantInt::get(Ty, I)` for the variable insert/extract index compares (`%idx.is.N`) does not truncate in a
  release build: an `i1` index with N >= 2 becomes an APInt with bits above its width, printed as `true`
  (`InstCombine/pr51824.ll`). impl/jai fails loudly.
- `unsigned Idx = CI->getZExtValue()` truncates constant indices to 32 bits before the range check
  (`InstCombine/out-of-bounds-indexes.ll`).
- `isTriviallyScalarizable(ID)` = isTriviallyVectorizable or the TableGen property `IntrTriviallyScalarizable`, which
  only DirectX/SPIR-V intrinsics have; no x86 intrinsic is scalarized.
- The scattered fragments of an argument are created at `entry->begin()` (head bit), of an instruction after it
  (past the phis), each fragment lazily on first use, with the debug location of the insertion point.
- `PotentiallyDeadInstrs` are WeakTrackingVHs (they follow RAUW); the final cleanup is
  `RecursivelyDeleteTriviallyDeadInstructionsPermissive` without TLI.
