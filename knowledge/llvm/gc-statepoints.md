# GC statepoints: rewrite-statepoints-for-gc, place-safepoints, verify<safepoint-ir>

Verified against LLVM 23.1.5 (`lib/Transforms/Scalar/RewriteStatepointsForGC.cpp`, `PlaceSafepoints.cpp`,
`lib/IR/SafepointIRVerifier.cpp`) with the 78 imported tests and a stress run over the corpus (see impl/jai NOTES).

- Only `gc "statepoint-example"` and `gc "coreclr"` are rewritten (GCStrategy::useRS4GC); both treat exactly
  `ptr addrspace(1)` (and vectors of it) as GC pointers. Other builtin GCs (erlang, ocaml, shadow-stack) are skipped;
  an unknown GC name is a fatal "unsupported GC: <name>".
- RS4GC's asserts are no-ops in release: values of first-class aggregate type containing GC pointers are simply never
  live; with `-rs4gc-allow-statepoint-with-no-deopt-info=false` a call without a deopt bundle is still rewritten.
- A call's own GC-pointer arguments are in its live set (findLiveSetAtInst scans the call itself, then removes only
  the call's result).
- The statepoint is first named `safepoint_token` (call) / `statepoint_token` (invoke) and then renamed
  `statepoint_token`, so the second statepoint of a function gets `statepoint_token1` etc. The gc.result takes the
  name of the call while the call still exists (uniquified: `%call1`).
- PlaceSafepoints visits top-level loops in LoopInfo order (TopLevelLoops, reverse program order), subloops first,
  then sorts the poll locations by *block name* with std::sort (unnamed blocks tie; std::sort is an insertion sort
  below 17 elements) and removes adjacent duplicates. The entry safepoint goes before the first call that is not an
  `llvm.*` callee other than statepoint/patchpoint; any callee named `llvm.*` counts as an intrinsic here, even an
  unknown one.
- SafepointIRVerifier (LLVM 23's CondBrInst has operands [cond, succ0, succ1]): for `br i1 true` it marks operand
  `Cond ? 1 : 2` dead, which is now the *taken* successor's edge (the code was written for the old BranchInst
  operand order). Ported as is (read from the source; no test covers it).
