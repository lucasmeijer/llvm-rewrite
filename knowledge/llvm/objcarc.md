# ObjC ARC passes (objc-arc, objc-arc-contract, objc-arc-expand, pa-eval, objc-arc-aa)

Verified against LLVM 23.1.5 (`lib/Transforms/ObjCARC/*`, `lib/Analysis/ObjCARC*.cpp`) and the 52 imported
`Transforms/ObjCARC` tests (all pass in impl/jai).

- There is no `objc-arc-apelim` pass in LLVM 23 (PassRegistry.def has `objc-arc`, `objc-arc-contract`,
  `objc-arc-expand`, `pa-eval` and the alias analysis `objc-arc-aa`). `apelim.ll` runs `objc-arc`.
- `objc-arc` runs on every function (no ModuleHasARC check); `objc-arc-contract` and `objc-arc-expand` return early
  unless the module declares one of 17 non-overloaded `llvm.objc.*` intrinsics (ModuleHasARC).
- ARCInstKind is decided by the *intrinsic ID* of the callee (`llvm.objc.retain`, ...), not by `objc_retain`
  names; `getCalledFunction()` must match the call's function type.
- `GetRCIdentityRoot` / `IsNoopInstruction` chains use `Value::stripPointerCasts`, which also looks through a call
  with a `returned` argument (contract-marker.ll: `@returnsArg(ptr returned)` makes the retainRV's argument the
  RC identity of the preceding call, so the inline-asm marker is inserted).
- ProvenanceAnalysis::related inserts `(A, B) -> true` into its cache before computing, so a cycle through phis
  answers "related"; the cache lives for the whole function (all OptimizeSequences iterations).
- objc-arc-aa: `alias` and `getModRefInfoMask` always fall back to AAResultBase (MayAlias / ModRef), so the only
  effects are `getModRefInfo(Call, Loc) = NoModRef` for retain/retainRV/autorelease(RV)/noop casts/pool push/fused
  retain-autorelease calls, and `getMemoryEffects(F) = none` for the noop-cast functions.
- Inserted RV calls for `clang.arc.attachedcall` bundles: objc-arc removes them again at the end (the bundle stays);
  objc-arc-contract also marks the annotated call `notail` and, with `-arc-contract-use-objc-claim-rv=1` (default:
  only AArch64 iOS/tvOS >= 16, watchOS >= 9, bridgeOS >= 7, macOS >= 13, Darwin >= 21), rewrites the bundle operand
  retainRV -> `llvm.objc.claimAutoreleasedReturnValue`.
- Removing the attached-call bundle (`BundledRetainClaimRVs::eraseInst`) recreates the call with
  `CallBase::Create(CB, Bundles)`, which copies the name: the new call is inserted while the old one still exists,
  so it gets a uniquified name (checked by hand: `%call` with the bundle becomes `%call1` after objc-arc pairs it
  with an autoreleaseRV).
