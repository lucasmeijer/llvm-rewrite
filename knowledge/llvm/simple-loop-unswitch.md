# SimpleLoopUnswitch: behaviour that decides output

Verified with the Goose port (impl/goose/src/simple_loop_unswitch*.goose): 63/67 `::opt` checks of
`Transforms/SimpleLoopUnswitch` (the rest run other passes) and 0 differences on every round-tripping corpus file
with `simple-loop-unswitch<nontrivial>` and `loop-mssa(simple-loop-unswitch<nontrivial>)` (also per function,
with the files' own flags, and through `print<memoryssa>`).

- Parameters: `simple-loop-unswitch<[no-]nontrivial;[no-]trivial>`, default NonTrivial = false, Trivial = true;
  `-enable-nontrivial-unswitch` forces non-trivial unswitching. Non-trivial unswitching is skipped for optsize
  (and minsize) functions.
- Trivial unswitching walks from the header while blocks have no side effects (or convergent calls); with MemorySSA
  it also stops at a block whose MemorySSA defs list is anything but a single MemoryPhi. A switch's unswitched
  successors are found with the same predicate for the default and the cases; two SwitchInstProfUpdateWrappers
  (old and new switch) are alive at the same time.
- Names: the cloned blocks get `.us`, the merge phis in split exits `.us-phi` (the split keeps the original exit
  name on the merge block via takeName and renames the cloned-from exit `<name>.split`), frozen conditions
  `<cond>.fr`, a select turned into a branch `unswitched.select`, guards `guarded` / `deopt` blocks, exit phis split
  for trivial unswitching `<phi>.split`, injected conditions `injected.cond` in `<bb>.check`.
- Partial (partially invariant) unswitching needs MemorySSA (hasPartialIVCondition walks MemoryUses' defining
  accesses); it adds `llvm.loop.unswitch.partial.disable` to the loop afterwards, injection adds
  `llvm.loop.unswitch.injection.disable`; otherwise the current loop is revisited.
- collectUnswitchCandidatesWithInjections groups the compares in a DenseMap<Value *, ...> and iterates it: the
  candidate order (and so ties in findBestNonTrivialUnswitchCandidate, which keeps the first lowest cost) depends
  on pointer hashing when more than one compared value has two or more compares.
- The cost multiplier counts Log2_32(non-exiting successors) per branch/switch candidate, 1 per select, guards only
  when they don't dominate the latch; candidates that dominate the latch with at most one in-loop successor (and
  guards dominating the latch) get multiplier 1.
- MemorySSAUpdater::updateForClonedLoop is called once per cloned VMap with IgnoreIncomingWithNoClones = true, after
  removeDuplicatePhiEdgesBetween for the retained and every unswitched successor; the exit blocks of all clones are
  then inserted with one applyInsertUpdates.
