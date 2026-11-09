# Jai perf numbers were mostly the x64 backend; long builds and background jobs needed workarounds

- **Date / implementation / unit:** 2026-11-09 / jai / compile-time performance task
- **What happened:** `harness/run perf` reported jai at ~3.9x LLVM, and NOTES.md listed many per-pass slowdowns
  (SCEV 7-15x, DSE 15x, ...). Almost all of it was the x64 backend: the same sources built with the LLVM backend
  (`-o`) are at 0.78x. Every earlier per-pass perf note was measured on the debug-quality build, so they pointed at
  the wrong hotspots. The optimized build takes ~2 min, so it can't be the default for `check`.
  Process friction on the way: (1) background jobs started from the Bash tool (`cmd &`) are killed when the tool call
  returns; only tmux sessions survive, which cost two lost 2-minute builds. (2) Running `build.sh` (x64) while an
  optimized build was in progress deleted the other build's `.build` objects (shared intermediate dir) — fixed by a
  per-build `intermediate_path`. (3) Editing sources during a 2-minute build could put a stale binary under the new
  source hash — fixed by compiling a snapshot. (4) The first baseline `perf` run had `Errno 26` (text file busy) /
  `Errno 2` rows: the binary was being replaced while perf ran.
- **Time or effort lost:** ~30 min on lost builds and re-runs; the misleading per-pass notes would have cost more if
  followed blindly (profiling the x64 build shows backend artefacts as hotspots).
- **What would have helped:** a note in docs/testing.md that perf numbers depend on the impl's build mode and that
  perf.env can select it; a sentence in the agent instructions that background processes must run in tmux.
- **What you did instead:** `JAI_BUILD=optimized` via `impl/jai/perf.env`, a content-hash build cache in
  `impl/jai/bin/.cache` so check/perf switch modes with a copy, and callgrind on the optimized build for profiling.
