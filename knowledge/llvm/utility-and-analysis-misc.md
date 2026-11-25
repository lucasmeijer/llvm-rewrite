# Utility passes and miscellaneous analysis printers

Facts verified against LLVM 23.1.5 while porting L1.extra.utility and L1.extra.analysis-misc (impl/jai, by
jai_extras_b). "Verified" means one of: a corpus test, a whole-corpus sweep against `opt`, or a hand-made module
diffed against `opt`. Source paths are under `/opt/llvm-project-23.1.5/llvm`.

## IR layout facts that several printers depend on

- **`SwitchInst` case values are not operands in LLVM 23.** `case_values()` lives after the operand block
  (`op_begin() + ReservedSpace`, include/llvm/IR/Instructions.h). `getNumOperands()` is `2 + #cases`:
  condition, default dest, and the case destinations. `print<func-properties>` (ConstantIntOperandCount) and
  `print<structural-hash><detailed>` (operand hashes) both show this: counting the case values gives different
  numbers. Verified with test/Analysis/FunctionPropertiesAnalysis/func-properties-analysis.ll and
  tests/analysis/domtree/irreducible.ll.
- **Vector splat constants** (lib/IR/Constants.cpp `ConstantVector::getSplat`):
  - `ConstantFP` vector splats are always real `ConstantFP`s, fixed and scalable.
  - `ConstantInt` vector splats are off by default (`-use-constant-int-for-fixed-length-splat` and
    `-use-constant-int-for-scalable-splat` are both false). Instead:
    - a fixed splat is a `ConstantDataVector` when the element type allows it (i8/i16/i32/i64, half/bfloat/float/double);
    - otherwise (i1, i128, ...) it is a `ConstantVector` of N copies;
    - a scalable splat is the ConstantExpr `shufflevector (insertelement (poison, V, i64 0), poison, zeroinitializer)`.
    It still prints as `splat (...)`.
  - `ConstantByte` (`bN` types) is its own value kind.
  These matter for anything that switches on the value ID (StructuralHash, IR2Vec operand kinds). Verified with
  hand-made modules diffed against `opt -passes='print<structural-hash><detailed>'`.
- **`MetadataAsValue` is uniqued per `Metadata`.** `metadata !0` in two functions is one `Value *`, so maps keyed by
  value (StructuralHash's `ValueToId` over a whole module) give it one id. Verified with
  Transforms/SimplifyCFG/no-md-sink.ll under `print<structural-hash><detailed>`.
- **x86_fp80 `bitcastToAPInt` does not always return the parsed bits.**
  - An unnormal (exponent not 0 or 0x7fff, integer bit clear) is a NaN, and is exported with exponent 0x7fff.
  - A pseudo-denormal (exponent 0, integer bit set) is a normal, and is exported with exponent 1.
  - `0xK40590000000000000000` therefore hashes (and prints) as `+snan(0x0)`.
  Source: lib/Support/APFloat.cpp, initFromF80LongDoubleAPInt and convertF80LongDoubleAPFloatToAPInt.

## StructuralHash (lib/IR/StructuralHash.cpp, lib/Analysis/StructuralHash.cpp)

- `print<structural-hash><call-target-ignored>` prints `IndexOperandHashMap`.
  - The map is a `DenseMap<std::pair<unsigned, unsigned>, stable_hash>`, so it prints in bucket order, not sorted.
  - DenseMap (include/llvm/ADT/DenseMap.h) uses linear probing and starts with 64 buckets.
  - It grows by doubling when `(n+1)*4 >= buckets*3`, rehashing in bucket order.
  - The key hash is `densemap::detail::mix((a*37) << 32 | (b*37))`.
  - Verified on the whole corpus.
- The hash of a ConstantDataSequential that is not a string, of a ConstantByte, and of a poison or undef value
  is just the type hash (none of them is a case of `hashConstant`'s switch).

## Stack safety and stack lifetime printers

- `print<stack-safety-local>` and `print-stack-safety` write their header before the analysis runs.
  `AssumptionAnalysis` asks for TTI, which builds the subtarget, which prints the "'+x' is not a recognized feature"
  warnings. Those warnings land between the header and the body.
  Verified: Transforms/LoopVectorize/X86/int128_no_gather.ll.
- `UseInfo::Calls` is a `std::map<CallInfo, ConstantRange>` ordered by `(ParamNo, Callee pointer)`. Two different
  callees for one argument number therefore print in address order. That happens in about 220 corpus files.
- `print<stack-lifetime><may|must>` prints the function through an AssemblyAnnotationWriter.
  - Before each reachable block it prints `  ; Alive: <names>`, using the block's first slot.
  - After each reachable instruction it prints `\n  ; Alive: <names>` (isAliveAfter), which leaves a blank line.
  - Names are sorted with `llvm::sort` on StringRef, so AllocaNumbering's DenseMap order never shows.

## Lint (lib/Analysis/Lint.cpp)

- `Check` returns from the whole visitor. A failed check in `visitCallBase` skips the tail-call and intrinsic checks
  of that call. `visitMemoryReference` returns only from itself.
- `findValue` on a load walks up unique predecessors with the `FindAvailableLoadedValue(L, BB, BBI, ...)` overload.
  BBI is passed by reference, so the loop stops when the scan did not reach the block's first instruction.
- Values that are not instructions print with `printAsOperand(OS, true, M)`; instructions print in full.
- With `<abort-on-error>`, any message is followed by `LLVM ERROR: linter found errors, aborting. (enabled by
  abort-on-error)` and exit 1.
- test/Other/lint.ll (102 lines of messages) is identical. It is not in the corpus, because `Other/` is not imported.

## FunctionPropertiesAnalysis (lib/Analysis/FunctionPropertiesAnalysis.cpp)

- Big, medium and small blocks are classified by the function's running `TotalInstructionCount`, not by the
  block's own size. This is an upstream bug; reproduce it.
- `IntrinsicCount` is incremented with `++`, not by `Direction`.
- `FloatingPointInstructionCount` uses `isFloatTy()` (float only). `CallReturnsFloatCount` uses
  `isFloatingPointTy()`.

## IR2Vec (lib/Analysis/IR2Vec.cpp, include/llvm/Analysis/IR2Vec.h)

- The opcode keys are Instruction.def's names, including `UncondBr`/`CondBr`, `UserOp1`/`UserOp2` and
  `PtrToAddr`: 69 opcodes.
- The predicate keys `FCMP_<name>` and `ICMP_<name>` are looked up in the **Arguments** section.
- The weights are `cl::opt<float>`, applied as `(double) Weight`. So 0.2 scales by 0.20000000298…
- `Embedding::print` uses `format("%.2f")`: printf's exact round-half-even on the binary value.
- The FlowAware embedder's `InstVecMap` persists across the printer's three sections:
  1. the function vector, which visits blocks in `depth_first` order and fills the map;
  2. the block vectors, in function order;
  3. the instruction vectors.
  An operand whose defining instruction is not yet in the map uses its operand-kind vocabulary entry.
- `print<ir2vec-vocab>` prints every slot: opcodes, canonical types, operand kinds, predicates.
- Vocabulary error messages: `LLVM ERROR: error reading vocabulary: Missing 'Opcodes' section in vocabulary file`,
  `... Vocabulary sections have different dimensions`. Verified with test/Analysis/IR2Vec/Inputs/incorrect_vocab*.json.

## Utility passes

- `IRNormalizer::reorderInstructionOperandsByNames` sorts `(name, Value *)` pairs. Two different operands with the
  same text are therefore ordered by pointer. `printAsOperand` is called without a module slot tracker, so:
  - metadata operands print slot numbers;
  - an unnamed struct type in a constant prints as `%"type 0x…"`, an address. impl/jai fails loudly on both.
- `StripDeadDebugInfoPass` rebuilds `llvm.dbg.cu` from a `std::set<DICompileUnit *>`, which is pointer order.
- `Value::setName` creates the new name in the symbol table before removing the old one (setNameImpl). MetaRenamer's
  `bb`/`bb1` numbering depends on this. Local names are capped at `-non-global-value-max-name-size` (1024).
- `require<loops>,break-crit-edges` preserves loop-simplify form: CriticalEdgeSplittingOptions'
  `PreserveLoopSimplify` defaults to true.
- `ctx-prof-flatten` without `-use-ctx-profile` only removes the `InstrProfCntrInstBase` intrinsics. Those are cover,
  increment, increment.step, callsite, timestamp and value.profile.
