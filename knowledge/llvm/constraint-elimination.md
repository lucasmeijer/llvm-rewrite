# ConstraintElimination

Facts about `Transforms/Scalar/ConstraintElimination.cpp` and `Analysis/ConstraintSystem.cpp` (LLVM 23.1.5).
Verified by porting both (impl/jai/src/pass_constraint_elimination.jai, constraint_system.jai): all 104 imported
tests and whole-file / `--per-function` sweeps of `-passes=constraint-elimination` (also after `sroa`, after
`debugify`, with `-constraint-elimination-max-rows=3`) are identical.

- **Arithmetic.** In 23.1.5 the constraint system is plain `int64_t` with `AddOverflow`/`SubOverflow`/`MulOverflow`
  (wrapped result + flag), not DynamicAPInt. A row whose combination overflows during Fourier–Motzkin is dropped,
  and elimination gives up ("may have a solution") once a system grows past 500 rows (hard-coded, independent of
  `-constraint-elimination-max-rows`, which only stops *adding facts* once a system has more rows than that).
  Entry ids are `uint16_t`.
- Rows are sparse `(coefficient, id)` lists sorted by id; FM elimination always removes the *last* variable
  (`NumVariables - 1`), swapping rows that mention it to the back. The order rows are produced in therefore depends
  on the order facts were added, i.e. the worklist order below.
- **Worklist order.** Facts and checks are collected per block in function order (unreachable blocks skipped), then
  `stable_sort`ed by DFS-in number of the dominator-tree node; on ties condition facts come first (among them those
  with a ConstantInt operand first), the rest by `comesBefore` of their context instruction. Uses of an `icmp` are
  checks in use-list order; a phi use's context is the incoming block's terminator.
- Function arguments are pre-registered as variables in both systems, and the unsigned system gets `arg >= 0` rows
  for each of them up front. Every new variable added by an unsigned fact gets a `v >= 0` row too.
- `getConstraintForSolving` turns a signed predicate into an unsigned one when both operands are known
  non-negative (`isKnownNonNegative` at depth `MaxAnalysisRecursionDepth - 1`, no context); `ule 0, x` /
  `uge x, 0` short-circuit to an all-zero row, which is *invalid* (and so unproven) when the unsigned system has no
  variables yet (`Coefficients.size() > 0` check).
- `samesign` matters: an unsigned check with samesign is retried with the signed predicate, and a samesign fact is
  added to the other system directly instead of going through `transferToOtherSystem`.
- The pass requests ScalarEvolution and LoopInfo (for induction facts in loop headers) and preserves DT, LoopInfo,
  SE and the CFG. `-constraint-elimination-dump-reproducers` builds a reproducer module as an optimization remark.
