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
- `x86_fp80` bit patterns whose explicit integer bit disagrees with the exponent are NaNs to APFloat
  (`initFromF80LongDoubleAPInt`): exponent 0x7FFF with a significand other than 0x8000000000000000 (pseudo-NaN,
  pseudo-infinity), and *unnormals* (exponent neither 0 nor 0x7FFF, integer bit 0). So a load of `x86_fp80` from
  `{i64 123, i64 112312312}` folds to bits `0xBFF8_000000000000007B` and prints as `-snan(0x7B)`
  (InstSimplify/ConstProp/loads.ll, visible only in an unnormalized printer output such as `print<memoryssa>`).
- `APFloat::toString` first divides the exact decimal significand by 10^k (truncating) and then rounds the digit
  string half-up, so it is not `printf("%.6e")`; port `AdjustToPrecision` both steps.
- Decimal literals are converted directly to the target type (one rounding); old-style `0x` hex literals are a
  double bit pattern that is converted to `half`/`bfloat`/`float` and must be exact.

## More parser/printer facts (verified in impl/goose)

- **Numbered values may skip numbers.** `NumberedValues` only requires each new `%N` / `N:` / `@N` to be >= the next
  free number (`LLParser::checkValueID`: "expected to be numbered '%N' or greater"); `%0, %1, %3` is valid and the
  printer renumbers densely. tests/imported/llvm/Analysis/LoopAccessAnalysis/evaluate-at-symbolic-max-backedge-taken-count-may-wrap.ll.
- **Unknown attribute groups are ignored**: a `#N` with no `attributes #N = {...}` merges nothing
  (`validateEndOfModule` looks it up with `find`). An `align=N` inside a function's group becomes the function's
  alignment (`align N` after the signature), not an attribute.
- **`declare` takes its metadata attachments right after the keyword** (`declare !dbg !1 void @f()`), `define` after
  the signature; the printer mirrors this.
- **Undeclared `llvm.*` callees** are declared at the end of parsing in *name order* (`ForwardRefVals` is a
  `std::map`), appended to the function list, each use re-pointed in use-list order.
- **opt infers the data layout from the triple** when the IR has none (`optdriver.cpp` `SetDataLayout` →
  `Triple::computeDataLayout`, `lib/TargetParser/TargetDataLayout.cpp`): `target triple = "x86_64-unknown-linux-gnu"`
  alone prints `target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"`,
  macOS gets `-m:o`, `i386` linux `e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128`.
  It also changes default alignments of `load`/`store`/`alloca` without `align`.
- **A uniqued node that refers to itself** (`!1 = !{!1, !2}`) cannot be uniqued and prints as `distinct !{...}`
  (tests/imported/llvm/Analysis/ScopedNoAliasAA/basic-domains.ll).
- **C comments**: the printer writes `/* (nan) */` before the class-mask argument of `llvm.is.fpclass` calls
  (`Intrinsic::printImmArg`, the only x86-relevant `ArgInfo<..., [ImmArgPrinter]>` in `Intrinsics.td`), so the lexer
  must skip `/* ... */`. tests/e2e/O0/float/float_compare.ll.
- **Operand order** (it decides use-list order): `CondBr` = [cond, true dest, false dest] (LLVM 23 splits `br` into
  `UncondBr`/`CondBr` opcodes 2 and 3); `switch` = [cond, default, (value, dest)*]; `call` = [args..., bundle
  inputs..., callee]; PHI incoming blocks are *not* operands (no block uses), so `; preds` never counts PHIs.
- **ConstantData has no use list** in LLVM 23 (`Value::hasUseList()` is `!isa<ConstantData>`): ints, FP, null,
  undef/poison, zeroinitializer, data arrays/vectors never record users.
- **Growing a PHI or switch** (`User::growHungoffUses`) copies each `Use` with `Use::operator=`, i.e. `set()`, which
  pushes the new use at the head of its value's list in operand order, then destroys the old ones. Capacity grows
  to `n + n/2` (min 2) for PHIs and `n * 3` for switches. Only matters to passes (the parser reserves exactly).
- Constant expressions are folded when created (`getelementptr inbounds ([16 x i32], ptr @a, i32 0, i64 0)` prints
  as `@a`; `ConstantFold.cpp` via `ConstantExpr::get*`), the `"PIC Level"` module flag's behavior is upgraded from
  7 (Max) or 1 (Error) to 8 (Min), and `llvm.lifetime.start/end` calls lose their size argument (AutoUpgrade).
  All three are handled in impl/jai (constfold.jai, autoupgrade.jai).

## AutoUpgrade, constant folding and debug info at parse time (verified in impl/jai, L0.print-imported COMPLETE)

- **End-of-module order** (LLParser::validateEndOfModule): attribute groups, auto-declared intrinsics (name order;
  a use whose call type is a valid signature gets `Intrinsic::getOrInsertDeclaration` with the *mangled* name, e.g.
  `@llvm.smin(i32 ...)` -> `@llvm.smin.i32`; otherwise a temporary function goes through
  UpgradeIntrinsicFunction/UpgradeIntrinsicCall), metadata cycles, DISubprogram::cleanupRetainedNodes, TBAA tag
  upgrade, UpgradeCallsToIntrinsic for every function (`make_early_inc_range`: functions appended meanwhile are
  visited), UpgradeDebugInfo, UpgradeModuleFlags.
- **Intrinsic attributes are set only when the signature is valid** (`UpgradeIntrinsicFunction` checks
  `Intrinsic::isSignatureValid`); a declaration with an invalid signature keeps its written attributes.
  Declarations are remangled (`remangleIntrinsicFunction`) when the name's suffix doesn't match the types
  (`@llvm.masked.compressstore.v16f32` -> `.v16f32.p0`, `@llvm.scmp.v16i8.16i8` -> `.v16i8.v16i8`).
- **Call operands are *set* in the order args, [dests], callee, bundle inputs** (CallInst/InvokeInst/CallBrInst::init
  then populateBundleOperandInfos) even though bundle inputs sit before the dests/callee; it decides use-list
  order when a value is both an argument and a bundle input.
- **Debug intrinsics become debug records**: calls to `llvm.dbg.value/declare/assign/label` are replaced by
  `#dbg_*` records before the call (upgradeDbgIntrinsicToDbgRecord) and the declarations are erased. An erased
  instruction's records move to the front of the next instruction's records (DbgMarker::removeMarker).
- **Debug info is stripped without `"Debug Info Version"` 3** (UpgradeDebugInfo -> StripDebugInfo: `llvm.dbg.*`
  named metadata, function/global/instruction `!dbg`, records, `heapallocsite`/`DIAssignID`, DILocations in loop
  IDs). With version 3 the Verifier runs and *broken* debug info is stripped too, with
  `warning: ignoring invalid debug info in <file>` on stderr; e.g. a call to a defined, non-interposable function
  with a subprogram, inside a function with a subprogram, without `!dbg`
  (tests/imported/llvm/Transforms/Inline/memprof_inline2.ll).
  Before that warning the Verifier prints each finding (it doesn't stop at the first: `CheckDI` returns from the
  one visit only), e.g. `inlinable function call in a function with debug info must have a !dbg location` and then
  the instruction (`  %call2 = call noundef ptr @_Z3bazv()`), printed with a `ModuleSlotTracker(&M)` that numbers
  all metadata *before* stripping. A version other than 3 prints `warning: ignoring debug info with an invalid
  version (N) in <file>` only when StripDebugInfo changed something: named `llvm.dbg.*`/`llvm.gcov` metadata or a
  function/global/instruction `!dbg` (AutoUpgrade.cpp UpgradeDebugInfo, DebugInfo.cpp StripDebugInfo;
  DeadStoreElimination/merge-stores.ll, Inline/memprof_inline2.ll under any analysis printer).
- **opt enables ODR uniquing of debug types** (tools/opt/optdriver.cpp `Context.enableDebugTypeODRUniquing()`):
  a `!DICompositeType` with an `identifier:` is created distinct and later ones with the same identifier and tag
  return it (DICompositeType::buildODRType), so uniqued input nodes print as `distinct`
  (tests/imported/llvm/Transforms/SROA/dbg-single-piece.ll).
- **Metadata numbering of debug records**: per instruction, its records first (location if it is an MDNode, the
  variable, for `#dbg_assign` the DIAssignID and an MDNode address, then the DILocation), then the instruction's
  intrinsic metadata operands and attachments (SlotTracker::processFunctionMetadata). `!DIExpression` never gets a
  slot and always prints inline; `!DIArgList` is not an MDNode (inline only, values only).
- **DI node operand order is not the printed field order**: e.g. DISubprogram operands are [file, scope, name,
  linkageName, type, unit, declaration, retainedNodes, containingType, templateParams, thrownTypes, annotations,
  targetFuncName] (DebugInfoMetadata.cpp getImpl); depth-first numbering follows the operands.
- **MetadataAsValue canonicalizes** (canonicalizeMetadataForValue): `metadata !{null}` becomes `!{}` and
  `metadata !{i32 0}` becomes `i32 0` (tests/imported/llvm/Transforms/LoopIdiom/debug-line.ll).
- **`uselistorder <ty> <v>, {i...}`** stable-sorts v's use list so that the use currently at position k moves to
  position i[k]; it is applied immediately (not printed back by `opt -S`).
- **`alloca` without `addrspace(N)` is in address space 0**, not the DataLayout's `A` (LLParser::parseAlloc).
- **Consecutive `module asm` lines merge** into one fragment (Module::appendModuleInlineAsm), printed as one
  `module asm` followed by one indented string per line; comdats are separated by blank lines.
- **ppc_fp128 constants** print bitwise (`f0x` + 32 hex digits, second double first) unless the second double is
  +0.0; then they print like that double, but decimal only if the 6-digit string denotes exactly that double.
- **Inline asm callees always have type `ptr`** (addrspace 0), so `call addrspace(0)` is printed in modules whose
  program address space is not 0; functions and calls default to the DataLayout's program address space `P`.
- **Target extension types take size/alignment from their layout type** (Type.cpp getTargetTypeInfo:
  `spirv.*` -> ptr, `aarch64.svcount` -> `<vscale x 16 x i1>`, ...), visible in default `align` of loads/allocas.
- **`gc.relocate` calls get a comment** `; (%base, %derived)` (AssemblyWriter::printGCRelocateComment).


## More parse-time facts (verified in impl/goose, L0.print-imported)

- **Intrinsic tables come straight from TableGen**: `llvm-min-tblgen -gen-intrinsic-impl` builds from
  `/opt/llvm-project-23.1.5/llvm` without CMake (impl/goose/tools/build_min_tblgen.sh: compile lib/Support,
  lib/TableGen, lib/Demangle, utils/TableGen/Basic with hand-made Config headers and stubs for the missing
  `third-party/siphash` and libc `shared/math.h`). Its IntrinsicImpl.inc holds the name table, IIT signature
  encodings, overload bits and attribute sets that Intrinsics.cpp uses (impl/goose/tools/gen_intrinsics.py).
- **`0xL` (fp128) and `0xM` (ppc_fp128) literals**: the first 16 hex digits are the *low* 64-bit word of the APInt
  (LLLexer::HexToIntPair; for ppc_fp128 that is the first double). `f0x` output prints the high word first.
- **A uniqued node whose operand resolves to itself becomes distinct** (`!0 = !{!0}` prints `distinct !{!0}`), but
  longer uniqued cycles stay uniqued (`!0 = !{!1}`, `!1 = !{!0}` print as written).
- **Uniqued nodes that become equal once forward references resolve are merged** (re-uniquing on operand change):
  `!7 = !{!"foo", !0}` and `!9 = !{!"foo", !0}` are one node.
- **Global objects keep several attachments of one kind** (`!type !0, !type !1`; GlobalObject::addMetadata),
  stable-sorted by kind; instructions keep only the last (setMetadata).
- **Old scalar TBAA tags are upgraded** (UpgradeTBAANode): `!tbaa !N` with `!N = !{!"int", !root}` becomes
  `!{!N, !N, i64 0}` (a 3-operand scalar tag `!{name, parent, i64 const}` becomes `!{!S, !S, i64 0, const}`).
- **Module flag behaviours are upgraded**: "PIC Level" Error(1)/Max(7) -> Min(8), "PIE Level" Error -> Max,
  "branch-target-enforcement"/"sign-return-address*" Error -> Min (UpgradeModuleFlags).
- **`%T = type <non-struct>`** makes `%T` an alias of that type (never printed); only struct bodies define types.
- **Function `align N` may appear among the function attributes** (even after `#0`); it becomes the function's
  alignment, not an attribute.
- **Aggregate canonicalization**: a struct of all-`undef` becomes `undef` only if no element is `poison`
  (`{ i32 undef, i32 poison }` stays); arrays/vectors fold to undef/poison/zeroinitializer only when all elements
  are the *same* constant.
- **`denormal_fpenv`** is an int attribute: `default | f32 << 4`, mode = `input << 2 | output` with ieee=0,
  preservesign=1, positivezero=2, dynamic=3; printed `denormal_fpenv(out[|in])`, with `float: m` (and the default
  mode only when it is not ieee) when the f32 mode differs.
- **Typed pointer syntax is still accepted**: `T*` and `T addrspace(N)*` parse as `ptr`/`ptr addrspace(N)`; only
  `ptr*` is an error.
- **Aliases take their address space from the aliasee's pointer type** (GlobalAlias::create).
- **Calling convention keywords**: the printer's names (printCallingConv) are also the parser's; `avr_intrcc` and
  `avr_signalcc` print with a trailing space.
- **A float/half/bfloat hex literal holding a signaling NaN stays signaling** (LLParser re-creates the sNaN after
  the double -> float conversion, which would quiet it); constant-folded conversions quiet NaNs.
- **MetadataAsValue of a forward-referenced local** (`metadata i32 %5` before `%5` is defined) is fixed up when the
  local is defined (ValueAsMetadata::handleRAUW).
