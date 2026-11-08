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
  intrinsics.jai  intrinsic-ID table and the attributes Intrinsic::getAttributes attaches to declarations
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
`u_prev == NONE` means "I am the head"), `u_aux` (phi incoming block; not part of any use list, matching LLVM where
a phi's block list is not a `Use`). A user's operands are a contiguous range `v_ops .. v_ops+v_nops`; `v_cap` is the
reserved capacity. Growing past capacity (phi `addIncoming`, `switch` `addCase`, call rebuilding) relocates the range
to the end of the table and patches the neighbours' `u_next/u_prev` and list heads; this mirrors LLVM's hung-off
operand reallocation, which also preserves use-list positions.

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

`m_kind` (STRING, VALUE (ValueAsMetadata; constant or local), TUPLE (generic `!{…}`), specialized DI* nodes later),
`m_distinct`, `m_ops`/`m_nops` into an `md_ops` pool (`Md_Id`, NONE = null operand), `m_str`. Uniqued nodes are
interned by content in a `Table`; distinct nodes never are. Instruction/global attachments are rows
`(kind_id, Md_Id, next)` in an `attach` table. Kind ids: the fixed kinds of `FixedMetadataKinds.def` (dbg = 0,
tbaa = 1, …) pre-registered, custom kinds registered in order of first appearance, exactly like `LLVMContext`.
Named metadata is an ordered array of `(name, [Md_Id])` on the module.

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
  `removeIncomingValue` keeps them in lockstep (LLVM's order-preserving removal is reproduced: later entries shift
  down, which moves uses between rows; we re-point the use-list links of moved rows).

Analyses (dominator tree, loop info, …) are separate tables keyed by block id and built on demand into the temporary
allocator or a per-analysis arena; passes invalidate them explicitly, mirroring the new-PM preserved-analyses sets.

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
