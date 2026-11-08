# SCCP and IPSCCP (LLVM 23.1.5)

Facts needed to reproduce `-passes=sccp` and `-passes=ipsccp` exactly. Sources:
`lib/Transforms/Utils/SCCPSolver.cpp`, `lib/Transforms/Scalar/SCCP.cpp`, `lib/Transforms/IPO/SCCP.cpp`,
`lib/Transforms/Utils/PredicateInfo.cpp`, `include/llvm/Analysis/ValueLattice.h`. "Verified" means a test in
`tests/imported/llvm/Transforms/SCCP/` that only passes with the behaviour described, unless noted.

## PredicateInfo
- In LLVM 23 the SSA copies are **no-op `bitcast X to T`** instructions, not `llvm.ssa.copy` calls. The
  solver recognises them as "a bitcast with equal source and destination type that has predicate info"
  (`getPredicateInfoFor`), and `removeSSACopies` RAUWs and erases them at the end. Copies that SCCP proved
  constant are replaced and erased by `simplifyInstsInBlock` like any other instruction first.
- Edge copies are inserted before the branch block's terminator and named `<op name>.<n>`, with a counter
  per renamed operand starting at 0 (an unnamed operand gives `.0`). Assume copies go right after the assume,
  unnamed. The names go through the function's symbol table, so they can bump its `LastUnique` counter.
- Assumptions are visited in `AC.assumptions()` order (instruction order for a fresh cache), after all
  branches/switches in block order.

## Solver details that change output
- `visitBinaryOperator` calls `simplifyBinOp(Opc, V1, V2, SimplifyQuery(DL, &I))`: a context instruction
  but **no DT, no AC, no TLI, no DomConditionCache** (Goose: `sq_no_dt/sq_no_ac/sq_no_tli` in vt.goose).
- `ValueLatticeElement::getCompare` folds two constants with `ConstantFoldCompareInstOperands` **without an
  instruction**. `FlushFPConstant(C, nullptr)` treats the denormal mode as Dynamic, so an fcmp with a
  denormal FP operand is never folded there, even in functions without `denormal_fpenv`
  (`no-fold-fcmp-dynamic-denormal-mode-issue114947.ll`).
- `getValueFromMetadata` uses `CallBase::getRange()`, which **intersects** the call-site `range` return
  attribute with the called function's (an empty intersection gives the "unknown" lattice value)
  (verified with `Inline/ret_attr_align_and_noundef.ll` under `-passes=sccp`).
- `getArgAttributeVL` uses `Argument::hasNonNullAttr()`, which is also true for `dereferenceable(N>0)`
  when null is not a valid pointer (`pointer-nonnull.ll`).
- PHIs with more than 64 incoming values are overdefined immediately; PHI merges allow
  `#feasible incoming + 1` range widenings, call results/arguments/loads of tracked globals 10.

## IPSCCP
- `canTrackArgumentsInterprocedurally` needs `hasExactDefinition && hasLocalLinkage && !hasAddressTaken`.
  A `blockaddress(@f, %bb)` is **not** a use of `@f` in LLVM 23 (BlockAddress only refers to the block), so it
  does not count as taking the address (`indirectbr.ll`, `ipsccp-clear-returned.ll`).
- `noipa` makes a definition interposable (`isInterposable` checks `isNoipaFnDef`), and `nobuiltin`
  definitions "may be derefined", so neither has an exact definition (`noipa.ll`).
- `ipsccp` runs FunctionSpecialization by default (`IPSCCPOptions(AllowFuncSpec = true)`); it only
  specializes functions whose TTI code size is at least 500 and that have direct call sites with constant
  arguments. On sqlite3, lua and SPASS (`tests/perf/compile`, after `function(sroa)`) LLVM's ipsccp output is
  identical to ipsccp without specialization (checked by building Goose with the specializer check disabled).
- Deleting a tracked global that turned out constant rewrites its single `DIGlobalVariableExpression`'s
  expression in place to `DW_OP_constu <value>, DW_OP_stack_value` (`getExpressionForConstant`; `pr50901.ll`).
- When a folded call is erased, the callee's `!implicit.ref` attachments are appended to the caller
  (`implicit-ref-propagation.ll`).

## Transformations
- A folded instruction is erased only if `wouldInstructionBeTriviallyDead(&Inst)` (SCCPSolver.cpp
  simplifyInstsInBlock), called **without a TargetLibraryInfo**: a call to `log(1.0)` is replaced by `0.0` but stays
  (no isMathLibCallNoop, no library alloc/free knowledge), unlike after instsimplify (DCE/calls-errno.ll,
  EarlyCSE/math-1.ll under `-passes=sccp`).
- `changeToUnreachable` puts the new `unreachable` before the first non-PHI and adopts the debug records
  attached there; the records of the erased instructions move forward and those of the old terminator end
  as trailing records, which `flushTerminatorDbgRecords` gives to the new `unreachable`
  (`InstCombine/salvage-dbg-declare.ll` under `-passes=ipsccp`).
- `SwitchInst::removeCase` moves the **last** case into the removed slot (case order changes);
  `SwitchInstProfUpdateWrapper` moves the branch weight the same way and rewrites `!prof` only if a case was
  removed and at least 2 weights remain. An infeasible default goes to one new `default.unreachable` block per
  function, inserted before the old default destination.
- `refineInstruction` adds `nuw`/`nsw` (add/sub/mul/shl), `nneg` (zext/uitofp), trunc `nuw`/`nsw`, and GEP
  `nuw` (only when the GEP is `nusw` and all indices are non-negative). `replaceSignedInst` turns sext/sitofp/
  ashr/sdiv/srem with non-negative operands into zext nneg/uitofp nneg/lshr/udiv/urem, taking the old name.

## Constant folding facts found on the way
- GEP offsets index vectors by the element's **store size** (`getSequentialElementStride`), arrays by alloc
  size: with `f16:32`, `getelementptr <2 x half>, ptr @g, i64 0, i64 1` is 2 bytes (InstCombine/getelementptr.ll).
- `ConstantFoldLoadFromUniformValue` refuses constants whose size differs from their store size (an `i1 true`
  global loaded as `i8` is not folded; InstSimplify/ConstProp/loads.ll).
