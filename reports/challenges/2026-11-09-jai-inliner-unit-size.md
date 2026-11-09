# One task covering CGSCC infrastructure, function-attrs and the whole inliner was far larger than a unit

- **Date / implementation / unit:** 2026-11-09 / jai / L2.function-attrs + L2.inline (+ the CGSCC pass manager)
- **What happened:** the assignment bundled LazyCallGraph, CGSCCPassManager, FunctionAttrs, InlineCost, the
  advisor/InlineOrder, Inliner, AlwaysInliner, ModuleInliner, InlineFunction, CloneAndPrune and ValueMapper changes
  (~10k LLVM lines). Much of the inliner's observable behaviour also depends on analyses no roadmap unit lists:
  ProfileSummaryInfo (13 Transforms/Inline tests only pass with function-entry-count updates; `inline-cold.ll` and
  `inline-hot-callsite*.ll` were *silent* mismatches until PSI existed, because the old stub only failed loudly for
  passes that called `psi_check`), and value-handle semantics in shared code (InstCombine's
  transformConstExprCastCall needed ValueIsRAUWd for devirt<N> to match).
  Two other agents were editing impl/jai at the same time; several builds broke on duplicate helper overloads after
  rebases (same LLVM helper ported twice under one name).
  `./harness/run perf` once reported "could not execute: [Errno 26]/[Errno 2]" for every benchmark (a concurrent
  rebuild of bin/opt); rerunning later worked, but the message does not say which binary it tried.
- **Time or effort lost:** several context compactions; maybe 10% on rebase/duplicate-helper fixes, an hour on the
  PSI gap that the stub hid.
- **What would have helped:** splitting the roadmap into L2.cgscc (LCG + CGSCC PM + print-lcg), L2.function-attrs,
  L2.inline.cost, L2.inline.function, L2.inline.profile (PSI + profile updates); a shared "analysis stubs" list in
  NOTES so a stub that silently answers "no profile" is known to be a stub; the perf harness printing the path it
  executed.
- **What you did instead:** ported PSI fully (psi.jai) and made the inliner use it; grep for a helper's LLVM name
  before adding it.
