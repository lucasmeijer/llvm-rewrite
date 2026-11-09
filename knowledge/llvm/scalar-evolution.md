# ScalarEvolution and the loop pass manager: behaviour that decides output

Verified against opt 23.1.5 with the Goose port (`impl/goose/src/scev*.goose`, `lpm.goose`, `loopnest.goose`)
passing 243/247 `print<scalar-evolution>` lines of `tests/analysis/scev` + `Analysis/ScalarEvolution`, all
`Analysis/LoopNestAnalysis`, and matching `print<scalar-evolution>` byte for byte on every tests/e2e input and on
6913 imported test files (sweep: stdout+stderr compared per file).

## print<scalar-evolution>

- Header `Printing analysis 'Scalar Evolution Analysis' for function 'f':`, then (unless
  `-scalar-evolution-classify-expressions=0`) every SCEVable non-cmp instruction in function order: the
  instruction as the module printer prints it, `  -->  <SCEV>` and ` U: <unsigned range> S: <signed range>`
  (`full-set`, `empty-set` or `[lo,hi)` in *signed* decimal), then ` -->  <at use scope>` only when
  getSCEVAtScope(S, innermost loop) differs, then inside a loop `\t\tExits: <SCEV at the parent scope or
  <<Unknown>>>` and `\t\tLoopDispositions: { %L: D, ... }` (the loop and its parents outward, then the loop's
  subloops in depth-first preorder). Dispositions are `Variant`, `Invariant`, `Computable` and LLVM 23's
  `Uniform` (an AddRec of an inner loop whose operands are uniform in the outer one).
- "Determining loop execution counts": loops recursively, inner loops first, top-level loops in LoopInfo order
  (reverse program order). Lines: backedge-taken count (`<multiple exits> ` when the loop has != 1 exiting
  blocks, then `  exit count for <block name>:` per exiting block), constant max (`, actual taken count either
  this or zero.` when max-or-zero), symbolic max, the `Predicated ...` variants only when they differ from the
  plain ones (with ` Predicates:` and each predicate indented by 4), and `Trip multiple is N` when the BTC is
  computable. A constant count prints its type first (`i32 13`).
- Predicates print as `Equal predicate: A == B`, `Compare predicate: A <pred>) B` (sic, LLVM prints `) `),
  `{...} Added Flags: <nusw><nssw>`.

## Construction details that change printed SCEVs

- **ValueID order** for operand complexity (CompareValueComplexity) follows LLVM 23's Value.def: constants
  (UndefValue first ... ConstantVector), then Function, GlobalAlias, GlobalIFunc, GlobalVariable, BlockAddress,
  ConstantExpr, DSOLocalEquivalent, NoCFIValue, ConstantPtrAuth, Argument, BasicBlock, MetadataAsValue,
  InlineAsm, MemoryUse/Def/Phi, Instruction + opcode. Pointers sort after integers. AddRecs sort by loop header
  dominance (each comparison is a `DT.dominates` call, which counts slow queries).
- `getPostIncExpr` adds operand i+1 to operand i (it is not `AR + step`).
- In getMulExpr, `AddRec->getNoWrapFlags(ComputeFlags({Scale, AddRec}))` evaluates ComputeFlags first; its
  isKnownNonNegative computes the AddRec's range, and getRangeRef *adds* the nowrap flags getRangeForAffineAR
  proves to the AddRec. So nuw/nsw on AddRecs depend on which ranges were asked for before (keep LLVM's order).
- getRangeRef intersects ranges from: the constant multiple (trailing zeros), `!range`/`range` attributes
  (CallBase::getRange intersects call-site and callee), known bits and sign bits (computeKnownBits with the
  instruction itself as context: `safeCxtI`), and for pointers the dereferenceable bytes (arguments: the
  attribute, else the store size of a byval/byref/preallocated/inalloca/sret type; calls: max of call site and
  callee; loads/inttoptr: `!dereferenceable`; allocas: size x count without overflow; globals: store size)
  together with the alignment and isKnownNonZero (Argument::hasNonNullAttr counts dereferenceable when null is
  not defined). getConstantMultiple's known bits allow ephemeral assumptions (an `align` bundle on the value's
  own assume counts), getRangeRef's don't.
- Cached results that a later query must not reuse: forgetMemoizedResults erases dispositions, ranges,
  ValuesAtScopes (both as key and as value) and FoldCache entries whose *value* is the forgotten SCEV
  (`zext-fold-cache-invalidation.ll`). createAddRecFromPHI forgets the symbolic PHI after building the AddRec;
  computing a loop's BTC forgets every AddRec of the loop (LoopUsers).
- LoopGuards: terms are the assumptions dominating the block, then the guard intrinsics, then the conditions on
  the unique-predecessor chain (at depth > 0 at most 2); they are processed in reverse. With more than one
  rewritten expression, each entry is erased *before* its target is re-rewritten (so it doesn't rewrite through
  itself). The rewriter looks up the map only for unknowns, zext, sext, umin and smin (not umax/smax).
- isGuaranteedToTransferExecutionToSuccessor over an instruction range fails at the 32nd instruction
  (ScanLimit 32): `inbounds nuw` GEP flags are dropped for GEPs more than ~31 instructions after the entry
  (`matmul_f64_4x4.ll`).
- The sequential umin deduplicator: each getSequentialMinMaxExpr call has its own SeenOps; nested umin/umin_seq
  operands are deduplicated against everything seen before them.

## Loop pass manager

- `loop(...)`/`loop-mssa(...)` and a single loop pass in a function pipeline each become a
  FunctionToLoopPassAdaptor that first runs loop-simplify and lcssa (counted by `-opt-bisect-limit`, skipped on
  optnone functions). A loop pass first in a top-level pipeline wraps the whole list in `function(loop(...))`
  (`loop-mssa` for licm).
- Worklist: appendLoopsToWorklist over the top-level loops in LoopInfo order, each nest in preorder (children in
  order, LIFO), inserted as one sequence into a SmallPriorityWorklist and popped from the back: loops run
  innermost-last-first, i.e. in program order of the nests' post-order.
- `-opt-bisect-limit` prints the *pipeline name* (`loop-simplify`, `no-op-loop`, `sroa`), not the class name, and
  the IR unit as `[module]`, the function name, or `loop %<header> in function <f>`.
- print<loopnest> is a loop pass: it prints one line per loop (inner loops first); IsPerfect compares the maximal
  perfect depth with the nest depth (breadth-first loop list).

## Printing instructions in analysis printers

- An intrinsic call with an MDNode operand (`llvm.read_register(metadata !0)`) is printed with a SlotTracker that
  numbers the metadata of *every* function in module order (AsmWriter's isReferencingMDNode), so its numbers
  differ from the per-function numbering of other instructions (`GVN/invariant-load-intrinsic.ll`).

## More facts (verified with the Jai port, impl/jai/src/scev*.jai: 235/239 analysis checks of L1.analysis.scev)

- **No-wrap flags are sticky on uniqued nodes**, so output depends on cache history: a node can print `<nw>` and,
  after a later range query proved more, `<nuw>`. `print<scalar-evolution>,loop(loop-rotate),print<scalar-evolution>`
  legitimately differs from `loop(loop-rotate),print<scalar-evolution>` (the second print reuses the cached
  ScalarEvolution and its nodes; reproducer: tests/analysis/domtree/loop_nest.ll).
- **getBackedgeTakenInfo inserts an empty BackedgeTakenInfo first** (try_emplace): recursive queries made while
  a loop's trip count is being computed see "unknown" for it.
- **GroupByComplexity uses std::stable_sort with a comparator that is not a strict weak order** (past
  `scalar-evolution-max-scev-compare-depth` it answers "unknown" = not less). The oracle is built with GCC 12's
  libstdc++ (`strings /opt/llvm-23.1.5/bin/opt | grep GCC`): two `__merge_sort_with_buffer` halves (insertion sort
  of chunks of 7, then pairwise merges), then `__merge_adaptive`. Reproduce that algorithm to be safe.
- **SCEVTraversal::visitAll stops pushing a node's remaining operands as soon as the visitor isDone()**, not only
  between worklist pops. SCEVMinMaxExprContains depends on it (its `follow` overwrites `Found` for every node):
  without the early stop `select (x == 0), 0, umin(y, x)` is not recognised as `x umin_seq y`
  (Analysis/ScalarEvolution/logical-operations.ll).
- The printer prints the SCEV *before* computing its ranges, so the flags a range computation adds show up only in
  later lines.
- FunctionToLoopPassAdaptor always computes ScalarEvolution (order: AA, AssumptionCache, DominatorTree, LoopInfo,
  ScalarEvolution, TLI, TTI), so every loop pass has one: `loop-rotate<check-exit-count>` depends on
  `SE->getExitCount`. LoopSimplifyPass and LCSSAPass only use a cached SE and preserve it. The forget calls that keep
  a cached SE identical to LLVM's: LoopSimplify forgetLoop before separating a nested loop, forgetValue on a
  simplified header PHI, forgetTopmostLoop when anything changed, and Loop::makeLoopInvariant
  forgetBlockAndLoopDispositions(I) per hoisted instruction; LCSSA `SE->getSCEV(PN)` on each new LCSSA PHI whose
  value had a cached SCEV; LoopRotate forgetTopmostLoop + forgetBlockAndLoopDispositions() before rotating,
  forgetValue on each rewritten header value, forgetBlockAndLoopDispositions() after simplifyLoopLatch.
- ScalarEvolution::invalidate checks AssumptionAnalysis, DominatorTree and LoopInfo, but
  AssumptionCache::invalidate always returns false: only DT and LoopInfo can drop a preserved ScalarEvolution.
- Value handles: deleting a value erases it from ValueExprMap (and ConstantEvolutionLoopExitValue); RAUW calls
  forgetValue(old). A SCEVUnknown whose value is deleted or RAUW'd is forgotten, removed from the uniquing set and
  keeps the new value (or null).
- `print<loopnest>` names loops with Loop::getName(): the header's name or `<unnamed loop>`.
- IVUsers' PostIncLoops is a SmallPtrSet with inline capacity 2: printed in insertion order (up to 2 loops).
- SCEVAA recurses on the base values with `LocationSize::beforeOrAfterPointer()` and empty AA tags.
- LLVM 23's SCEVUse (a SCEV pointer plus use-specific NUW/NSW bits) exists, but nothing in 23.1.5 constructs a use
  with flags (grep `SCEVUse(` in lib/), so every SCEV is its own canonical and operands can be plain pointers.
- SCEVExpander and IndVarSimplify (the main SCEV clients so far): see indvars-and-scev-expander.md.

## Keeping a cached ScalarEvolution valid (verified with the Goose port, scev_update.goose)

- `registerUser` skips SCEVConstant operands (ScalarEvolution.cpp:15665): forgetting a constant SCEV (e.g. the
  SCEV of a PHI that folded to 0) must not forget every expression containing that constant. Without this,
  `loop(indvars),print<scalar-evolution>` on IndVarSimplify/eliminate-max.ll recomputes `select` SCEVs after
  indvars changed an icmp predicate in place and prints `umin` where LLVM keeps the cached `smin`.
- ValueHandleBase::ValueIsRAUWd runs before the use list is rewritten, so SCEVCallbackVH::allUsesReplacedWith's
  forgetValue still sees the old users; a value only has a SCEVCallbackVH while it is in ValueExprMap
  (eraseValueFromMap drops it), so forgetValue(PN) followed by RAUW(PN) does not forget twice.
- forgetBlockAndLoopDispositions(V) erases the dispositions of V's SCEV and, only while something was erased,
  of its SCEVUsers; forgetMemoizedResults' LoopDispositions.erase(S) erases every loop's entry for S.
- `print<iv-users>` prints `getSCEV(operand)` (not the normalized expression) and the post-inc loops in
  insertion order; IVUsers reuses the normalized ISE for the next user of the same instruction.
