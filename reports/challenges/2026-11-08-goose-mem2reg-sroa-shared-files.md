# Concurrent agents on one implementation: a merge silently deleted SROA; units can't finish without other passes

- **Date / implementation / unit:** 2026-11-08 / goose / L1.mem2reg, L1.sroa
- **What happened:**
  1. Four goose agents worked in parallel in their own worktrees. After I had pushed the SROA port, another
     agent's commit (77b3349, L1.instsimplify) deleted `impl/goose/src/sroa.goose` and reverted my changes to
     passmgr/flags/datalayout/mem2reg (and another agent's byte-type support) — apparently a merge resolved by
     taking a stale tree. The ratchet still passed for them because SROA tests were not yet in passing.txt
     when they last ran it, and nothing checks that a commit doesn't delete files it didn't create.
  2. Shared small files (passmgr.goose pass table, flags.goose, datalayout.goose, analyses/A_* ids) were edited
     by everyone; every rebase had conflicts there.
  3. Both units depend on unported things outside their scope: mem2reg's simplifyPHINode needs
     isGuaranteedNotToBePoison and isKnownNonZero (ValueTracking, owned by the instsimplify agent), SROA tests
     run `debugify`, `gvn`, `instcombine`. L1.mem2reg ends at 59/60 and L1.sroa at 119/122 for reasons no
     mem2reg/SROA work can fix.
  4. Goose has one global function namespace: a helper name I added (`cint_sext`) collided with one in ir.goose
     and broke compilation of unrelated files with "ambiguous call".
- **Time or effort lost:** ~30 min diagnosing "0 pass / 61 fail" after a rebase (the file was gone) and
  restoring; ~20 min of conflict resolution in shared files; an hour writing private stubs of ValueTracking
  queries that were then replaced by the other agent's port.
- **What would have helped:** a harness or pre-push check that refuses commits deleting/reverting lines in files
  the commit's unit doesn't own (or at least a warning listing deleted files); registering passes through a
  generated table instead of hand edits in one file; roadmap deps that list cross-cutting analyses (mem2reg →
  ValueTracking poison/known-nonzero) so the analysis lands first; exit selectors that exclude tests whose RUN
  lines need other passes (or a separate "pipeline" bucket).
- **What I did instead:** restored from my pushed commit, messaged the other agent (they restored the rest and
  now diff against origin/main before pushing), prefixed pass-private helpers (`sr_`, `m2r_`), and kept stubs
  failing loudly until the shared port landed.
