# Textual IR: what `opt -S` (LLParser + AsmWriter) does to a module (LLVM 23.1.5)

Facts needed to make a parse+print round trip byte-identical. Sources: `llvm/lib/AsmParser/LLParser.cpp`,
`llvm/lib/IR/AsmWriter.cpp`, `llvm/lib/IR/TypeFinder.cpp`. Each was verified by a passing `::roundtrip` test
(tests/roundtrip, tests/e2e, tests/function) in impl/jai unless said otherwise.

## Order of things

- **Use lists are LIFO.** `Use::addToList` pushes at the front, so `; preds = ...` lists predecessors in reverse
  order of the branches that were parsed. clang's printed `; preds = %0, %6` comes back from `opt -S` as
  `; preds = %6, %0` (tests/e2e/O2/arith/compare.ll). Blocks are created at their first reference (no placeholder),
  so their uses are simply LIFO.
- **Forward-referenced local values** get a placeholder that is RAUW'd at the definition. `doRAUW` takes the head use
  each time, so the moved uses end up in *parse order*, ahead of uses added later.
- **Forward-referenced globals** (`@f` used before its definition) get an unnamed `i8` placeholder GlobalVariable
  appended to the global list, RAUW'd and erased at the definition. Module order is therefore definition order.
  Constant users of the placeholder are re-uniqued (`handleOperandChange`).
- **Block order** is definition order: a forward-referenced block is created at the end of the function and moved to
  the end again when its label is parsed.
- **Named struct types** are printed only if reachable (TypeFinder over globals, initializers, aliases, ifuncs,
  function types/attributes/operands/args/instructions/metadata, named metadata), in DFS pre-order (subtypes pushed
  in reverse). Unused `%t = type ...` definitions disappear (tests/roundtrip/types/aggregates.ll).
- **Comdats** printed are only the used ones, functions' comdats before globals' (`Module::global_objects()` is
  functions then globals).
- **Attribute groups `#N`**: first every global variable's attribute set and every function's function-attribute set
  in module order (`SlotTracker::processModule`), then call-site function-attribute sets as each function is printed.
  So a set used only by calls gets a number after all function sets.
- **Metadata `!N`**: named-metadata operands first (and global-variable/ifunc attachments, in module order), then per
  function *while it is printed*: function attachments, then per instruction the MDNode operands of calls to
  intrinsics and the attachments. Numbering is depth-first pre-order over node operands. MDStrings and
  ValueAsMetadata get no number. tests/roundtrip/metadata/named_and_attached.ll.
- **Attachments on one instruction** print sorted by kind id (stable): fixed kinds from `FixedMetadataKinds.def`
  (`dbg`=0, `tbaa`=1, `prof`=2, `range`=4, `llvm.loop`=18, ...), custom kinds in order of first appearance.
- **Attributes inside a set** are sorted by kind enum, then string attributes by key. The enum order is TableGen's:
  all `EnumAttr` records sorted by *record name* (ASCII, so `NoUndef` < `NonNull`), then `TypeAttr`, `IntAttr`,
  `ConstantRangeAttr`, `ConstantRangeListAttr`. Example: `noundef nonnull dereferenceable(1)`.

## Things the parser changes

- `nocapture` becomes `captures(none)`. Legacy function attrs `readnone`/`readonly`/`writeonly`/`argmemonly`/... become
  `memory(...)`.
- **Intrinsic declarations get `Intrinsic::getAttributes`**, replacing *all* their declared attributes (function, return
  and parameter). This happens at the end of parsing (`UpgradeIntrinsicFunction` from `validateEndOfModule`).
  `declare void @llvm.memcpy...(ptr noalias nocapture writeonly, ...)` prints as
  `(ptr noalias writeonly captures(none), ...) #0` with `#0 = { nocallback nofree nosync nounwind willreturn
  memory(argmem: readwrite) }`. Intrinsic names come from `def int_*` records unless the record gives an explicit
  `"llvm.*"` name (`int_vastart` is `llvm.va_start`).
- **Default alignments are filled in**: `load`/`store` without `align` get the DataLayout ABI alignment of the type,
  `alloca` the preferred alignment, `cmpxchg`/`atomicrmw` the store size. They are then always printed.
- `source_filename` defaults to the module identifier (the input path as given) when the file has none.
- Calls to an undeclared `llvm.*` function get an automatically created declaration.
- Integer literals are truncated/extended to the type (`i8 255` prints as `i8 -1`). `[N x i8]` of all zero bytes
  becomes `zeroinitializer`; arrays of i8 always print as `c"..."`.
- Vector constants: all-equal fp elements become a `ConstantFP` splat (`splat (float 1.000000e+00)`), all-equal
  non-zero ints a ConstantDataVector (also printed `splat (...)`), a vector of `ptr null` a vector
  ConstantPointerNull printed `splat (ptr null)`, all zero `zeroinitializer`.
- The lexer must not end an identifier at `:` inside `memory(argmem: read)` and `captures(ret: ...)`
  (`setIgnoreColonInIdentifiers`).

## Floating-point constants (new in LLVM 23 syntax)

- Decimal form `1.000000e+00` (APFloat::toString with precision 6, no padding) is used when it reparses to the same
  value; otherwise `f0x` + the full bit pattern of *that* type (`float` gives 8 hex digits, `double` 16). Infinities
  print as `+inf`/`-inf`, NaNs as `+qnan`/`-qnan` (only the quiet bit set) or `+nan(0x...)`/`+snan(0x...)` with the
  payload without the quiet bit. `half`, `bfloat`, `x86_fp80`, `fp128` use the same rules (old `0xH`/`0xK` forms are
  only accepted on input). Verified with `opt -S` on hand-written globals (`double 3.14159265358979` →
  `f0x400921FB54442D11`, `double 1234567.0` → `f0x4132D68700000000`, `double 123456.0` → `1.234560e+05`).
- `APFloat::toString` first divides the exact decimal significand by 10^k (truncating) and then rounds the digit
  string half-up, so it is not `printf("%.6e")`; port `AdjustToPrecision` both steps.
- Decimal literals are converted directly to the target type (one rounding); old-style `0x` hex literals are a
  double bit pattern that is converted to `half`/`bfloat`/`float` and must be exact.
