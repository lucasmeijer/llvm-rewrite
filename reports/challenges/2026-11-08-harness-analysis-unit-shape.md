# L1.harness-analysis was a harness task wearing a per-implementation unit's exit selector

- **Date / implementation / unit:** 2026-11-08 / harness (no impl) / L1.harness-analysis
- **What happened:** the unit's exit was `tests/analysis/*::analysis`, which is checked per implementation, but the
  work was harness work done once for everyone. Once the harness and tests exist, "complete for impl/rust" would mean
  "rust implements every analysis printer in tests/analysis", which is a big aggregate of analysis ports, not harness
  support. I kept the ID (the loop may refer to it), retitled it as that aggregate, and added one `L1.analysis.*` unit
  per analysis with its own exit. Two smaller surprises while importing LLVM's Analysis tests: (1) the importer turned
  `opt -passes=dot-dom -disable-output` into an `@opt` test, and running it wrote `dom.test*.dot` into the repo root
  (now skipped as "writes .dot files"); (2) `print<demanded-bits>` prints in heap-address order, and two runs of LLVM
  agreed by chance on 2 of 8 files, so a two-run determinism check was not enough for the importer.
- **Time or effort lost:** small; ~15 minutes deciding where imported vs hand-written analysis tests go and how the
  unit should read for implementations.
- **What would have helped:** marking harness/infrastructure units as such in the roadmap (e.g. an `exit-impl: llvm`
  field or a "harness" section whose completion is `check --impl llvm`), so they don't show up as per-impl work in
  `status`.
- **What you did instead:** described above; `import-llvm` now runs each printer line six times and picks ordered,
  unordered, or skip.
