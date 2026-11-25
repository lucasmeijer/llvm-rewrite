# Hardening passes: bounds-checking, alloc-token, lower-allow-check, kcfi, safe-stack, stack-protector

Verified against LLVM 23.1.5 with the 72 imported tests and corpus sweeps (see impl/jai NOTES "Hardening").

- All six are `RequiredPassInfoMixin` passes: they run on `optnone` functions too (a sweep found
  bounds-checking instrumenting an optnone function in RealtimeSanitizer/rtsan.ll).
- Module::createRNG(Name) seeds `std::mt19937_64` with `std::seed_seq{seed & 0xffffffff, seed >> 32, chars of
  Name + sys::path::filename(ModuleIdentifier)...}` (each char sign-extended to uint32); `-rng-seed` defaults to 0.
  lower-allow-check draws one `bernoulli_distribution(rate)` per check (libstdc++: `generate_canonical<double,53>
  (one 64-bit draw / 2^64) < p`) and removes the check when it is *false*; alloc-token's random mode takes
  `rng() % MaxTokens`.
- alloc-token's default mode is typehashpointersplit; MaxTokens 0 means the IntPtr type's bit mask. TypeHash uses
  `getStableSipHash(name) % MaxTokens` (SipHash-2-4, fixed key in lib/Support/SipHash.cpp); pointer-split halves
  the range and adds MaxTokens/2 when the `!alloc_token` metadata's second operand is true.
- bounds-checking marks every instruction its own builder inserts with `!nosanitize !{}` (not the ones the
  ObjectSizeOffsetEvaluator creates). The `ubsantrap` immediate is the guard kind, else the function's *block count
  after the trap block was added*, clamped to 255 (a negative guard sign-extends past 255).
- ObjectSizeOffsetEvaluator caches WeakTrackingVHs: when a size/offset phi folds to a constant, the cached results of
  values computed from it see the constant.
- On x86 the stack guard of glibc, musl, Android and Fuchsia is a load from `inttoptr (i32 0x28 to ptr
  addrspace(257))` (fs; 0x14/gs on i386, 0x10 on Fuchsia): StackProtector then inserts IR checks (`SP_return`,
  `CallStackCheckFailBlk` calling `__stack_chk_fail` with a call-site `noreturn`); for other OSes the guard is
  `llvm.stackguard` + `__stack_chk_guard` and only the prologue is inserted (SelectionDAG emits the checks).
- SafeStack's `CreateBitCast` / `CreateAddrSpaceCast` to the same type return the GEP itself, so the `.unsafe` and
  `.unsafe-byval` names only appear when the alloca's address space differs from the unsafe stack's.
- SafeStack's checkStackGuard weights are (2147481600, 2048) = getBranchProbStackProtector(true/false) numerators;
  StackProtector creates (failure, success) and then swaps successors (and the weights).
