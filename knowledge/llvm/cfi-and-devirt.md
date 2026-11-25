# CFI and whole-program devirtualization (LowerTypeTests, CrossDSOCFI, GlobalSplit, SimplifyTypeTests, WholeProgramDevirt)

Verified against `/opt/llvm-project-23.1.5/llvm/lib/Transforms/IPO/LowerTypeTests.cpp` (line numbers below) and the
imported tests `tests/imported/llvm/Transforms/{LowerTypeTests,CrossDSOCFI,GlobalSplit,SimplifyTypeTests}/`.

## LowerTypeTests

- `-passes=lowertypetests` runs `LowerTypeTestsPass` with the command-line options (runForTesting): the summary
  action comes from `-lowertypetests-summary-action=none|import|export`, the summary from
  `-lowertypetests-read-summary=<yaml>`; in the import phase it reads the YAML file, in the export phase it also
  writes `-lowertypetests-write-summary` (YAML). The YAML is `ModuleSummaryIndexYAML.h` (`GlobalValueMap` keyed by
  GUID, `TypeIdMap` with `TTRes` / `WPDRes`, `CfiFunctionDefs` / `CfiFunctionDecls`).
- Disjoint sets: an `EquivalenceClasses` over type ids, global type members and branch funnels. Members are visited
  in insertion order per class (the class list starts at the leader; `unionSets` appends the second list). The sets
  are processed sorted by their largest `UniqueId` (first-use order of the type ids); inside a set the type ids are
  `llvm::sort`ed by UniqueId. Type ids no global references have UniqueId 0, so several may compare equal: std::sort
  is an insertion sort (stable) only up to 16 elements, above that the order is libstdc++-specific.
- Byte arrays are `llvm::stable_sort`ed by descending bit-set size before allocation (line 616). With
  `-lowertypetests-avoid-reuse` (default on) and no import summary, every *use* of a byte array goes through its
  own private alias `bits_use` (line 673), so the printed module has one `@bits_use.N` per type test.
- x86 jump tables: entry size 8 (`jmp f.cfi; int3 x3`), 16 when the module flag `cf-protection-branch` is set
  (`endbr64` first) (getJumpTableEntrySize, line 1282). The table is a naked, nounwind function `.cfi.jumptable`
  made of inline asm; defined members are renamed `<name>.cfi` (aliases too, line 1120) and the original name
  becomes an alias into the table. ARM/Thumb/AArch64/RISC-V/LoongArch/WASM have their own encodings.
- `llvm.type.test` users of non-instruction (constant) users are first turned into instructions
  (`convertUsersOfConstantsToInstructions`, lib/IR/ReplaceConstant.cpp).

## CrossDSOCFI, GlobalSplit, SimplifyTypeTests

- CrossDSOCFI emits `__cfi_check(i64, ptr, ptr)` with a switch over the numeric (i64 ConstantInt) type ids of
  `!type` metadata and `cfi.functions`, in SetVector (first-seen) order.
- GlobalSplit splits a global whose only uses are `inrange` constant GEPs (vtables) into one global per struct
  element, and moves `!type` metadata to the piece containing its offset (GlobalSplit.cpp).
- SimplifyTypeTests (runs after ThinLTO inlining) reverse-engineers LowerTypeTests' output: for each
  `__typeid_<T>_global_addr` it folds `sub (ptrtoint @f, ptrtoint @__typeid_..._global_addr)` to 0 and
  `icmp eq @f, @__typeid_..._global_addr` to true when `@f` (or `@f.cfi`) is a known member of T
  (LowerTypeTests.cpp:2607).
