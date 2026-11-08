# Sweep before/after needs a second worktree; debug-info plumbing was owned by nobody

- **Date / implementation / unit:** 2026-11-08 / jai / debugify, SimplifyDemandedFPClass, LowerDbgDeclare, L1.instcombine triage
- **What happened:** (1) The task asked for "no identical→differs vs the origin/main baseline" for each sweep. The
  harness has no baseline mode, so I kept a second detached worktree on origin/main, rebuilt it after every
  rebase and diffed the two `results.tsv` files with a throwaway script (which first keyed on the file column only
  and silently merged per-function rows). (2) `debugify` itself was 200 lines, but every pass that the debugify
  tests run (DCE/ADCE/BDCE, SROA, InstCombine, mem2reg) needed salvageDebugInfo, head-bit-correct insertion and
  ValueAsMetadata RAUW semantics that nobody owned; three agents (me, simplifycfg, licm) independently set out to
  port salvageDebugInfo within the same day and only messages avoided the duplicate.
  (3) An existing Jai precedence trap (`~cast(u32) A & B` casts the whole `A & B`) silently broke
  foldIntrinsicIsFPClass for weeks; only the per-function sweep surfaced it.
- **Time or effort lost:** ~1 hour on baseline bookkeeping and a wrong comparison; the cross-agent overlap cost
  little because of the messages, but would have cost a day without them.
- **What would have helped:** `sweep --baseline <git-ref>` (build the ref in a temp worktree, print transitions
  per file/function); a list in AGENTS.md of shared "utility" ports (salvageDebugInfo, MemorySSAUpdater, ...) with
  an owner column, so agents claim them before starting; a lint for `~cast(T) X &` / `cast(T) a << b` patterns in
  impl/jai.
- **What you did instead:** the second worktree + `/tmp` comparison script (keying on file+function for
  per-function results), messages to the other jai agents before porting shared Local.cpp pieces.
