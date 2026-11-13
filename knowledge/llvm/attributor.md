# Attributor (AttributorLight: `attributor-light`, `attributor-light-cgscc`)

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
