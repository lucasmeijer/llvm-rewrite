# Attribute-gated passes are barely exercised by the corpus sweep; an "inject attribute" sweep mode would help

- **Date / implementation / unit:** 2026-11 / jai / L1.extra.gc-statepoints, L1.extra.hardening (also L1.extra.objcarc)
- **What happened:** rewrite-statepoints-for-gc, place-safepoints, safe-stack and stack-protector only act on
  functions with `gc "statepoint-example"`, `safestack` or `ssp*` (and, for RS4GC, `ptr addrspace(1)` values). The
  whole-corpus sweeps reported 10800+/10800+ identical, but almost every file is a no-op for these passes, so the
  sweep said little beyond the unit's own tests. I wrote throwaway scripts (in /tmp, not committed) that add the
  attribute / GC to every definition of the passing files (optionally rewriting `ptr` to `ptr addrspace(1)`, appending a
  gc.safepoint_poll) and compare against LLVM. They found two real bugs the sweeps could not: PlaceSafepoints visiting
  top-level loops in reversed order (only visible with two loops), and `isa<IntrinsicInst>` being true for unknown
  `llvm.*` callees. Similarly, the roadmap's unit text names ObjCARCAPElim, which no longer exists in LLVM 23 (apelim.ll
  runs objc-arc); a minute lost checking PassRegistry.def.
- **Time or effort lost:** about an hour writing and running the stress scripts (each full-corpus run of a pass with
  a new argument also takes 2-10 minutes with a cold oracle cache, beyond the 10-minute tool timeout, so long sweep
  batches had to go into tmux).
- **What would have helped:** a `sweep --inject-fn-attr=<attr>` / `--inject-gc=<name>` option in the harness (the
  same rewrite, cached oracle outputs, results like any sweep), and the skill text saying which passes are
  attribute-gated so a plain sweep is not mistaken for coverage. The roadmap entry could drop ObjCARCAPElim.
- **What you did instead:** the /tmp scripts (results in impl/jai/NOTES.md "GC statepoints" / "Hardening"); worth
  turning into a harness mode if more attribute-gated passes are ported (sanitizer passes are similar).
