# LVI printer differences that only come from stale-cache state across a pass are hard to localize

- **Date / implementation / unit:** 2026-11-08 / jai / L1.cvp, L1.jump-threading, L1.analysis.lvi, L1.analysis.bfi
- **What happened:** after all unit tests passed, the `jump-threading,print<lazy-value-info>` sweep showed one
  real difference in a 1000-line llvm-test-suite function (`constantrange<0, 8>` vs `<1, 8>` for a phi). Running
  the same pipeline on LLVM's *output* IR matched exactly, so the difference was cache state carried through the
  transformation, not the analysis. The cause turned out to be outside LVI: our pass manager rebuilt the
  AssumptionCache after the pass while LLVM keeps the stale one forever. There is no way to dump LLVM's LVI cache
  or AssumptionCache in a release `opt`, so finding it was reasoning plus `llvm-extract` reduction.
- **Time or effort lost:** ~30 minutes on this one; a similar amount on two Jai syntax traps that produced silently
  wrong analysis results rather than compile errors (`cast(u64) a << 32` casts the whole shift; an untyped
  `0xFFFF_FFFF_FFFF_FFFF >> 4` is an arithmetic shift of -1).
- **What would have helped:** a note in docs/testing.md's sweep section: "if a pipeline differs but the same
  pipeline on LLVM's output IR does not, the difference is cached analysis state (value handles, AssumptionCache,
  LVI/SCEV caches)". For Jai, a lint (grep) for `cast(...) <expr> <binary-op>` in new code.
- **What you did instead:** reduced with `llvm-extract --func`, compared `opt -passes=jump-threading` output IR
  (identical), then re-ran the analysis on LLVM's output IR to separate "analysis bug" from "cache-history bug".
  Also: the task said to port BPI/BFI "if tests need them"; 6 of 97 JumpThreading tests (and 8 sweep files) did, and
  the port (~4500 C++ lines incl. ScaledNumber and irreducible-loop handling) was about a third of the total work —
  worth flagging as its own unit size when assigning JT.
