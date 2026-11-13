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
- **AtomicExpand on x86-64** (AtomicExpandPass.cpp + X86ISelLowering.cpp; verified by
  Transforms/AtomicExpand/X86/expand-atomic-non-integer.ll and a full-corpus sweep with and without `+cx16`):
  - as an opt pass it needs `require<libcall-lowering-info>` first, else it emits "'LibcallLoweringModuleAnalysis'
    analysis required" and changes nothing.
  - max atomic size is 128 bits with cx16, else 64; a too-big or under-aligned access becomes an `__atomic_*`
    libcall (sized `_1.._16` variant only when align >= size; i128 values passed directly, others through
    allocas with lifetime markers; orders in C ABI numbering, seq_cst = 5). An atomicrmw with no libcall (min/max,
    fp ops, a generic size for add etc.) becomes a cmpxchg loop whose cmpxchg is then turned into
    `__atomic_compare_exchange[_N]`.
  - FP atomic loads/stores and FP/pointer `xchg` are cast to the same-size integer first; pointer cmpxchg goes
    through ptrtoint/inttoptr + insertvalue rebuild. Vectors are not cast.
  - 128-bit loads become `cmpxchg 0, 0` and stores become `xchg` (then a cmpxchg loop) when cx16 is available and
    *not* (AVX && !noimplicitfloat && !soft-float); with AVX the 128-bit access stays atomic as is.
  - RMW ops other than xchg/add/sub/or/and/xor become cmpxchg loops (`atomicrmw.start` / `atomicrmw.end`, initial
    load non-atomic); or/and/xor with a used result too unless it is a single-bit test (`llvm.x86.atomic.bt*`) or
    `xor` with the sign mask. The builder is InstSimplifyFolder-based: `atomicrmw fsub x, 0.0` builds no `fsub`.
    Every instruction it creates gets the original's `!pcsections` and (memory ops) `!mmra`.
- **X86PartialReduction** rewrites the leaves of an `extractelement 0` of a log2(n)-stage add/shuffle pyramid:
  `mul` of shrinkable operands into even/odd shuffles + add + zero-concat (pmaddwd shape), `abs(sub(zext <N x i8>,
  zext))` into `llvm.x86.sse2.psad.bw` calls (AVX2 / AVX512BW variants for wide vectors).
- **CanonicalizeFreezeInLoops** (`canon-freeze`): for an induction PHI whose add/sub/mul step is loop invariant and
  that (or whose step instruction) has a freeze user, freezes the start value and the step in the preheader
  (`<name>.frozen`), drops poison flags of the step instruction and removes the freeze.
- **PreISelIntrinsicLowering** lowers `llvm.objectsize`/`llvm.is.constant` by calling `lowerConstantIntrinsics` on
  the whole caller once per call site visited (`forEachCall`); unreachable blocks keep their calls.
  On x86 it also expands every `llvm.vp.*` call (default TTI: EVL folded into the mask, ops converted to
  unpredicated ones, `-expandvp-override-*` honoured), lowers non-constant-length `memcpy.inline`/`memset.inline`
  to byte loops, `memset.pattern` to `memset_pattern16` (Darwin-only TLI) or a loop, and ObjC ARC intrinsics to
  `objc_*` calls carrying the intrinsic's tail kind (PreISelIntrinsicLowering.cpp; the PreISelIntrinsicLowering/
  tests).
- **CodeGenPrepare simplifyOffsetableRelocate**: for each gc.statepoint, a derived `gc.relocate` whose derived
  pointer is a GEP off the base with all-constant indices <= 20 is rewritten as the same GEP off the base's
  relocate (in the same block; the base relocate is moved up first). The result of the loop is `MadeChange =`,
  not `|=` (CodeGenPrepare.cpp; CodeGenPrepare/X86/statepoint-relocate.ll).
- **ExpandMemCmp** (opt -O2 runs it after mergeicmps): candidate calls are found with
  `TLI->getLibFunc(*CI, Func)`, which checks the name and prototype but **not** availability (`TLI.has`), so `bcmp`
  is expanded on triples where TLI marks it unavailable (ExpandMemCmp/X86/bcmp.ll, x86_64-unknown-unknown). x86 allows
  2 loads (also at -Os), 2 loads per block for zero-equality uses (`-memcmp-num-loads-per-block` overrides),
  overlapping loads, and 16/32/64-byte vector loads only for zero-equality comparisons. After any expansion every
  block gets `SimplifyInstructionsInBlock` (no TLI).
- **CodeGenPrepare makeBitReverse** fires only when ISD::BITREVERSE is legal or custom for the instruction's own
  (simple) integer type: on x86 i8..i64 with GFNI, i128 with SSSE3 (X86ISelLowering.cpp constructor). It reuses
  `recognizeBSwapOrBitReverseIdiom(I, false, true)` from Local.cpp.
