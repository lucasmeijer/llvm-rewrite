# llc's IR passes (TargetPassConfig up to x86-isel)

Facts about the IR-level part of llc's pipeline (`addIRPasses`, `addCodeGenPrepare`, `addISelPrepare` for x86-64),
which runs under the **legacy** pass manager. Verified with `llc -debug-pass=Structure -stop-before=x86-isel` and by
diffing our output against `llc -stop-before=x86-isel` (the `::isel-ir` check) on tests/e2e and tests/function.

## Pipeline shape

- At -O1+, LoopStrengthReduce runs inside a legacy `LPPassManager { CanonicalizeFreezeInLoops, IVUsers,
  LoopStrengthReduce }`, preceded by LoopSimplify (a function pass). LCSSA is **not** formed (unlike opt's
  `loop(...)` adaptor), and `LoopStrengthReduce::runOnLoop` calls ReduceLoopStrength with `PreserveLCSSA=false`.
- The LPPassManager queue (LoopPass.cpp): `for L in reverse(LoopInfo): addLoopIntoQueue(L)`, where addLoopIntoQueue
  pushes L and then recurses into `reverse(L->subloops)`; loops are popped from the back. For each loop all three
  passes run in order before the next loop (IVUsers is computed after canon-freeze changed the loop).
- `opt -passes=loop-reduce` instead goes through the new-PM loop adaptor (LoopSimplify + LCSSA first) and uses
  `PreserveLCSSA=true`. Without `-mtriple` and with no module triple, TTI is TargetTransformInfoImplBase, which changes
  LSR's answers a lot: `isLegalICmpImmediate`/`isLegalAddImmediate` are false, `isLegalAddressingMode` is
  `!BaseGV && BaseOffset == 0 && (Scale == 0 || Scale == 1)` (HasBaseReg is ignored), `getIntImmCost` is TCC_Basic
  (constants cost a setup register), `isLSRCostLess` compares NumRegs first (X86 compares Insns first).
  (tests/imported/llvm/Transforms/LoopStrengthReduce/lsr-term-fold.ll depends on all of these.)

## LoopStrengthReduce (LoopStrengthReduce.cpp)

- Formula generation loops (`GenerateAllReuseFormulae`) iterate `for (i = 0, f = LU.Formulae.size(); i != f; ++i)`:
  the bound is fixed before the loop, so formulae inserted by one generator are only revisited by the next one.
  Re-reading the size each iteration loops forever on unrolled code (X86/iv-chain-assume-ephemeral.ll).
- `GenerateCrossUseConstantOffsets` groups registers by `ExtractImmediate` base in a `std::map<Immediate, ...>`
  (KeyOrderTargetImmediate: fixed before scalable, then by value; `insert` keeps the first register for a key) and
  compares each offset against begin, the last entry and `lower_bound(avg)`, with
  `avg = (F & L) + ((F ^ L) >> 1)` (arithmetic shift) `+ ((F ^ L) & (uint64(avg) >> 63))`. Getting the average wrong
  silently changes the chosen solution (tests/e2e/O2/control/nested_loops.ll).
- `FindUseWithSimilarFormula`, `DeleteUse` and `LSRUse::DeleteFormula` swap the victim with the last element and
  pop; `FilterOutUndesirableDedicatedRegisters` keeps indices into a list that DeleteFormula reorders, and the
  output depends on that.
- IV chains: `ChainInstruction` adds a user to the first chain whose ExprBase matches and whose increment is
  profitable; a complete chain needs the header phi as tail (`SE.getSCEV(tail) == Incs[0].IncExpr`), which is what
  makes a chain of constant increments profitable (cost 1 - 1 (phi) - 1 (more than one const inc) < 0).
- `CollectFixupsAndInitialFormulae` swaps the operands of an equality icmp so the IV operand is first
  (sets Changed even if nothing else happens).
- ReduceLoopStrength always runs `DeleteDeadPHIs`, `replaceCongruentIVs` (phi elimination, `-enable-lsr-phielim`)
  and, when the loop is recursively LCSSA and has a unique exit block, `rewriteLoopExitValues` with
  `UnusedIndVarInLoop` (exit values are rewritten only for induction PHIs used solely by PHIs and their own
  increment, or the increment of such a PHI).
- The debug-value salvage (`DbgGatherSalvagableDVI`/`DbgRewriteSalvageableDVIs`) only rewrites records that
  became kill locations during LSR.

## Other passes

- **InterleavedAccess** on x86: `X86TargetLowering::lowerInterleavedLoad/Store` only rewrites AVX groups of factor
  3/4 (`X86InterleavedAccessGroup::isSupported`). Without AVX nothing is lowered, but `lowerInterleavedLoad` still
  rewrites extractelements of the load into extracts of the de-interleave shuffles (`tryReplaceExtracts`) and
  `shuffle(binop(load, x))` into `binop(shuffle, shuffle)` before asking the target. X86 implements neither
  `lowerDeinterleaveIntrinsicToLoad` nor `lowerInterleaveIntrinsicToStore`, so the (de)interleave intrinsics are
  never touched. Max factor: 4.
- **AtomicExpand**: an idempotent atomicrmw (`add/sub/or/xor 0`, `and -1`, min/max of the extreme value) becomes
  `fence seq_cst` + `load atomic` with `getStrongestFailureOrdering` (release -> monotonic, acq_rel -> acquire),
  the RMW's align and syncscope, unless it is wider than 64 bits or is an unused `or 0` (X86ISelLowering.cpp
  lowerIdempotentRMWIntoFencedLoad; tests/e2e/O2/misc/thread_local_atomics.ll).
- **X86PartialReduction** rewrites the leaves of an `extractelement 0` of a log2(n)-stage add/shuffle pyramid:
  `mul` of shrinkable operands into even/odd shuffles + add + zero-concat (pmaddwd shape), `abs(sub(zext <N x i8>,
  zext))` into `llvm.x86.sse2.psad.bw` calls (AVX2 / AVX512BW variants for wide vectors).
- **CanonicalizeFreezeInLoops** (`canon-freeze`): for an induction PHI whose add/sub/mul step is loop invariant and
  that (or whose step instruction) has a freeze user, freezes the start value and the step in the preheader
  (`<name>.frozen`), drops poison flags of the step instruction and removes the freeze.
- **PreISelIntrinsicLowering** lowers `llvm.objectsize`/`llvm.is.constant` by calling `lowerConstantIntrinsics` on
  the whole caller once per call site visited (`forEachCall`); unreachable blocks keep their calls.
