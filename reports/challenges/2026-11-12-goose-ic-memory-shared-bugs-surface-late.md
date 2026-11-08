# Porting the memory/vector visitors mostly exposed bugs in other people's code, and the unit can't complete

- **Date / implementation / unit:** 2026-11-12 / goose / L1.instcombine.memory
- **What happened:** The port itself (InstCombineLoadStoreAlloca.cpp, InstCombineVectorOps.cpp, and the
  InstructionCombining.cpp visitors, about 6k Goose lines) compiled and ran almost on the first try. After that,
  most of the session went into the per-function sweep. Of the 36 silent mismatches it found right after the port,
  only about a third were in my files: two wrong `FoldOpIntoSelect` arguments, the GEP no-wrap flag algebra, and
  the scalable `CreateTypeSize`. The rest were in shared code that had run correctly until then, only because
  nothing had reached it before:
  - `ic.goose` handleUnreachableFrom erased a whole block;
  - ic_compares had "fixed" an LLVM quirk in canRewriteGEPAsOffset;
  - vt's ComputeNumSignBits used the DomConditionCache;
  - the unnamed_addr encoding was off by one in two places;
  - the isStaticAlloca bit was wrong;
  - the cfold non-integral pointer handling was wrong.

  Every new visitor makes more of the other visitors' code reachable. That makes "0 differs at the end" a
  moving target that several agents are changing at the same time.
- **Time or effort lost:** about 40% of the session on shared-code mismatches. The single worst case was the
  `trunc nuw` vs `trunc nuw nsw` difference: about 30 minutes of reasoning through ValueTracking before a
  three-line reduced test showed the difference was the query's missing DomConditionCache.
- **What would have helped:**
  - **Knowing about `opt -debug-counter=instcombine-visit=0-N`.** It works in the release LLVM build and was by
    far the fastest way to see LLVM's intermediate states. I found it by accident, and it should be in the
    debug-mismatch skill.
  - **A goose `-goose-dbg` style trace flag that is always registered.** I added and removed one ad hoc. Flags
    must be listed in flags.goose, or flag_bool silently returns the default, and that cost a rebuild cycle.
  - **A note in the unit description that L1.instcombine.memory's exit tests are mostly library-call tests.**
    36 of the 48 still-failing tests are mem*/str* LibCallSimplifier tests, and 8 more are memory intrinsics. All
    of those belong to the InstCombineCalls.cpp port, so this unit can't reach COMPLETE on its own.
- **What you did instead:** I fixed the shared bugs in place, each with a knowledge/llvm/instcombine.md entry,
  and told the owning agents. I used reduced tests plus `-debug-counter` to compare intermediate states with
  LLVM.
