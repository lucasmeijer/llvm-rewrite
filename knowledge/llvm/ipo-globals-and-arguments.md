# GlobalOpt, GlobalDCE, ConstantMerge, Internalize, DeadArgElim, ArgumentPromotion: behaviour that decides output

Verified with the Jai port (impl/jai/src/pass_global_opt.jai, evaluator.jai, pass_global_dce.jai,
pass_constant_merge.jai, pass_internalize.jai, pass_dead_arg_elim.jai, pass_arg_promotion.jai, ipo_utils.jai): the
sweeps `globalopt`, `globaldce`, `constmerge`, `strip-dead-prototypes`, `elim-avail-extern`, `internalize`,
`deadargelim`, `argpromotion` (and `deadargelim,function(instcombine),function(dce)`) are identical to opt 23.1.5 on
every round-tripping corpus file, also with each test's own flags; `globalopt --per-function` too.

## Uses that are not uses

- A `blockaddress(@f, %bb)` is not a user of `@f` in LLVM 23 (BlockAddress has no operands). Everything that walks a
  function's uses must skip it: GlobalStatus::analyzeGlobal (otherwise the function "escapes" and GlobalOpt does not
  add `local_unnamed_addr`: 30 corpus files, e.g. Transforms/JumpThreading/indirectbr.ll), Function::hasAddressTaken,
  DAE's surveyFunction / ArgumentPromotion's direct-caller check, `F->use_empty()`. After DAE splices the body into
  the new function, the blockaddress refers to the new function (BlockAddress::getFunction is the block's parent).
- Constants are users: a dead `getelementptr (@g, ...)` constant keeps `@g` "used" until removeDeadConstantUsers.
  GlobalOpt's Evaluator allocates a detached GlobalVariable per alloca it executes (AllocaTmps) and deletes them in
  its destructor; if they are not deleted, their initializers stay constant users and later isSafeToDestroyConstant
  checks fail (GlobalOpt/evaluate-call.ll lost its `local_unnamed_addr`).

- Deleting a block whose address is still used (~BasicBlock: a dead function with a `blockaddress` in some
  initializer) replaces the blockaddress by `inttoptr (i32 1 to ptr)` (GlobalOpt/deadfunction.ll; verified with the
  goose port).
- `Function::hasAddressTaken()` has IgnoreAssumeLikeCalls = true by default: a direct use by an assume-like
  intrinsic (`llvm.objectsize`, lifetime, assume, ...) or a bitcast/addrspacecast constant whose users are all
  assume-like intrinsics is not "address taken". GlobalOpt still gives such a function `fastcc`
  (GlobalOpt/fastcc.ll @assume_fastcc, @constexpr_self_user); DAE's deleteDeadVarargs uses the same query.
- `GlobalValue::isInterposable()` defaults to CheckNoIPA = true: a `noipa` function definition is interposable.
  The Evaluator refuses to call one (GlobalOpt/global-constructor-noipa.ll), static ifunc resolution refuses a
  `noipa` resolver (resolve-static-ifunc-noipa.ll); DAE's isDefinitionExact goes through mayBeDerefined, the same.

## GlobalOpt

- processGlobal runs on functions too: any function or global whose address is never compared gets
  `local_unnamed_addr` (or `unnamed_addr` when it has local linkage). Almost every module changes under `globalopt`.
- `Module::global_objects()` is functions then global variables (no ifuncs); `global_values()` is functions,
  globals, aliases, ifuncs (Module.cpp:451/459).
- The loops use `make_early_inc_range`: the successor is fixed before the body runs, so a global appended to the
  module while the *last* global is processed (`.body` of OptimizeGlobalAddressOfAllocation) is not visited in that
  round; one appended earlier is.
- OptimizeGlobalAliases always rebuilds `llvm.used` / `llvm.compiler.used` (setUsedInitializer): the old variable is
  removed and a new one is appended at the *end* of the global list, sorted by name, with section `llvm.metadata`.
- Deleting a global: a `metadata ptr @g` call operand becomes `metadata !{}` when the global is erased directly
  (ValueAsMetadata::handleDeletion -> canonicalizeMetadataForValue(nullptr)), but `metadata ptr poison` when the
  deletion goes through deleteIfDead, which calls ReplaceableMetadataImpl::SalvageDebugInfo first (MetadataAsValue
  and DINode owners get poison, MDTuples keep the operand until the deletion nulls it) (GlobalOpt/metadata.ll).
- RAUW of a global by an alloca (localization): the global's ConstantAsMetadata uses drop to null
  (ValueAsMetadata::handleRAUW, constant -> function-local).
- TTI hooks on X86 / without a target: canHaveNonUndefGlobalInitializerInAddressSpace is `AS == 0`,
  useColdCCForColdCall is false (coldcc only with -enable-coldcc-stress-test), useFastCCForInternalCall compares the
  EGPR feature of every caller (true without a target), isMultiversionedFunction is false (OptimizeNonTrivialIFuncs
  never resolves anything).
- removeGlobalCtors of the last ctor: `ConstantArray::get(ATy, {})` is a ConstantAggregateZero, so
  `@llvm.global_ctors` becomes `[0 x {...}] zeroinitializer` in a new global (GlobalOpt/ctor-list-preserve-addrspace.ll).
- ConstantMerge's `getAlign(GV)` is the explicit alignment when there is one, else DataLayout::getPreferredAlign
  (ConstantMerge/align.ll: align 1 and align 2 merge to align 2, not to the preferred 4).

- Localizing a global needs `GV->getType()->getAddressSpace() == DL.getAllocaAddrSpace()`: with `A5` in the
  data layout a global in address space 0 is not turned into an alloca (global_alloca_diff_addrspaces.ll).
- `opt -f` (force binary output) and the codegen option `-emulated-tls` change nothing in `-S` output; GlobalOpt
  tests pass them.

## DeadArgElim and ArgumentPromotion

- markFnOrRetTyFrozenOnMusttail tests `CC != SwiftTail || CC != Tail`, which is always true: any musttail call
  freezes the whole function (DeadArgumentElimination.cpp:640).
- When a signature changes, `SP->getType()` is replaced by a uniqued clone with `cc: DW_CC_nocall` (DW_CC_nocall = 3).
- New call sites are created fresh (CallInst::Create): only the tail-call kind, calling convention, attributes and
  `!prof` / `!dbg` are carried over; fast-math flags and other metadata are dropped. DAE inserts a replaced *invoke*
  at the end of the old invoke's block, a call before the old call.
- ArgumentPromotion's callee-side allocas: every promoted argument builds its own `IRBuilder(&NF->begin()->front())`,
  so the second argument's allocas are inserted before the first one's. Loads in callers get `.val` names from the
  passed value, including `.val` for an unnamed value.
- `-passes=argpromotion` is `cgscc(argpromotion)` with MaxElements = 2.
- ArgumentPromotion creates the new function with `Function::Create(..., F->getName())` and then inserts it next
  to F: the module symbol table uniques the name first (`foo.N`, bumping the module's unique-name counter), then
  `takeName` gives it `foo`. Later uniqued global names count from there. (DAE creates its new function unnamed.)
- ArgumentPromotion hands the callee-side allocas to PromoteMemToReg in `SmallDenseMap<int64_t, AllocaInst *>`
  order (offset -> alloca, 4 inline buckets, hash `offset * 37`, quadratic probing), not offset order.
- The `sret` -> `noalias` rewrite of an argument happens before the promotability checks, so it changes the IR even
  when nothing is promoted (and the pass then reports "all preserved").
