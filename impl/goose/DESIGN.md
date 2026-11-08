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
struct Val { kind: u8, ty: i32, sub: i32, name: i32, first_use: i32 }
```

`kind` is the LLVM subclass (`ValueID` order), `ty` a type id, `sub` an index into the kind's own table
(`insts`, `blocks`, `args`, `globals`, `consts`), `name` a string id (-1 = unnamed) and `first_use` the head of its
use list. A single id space is what makes use lists, RAUW and per-value side tables uniform: any analysis can keep
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
- Growing a run (`phi.addIncoming`, `switch.addCase`) doubles the capacity: the run is copied to the end of the pool
  and the neighbours' links (and `first_use` heads) are re-pointed at the moved `Use`s. The old run goes on a free
  list per power-of-two capacity, so a pass that grows many phis does not grow the pool without bound. Removing an
  operand (`phi.removeIncoming`) shifts the tail down *in LLVM's way* (it swaps/moves exactly like the C++ so that
  operand order matches).
- PHI incoming blocks are **not** operands in LLVM (no uses on the block); they sit in `use_aux` beside the value's
  `Use`. Shufflevector masks and `extractvalue`/`insertvalue` indices are not operands either; they live in the
  `ints: i32[>..]` pool.

### 2.3 Instructions, blocks, functions: intrusive lists

```goose
struct Inst  { op: u8, flags: u8, fmf: u8, sub8: u8, sub32: u32, val: i32, parent: i32,
               prev: i32, next: i32, ops_start: i32, ops_len: i32, ops_cap: i32, extra: i32, md: i32 }
struct Block { val: i32, parent: i32, prev: i32, next: i32, first: i32, last: i32 }
struct Func  { val: i32, first_block: i32, last_block: i32, args_start: i32, nargs: i32, attrs: i32, ... }
```

Instructions are in a doubly linked list per block, blocks in a doubly linked list per function, globals and
functions in per-module lists. Insertion, erase, splitting a block and moving instructions are O(1) relinks, so every
LLVM mutation API (`insertBefore`, `moveBefore`, `splitBasicBlock`, `eraseFromParent`, `splice`) ports one to one
and keeps LLVM's order. `extra` points at an opcode-specific cold record (GEP source type, alloca type, call function
type + calling convention + attribute list + bundles, load/store alignment and atomic ordering, …). `flags` is the
poison-generating flag byte (`nuw nsw exact disjoint nneg samesign inbounds…`), `fmf` the fast-math byte, `sub8` /
`sub32` hold predicates, alignment exponents, tail-call kinds and similar "subclass data".

**Erasing** unlinks the record, drops its operands (unlinking each `Use`), marks `vals[v].kind = DEAD`, and pushes the
id on a free list that `new_inst` reuses. Ids are therefore *not* stable across an erase: a pass that wants to
remember an erased instruction must not keep its id (LLVM's `WeakVH` semantics, see §5).

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

- A pass is a plain function over ids: `fn instsimplify(f: i32) -> bool`. The pass manager is an `enum Pass`
  and a `match` (no function pointers), parsed from `-passes=` text, with LLVM's nesting
  (module → CGSCC → function → loop adaptors) and the same order of running and of `-opt-bisect-limit` counting.
- Per-pass state lives in **locals of the pass's (non-recursive) entry function**: side tables indexed by value id
  (`var seen: bool[>..]`, sized to `vals.len`), worklists (`i32[>..<]`), and maps. They're freed when the pass
  returns. Helpers that need them take them by reference or are nested functions of the entry.
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

- Ids are recycled after erase: never keep an id of something that may be erased (use a handle).
- Append-only pools leak dead operand runs, types and constants until exit (see §2.4).
- A single global state means one module "context" per process. `llvm-link` has to load all inputs into it, which
  matches LLVM (all modules share one `LLVMContext`).
