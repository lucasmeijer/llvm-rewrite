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

## WholeProgramDevirt

Verified against `/opt/llvm-project-23.1.5/llvm/lib/Transforms/IPO/WholeProgramDevirt.cpp`, `tools/opt/optdriver.cpp`
and `tests/imported/llvm/Transforms/WholeProgramDevirt/` (all 33 `::opt` identical; sweeps below).

- `-whole-program-visibility` is not read by the pass: opt itself (optdriver.cpp:628) runs `AssignGUIDPass` (every
  definition gets `!guid !{i64 MD5("file;name" or "name")}`, globals first, then functions) and
  `updateVCallVisibilityInModule`, which gives every global with `!type` and public vcall visibility a
  `!vcall_visibility !{i64 1}`. This happens after the source file name is known (private/internal GUIDs hash
  `source_filename;name`), before any pass, whatever the pipeline. The pass erases `!vcall_visibility` from all
  global variables when it does not take its early exit, so without type tests the attachment stays in the output.
- Without whole program visibility (and without `-devirtualize-speculatively`) every vtable is public and
  `tryFindVirtualCallTargets` gives up: only the type test scanning (and the removal of assumes of type ids no global
  has) changes the IR.
- Order: `CallSlots` is a MapVector in the order the slots are first seen (type.test users in use-list order, then
  type.checked.load, then .relative); per slot the constant-argument groups are a `std::map` (lexicographic on the
  argument vector). VCP allocates per slot in that order, so the before/after byte layout of the rebuilt vtables
  follows it. The two pointer-keyed `std::map`s (`NumUnsafeUsesForTypeTest`, and `CallBases` in
  applyICallBranchFunnel) are only used for RAUW + erase, which is not order-sensitive in the printed IR.
- `scanTypeCheckedLoadUsers` always declares `llvm.type.test` (getOrInsertDeclaration) even if nothing uses it.
- VCP's loads: `getelementptr i8, ptr %vtable, i32 <byte>` (CreatePtrAdd: no inbounds), `load i8 ... align 1` for i1
  (then `and` with the bit and `icmp ne 0`), otherwise a load with the ABI alignment of the return type. The vtable
  becomes `@N = private constant { [B x i8], <init>, [A x i8] }` inserted before it, with `!type` offsets shifted by
  B, and the old name becomes an alias to element 1.
- The Evaluator runs with no TargetLibraryInfo: a call to a library function declaration is not constant folded.
- Branch funnels: only on x86_64, at most `-wholeprogramdevirt-branch-funnel-threshold` (10) targets, and only call
  sites in functions whose `target-features` contain `+retpoline` are rewritten (the funnel is created anyway). The
  funnel gets `!prof !{!"function_entry_count", N}` from the callers' BFI-scaled entry counts when a call was
  rewritten, else `!{!"unknown", !"wholeprogramdevirt"}`.
