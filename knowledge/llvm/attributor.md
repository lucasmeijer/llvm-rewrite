# Attributor (`attributor`, `attributor-cgscc`, `attributor-light`, `attributor-light-cgscc`)

Facts that decide the output of the light Attributor. Verified with impl/jai's port (src/attributor.jai,
src/attributor_aas.jai): all 11 attributor-light RUN lines of Transforms/FunctionAttrs and sweeps of both passes over
the corpus (0 differs), unless another source is named.

## Configuration and what it switches off

- `runAttributorLightOnFunctions` (Attributor.cpp) allows 17 AA kinds (`AC.Allowed`): WillReturn, NoUnwind,
  NoRecurse, NoSync, NoFree, NoReturn, MemoryLocation, MemoryBehavior, UnderlyingObjects, NoCapture,
  InterFnReachability, IntraFnReachability, CallEdges, NoFPClass, MustProgress, NonNull, DenormalFPMath.
  `getOrCreateAAFor` returns null for every other kind (`shouldInitialize` checks `Allowed`), and
  `checkAndQueryIRAttr` skips not-allowed kinds before even asking `isImpliedByIR` (so NoUndef / NoAlias are never
  manifested from the seeding, but `hasAssumedIRAttr<NoAlias>` still evaluates `AANoAlias::isImpliedByIR`, which
  can add `noalias` through `hasAttr`'s implied manifest).
- `UseLiveness = false`: every `isAssumedDead` query is false.
- No AAPotentialValues: `getAssumedSimplifiedValues` yields the associated value itself, except for a *returned*
  position, where it fails. Hence `checkForAllReturnedValues` always fails: AANonNullReturned and AANoFPClassReturned
  go pessimistic on their first update; `nonnull` on a return comes only from `AANonNull::isImpliedByIR` at seeding
  (isKnownNonZero on every `ret` operand), and AANoCapture's "CheckReturnedArgs" never succeeds.
- `getPotentialCopiesOfStoredValue` (used by `checkForAllUses` on a use as the stored value of a store) succeeds only
  if every underlying object of the store's pointer is undef/poison or a literal null where null is undefined: it
  still creates an AAUnderlyingObjects for the pointer.
- The module pass uses `AnalysisGetter(FAM, /*CachedOnly=*/true)`: with `opt -passes=attributor-light` nothing is
  cached, so DT, PDT, LI, SE, AC and TLI are all null (MustBeExecutedContextExplorer works without them,
  `mayContainUnboundedCycle` falls back to "any CFG SCC with a cycle", isKnownNonZero / computeKnownFPClass run
  without DT/AC/TLI). The CGSCC pass computes them (`AnalysisGetter(FAM)`).

## Behaviour that shows in the output

- `Attributor::hasAttr(IRP, Kinds, ..., ImpliedAttributeKind)` *manifests* the implied attribute at IRP when it was
  found at a subsuming position (or as a different kind, or in an `llvm.assume` bundle). So querying `nounwind` for
  a call site whose callee is `nounwind` adds `nounwind` to the call site, and `hasAssumedIRAttr<NoAlias>` on a call's
  returned value whose callee returns `noalias` adds `noalias` to the call. Manifests go into the `AttrsMap` and are
  written to the IR at the end of `manifestAttributes`, even when the pass reports "unchanged".
- All other IR reads (`F.onlyReadsMemory()`, `Arg->hasByValAttr()`, `CB.hasFnAttr`) see the IR as it was before the
  pass: the AttrsMap is separate until the end.
- `addIfNotExistent`: enum attributes are added only if absent; integer attributes (`captures`, `nofpclass`) only if
  absent or the old integer value is smaller (`isEqualOrWorse` compares the raw values, so an existing
  `captures(address)` is never replaced by `captures(none)`); `memory(...)` is intersected with the existing one.
- `FPClassTest` is a bitmask enum: `~KnownFPClasses` is masked to `fcAllFlags` (AANoFPClassImpl::initialize). Without
  the mask an argument with nothing known gets an empty `nofpclass()`.
- Call sites get attributes too (`nofree nosync willreturn` on calls to intrinsics, `memory(...)` from
  AAMemoryBehaviorCallSite): every allowed AA created for a call-site position manifests there.
- A `blockaddress(@f, %bb)` is not a use of `@f` (no operands in LLVM 23): `checkForAllCallSites` on `@f` sees no
  use for it (GlobalOpt/deadfunction.ll: `@test` only referenced by blockaddresses is `norecurse mustprogress`).

## Order

- Seeding (`identifyDefaultAbstractAttributes`) runs per defined function in module order; within a function:
  function-position AAs, return, arguments, then call sites (all invokes, then callbrs, then calls: the
  OpcodeInstMap is walked opcode by opcode), each AA initialized and updated once on creation.
- `InformationCache::getFunctionInfo` is lazy: a function's `llvm.assume` knowledge and the "alwaysinline and
  inline-viable" set (IPO amendability of non-exact definitions) exist only once something asked for its info.
- Dependences are `SmallSetVector<PointerIntPair<AA *, 1>>` (DepClassTy REQUIRED = 0, OPTIONAL = 1, NONE = 2); the
  worklist is a SetVector in insertion order; query AAs (the two reachability AAs) are re-run through
  `QueryAAsAwaitingUpdate` when a temporary query answered "not reachable".

## The full Attributor (`attributor`, `attributor-cgscc`)

Verified with impl/jai's port (src/attributor*.jai): 290 of the 301 `@opt` lines of Transforms/Attributor and sweeps of
both passes over the corpus (0 differs, also `--with-test-flags` and tests/perf/compile), unless another source is
named.

- Call sites are `AbstractCallSite`s. A use of `@cb` as argument `k` of a call to a broker declared with
  `!callback !{!{i64 k, i64 a0, i64 a1, ..., i1 vararg}}` is a *callback call* of `@cb` whose argument `j` is the
  broker's operand `a_j` (`-1`: none, the position is invalid). `IRPosition::getAssociatedArgument` of a call-site
  argument prefers the unique callback-callee argument that operand is passed to over the broker's own parameter,
  so the broker's call-site-argument AAs reason about the callback callee (thread_local_acs.ll: the broker's
  operands become `undef` after the callee's arguments are replaced by the globals).
- `checkForAllCallSites`: with `RequireAllCallSites = false` a use that is not a callee is skipped, with `true` it
  fails; a use through a single-use cast constant expression always fails (the "effective use" is the use in the
  constant expression, not the call's callee operand). Uses in pointer-typed cast expressions are expanded first.
- Callback calls block: signature rewrites (`CallSiteCanBeChanged`), `AAIsDead` for returned values, and
  `AANoAliasArgument` when the function is neither nosync nor the argument read-only.
- AAIndirectCallInfo manifest: no callee → the call becomes unreachable; one known callee that `isLegalToPromote`
  → `promoteCall` in place (operand bit/pointer casts, a return cast after the call, incompatible attributes
  dropped); otherwise per callee `%c = icmp eq ptr %fp, @f` + `SplitBlockAndInsertIfThen`, the clone of the call in
  the then-block (promoted) or a fresh `call` without attributes named like the original, the merge PHI
  `%<name>.phi` at the start of the original block; if all callees are known the last compare becomes `true` and the
  fallback block ends in `unreachable`, else a clone of the indirect call (with `!callees` of the skipped callees)
  stays as the fallback. `-attributor-max-specializations-per-call-base` limits it per call (0: none, only `!callees`).
- `-attributor-assume-closed-world`: the indirectly callable functions are those with
  `hasAddressTaken(IgnoreCallbackUses=false, IgnoreAssumeLikeCalls, IgnoreLLVMUsed, IgnoreCastedDirectCall)`.
- `-attributor-allow-shallow-wrappers`: every function that is not IPO-amendable (non-exact definitions) gets a
  wrapper with its name, linkage, comdat, metadata and attributes, whose body is `tail call @<anon>(args) #noinline`;
  the original becomes internal and unnamed (`@0`).
- `-attributor-allow-deep-wrappers`: a non-exact, non-interposable definition with uses is cloned into
  `private dso_local @<name>.internalized` (inserted before it); call uses outside the function itself move to the
  clone, then `CallGraphUpdater::replaceFunctionWith` deletes the original's body and erases it at the end (remaining
  non-call uses become poison), even in the module pass (internalize.ll).
- `rewriteFunctionSignatures` walks `ArgumentReplacementMap`, a `DenseMap<Function *, ...>` (pointer-hash order).
  It only shows when two privatizing rewrites name new values in the same caller (`%x.b8` vs `%x.b81`): not
  reproducible (ArgumentPromotion/byval.ll, IPConstantProp/2009-09-24-byval-ptr.ll).
- `nofpclass` is valid on FP and FP-vector types, arrays of them (any depth) and *literal* structs of one repeated
  FP type (`FPMathOperator::isSupportedFloatingPointType`); a named struct `%struct.S = type { double }` is not
  (DeadArgElim/musttail-verifier.ll).
- `ppc_fp128` constants: `DoubleAPFloat::isDenormal` is "either half denormal or (double)(hi + lo) != hi", so
  `0xM3FF00000000000000000000000000000` (1.0) is normal and gets `nofpclass(... sub nnorm)`
  (InstSimplify/canonicalize.ll, ConstProp/convert-from-fp16.ll).
- A call whose callee is declared with another return type (`declare i1 @f(i1)` called as `call i32 @f(i32 ...)`)
  gives AAValueConstantRange call-site states of two widths; the callee's range is the full set (a declaration), so
  the call-site-returned position goes pessimistic (MemorySSA/call-bitcast.ll).
