# InstCombine select unit: the port is done, but whole-file tests can't show it; per-function sweeps can

- **Date / implementation / unit:** 2026-11-11 / goose / L1.instcombine.select
- **What happened:** I ported InstCombineSelect.cpp and InstCombinePHI.cpp whole, plus SimplifyDemandedVectorElts
  (about 4,900 lines of Goose). The unit went from 0/49 to only 12/49 `::opt`. Each of the other 37 files stops first
  at a visitor outside this unit: fadd, load, freeze, fpext, the min/max/ctlz intrinsics, vector ops. Real evidence
  came from `tools/ic_func_sweep.py`, which runs `llvm-extract` on each function and compares the result: 0 functions
  differ across all InstCombine tests, and a select-heavy variant of `tools/fuzz_ic.py` also found 0 differences.
  Once select and phi ran, the sweep found five latent bugs in code other agents had already pushed:
  - `matchSymmetricPhiNodesPair` was a stub that silently returned false;
  - the arms of `foldBinOpOfSelectAndCastOfSelectCondition` were swapped;
  - the Negator gave its swapped select a name that LLVM drops;
  - `containsUndefElement` counted poison lanes;
  - `(mul (div exact X, C0), C1)` only accepted splat constants.

  None of these could show up earlier, because every test containing a select stopped before reaching that code.
- **Time or effort lost:** little was lost on the port itself. About an hour went on tracing diffs into files I don't
  own and checking that each fix matched LLVM. One near-trap: `ic_common.goose`'s `icmp_is_lt`/`icmp_is_gt` include
  the non-strict predicates, but LLVM's `ICmpInst::isLT/isGT` are strict. Reusing the shared helper silently
  miscompiled one fold, and only the sweep caught it.
- **What would have helped:**
  - Make the per-function sweep a harness mode (`check --per-function` or `sweep --per-function`) and use it as the
    unit's evidence, since file-level exit selectors cannot complete until almost all of InstCombine exists.
  - Give shared helpers LLVM's exact names and semantics, or name the differences (`icmp_is_lt_or_le`).
- **What you did instead:** I used per-function sweeps and the fuzzer as the acceptance test, fixed the shared bugs
  in place with LLVM file and line references, and wrote down the strict isLT/isGT trap.
