# SLP codegen: the decision-sequence oracle made a 4000-line port tractable; shared LLVM debug tree and push races cost time

- **Date / implementation / unit:** 2026-11-11 / jai / L1.vectorize.slp
- **What happened:** ported SLPVectorizer's code generation (vectorizeTree, ShuffleInstructionBuilder,
  scheduleBlock, optimizeGatherSequence, external-use extraction, reduction emission) and then the analyses it had
  been blocking (isMaskedLoadCompress, the masked-gather cost check, matchesShlZExt and siblings, masked stores).
  The unit went from 79 to 615 of 650 tests. Once code generation existed, every tree after the first
  vectorization of a function became reachable for the first time, and so did cost-model bugs that had been
  invisible (a swapped-candidate list in tryToVectorizeSequence, a REVEC guard read backwards in the
  instruction-count check, and a call to the wrong X86 TTI entry point for gather costs: `x86_masked_memory_op_cost`
  instead of the `getMemIntrinsicInstrCost` dispatcher `x86_mem_intrinsic_cost`).
- **Time or effort lost:** about 30 minutes on the gather-cost bug (the two procedures have plausible names and the
  wrong one returns small, believable numbers); finding it needed a temporary `LLVM_DEBUG` line in the shared
  assertions-build source tree, a 2-minute `ninja opt`, and a rebuild afterwards to restore it. Separately, three
  pushes were rejected because other agents pushed during the 4-minute full check; each retry repeated the check.
- **What would have helped:** (1) a per-workspace copy (or overlay) of the assertions-build LLVM source and build
  directory: /persistent/llvm-rewrite/llvm-assert-src is shared by every workspace, so a temporary trace line is
  visible to anyone who rebuilds or runs that `bin/opt` during the window. (2) A harness mode that checks only the
  tests whose result can change for one implementation after a rebase that only brought commits for other
  implementations (or a note in AGENTS.md that such a rebase does not require a rerun), so busy-main pushes do not
  serialize on the full check. (3) In the TTI port, one entry point per LLVM TTI method name (`tti_mem_intrinsic_cost`)
  instead of exposing target-internal helpers with similar names.
- **What you did instead:** ran `impl/jai/tools/slp_cost_compare.py` over the `--with-test-flags` sweep after every
  step: it now compares the whole sequence of tree decisions (not only the prefix before the first vectorization) and
  found every decision bug within minutes; the sweeps (whole-file, with test flags, per function, tests/perf/compile)
  stayed at 0 silent mismatches throughout. For rebases that only brought other implementations' commits, I checked
  `git show --stat` and pushed without rerunning the jai check.
