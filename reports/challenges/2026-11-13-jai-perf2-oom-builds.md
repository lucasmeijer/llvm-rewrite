# The optimized Jai build was OOM-killed over and over on the shared machine

- **Date / implementation / unit:** 2026-11-13 / jai / compile-time performance (jai_perf2)
- **What happened:** every measurement needs an optimized (LLVM-backend) build of the whole compiler. With
  VERY_OPTIMIZED that one compile idles at 3.6 GB and spikes to ~12.7 GB several times; the VM has 30 GB shared with
  other agents' workspaces (often 15-27 GB "used" by processes invisible from this container), and the cgroup's
  `oom_kill` counter went from 22 to 64 during the session. About two thirds of my build attempts died with exit
  137, some after 6 minutes; one session of six retries lost all six. A message from /root also said another
  agent's pkill may have killed runs, so some 137s may not even have been the OOM killer.
- **Time or effort lost:** roughly 1.5 hours of waiting on retried builds, plus measurements I could not trust
  because the machine was loaded (single-run CPU times varied by 2x; system time spiked to 3-5 s on runs that
  normally take 0.1 s).
- **What would have helped:** a per-workspace memory budget that is visible (`memory.max` reads `max`), or a
  shared build queue for the heavy compiles; and a rule that agents never `pkill` by pattern.
- **What you did instead:** switched the optimized build to OPTIMIZED (O2): peak 3.7 GB, ~3.5% more instructions
  executed at run time. `build.sh` now builds one binary (opt; llc and llvm-link are copies that dispatch on argv[0])
  instead of three in parallel, and retries a compile killed with 137. For decisions I used instruction counts
  (cachegrind/callgrind), which are unaffected by load.
