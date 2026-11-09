# AggressiveInstCombine

Facts about `Transforms/AggressiveInstCombine/*.cpp` (LLVM 23.1.5), verified by porting them
(impl/jai/src/pass_aggressive_instcombine.jai, aic_trunc.jai): all 44 imported tests pass, and sweeps of
`-passes=aggressive-instcombine` (whole-file, `--per-function`, with `-mtriple=x86_64-unknown-linux-gnu`, after
`debugify`) are identical.

- **Order.** TruncInstCombine runs first over the whole function (truncs collected from reachable blocks in
  order, processed from the *back* of the worklist). Then every reachable block is walked *bottom-up* with
  `make_early_inc_range(reverse(BB))`, trying all folds on each instruction in a fixed order (any/all-bits-set,
  guarded funnel shift, split ctlz/cttz select, three popcount idioms, fptosi.sat, table cttz/log2, consecutive
  loads, patterned loads, icmp of or-chains, mul-high, library calls last because they may erase `I`), then
  consecutive stores for the block. Blocks created by the strncmp/memchr expansions are visited afterwards.
- **Cleanup without TLI.** If anything changed, `SimplifyInstructionsInBlock(&BB)` runs on every block with
  `TLI = nullptr`: dead `call double @fmod(...)` etc. are kept (isMathLibCallNoop needs a TLI) and library calls are
  *not* constant-folded (ConstantFoldLibCall1/2 return null without a TLI), unlike InstSimplify/InstCombine.
  Seen on tests/e2e/*/float/libm.ll and InstCombine/constant-fold-nextafter.ll.
- **TTI gates.** Without a target (no triple) `isTypeLegal`, `allowsMisalignedMemoryAccesses` and `haveFastSqrt` are
  false, so load/store merging and sqrt are never done. X86 allows any misaligned access and reports it fast except
  128/256-bit accesses on `slow-unaligned-mem-16/32` subtargets.
- **Analyses.** Uses AC, TLI, DT, TTI and the default AA. Folds that change the CFG (strncmp/strcmp inlining,
  memchr to switch) update the DT through a lazy DomTreeUpdater created per call and flushed when `foldLibCalls`
  returns; the pass then preserves only the DominatorTree, otherwise the CFG set.
- The table-based cttz/log2 folds put `!prof` branch weights `(1, 1048575)` (createUnlikelyBranchWeights) on the
  select for the zero case.
- `mergePartStores` sorts parts with `llvm::sort` (std::sort, not stable) by pointer offset; only equal offsets
  could expose that, and such parts never merge.
- `m_ShlOrSelf`/`m_LShrOrSelf` (ShiftLike_match) do not fall back to "self" when the value *is* a shift of the
  opcode with a non-constant amount: the match fails.
- Matchers: `m_Add`/`m_Or`/`m_Mul`/`m_LShr`/... (BinaryOp_match) and the cast matchers match **instructions only** in
  LLVM 23 (PatternMatch.h `BinaryOp_match::match`: `V->getValueID() == Value::InstructionVal + Opc`), so constant
  expressions never take part in these folds; `m_ShlOrSelf`'s amount is `m_ConstantInt(uint64_t&)`, which accepts
  a non-poison splat (`ap_match`) of a value that fits in 64 bits. Verified with the Goose port (0 differs over the
  corpus, also per function and with `-mtriple=x86_64-unknown-linux-gnu`).
- tryToFPToSat's `getIntrinsicInstrCost(fptosi.sat)` on x86 has no cost-table entry: BasicTTIImpl's type-based path
  sets ISD::FP_TO_SINT_SAT, and X86ISelLowering marks it Custom for i8/i16/i32 (and i64 in 64-bit mode) with SSE2
  (Legal for i32/i64 with AVX10.2), so a scalar costs 2 * LT.first; vector types fall through to the
  minnum/maxnum/fptosi/fcmp/select expansion (X86/fptosisat.ll).
