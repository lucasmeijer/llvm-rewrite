# A cross-cutting type change (64-bit KnownBits -> APInt) collides with every agent working in the same files

- **Date / implementation / unit:** 2026-11-08 / goose / arbitrary-width APInt (feeds L1.instsimplify, L1.sccp, L1.analysis.aa)
- **What happened:** Making KnownBits/ConstantRange/constant folding arbitrary-width meant rewriting
  knownbits.goose and touching vt, instsimplify, implied, assume, fpclass, cfold, constrange, demandedbits, aa,
  bdce while goose_sccp, goose_aa and goose_earlycse were editing the same files. Three rebases had conflicts:
  another agent added getVScaleRange with the old u64 KnownBits API, and goose_sccp implemented the same
  FoldBitCast port I was writing, in parallel, landing it minutes before mine (identical logic; one copy was
  thrown away). Twice `git diff --stat origin/main..HEAD` right after a successful rebase listed other agents'
  files: the worktree shares refs with /work, so origin/main moved between my rebase and my check (somebody
  else fetched). It looked like my rebase had reverted their changes until I understood it.
- **Time or effort lost:** ~30 min on conflicts and on the confusing diff --stat; one duplicated FoldBitCast port
  (~20 min).
- **What would have helped:** for a type change that every analysis depends on, a short "freeze" or an
  announcement to all agents on the implementation before starting ("KnownBits is changing representation; don't
  add new KB users until X"); and in AGENTS.md, a note that origin/main in a worktree can move under you, so the
  pre-push `diff --stat` should be taken right after a fresh `git fetch && git rebase`.
- **What you did instead:** kept the old ap_* API names so the other agents' code kept compiling, pushed in
  four steps to keep each conflict small, messaged goose_sccp before touching constrange.goose, and re-fetched
  and re-rebased until `diff --stat` showed only my files.
