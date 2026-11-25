# Sanitizer and coverage instrumentation passes (LLVM 23.1.5)

Facts that bite every port of lib/Transforms/Instrumentation. Verified by matching the oracle on the imported tests
and on whole-corpus sweeps (`./harness/run sweep --passes 'forceattrs,X' --extra='-force-attribute=sanitize_...'`).

- **Every sanitizer pass is required** (`isRequired() = true`): it runs on `optnone` functions. JMCInstrumenterPass is
  not required.
- **The oracle is a release build, and some instrumentation code relies on behaviour that only exists there:**
  - `ConstantInt::get(i32, uint64_t V)` with a `V` that does not fit (`~(0x3F << 57)` in HWASan's untagPointer for
    32-bit pointers) has no implicit truncation: the APInt keeps the high bits, the constant prints as `-1` but is not
    the uniqued all-ones value, so `and %p, -1` is neither folded by the IRBuilder nor by ConstantFoldBinaryInstruction
    (identity check by pointer). For widths above 64 the value is zero-extended (`i128 9367487224930631679`).
    Verified: HWAddressSanitizer with `-force-attribute=sanitize_hwaddress` on the 32-bit-pointer InstCombine tests.
  - `Align(n)` for an `n` that is not a power of two (SanitizerCoverage's `Align(StoreSize(ptr))` with 40-bit
    pointers) becomes `1 << Log2(n)` (align 4 for 5 bytes).
  - `TypeSize::getFixedValue()` on a scalable size returns the known minimum (NumericalStabilitySanitizer's non-FT
    store of a scalable vector).
- **`MemIntrinsic::getDest()` / `getSource()` strip pointer casts** (an `addrspacecast` to address space 0 is looked
  through, so an access to addrspace(1) memory is ignored by HWASan / TySan).
- **`GlobalVariable::copyAttributesFrom` does not copy the comdat**; ASan copies it explicitly, HWASan's
  instrumented globals end up without one.
- **`isa<IntrinsicInst>` is any call whose callee's name starts with `llvm.`**, including names that are not real
  intrinsics (`llvm.convergent` in a test): SanitizerCoverage's leaf-function check counts those calls as intrinsics.
- **`Instruction::setFastMathFlags` ORs** the flags in (`copyFastMathFlags` overwrites); NSan's moveFastMathFlags
  relies on it.
- **CreateLoad/CreateStore without an alignment use the ABI alignment** of the type, which for `i1` can be 4 under a
  custom datalayout (SanitizerCoverage's bool flags).
- **SanitizerCoverage `-sanitizer-coverage-inline-bool-flag` with `-sanitizer-coverage-stack-depth`** keeps inserting
  through an IRBuilder whose block was split off; LLVM's opt crashes on most functions (the sweep reports them as
  llvm-failed).
- **MSan without a Linux/FreeBSD/NetBSD triple aborts** ("unsupported operating system"), so whole-corpus msan sweeps
  need `-mtriple=x86_64-unknown-linux-gnu`.
- **DFSan without a Linux triple aborts** ("unsupported operating system"), like MSan: sweep with
  `-mtriple=x86_64-unknown-linux-gnu`.
- **LLVM 23's `BlockAddress` has a single operand, the block** (the function is the block's parent), so it is not a
  use of the function: DFSan's `F.replaceUsesWithIf(Wrapper, ...)` leaves `blockaddress(@F, %bb)` alone. An IR model
  that keeps the function as an operand must skip blockaddress users there. Verified: dfsan with an ABI list marking
  every function uninstrumented on tests/e2e/*/misc/computed_goto.ll.
- **A struct with scalable-vector members of different types is unsized** (`StructType::isSized`: only homogeneous
  scalable-vector structs are sized), so DFSan gives it the primitive shadow `i8`; an `extractvalue` of that shadow
  then goes through `ConstantInt::getAggregateElement`'s unchecked `cast<VectorType>` (UB in a release build).
- **`CallBase::setCalledFunction(Function *)` replaces the call's function type, not its result type**: a call
  `call float @f(...)` of `i32 @f(...)` prints as `call i32 @f` afterwards and still verifies (DFSan's wrapper
  kinds warning / discard / functional do this).
- **SpecialCaseList (v2 default) = globs with `{a,b}` brace expansion (at most 1024 sub-patterns), `[..]` classes with
  `!`/`^`, `\` escapes; the last matching line of the newest matching section wins** (`inSection` walks sections in
  reverse; each section name is itself a glob, "*" for the implicit first one). `#!special-case-list-v1` switches
  patterns to regexes (`*` becomes `.*`). Verified: dfsan sweeps with hand-written ABI lists (jai NOTES.md).

## GCOVProfiling (insert-gcov-profiling)

Verified by byte-comparing the .gcno files with LLVM's (`@opt-files` tests, `sweep --files`; jai pass_gcov.jai).

- **opt writes `<CU file stem>.gcno` into the cwd** and embeds `<cwd>/<stem>.gcda` in the IR (mangleName; the cwd is
  `sys::fs::current_path`: `$PWD` when it names the same directory as `.`, else getcwd). An `!llvm.gcov` node
  `!{!"path", CU}` gives both names (extension replaced); `!{!"x.gcno", !"y.gcda", CU}` gives them verbatim. A notes
  file that cannot be opened is an `LLVMContext::emitError` (opt exits 1 after the pipeline).
- The notes header is `oncg` + the version reversed (little endian) or `gcno` + version (big endian, from the
  DataLayout), then the CRC stamp (JamCRC of the arc destination block numbers, byte-split), `"."` as the cwd
  string, 0. Versions below 111 (the default `0000`) become `B11*`; the gcda version argument is `read32be("B11*")`.
- FuncChecksum = `(uint32_t)hash_value(linkageName-or-name + line)`: xxh3_64bits of the bytes XOR the release
  execution seed `0xff51afd7ed558ccd`.
- Function EndLine is the line of the *first* instruction with a non-zero line (functionHasLines returns early),
  not the maximum.
- The function records accumulate across compile units (`Funcs` is never cleared) and FunctionIdent restarts per CU;
  `emitGlobalConstructor` runs inside the CU loop right after the first non-DWO CU, so a second CU reads
  `FileChecksums[1]` out of bounds (UB).
