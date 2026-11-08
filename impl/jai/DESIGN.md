# impl/jai — design of the IR core

Data-oriented, no OOP. Every IR entity is a **32-bit index** into flat, growable tables. Kind-specific behaviour is a
`switch` on a small enum tag (`if x == { case .ADD; ... }` with `#complete`), never a virtual call, inheritance or
a visitor. All of this is plain Jai: `[..] T` dynamic arrays, structs of arrays written out by hand (the `Soa`
module in the distribution is marked experimental), `Table` from `Hash_Table` for interning, and the temporary
allocator for per-pass scratch.

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
  inst_props.jai  mayHaveSideEffects, willReturn, wouldInstructionBeTriviallyDead, the TLI subset
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
exactly like in an `LLVMContext`. Entities are never moved: an id stays valid until the entity is erased, and erased
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
  `function(...)`; a function pass inside a module list gets its own adaptor). `loop`/`loop-mssa`/`cgscc` and
  unknown names fail loudly. `-O<n>` fails loudly in `opt_main`.
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
  `..._for_loc`, `..._skip_self`, `mssa_ensure_optimized_uses`, `mssa_dominates`. No MemorySSAUpdater and no use lists
  of accesses yet: passes that update MemorySSA must add them (see NOTES.md).
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
