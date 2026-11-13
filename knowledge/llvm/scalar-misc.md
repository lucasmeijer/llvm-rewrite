# Small scalar passes (L1.scalar-misc)

Facts verified while porting LowerExpectIntrinsic, LowerConstantIntrinsics, InferAlignment, DivRemPairs, Float2Int,
Sink, TailCallElim, MergedLoadStoreMotion, SpeculativeExecution and CallSiteSplitting
(`/opt/llvm-project-23.1.5/llvm/lib/Transforms/Scalar/`); every claim is exercised by the imported tests of that pass
(all pass for impl/jai) and by a corpus sweep with 0 differences.

- **TailCallElim, readnone calls** (`markTails`): the loop meant to check that a `readnone` call's arguments are
  constants or non-byval arguments tests `isa<Constant>(Arg.getUser())`, i.e. the call itself. So only a readnone
  call *without arguments* is marked `tail` on that path; others go through the escape analysis (DeferredTails).
- **TailCallElim, entry counts**: `-passes=tailcallelim` constructs `TailCallElimPass()` with
  `UpdateFunctionEntryCount = true`, so a function with `!prof function_entry_count` gets BFI and its count reduced
  by round(freq(BB)/freq(entry) * count) per eliminated call; in `-O2` the flag is `isInstrumentedPGOUse()` (false).
  `-tre-disable-entrycount-recompute` turns it off.
- **TailCallElim** creates the new entry block with the old entry's name, renames the old one `tailrecurse`, and
  inserts the argument phis (`<arg>.tr`, `.tr` for unnamed args), then `ret.tr` and `ret.known.tr`, at
  `HeaderBB->begin()` (head bit: before the first instruction's debug records). The accumulator phi
  (`accumulator.tr`) goes in front of all of them. The new branch in the new entry has no `!dbg`.
- **LowerConstantIntrinsics** passes no TLI/DT/AC to `replaceAndRecursivelySimplify`, and only uses a DomTreeUpdater
  when a DominatorTree is *cached*; it preserves only the DominatorTree.
- **InferAlignment** runs two walks: first "enforce preferred alignment" over all instructions in layout order
  (tryEnforceAlignment can raise alloca/global alignment), then a dominator-tree DFS where a ScopedHashTable keeps
  the best known alignment per base pointer (after stripAndAccumulateConstantOffsets) per scope. `Align()` (1) in
  the table means "absent". `and (ptrtoint p), C` folds to 0 or to the ptrtoint when the alignment decides it;
  `trunc (ptrtoint p)` folds to 0 when log2(align) >= the result width.
- **DivRemPairs**: X86 `hasDivRemOp` is `isOperationLegal([SU]DIVREM, VT)`: legal for the scalar integer types
  (checked for i32 with `-mtriple=x86_64-unknown-linux-gnu`: a dominated `srem` is hoisted next to the `sdiv`,
  nothing else changes), not for i128/vectors. Without a target (NoTTI: false) the pass instead decomposes `rem`
  into `sub(x, mul(div, y))`, freezing x / y (`.frozen`) unless they are provably not undef.
- **Float2Int**: the partitions are visited in EquivalenceClasses member insertion order (`unionSets(I, Operand)`
  inserts I first); a root whose operands are not instructions is never inserted, so it is never converted. The
  integer type is the smallest legal integer type (datalayout `n...`) >= MinBW, else i32/i64.
- **SpeculativeExecution** in `-O2` is `speculative-execution<only-if-divergent-target>`: a no-op on x86.
- **MergedLoadStoreMotion** in `-O2` is `mldst-motion<no-split-footer-bb>`; plain `-passes=mldst-motion` is also
  `no-split-footer-bb` (MergedLoadStoreMotionOptions default).

## The -O2 pipeline as text

- `opt -passes='default<O2>' -print-pipeline-passes` does not round-trip exactly: the
  `extra-simple-loop-unswitch-passes` element is an `ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch>` whose
  printPipeline drops its inner `simple-loop-unswitch<...>` (PassBuilderPipelines.cpp builds it with one), so the
  textual pipeline runs an empty manager there. It only runs its passes when IndVarSimplify left the
  ShouldRunExtraSimpleLoopUnswitch marker cached for the loop.
- Passes in `default<O2>` that never change IR without a feature: annotation2metadata / annotation-remarks (only with
  remarks enabled), forceattrs (only with -force-attribute*), coro-* (only with coroutine intrinsics), openmp-opt*
  (only with the "openmp" module flag), alloc-token (sanitize_alloc_token), lower-comment-string (AIX),
  inject-tli-mappings (only with -vector-library), loop-sink (only with a function entry count), cg-profile (only
  with entry counts), rel-lookup-table-converter (only for PIC: opt's default relocation model is static except
  x86-64 Darwin / Windows; `-relocation-model=pic` turns it on). Verified by sweeping each over the corpus.
- Required passes (RequiredPassInfoMixin: run on optnone functions, not counted by -opt-bisect-limit):
  coro-early/cleanup/elide/split, alloc-token, ee-instrument, lower-comment-string, annotation-remarks,
  extra-simple-loop-unswitch-passes.
- CalledValuePropagation's !callees lists are sorted by function name; its SparseSolver treats a phi's incoming
  edge as feasible from the edge's terminator alone (isEdgeFeasible does not ask whether the predecessor block is
  executable).
- JumpTableToSwitch: the switch is created with IRBuilder::CreateSwitch's default 10 reserved cases, gets
  `!prof !{!"unknown", !"jump-table-to-switch"}` unless the call had VP data with a non-zero weight for one of the
  table's functions (a function's GUID is its !guid attachment, else MD5 of its PGO name = the global identifier).
- LibCallsShrinkWrap in a strictfp function emits `llvm.experimental.constrained.fcmp(..., metadata !"<pred>",
  metadata !"fpexcept.strict")` calls with the strictfp attribute (IRBuilder setIsFPConstrained).

## LICM naming

- LICM's cloneInstructionInExitBlock clones a call with `CallInst::Create(CI, OpBundles)`, which names the clone
  `CI->getName()`. Inserting it into the exit block uniquifies that name (one `++LastUnique` in the function's symbol
  table, e.g. `smax1`, `smax3`) before `setName(Name + ".le")`; other instructions are `clone()`d unnamed. So the
  second sunk copy of a call `%smax` is `%smax.le4`, not `%smax.le1` (SCCP/2003-06-24-OverdefinedPHIValue.ll after
  lcssa, `licm<allowspeculation>`).
- The same naming effect decides `.lcssa` suffixes later in -O2 (SPASS.ll: `%.lcssa33` vs `%.lcssa32` after a sunk
  `llvm.scmp` call); verified by the jai port (pass_licm.jai).

## More facts (verified by impl/goose ports: imported tests + corpus sweeps with 0 differences)

- **SplitEdge** of a non-critical edge calls `SplitBlock(BB, BB->getTerminator())`, and an empty name becomes
  `Old->getName() + ".split"`. DuplicateInstructionsInSplitBetween (CallSiteSplitting, JumpThreading) then sets the
  name `<pred>.split` again; when the first name collided, the rename collides too and the function's unique counter
  is bumped twice (seen on lua: `.split14` in LLVM).
- **InferAlignment** returns `PreservedAnalyses::all()` even when it changed alignments, and `m_PtrToIntOrAddr`
  matches `ptrtoint` constant expressions, so `and (ptrtoint @g), C` folds too (InstCombine/constant-fold-alias.ll).
- **`-use-dereferenceable-at-point-semantics`** defaults to true (Value.cpp); with `=0`, getPointerDereferenceableBytes
  never asks canBeFreed (MergeICmps/X86/no-gep-other-work.ll).
- **ConstantFolding of `llvm.is.constant`** returns true iff the operand `isManifestConstant` (no undef/poison, only
  ConstantData / aggregates / constant expressions of those); otherwise it does not fold (LowerConstantIntrinsics).
- **MergeICmps**: the merged blocks are created before the chain's entry block, so the later
  `EntryBlock_->isEntryBlock()` (and setNewRoot) never fires; enableMemCmpExpansion is false without a target (NoTTI),
  so the pass is a no-op on modules without an x86 triple.
- **LoopSink** gets no ScalarEvolution (`nullptr`), and only runs on functions with profile data
  (`function_entry_count` or `synthetic_function_entry_count`).
- **libcalls-shrinkwrap** builds its conditions before the call with the call's debug location; `createOrCond` creates the
  second condition first.

## DFAJumpThreading and SSAUpdaterBulk

Verified by impl/goose (dfa_jump_threading.goose, ssa_updater_bulk.goose): Transforms/DFAJumpThreading 10/10, the
corpus sweep (also with `-dfa-cost-threshold=100000 -dfa-early-exit-heuristic=false -dfa-max-cloned-rate=1000
-dfa-max-out-use-blocks=100000` and with `,print<domtree>`) and the IR the -O2 pipeline hands the pass in the four
tests/perf/compile programs (`-opt-bisect-limit=<index of dfa-jump-threading - 1>`): 0 differences.

- At `-O2`, LLVM threads `sqlite3AffinityType` (sqlite3) and `dfg_lex` / `ia_lex` (SPASS); lua and oggenc have
  candidates the cost model rejects. `function(sroa),dfa-jump-threading` threads nothing in any of the four: test
  the pass on the pipeline's real input (`-pass-remarks=dfa-jump-threading` names the functions, `-opt-bisect-limit`
  gives the module just before).
- SSAUpdaterBulk::RewriteAllUses creates each new PHI with `IRBuilder<> B(BB, BB->begin())`, so the PHI goes in front
  of the existing PHIs and takes the **DebugLoc of the block's first instruction** (SetInsertPoint copies
  `IP->getStableDebugLoc()`); it is named after the rewritten instruction. IDF blocks come out in the priority-queue
  order of (dom-tree level, DFS-in), the dom-tree children walk follows the DT's child order, so the incrementally
  updated DT (lazy DTU, flushed by `DTU->getDomTree()`) must match LLVM's child order.
- `PHINode::removeIncomingValueIf` (cleanPhiNodes) walks backwards and moves the current last entry into each removed
  slot (not stable); `removeIncomingValue(BB)` does the same swap.
- `DFAJumpThreading::run` does `LI->verify(DTU->getDomTree())` under `#ifdef NDEBUG`: in a release build its only
  effect is the DTU flush. The pass requests AC, DT, LoopInfo and TTI before the optsize/minsize early exit.
- Cloned blocks are named `<bb>.jt<state>` with `APInt::getLimitedValue()` (an `i32 -1` state gives `.jt4294967295`);
  RemapInstruction does not remap the clones' debug records (they keep the original values) and cloned PHIs are not
  remapped at all (cleanPhiNodes and SSAUpdaterBulk fix them).
