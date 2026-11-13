# NewGVN

Facts about LLVM 23.1.5's `newgvn` (lib/Transforms/Scalar/NewGVN.cpp) that decide output, found while porting it
(impl/jai, L1.extra.newgvn). Verified with the unit tests (`tests/imported/llvm/Transforms/NewGVN`), `sweep --passes
newgvn` (whole files, `--per-function`, `--with-test-flags`, `-enable-store-refinement`, `-enable-phi-of-ops=false`,
tests/perf/compile with and without `function(sroa)`), `default<O2> -enable-newgvn` on tests/perf/compile, and traces
of the assertions build (`-debug-only=newgvn`, see tools-and-flags.md).

## The dominator tree is modified (and kept)

- `runGVN` re-links every dominator-tree node's children into RPO order (`removeChild` / `addChild`) before numbering,
  and NewGVN preserves `DominatorTreeAnalysis`, also when it changes nothing (`PreservedAnalyses::all()`). A later
  `print<domtree>` or pass that walks children sees the RPO child order.
- It does not invalidate the DFS numbers: `eliminateInstructions` calls `updateDFSNumbers()`, which returns early when
  `DFSInfoValid` was already set (by >32 slow `dominates` queries during the iteration), so elimination may use numbers
  computed with either child order. Only the order of disjoint subtrees in the elimination sort depends on it.
- Instruction DFS numbers come from a pre-order walk of that sorted tree; a block's MemoryPhi gets the number before
  its first instruction. Trivially dead instructions (`isInstructionTriviallyDead(I, TLI)`) get number 0, are
  `salvageDebugInfo`'d and queued for deletion during numbering.

## PredicateInfo copies

- PredicateInfo (built in NewGVN's constructor, after MemorySSA) inserts no-op `bitcast X to T` copies; branch copies
  are inserted before the *branching block's* terminator, so the copies of both edges are evaluated in a reachable
  block even when one edge is dead.
- A copy is value-numbered as `createVariableOrConstant(FirstOp)` for an `eq` constraint, where FirstOp/SecondOp are
  ordered by `shouldSwapOperands`: rank, then **pointer value**. On a dead edge both can be different constants of
  equal rank (`%c` known `true`, the false edge says `%c == false`); which one wins then depends on LLVM's heap
  layout, not on creation order (pr27712.ll: `i1 true` is created first but has the higher address). This decides
  reachability in rare cases: SCCP/pr27712.ll and InstCombine/assume.ll `@debug_interference` (per-function) differ;
  ordering such constants by creation order matches LLVM on 38 of the 39 corpus files where it happens.
- Such a tie is often only transient: in NewGVN/completeness.ll `@test10` the optimistic iteration briefly sees
  `inttoptr (i64 4 to ptr) == inttoptr (i64 32 to ptr)`, but the fixpoint does not depend on which wins. In
  pr27712.ll the tie is gone at the fixpoint and still decided it, so checking only the final state is not enough;
  impl/jai iterates a second time with all rank ties broken the other way and compares the fixpoints (12 corpus files
  differ that way).
- Copies that survive are always congruent to their operand, so elimination replaces and deletes them all.

## Things that look like they should not matter, but do

- `DenseMapInfo<const Expression *>::isEqual` compares the full hashes before `operator==`. Load and Store
  expressions compare equal (both opcode 0) and must hash alike; `StoreExpression`'s stored value is not hashed.
- Temporary phi-of-ops PHIs (`PHINode::Create(..., "phiofops")`, never inserted unless used) are real users of
  their incoming values: `markUsersTouched` visits them (through their DFS number = the original instruction's), and
  the eliminator counts uses by them, so a value used only by a dead temporary PHI is *not* deleted as probably dead.
  Those that are used are inserted at the block's `begin()` and get their name uniqued then (`%phiofops1` ...).
- The clone used for phi translation is really inserted before the predecessor's terminator while it is evaluated
  (context instruction for InstSimplify / ValueTracking), then erased.
- `CongruenceClass` member sets are `SmallPtrSet<Value *, 4>`: insertion order while small, erase moves the last
  element into the hole; classes of more than four members iterate in pointer-hash order. `findPHIOfOpsLeader`
  returns the first dominating member, but elimination then rewrites phi-of-ops operands to the dominating leader, so
  no output difference was seen from member order.
- `OpIsSafeForPHIOfOps` returns a cached answer for the *first* worklist entry found in the cache (not only the
  argument), and its inner cache check looks up the current instruction instead of the operand.
- In `performSymbolicCmpEvaluation`, predicates are plain `CmpInst::Predicate` (no samesign), also when calling
  `simplifyCmpInst` and `isImpliedByMatchingCmp`.
- Unreachable blocks (per NewGVN's reachability) keep their terminator: all other instructions are erased in reverse
  (`landingpad` kept, uses replaced by poison, `salvageKnowledge(I, AC)`), and `store i8 poison, ptr null, align 1` is
  inserted before the terminator. Phi operands from unreachable edges become poison.
- `-enable-newgvn` replaces `GVNPass` by `NewGVNPass` in both the function simplification pipeline and the full LTO
  pipeline (PassBuilderPipelines.cpp:781, 2292).
