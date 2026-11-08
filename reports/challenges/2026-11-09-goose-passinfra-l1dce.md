# L1.dce can't reach COMPLETE on its own; concurrent builds in the shared tree break `check --update`

- **Date / implementation / unit:** 2026-11-09 / goose / pass infrastructure + L1.dce (also L1.analysis.domtree, L1.analysis.demanded-bits)
- **What happened:**
  1. The L1.dce exit selector is every `::opt` check in `Transforms/{DCE,ADCE,BDCE}`. 9 of those 56 files run other
     passes in the same pipeline (`adce,simplifycfg`, `sroa,adce`, `gvn,simplifycfg,adce`, `loop-mssa(licm)`,
     `instcombine`, `module(debugify)`, `redundant-dbg-inst-elim`) or need unrelated features
     (`--preserve-ll-uselistorder` printing, `--enable-knowledge-retention`). The unit can only become COMPLETE after
     simplifycfg, sroa, gvn, licm, instcombine and debugify units, so "work until COMPLETE" was not achievable.
     Same for L1.analysis.domtree: 2 of its tests need `break-crit-edges` plus the incremental dominator-tree update
     algorithm, a big separate port.
  2. Another agent was working in `impl/goose` at the same time. Its `build.sh` replaces `bin/opt` while my
     `check --update` was running, so a batch of checks failed with "Permission denied" and `--update` reported
     regressions (twice). Its commit also picked up my uncommitted new files once.
  3. computeKnownBits (needed by DemandedBits) pulls in a large part of ValueTracking (isKnownNonZero,
     isImpliedCondition, ConstantRange, assumptions). I ported a core and made every unported path fail loudly;
     deciding where "unknown" is safe and where it silently diverges took real care.
- **Time or effort lost:** ~30 min re-running checks after build races; some time scoping ValueTracking.
- **What would have helped:** exit selectors that only contain tests runnable with the unit's own passes (put
  multi-pass pipelines in a later "integration" unit, or let a unit list `requires: simplifycfg` tests separately);
  a harness option to build into a private directory (or a lock around `build.sh` + check) when several agents share
  one worktree; a roadmap unit for ValueTracking/KnownBits shared by BDCE, InstSimplify and InstCombine.
- **What you did instead:** finished everything runnable with dce/adce/bdce (43 of 56 `::opt` checks and all 56
  `::roundtrip` checks pass; the other 13 fail loudly: 9 need other passes, 2 need unported flags, 2 need
  salvageDebugInfo), reran `--update` when the other agent's build was done, committed only my
  own paths. ValueTracking gaps are listed in `impl/goose/NOTES.md`.
