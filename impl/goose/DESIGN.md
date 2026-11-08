# Goose implementation: design

How the IR core is laid out in memory, how passes mutate it, and how it reproduces the orders that LLVM's output
depends on. Everything here was chosen around Goose's memory model, so that comes first.

## 1. Constraints from Goose

Verified with a prototype (`goose build` with clang, Goose v2026.4) before writing this:

- **No heap.** Dynamic data lives on data stacks. A resizable array (`T[>..]` grow-only, `T[>..<]` grow-shrink) must
  be the top of its own stack, so each live resizable value gets its own stack. Globals of resizable type are legal and
  own the bottom of a stack for the whole run; the prototype keeps several of them live at once, pushes into them from a `recursive fn`, and shrinks one with `resize`.
- **Elements of a resizable array must be fixed-size**, and can't themselves be resizable. So there is no
  `Vec<Vec<T>>`: every variable-length list (operands, elements of a struct type, metadata operands, attribute sets)
  must be a *run* inside a shared pool array.
- **No pointers to keep, no function pointers, no virtual dispatch.** Polymorphism is `enum` + `match` only.
- **Recursion** (`recursive fn`) cannot hold a growable local across a recursive call, and no non-fixed temporary
  (e.g. `str(...)`) may be live at the call. Recursive code (type/constant/metadata parsing and printing, dominator
  DFS, …) works only on global tables and on fixed-size locals; scratch is a shared `[>..<]` stack with a mark.
  Verified: a `recursive fn` may push into a global `T[>..]`.
- **Shrinking** a grow-only array is legal only where the checker sees no live reference into it. We never hold
  references (`T&`) into the IR tables across calls; we hold **`i32` indices**. That keeps every table shrinkable and
  every function free of lifetime puzzles.
- `block`, `type`, `self`, `in`, `pad` are keywords: no field may be named `block` or `type`.
- `%` is Euclidean and `/` truncates; signed overflow aborts in `--debug` builds. APInt-style arithmetic is done on
  `u64` words, where everything wraps by definition.

## 2. The big decision: one process-wide set of global tables, addressed by `i32` ids

All IR lives in **global grow-only arrays of small fixed-size records** (array-of-structs per entity kind, with hot
and cold data split where it pays), plus a few **pools** that hold variable-length runs. An entity is named by its
index (`i32`), never by a reference. `-1` is "none". This is a data-oriented arena: no allocation per object, no
ownership puzzles, freeing is the process exit (`opt` handles one module per run; `llvm-link` loads several modules
into the same tables, each global value tagged with its module).

```
src/ir/        types.goose  values.goose  consts.goose  insts.goose  md.goose  attrs.goose  strings.goose
               uses.goose   symtab.goose  apint.goose   apfloat.goose
src/asm/       lexer.goose  parser.goose  printer.goose  slots.goose
src/opt.goose  src/llc.goose  src/llvm-link.goose        (root files; `import ir.values;` etc.)
```

### 2.1 Values: one id space

Every LLVM `Value` (constant, global variable, function, alias, argument, basic block, instruction, inline asm,
metadata-as-value) has an id in **`vals: Val[>..]`**:

```goose
struct Val { kind: u8, flags: u8, ty: i32, sub: i32, name: i32, first_use: i32, ops: i32, nops: i32, cap: i32 }
```

`kind` is the LLVM subclass (`ValueID` order), `ty` a type id, `sub` an index into the kind's own table
(`insts`, `blocks`, `args`, `globals`, `consts`), `name` a string id (-1 = unnamed) and `first_use` the head of its
use list. `ops/nops/cap` is the value's operand run (every user kind: instructions, constants, globals with
initializers/aliasees, functions with personality/prefix/prologue). A single id space is what makes use lists, RAUW and per-value side tables uniform: any analysis can keep
`xs: T[>..]` indexed by value id.

### 2.2 Uses and operands: runs in one pool, intrusive use lists

```goose
struct Use { val: i32, user: i32, next: i32, prev: i32 }     // uses: Use[>..]
var use_aux: i32[>..];                                        // parallel to uses: phi incoming block, …
```

A *user* (instruction or constant) owns a run `[ops_start, ops_start + ops_len)` in `uses`, with capacity
`ops_cap`. `next`/`prev` form the doubly linked use list of `val`, exactly LLVM's `Use::Next/Prev`.

- `set_operand(user, k, v)` = LLVM `Use::set`: unlink from the old value's list, **push at the head** of `v`'s list
  (`Use::addToList`). So `users(v)` iterates most recent first, as in LLVM.
- **ConstantData has no use list** in LLVM 23 (`Value::hasUseList()` is `!isa<ConstantData>`): ints, FP, null,
  undef, poison, zeroinitializer, data arrays/vectors. Uses of them are not linked (`next = prev = -1`); `users()` on
  them is an error, as it is in LLVM.
- Growing a run (`phi.addIncoming`, `switch.addCase`) copies it to a bigger run at the end of the pool exactly like
  LLVM's `growHungoffUses` (`grow_ops`): each copied use is re-`set` (pushed at the head of its value's list) in
  operand order, then the old uses are destroyed; capacity `n + n/2` for PHIs, `3n` for switches. Old runs are
  leaked for now (a per-capacity free list is planned). Removing an
  operand (`phi.removeIncoming`) shifts the tail down *in LLVM's way* (it swaps/moves exactly like the C++ so that
  operand order matches).
- PHI incoming blocks are **not** operands in LLVM (no uses on the block); they sit in `use_aux` beside the value's
  `Use`. Shufflevector masks and `extractvalue`/`insertvalue` indices are not operands either; they live in the
  `ints: i32[>..]` pool.

### 2.3 Instructions, blocks, functions: intrusive lists

```goose
struct Inst  { op: u8, flags: u8, fmf: u8, pred: u8, align: u8, ord: u8, ord2: u8, bits: u8,
               val: i32, parent: i32, prev: i32, next: i32, ty2: i32, attrs: i32, cc: i32,
               aux: i32, naux: i32, md: i32, nmd: i32, ss: i32, as_: i32 }
struct Block { val: i32, parent: i32, prev: i32, next: i32, first: i32, last: i32 }
struct Glob  { val: i32, module: i32, prev: i32, next: i32, linkage: u8, ..., vty: i32, attrs: i32,
               first_block: i32, last_block: i32, args: i32, nargs: i32, md: i32, nmd: i32, symtab: i32, ... }
```

(One `Glob` record serves functions, variables, aliases and ifuncs; the instruction record is one flat struct with
opcode-specific meanings for `pred`, `bits`, `ty2`, `aux` rather than a separate cold table.)

Instructions are in a doubly linked list per block, blocks in a doubly linked list per function, globals and
functions in per-module lists. Insertion, erase, splitting a block and moving instructions are O(1) relinks, so every
LLVM mutation API (`insertBefore`, `moveBefore`, `splitBasicBlock`, `eraseFromParent`, `splice`) ports one to one
and keeps LLVM's order. Opcode-specific fields: `ty2` is the GEP source type / alloca type / call function type, `aux/naux` a run in
`ints` (extractvalue indices, shuffle mask), `pred` the cmp predicate / atomicrmw op / tail-call kind, `align`
log2+1, `ord`/`ord2` atomic orderings, `bits` volatile/weak/inalloca. `flags` is the poison-generating flag byte
(`nuw nsw exact disjoint nneg samesign`, or GEP `inbounds nusw nuw`), `fmf` the fast-math byte.

**Erasing** (`inst_erase_from_parent`, irutil.goose) removes the name from the function's symbol table, unlinks the
record, drops its operands (unlinking each `Use`) and marks `vals[v].kind = VK_DEAD`. **Value ids are never
reused** (decided with the pass infrastructure, §8.2): a dead id stays a tombstone, so a stale id is detectable
(`is_dead(v)`) instead of silently naming a different value, and side tables indexed by value id never need
clearing on erase. The cost is a few dozen bytes per erased value until exit.

### 2.4 Types, constants, strings, metadata, attributes: interned, append-only

- **Types** `types: Ty[>..]` (`kind, bits, a, b`) with element lists in `type_elems: i32[>..]`. Structural types are
  hash-consed (same type ⇒ same id, so type equality is `==`). Identified structs are unique by name; their body is
  set once (opaque → body), appended to `type_elems` at that point. Named-struct printing order is by first use, the
  same way LLVM's `TypeFinder` collects them (see §4).
- **Constants** are uniqued like LLVMContext's tables: an open-addressing hash table maps (kind, type, payload,
  operand run) → value id. Wide integers (`i128`, `i256`) keep their words in `words: u64[>..]`; doubles keep their
  bit pattern. Constant expressions and aggregates are users with operand runs in `uses`, so a global's use list
  includes uses from initializers and constant expressions, as in LLVM.
- **Strings** (value names, section names, MDStrings, string attributes) live in one byte pool `chars: u8[>..]`;
  `strs: Str[>..]` holds (offset, length). Lookups go through our own hash tables of `i32` (not `dictionary` with
  slice keys), so nothing stores a slice into a growing array.
- **Metadata** `mds: Md[>..]` (`kind, distinct, ops_start, ops_len, …`) with operands in `md_ops: i32[>..]`; uniqued
  nodes are hash-consed. Instruction attachments are runs of `(kind id, md id)` pairs kept **sorted by kind id**, as
  `Instruction::getAllMetadata` returns them; the fixed kind ids are `FixedMetadataKinds.def` (`dbg`=0, `tbaa`=1,
  `prof`=2, …) and custom kinds are numbered in first-registration order, as LLVMContext does.
- **Attributes**: an attribute is (kind, int or type or string pair); an *attribute set* is a sorted run of them,
  interned, sorted exactly by `AttributeImpl::cmp` (enum kinds in `Attributes.td` enum order, then string attributes
  by key); an *attribute list* is an interned run of set ids (function, return, params). Equal sets share an id, which
  is what attribute-group numbering keys on.

Append-only pools mean dead records are garbage until the process exits. That is the deliberate trade: LLVM itself
keeps dead constants and types alive for the context's lifetime. If a pipeline ever grows the pools too much, a
compaction pass can rebuild them between passes with an id remap.

## 3. How passes use it

- A pass is a plain function over ids returning the analyses it preserved: `fn dce_run(fv: i32) -> u32`. The pass
  manager (§9) dispatches on a pass id with a `match` (no function pointers), parsed from `-passes=` text, with
  LLVM's nesting and the same order of running and of `-opt-bisect-limit` counting.
- Per-pass state lives in **locals of the pass's (non-recursive) entry function** and its nested functions:
  worklists (`i32[>..<]`), per-block arrays indexed by a local block number. Sets/maps over value ids use the
  O(1)-clear scratch slots of §8.4, never a `vals.len`-sized local (that would make a per-function pass quadratic
  in the number of functions).
- Recursive algorithms are written with an explicit stack (`[>..<]`) when the LLVM code uses one, and as
  `recursive fn` over global tables otherwise, following the LLVM code's visiting order exactly.
- LLVM containers are ported by behaviour, not by type: `SmallVector` → local `[>..<]`; `SetVector` → array + seen
  table (insertion order); `DenseMap` iteration order is never relied on unless LLVM relies on it, in which case we
  port the hash function and probing (`DenseMapInfo<T*>` hashes pointers, so LLVM generally avoids that).
- Analyses (dominators, loops, SCEV, …) are tables keyed by function id with a valid bit, invalidated by the pass
  manager with LLVM's preserved-analyses rules.

## 4. Reproducing LLVM's orders

| Order | LLVM mechanism | How we reproduce it |
| --- | --- | --- |
| Instruction / block / global order | `ilist` | intrusive `prev/next` lists, same mutation APIs |
| **Use lists** | `Use::addToList` pushes at head; `RAUW` loops `while (!use_empty()) UseList->set(New)` | same intrusive list; RAUW implemented by the same loop, so the old list is *reversed* onto the front of the new one. The parser resolves forward references with placeholder values and this RAUW, as `LLParser` does, so a freshly parsed module has LLVM's use-list order |
| **Value numbering** `%N` | `SlotTracker::processFunction`: unnamed args, then for each block the block (if unnamed) and each non-void unnamed instruction | the printer ports `SlotTracker` literally (module slots for unnamed globals, function slots on demand) |
| **Name uniquing** | `ValueSymbolTable::makeUniqueName`: per-table counter `LastUnique`, suffix `N` for locals and `.N` for globals, retry until free | one symbol table per function plus one per module, each an `i32` hash table over string ids with its own `last_unique` counter; same loop |
| **Attribute groups** `#N` | `CreateAttributeSetSlot`: global-variable attribute sets, then every function's fn attributes in module order, then call-site fn attributes while each function is processed | interned set ids make "same group" an `==`; the slot table is filled in that exact order |
| **Metadata numbering** `!N` | `processModule`: global attachments, then named-metadata operands; `processFunction`: function attachments, then per instruction (intrinsic metadata operands, then attachments by kind id); `CreateMetadataSlot` numbers a node and then its operands depth first, skipping `DIExpression` | ported literally; `!N` lines are printed after all functions, in slot order |
| Named struct types | `TypeFinder` over globals, functions, instructions, metadata | ported literally |
| Constant uniquing | `LLVMContextImpl` maps | hash-consing gives the same identity semantics (two equal constants are one value with one use list) |

Verified examples (`opt -S` on `tests/roundtrip/metadata/named_and_attached.ll`): the input's `!0` (a function
attachment) becomes `!3` because named metadata is numbered first, and the TBAA chain is renumbered depth first.

## 5. Value handles and callbacks without function pointers

Some passes and analyses rely on `WeakVH`, `WeakTrackingVH`, `AssertingVH` and `CallbackVH` (e.g. `ValueMap` in
cloning, SCEV's value cache). These are a table of handle records with a per-value intrusive list, and the *kind* of
handle decides what `erase`/`RAUW` does to it: null it out, follow the replacement, or append an event (handle id,
event kind) to a queue that the owning analysis drains. That replaces virtual `deleted()`/`allUsesReplacedWith()`
with data plus a `match`.

## 6. Text in, text out

- **Lexer**: one pass over the input bytes (read with `read_file` into a global buffer), tokens are (kind, offset,
  length); identifiers and strings are decoded into the string pool lazily.
- **Parser**: a recursive-descent port of `LLParser`. Recursion (types, constants, metadata) only touches globals.
  Forward references follow `LLParser`: placeholder values plus RAUW for local values and globals; blocks are created
  on first reference and moved into place when defined; numbered values must be sequential. Errors print
  `error: …` with the line and exit 1.
- **Printer**: a port of `AsmWriter.cpp` writing into one global `u8[>..]` output buffer, flushed once. Floats are
  printed with a port of `APFloat::toString` (shortest `%e`-like form that round-trips, else hex), integers of any
  width with an APInt-style word algorithm.

## 7. Known costs and debts

- Ids are never reused; erased values are `VK_DEAD` tombstones (§8.2). Operand runs of erased values are leaked.
- Append-only pools leak dead operand runs, types and constants until exit (see §2.4).
- A single global state means one module "context" per process. `llvm-link` has to load all inputs into it, which
  matches LLVM (all modules share one `LLVMContext`).

## 8. Pass-facing IR conventions (irutil.goose, instinfo.goose)

### 8.1 Queries
CFG: `term_nsucc/term_succ/term_set_succ`, `block_nsucc/block_succ`, `each_pred(bv) { p => … }` (users of the
block that are terminators, in use-list order, one per edge: LLVM's `predecessors()`), `single_pred`,
`first_non_phi`. Iteration: `each_inst(fv) { i => … }` reads the next instruction first (`make_early_inc_range`),
so the callback may erase `i`. PHIs: `phi_value/phi_block/phi_block_index`. Instruction properties are ports of the
`Instruction`/`CallBase` methods in instinfo.goose: `inst_may_have_side_effects`, `inst_may_read/write_memory`,
`inst_may_throw`, `inst_will_return`, `inst_is_eh_pad`, `call_has_fn_attr`, `call_memory_effects`,
`called_function`, `call_iid` (intrinsic id, `IID_*` constants from gen_iids.goose = LLVM's `Intrinsic::ID`).
Calls: `cb_*` accessors in calls.goose (operand layout `args…, bundle operands…, [dests…], callee`).

### 8.2 Mutation
`create_inst` (unlinked) + `inst_insert_before/after`, `block_append_inst`; `build_before(op, ty, ops, name, pos)`
and `build_br` are the IRBuilder equivalents. **Names are set after insertion** (`set_name`, `set_name_from`)
so the function's `ValueSymbolTable` uniques them exactly like LLVM (`x` taken → `x1`, per-table counter).
`inst_erase_from_parent` (fatal if uses remain, as LLVM asserts), `inst_remove_from_parent`, `inst_move_before`,
`rauw` (LLVM's head-first loop), `set_op` (`Use::set`), `drop_all_refs`. Blocks: `create_block_after`,
`split_block` (`splitBasicBlock`), `block_erase`, `block_remove_predecessor` (`removePredecessor`, including its
PHI folding), `block_replace_phi_uses_with`. PHIs: `phi_add_incoming`, `phi_remove_incoming` (LLVM 23 swaps the
last entry into the hole), `phi_has_constant_value`. Flags: `drop_poison_generating_flags/annotations`.
Ids are never reused (§2.3).

### 8.3 Value handles and worklists
No handle table yet: passes keep ids and check `is_dead(v)` where LLVM would use a `WeakVH`. Worklists follow the
LLVM container: `SmallVector` = `i32[>..<]` with `push`/`pop`; `SetVector` = array + scratch set membership
(DCE: insert if `vs_add` returned true, `vs_del` on pop).

### 8.4 Scratch sets and maps (O(1) clear)
`vs_clear/vs_add/vs_has/vs_del` (sets) and `vm_clear/vm_set/vm_get/vm_has` (maps to `i64`) over value ids (or use
ids), 6 slots each, with an epoch stamp per entry so clearing is O(1). Owners: `VS_PASS0/VS_PASS1`,
`VM_PASS0/VM_PASS1` belong to the running transform pass (ADCE: live set, dead-terminator set, block numbers);
`VS_ANA0/VM_ANA0` belong to DemandedBits (Visited, AliveBits); its DeadUses and worklist membership are private
stamped arrays (`db_dead_*`, `db_wl_*`), because the known-bits queries it makes reach ValueTracking code that uses
VS_ANA1. A pass that calls an analysis must not hold data in the slots the analysis uses.
`promote_mem_to_reg` (mem2reg.goose, also called by SROA) uses VM_PASS0 (AllocaLookup, PhiToAllocaMap), VM_PASS1
(LargeBlockInfo), VS_PASS0 (new PHIs) and VS_PASS1 (values mentioned by debug records); poison.goose's
programUndefinedIfUndefOrPoison, vt.goose's getUnderlyingObjects and SCEV's KnownPoison use VS_ANA1. A pass with more state keeps its own stamped table (SROA's `sr_*`,
20 slots keyed by value or use id). SCCP (sccp.goose) keeps one stamped record per value id (`ScRec`: lattice
index, struct-lattice base, additional-users list, tracked return/global, bit flags for executable/visited/
in-worklist/argument-tracked blocks and functions) and PredicateInfo (predinfo.goose) another (`PiRec`); its
transform phase uses VS_PASS1 through `m2r_collect_records` (debug-record RAUW). `m2r_collect_records(fv)` +
VS_PASS1 is the general "values that debug records mention" set: InstSimplifyPass, DCE and EarlyCSE use it for
RAUW (`m2r_dbg_rauw`), `salvage_debug_info` and `m2r_erase`; InstSimplifyPass keeps its ToSimplify/Next sets in
VS_PASS2/VS_PASS3 for that reason.

Block numbers (`BasicBlock::getNumber`) are tracked in ir.goose (`block_set_parent`, `block_number`,
`func_max_block_number`): assigned from a per-function counter when a block's parent changes. Every place that
links a block into a function goes through `block_set_parent`. Debug records carry their owning instruction
(`DbgRec.owner`), so `dbg_erase_record` doesn't search.

### 8.5 Analyses
**Dominator trees** (domtree.goose) port `GenericDomTreeConstruction.h` whole: construction (`SemiNCAInfo`) and
the incremental updates (`InsertEdge`/`DeleteEdge`/`ApplyUpdates` over a `GraphDiff` snapshot, with
`LegalizeUpdates`, the recalculation thresholds and the post-dominator root updates). Nodes are global
per-(block, kind) records with an epoch per tree, so recomputing never clears memory; children are an intrusive
list in LLVM's order (`addChild` appends, `removeChild` unlinks), the virtual root lives in the head record.
`DFSInfoValid`, `SlowQueries` and the DFS numbers are kept like LLVM's and printed by `print<domtree>`:
`dt_dominates_block` counts slow queries and switches to DFS numbers after 32, `dt_update_dfs_numbers` is what
`updateDFSNumbers` is (LoopInfo and IDF computations call it). API: `dt_get(fv, DT_DOM|DT_POST)`, queries
`dt_idom`, `dt_has_node`, `dt_dominates_block`, `dt_properly_dominates_block`, `dt_dominates_nodes`,
`dt_value_dominates_inst`, `dt_inst_dominates_block`, `dt_find_ncd`, `dt_first_child/dt_next_sibling`, `dt_level`,
`dt_root`, roots; updates `dt_apply_updates(fv, t, DTUpdate[])` (after the CFG change, like LLVM),
`dt_insert_edge/dt_delete_edge`, `dt_add_new_block`, `dt_change_idom`, `dt_erase_node`, `dt_split_block`,
`dt_recalculate`. `DT_VROOT` is the post-dominator tree's virtual exit. The SemiNCA state (one instance at a time,
O(1) clear) and the GraphDiff (one at a time) are module globals, so updates don't nest (they never do in LLVM).
Not ported: the two-argument `applyUpdates(Updates, PostViewUpdates)` and `CalculateWithUpdates`.

**DomTreeUpdater** (dtu.goose): one active updater (`dtu_begin(fv, use_dt, use_pdt, lazy)` … `dtu_end()`, the
destructor, which flushes), `dtu_apply_updates`, `dtu_apply_updates_permissive`, `dtu_split_critical_edge`,
`dtu_delete_bb`, `dtu_flush`, `dtu_get_dt/pdt`, `dtu_recalculate`. A tree that isn't cached is treated as absent
(LLVM's null pointer), so a pass passes `true` for every tree it would hand to the updater.

**LoopInfo** (loopinfo.goose) and **CycleInfo** (cycleinfo.goose): loops and cycles are ids into global tables
(never reused); their block lists, subloop lists and the top-level list are runs in a pool (copied to a bigger run
when they grow), kept in LLVM's order (a loop's header is `blocks[0]`). The block → innermost loop/cycle map is
stamped with a per-function epoch. `loop_contains(l, bb)` walks the parents of the block's innermost loop (LLVM's
`DenseBlockSet`; equivalent while the map and the block vectors are kept consistent, which every LLVM updater
does). Update API for transforms: `loop_add_basic_block_to_loop`, `li_change_loop_for`, `loop_add_child`,
`loop_remove_child`, `loop_replace_child_with`, `li_change_top_level_loop`, `loop_remove_block_from_loop`,
`loop_move_to_header`, `li_remove_block`, `li_allocate_loop`; `ci_split_critical_edge`, `ci_add_block_to_cycle`.

DemandedBits
(demandedbits.goose) is computed per query (`db_analyze`, cached for the current function, `db_invalidate()` at the
start and end of a pass that uses it). computeKnownBits (knownbits.goose), computeKnownFPClass (fpclass.goose)
and the rest of ValueTracking (vt.goose, poison.goose, implied.goose, assume.goose) fail loudly on every case LLVM
handles that isn't ported (see the file headers), so imprecision can't silently change output. They are free
functions over the global IR tables; the SimplifyQuery context instruction is the global `kb_cxt` and the
query's missing members are the `sq_no_dt/sq_no_ac/sq_no_tli` switches. InstSimplify (instsimplify.goose) keeps
the operands of recursive simplification on the global `is_ops` stack. TargetLibraryInfo (tli.goose)
must know the current function: set `tli_cur_fn = fv` at the start of a pass.

Analysis ids and preserved sets are in analyses.goose (`A_*`, `PA_ALL`, `PA_NONE`, `PA_CFG`). `PA_CFG` is
`preserveSet<CFGAnalyses>`: every CFG-only analysis (dominator trees, loops, cycles). A pass that changes the CFG
and updates some trees returns exactly those bits (ADCE: domtree | postdomtree; break-crit-edges and
loop-simplify: domtree | loops).

### 8.6 Memory analyses (memloc, aa, tbaa, globalsaa, capture, aautil, memoryssa, phitrans)

Ports of `MemoryLocation.cpp`, `AliasAnalysis.cpp`, `BasicAliasAnalysis.cpp`, `TypeBasedAliasAnalysis.cpp`,
`ScopedNoAliasAA.cpp`, `GlobalsModRef.cpp` (+ `CallGraph.cpp`, `SCCIterator.h`), `CaptureTracking.cpp`,
`CFG.cpp` (reachability), `MemorySSA.cpp` and `PHITransAddr.cpp`. Data, not objects:

- **MemoryLocation** is the fixed-size struct `ML { ptr, size, tbaa, tbaa_struct, scope, noalias, noalias_as }`;
  `size` is LLVM's raw 64-bit `LocationSize` encoding (`ls_precise/ls_upper_bound/LS_AFTER/LS_BEFORE_OR_AFTER`,
  `ls_has_value/ls_value/ls_is_precise/ls_is_scalable`), so equality and hashing are LLVM's. `ptr == ML_NULL` is
  `MemoryLocation()` (Ptr = null), `ptr == ML_NONE` is `std::nullopt`. `ml_get(i)`, `ml_get_or_none(i)`,
  `ml_for_argument(call, k, use_tli)`, `ml_for_source/dest`, `ml_aa_tags(i)`.
- **ModRefInfo** is an `i64` (`MR_NO/REF/MOD/MODREF`), **MemoryEffects** a `u64` (2 bits per location, `me_*`),
  **CaptureComponents/CaptureInfo** `i64`s (`CC_*`, `ci_other/ci_ret`; the parser stores `captures(...)` as
  `other | ret << 8`, `aset_capture_info` converts). CallBase per-operand queries: `cb_param_has_attr`,
  `cb_arg_only_reads/writes`, `cb_arg_no_memory`, `cb_capture_info` (memloc.goose).
- **AliasResult** is `AR { k, has_off, off }` (`AR_NO/MAY/PARTIAL/MUST`, `ar_swap`, `ar_format`).
- **The AA pipeline** (`-aa-pipeline`, default `basic-aa,scoped-noalias-aa,tbaa` + `globals-aa` when cached) is the
  list `aa_kinds`; the aggregation functions loop over it with a `match` on the kind (no virtual dispatch).
  Call `aa_begin(fv)` first (= `AM.getResult<AAManager>(F)`: sets the function and TLI, computes the DT, which
  BasicAA requires).
- **AAQueryInfo / BatchAAResults**: `q = aq_push(CA_SIMPLE | CA_EARLIEST)` ... `aq_pop(q)` (stack discipline). A
  query info owns an alias cache region in one chained hash table (`aent/abuck`, entries after `ent_mark`), the
  assumption-based results (`aq_abr`), `cross` (MayBeCrossIteration; `BatchAACrossIterationScope` = save/restore
  `aqs[q].cross`), `use_dt`, and the SimpleCaptureAnalysis cache. `CA_EARLIEST` query infos use the single
  EarliestEscapeAnalysis instance instead, which outlives query infos as in DSE/MemCpyOpt: `ea_begin(use_li,
  use_ci)` = `EarliestEscapeAnalysis(DT, LI, CI)`, `ea_remove_instruction(i)`. Results depend on the cache
  exactly as in LLVM (assumption-based PHI results), so reuse one `q` where LLVM reuses a BatchAAResults and make
  a fresh one where LLVM makes a SimpleAAQueryInfo (`aa_*_simple` helpers).
- **Entry points**: `aa_alias(a, b, q, cxt)`, `aa_inst_loc_mr(i, loc, q)` (getModRefInfo(I, OptLoc)),
  `aa_inst_call_mr`, `aa_inst_inst_mr`, `aa_call_loc_mr`, `aa_call_call_mr`, `aa_call_me` / `aa_fn_me`
  (getMemoryEffects), `aa_mod_ref_mask` / `aa_points_to_constant_memory`, `aa_arg_mod_ref`,
  `aa_call_captures_before`, `aa_is_identified_object` & co., `aa_is_not_visible_on_unwind`,
  `aa_is_writable_object`. Capture tracking: `ct_pointer_may_be_captured`, `ct_may_be_captured_before`,
  `ct_find_earliest_capture`. Reachability (DT, optional LoopInfo / CycleInfo): `cfr_inst_reachable`, `cfr_block_reachable`,
  `cfr_from_many`, `cfr_not_in_cycle`.
- **Recursion**: the aggregator and BasicAA are mutually recursive (`AAQI.AAR.alias`), so they live in one file
  (aa.goose) and keep no growable locals: decomposed GEP indices are runs on `bas_vars`, aliasPHI's sources on
  `bas_srcs`, truncated to a mark before returning.
- **APInt widths**: BasicAA's offsets/scales are `u64` at the index width; index widths or GEP index types wider
  than 64 bits fail loudly.
- **GlobalsAA** (`require<globals-aa>` module pass, `gm_compute`/`gm_invalidate`): per-function FunctionInfo by
  value id with the per-global map as runs; the CallGraph is node/edge lists, SCCs by the ported Tarjan iterator
  (SCC order and SCC[0] matter). No deletion callbacks: valid while no tracked global/function is erased.
- **MemorySSA** (`mssa_get(fv)`; one instance, for `mssa_fn`; invalidated unless the pass preserves `A_MEMORYSSA`,
  the DT and `A_AA`): accesses are ids into `macc` (0 = liveOnEntry; `MAK_DEF/USE/PHI/LIVE`, printed `id`),
  per-block access and defs lists are intrusive (`mb_first/mb_last`, `next/prev`, `dnext/dprev`), block and
  instruction -> access maps are value-id arrays stamped with a build epoch (`mssa_access_of(v)`). Operands are
  uses with LLVM's use-list order (`mssa_first_use/mssa_use_next/mssa_use_user/mssa_use_slot`); MemoryPhi operands
  are runs (`mphi_n/mphi_val/mphi_blk`, `mphi_add_incoming` grows like `growHungoffUses`). Walker:
  `mssa_get_clobbering(ma, q)` (CachingWalker, MaxCheckLimit), `mssa_get_clobbering_loc(ma, loc, q)`,
  `mssa_clobbering_access(ma, q, skip_self, use_invariant_group)` with `cw_limit` as the UpwardWalkLimit;
  `mssa_ensure_optimized()`, `mssa_dominates`, `mssa_locally_dominates`, `mssa_def_clobbers`
  (instructionClobbersQuery). Not ported: the loop (`MemorySSA(Loop&)`) constructor, the verifier
  (`verify<memoryssa>` only builds), DOT output.
- **MemorySSAUpdater** (mssaupdater.goose): only the removal part so far: `msu_remove_memory_access(ma,
  optimize_phis)` / `msu_remove_inst_access(i, optimize_phis)` (removeMemoryAccess with tryRemoveTrivialPhi /
  recursePhi), `msu_rauw`, `mssa_remove_from_lookups` / `mssa_remove_from_lists`. A removed access gets kind
  `MAK_DEAD` (WeakVH lists test `msu_is_dead`); `msu_repl` records RAUWs for TrackingVH-style lists
  (`msu_track`). Every operand change of an access must go through `msu_use_set`, which keeps the cached
  `def`/`opt`/phi-incoming values in sync with the use. `msu_reset()` when a pass starts using the updater.
  Insertion (createMemoryAccess*, insertUse/insertDef with phi placement), moves and block removal are for LICM,
  DSE, MemCpyOpt and the loop passes to add here.
- **Printing with annotations** (`F->print(OS, &AnnotationWriter)`): `pr_annot_set(v, text)` registers a line for
  a block (printed after its label) or an instruction (printed before it), `pr_annot_on` while `print_function`
  runs (printer.goose); the annotation texts are computed first in printing order.

### 8.7 ScalarEvolution (scev*.goose)
One ScalarEvolution instance exists at a time, for the function `sc_fv`: `scev_get(fv)` builds it (empty, as
LLVM's constructor does), `scev_invalidate(fv)` drops it, and a different function resets every table.
- **Nodes**: `scevs: Scev[>..]` (kind in `SCEVTypes` order, flags, expression size, type, operand run in
  `sc_ops`, value for constants/unknowns, loop for AddRecs). Uniquing is a chained hash table keyed exactly like
  LLVM's FoldingSetNodeIDs (kind, operands, value, loop; the type only for vscale/trunc/zext/sext/ptrtoaddr). Id 0
  is SCEVCouldNotCompute. SCEVUse's use-flags are never set in LLVM 23, so an operand is a plain id.
- **Operand lists**: the builders form one big recursive cycle, and Goose forbids growable locals across a
  recursive call, so every `SmallVector<SCEVUse>` is a run on the scratch stack `ss`: a builder that takes
  `SmallVectorImpl &Ops` (`sc_add_n`, `sc_mul_n`, `sc_addrec_n`, `sc_minmax_n`, `sc_seq_minmax_n`, ...) gets the
  base `b` of a run reaching the top of `ss`, owns it and truncates `ss` to `b` before returning. Other
  mark-based scratch stacks: `sc_newops` (worklists, LIOps, AddRecOps, DeadIndices), `sc_cops`/`sc_newscales`
  (CollectAddOperandsWithScales), `sc_seen` (visited sets: each traversal searches only from its own mark),
  `sc_vops`/`sc_cstack` (createSCEVIter), `sc_tmp` (exiting blocks, assumptions). Never index two of them in
  parallel unless only that pair is pushed in between.
- **Caches**: per-SCEV side tables (`sc_side`: ranges, has-AddRec; `sc_cm`: constant multiples; `sc_side2`:
  generation and the *WrapViaInductionTried bits) and hash maps (`HMap`, u64 -> i64) for ValueExprMap, FoldCache,
  loop/block dispositions, ValuesAtScopes, BackedgeTakenCounts. Erasing every entry of a forgotten SCEV is a
  generation bump (`sc_side2[s].gen`): dispositions, ValuesAtScopes and FoldCache entries carry the generation of
  the SCEV they were computed for (and of their result), stale ones are misses. SCEVUsers / ExprValueMap /
  BECountUsers / LoopUsers are linked lists in `sc_lpool`.
- **APInt lifetime**: wide APInts live in a pool reset after every pass, but SCEV caches outlive passes (loop passes
  preserve SCEV), so cached ranges and constant multiples are stored as IR ConstantInts.
- **Rewriters**: one `SCEVRewriteVisitor` (`sc_rw_visit`, RewriteResults keyed by a per-instance serial) with a
  `RW` record whose kind selects the overrides (Init, PostInc, BackedgeConditionFolder, Shift, LoopGuards,
  PredicateRewriter).
- **Predicates**: compare and wrap predicates uniqued in `sc_preds`; ExitLimits and ExitNotTakenInfos keep runs
  of predicate ids in `sc_predl`.
- **LoopGuards**: an id into `sc_guards`; its RewriteMap and NotEqual set are hash maps keyed by the id.

## 9. The pass manager and how to add a pass (passmgr.goose)

`-passes=` text is parsed like `PassBuilder::parsePipelineText` into a tree of `PNode`s (module / function
adaptors, passes). The implicit outer level is chosen from the first name like `parsePassPipeline` (a function pass
first ⇒ the whole list is wrapped in one `function(...)`; a function pass inside a module list gets its own
adaptor). Names are checked against `LLVM_PASS_NAMES` (gen_passes.goose, from `PassRegistry.def`): a name LLVM
doesn't know fails with "unknown pass", one LLVM knows but we don't fails with "not implemented yet". The module
→ function adaptor runs every child on each function definition in module order. `-opt-bisect-limit` counts every
non-required pass run and prints LLVM's `BISECT:` lines. After each function pass, `invalidate_function` drops the
analyses not in the returned preserved mask (`PA_ALL`, `PA_CFG`, `PA_NONE`, or bits `1 << A_*`).

To add a function pass `foo`:
1. Port it in `src/foo.goose` (header comment: the LLVM file), entry `fn foo_run(fv: i32) -> u32` returning the
   preserved analyses exactly as LLVM's `run` does (`PA_ALL` if nothing changed).
2. In passmgr.goose: a `P_FOO` id, a `PASS_TABLE` row `"f:foo:<id>:0"` (`:1` for required passes such as
   printers), a case in `run_function_pass`, its class name in `pass_class_name` (for bisect), and `import foo;`.
   Pass parameters (`foo<a;b>`) arrive as the full element name: parse them in `parse_function_elem`.
3. cl::opt flags it reads: add the name to `KNOWN_FLAGS` (flags.goose) and read with `flag_bool/flag_int`.
4. New analysis: an `A_*` bit in analyses.goose, `analysis_id` (for `require<>`/`invalidate<>`), invalidation in
   `invalidate_function`, and decide whether it's in `PA_CFG` (LLVM's `CFGAnalyses` set).
5. Printers write to `errs(...)` (flags.goose); `errs_operand`/`errs_inst` print values exactly as the IR printer
   does (they number the function with the printer's SlotTracker).
Module passes: an `m:` row and a case in `run_module_node`.

**Loop passes** (lpm.goose, passmgr.goose): `loop(...)`/`loop-mssa(...)` and a loop pass in a function pipeline
become a `PK_LOOP` node (FunctionToLoopPassAdaptor) whose `pass` field links its two canonicalization nodes
(loop-simplify, lcssa: run like a function pass manager, counted by bisect); a nested `loop(...)` is a `PK_LPM`
node. `run_loop_adaptor` runs the canonicalization, gets LoopInfo (no loops: done), builds the
LoopStandardAnalysisResults (DT, SCEV, TLI; MSSA fails loudly for now), fills the worklist with
`appendLoopsToWorklist(LI)` and pops loops LIFO; each loop runs the children (`run_loop_list`, stopping when
`lpm_skip`). The adaptor's preserved set is the intersection of every pass's plus DT, LoopInfo and SCEV. A loop pass
`foo` is an `l:` row, a case in `run_loop_pass(n, l, fv)`, and uses the LPMUpdater API in lpm.goose
(`lpm_cur`, `lpm_mark_loop_as_deleted`, `lpm_add_child_loops`, `lpm_add_sibling_loops`, `lpm_revisit_current_loop`).
Loop-nest passes are not ported. Bisect prints the pipeline name of the pass (`loop-simplify`, not the class name)
and `[module]`, `<function>`, `loop %<header> in function <f>` as the IR unit.

## 10. Arbitrary-width integers (apint.goose)

LLVM's `APInt` has any width up to 2^23 bits, and the analyses (KnownBits, ConstantRange, constant folding,
PatternMatch) are written over it, so ours are too: `struct AP { lo: u64, w: i32, ix: i32 }`, 16 bytes, passed by
value.

- **w <= 64**: the value is `lo` (always truncated to `w` bits), `ix = -1`. Every operation tests `a.ix < 0` first
  and then works on `lo` directly, so i1..i64 code (almost all real code) never touches memory and costs about
  what the earlier raw-`u64` code did (instsimplify on the tests/perf/compile programs stayed 2x faster than LLVM's).
- **w > 64**: the `ceil(w/64)` little-endian words live in a global bump pool `apw: u64[>..<]` at
  `[ix, ix + nw)`; the top word is kept truncated and `lo` caches word 0. An operation allocates its result's words
  and never writes into an existing value's words, so copying an `AP` (sharing `ix`) is safe and values are
  immutable.
- **Lifetime**: the pass manager calls `ap_pool_reset()` after every pass (`run_function_node`; module passes must
  do the same). So *no AP may outlive the pass that made it*: anything kept across passes is stored as an IR
  constant (`ap_to_cint`). `ap_mark()/ap_release(m)` free a bounded computation's temporaries early (used by
  `ap_format`).
- Alternatives rejected: a fixed-capacity word array (i4097 = 65 words would make every KnownBits value ~1 KB
  and every copy expensive, and still fail above the cap); a free-list allocator (needs ownership, which `AP` as a
  plain value doesn't have; a per-pass arena gives the same memory bound with no bookkeeping).
- Division is shift-subtract on scratch words in the pool (the quotient/remainder are unique, so the algorithm
  needn't match LLVM's Knuth D); everything else follows APInt.cpp. `tools/aptest.py` is a differential test
  against Python integers (widths 1..4097, all operations; `tools/gb.sh src/aptest.goose bin/aptest` first).
- Users: `KB { z: AP, o: AP }` (knownbits.goose, width = `kb_bw`), `CRange { lo: AP, hi: AP }`
  (constrange.goose), constant folding (`ap_from_cint`/`ap_to_cint`, `ci_ap`/`c_int_ap` in pm.goose). The 64-bit
  `CR` of crange.goose remains only for BasicAA's index-width arithmetic (aa.goose) and fails loudly above 64 bits;
  DemandedBits is still u64-based and fails loudly above 64 bits.

## 11. Calling C: the host libm (hostmath.goose, hostmath.c, opt.build)

LLVM folds `sin`, `exp`, `pow`, ... by calling the host's double-precision libm and discarding the fold when
errno or an FP exception other than inexact is raised. Goose calls C through `extern fn`; the C side
(`src/hostmath.c`, compiled through the root sidecar `src/opt.build`) does the call with the same errno/fenv test,
through a volatile function pointer so the C compiler can't reorder it around `fetestexcept`. LLVM's opt links the
same glibc libm, so the results are bit-identical. Only `opt` links it; a new root file that imports cfold.goose
needs the same `.build` sidecar.

## 12. InstCombine (ic*.goose)

A port of `lib/Transforms/InstCombine`. All files are in `namespace ic;` (so helper names like `has_nsw` or
`opcode_name` can't collide with the global ones); the pass manager calls `ic::instcombine_run(fv, verify_fixpoint,
max_iterations)` and `ic::ic_lrt_invalidate(fv)`.

| File | Port of |
| --- | --- |
| `ic.goose` | InstructionCombining.cpp: `InstructionWorklist` (`icw_*`), `run()`, `prepareWorklist`, `combineInstructionsOverFunction` + `InstCombinePass::run` (fixpoint loop, verify-fixpoint error, LastRunTracking `ic_lrt_*`), the InstCombiner helpers (`ic_replace_inst_uses_with`, `ic_replace_operand`, `ic_replace_use`, `ic_erase`, `ic_insert_new_before/with`, `ic_take_name`), dead blocks/edges, sinking, the opcode dispatch `ic_visit`, the terminator visitors |
| `ic_builder.goose` | `IRBuilder<TargetFolder, IRBuilderInstCombineInserter>`: `icb_*` create-or-fold functions; `ic_new_*` create unattached instructions (BinaryOperator::Create & co.) |
| `ic_common.goose` | the binop helpers of InstructionCombining.cpp (reassociation, distributive laws, folding into selects/phis, getFreelyInverted, ...) and small PatternMatch-style matchers (`bo`, `m_zext`, `m_add_like`, ...) |
| `ic_addsub.goose`, `ic_muldivrem.goose`, `ic_shifts.goose`, `ic_casts.goose` | InstCombineAddSub / MulDivRem / Shifts / Casts (integer parts) |
| `ic_andorxor.goose` | InstCombineAndOrXor.cpp (whole), with recognizeBSwapOrBitReverseIdiom (Local.cpp) and decomposeBitTest |
| `ic_negator.goose` | InstCombineNegator.cpp |
| `ic_demanded.goose` | SimplifyDemandedBits (integer and pointer part of InstCombineSimplifyDemanded.cpp) |
| `ic_compares.goose` | InstCombineCompares.cpp, whole: `visit_icmp`/`visit_fcmp` and every helper in file order (GEP compares, load-from-constant-global compares, alloca compares, the APFloat helpers the fcmp folds need); also decomposeBitTestICmp (CmpInstAnalysis.cpp) and decomposeLinearExpression (Loads.cpp) |
| `ic_andorxor.goose` | InstCombineAndOrXor.cpp (insertRangeTest so far) |
| `ic_visit_misc.goose` | calls (`visitCallInst`/`visitCallBase` for ordinary functions, `llvm.assume`), and the fail-loudly fallback for every visitor that isn't ported |
| `domcond.goose` (global) | DomConditionCache; ValueTracking consults it (knownbits, pow2, non-equal, fpclass) while `dc_active` |
| `overflow.goose` (global) | computeOverflowFor*, haveNoCommonBitsSet |

### 12.1 Conventions

- **A visitor returns an instruction id**: `-1` = nullptr (no change), the visited instruction itself = "modified
  in place" (run() re-queues it and its users), or a *new unattached* instruction that replaces it (run() does
  RAUW, `takeName`, inserts it at the old position and erases the old one). `ic_replace_inst_uses_with(i, v)`
  returns `i` (as LLVM's `replaceInstUsesWith` returns `&I`), `ic_erase` returns -1.
- **Names.** An unattached instruction may carry a name (`set_name` on it just stores the string); it is
  registered and uniqued in the function's symbol table when it is inserted (`ic_register_name`). `icb_*(..., name)`
  inserts first and names after (IRBuilder semantics: `x` taken -> `x1`). `ic_take_name(dst, src)` is
  `Value::takeName`. Copy names into a local buffer before passing them on (`val_name` is a slice of the
  string pool that `set_name` may grow).
- **Builder state** is global: `icb_pos/icb_bb/icb_dl/icb_fmf`. run() sets it to the visited instruction
  (`icb_set_insert_point`). An `IRBuilderBase::InsertPointGuard` is a save/restore of those three globals.
  `icb_insert` adds new instructions to the *deferred* worklist (`IRBuilderInstCombineInserter`), except while
  the Negator runs (`ng_active`: they are recorded and added after a successful negation).
- **TargetFolder**: `tf_binop` = `ConstantExpr::get` + `ConstantFoldConstant` for add/sub/xor, else
  `ConstantFoldBinaryOpOperands`; casts through `cf_fold_cast_operand`; intrinsics through `tf_intrinsic`.
- **The SimplifyQuery** is `sq_at(i)` for InstSimplify calls and `kb_cxt = i` for ValueTracking calls (set it
  right before every `kb_compute_all` / `is_known_*` / `num_sign_bits` / `masked_value_is_zero` call: other
  calls overwrite it). InstCombine's SimplifyQuery has a DomConditionCache: `dc_active` is set for the
  duration of one InstCombinerImpl (one iteration); `visit_cond_br` registers branches (`dc_register_branch`),
  `ic_erase` calls `dc_remove_value`. Code that asks for `getWithoutDomCondCache()` saves/clears `dc_active`.
- **Matching.** `BinaryOp_match`/`CastInst_match` (m_Add, m_ZExt, ...) match *instructions only* in LLVM 23;
  `m_PtrToInt`, `m_BitCast`, `m_IntToPtr` also match constant expressions (`is_op`). `m_OneUse` is `one_use(v)`
  (false for ConstantData). Commutative patterns are a `for k in 2` over the operand order LLVM tries first.
  Partial matches bind values in LLVM (`m_Value(X)` inside a failing pattern still assigns X): where a later
  check depends on that, the port says so.
- **Recursive helpers** (getFreelyInverted, Negator, takeLog2, SimplifyDemandedBits, canEvaluateShifted,
  EvaluateInDifferentType) are `recursive fn` with fixed-size locals only; their output parameters are extra
  return values (`-> i32, KB`) or globals saved/restored around the recursive call (`gfi_consume`).

### 12.2 How to add a fold or a visitor

1. Find the LLVM function (e.g. `InstCombinerImpl::visitAnd` in InstCombineAndOrXor.cpp) and port it top to bottom
   into the matching `ic_*.goose` file (`fn visit_and(i: i32) -> i32`), keeping LLVM's order of folds: the first
   fold that fires wins, so order is behaviour.
2. Register a new visitor in the `match` of `ic_visit` (ic.goose) and remove its opcode from the fail-loudly
   fallback (it is the `_` arm, `ic_visit_other`).
3. A sub-fold you don't port must not silently do nothing: test its distinctive precondition and call
   `ic_not_ported("<LLVM function name>")` (see `fold_vector_binop`, `narrow_binop`
   `canonicalize_cond_signext_of_high_bit_extract`). Keep the guard as narrow as the pattern, or it blocks unrelated tests.
4. Create IR with `icb_*` (inserted, folded, named) or `ic_new_*` (unattached, for a visitor's return value);
   set flags with `set_nsw/set_nuw/set_exact/set_disjoint/set_nneg`. Use `ic_replace_operand` / `ic_replace_use`
   (not `set_op`) where LLVM uses replaceOperand/replaceUse, so the worklist sees the use-count change.
5. Run `tools/ic_failures.py [globs]` after a `check` to see the first blocker of every failing test, and
   `opt -goose-ic-lenient` (development only: unported visitors do nothing instead of failing) to see which tests
   would pass if only the unported visitors were missing.

## 13. EarlyCSE and its shared helpers (earlycse.goose, instident.goose, salvage.goose, knowledge.goose)

- **Scoped hash tables** (earlycse.goose): the five `ScopedHashTable`s are one chained hash map (`ec_ents`,
  buckets `ec_bk`) whose entries are tagged with the table (`ET_VALUES/LOADS/INVARIANTS/CALLS/GEPS`). An entry
  is a DenseMap bucket: the key of its first insertion, the head of the value chain, and the hash computed when
  it was created. Value records (`ec_vals`, ScopedHashTableVal) hold NextForKey and NextInScope; a scope is the
  `NextInScope` chain from `ec_scope_last`, saved and restored by the DFS stack nodes (`ENode.saved_last`).
  Lookups compare the hash computed now with the stored one, so an instruction whose operands changed after its
  insertion is not found under its new hash, which is what a DenseMap does. Hashes are LLVM's getHashValue with
  value ids instead of pointers; equal keys always hash equally. Chains are searched oldest first.
- **instident.goose** (shared): `ii_is_identical_when_defined(a, b, intersect_attrs)`, `ii_has_same_special_state`,
  `ii_alist_intersect` / `ii_aset_intersect` (AttributeList/AttributeSet::intersectWith with the
  `ATTR_INTERSECT` rule table generated from Attributes.td), `ii_try_intersect_attributes`, `ii_and_ir_flags`
  (Instruction::andIRFlags for two instructions), `ii_is_commutative` / `ii_intrinsic_is_commutative`. GVN and
  SimplifyCFG hoisting/sinking need exactly these.
- **salvage.goose** (shared): `salvage_debug_info(i)` (salvageDebugInfo: casts, GEPs via collectOffset, binops,
  icmps; DIExpression appendOpsToArg/prependOpcodes/appendOffset, foldConstantMath, DIArgList growth, kill
  locations). Needs `m2r_collect_records(fv)` at the start of the pass. dbg_assign address salvaging fails loudly.
- **knowledge.goose** (shared): `salvage_knowledge(i, use_ac)` for `--enable-knowledge-retention`
  (AssumeBuilderState: attribute and access knowledge, canonicalization, tryToPreserveWithoutAddingAssume through
  the AssumptionCache, the new `llvm.assume` with operand bundles). Callers in LLVM: DCE, EarlyCSE (ported), DSE,
  GVN, NewGVN, LICM, the inliner.

