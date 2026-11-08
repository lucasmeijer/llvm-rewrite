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
- Dominator trees are recomputed after a CFG change instead of updated incrementally (§8.5): child order can then
  differ from LLVM's for passes that preserve the tree through `DomTreeUpdater`.
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
ids), 4 slots each, with an epoch stamp per entry so clearing is O(1). Owners: `VS_PASS0/VS_PASS1`,
`VM_PASS0/VM_PASS1` belong to the running transform pass (ADCE: live set, dead-terminator set, block numbers);
`VS_ANA0/VS_ANA1/VM_ANA0` belong to DemandedBits (Visited, DeadUses, AliveBits), which also borrows `VS_PASS1`
for its worklist while it runs. A pass that calls an analysis must not hold data in the slots the analysis uses.

### 8.5 Analyses
Dominator trees (domtree.goose, a port of `SemiNCAInfo`: `runDFS`, `runSemiNCA`, `FindRoots` with
`RemoveRedundantRoots`, `attachNewSubtree`) live in global per-(block, kind) node records with an epoch per tree,
so recomputing never clears memory. `dt_get(fv, DT_DOM|DT_POST)` computes if invalid; queries: `dt_idom`,
`dt_dominates_block`, `dt_first_child/dt_next_sibling` (LLVM's child order), `dt_level`, `dt_root`, roots.
`DT_VROOT` is the post-dominator tree's virtual exit. **Incremental updates are not ported**: a pass that changes
the CFG returns a preserved set without the trees and they are recomputed on the next `dt_get`. DemandedBits
(demandedbits.goose) is computed per query (`db_analyze`, cached for the current function, `db_invalidate()` at the
start and end of a pass that uses it). computeKnownBits (knownbits.goose) fails loudly on every case LLVM handles
that isn't ported (see the file header), so imprecision can't silently change output. TargetLibraryInfo (tli.goose)
must know the current function: set `tli_cur_fn = fv` at the start of a pass.

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
4. New analysis: an `A_*` bit, `analysis_id` (for `require<>`/`invalidate<>`), invalidation in
   `invalidate_function`, and decide whether it's in `PA_CFG` (LLVM's `CFGAnalyses` set).
5. Printers write to `errs(...)` (flags.goose); `errs_operand`/`errs_inst` print values exactly as the IR printer
   does (they number the function with the printer's SlotTracker).
Module passes: an `m:` row and a case in `run_module_node`.
