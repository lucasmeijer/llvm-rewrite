# Sweeping insert-gcov-profiling litters the worktree with .gcno files; the Instrumentor is a unit of its own

- **Date / implementation / unit:** 2026-11-25 / jai / L1.extra.instrumentation.coverage (+ sanitizers.dfsan, asan)
- **What happened:** (1) `./harness/run sweep --passes insert-gcov-profiling` runs LLVM's opt with the worktree as
  cwd, and GCOVProfiling writes `<cu name>.gcno` for every file with an `llvm.dbg.cu`: ~150 untracked files
  (`-.gcno`, `<stdin>.gcno`, `t1.gcno`, ...) appeared in the worktree root, easy to commit by accident with
  `git add -A`. (2) The coverage unit lumps SanitizerCoverage, SanitizerBinaryMetadata, GCOVProfiling, JustMyCode
  and the Instrumentor together. The last two missing pieces are not small: the Instrumentor is ~5000 lines
  (Instrumentor.cpp, its 1300-line header of opportunity classes with per-argument getter/setter callbacks, a JSON
  config reader, a runtime-stub printer) and its default configuration enables *every* opportunity (module, globals,
  functions, allocas, loads, stores, casts, numeric ops, compares, unreachable, base pointers, demangled names), so
  even its 4 default-config tests need nearly all of it; GCOVProfiling needs the .gcno writer, the CFGMST edges and
  the gcda ctor for any CU that isn't split DWARF. The roadmap note made it look like leftovers.
- **Time or effort lost:** ~10 minutes finding and deleting the .gcno files; the Instrumentor was not started.
- **What would have helped:** the sweep (and check) running the oracle in a scratch cwd, like `--per-function`
  already does; splitting L1.extra.instrumentation.coverage into "sancov+sanmd+jmc" and "gcov" and "instrumentor",
  with a size estimate for the Instrumentor.
- **What you did instead:** deleted the untracked `*.gcno`; ported GCOVProfiling's module-level part (split-DWARF
  skip, fork/exec flushes) with a loud failure for real coverage emission; left the Instrumentor for a dedicated
  unit (noted in impl/jai/NOTES.md "Next steps").
