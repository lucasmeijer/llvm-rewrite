# The whole-file sweep sees almost none of an InstCombine visitor; a per-function sweep does

- **Date / implementation / unit:** 2026-11-10 / goose / L1.instcombine.bitwise
- **What happened:** after porting all of InstCombineAndOrXor.cpp, `./harness/run sweep --passes instcombine`
  compared only 1300 of 7704 files (83% stop loudly in some other unported visitor: phi, alloca, load, select...),
  and the unit's own exit tests were the same: 63 of 86 `::opt` tests stop in select/store/shufflevector/phi
  before the and/or/xor code is ever compared. The sweep reported 0 `differs`, but that said little about the
  new code. Splitting every test file into one-function modules (llvm-extract) and comparing each function gave
  10482 compared functions and found 16 silent mismatches the file-level sweep and the unit check had missed
  (matcher semantics: `m_ConstantInt(uint64_t&)` matching splats, api_pred_ty allowing poison, fcmpToClassTest's
  LookThroughSrc default, mergeUndefsWith producing undef; plus bugs in other agents' files).
- **Time or effort lost:** little, once the tool existed (~30 minutes to write it and tools/fuzz_ic.py); without it
  the port would have been pushed with these bugs.
- **What would have helped:** a harness mode `sweep --split-functions` (llvm-extract per function, compare per
  function, report per function). For any pass that fails loudly per instruction kind (InstCombine above all),
  that is the only way to get coverage before the whole pass is ported. The unit's exit selector also can't be
  reached without select, memory and vector visitors (same issue as the arith unit's report).
- **What you did instead:** `impl/goose/tools/ic_func_sweep.py` (per-function sweep, any `--passes`) and
  `impl/goose/tools/fuzz_ic.py` (random integer/bitwise IR differential fuzzer). Both are generic enough to move
  into the harness.
