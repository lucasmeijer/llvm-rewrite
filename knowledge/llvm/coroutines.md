# Coroutine passes (coro-early, coro-split, coro-elide, coro-cleanup, coro-annotation-elide)

Verified with tests/imported/llvm/Transforms/Coroutines and the LLVM 23.1.5 sources in
`lib/Transforms/Coroutines/`. Everything below changes printed output.

## Pipeline facts
- `coro-split` with no parameter has OptimizeFrame = false; `coro-split<reuse-storage>` sets it. The default
  pipelines build `CoroSplitPass(Level != O0)` but print it as plain `coro-split` (no printPipeline override), so
  the frame-storage reuse of -O1..-O3 cannot be read off `-print-pipeline-passes` (PassBuilderPipelines.cpp).
- CoroCleanup runs its own `FunctionPassManager{SimplifyCFGPass()}` on every function it changed. That run goes
  through the pass instrumentation: optnone functions are skipped (and it counts for `-opt-bisect-limit`). Default
  SimplifyCFGOptions do not convert switches to icmp (coro-split-sink-lifetime-01.ll's optnone function keeps its
  switch).
- The coro passes never call salvageKnowledge (only InlineFunction does, for the async ABI and
  coro-annotation-elide), so `-enable-knowledge-retention` changes nothing for them.

## Frame layout (CoroFrame.cpp)
- The frame is no longer a struct type: spills and allocas are byte offsets (`getelementptr inbounds i8, ptr %frame,
  i64 N`, named `<v>.spill.addr` / `<v>.reload.addr`). A GEP with offset 0 is still emitted for reloads.
- Switch ABI header: resume fn ptr, destroy fn ptr, the promise (if any) as fixed-offset fields, then the index
  field `i<max(1, Log2_64_Ceil(#suspends))>`: with no suspends that is **i64** (Log2_64_Ceil(0) = 64), visible in
  the `__coro_index` debug member (coro-split-dbg-nested-struct.ll).
- Field order comes from performOptimizedStructLayout (Support/OptimizedStructLayout.cpp): flexible fields sorted by
  alignment desc, size desc, insertion order; if that leaves no padding it is used as is, otherwise the
  alignment-queue filler algorithm. A queue's MinSize is only updated when its *tail* is removed.
- `addField` of a zero-size field returns field index 0 (the resume pointer) instead of adding a field.
- With OptimizeFrame, allocas are sorted by size (std::sort, size descending) and greedily merged into sets whose
  StackLifetime ranges (May liveness) do not overlap and whose first (largest) member's alignment is a multiple;
  while computing liveness the suspend switches' default destination is temporarily the resume successor.

## Ordering details that show in the output
- Shape::analyze swaps the final suspend to the end of CoroSuspends, and a fallthrough coro.end to the front of
  CoroEnds.
- movePHIValuesToInsertedBlock inserts each new single-entry PHI at the *beginning* of the inserted block, so the
  PHIs come out in reverse order; they are named `<incoming value name>.<succ name>` (".<succ>" for an unnamed or
  constant value).
- cleanupSinglePredPHIs RAUWs single-incoming PHIs but does not erase them; a pure `cgscc(coro-split)` run leaves
  them dead in the output.
- sinkLifetimeStartMarkers walks `SmallPtrSet<BasicBlock *, 4>{entry, successor of each suspend}`: insertion order
  with up to 4 blocks, pointer-hash order beyond. The first block that dominates all non-lifetime users wins.
- AllocaUseVisitor::getAliasesCopy returns a DenseMap: the alias GEPs re-created after coro.begin come out in
  pointer order when there are several.
- sinkSpillUsesAfterCoroBegin sorts with `DominatorTree::dominates` (not a strict weak ordering): the result is
  libstdc++'s std::sort's permutation.
- Clones are created at the end of the module (switch ABI: `.resume`, `.destroy`, `.cleanup`, then the private
  `<f>.resumers` array at the end of the globals) or right after the coroutine (retcon / async: `.resume.N`, Swift
  mangled `TQN_` / `TYN_` for the swift projection functions).
- BaseCloner::create maps the arguments to unlinked `freeze poison` dummies; anything that still refers to them at
  the end (debug records) becomes `poison`.

## Debug info
- buildFrameDebugInfo only runs for C++ compile units with FullDebug. `__coro_frame` is a uniqued DILocalVariable
  appended to the subprogram's retainedNodes (a new uniqued tuple), with a `#dbg_declare` inserted *at the head* of
  the records after the frame pointer. Its type is a uniqued `<f>.coro_frame_ty` DICompositeType whose elements are
  replaced after the members (which point back at it) exist, i.e. a uniqued cycle.
- `createPointerType(nullptr, PtrSize, AddressSpace)` passes the address space as AlignInBits: the `__resume_fn` /
  `__destroy_fn` member type has no align. The array type of an unknown type gets its *byte* alignment as AlignInBits.
- Resume points of the switch ABI get `__coro_resume_N` DILabels (artificial, coroSuspendIdx N, file and line of the
  outermost inlined-at location of the suspend) at the head of `resume.N`.
- coro::salvageDebugInfo puts an argument's `<arg>.debug` alloca at the entry block's first insertion point
  *with the head bit* (before the records there) unless it had to skip intrinsics; on 64-bit triples the clones use
  DW_OP_LLVM_entry_value for swiftasync arguments.
- The clones' DISubprograms are distinct copies with the linkage name of the clone and scopeLine taken from the
  first located instruction after the active suspend (updateScopeLine); a declaration is cloned with the new linkage
  name too.
- CloneFunctionInto's metadata mapper clones function-local types (scope inside the cloned subprogram) including
  distinct DICompositeTypes with an identifier.

## CoroElide / CoroAnnotationElide
- BeginDeadMap gets an entry for a coro.begin only if it has users; a coro.begin without users makes the
  coroutine ineligible for heap elision.
- The elided frame is `alloca [N x i8]` (N and align from the resume function's `dereferenceable` / `align`
  parameter attributes) plus a real `bitcast ptr %0 to ptr` named `vFrame`.
- coro-annotation-elide compares the call's block frequency with `uint64_t(EntryFreq * 0.55f)` (float math).
