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

- `initializeLibCalls` is target logic, not a table: e.g. on `x86_64-apple-macosx10.9` exp10/exp10f are available
  as `__exp10`/`__exp10f` (setAvailableWithName: emitted calls and declarations use the custom name, getLibFunc
  still only knows the standard name), Windows MSVC < 19 renames `_copysign`/`_logb`/`_cabs`, x86-32 macOS >= 10.7
  uses `fwrite$UNIX2003`; memrchr is off on macOS and Windows; Itanium new/delete are off on MSVC-like triples and
  the msvc_* ones everywhere else. Ported as code in goose's tli.goose (verified with InferFunctionAttrs/annotate.ll,
  InstCombine/new-delete-msvc.ll, exp2-to-ldexp.ll, pow-to-ldexp.ll).
- getIntSize() is 16 on 16-bit architectures (AVR, MSP430: `Triple::isArch16Bit`), which changes every emitted
  `int` (putchar, strchr's character, snprintf's INT_MAX bound, powi's exponent) — pow-4.ll's CHECKI16 prefix.
- opt's `-disable-builtin`/`-enable-builtin` are cl::lists and accept `-disable-builtin strcat` (separate value) as
  well as `=`; with `-disable-simplify-libcalls` the lists are ignored (no "nonexistent builtin" error either).
- Triple::Triple(Str) splits at most 4 components (the environment is everything after the third `-`); parseOS and
  parseEnvironment are *prefix* matches in TripleName.def order, parseVendor whole names; the object format comes
  from the environment's suffix (`-elf`, `-macho`, `coff`...) or the default for the arch/OS. OS versions come from
  the OS component after its canonical name (`macosx10.9` -> 10.9; `darwin10` is macOS 10.6 for
  isMacOSXVersionLT). Normalize permutes components into place (`linux-x86_64` -> `x86_64-unknown-linux`), maps
  `win32`/`mingw32`/`cygwin` to `windows-msvc`/`windows-gnu`/`windows-cygnus` (verified against
  `opt -mtriple=X -S` on an empty module).

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

- emitFWrite's call is unnamed (`B.CreateCall(F, Args)` without a name) while emitFPutC/FPutS/PutChar/... name it
  after the function; emitFPutC/FPutS/FWrite infer attributes only when the FILE argument is a pointer.
- isFortifiedCallFoldable with a `-1` object size is foldable even when nothing else is known; `__strcpy_chk` with
  a known string length and a too-small object size becomes `__memcpy_chk` (an unnamed call with a `nounwind`
  declaration, emitMemCpyChk), not a plain memcpy (strcpy_chk-1.ll).
- nan("...") parses the payload with StringRef::getAsInteger(0, APInt): radix auto-sensed (`0x`, `0b`, `0o`, a
  leading `0` = octal), the whole string must be consumed, and the payload is truncated to the significand
  (makeNaN), with the quiet bit (and on x86_fp80 the integer bit) set (nan.ll, nanl-fp80.ll, nanl-fp128.ll).
- optimizeRemquo folds only when divide's status is opOK/opInexact (so not for underflowing or overflowing
  quotients) and remainder's is opOK; the quotient's int is convertToInteger(rmNearestTiesToEven) of the rounded
  FP quotient, stored with the call's param align or the ABI alignment (remquo.ll, remquol-fp80.ll).

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
- `isMathLibCallNoop` (ConstantFolding.cpp:4749), which lets wouldInstructionBeTriviallyDead delete a constant-folded
  libcall that may write errno, lists `LibFunc_ilogb` only: `ilogbf`/`ilogbl` calls with a constant stay after
  their result is folded (InstCombine/ilogb.ll and InstSimplify/pr122582.ll at -O2: early-cse keeps
  `call i32 @ilogbf(float 7.0)`; the other families list all three of f/l/plain). Verified with impl/jai.
- LibCallSimplifier's remquo fold stores the quotient with `CreateAlignedStore(.., CI->getParamAlign(2))`; without a
  param align that MaybeAlign is empty and IRBuilder uses the ABI alignment (`align 4`), which later passes
  (infer-alignment) keep. InstCombine/remquo*.ll at -O2.
