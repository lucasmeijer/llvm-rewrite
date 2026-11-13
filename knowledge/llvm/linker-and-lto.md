# llvm-link and the LTO pipelines (LLVM 23.1.5)

Verified against `tools/llvm-link/llvm-link.cpp`, `lib/Linker/{LinkModules,IRMover}.cpp`,
`lib/Passes/PassBuilderPipelines.cpp` and the corpus (`tests/lto/`, `tests/imported/llvm/Linker/`, both passing for
impl/jai with a faithful port, so every claim below has tests behind it).

## llvm-link

- **Every input is linked into an empty composite module** named `llvm-link` (ModuleID and `source_filename` are
  both `llvm-link`; nothing copies the inputs' source_filename). The first file is linked like the others, so even a
  single-file `llvm-link a.ll` goes through IRMover (and can change the module: unreferenced `linkonce` globals are
  dropped, structurally identical named structs merged, globals reordered).
- **All files are parsed into one LLVMContext**, one after the other, each right before it is linked. Struct type
  names are unique per *context* (`StructType::setName`): the second module's `%struct.S` is renamed
  `%struct.S.<N>` with a context-wide counter starting at 0 (`NamedStructTypesUniqueID`), and names stay taken
  after the source module is gone.
- **No default data layout**: llvm-link parses without opt's data-layout callback, so a module without
  `target datalayout` stays without one (opt would fill in the triple's default). The composite takes the first
  non-default data layout and the first non-empty triple; later triples are merged with `Triple::merge`, which keeps
  the destination's string unless the vendor is Apple.
- **Type mapping (TypeMapTy)**: in 23.1.5 `recursivelyAddMappingIfTypesAreIsomorphic` records only identity mappings
  (the `MappedTypes[SrcTy]` entry is created null and the final `insert` does not overwrite it); its only lasting
  effect is clearing the *name* of an isomorphic source struct. `TypeMapTy::get` then maps an identified struct by
  its (mapped) body through `IdentifiedStructTypeSet::findNonOpaque`, keyed by (element types, packed), which keeps
  the *first* struct inserted with a body. So two differently named structs with the same body are merged, also
  within one module.
- **Linkage resolution** is `ModuleLinker::shouldLinkFromSource`; linkonce / available_externally / local globals
  that nothing references are not linked at all (lazy linking through `addLazyFor`). Common symbols: the larger wins,
  alignment is the maximum. Visibility is the most restrictive, unnamed_addr the weakest of the two.
- **Order**: functions appear in the order they are materialized (the IRLinker worklist and the ValueMapper's
  LIFO worklist of bodies); after all bodies, every non-appending global variable *named in the source module* is
  moved to the end of the global list in source order — including existing destination globals that the source only
  declares.
- **Renaming**: a new global first gets a uniqued name if it clashes, then `forceRenaming` gives it the real name and
  renames the old (to-be-replaced) declaration with the module's `.N` counter; internal globals keep the uniqued
  name. The counter is the module symbol table's `LastUnique`, so these renames shift later suffixes.
- **Appending globals** (`llvm.global_ctors`, `llvm.used`, ...) become a new variable inserted where the old one was;
  ctor entries whose key (third field) is not linked are dropped.
- **Named metadata**: operands are appended, but an operand already present in that destination node (across all
  linked modules) is skipped (`IRMover::NamedMDNodes`), so `!llvm.ident` keeps one copy. Module flags are merged by
  behavior (`linkModuleFlagsMetadata`): Min/Max pick a value, Append/AppendUnique make the tuple distinct and extend
  it, Require is checked at the end; the flags are added *unmapped*.
- **Metadata** is mapped with `RF_ReuseAndMutateDistinctMDs`: distinct nodes are reused and their operands mutated,
  uniqued nodes are rebuilt only when an operand changes (in practice: a ConstantAsMetadata of a source global).
  `enableDebugTypeODRUniquing` is on, so `DICompositeType`s with an identifier are shared across modules.
- `-internalize` internalizes, in every file after the first, the symbols that file brought in;
  `-only-needed` links only what the destination references.

## LTO pipelines

- **clang `-O2 -flto`** = `clang -O2 -flto -Xclang -disable-llvm-passes` followed by `opt -passes='lto-pre-link<O2>'`,
  plus two module flags clang adds when it writes LTO output (`ThinLTO` = 0, `EnableSplitLTOUnit` = 1) and the module
  summary. Checked on the corpus' C programs (identical IR otherwise).
- `lto-pre-link<O#>` is `buildPerModuleDefaultPipeline(FullLTOPreLink)`: no memprof-remove-attributes, no
  elim-avail-extern / drop-unnecessary-assumes / alloc-token / cg-profile / rel-lookup-table-converter, loop-rotate
  with `prepare-for-lto`, IPSCCP without function specialization, and `canonicalize-aliases,name-anon-globals,
  assign-guid` at the end (after annotation-remarks).
- `lto<O#>` (`buildLTODefaultPipeline` with no export summary) has its own pass list; its inliner is a
  `ModuleInlinerWrapperPass` with `inline<only-mandatory>,inline` and no module passes or devirt wrapper.
  `opt -passes='lto<O2>' -print-pipeline-passes` is the ground truth; impl/jai's `-jai-print-pipeline` matches it
  for all four LTO aliases at O0-O3.
- **Hidden parameters**: printPipeline does not show IPSCCP's AllowFuncSpec, CGProfile's InLTOPostLink,
  JumpTableToSwitch's InLTO or LoopUnroll's OnlyWhenForced; they follow the phase.
- `lto<O2>` alone keeps every external symbol: a linker doing full LTO for an executable internalizes the symbols
  not visible outside the IR before running it (lib/LTO/LTO.cpp `runRegularLTO`). The corpus emulates that with
  `-passes='internalize,lto<O2>' -internalize-public-api-list=main`.

## MergeFunctions

- Only *equality* of the FunctionComparator decides merges; the order it defines between unequal functions only
  shapes the std::set, and its GlobalNumberState numbering depends on the comparison sequence. A list searched for an
  equal element gives the same merges.
- `StructuralHash(F)` (non-detailed) is `xxh3_64bits` over (4, 0x62642d6b6b2d6b72, isVarArg, arg count, then per
  block in DFS order 45798 and one `stable_hash_combine({opcode})` per instruction); functions are processed sorted
  by it, and only those sharing a hash with a neighbour start in the worklist.
- `cmpTypes` compares a pointer in address space 0 as the pointer-sized integer, so `ptr` and `i64` arguments are
  equal; the thunk then converts with `CreateAggregateCast` (ptrtoint / inttoptr / bitcast, element-wise for
  aggregates).
- The Deferred worklist holds WeakTrackingVHs: after `F->replaceAllUsesWith(NewF)` an entry for F refers to NewF.

## Pipeline parsing

- `verify` is both a module and a function pass name, so `-passes=verify,forceattrs,verify` is a *module* pipeline
  (a pipeline whose first element is a function pass is wrapped into one `function(...)` instead).
