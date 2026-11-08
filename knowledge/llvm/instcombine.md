# InstCombine: facts that matter for exact output

Verified against LLVM 23.1.5 source (file:function named) and the imported InstCombine tests.

- **`-passes=instcombine` verifies the fixpoint.** PassBuilder's `parseInstCombineOptions` starts with
  `setVerifyFixpoint(true)`, MaxIterations is 1: iteration 1 does the work, iteration 2 must change nothing or opt
  dies with "Instruction Combining on F did not reach a fixpoint after 1 iterations". `instcombine<no-verify-fixpoint>`
  (or the `instcombine-no-verify-fixpoint` function attribute) runs exactly one iteration.
- **Worklist order** (InstructionWorklist.h): prepareWorklist walks reachable blocks in RPO, constant-folds
  instructions whose first operand is constant (`ConstantFoldInstruction`), folds ConstantExpr/ConstantVector
  operands with ConstantFoldConstant, then pushes the survivors in *reverse*, so they pop in program order. New
  instructions from the Builder go on the *deferred* list (`add`), which is flushed in reverse before each pop (so
  they are visited in creation order, before older work). Users of a changed instruction are `push`ed (LIFO).
- **Names.** `Value::takeName(V)` first drops the destination's own name even if V has none, so a replacement
  returned by a visitor always ends up with exactly the old instruction's name. A name set on an unlinked
  instruction (`BinaryOperator::Create(..., "x")`) is only uniqued when the instruction is inserted.
  `canonicalizeICmpPredicate` renames the compare to `getName() + ".not"`, which is `.not` for an unnamed one.
- **SimplifyQuery.** InstCombine's SQ has DT, AC, TLI and the DomConditionCache, so `computeKnownBits` etc. see
  dominating branch conditions — but only of branches already visited (`visitCondBrInst` ends with
  `DC.registerBranch`), which makes results visit-order dependent. `InstCombiner::ComputeNumSignBits` and
  `ComputeMaxSignificantBits` call the `(DL, AC, CxtI, DT)` overloads: no DomConditionCache, and `safeCxtI`.
- **Builders that are not the combiner's.** `foldFDivConstantDivisor` (nnan `X / +0.0` -> copysign) uses a local
  `IRBuilder<> B(&I)`: the new call is not added to the worklist. The Negator's builder inserts each negated
  instruction right before the instruction it negates (with that instruction's debug location), and on success
  the new instructions are handed to the worklist in creation order; on failure they are erased in reverse.
- **`Instruction::isAssociative`**: `fmul` needs only `reassoc`; `fadd` needs `reassoc` and `nsz`
  (Instruction.cpp:1390). So `SimplifyAssociativeOrCommutative` folds `(X * C1) * C2` with just `reassoc`
  (fdiv.ll `div_constant_dividend3`).
- **Unknown profiles.** `createSelectInstWithUnknownProfile` and friends add `!prof !{!"unknown", !"instcombine"}`
  only when the function has an entry count > 0 (`setExplicitlyUnknownBranchWeightsIfProfiled`); IRBuilder's
  plain `CreateSelect` without MDFrom adds nothing.
- **Negator** (`InstCombineNegator.cpp`): `NegatorMaxDepth` defaults to `~0U`, so the depth limit never triggers;
  results (including failures) are cached per value for one negation attempt. A phi is not negated if its block
  dominates the incoming *edge's* block (`DT.dominates(BB, Use)`: for a phi use, the incoming block), which is how
  induction variables are excluded.
- **Pattern details that change results**: `m_ZExt`/`m_SExt`/`m_Trunc`/fp casts are `CastInst_match`
  (instructions only), `m_PtrToInt`/`m_BitCast`/`m_IntToPtr` match constant expressions too; `m_NUWAdd` etc.
  (OverflowingBinaryOp_match) match constant expressions, `m_DisjointOr` only instructions. Two `const APInt *`
  captures compared with `==` (e.g. `C2 == C3` in foldAddWithConstant) compare uniqued constants, i.e. equal
  values of the same type.
