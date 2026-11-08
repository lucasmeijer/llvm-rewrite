# One agent for InstCombineCalls + Casts + X86 + TLI + BuildLibCalls + SimplifyLibCalls is several units of work

- **Date / implementation / unit:** 2026-11-11 / goose / L1.instcombine.calls (+ inferattrs)
- **What happened:** the task bundled ~20k lines of LLVM C++ (InstCombineCalls 5.5k, X86InstCombineIntrinsic 3.5k,
  rest of InstCombineCasts 1.5k, SimplifyLibCalls 4.7k, BuildLibCalls 2.3k, TargetLibraryInfo 1.5k). The calls part
  also depended on helpers another agent (goose_ic_memory) was writing at the same time (builders for loads/stores/
  shuffles, loads.goose, memorybuiltins) that were not pushed for the first ~2 hours, so nothing of ic_calls could be
  compiled. Two more agents changed central types (`Val.ty` → TyId, `Inst.op` removed) mid-way.
- **Time or effort lost:** ~30 min building a scratch overlay (/tmp) of the other agent's uncommitted files to compile
  against; a few rebases with type-change fixups. X86InstCombineIntrinsic and most of SimplifyLibCalls (pow, log,
  fortified calls, sprintf/fprintf/snprintf, str* copy functions) are not done.
- **What would have helped:** split the unit (calls; casts; x86; TLI+BuildLibCalls+inferattrs; SimplifyLibCalls);
  ask agents that create shared helpers to push them first (even as fail-loudly stubs), before porting visitors on
  top of them.
- **What you did instead:** ported in sweep-impact order (generic intrinsics → casts → libcall dispatcher with
  per-LibFunc fail-loud stubs → X86 SimplifyDemanded hooks), keeping the per-function sweep at 0 silent mismatches.
  The generated statement-program approach for BuildLibCalls' 1100-line switch (tools/gen_libfunc_attrs.py) worked
  well and is reusable for other big LLVM switches made of setter calls.
