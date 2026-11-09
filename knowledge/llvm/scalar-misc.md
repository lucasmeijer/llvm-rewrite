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
- **DivRemPairs**: X86 `hasDivRemOp` is `isOperationLegal([SU]DIVREM, VT)`, which is false for every type (the
  X86 lowering marks DIVREM Expand), so on x86 the pass decomposes `rem` into `sub(x, mul(div, y))` (freezing x/y
  when not provably non-undef) and never recomposes. Without a target (NoTTI) the same.
- **Float2Int**: the partitions are visited in EquivalenceClasses member insertion order (`unionSets(I, Operand)`
  inserts I first); a root whose operands are not instructions is never inserted, so it is never converted. The
  integer type is the smallest legal integer type (datalayout `n...`) >= MinBW, else i32/i64.
- **SpeculativeExecution** in `-O2` is `speculative-execution<only-if-divergent-target>`: a no-op on x86.
- **MergedLoadStoreMotion** in `-O2` is `mldst-motion<no-split-footer-bb>`; plain `-passes=mldst-motion` is also
  `no-split-footer-bb` (MergedLoadStoreMotionOptions default).
