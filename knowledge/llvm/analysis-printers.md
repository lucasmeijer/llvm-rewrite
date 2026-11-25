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
  `@analysis-unordered`; LLVM's own tests use `CHECK-DAG`. A non-integer operand prints `getAllOnes(DL.getTypeSizeInBits(T->getScalarType()))`
  through `getLimitedValue`: a pointer under `p:32` is `0xffffffff`, x86_fp80 is 64 ones; a metadata operand hits
  `llvm_unreachable` (undefined in release builds; it happens to print 64 ones).
- **`print<alias-sets>` and `print-callgraph` print pointer values** (`AliasSet[0x…`, `Call graph node <<null function>><<0x…>>`), so
  they can't be compared at all; `import-llvm` skips them as nondeterministic.
- **`print<lazy-value-info>` shows only what is cached**: on its own (or after `require<lazy-value-info>`) it prints just
  the header. LLVM's tests run it after `jump-threading`, so those tests also check jump-threading's queries.
- **`aa-eval`** prints only the summary unless `-print-all-alias-modref-info` (or `-print-no-aliases`, …) is given; the
  pairs come in instruction order of the pointer operands, deterministic.
- **`print<memoryssa>` / `print<memoryssa-walker>` print the whole function** with `Function::print` and an
  `AssemblyAnnotationWriter`: `; <access>` after a block's label line (MemoryPhi) and before each instruction that
  has an access; the header is `MemorySSA for function: f` / `MemorySSA (walker) for function: f`. The function is
  printed like the module printer prints it (attribute-group references `#N`; metadata numbered like a single-function print: module-level slots, then this function's;
  numbered struct types). Details: `knowledge/llvm/alias-analysis-and-memoryssa.md`.
- **Small printers** (verified with impl/jai/src/analysis_printers_misc.jai, Analysis/{AssumptionCache,CallGraph,
  MustExecute,PhiValues} and ValueTracking/*deref*):
  - `print<assumptions>` (AssumptionCache.cpp): `Cached assumptions for function: f`, then per assume in
    AssumeHandles order: `  ` + `*Cond` (an instruction prints with its own two leading spaces, so 4 in total), or
    for a bundle-only assume `  [ "tag"(ty %v, ...), ... ]` (inputs with `printAsOperand(OS)` = with type).
  - `print-callgraph-sccs`: `SCCs for the program in PostOrder:` then `\nSCC #N: f, g` (scc_iterator from the
    external calling node, nodes in SCC order, `external node` for the null-function nodes), ` (Has self-loop).` for
    a single-node SCC with a self edge; one final newline.
  - `print<phi-values>`: getValuesForPhi on every phi in block order first, then `PHI %p has values:` and the non-phi
    reachable values in SmallSetVector (insertion) order: instructions as `*I`, other values as `  ` + `*V` (so a
    global prints its whole definition line `@X = common global i32 0`); `  NONE` / `  UNKNOWN`.
  - `print<mem-derefs>`: for each load in order, isDereferenceablePointer and isDereferenceableAndAlignedPointer with
    `SimplifyQuery(DL, LI)` (no TLI/DT/AC); one line per load (duplicates kept): `  ` + `V->print` + `\t(aligned)` or
    `\t(unaligned)`. Looks through gc.relocate (getDerivedPtr).
  - `print<must-execute>` prints the function (`F.print` with an annotation writer) with ` ; (mustexec in: H)` or
    ` ; (mustexec in N loops: H1, H2)` after the metadata of each instruction (printInfoComment, after the gc.relocate
    comment), innermost loop first; the test per loop is **SimpleLoopSafetyInfo** (blockMayThrow = any block of the
    loop may throw) or isGuaranteedToExecuteForEveryIteration, not the ICF variant LICM uses.
  - `print-must-be-executed-contexts`: `-- Explore context of: *I` then `  [F: f] *CI` for the explorer's range
    (ExploreInterBlock/CFGForward/CFGBackward all true, LI/DT/PDT getters always compute).

## IR printers and small printers of the pass registry (verified by whole-corpus sweeps, jai_registry_gap)

- **`print`** exists at module, function and loop level (PrintModulePass / PrintFunctionPass / PrintLoopPass, all
  to stderr, empty banner). The function form is `OS << '\n' << F`, i.e. `Value::print`, which builds a
  ModuleSlotTracker with *ShouldInitializeAllMetadata*: every function's metadata is numbered (module order) before
  the printed function's, but only the printed function's call-site attribute groups get `#N` slots (after the
  functions' own attribute sets). The loop form prints `; Preheader:` + block, `; Loop:`, the loop blocks,
  `; Exit blocks` + the exit blocks, each with `BasicBlock::print` (a fresh SlotTracker of the function).
  LLVM's per-function ModuleSlotTracker makes `function(print)` quadratic (25 s on SPASS.ll).
- **print<cfg-sccs>**: scc_iterator order, blocks as operands separated by ", ", " (Has self-loop)." for a
  single-block SCC with a self edge.
- **print<domfrontier>** prints `DominanceFrontierBase::Frontiers`, a `std::map<BasicBlock *, SetVector>`: the
  block order is pointer order (the test uses CHECK-DAG); the sets are SetVectors in insertion order.
- **print<module-debuginfo>**: DebugInfoFinder starts from `M.debug_compile_units()`, which skips CUs with
  `emissionKind: NoDebug` (a CU reached through a subprogram's `unit:` is still listed).
- **print<inline-cost>**: one InlineCostCallAnalyzer per direct call of a defined function with getInlineParams(),
  the cached PSI, no GetBFI and an ORE, so ComputeFullInlineCost is on (no early stop at the threshold). The callee
  is printed with `; cost before = ..., cost after = ..., threshold before/after, cost delta [, threshold delta]
  [, simplified to <Value::print>]` before every instruction (`; No analysis for the instruction` for ones never
  visited). A simplified *constant* is printed with a fresh TypePrinting (no module), so an unnamed struct type
  prints as `%"type 0x<address>"`; a simplified global prints its whole definition.
- **print<uniformity>** on a target without branch divergence (x86, no target):
  `UniformityInfo for function 'f':` + `  Uniformity analysis not computed (no branch divergence).`
- **print<inline-advisor>** without a cached InlineAdvisorAnalysis prints `No Inline Advisor`.
- **print-callgraph, dot-* / view-*, print-lcg-dot, print<ddg>** print heap addresses (`<<0x...>>`, `Node0x...`,
  `Node Address:0x...`): nothing to compare.
