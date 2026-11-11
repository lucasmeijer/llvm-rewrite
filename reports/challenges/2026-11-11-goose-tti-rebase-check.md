# Rebasing onto other agents' commits without re-running the check broke the shared build

- **Date / implementation / unit:** 2026-11-11 / goose / L1.analysis.cost-model
- **What happened:** I replaced the Goose x86 TTI wholesale (new value-type encoding, TargetLowering tables, all
  helpers renamed). While I worked, /root/goose_inline pushed L2.inline, whose inline_cost.goose used three of the
  old helpers (`EVT_OTHER`, `evt_to_mvt`, `x86_mvt_legal`). My full ratchet ran on the tree *before*
  `git rebase origin/main`; after the rebase I only inspected `git diff --stat origin/main..HEAD` (which correctly
  showed only my files) and pushed. main did not build for one commit (d463ea4, fixed in 32e6b80). The same
  pattern nearly repeated for the next push: `git log HEAD~3..origin/main` looked like it showed only jai commits,
  but the goose inline commits were already below.
- **Time or effort lost:** ~15 minutes, plus a broken main for the other goose agents in that window.
- **What would have helped:** a harness/script step `publish` that fetches, rebases, runs the ratchet on the result
  and pushes only if it passes (and refuses if the rebase brought in commits touching the same impl since the last
  check). "diff --stat only shows my files" is not evidence that the rebased tree builds: the conflict was
  semantic, between my files and theirs.
- **What you did instead:** fixed inline_cost.goose's getFPOpCost on the new API, told /root/goose_inline, and from
  then on ran the full check after every rebase, right before the push. Generators for big target data
  (TableGen `--print-records`, a C++ → Goose translator of the X86TargetLowering constructor) made the port itself
  smooth; the 122 cost-model tests passed on the first full build.
