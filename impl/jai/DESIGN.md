# impl/jai — design of the IR core

Data-oriented, no OOP. Every IR entity is a **32-bit index** into flat, growable tables. Kind-specific behaviour is a
`switch` on a small enum tag (`if x == { case .ADD; ... }` with `#complete`), never a virtual call, inheritance or
a visitor. All of this is plain Jai: `[..] T` dynamic arrays, structs of arrays written out by hand (the `Soa`
module in the distribution is marked experimental), `Table` from `Hash_Table` for interning, and the temporary
allocator for per-pass scratch.

**No hand-rolled vtables.** Don't emulate virtual dispatch with procedure-pointer fields in a struct (a `hook`,
`visit`, `callback` member assigned per "subclass"), with tables of procedure pointers, or with polymorphic
procedures standing in for a class hierarchy. Where LLVM has an interface with several implementations (a
`SCEVRewriteVisitor` subclass, a `CaptureTracker`, an AA result, a pass), give the struct a `kind: enum` plus that
kind's state, and `switch` on the kind (`#complete`) at the one place LLVM makes the virtual call. Where only one
implementation matters to us, drop the interface and call the plain procedure. This keeps every behaviour visible
with grep, keeps the data flat, and matches the Goose implementation (which has no function pointers at all).

```
src/
  ir.jai          tables, ids, use lists, create/erase/RAUW, interning (types, constants, attributes, metadata)
  lexer.jai       LLLexer port (token stream over the input bytes)
  parser.jai      LLParser port (builds the tables; reproduces LLParser's creation order and placeholders)
  printer.jai     AsmWriter + SlotTracker + TypeFinder port
  apfloat.jai     the bits of APFloat/APInt the printer and constant folder need (exact decimal printing)
  intrinsics.jai  intrinsic IDs (gen_iit.jai), signature matching, name mangling, getOrInsertDeclaration, attributes
  autoupgrade.jai AutoUpgrade (intrinsics, TBAA, module flags) and a constant-folding IRBuilder subset
  constfold.jai   ConstantFold.cpp port (cf_* fold or NONE, ce_* = ConstantExpr::get*)
  debuginfo.jai   DI* nodes, DIArgList, debug records, debug-intrinsic upgrade, StripDebugInfo
  apint.jai       APInt (arbitrary width, words in temp) and KnownBits arithmetic
  ir_edit.jai     mutation/CFG API for passes: iterators, successors/predecessors, phi edits, builders, split block
  inst_props.jai  mayHaveSideEffects, willReturn, wouldInstructionBeTriviallyDead
  tli.jai         TargetLibraryInfo (tli_for(f), tli_lookup_*, tli_func_has; gen_tli.jai from TargetLibraryInfo.td)
                  and the Triple parser/normalizer it needs (gen_triple.jai from TripleName.def)
  build_lib_calls.jai, simplify_lib_calls.jai, simplify_lib_calls2.jai   BuildLibCalls.cpp, SimplifyLibCalls.cpp
                  (LibCallSimplifier, used by InstCombine's tryOptimizeCall); value_tracking_strings.jai
                  (getConstantStringInfo, GetStringLength); pass_inferattrs.jai (InferFunctionAttrs)
  domtree.jai     DominatorTree/PostDominatorTree (SemiNCA, incremental updates, IDF calculator, printer)
  knownbits.jai   KnownBits.cpp (kb_*); apint.jai is APInt with an inline 64-bit word (ap_*)
  constant_range.jai  ConstantRange (cr_*); cmp_pred.jai CmpInst predicate algebra; intrinsic_ids.jai IID_* constants
  analysis_base.jai   SimplifyQuery (passed by value), AssumptionCache (ac_*), instruction/edge dominance helpers
  pattern.jai     PatternMatch (pm_*: BinaryOp_match only matches instructions, as in LLVM 23) and the APFloat struct
  value_tracking.jai / value_tracking2.jai   ValueTracking (known bits, non-zero, power of two, sign bits, implied
                  conditions, constant ranges, overflow, poison/undef reasoning, underlying objects)
  fpclass.jai     KnownFPClass, computeKnownFPClass, fcmpImpliesClass/fcmpToClassTest, ConstantFPRange
  const_folding.jai   ConstantFolding.cpp (cfo_*: DataLayout-aware folding, loads, GEPs); const_folding_calls.jai
                  ConstantFoldCall + the TLI math subset; apfloat_ops.jai rounding-mode APFloat operations
  inst_simplify.jai   InstructionSimplify.cpp (simplify_instruction(i, q) and the simplify_*_inst entry points)
  demanded_bits.jai  DemandedBits analysis and print<demanded-bits>
  print_util.jai  printAsOperand / Instruction::print for analysis printers
  passes.jai      pass registry, pipeline parser, pass and analysis managers, opt's command line (opt_main)
  pass_<name>.jai one file per ported pass (dce + break-crit-edges, adce, bdce, mem2reg, sroa, instsimplify, ...)
  ir_builder.jai  IRBuilder<ConstantFolder>: insertion point, debug location, name prefix (Irb, irb_*)
  salvage_debug.jai  salvageDebugInfo, replaceAllDbgUsesWith, LowerDbgDeclare, RemoveRedundantDbgInstrs, DIExpression
                  rewriting (appendOpsToArg, foldConstantMath, ...), record location edits
  pass_debugify.jai debugify / check-debugify
  dbg_records.jai debug-record utilities (owners, findDbgUsers, ValueAsMetadata RAUW/deletion, DIExpression,
                  merged DILocations, dbg.declare -> dbg.value conversion)
  value_utils.jai GEP constant offsets and pointer stripping (sv_*)
  ssa_updater.jai SSAUpdater + LoadAndStorePromoter
  capture_tracking.jai  CaptureTracking (DetermineUseCaptureKind, PointerMayBeCaptured[Before], FindEarliestCapture)
                  and CFG.cpp reachability (isPotentiallyReachable*)
  aa.jai          ModRef/MemoryEffects helpers, LocationSize, MemoryLocation, AAResults aggregation (Aa_Results,
                  Aa_Query = AAQueryInfo), object classification, -aa-pipeline, aa-eval
  basic_aa.jai    BasicAA (DecomposeGEP, aliasGEP/PHI/Select, call mod/ref), getBaseObjectSize/getAllocSize
  tbaa.jai, scoped_noalias_aa.jai, globals_aa.jai (+ CallGraph and its SCCs)
  memoryssa.jai   MemorySSA (construction, OptimizeUses, ClobberWalker, PHITransAddr, printers)
  loop_info.jai   LoopInfo (analyze, queries, update API, loop metadata, print<loops>)
  cycle_info.jai  CycleInfo (print<cycles>)
  bb_utils.jai    SplitBlockPredecessors (+ landing pads), SplitBlock, DT/LoopInfo update helpers
  pass_loop_simplify.jai, pass_lcssa.jai   LoopSimplify (+ formDedicatedExitBlocks, makeLoopInvariant,
                  foldBranchToCommonDest for exit merging), LCSSA (formLCSSA*, SSAUpdater::RewriteUse)
  loop_pm.jai     loop(...) / loop-mssa(...): FunctionToLoopPassAdaptor, LoopPassManager, LPMUpdater
  pass_loop_rotate.jai  LoopRotate, MergeBlockIntoPredecessor, CodeMetrics, x86 code-size cost bounds
  mssa_updater.jai MemorySSAUpdater (insertDef/insertUse, removeMemoryAccess, moveTo*, applyUpdates, removeBlocks,
                  updateForClonedLoop / updateExitBlocksForClonedLoop, ...)
  pass_simple_loop_unswitch.jai  SimpleLoopUnswitch (`slu_*` state, trivial + non-trivial unswitching, loop cloning,
                  hasPartialIVCondition, SplitBlockAndInsertIfThen with an eager DTU)
  must_execute.jai ICFLoopSafetyInfo (MustExecute.cpp) + InstructionPrecedenceTracking, colorEHFunclets
  alias_set_tracker.jai  AliasSetTracker
  pass_licm.jai   LICM / LNICM (incl. ControlFlowHoister, LoopPromoter, hoistArithmetics)
  pass_dse.jai    DeadStoreElimination (DSEState = `Dse`: MemorySSA walk, OverlapIntervals, calloc folding, initializes)
  pass_memcpyopt.jai  MemCpyOpt (`Mco`: memset merging, call slot / memcpy / memset forwarding, stack move, byval)
  assume_builder.jai  AssumeBundleBuilder salvageKnowledge (-enable-knowledge-retention, AC-less form only)
  value_handles.jai   WeakTrackingVH / TrackingVH (slots updated by replace_all_uses_with / erase_inst)
  scev_expander.jai   SCEVExpander (`Scev_Expander`, sx_*), its SE/LoopInfo helpers
  simplify_indvar.jai, pass_indvars.jai   SimplifyIndVar (Siv, Widen_IV), IndVarSimplify (Ivs), rewriteLoopExitValues
  phi_trans_addr.jai  PHITransAddr (pta_*: translateValue incl. select conditions, translateWithInsertion)
  memdep.jai      MemoryDependenceAnalysis (md_*: local/non-local deps, caches, removeInstruction)
  vn_coercion.jai VNCoercion (vnc_*)
  pass_gvn.jai    GVN (gvn_*: ValueTable, LeaderMap, load elimination with MemDep or MemorySSA, load/scalar PRE)
  pass_early_cse.jai  EarlyCSE (`Early_Cse`, ec_*: the five ScopedHashTables in one bucket store, ParseMemoryInst)
  predicate_info.jai  PredicateInfo (`Predicate_Info`, pi_*: SSA copies as no-op bitcasts, getConstraint, print<predicate-info>)
  sccp_solver.jai     SCCPSolver (`*Sccp`, sc_*: lattice values in `lat`, maps hold indices; the InstVisitor is a switch)
  pass_sccp.jai       sccp / ipsccp drivers (runSCCP, runIPSCCP, findReturnsToZap, getExpressionForConstant)
  function_specialization.jai  FunctionSpecializer + InstCostVisitor (`Func_Spec`, `Fs_Cost_Visitor`, fs_*), CloneFunction
                      with a LocalChangesOnly MDNodeMapper (fs_map_md), libstdc++ heap algorithms for the spec selection
  pass_mergeicmps.jai MergeICmps (`Mic_Block` = BCECmpBlock, `Mic_Chain`, dt_set_new_root)
  pass_dfa_jump_threading.jai  DFAJumpThreading (`Dfa`, MainSwitch / AllSwitchPaths / TransformDFA as dfa_* procedures,
                      SSAUpdaterBulk::RewriteAllUses as dfa_ssa_rewrite_all_uses)
  value_lattice.jai   ValueLatticeElement (`Vle`, vle_*)
  lazy_value_info.jai LazyValueInfo (`*Lvi`, lvi_*: block-value cache, solver, edge values, query API, printer)
  pass_cvp.jai    CorrelatedValuePropagation (cvp_*)
  pass_jump_threading.jai  JumpThreading (`Jt`, jt_*), MergeBasicBlockIntoOnlyPred, SimplifyInstructionsInBlock,
                  DuplicateInstructionsInSplitBetween, findAvailablePtrLoadStore, noalias-scope cloning
  branch_prob.jai BranchProbabilityInfo (`*Bpi`, bpi_*; BranchProbability helpers bp_*, CFG scc_iterator)
  block_freq.jai  BlockFrequencyInfo (`*Bfi`, bfi_*; ScaledNumber `Scaled64` sn_*, BlockMass bm_*)
  value_mapper.jai    ValueMapper (`Value_Map` = ValueToValueMapTy; map_value, remap_instruction, remap_dbg_record)
  clone_function.jai  CloneBasicBlock, remapInstructionsInBlocks, noalias-scope cloning, cloneLoop
  loop_utils.jai      loop metadata (attributes, followup ids, estimated trip counts, convergence heart),
                      BranchProbability (`Bprob`) and the branch/loop probability helpers of LoopUtils
  pass_loop_unroll.jai  LoopUnrollPass / LoopFullUnrollPass, UnrollingPreferences (+ BasicTTI's), UnrolledInstAnalyzer,
                      analyzeLoopUnrollCost, the unroll cl::opts (`lu_cl`)
  loop_unroll_utils.jai  UnrollLoop, simplifyLoopAfterUnroll, loadCSE (+ loop-scoped MemorySSA), fixProbContradiction
  loop_unroll_runtime.jai  UnrollRuntimeLoopRemainder (prolog/epilog), SplitEdge, splitBlockBefore
  loop_peel.jai       LoopPeel (computePeelCount, PhiAnalyzer, peelLoop)
  gen_x86_sched.jai   generated: X86 CPU -> scheduling model -> LoopMicroOpBufferSize (gen/gen_x86_sched.py)
  tti_vectorizer.jai  TTI queries of the vectorizers (register classes/widths, explicit-operand insert/extract,
                      demanded-lane scalarization, reduction costs, commonOperandInfo)
  vector_utils.jai    VectorUtils/LoopUtils helpers for vectorizers (shuffle-mask scaling, propagateIRFlags, reductions)
  pass_vector_combine.jai  VectorCombine (`vc` state, its own InstructionWorklist, `vcb_*` = IRBuilder<InstSimplifyFolder>)
  slp_utils.jai, slp_lookahead.jai, slp_operands.jai, slp_tree.jai   SLPVectorizer (in progress, not a pass yet):
                      helpers + InstructionsState, LookAheadHeuristics, VLOperands, BoUpSLP state (`slp`, Tree_Entry rows)
  ipo_utils.jai   GlobalValue / GlobalVariable / Function helpers for module passes (linkage, comdats, deleteBody,
                  eraseFromParent with metadata, destroyConstant, llvm.used, CtorUtils, GlobalStatus) and function
                  signature rewriting (ipo_fn_create / ipo_fn_splice_body / ipo_create_call_like)
  evaluator.jai, pass_global_opt.jai, pass_global_dce.jai, pass_constant_merge.jai, pass_internalize.jai,
  pass_strip_dead_prototypes.jai, pass_elim_avail_extern.jai, pass_assign_guid.jai, md5.jai   IPO module passes
  pass_dead_arg_elim.jai, pass_arg_promotion.jai   DeadArgumentElimination (module), ArgumentPromotion (CGSCC)
  pass_partial_inliner.jai, code_extractor.jai   PartialInliner (single region) and CodeExtractor
  attributor.jai, attributor_aas.jai   AttributorLight (module + CGSCC): the Attributor framework (`Irp` positions,
                  `Abs_Attr` rows, fixpoint, AttrsMap, MustBeExecutedContextExplorer) and its 17 abstract attributes
  pass_lower_expect.jai, pass_lower_constant_intrinsics.jai, pass_infer_alignment.jai, pass_div_rem_pairs.jai,
  pass_float2int.jai, pass_sink.jai, pass_tailcallelim.jai, pass_mldst_motion.jai, pass_speculative_execution.jai,
  pass_callsite_splitting.jai (L1.scalar-misc; their cl::opts: scalar_misc_cl.jai), and the small -O2 passes:
  pass_loop_sink.jai, pass_transform_warning.jai, pass_drop_unnecessary_assumes.jai, pass_jump_table_to_switch.jai,
  pass_move_auto_init.jai, pass_alignment_from_assumptions.jai, pass_libcalls_shrinkwrap.jai,
  pass_called_value_propagation.jai (+ its SparseSolver), pass_rel_lookup_table_converter.jai, pass_cg_profile.jai,
  pass_ee_instrument.jai, pass_inject_tli_mappings.jai, pass_misc_module.jai (forceattrs, memprof-remove-attributes,
  recompute-globalsaa, lower-comment-string, alloc-token), pass_remark_only.jai, pass_coroutines.jai,
  pass_openmp_opt.jai (early exits)
  pass_lto_misc.jai (the LTO pipelines' module passes), pass_merge_functions.jai (MergeFunctions, FunctionComparator)
  linker.jai      llvm-link: ModuleLinker, IRMover (IRLinker, TypeMapTy), its ValueMapper (see "llvm-link" below)
  opt.jai / llc.jai / llvm_link.jai    CLI entry points
```

## 1. Ids and the world

```jai
Type_Id  :: u32;     // index into the type table
Value_Id :: u32;     // index into the value table (constants, globals, args, blocks, instructions)
Use_Id   :: u32;     // index into the use (operand) table
Md_Id    :: u32;     // index into the metadata table
// attribute sets and lists are u32 indices too: 0 = empty
NONE     :: 0xFFFF_FFFF;
```

(Plain aliases, not `#type,distinct`: distinct types need a cast at every table index, which made the code
noisy. The names still document intent.)

There is one global `IR` struct per process (the equivalent of `LLVMContext` + `Module`s). It owns every table.
Modules (for `llvm-link`) are lists of global-value ids inside the same world, so types and constants are shared
exactly like in an `LLVMContext`: `ir` holds the module-level state (global lists, symbol table, comdats, named
metadata, target strings, module asm) of the *current* module, and `linker.jai`'s `Module_State` holds another
module's (see "llvm-link"). Entities are never moved: an id stays valid until the entity is erased, and erased
ids are not reused within a run (erasure marks the row dead, see §5). That keeps every order deterministic and
makes `id` comparisons meaningless for semantics, which is deliberate: **order always comes from explicit lists,
never from id values**, except where LLVM itself orders by creation (§6).

## 2. Tables

### Values (struct of arrays, one row per `llvm::Value`)

| column | type | meaning |
| --- | --- | --- |
| `v_kind` | `Value_Kind` (u8) | ARGUMENT, BLOCK, INST, GLOBAL_VAR, FUNCTION, ALIAS, IFUNC, CONST_INT, CONST_FP, CONST_NULL (zeroinitializer / null / none), UNDEF, POISON, CONST_ARRAY, CONST_STRUCT, CONST_VECTOR, CONST_DATA_ARRAY (`c"..."`, data vectors), CONST_EXPR, BLOCK_ADDRESS, DSO_LOCAL_EQUIV, NO_CFI, PTRAUTH, METADATA_AS_VALUE, INLINE_ASM, DEAD, … |
| `v_type` | `Type_Id` | `getType()` |
| `v_name` | `string` | name without sigil; empty = unnamed (numbered by the printer) |
| `v_first_use` | `Use_Id` | head of the use list (§3) |
| `v_ops` / `v_nops` / `v_cap` | `Use_Id`, u32, u32 | operand range in the use table (instructions and constants are users) |
| `v_aux` | u32 | row index into the kind's side table (instruction row, global row, constant payload, …) |

Side tables, one row per entity of that kind, also SoA:

- **Instructions** (`ir.insts`, one `Inst_Row` struct per instruction; the per-opcode payload is folded into the
  same fixed-width row rather than separate side tables): `opcode` (u8 enum, LLVM's `Instruction::` opcodes), `sub` (u32 "subclass data": wrap
  flags nuw/nsw, exact, disjoint, nneg, samesign, fast-math flags, predicate, atomic orderings, volatile, tail kind,
  calling conv, alignment log2…), `parent` (block Value_Id), `prev`/`next` (intrusive list inside the block),
  `extra` (u32 index into per-opcode payload arrays, e.g. GEP/alloca source type, call function type + `Attr_List`,
  shuffle mask, extract/insertvalue indices, cmpxchg/atomicrmw details), `md` (index of the first metadata
  attachment, §4), `order` (lazily renumbered position for `comesBefore`).
- **Blocks** `b_*`: `parent` function, `first`/`last` instruction, `prev`/`next` block.
- **Functions / globals** `g_*`: linkage, visibility, DLL storage, thread-local mode, unnamed_addr, address space,
  value type, section, partition, comdat, alignment, `Attr_List`, calling convention, GC, prefix/prologue/
  personality (as operands), first/last block, argument range (arguments are values allocated contiguously at
  function creation), metadata attachments, and a per-function local symbol table.
- **Constants**: CONST_INT stores its APInt in a word pool (`ap_words`, offset in `v_aux`, width from the type);
  CONST_FP the same; aggregates/exprs keep their operands as uses, and the expression opcode/flags/GEP source type in
  a `cexpr` side table; CONST_DATA_ARRAY keeps raw bytes.

### Uses (one row per operand slot)

`u_val` (the used value), `u_user` (the user Value_Id), `u_next`, `u_prev` (doubly linked use list of `u_val`;
`u_prev == NONE` means "I am the head"), `u_aux` (side data that is *not* a `Use` in LLVM and so is in no use list:
a phi's incoming block, a switch case's `ConstantInt` value; LLVM 23 keeps switch case values next to the hung-off
operands, so a switch's operands are `[cond, default, dest...]`). A user's operands are a contiguous range
`v_ops .. v_ops+v_nops`; `v_cap` is the reserved capacity (LLVM's `ReservedSpace`). Growing past capacity (phi
`addIncoming`, `switch` `addCase`, `indirectbr` `addDestination`, landingpad clauses) follows each class's
`growOperands` policy (phi `n + n/2` (min 2), switch `3n`, indirectbr `2n`) and `User::growHungoffUses`: a new
range at the end of the use table, the old operands copied in operand order with `Use::set` (each copied use moves
to the *front* of its value's use list), then the old uses destroyed. So growth reorders use lists the way LLVM's
does.

### Types (interned, `Type_Id`)

`t_kind` (VOID, LABEL, METADATA, TOKEN, INT, HALF, BFLOAT, FLOAT, DOUBLE, X86_FP80, FP128, PPC_FP128, X86_AMX,
PTR, FUNC, STRUCT, ARRAY, VECTOR, SCALABLE_VECTOR, TARGET_EXT), `t_a` (int width / addrspace / element count /
vararg / packed), `t_sub` + `t_nsub` (contained types in a `type_list` pool), `t_name` (named structs). Literal types
are interned through a `Table` keyed by a byte-string encoding of (kind, a, subtypes). Identified (named) structs are
not structural: each `%name = type …` gets a fresh row; opaque-then-defined bodies are filled in place.

### Attributes

An attribute is `(kind: u8 enum in LLVM's tablegen order, int value or Type_Id or string key/value)`. `Attr_Set`
interns a *sorted* array exactly as `AttributeImpl::cmp` orders it: enum-kind attributes by kind number (tablegen
order = all EnumAttr defs sorted by def name, then TypeAttr, IntAttr, ConstantRangeAttr, ConstantRangeListAttr), then
string attributes by key then value. `Attr_List` interns `[fn, ret, param0, …]`. Interning means equal sets are
equal ids, which is what attribute-group numbering needs.

### Metadata (`Md_Id`)

`m_kind` (STRING, VALUE (ValueAsMetadata; constant or local), TUPLE (generic `!{…}`), SPECIAL (a DI* node:
`sub` = DI_Kind, operands in LLVM's operand order, integer fields in `ir.md_ints`), DI (parser temporary)),
`m_distinct`, `m_ops`/`m_nops` into an `md_ops` pool (`Md_Id`, NONE = null operand), `m_str`. Uniqued nodes are
interned by content in a `Table`; distinct nodes never are. Instruction/global attachments are rows
`(kind_id, Md_Id, next)` in an `attach` table. Kind ids: the fixed kinds of `FixedMetadataKinds.def` (dbg = 0,
tbaa = 1, …) pre-registered, custom kinds registered in order of first appearance, exactly like `LLVMContext`.
Named metadata is an ordered array of `(name, [Md_Id])` on the module. Debug records (`#dbg_value(...)`) are rows
of `ir.dbg_records`, chained per instruction from `Inst_Row.records` (the records printed before it).

The parser hands out one placeholder node per `!N` reference and resolves them all at the end of the module
(distinct nodes first get their row so self-references work; uniqued nodes are interned after their operands are
resolved, so two textually different but equal nodes merge as in LLVM), then rewrites every reference
(attachments, node operands, named metadata, `metadata` operands of calls).

## 3. Use lists — reproducing LLVM's order

LLVM's `Use::addToList` pushes at the **front**. `set_operand(use, v)` here does the same: unlink from the old
value's list, push at the head of `v`'s. So `v_first_use` iterates most-recent-first, like `Value::uses()`; the
printer's `; preds = …` comments (users of a block in use-list order) and every pass that walks `users()` see the
same sequence as LLVM.

`replace_all_uses_with(old, new)` copies LLVM: repeatedly take the *head* use of `old` and `set` it to `new` (which
reverses the moved uses onto the front of `new`'s list). If the user is a constant, it is not mutated blindly: like
`Constant::handleOperandChange`, the constant is re-interned with the new operand; if an equal constant already
exists, the user's own uses are RAUW'd to it and the old constant row dies; otherwise it is updated in place and
re-keyed in the interning table.

The parser reproduces LLParser's forward-reference mechanics because they decide use order:

- a forward-referenced *local value* gets a placeholder value (LLParser uses a fake `Argument`); when the definition
  arrives, the placeholder is RAUW'd, so forward uses end up in parse order ahead of later uses;
- a forward-referenced *block* is created immediately (no placeholder; `getBB` creates the block) and moved into
  position when defined;
- a forward-referenced *global* gets a placeholder global that is RAUW'd at its definition (constant users get
  re-interned as above).

Constants are interned and live for the whole run, and they are users: an unused `getelementptr` constant created
while parsing stays on its global's use list, as in LLVM (until a `removeDeadConstantUsers` equivalent runs).

## 4. Mutation by passes

- **Create**: `new_inst(opcode, type, nops)` appends rows to the value and instruction tables and reserves the
  operand range; `insert_before(inst, pos)` / `insert_at_end(block)` link it into the block's list. Blocks likewise
  (`new_block`, `insert_block_after`). Functions/globals are appended to the module's ordered arrays
  (`m_globals`, `m_functions`, `m_aliases`, `m_ifuncs`) or inserted at a position.
- **Mutate**: `set_operand`, `rauw`, `replace_uses_if(pred)`, `move_before`, `splice` (moves a list segment between
  blocks; only `parent` and the links change), `set_name` (goes through the symbol table, §6).
- **Erase**: `erase_inst` unlinks the instruction, drops its operand uses (each removed from its value's list),
  drops attachments, removes the name from the symbol table, and sets `v_kind = DEAD`. Erasing a value that still has
  uses is an assertion failure, as in LLVM. Dead rows are garbage that is never compacted within a run; a run is one
  process invocation.
- **Phis**: incoming values are operands, incoming blocks the `u_aux` column of the same rows, so
  `removeIncomingValue` keeps them in lockstep. LLVM's removal copies later entries down one slot with `Use::set`,
  which moves those uses to the front of their values' lists; the port must do the same (not patch links).

Analyses (dominator tree, loop info, …) are separate tables keyed by block id, built on demand on the heap and
cached per function; passes return the preserved set and the pass manager invalidates the rest (§9).

## 5. Allocation

- Big tables are `[..]` arrays in the default heap; they double, so amortised appends are O(1). Ids are indices, so
  reallocation never invalidates them (no pointers into tables are kept across a call that may grow a table).
- Strings (names, string attributes, MDString contents, section names) live in a `Flat_Pool` arena for the run;
  `string` slices point into it or into the input buffer, which is kept alive for the whole run.
- Per-pass and per-print scratch (worklists, slot maps, visited sets) uses `temporary_storage` and is reset between
  passes (`reset_temporary_storage()`), so passes need no frees.
- Nothing is freed individually; the process exits after writing the output.
- Hot-path traps (NOTES.md "Performance"): `tprint` / a `String_Builder` zero a 4 KB inline buffer per call (use
  `tconcat` / `tdec` for names), a `[..]` array's first `array_add` is an allocator call (use a stack buffer for small
  fixed-size scratch), and `Table` lookups are ~40 instructions (prefer dense arrays indexed by ids).
- Caches of derived data: struct layouts (`dl_cached_struct_layout`, per type, invalidated by bumping
  `dl_layout_gen` in `dl_init` and `set_struct_body`), the interned ids of `iN` for N <= 256 (`int_type_cache`), md
  kind ids of literals (`md_kind_cache`; fixed kinds on hot paths use the `MDK_*` constants).

## 6. Orders that LLVM's output depends on

| What | LLVM source | How we reproduce it |
| --- | --- | --- |
| Use-list order (`; preds =`, `users()` walks) | `Use::addToList`, `Value::doRAUW` | head insertion, RAUW takes head use (§3), parser placeholders (§3) |
| Local value numbering `%0, %1` | `SlotTracker::processFunction` | printer recomputes per function: unnamed args, then for each block: the block if unnamed, each non-void unnamed instruction. Nothing is stored in the IR. |
| Global numbering `@0` | `SlotTracker::processModule` | unnamed globals, then aliases, ifuncs, functions, in module list order |
| Name uniquing | `ValueSymbolTable::makeUniqueName` | per-function and per-module `Table(string, Value_Id)` plus a `last_unique` counter per table (monotonic, never reset); globals append `.N`, locals append `N`, retry until free |
| Attribute-group numbers `#N` | `SlotTracker::CreateAttributeSetSlot` | in `processModule`: global-variable attribute sets and function attribute sets in module order; then, while printing each function, call-site function-attribute sets in instruction order. Groups are printed after all functions, in number order. |
| Metadata numbers `!N` | `SlotTracker::CreateMetadataSlot`, lazy per-function processing | global-variable attachments, ifunc attachments, named metadata operands (module order), then per function as it is printed: function attachments, then for each instruction the MDNode operands of intrinsic calls and the attachments (sorted by kind id, stable). Recursion into node operands assigns depth-first pre-order. Nodes are printed after the attribute groups, in number order. |
| Attachment order on an instruction | `MDAttachments::getAll` (stable sort by kind id) | kind ids as in §2; print `!dbg` first, others in kind order |
| Named struct types printed | `TypeFinder::run` (only named) | port of TypeFinder: globals' value types and initializers, aliases, ifuncs, then functions (type, attributes, operands, args, instructions' types, non-instruction operands, GEP/alloca types, call attributes, metadata), then named metadata; DFS with a worklist pushing subtypes in reverse |
| Attribute order inside a set | `AttributeImpl::cmp` | sorted on interning (§2) |
| Module lists | `Module::globals()` etc. | ordered arrays; the parser appends in definition order. A forward-referenced global's placeholder is RAUW'd and erased when the definition arrives, so the definition's position wins |

Where LLVM orders by pointer value (e.g. some `DenseMap` iterations or `SmallPtrSet` orders that leak into output),
the port must find the deterministic order LLVM actually produces in practice or use the same insertion order; such
cases are recorded in `knowledge/llvm/`.

## 7. Printing numbers

APFloat values print the way `AsmWriter`'s `writeAPFloatInternal` does: `double`/`float` in `%e`-like form with
6 digits after the point when that text reparses to the same value (exact decimal expansion, not `printf`), otherwise
`0x` + 16 hex digits of the value converted to double; `+inf`, `-inf`, NaN spellings as in LLVM 23; `half` `0xH`,
`bfloat` `0xR`, `x86_fp80` `0xK`, `fp128` `0xL`. Integers wider than 64 bits use multi-word arithmetic in
`apfloat.jai`.

## 8. Errors

Every unsupported construct (token, instruction, attribute, flag) makes the tool print
`<tool>: <file>:<line>:<col>: error: …` to stderr and exit 1. Output is only written once the whole module has been
processed, so a failure never leaves partial IR behind.

## 9. Pass infrastructure (passes.jai)

Ported from `llvm/lib/Passes/PassBuilder.cpp`, `llvm/include/llvm/IR/PassManager.h` and the instrumentation in
`StandardInstrumentations.cpp` / `OptBisect.cpp`. Everything is tables and switches:

- **Registry**: `PASS_TABLE` rows `{name, level (MODULE/FUNCTION/LOOP), kind: Pass_Kind, required, analysis}`.
  `name` is the textual PassRegistry.def name including parameters (`print<domtree>`). `required` passes (printers,
  `require<>`, `invalidate<>`) run on `optnone` functions and aren't counted by `-opt-bisect-limit`.
- **Pipeline**: `parse_pipeline_text` splits the text on `,()` into `Pipeline_Element` rows (tree via
  first_child/next), `parse_pass_pipeline` turns that into `Pass_Node` rows: `MODULE_PM`, `FUNCTION_ADAPTOR` and
  pass nodes, with LLVM's wrapping rules (first element not a module pass: the whole list goes into one
  `function(...)`; a function pass inside a module list gets its own adaptor). `loop(...)`/`loop-mssa(...)` become
  `LOOP_ADAPTOR` nodes whose children are loop passes (`LOOP_PM` for a nested `loop(...)`); see "Loops" below.
  `cgscc(...)` / `devirt<N>(...)` become `CGSCC_ADAPTOR` / `CGSCC_PM` / `DEVIRT` / `CGSCC_FN_ADAPTOR` nodes (see
  "CGSCC" below). Unknown names fail loudly. `-O<n>` fails loudly in `opt_main`.
- **Running**: `run_module_pm` → `run_function_adaptor` (every defined function in module order) →
  `should_run_pass` (OptNone, then OptBisect: prints `BISECT: ...` lines like LLVM) → `run_function_pass`, a
  `switch` on `Pass_Kind` that returns a `Preserved`. After each pass: `fam_invalidate(f, preserved)` and
  `reset_temporary_storage()`.
- **Preserved** = `PreservedAnalyses`: `all`, `cfg` (`preserveSet<CFGAnalyses>`), and a bit mask per
  `Analysis_Kind`. `analysis_survives` encodes each result's `invalidate`: dom/post-dom trees survive `cfg`.
- **Analyses** live in `fam: Table(Value_Id, Fn_Analyses)`, one heap-allocated result per kind and function:
  `get_domtree(f)` (= `AM.getResult`), `cached_domtree(f)` (= `getCachedResult`), same for post-dom and
  DemandedBits. Results that a pass keeps up to date (break-crit-edges updates a cached DT with `dt_apply_updates`)
  are returned as preserved.
- **Options**: `opts` holds the `cl::opt`s we know (`-adce-remove-loops`, `-opt-bisect-limit`, ...); `cl_opts()` maps
  names to fields; `parse_cl_opt` accepts `-x`, `--x`, `-x=v`. Unknown flags fail loudly.
- **Memory**: passes allocate scratch from `temp` explicitly (`arr.allocator = temp`); APInt words are always temp.
  Anything that must outlive the pass (analysis results) uses the heap (`New`, `ap_heap_copy`).
- **Printing inside passes**: `value_as_operand` / `inst_to_string` (print_util.jai) reproduce LLVM's per-call
  SlotTracker; the module printer for `-S` always starts from a fresh state (`print_module_fresh`).

### IR editing conventions (ir_edit.jai)

- Iterate with `for b: fn_blocks(f)`, `for i: block_insts(b)`, `for i: fn_insts(f)`. Use `for :early_inc` (next
  read before the body, LLVM's `make_early_inc_range`) when the body may erase `it`, `for :reverse_early_inc` for
  `reverse(instructions(F))`.
- Successor *i* of a terminator: `get_successor/set_successor` (operand layout per opcode in `succ_operand_index`).
  `block_predecessors` = `predecessors(BB)`: use-list order, one entry per edge, so it depends on use lists being
  right.
- New instructions: `create_br/create_cond_br/create_cast/create_binop/create_phi` build an unlinked instruction;
  `insert_before_named(i, pos, name)` links it and *then* names it (IRBuilder order, so `makeUniqueName` sees the
  current symbol table: BDCE's zext named after the still-live sext becomes `%x1`). New blocks: `create_block` or
  `new_block` + `fn_insert_block_after` + `note_block_created` + `set_name`.
- Erasing: `erase_inst` asserts that there are no uses. For a group of dead instructions do what LLVM does:
  `drop_all_references` on all of them first, then erase.
- Phis: `phi_remove_incoming` moves the last entry into the hole (LLVM 23), `block_remove_predecessor` is
  `BasicBlock::removePredecessor` (may fold a phi to its constant value).
- `drop_poison_generating_annotations`, `copy_debug_loc`, `is_critical_edge`, `find_function_backedges` are there
  too. Grep this file and inst_props.jai before writing a helper: names are global in Jai, a duplicate is a compile
  error (`call_arg`, `call_callee`, `strip_pointer_casts` live in autoupgrade.jai).

### Dominator trees (domtree.jai)

`Dom_Tree` rows `Dom_Node{block, idom, first_child, last_child, sibling, level, dfs_in, dfs_out}`; one struct for both
directions (`post`). Construction, `dt_apply_updates` (GraphDiff/LegalizeUpdates, InsertEdge/DeleteEdge with
LLVM's recalculation thresholds), `dt_dominates` (with LLVM's slow-query counter, which shows in the printer),
`dt_find_nca`, `dt_add_new_block`, `dt_change_idom`, `dt_erase_node` and `idf_calculate` (IDFCalculator) are ports of
GenericDomTree*. Child lists are in insertion order, exactly as LLVM's, so any pass that walks the tree sees LLVM's
order. Keep the tree updated the way the LLVM pass does (eager `applyUpdates` or the specific helper it calls);
recomputing gives a different child order.

Block -> node lookup (`dt_node`) is a dense array `node_dense` over block rows (`ir.v_aux` of the block) from
`dense_base`, the function's lowest block row when the tree was reset; the `node_of` Table holds the rest (the
post-dominator virtual root `NONE`, blocks moved in from a function created earlier). Write it only through
`dt_map_set`. Block numbers (`BasicBlock::Number`) are `Block_Row.number` (assigned once, in LLParser order by
`ensure_block_numbers`, then `note_block_created`); the function's counter is `Global_Row.next_block_num` (-1 = not
numbered yet). `Block_Set` (stamp per block row, O(1) clear) is the fast block set for hot paths; `idf_calculate` takes
a Table, a `Block_Set` or null for its def / live-in sets, and keeps its visited marks in global stamp arrays.

### Alias analysis and MemorySSA (aa.jai, basic_aa.jai, tbaa.jai, scoped_noalias_aa.jai, globals_aa.jai, memoryssa.jai)

- **AAResults** = `Aa_Results` (by value, `aa_results_for(f)` = `AM.getResult<AAManager>(F)`): the registered
  analyses as an `Aa_Kind` list in priority order plus BasicAA's DominatorTree/AssumptionCache. Every AAResults
  method is a loop over that list with a `switch` per kind. GlobalsAA is included only when `globals_aa` (the cached
  module result of `require<globals-aa>`) exists.
- **AAQueryInfo** = `*Aa_Query` (temp): alias cache with LLVM's assumption bookkeeping, depth, MayBeCrossIteration,
  the capture-analysis cache (SimpleCaptureAnalysis, or EarliestEscapeAnalysis via `aa_query_new_earliest_escape`).
  `aa_query_new(*aar)` per top-level query = SimpleAAQueryInfo; keeping one `*Aa_Query` across queries =
  BatchAAResults. All query entry points take the `*Aa_Query`: `aa_alias(q, la, lb, ctx)`,
  `aa_mod_ref_inst_loc(q, i, loc)`, `aa_mod_ref_inst_opt_loc(q, i, has_loc, loc)`, `aa_mod_ref_call_loc`,
  `aa_mod_ref_call_call`, `aa_mod_ref_inst_call`, `aa_mod_ref_inst_inst`, `aa_mod_ref_mask`, `aa_memory_effects_call`,
  `aa_call_captures_before`. Results: `Alias_Result` (kind AR_NO/AR_MAY/AR_PARTIAL/AR_MUST + offset), ModRef u8
  (MR_*), MemoryEffects u64 (parser.jai encoding).
- **MemoryLocation** = `Mem_Loc {ptr, size (LocationSize encoded like LLVM: ls_*), tags: AA_Tags}`; `mloc_get(i)`,
  `mloc_get_or_none`, `mloc_for_argument(call, k, use_tli)`, `mloc_for_dest/source`, `mloc_for_dest_call`.
- **MemorySSA** = `*Memory_SSA` (heap, cached as `Fn_Analyses.mssa`, `get_memoryssa(f)`): a table of `Mem_Access`
  rows (index 0 = liveOnEntry; DEF/USE/PHI tag; operands are row indices), per-block access/def lists as intrusive
  links through the rows, `of_value` = getMemoryAccess(I or BB). Walker: `mssa_get_clobbering_access(m, a, q)`,
  `..._for_loc`, `..._skip_self`, `mssa_ensure_optimized_uses`, `mssa_dominates`, `mssa_verify` (verifyMemorySSA: LLVM's release build checks nothing; ours
  fails loudly on a broken invariant). Operands are `Mssa_Use` rows with push-front use lists (`ma_defining`, `ma_op`,
  `mphi_value/_block/_add_incoming`, `ma_rauw`, `ma_users`); a MemoryPhi's operand list grows like a hung-off list
  (`mphi_grow`), so use-list order (which decides RAUW and phi-simplification order in the updater) matches LLVM.
  Mutation API: `mssa_create_defined_access`, `mssa_create_phi`, `mssa_insert_into_lists_for_block / _before`,
  `mssa_move_to_before / _place`, `mssa_remove_from_lookups / _lists`, `mssa_rename_pass_from_block`.
- **MemorySSAUpdater** = `Mssa_Updater{mssa}` on the stack (`mssau_*`, LLVM's method names). LLVM's TrackingVH / WeakVH
  on accesses are rows of `mssa.vh` (`vh_new/vh_get`, followed by `ma_rauw`, nulled when an access is destroyed);
  every public `mssau_*` brackets itself with `mssau_enter/leave` and the handles are released when the outermost call
  returns. Deleted accesses keep their row (`dead`).
- **EarliestEscapeAnalysis**: `aa_query_new_earliest_escape(aar, dt)` (+ `q.ee_ci` for the CycleInfo form DSE uses);
  `aa_query_new_sharing_ee(aar, ee)` = another BatchAAResults on the same EEA (MemCpyOpt).
- Printers with annotations use the `print_annot_block` / `print_annot_inst` hooks of printer.jai (LLVM's
  AssemblyAnnotationWriter) around `print_function`.

## 10. How to add a pass

1. Read the LLVM source (`/opt/llvm-project-23.1.5/llvm/lib/Transforms/...`) and note which analyses it gets with
   `getResult` vs `getCachedResult`, what it preserves, and which utilities it calls.
2. Create `src/pass_<name>.jai` with a header comment naming the LLVM file(s), and a
   `<name>_run :: (f: Value_Id) -> Preserved` (function pass). Return `PRESERVE_ALL` when nothing changed, otherwise
   exactly what LLVM's `run` preserves (`preserved_cfg()`, `preserve(*pa, .DOMTREE)`, ...).
3. Register it: a `Pass_Kind` value, a `PASS_TABLE` row with its PassRegistry.def name, and a `case` in
   `run_function_pass`. Pass parameters (`name<...>`): match the prefix in `lookup_pass`/`parse_function_pass` and
   parse the parameters into the `Pass_Node` (add a field) — not needed yet by any ported pass.
4. `#load` the file in `opt.jai`.
5. New analysis: add an `Analysis_Kind`, a field in `Fn_Analyses`, `get_x`/`cached_x`, its invalidation rule in
   `analysis_survives`/`fam_invalidate`, `require<x>`/`invalidate<x>`/`print<x>` rows.
6. New `cl::opt`: a field in `opts` and an entry in `cl_opts()` (default = LLVM's default).
7. Anything LLVM does that you don't port must `fatal(...)` when reached, never silently do something else.

### Target cost model (tti*.jai, x86_lowering.jai, gen_x86_*.jai)

- `Tti :: struct { kind: Tti_Kind; xl: X86_Lowering; }`: `.NONE` is NoTTIImpl (no target machine: module without
  an x86 triple), `.X86` is X86TTIImpl + BasicTTIImplBase. There is no virtual dispatch: `tti_*` entry points switch
  on `kind`, and inside the X86 code "thisT()->" calls are direct calls to the `x86_*` procedures (`bt_*` are the
  BasicTTIImplBase bodies, `base_*` TargetTransformInfoImplBase's).
- `tti_get(f)` caches one `X86_Lowering` per distinct (cpu, tune-cpu, features, prefer/min vector width,
  soft-float) tuple: the X86Subtarget (feature bits with implications), TargetLoweringBase tables
  (`op_actions`, `type_action`, `transform_to`, `num_registers`, load-ext/trunc-store actions) computed once by
  `x86_lowering_init` from the generated constructor actions.
- Types are mapped with `x86_value_type` to `Evt` (simple `MVT` code or an extended (elt, n, scalable) triple);
  `bt_type_legalization_cost` walks `xl_type_conversion` exactly like getTypeLegalizationCost.
- Cost tables are `[] XCost_Entry { isd, dst, src, c: [4] s32 }` (one column per cost kind, -1 = no cost for
  that kind; CostTblEntry tables keep their single cost in `c[0]`), looked up first-match like CostTableLookup.
- Demanded-element sets are `[] bool`; shuffle masks `[] s32` with -1 for poison.

### Loops (loop_info.jai, cycle_info.jai, bb_utils.jai, pass_loop_simplify.jai, pass_lcssa.jai, loop_pm.jai, pass_loop_rotate.jai)

- **LoopInfo** = `*Loop_Info` (heap, `Fn_Analyses.li`, `get_loop_info(f)` / `cached_loop_info(f)`; survives
  `preserve(.LOOPS)` or `preserved_cfg()`). A loop is a `Loop_Id` row of `li.loops`: `parent`, `blocks`
  (Blocks: `[0]` is the header), `subloops`, `dead`. `top_level` is TopLevelLoops (reverse program order),
  `loop_of` the BBMap (innermost loop), `member` every loop's DenseBlockSet as one table keyed `(loop << 32) |
  block`. Ids are never reused, so a destroyed loop (`li_erase`) keeps its row with `dead = true`.
  Queries mirror LoopBase: `li_header`, `li_loop_for`, `li_contains` (block), `li_contains_loop`, `li_depth`,
  `li_loop_preheader`, `li_loop_predecessor`, `li_loop_latch`, `li_loop_latches`, `li_exiting_blocks`,
  `li_exit_blocks`, `li_unique_exit_blocks`, `li_exit_block`, `li_unique_exit_block`, `li_is_loop_exiting`,
  `li_is_loop_latch`, `li_has_dedicated_exits`, `li_is_loop_simplify_form`, `li_is_lcssa_form`,
  `li_loops_in_preorder`, `li_loop_id`, `li_is_annotated_parallel`, `li_is_loop_invariant` (pass_loop_simplify).
  Updates mirror LoopBase/LoopInfoBase: `li_add_basic_block_to_loop`, `li_add_block_entry`, `li_change_loop_for`,
  `li_remove_block_from_loop`, `li_remove_block`, `li_move_to_header`, `li_add_child_loop`,
  `li_remove_child_loop`, `li_replace_child_loop_with`, `li_add_top_level_loop`, `li_change_top_level_loop`,
  `li_alloc_loop`, `li_erase` (LoopInfo::erase with UnloopUpdater), `li_set_loop_id`.
- **CycleInfo** = `*Cycle_Info` (`get_cycle_info(f)`): `Cycle_Row{parent, top, depth, entries, blocks, children}`.
- **CFG surgery that keeps analyses up to date** (bb_utils.jai, pass_loop_rotate.jai, pass_dce.jai):
  `split_block_predecessors(bb, preds, suffix, dt, li, mssau, preserve_lcssa)`,
  `split_landing_pad_predecessors`, `split_block`, `split_critical_edge` with `Crit_Edge_Options.li /
  preserve_lcssa / preserve_loop_simplify`, `merge_block_into_predecessor(bb, dt, li, mssau, two_succs)` (eager
  DomTreeUpdater semantics), `change_to_unreachable`, `fold_single_entry_phi_nodes`, `erase_block`,
  `dt_split_block` (DominatorTree::splitBlock). Pass the trees LLVM's caller has; never recompute them.
- **Loop passes**: a `Pass_Kind` with `level = .LOOP` in `PASS_TABLE` and a `case` in `run_loop_pass`; signature
  `(node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved`. `Loop_Std_Results` has the
  function, AC, DT, LoopInfo, ScalarEvolution (`lar.se`, always computed by the adaptor, like LLVM) and MemorySSA
  (null unless `loop-mssa`); there is no AA object, TLI or TTI in it. While a loop pass runs, `scev_pass_se` is its
  SE (see "ScalarEvolution" below for keeping it valid). Return `PRESERVE_ALL` when nothing changed, else `loop_pass_preserved()` (+ `.MEMORYSSA` when
  `lar.mssa`). Tell the worklist about structural changes with `lpm_mark_loop_as_deleted`,
  `lpm_add_child_loops`, `lpm_add_sibling_loops`, `lpm_revisit_current_loop`. Pass parameters
  (`loop-rotate<...>`) are parsed by the pass from `node.name` (see `lookup_pass`).
- **Debug records when moving instructions**: `inst_move_before` keeps an instruction's records with it
  (moveBeforePreserving); `inst_move_before_dbg` is LLVM's `moveBefore` (records stay, the destination's records
  are absorbed); `insert_at_position(i, bb, pt, head)` is `insertBefore(It)`. `records_take/prepend/append`
  manipulate the per-instruction lists; erasing a terminator with records needs `records_take` first (there is no
  "trailing records" state in this implementation).

### LoopVectorize and VPlan (iv_descriptors.jai, lv_*.jai, vplan*.jai)

LLVM's VPlan is a class hierarchy (VPBlockBase -> VPBasicBlock / VPIRBasicBlock / VPRegionBlock; VPValue ->
VPIRValue / VPSymbolicValue / VPRegionValue / VPSingleDefValue / VPMultiDefValue; VPRecipeBase with ~35 recipe
classes and mixins VPIRFlags, VPIRMetadata, VPPhiAccessors, VPWidenMemoryRecipe). The port keeps one plan's entities
in flat tables of one `Vp_Plan` struct; every entity is a u32 row index:

- **Blocks** `Vp_Blk` -> `Vp_Block_Row {kind: .BASIC/.IR_BASIC/.REGION, name, parent region, preds, succs (in
  LLVM's order: setTwoSuccessors, swapSuccessors, ... are list edits), first/last recipe (intrusive list through the
  recipe rows, = iplist<VPRecipeBase>), irbb, entry/exiting (regions), can_iv / header_mask region values and the
  canonical-IV NUW bit (VPCanonicalIVInfo; a region without can_iv is a replicate region)}`.
- **Values** `Vp_Val` -> `Vp_Value_Row {kind: .IR/.SYMBOLIC/.REGION/.SINGLE_DEF/.MULTI_DEF, underlying IR Value_Id,
  scalar type (VPRecipeValue::Ty, VPSymbolicValue::Ty), users: [..] Vp_Rec (a SmallVector in LLVM: push_back on
  addOperand, erase of the first match on removeUser, so the order is reproduced exactly), defining recipe,
  materialized flag, region}`. A recipe that defines one value has `def`; interleave groups have `defs`.
- **Recipes** `Vp_Rec` -> `Vp_Recipe_Row {kind: Vp_Kind (VPRecipeTy in LLVM's enum order, so the
  VPFirstPHISC..VPLastPHISC range tests work), parent block, prev/next, ops: [..] Vp_Val, debug loc, opcode (IR
  `Opcode` values or VPI_* VPInstruction opcodes), flags: Vp_Flags (VPIRFlags: operation type + the union's bits),
  md: [..] (kind, node) pairs (VPIRMetadata), name, and the union of all per-kind payload fields (intrinsic id,
  source element type, stride, induction descriptor index, reduction kind/style, memory ingredient, alignment,
  consecutive/masked bits, SCEV expression, interleave group, ...), each commented with the kinds that use it}`.
  `VPInstructionWithType` and `VPPhi` are VPInstruction rows (classified by opcode, exactly like their classof);
  `VPIRPhi` is an IR_INSTRUCTION row whose instruction is a phi.
- **Virtual calls are switches** on `Vp_Kind`: `vp_execute_recipe(s, r)` (vplan_execute.jai), `vp_clone(r)`,
  `vp_uses_first_lane_only(r, op)`, `vp_may_read_from_memory(r)`, ... (vplan_props.jai), one `case` per recipe class,
  so the behaviour of a recipe kind can be read in one place; VPInstruction::generate is `vpi_generate`, a switch on the
  opcode; VPRecipeBase::computeCost is `vp_compute_cost` (vplan_cost.jai), VPRecipeBase::cost (the skip set and
  -force-target-instruction-cost) is `vp_recipe_cost`.
- **Costs** (LoopVectorizationCostModel and VPCostContext) are computed in LLVM 23's fixed-point InstructionCost domain:
  `Lc` = 4 * the cost (lv_cost.jai), so divisions by block-frequency divisors keep their fractions. TTI answers stay
  plain integers and are converted at the call (`lt_*` wrappers). `Vp_Cost_Ctx` is VPCostContext (the skip set is an
  Iset; NumPredStores is -1 until computed).
- **Interleave groups** are referred to by index into the loop's `Iai` (`vr(r).ig`); the `Iai` of the loop being
  vectorized is the global `lv_cur_iai`, like `vpl` for the plan.
- **Plans are values**: `VPlan::duplicate()` copies the tables (ids stay meaningful in the copy) and then rebuilds
  every user list in the order LLVM's remapOperands produces (deep RPO over the blocks, recipes in order, operands
  in order), so transforms that walk users see LLVM's order. The global `vpl: *Vp_Plan` is the plan being worked
  on (like `se` for ScalarEvolution); `vp_use(plan)` switches it.
- **VPTransformState** (`Vp_State`) maps a Vp_Val to its IR vector value and per-lane scalars (Tables keyed by the
  value id; lane vectors), plus the CFG state (VPBB2IRBB, a Lazy `Dtu`, the current parent loop); recipes emit IR
  through an `Irb` (ConstantFolder semantics) and `s.fmf` stands for the IRBuilder's FastMathFlags (applied to FP
  operations the helpers `vs_binop` / `vs_unop` / `vs_cmp` create).
- **InterleavedAccessInfo** (`Iai`, lv_interleave.jai): groups are rows of a table (`Ig`, members as parallel
  key/value arrays = the DenseMap), released groups stay as dead rows; InterleaveGroups is the ordered list of live
  ids.
- **VPExpressionRecipe** (vplan_expression.jai): member recipes stay rows of the plan, unlinked from any block, in
  `expr_recipes` (duplicates allowed); its LiveInPlaceholders are symbolic values in `expr_placeholders`, one per
  operand. `vp_duplicate` re-adds the members' users (they only use each other and the placeholders).
- **Lanes** (VPLane) are u64: a plain lane index, or `LANE_SCALABLE_LAST | k` for lane k of the last vscale chunk
  (the cache index is VF.min + k, the runtime index `vscale * VF.min - (VF.min - k)`).
- Everything not ported yet fails loudly (`vp_unported("...")`) at the point where LLVM would act.

### Cloning: ValueMapper, CloneBasicBlock, LoopUnroll (value_mapper.jai, clone_function.jai, loop_unroll*.jai, loop_peel.jai)

- **ValueToValueMapTy** = `Value_Map` (temp): `map` (Value_Id -> Value_Id) and `md` (Md_Id -> Md_Id, ValueMap::MD()).
  `vmap_set/get/lookup/find/erase`. LLVM's map values are WeakTrackingVHs; the unroll and peel code never RAUWs or
  erases a mapped value while a map is live, so for them it is a plain table. The inliner's VMap (and its
  OperandBundleCallSites map) is a *tracking* map: `vmap_track_begin(*vm)` / `vmap_track_end` register it in a global
  list; `replace_all_uses_with` / `value_is_rauwd` call `vmap_note_rauw` and `erase_inst` calls `vmap_note_erase`
  (through `vm.rev`, value -> keys), so values follow RAUW and become NONE when erased (`map_value` treats NONE as
  missing, like a null WeakTrackingVH).
- **Mapper** = `map_value(*vm, v, flags)`, `remap_instruction(*vm, i, flags)`, `remap_dbg_record(_range)`,
  `map_metadata` with LLVM's RF_* flags. Faithful for RF_NoModuleLevelChanges (+ IgnoreMissingLocals,
  NullMapMissingGlobalValues): globals / inline asm map to themselves and are memoized in the map, constants are
  rebuilt only when an operand maps elsewhere (blockaddress of a cloned block), LocalAsMetadata / DIArgList operands
  of calls are mapped, every mapped operand is re-`set` (Use::set moves the use to the front even when the value is
  unchanged: use-list order). Not ported (fatal): the MDNodeMapper (module-level changes: distinct-node cloning,
  uniqued-graph POT), TypeMapper/Materializer, global initializer and alias remapping, atom groups.
- **CloneBasicBlock** = `clone_basic_block(bb, *vm, suffix, f)`. With `f = NONE` the block has no parent: names are
  stored raw and uniqued when `fn_insert_detached_block_before/_after` links it (instructions first, then the block,
  as SymbolTableListTraits does). Debug records are cloned (`cloneDebugInfoFrom`).
- UnrollLoop / peelLoop / the runtime remainder keep DominatorTree and LoopInfo updated exactly like LLVM (addNewBlock
  per clone, changeImmediateDominator, the lazy DTU of the exit folding, MergeBlockIntoPredecessor with a direct DT
  via `merge_block_into_predecessor(..., direct_dt = dt)`). The SE is the global `se` (= `scev_pass_se` while the
  pass runs, so LoopSimplify/LCSSA called from the unroller update it).

### ScalarEvolution (scev*.jai, loop_nest.jai, iv_users.jai)

- **Nodes**: a SCEV is a `Scev_Id`, a row of `se.nodes` (`Scev_Row{kind, flags, size, nops, ops, type, val, loop}`;
  id 0 = SCEVCouldNotCompute, `SCEV_NULL` = nullptr where LLVM distinguishes it). Operands are runs in `se.ops`:
  read them with `sc_op(s, i)` (the pool grows while folding, so never keep a slice across a constructor call) or
  copy them with `sc_operands(s)`. Uniquing is LLVM's FoldingSet: `sc_find(kind, ops, type, val, loop)` /
  `sc_insert` hash into `se.unique` with buckets chained through `hnext`; flags live on the node and only grow
  (`sc_set_no_wrap_flags` = ScalarEvolution::setNoWrapFlags, `sc_row(s).flags |=` = SCEVNAryExpr::setNoWrapFlags).
  LLVM 23's SCEVUse can carry use flags, but 23.1.5 never creates one, so operands are plain ids.
  `sc_get_constant` of a <= 64-bit value first looks in `se.const_cache` (direct-mapped (width, value) -> id; SCEV
  constants are never removed from the uniquing table).
- **State**: one `*Scev_State` per function (`Fn_Analyses.se`, `get_scev(f)` = AM.getResult, `cached_scev(f)`);
  every `sc_*` procedure works on the global `se`, which `get_scev` (and the loop PM / AA entry points) set. All of
  LLVM's caches are tables of the state with the same keys (ValueExprMap / ExprValueMap, ranges, constant
  multiples, dispositions, ValuesAtScopes(+Users), BackedgeTakenCounts / Predicated..., BECountUsers, FoldCache(+User),
  SCEVUsers, LoopUsers, ...), so `sc_forget_memoized_results` reproduces exactly what LLVM forgets (that changes
  output: e.g. forgetting the symbolic PHI in createAddRecFromPHI, or LoopUsers after a trip count is computed).
- **Operand lists** are `[..] Scev_Id` in `temp`; constructors that take `SmallVectorImpl &Ops` take `*[..]` and may
  rewrite it (`sc_get_add(*ops, flags, depth)`); `sc_get_add2/3`, `sc_get_mul2/3`, `sc_list(...)` for small lists.
- **API map** (LLVM name -> Jai): getSCEV `sc_get_scev`, getExistingSCEV `sc_get_existing`, getAddExpr `sc_get_add`,
  getMulExpr `sc_get_mul`, getUDivExpr `sc_get_udiv`, getURemExpr `sc_get_urem`, getMinusSCEV `sc_get_minus`,
  getNegativeSCEV `sc_get_negative`, getNotSCEV `sc_get_not`, get{Truncate,ZeroExtend,SignExtend,AnyExtend}Expr
  `sc_get_truncate` / `_zero_extend` / `_sign_extend` / `_any_extend` (and the `_or_` variants), getAddRecExpr
  `sc_get_add_rec(start, step, l, flags)` / `sc_get_add_rec_ops`, getMinMaxExpr `sc_get_min_max`, get{S,U}{Max,Min}Expr
  `sc_get_smax2` ..., getUMinExpr(Seq) `sc_get_umin`, getGEPExpr `sc_get_gep`, getPtrToIntExpr `sc_get_ptr_to_int`,
  ranges `sc_unsigned_range` / `sc_signed_range` (+ `_min` / `_max`), isKnown* `sc_is_known_*`,
  isKnownPredicate(At) `sc_is_known_predicate(_at)`, isLoopEntryGuardedByCond / isLoopBackedgeGuardedByCond
  `sc_is_loop_*_guarded_by_cond`, getBackedgeTakenCount `sc_get_backedge_taken_count` (constant / symbolic max,
  predicated variants, `sc_get_exit_count(l, bb, kind)`), getSCEVAtScope `sc_get_scev_at_scope`, isLoopInvariant
  `sc_is_loop_invariant`, getLoopDisposition, properlyDominates `sc_properly_dominates`, applyLoopGuards
  `sc_apply_loop_guards` / `sc_loop_guards_collect` + `sc_apply_loop_guards_with`, getSmallConstantTripCount /
  TripMultiple, getConstantMultiple / getMinTrailingZeros, evaluateAtIteration, SCEVRewriteVisitor `Sc_Rewriter`,
  SCEVTraversal / SCEVExprContains `sc_visit_all` / `sc_expr_contains` (see the next item). Predicates (SCEVComparePredicate / SCEVWrapPredicate) are u32 rows of
  `se.preds`.
- **Visitors without vtables**: `Sc_Rewriter` (scev_create.jai) has `kind: Sc_Rewriter_Kind`, one value per
  SCEVRewriteVisitor subclass we emulate (INIT, POST_INC, SHIFT, BACKEDGE_FOLD, LOOP_GUARDS, PREDICATE, NORMALIZE),
  plus the union of their state fields (each commented with the kinds that use it) and the memo table.
  `sc_rewrite_dispatch` is the virtual `visit` call: a `#complete` switch on the kind calls that kind's
  `sc_rw_<kind>_visit(rw, s) -> (handled, result)` (defined next to the rewrite entry point, e.g.
  `sc_rw_loop_guards_visit` in scev_guards.jai, `sc_rw_normalize_visit` in iv_users.jai); unhandled nodes get
  `sc_rewrite_default` (the base class visit*). `Sc_Visitor` (scev.jai) does the same for SCEVTraversal:
  `kind: Sc_Visitor_Kind` (CONTAINS_ADDREC / CONTAINS_UB_UDIV / CONTAINS_OPERAND for the SCEVExprContains
  predicates, MIN_MAX_CONTAINS, CONST_IN_ADD_MUL_CHAIN, POISON_COLLECTOR, USED_LOOPS, INVALIDATION_ROOTS), with
  `sc_visitor_follow` / `sc_visitor_is_done` as the two `#complete` switches. A new rewriter or traversal = a new
  enum value, its fields, and a case in the switch; `sc_expr_contains(root, .CONTAINS_X, operand)` takes the
  predicate as a kind, not a lambda.
- **Keeping a cached SE valid** (scev_update.jai): `erase_inst` and `replace_all_uses_with` call `scev_note_erase` /
  `scev_note_rauw` (LLVM's SCEVCallbackVH and SCEVUnknown value handles). Passes call the same forget* LLVM calls
  through `pse_forget_value / _loop / _topmost_loop / _block_and_loop_dispositions`, which act on `scev_pass_se`
  (null when LLVM's pass has no SE: LoopSimplifyPass and LCSSAPass use getCachedResult). A pass that changes IR in a
  function with a cached SE must make every forget call its LLVM counterpart makes.
- **SCEVExpander** (scev_expander.jai): a `Scev_Expander` struct on the caller's stack holds SCEVExpander's state
  (temp tables; InsertedExpressions' TrackingVHs are value_handles.jai slots); its IRBuilder is an `Irb` used through
  `sx_create_*` (InstSimplifyFolder: fold with InstSimplify, else insert and rememberInstruction). SCEVInsertPointGuard
  is `g := sx_guard_push(x); defer sx_guard_pop(x, g);` (the guard stack lets fixupInsertPoints move saved points).
  The visitor is the `if sc_kind(s) ==` switch in `sx_visit`. Iterators with LLVM's head bit are `Sx_It`.
- Printers: print<scalar-evolution> (scev_print.jai), print<loopnest> (loop_nest.jai, a loop pass),
  print<iv-users> (iv_users.jai, a loop pass), `-aa-pipeline=scev-aa` (scev_aa.jai).

### CGSCC: LazyCallGraph and the CGSCC pass manager (lazy_call_graph.jai, cgscc_pm.jai)

- **LazyCallGraph** = the global `lcg: *Lazy_Call_Graph` (null when not cached; `lcg_get()` = AM.getResult):
  nodes, SCCs and RefSCCs are s32 row ids (`Lcg_Node`, `Lcg_Scc`, `Lcg_Ref_Scc`; ids are never reused, a dead row is
  flagged). An `Lcg_Edges` (EdgeSequence) is `[..] Lcg_Edge{node, call}` plus the EdgeIndexMap table, so insertion /
  erasure order matches LLVM; SCCMap is `scc_of` by node id. `buildRefSCCs` /
  `buildSCCs` are the iterative Tarjan walks of LazyCallGraph.cpp; the incremental updates (switchInternalEdgeToCall
  / ToRef, switchOutgoingEdgeToCall/ToRef, insertIncomingRefEdge, removeOutgoingEdge, removeInternalRefEdges,
  addSplitFunction, addSplitRefRecursiveFunctions, removeDeadFunctions) keep the post-order lists in the same order.
  `print-lcg` is `lcg_printer_run`. Library functions (`isKnownLibFunction`) are part of the graph like in LLVM.
- **CGSCC PM** (cgscc_pm.jai): `run_cgscc_adaptor` = ModuleToPostOrderCGSCCPassAdaptor with its RefSCC/SCC
  worklists as `Prio_Worklist`s and a `Cgscc_Ur` (CGSCCUpdateResult: InvalidatedSCCs/RefSCCs, UpdatedC,
  CWorklist/RCWorklist, IndirectVHs, CrossSCCPA, InlinedInternalEdges, DeadFunctions). `run_cgscc_pm`, `run_devirt`
  (DevirtSCCRepeatedPass: the IndirectVHs call counts) and `run_cgscc_fn_adaptor` (CGSCCToFunctionPassAdaptor +
  `update_cg_and_am_for_pass` = updateCGAndAnalysisManagerForFunctionPass / ForCGSCCPass). IndirectVHs are WeakVHs:
  `cg_vh_note_rauw` / `cg_vh_note_erase` hooks in ir.jai. Function analyses are invalidated per function through the
  same `fam_invalidate`; the CGSCC analysis results we need (none are cached across SCCs) are not modelled.
- Module-level CGSCC passes: function-attrs (pass_function_attrs.jai), inline / always-inline / module-inline /
  inliner-wrapper (pass_inliner.jai); InlineCost (inline_cost.jai, InlineCostCallAnalyzer only, its virtual hooks are
  plain calls), InlineFunction + CloneAndPruneFunctionInto (inline_function.jai), ProfileSummaryInfo (psi.jai: the
  module's one result; `psi_cached_or_null()` = getCachedResult, `psi_require()` = getResult).

## 11. InstCombine (instcombine.jai and ic_*.jai)

Port of `llvm/lib/Transforms/InstCombine/`. `instcombine.jai` `#load`s the files; add new `ic_*.jai` files there
(not in opt.jai).

| File | LLVM source |
| --- | --- |
| `ic_core.jai` | InstructionCombining.cpp driver (`prepareWorklist`, `run`, sinking, `combineInstructionsOverFunction`, `InstCombinePass::run` + `instcombine<...>` params), InstructionWorklist.h, the InstCombiner.h helpers (`replaceInstUsesWith`, `eraseInstFromFunction`, `replaceOperand`, `InsertNewInstBefore/With`, `getComplexity`, `AddOne/SubOne`), IRBuilder<TargetFolder, IRBuilderInstCombineInserter> (`icb_*`), the unlinked `BinaryOperator::Create*` family (`create_*`) |
| `ic_binop.jai` | InstructionCombining.cpp folds shared by binops: `SimplifyAssociativeOrCommutative`, distributive laws, `FoldOpIntoSelect`, `foldOpIntoPhi`, `foldBinopWithPhiOperands`, `foldVectorBinop`, `narrowMathIfNoOverflow`, `getFreelyInvertedImpl`, `dyn_castNegVal`, ... and the `willNotOverflow*` / `computeKnownBits` wrappers of InstCombineInternal.h |
| `ic_pattern.jai` | PatternMatch matchers not in pattern.jai (instruction-only casts `pmi_cast`, `pm_ob` = OverflowingBinaryOp_match, `pm_disjoint_or`, ...) |
| `ic_addsub.jai`, `ic_fp_addsub.jai`, `ic_negator.jai` | InstCombineAddSub.cpp (incl. FAddCombine), InstCombineNegator.cpp |
| `ic_muldivrem.jai`, `ic_fp_muldivrem.jai` | InstCombineMulDivRem.cpp |
| `ic_demanded.jai` | InstCombineSimplifyDemanded.cpp, integer half (`SimplifyDemandedUseBits`, `SimplifyMultipleUseDemandedBits`, ...) |
| `ic_demanded_fp.jai` | InstCombineSimplifyDemanded.cpp, FP half, complete (`ic_simplify_demanded_fp_class`, `..._use_fp_class`, `..._multiple_use_demanded_fp_class`, `..._instruction_fp_class`) |
| `ic_atomicrmw.jai` | InstCombineAtomicRMW.cpp, complete |
| `ic_compares.jai` | InstCombineCompares.cpp: `visitICmpInst`, `visitFCmpInst` and all their helpers; at its end the helpers it borrows from other files under their LLVM names (`simplifyIntToPtrRoundTripCast`, `canBeCastedExactlyIntToFP`): move them when their file is ported |
| `ic_shifts.jai` | InstCombineShifts.cpp: `visitShl/LShr/AShr`, `commonShiftTransforms`, `FoldShiftByConstant`, `setShiftFlags`, `canEvaluateShifted`/`getShiftedValue`, `reassociateShiftAmtsOfTwoSameDirectionShifts`; `Constant::replaceUndefsWith`/`mergeUndefsWith` (`ic_replace_undefs_with`, `ic_merge_undefs_with`) |
| `ic_andorxor.jai` | InstCombineAndOrXor.cpp: `visitAnd/Or/Xor`, `foldAndOrOfICmps`, `foldLogOpOfMaskedICmps`, `foldLogicOfFCmps`, `foldNot`, `foldBooleanAndOr`, `FoldOrOfLogicalAnds`, `sinkNotInto*`, `convertOrOfShiftsToFunnelShift`, `insertRangeTest`, ...; CmpInstAnalysis.cpp's `getICmpCode`/`getPredForICmpCode`/`predicatesFoldable`; Local.cpp's `recognizeBSwapOrBitReverseIdiom`; matchers `pm_max_min` (MaxMin_match incl. the select form), `pm_c_binop_not_val`/`pm_c_binop_val_not` (commuted not-matchers with LLVM's try order) |
| `ic_select.jai` | InstCombineSelect.cpp: `visitSelectInst` and all its helpers, in LLVM's order (SimplifyDemandedVectorElts is in `ic_demanded.jai`) |
| `ic_casts.jai` | InstCombineCasts.cpp, complete: `commonCastTransforms`, `EvaluateInDifferentType`, TypeEvaluationHelper (`ic_can_evaluate_truncated/zextd/sextd`), every `visit<Cast>` and helper, `canBeCastedExactlyIntToFP`, `foldItoFPtoI` (also used for the fpto[su]i.sat intrinsics) |
| `ic_calls.jai` | InstCombineCalls.cpp: `visitCallInst` (mem intrinsics, the generic intrinsic switch, select/phi/shuffle/reverse operand folds), `visitCallBase`, `visitFenceInst`, `visitInvoke/CallBr`, `visitVAEndInst`, and their helpers; the target hook `ic_target_inst_combine_intrinsic` (TTI by module triple); `ic_aa()` (the pass's AAResults) |
| `ic_x86.jai` | X86InstCombineIntrinsic.cpp, complete: `ic_x86_inst_combine_intrinsic`, `ic_x86_simplify_demanded_use_bits_intrinsic`, `ic_x86_simplify_demanded_vector_elts_intrinsic` (called from ic_demanded.jai when the triple is x86); intrinsics are dispatched by name through `x86_kind` |
| `ic_loadstorealloca.jai` | InstCombineLoadStoreAlloca.cpp, complete: `visitAllocaInst` (+ PointerReplacer, isOnlyCopiedFromConstantMemory), `visitLoadInst`, `visitStoreInst`, `mergeStoreIntoSuccessor` and their helpers; the IRBuilder methods for memory (`icb_gep`/`create_gep`, `icb_ptr_add`, `icb_load_props`, `icb_aligned_load/store`, `icb_alloca`, `icb_insert_value`, `icb_mem_transfer`), `ic_create_non_terminator_unreachable`, Local.cpp's `get_or_enforce_known_alignment` |
| `ic_combining.jai` | InstructionCombining.cpp visitors that are not driver or binop code: `visitGetElementPtrInst` (+ visitGEPOfGEP, foldGEPOfPhi, ...), `visitAllocSite`/`isAllocSiteRemovable`, `visitFree`, `visitSwitchInst`, `visitExtractValueInst` (+ foldExtractOfOverflowIntrinsic), `visitLandingPadInst`, `visitFreeze` (+ freezeOtherUses, foldFreezeIntoRecurrence) |
| `ic_vectorops.jai` | InstCombineVectorOps.cpp, complete: `visitExtractElementInst`, `visitInsertElementInst`, `visitInsertValueInst` (+ foldAggregateConstructionIntoAggregateReuse), `visitShuffleVectorInst` and every helper, `foldExtractionOfVectorDeinterleave`; shuffle masks are copied into `[..] s32` (`shuf_mask`, -1 = poison) because `shuffle_mask()` is a view into `ir.u32_pool` |
| `ic_misc.jai` | `ic_visit` (the opcode switch = InstVisitor) and the terminators |
| `simplify_lib_calls*.jai` | SimplifyLibCalls.cpp, reached through `ic_try_optimize_call` (ic_calls.jai). One `lcs: Lcs_State` per simplified call (the TLI of the function, UnsafeFPShrink); builds with `icb_*`; Replacer/Eraser are `ic_replace_inst_uses_with` / `ic_erase_inst`; `ic.default_bundles_src` gives new calls the call's operand bundles |

**State.** One global `ic: Ic_State` (= one `InstCombinerImpl`), reset per iteration like LLVM's per-iteration
object: worklist, DomConditionCache (`ic.dc`, also reachable through `ic.sq.dc` so every ValueTracking query made
with `ic_q(i)` = `SQ.getWithInstruction(I)` sees the registered branches), dead edges, back edges, the Builder
(`ic.b` insertion point + `ic.b_fmf` default fast-math flags).

**Visitor contract** (exactly LLVM's `Instruction *visitX`): return `NONE` = no change; the instruction itself =
changed in place, or its uses were replaced (`ic_replace_inst_uses_with` returns it); any other value = a new
**unlinked** instruction that replaces it. The driver (`ic_run_worklist`) inserts the new instruction at the old
one's position, copies the debug location, RAUWs, moves the name (`ic_take_name`, LLVM's `takeName` semantics:
the target loses its own name even when the source has none) and erases the old one.

**Creating instructions.** Use `icb_*` for `Builder.CreateX(...)`: it constant-folds like TargetFolder, inserts at
`ic.b`, names after insertion (so uniquing sees the function's symbol table, as IRBuilder does) and adds the
instruction to the worklist (deferred). Use `create_*` (`create_binop`, `create_binop_flags`, `create_cast`,
`create_icmp`, `create_select`, `create_fop`, ...) for `BinaryOperator::Create(...)` & co. that a visitor returns
or inserts with `ic_insert_new_inst_before/with`. A name given to an unlinked instruction is only stored; the
symbol table sees it when the instruction is linked (`ic_reinsert_name`, ValueSymbolTable::reinsertValue).
`ic_create_select_unknown_profile` = `createSelectInstWithUnknownProfile`. Save/restore the builder around
`IRBuilderBase::InsertPointGuard` regions with `saved := ic.b; defer ic.b = saved;`.

**Matching.** LLVM's `match(V, m_X(...))` becomes a `pm_*`/`pmi_*` call returning `(ok, captures...)`; commuted
matchers (`m_c_*`) are explicit `for side: 0..1` loops in LLVM's operand order (first the written order, then the
swapped one). Keep LLVM's instruction-vs-operator distinction (pattern.jai header). `m_OneUse` is `has_one_use`.
`m_Deferred` is an equality test on an earlier capture.

**How to add a fold** (for the bitwise/cmp/select/cast/memory sub-units):
1. Find the LLVM visitor (`grep -n "visitX" InstCombine*.cpp`). If `ic_misc.jai` has a partial visitor for it,
   move it into a new `ic_<file>.jai` named after the LLVM file and add the file to `instcombine.jai`.
2. Port the visitor top to bottom *in LLVM's order* — the first fold that fires wins, so order is behaviour. Each
   helper keeps its LLVM name in snake case with the `ic_` prefix (`foldICmpWithConstant` -> `ic_fold_icmp_with_constant`).
3. Every query uses the same SimplifyQuery as LLVM: `ic_q(i)` for `SQ.getWithInstruction(&I)`, `ic.sq` for plain
   `SQ`, `ic_q_no_dc` / `num_sign_bits_ctx` where LLVM calls the `DL, AC, CxtI, DT` overloads (no DomConditionCache).
4. Something you can't port yet: `fatal("instcombine: <what> is not supported yet")` at the point where LLVM would
   act, guarded by the pattern's own preconditions so unrelated code is unaffected.
5. Check `./harness/run check --impl jai --unit L1.instcombine.<x>`, then the whole InstCombine directory
   (`'tests/imported/llvm/Transforms/InstCombine/*'`): a new fold can expose fixpoint differences elsewhere
   (`did not reach a fixpoint` = our iteration 2 changed something LLVM's iteration 1 already did).

### LazyValueInfo, CVP, JumpThreading, BPI/BFI

- **LazyValueInfo** = `*Lvi` (heap, `Fn_Analyses.lvi`, `get_lvi(f)`; survives only when preserved). The cache is a
  `Table(block, *Lvi_Block_Entry)` (lattice values, overdefined set, non-null pointers) instead of LLVM's
  block-number-indexed vector (block ids are never reused, so it is equivalent). LVIValueHandle = the global
  `lvi_value_handles` (value -> owning Lvi); `erase_inst` / `replace_all_uses_with` call `lvi_note_erase` /
  `lvi_note_rauw`. `has_impl` models the lazily created PImpl (the printer prints nothing without it). Lattice values
  (`Vle`) stored in the cache are heap copies (`vle_heap_copy`); everything else is temp.
- **DomTreeUpdater**: `Dtu` (scfg_util.jai) has a Lazy mode (`lazy`, `pending`, `deleted` + `deleted_set`):
  `dtu_apply` / `dtu_apply_permissive` queue, `dtu_flush` / `dtu_get_dom_tree` apply one batch and then erase the
  pending blocks, `dtu_delete_bb` defers, `dtu_recalculate` recalculates. Eager callers are unchanged.
- **BranchProbabilityInfo** = `*Bpi` (probabilities per source block, `get_bpi(f)`), **BlockFrequencyInfo** =
  `*Bfi` (integer and scaled frequencies per block, `get_bfi(f)`); both survive `preserved_cfg()`. The BFI
  construction state (`Bfi_Impl`: RPOT, Working, LoopData rows with an explicit list order for std::list inserts,
  IrreducibleGraph) is temp and discarded, like LLVM's `cleanup`.
- JumpThreading keeps `bpi`/`bfi` in `Jt` (getBPI/getBFI = own or cached result, getOrCreate* through
  `jt_run_external_analysis`).

## llvm-link (linker.jai)

Port of llvm-link.cpp, LinkModules.cpp (ModuleLinker) and IRMover.cpp (IRLinker) with the parts of ValueMapper.cpp
IRMover uses. The world is the LLVMContext; modules differ only in their module-level state:

- `Module_State` has every module-level field of `IR`; `lk_swap_module(*s)` exchanges them with `ir`. Loading a file
  swaps the composite out, parses into fresh state (types, constants and metadata interned into the shared tables,
  struct names uniqued per context: parser.jai `ctx_set_struct_name`), and swaps back: the source module ends up in
  a `Module_State`, the composite in `ir`, so everything that creates globals (set_name, gv_create, new_function)
  works on the destination as in IRMover.
- `lk.owner[global row]`: DST / SRC / GONE, for `GlobalValue::getParent()` checks (the materializer only links
  globals of the current source module).
- Moving, not cloning: `lk_link_function_body` gives the new destination function the source function's argument
  rows (`arg_parents`), blocks and local symbol table (`Function::stealArgumentListFrom` + `splice`), then the
  scheduled REMAP_FUNCTION work item rewrites operands, metadata attachments and types in place (`RF_IgnoreMissingLocals`:
  moved locals have no map entry and stay). Constants are rebuilt when an operand or the type maps differently.
- The mapper's state (two value maps for the two mapping contexts, MD maps, the LIFO worklist of global initializers /
  appending variables / aliases / function bodies, flushed after each top-level map call) and the IRMover state
  that lives across files (IdentifiedStructTypeSet, SharedMDs, NamedMDNodes) are in the global `lk`.
