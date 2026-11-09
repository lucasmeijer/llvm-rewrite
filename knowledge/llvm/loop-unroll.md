# LoopUnroll, runtime unrolling, peeling: behaviour that decides output

Verified with the Jai port (impl/jai/src/pass_loop_unroll.jai, loop_unroll_utils.jai, loop_unroll_runtime.jai,
loop_peel.jai, value_mapper.jai, clone_function.jai): 124/128 `::opt` checks of `Transforms/LoopUnroll` (the rest are
`-O1`/`-O2` pipelines and `-pgso`), and `loop-unroll`, `loop(loop-unroll-full)` identical to opt 23.1.5 on every
round-tripping corpus file, whole-file and `--per-function`, also with `-unroll-runtime`,
`-unroll-runtime-epilog=false`, `-unroll-force-peel-count=2`, `-unroll-count=3` and
`-unroll-allow-partial -unroll-runtime -unroll-threshold=300`.

## Pass structure

- `loop-unroll` is a *function* pass (LoopUnrollPass::run): it first runs simplifyLoop + formLCSSARecursively on every
  top-level loop (with the SE), then walks the loops in appendLoopsToWorklist order. The `for (auto &L : LI)` loop
  holds a reference to the TopLevelLoops slot, so if simplifyLoop replaces the top-level loop (separateNestedLoop),
  formLCSSARecursively runs on the replacement. `loop-unroll-full` is a loop pass (OnlyFullUnroll, no partial/runtime,
  peeling allowed but not profile-based peeling, no AA so no loadCSE).
- Only `loop-unroll` passes AAResults, so only it runs loadCSE after a partial/runtime unroll. loadCSE builds a
  *loop-scoped* MemorySSA (MemorySSA(Loop&): accesses only for the loop blocks, liveOnEntry in the header, a
  MemoryPhi IDF placed in the preheader is replaced by liveOnEntry and removed, renaming starts at the preheader's
  DT node with the exit blocks pre-marked visited) the first time a matching load is found in another generation.
- Parameters: `loop-unroll<O0..O3;[no-]partial;[no-]peeling;[no-]profile-peeling;[no-]runtime;[no-]upperbound;full-unroll-max=N>`.
  `Os`/`Oz` are a fatal usage error.

## x86 unrolling preferences

- X86TTIImpl does not override getUnrollingPreferences: BasicTTIImplBase's version enables Partial/Runtime/UpperBound
  with PartialThreshold = the scheduling model's LoopMicroOpBufferSize, unless a non-intrinsic call that is lowered to
  a call is in the loop (or `-partial-unrolling-threshold` overrides it). The model is the **TuneCPU**'s: no
  `tune-cpu` attribute = the `target-cpu` (or `-mcpu`), `x86-64` becomes `generic`; no CPU at all = `i586` =
  GenericModel = 0 = no partial/runtime unrolling. `generic` and `x86-64` use SandyBridgeModel (28), Haswell/
  Broadwell/Skylake/IceLake 50, Alderlake/SapphireRapids 72, Znver3 96, Znver4 108, Atom/SLM 10; a `-1` in the .td
  (BdVer2) is MCSchedModel's default 0 (gen/gen_x86_sched.py).
- getPeelingPreferences of BasicTTI equals the defaults; a module without a triple (NoTTIImpl) changes nothing.

## Cost model details

- analyzeLoopUnrollCost uses TTI.getInstructionCost(I, Operands, TCK_SizeAndLatency) with the *simplified* operands
  (operand info of a constant changes the cost), the rolled cost with the real operands.
- UnrolledInstAnalyzer's `visitLoad`, `visitBinaryOperator`, `visitCastInst`, `visitCmpInst`, `visitPHINode` are the
  InstVisitor opcode/class visitors; everything else is `visitInstruction` = simplifyInstWithSCEV. The cast visitor
  checks the full CastInst::castIsValid (uitofp i32 -> x86_fp80 is valid; a partial castIsValid made a 10-iteration
  x86_fp80 loop not fully unroll).

## Cloning

- CloneBasicBlock without a function (UnrollLoop) creates a parentless block: the names `x.1` are not uniqued until
  `F->insert`, which reinserts the instructions' names in order and then the block's.
- RemapInstruction does `Op = mapValue(Op)` for every operand with a mapping, including identity mappings of
  globals and constants: Use::set unlinks and pushes the use to the front of the value's use list, so use-list order
  changes even when nothing is remapped.
- New exit/epilog phis are named `PN.getName() + ".unr"` / `".epil.init"` even for unnamed phis (`%.unr`).
- All loop IDs built by makeFollowupLoopID / addStringMetadataToLoop / makePostTransformationMetadata are distinct
  self-referential nodes (a uniqued node whose operand 0 becomes itself drops uniquing).
- SplitLandingPadPredecessors inserts the cloned landingpad at NewBB->getFirstInsertionPt(), i.e. after the phis that
  UpdatePHINodes created (peeling a loop whose exits are landing pads reaches this through simplifyLoop).
- SplitEdge into a block whose single predecessor is the source uses splitBlockBefore: the phis of the successor move
  into the new block (peeling the last iteration splits the exit like this).

## ScalarEvolution quirk found here

- proveNoWrapByVaryingStart iterates `for (unsigned Delta : {-2, -1, 1, 2})`: Delta is a 32-bit unsigned and is
  zero-extended to uint64_t by `APInt - uint64_t` and `getConstant(Ty, uint64_t)`. For types wider than 32 bits the
  "-2" and "-1" deltas are 2^32-2 and 2^32-1, so only +1/+2 can find an existing nsw/nuw neighbour addrec. Treating
  them as -2/-1 made the peeled loop's niter add get `nsw` (SimplifyIndVar after peeling).

## Flags

- `-disable-loop-unrolling` only sets PipelineTuningOptions::LoopUnrolling (read by -O<n> pipelines); `-disable-verify`
  only skips opt's own input/output verification. Neither changes a `-passes=` run.
