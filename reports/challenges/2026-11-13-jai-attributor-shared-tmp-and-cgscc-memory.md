# Shared /tmp helper scripts get overwritten by other agents; a per-SCC memory leak only showed on one perf file

- **Date / implementation / unit:** 2026-11-13 / jai / L1.extra.attributor
- **What happened:**
  1. I kept my build and diff helpers in `/tmp/jb.sh` and `/tmp/d.sh`. Another agent in the same container wrote its
     own `/tmp/jb.sh`, which `cd`s into its worktree (`/work-wt/jai_sanitizers`). My next "build" compiled the
     other agent's tree and printed its compile errors. I noticed only because the errors named another worktree.
     Before that, a silently-succeeding build of the wrong tree would have made me test a stale `bin/opt`.
  2. The full Attributor runs once per SCC in `attributor-cgscc`. Its per-run state (1-2k AAs, each with its
     extension structs, arrays and tables) was never freed, because `atr = .{}` just drops the old state. Every test
     in the corpus passed. Only the sweep over `tests/perf/compile` showed the leak: SPASS.ll ended as
     `[signal 9] [exit -9, no stderr]`. Finding out that this was the OOM killer and not the CPU timeout took a
     manual RSS sampling loop.
  3. The unit's goal ("sweeps reach 0 differs") does not say what to do about loud failures that LLVM's own
     behaviour makes unreachable. One case is a DenseMap keyed by `Function *` deciding value names, which depends on
     allocation addresses. Another is `-attributor-print-call-graph`, which prints node addresses. I kept both loud
     and documented them.
- **Time or effort lost:** about 15 minutes on the `/tmp` collision. About 30 minutes on the CGSCC memory issue: an
  hour-long sweep was killed, then I diagnosed and fixed it.
- **What would have helped:**
  - A note in AGENTS.md: "`/tmp` is shared by all agents in the workspace; keep scratch files under
    `/tmp/<your task name>/`".
  - The harness sweep reporting peak RSS (or "killed by signal 9, likely out of memory") for failed runs.
  - A perf benchmark or scaling test that runs a CGSCC pass over a module with many SCCs. It would catch per-SCC
    leaks early, for any CGSCC pass.
- **What I did instead:**
  - Moved my scripts to `/tmp/jattr/`.
  - Gave the Attributor a per-run Flat_Pool. `atr_new(T)` points every array and table inside T at the pool, and
    `atr_reset` frees it. This is recorded in impl/jai/NOTES.md. Other passes that keep state across CGSCC runs
    could use the same pattern.
