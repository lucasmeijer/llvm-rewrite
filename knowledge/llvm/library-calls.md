# Library calls: TargetLibraryInfo, BuildLibCalls, LibCallSimplifier

Facts verified against LLVM 23.1.5 (sources named; behaviour checked with `opt -passes=instcombine` / `inferattrs`
on the imported tests named).

## TargetLibraryInfo

- The LibFunc enum, names and prototypes come from `include/llvm/Analysis/TargetLibraryInfo.td` (TableGen,
  `utils/TableGen/Basic/TargetLibraryInfoEmitter.cpp`): `NotLibFunc = 0`, then the defs **in input order**. A
  return type of `?` ("checked manually": cabs*, sincospi*_stret, __size_returning_new*) gives an empty signature;
  isValidProtoForLibFunc handles those by hand. `LDbl` matches any FP type, `Long`/`IntPlus` any int >= int size,
  `SizeT` the index width of address space 0 (`getSizeTSize`).
- `getLibFunc(const Function&)` rejects intrinsics and checks the prototype; `getLibFunc(const CallBase&)` also
  needs `!isNoBuiltin()` and `getCalledFunction()` (callee type == call type). `TLI.has(F)` combines the triple's
  baseline with the caller's `"no-builtins"` (everything off) or `"no-builtin-<name>"` attributes.
- opt builds the baseline from the module triple; `-disable-simplify-libcalls` disables every function,
  `-disable-builtin=<f>` / `-enable-builtin=<f>` (lists) adjust single ones and fail with "cannot disable
  nonexistent builtin function" for unknown names (`tools/opt/optdriver.cpp`).
- Triple-dependent availability that shows up in tests: bcmp only on Linux GNU/musl, FreeBSD, Solaris;
  memset_pattern4/8/16 only on Darwin (macOS >= 10.5, iOS >= 3); exp10/exp10f are `__exp10`/`__exp10f` on macOS
  >= 10.9 and unavailable on Linux; `*_finite` and `__strdup` etc. only on Linux GNU; sinpi/cospi/sincospi_stret
  only on Darwin (non-x86-32); iprintf/siprintf/fiprintf only on XCore/TCE/Emscripten.
- `-mtriple` goes through `Triple::normalize`: `x86_64-linux-gnu` -> `x86_64-unknown-linux-gnu`,
  `x86_64-linux` -> `x86_64-unknown-linux`, but `x86_64` and `x86_64-pc_linux` stay as they are (the ANY form
  only permutes and fills empty components; it does not pad).

## BuildLibCalls

- `emitLibCall` and most emit* helpers call `inferNonMandatoryLibFuncAttrs` on the declaration after
  `getOrInsertLibFunc`, **also on a pre-existing declaration**, so `strlen`/`putchar`/`memcmp` declarations in the
  output gain attributes. `emitUnaryFloatFnCall` does not; `emitBinaryFloatFnCall` does.
- Emitted float calls copy the given attribute list minus `speculatable` (sin/cos -> tan in visitFDiv passes the
  sin/cos intrinsic's function attributes, so `tan` calls get `nocallback nofree ... memory(none)`).
- `getOrInsertLibFunc` adds `signext`/`zeroext` only on targets that need it (PPC64, SystemZ, Sparc64, MIPS,
  RISCV64, LoongArch), none on x86-64.

## LibCallSimplifier (SimplifyLibCalls.cpp)

- Runs from InstCombine's `tryOptimizeCall` (not for musttail/notail calls). Before the libcall table it handles
  pow/exp2/log*/sqrt/memset/memcpy/memmove/sin/cos **intrinsics** (C calling convention only) and the fortified
  `*_chk` functions (which ignore nobuiltin and `TLI.has`).
- Builder details: `CreateBinaryIntrinsic`/`CreateUnaryIntrinsic` insert the intrinsic declaration *before*
  constant folding, so `strnlen("abc", 3)` folds to `ret i64 3` but leaves `declare i64 @llvm.umin.i64`
  (strnlen-1.ll); `CreateIntrinsic(ID, Types, Args)` folds without declaring. `CreatePtrDiff` is
  `sub (ptrtoaddr L), (ptrtoaddr R)` (sprintf-1.ll). The builder's default operand bundles are the simplified
  call's, so `fprintf(...) [ "deopt"() ]` becomes `fwrite(...) [ "deopt"() ]` (fprintf-1.ll, printf-3.ll).
- `CreateGlobalString` makes `@str = private unnamed_addr constant [N x i8] c"...", align 1`; a string of zero
  bytes becomes `zeroinitializer` (ConstantDataArray::get returns a ConstantAggregateZero).
- `getConstantDataArrayInfo` reads non-CDA initializers through ReadByteArrayFromGlobal; when all the bytes are
  zero the result is again a ConstantAggregateZero, i.e. `Slice.Array == nullptr` (a zero-initialized string).
- `annotateNonNullNoUndefBasedOnAccess` adds `noundef nonnull dereferenceable(1)` to string arguments even when no
  fold applies, which is why nearly every `printf`/`puts`/`strlen` call in clang output changes under InstCombine.
  `getParamDereferenceableBytes` reads call-site attributes only; `paramHasAttr(NonNull)` also the callee's.
- New functions (getOrInsertFunction, intrinsic declarations) are created in the DataLayout's program address
  space: with `P200`, `call addrspace(200) void @llvm.memcpy...` (strcpy-nonzero-as.ll).
- `shouldOptimizeForSize` is only `optsize`/`minsize` under `-passes=instcombine`: InstCombine's PSI is a cached
  module result that exists only after `require<profile-summary>`.

## InferFunctionAttrs

- `inferattrs` visits every declaration without `optnone`; `inferNonMandatoryLibFuncAttrs` unless the function is
  `nobuiltin`, then always `inferAttributesFromOthers` (readnone+!convergent -> nosync, readonly -> nofree,
  willreturn -> mustprogress). Any change returns PreservedAnalyses::none() (annotate.ll, BasicAA/libfuncs.ll).

## Facts found porting LibCallSimplifier/BuildLibCalls for goose (verified with opt 23.1.5)

- **Plain `free` is not a free function to TLI-based code**: LLVM 23's FreeFnData lists only operator delete
  variants, so isLibFreeFunction falls back to the callee's `allockind("free")`. `call void @free(ptr null)`
  survives `instcombine` unless the declaration has `allockind("free")` (then visitFree erases it); without it the
  call goes through visitCallBase and gets `nonnull` arguments.
- getConstantDataArrayInfo needs GlobalVariable::hasDefinitiveInitializer: `weak_odr`/`linkonce_odr` constants
  *are* definitive (only weak/linkonce/common/extern_weak and the SemanticInterposition module flag on non-dso_local
  globals are interposable) — `strcmp(@weak_odr_str, "y")` folds (InstCombine/weak-symbols.ll).
- inferNonMandatoryLibFuncAttrs ends with `setDoesNotFreeMemory` unless isLibFreeFunction or the declaration's
  allockind has Realloc; `inferattrs` then adds nosync (readnone & !convergent), nofree (readonly), mustprogress
  (willreturn) to every declaration (inferAttributesFromOthers), also non-libfuncs.
- canTransformToMemCmp: strcmp builds a full SimplifyQuery (DT, AC, CxtI) for isDereferenceablePointer, strncmp only
  `SimplifyQuery(DL)` (no context, no assumptions); strncmp/memchr's isKnownNonZero(Size, DL) has no context either.
