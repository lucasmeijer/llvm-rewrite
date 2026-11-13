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
