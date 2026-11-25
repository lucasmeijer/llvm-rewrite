# OpenMPOpt (`openmp-opt`, `openmp-opt-postlink`, `openmp-opt-cgscc`)

Facts that decide the output of llvm/lib/Transforms/IPO/OpenMPOpt.cpp. Verified with impl/jai's port
(src/pass_openmp_opt.jai, openmp_aas.jai, openmp_kernel_info.jai): Transforms/OpenMP (20 of 21 `@opt` files; the
other needs `-openmp-opt-enable-merging`), the OpenMP files of Transforms/Attributor, tests/pass/openmp-opt (LLVM's
GPU tests without the triple) and `default<O2>` over the corpus, unless another source is named.

## When it runs and what it always does

- Both passes return immediately unless the module has an `"openmp"` module flag (`containsOpenMP`); device code is
  recognized by an `"openmp-device"` flag (`isOpenMPDevice`), not by the triple. A device module without a GPU triple
  runs every device transformation (kernels are functions with the `"kernel"` attribute; `getDeviceKernels`
  additionally needs a kernel calling convention: amdgpu_kernel, ptx_kernel, spir_kernel).
- `openmp-opt-postlink` is OpenMPOptPass(FullLTOPostLink). "PostLink" (OpenMPPostLink: removing an unused
  `@__llvm_rpc_client`, and `runtimeFnsAvailable` requiring *definitions* of the runtime functions a transformation
  would call) is true for FullLTOPostLink, ThinLTOPostLink and ThinLTOPreLink; the pipelines pass their phase.
- Every OMPInformationCache construction (once per module pass, once per SCC in the CGSCC pass) looks up every
  OMPKinds.def runtime function by name; a declaration whose signature matches exactly (`declMatchesRTFTypes`) gets
  the OMPKinds.def attributes added (`OpenMPIRBuilder::addAttributes`, from `collectUses`). With the default
  `-openmp-ir-builder-optimistic-attributes=false` that is mostly `nounwind` (barriers: `convergent nounwind`,
  `__kmpc_alloc_shared`: `nounwind nosync allocsize(0) allockind("alloc,uninitialized") "alloc-family"=...` and a
  `noalias` return). Integer-extension sets (SExt / ZExt / SizeTyExt) add what
  `TargetLibraryInfo::getExtAttrForI32Param/Return` asks for: nothing on x86-64 or without a triple. So a host module
  with OpenMP changes (declaration attributes) even when nothing is optimized.
- In device modules `noinline` is removed from every function named `__kmpc*`, `_ZN4ompx*` or `omp_*` without
  `optnone`.
- The device module pass first internalizes every defined, non-kernel function with uses that
  `Attributor::isInternalizable` accepts: a copy `@<name>.internalized` (private, dso_local, default visibility)
  right before the original, and only *call* uses outside the internalized copies are redirected. The originals
  stay and are not part of the SCC. `internalizeFunctions` reports a change even for an empty set, so the device
  module pass always returns PreservedAnalyses::none().

## The Attributor inside

- AttributorConfig: no `identifyDefaultAbstractAttributes`; OpenMPOpt seeds its own AAs (registerAAs) and
  `registerAAsForFunction` runs for live internal functions (DefaultInitializeLiveInternals = false,
  InitializationCallback). RewriteSignatures = false, DeleteFns = true: `identifyDeadInternalFunctions` deletes dead
  internal functions even in a host CGSCC run that created no AA. MaxFixpointIterations: 32 on the host,
  `-openmp-opt-max-iterations` (256) on the device. The module pass makes `"kernel"` functions IPO-amendable.
- Host CGSCC: only AAICVTracker under `-openmp-deduce-icv-values`. Device: AAKernelInfo per `__kmpc_target_init`
  user and AAFoldRuntimeCall per `__kmpc_is_spmd_exec_mode` / `__kmpc_parallel_level` /
  `__kmpc_get_hardware_num_threads_in_block` / `__kmpc_get_hardware_num_blocks` call (module pass, created without
  an update), then per function AAExecutionDomain, AANonConvergent (convergent functions), AAAddressSpace of
  load/store pointers, AAIsDead of stores and fences, AAIndirectCallInfo, AAPotentialValues of assume conditions,
  AAHeapToShared and AAHeapToStack. Internal functions whose uses are all direct calls from the run set are only
  seeded when found live.
- Several regular AAs look AAExecutionDomain up (only OpenMPOpt creates it): AAIsDeadFloating removes fences the
  domain calls no-ops; AAPointerInfo ignores threading for accesses in aligned regions or executed by the initial
  thread only, and, for an alloca in a kernel, skips accesses in other kernels.
- AAHeapToStack treats a `__kmpc_alloc_shared` call as a globalized local through `CB.getFnAttr("alloc-family")`,
  which also reads the callee's attributes: the attribute OpenMPOpt adds to the declaration is what makes H2S skip
  the loop / free-pairing checks for those allocations.
- `updateReachingKernelEntries` passes `AllReachingKernelsKnown = true` as checkForAllCallSites'
  UsedAssumedInformation, which is only ever set to true: `UsedAssumedInformationFromReachingKernels` starts false and
  never changes from that walk.
- KernelInfoState equality compares the five set states and NestedParallelism only (not IsAtFixpoint, the
  init/deinit calls or the kernel environment); `AAKernelInfoCallSite::updateImpl` copies the callee's whole state,
  including IsAtFixpoint.

## Host transformations (CGSCC pass), in this order

1. `deleteParallelRegions`: a `__kmpc_fork_call` whose microtask (operand 2) `onlyReadsMemory` and is `willreturn`.
2. `hideMemTransfersLatency` (`-openmp-hide-memory-transfer-latency`): `%handle = alloca %struct.__tgt_async_info`
   at the entry's first non-PHI/non-static-alloca point (with its debug location), an `addrspacecast` to `ptr` if
   the alloca address space is not 0, `__tgt_target_data_begin_mapper_issue(args..., handle)` replaces the call and
   `__tgt_target_data_begin_mapper_wait(device_id, handle)` goes before the first later instruction that may have
   side effects or read memory (or the terminator).
3. `deduplicateRuntimeCalls`: per SCC function, 15 getters and `__kmpc_global_thread_num`. The kept call is the
   first movable one in use-list order, moved to the nearest common dominator of all of them; its ident (operand 0)
   becomes the common global ident of the calls, or a new default one (`;unknown;unknown;0;0;;`, flags 2).
   `__kmpc_global_thread_num` is replaced by a "global thread id" argument when one exists
   (`collectGlobalThreadIdArguments`: internal callees whose every call passes a gtid).
- New idents and source location strings are appended to the global list: `private unnamed_addr constant
  %struct.ident_t {...}, align 8` / `[N x i8] c"...", align 1`; existing ones with the same initializer are reused
  (the *last* matching ident, the *first* matching string).

## Order that does not show

- `internalizeFunctions`' SmallPtrSet, AAExecutionDomain's barrier/assume SmallPtrSets and the BEDMap / CEDMap /
  UniqueKernelMap DenseMaps are only membership-tested, merged or looked up (deletion order of barriers does not
  change the output). `mergeParallelRegions` iterates a `SmallDenseMap<BasicBlock *, ...>`: with two or more blocks
  that get merged in one SCC the outlining order is the address order (not ported in impl/jai).
