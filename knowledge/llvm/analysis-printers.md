# Analysis printers (`opt -passes='print<…>' -disable-output`)

What the `::analysis` check compares (see `docs/testing.md`). Verified with opt 23.1.5 on `tests/analysis/`.

- **Printers write to stderr**, nothing to stdout, with `-disable-output` (true for every `@analysis` line in the
  corpus). Each printer prints a per-function header
  (`DominatorTree for function: f`, `Loop info for function 'f':`, `Printing analysis 'Scalar Evolution Analysis'
  for function 'f':`, …), in module order of the defined functions; declarations print nothing.
- **Values are printed like the IR printer prints them** (`%5`, `%entry`, whole instructions as in `opt -S`), so
  slot numbering and the instruction printer have to be exact before any printer output can match.
- **Dominator trees** (`DominatorTreePrinterPass` → `DomTreeBase::print`): `[level] %block {DFSIn,DFSOut} [parent level]`;
  the DFS numbers are `{4294967295,4294967295}` (unsigned -1) because the printer doesn't compute them, and the header
  says `DFSNumbers invalid: 0 slow queries.`. `Roots: %entry ` ends with a space. Post-dominator trees start at
  ` <<exit node>>` (two spaces) and list every root: returns/unreachables plus one block per infinite loop
  (`tests/analysis/postdomtree/infinite_loop.ll`).
- **`print<demanded-bits>` iterates a `DenseMap<Instruction*, APInt>`** (`DemandedBits::print`,
  `lib/Analysis/DemandedBits.cpp`), so its line order changes from run to run with heap addresses. Tests use
  `@analysis-unordered`; LLVM's own tests use `CHECK-DAG`.
- **`print<alias-sets>` and `print-callgraph` print pointer values** (`AliasSet[0x…`, `Call graph node <<null function>><<0x…>>`), so
  they can't be compared at all; `import-llvm` skips them as nondeterministic.
- **`print<lazy-value-info>` shows only what is cached**: on its own (or after `require<lazy-value-info>`) it prints just
  the header. LLVM's tests run it after `jump-threading`, so those tests also check jump-threading's queries.
- **`aa-eval`** prints only the summary unless `-print-all-alias-modref-info` (or `-print-no-aliases`, …) is given; the
  pairs come in instruction order of the pointer operands, deterministic.
- **`print<memoryssa>` / `print<memoryssa-walker>` print the whole function** with `Function::print` and an
  `AssemblyAnnotationWriter`: `; <access>` after a block's label line (MemoryPhi) and before each instruction that
  has an access; the header is `MemorySSA for function: f` / `MemorySSA (walker) for function: f`. The function is
  printed like the module printer prints it (attribute-group references `#N`, metadata numbering of the module's
  SlotTracker, numbered struct types). Details: `knowledge/llvm/alias-analysis.md`.
