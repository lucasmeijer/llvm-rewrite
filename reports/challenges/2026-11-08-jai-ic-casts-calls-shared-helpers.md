# Parallel InstCombine agents keep re-creating the same small helpers under the same global names

- **Date / implementation / unit:** 2026-11-08 / jai / L1.instcombine.cast (InstCombineCalls, X86InstCombineIntrinsic)
- **What happened:** three agents ported InstCombine files into impl/jai at the same time. Jai procedure names are
  global, and each of us needed IRBuilder/InstCombiner one-liners (CreateCall, CreateInsertValue,
  CreateNonTerminatorUnreachable, simplifyNonNullOperand, CreateFAbs, getParamAlign, m_ExtractValue, CreateVectorSplat,
  APIntOps::ScaleBitMask, BAD_FCMP_PREDICATE...). Every rebase produced "matches 2 overloads" / "redeclaration"
  build errors, resolved by deleting my copy and adapting call sites to slightly different signatures.
- **Time or effort lost:** ~1 hour over the session (six rebase/rebuild rounds), plus messages to coordinate.
- **What would have helped:** one shared, agent-owned file for IRBuilder/InstCombiner primitives (ic_core.jai is the
  natural place) with a rule "add builder/matcher one-liners there, grep `^name ::` first", and a cheap script that
  lists top-level procedure names defined in more than one file before pushing.
- **What you did instead:** grepped for every new name before adding it, sent the other agents the list of helpers I
  was adding, and resolved the duplicates at each rebase by keeping the version that landed first.
