# impl/jai notes

- The compiler (beta 0.2.030) isn't in the workspace image, because its download URL is private. `build.sh` calls
  `scripts/ensure-jai.sh`, which installs it once into `/persistent/toolchains/jai` from the `JAI_COMPILER_URL`
  environment variable. Never write that URL into the repo, reports or logs. If it's missing, stop and say so in a
  challenge report.
- Docs: `/persistent/toolchains/jai/how_to/*.jai` (numbered tutorials), `README.txt`, `CHANGELOG.txt`, and the module
  sources in `/persistent/toolchains/jai/modules`. Training data for Jai is thin and the language changes between
  betas, so check against the how_to files and modules rather than relying on memory.
- `build.sh` compiles each `src/<tool>.jai` with the x64 backend (`-x64`): about 0.5 s for `opt`. The LLVM backend
  with `-o` takes ~6.5 s per tool but the result parses+prints sqlite3.ll in 0.26 s vs 1.5 s for the x64 build
  (LLVM's opt: 0.36 s). `perf` numbers from the default build are therefore ~5-9x LLVM for parse+print; that's the
  backend, not the algorithms (scaling exponents are all ~1.0). Switch build.sh to `-o` when speed matters.

## Layout of the code

- `src/opt.jai` `#load`s the shared core: `ir.jai` (tables, use lists, RAUW, interning), `apfloat.jai` (bignum,
  APFloat decimal printing/parsing, IEEE arithmetic/compare/conversions), `apint.jai`, `datalayout.jai`,
  `lexer.jai`, `parser.jai`, `printer.jai`, `intrinsics.jai` (intrinsic IDs, signature matching, mangling,
  declarations), `autoupgrade.jai` (AutoUpgrade.cpp + a small constant-folding IRBuilder), `constfold.jai`
  (ConstantFold.cpp), `debuginfo.jai` (DI* nodes, debug records, StripDebugInfo). `llc.jai` and `llvm_link.jai`
  are still stubs; they should `#load` the same files.
- Generated tables (do not edit, rerun the script):
  - `gen_attrs.jai` (`gen/gen_attrs.py`: attribute kinds in TableGen order from Attributes.td),
  - `gen_cc.jai` (`gen/gen_cc.py`: calling conventions),
  - `gen_iit.jai` (`gen/gen_iit.py`: every intrinsic of Intrinsics.td + IntrinsicsX86.td with its decoded
    IITDescriptor list, in IntrinsicNameTable order; the script contains a small lazy TableGen evaluator, see
    its docstring),
  - `gen_intrinsics.jai` (`gen/gen_intrinsics.py`: the attributes the oracle prints for every intrinsic
    declaration in `opt -S` of any file in `tests/`, keyed by the names gen_iit.py evaluates; a return
    `range(iN ...)` is stored as `range(i@ ...)` and gets the return width at run time). An intrinsic that isn't
    in that table fails loudly when a declaration is created: add a test that uses it and rerun the script.
    (A faithful replacement: compute the attributes from IntrProperties like IntrinsicEmitter, or read
    `/persistent/llvm-rewrite/min-tblgen/IntrinsicImpl.inc` that impl/goose's `tools/build_min_tblgen.sh` builds.)
  - `gen_dwarf.jai` (`gen/gen_dwarf.py`: DW_TAG/ATE/LANG/LNAME/VIRTUALITY/CC/OP/MACINFO name tables from
    Dwarf.def, DIFlag/DISPFlag tables in DebugInfoFlags.def order, which is DINode::splitFlags' print order).

## Parser/printer: what is ported and where (L0.print-imported COMPLETE)

- End of module (parser.jai `validate_end_of_module`, LLParser::validateEndOfModule order): forward-referenced
  intrinsics are auto-declared in *name order* (ForwardRefVals is a std::map), per use, with mangling
  (`@llvm.smin(` -> `@llvm.smin.i32`) or via UpgradeIntrinsicFunction for invalid signatures; then metadata
  resolution, debug-record locations, DISubprogram::cleanupRetainedNodes, UpgradeTBAANode, UpgradeCallsToIntrinsic
  for every function (functions appended meanwhile are visited), UpgradeDebugInfo, UpgradeModuleFlags.
- AutoUpgrade: the generic upgradeIntrinsicFunction1 cases, remangling, named/packed struct returns, and the call
  rewrites for lifetime/memcpy/memset/masked.*/objectsize/ctlz/cttz/annotations/coro.end/convert.*/dbg.*.
  x86: shouldUpgradeX86Intrinsic is a mechanical translation (all names), but only the call rewrites the corpus
  needs are ported (scalar sse arith/sqrt, pmul(u)dq, vcvtph2ps, xop vpcom, bmi pdep/pext); every other x86
  rewrite, and x86 declarations with an old signature, fail loudly. Other targets' intrinsics are unknown names.
- Debug info: DI node kinds in debuginfo.jai `DI_Kind` (those in the corpus plus imported entity and template
  parameters); others fail loudly. Operands are kept in LLVM's operand order (it decides `!N` numbering), ints
  in a per-kind layout documented next to `parse_di_node`. DICompositeType with an identifier goes through
  buildODRType (opt enables the DITypeMap, so such nodes are distinct and merged by identifier).
  UpgradeDebugInfo strips debug info without "Debug Info Version" 3; of the Verifier's debug-info checks only
  "inlinable call without !dbg" is ported (a module that breaks other checks keeps its debug info, unlike LLVM).
- `uselistorder` directives reorder use lists at parse time (stable sort by index).

## Debug records and metadata uses (for passes)

- `Inst_Row.records` chains the debug records before an instruction; `erase_inst` moves them to the next
  instruction like DbgMarker::removeMarker (erasing a terminator with records is fatal).
- ValueAsMetadata does not create uses. The parser updates it when a forward-reference placeholder is resolved
  (`md_value_rauw`), but `replace_all_uses_with` does not (LLVM's ValueAsMetadata::handleRAUW): a pass that
  RAUWs values referenced by `#dbg_value` must call md_value_rauw too (or ir.jai should do it).

## Pass infrastructure status (see DESIGN.md §9-10)

- Passes: dce, adce (+ `-adce-remove-loops`, `-adce-remove-control-flow`), bdce, break-crit-edges; printers
  print<domtree>, print<postdomtree>, print<demanded-bits>; require<>/invalidate<> for domtree, postdomtree,
  demanded-bits. L1.analysis.domtree is COMPLETE. L1.dce: all checks that only need dce/adce/bdce pass; the rest need
  simplifycfg, sroa, gvn, licm (loop-mssa), instcombine, debugify, redundant-dbg-inst-elim, debug-info metadata,
  `--preserve-ll-uselistorder` printing or `--enable-knowledge-retention` (AssumeBundleBuilder), and fail loudly.
- Cross-checked beyond the corpus: dce, adce, adce -adce-remove-loops, bdce and break-crit-edges output, and
  print<domtree>/print<postdomtree> (also after break-crit-edges and adce with cached trees), are identical to LLVM's
  on every imported test that round-trips (6635 files), except BDCE on `InstCombine/known-bits.ll` (assume-based
  known bits).
- **Sweep beyond the unit's tests** (found 6 bugs the unit tests didn't): for every round-tripping imported file,
  run our opt and LLVM's with the same pipeline and compare canonicalized IR (`llvm-as | llvm-dis`) or, for
  printers, stderr (sorted for demanded-bits):
  `grep ::roundtrip impl/jai/passing.txt | sed 's/::roundtrip//' | grep imported | xargs -P8 -I{} cmp.sh "-passes=adce" {}`
  where cmp.sh runs both tools into a temp dir and prints OK/DIFF/JAI-FAIL. Do this for every new pass.
- **known_bits.jai is a partial computeKnownBits**: no assumptions/dominating conditions, no isKnownNonZero, no
  mul/div/rem/intrinsics/abs/min/max, no getKnownBitsFromAndXorOr idioms, no adjustKnownBitsForSelectArm, no
  computeKnownBitsAddSub dom-condition refinement. print<demanded-bits> matches LLVM (unordered) on 6538 of 6635
  files; the rest are these gaps or intrinsic-name upgrades. Note that missing known bits is *not* always
  conservative for BDCE: an operand with fewer known bits can look dead (`and 0, %phi`). Replace the file with the
  full ValueTracking port when InstSimplify/InstCombine need it.
- TLI: only what DCE/ADCE need (MemoryBuiltins' new/delete/strdup tables, allockind, isMathLibCallNoop with host
  libm + fenv via `#foreign`, "no-builtins"/"no-builtin-<f>"). Its `getLibFunc` prototype checks are simplified.
- Debug info: salvageDebugInfo/dbg-record dropping are no-ops; the parser now creates debug records
  (`Inst_Row.records`, see "Debug records" above), so passes that delete or move instructions must handle them.
- Perf (x64 build, sqlite3.ll, `-disable-output`): parse 1.01 s (LLVM 0.28 s); dce +0.0 s (LLVM +0.0), adce +0.23 s
  (LLVM +0.01), bdce +0.31 s (LLVM +0.03), require<domtree>,require<postdomtree> +0.01 s. ADCE/BDCE cost is in
  `Table` lookups and temp APInt allocation (every APInt op allocates); no `@perf` benchmark times these passes, so
  nothing in `harness/run perf` covers them yet.

## Jai traps hit so far

- `return f()` where `f` returns two values is an error ("Not enough return values"): write
  `a, b := f(); return a, b;`.
- Inside a `#expand` macro, `return` returns from the macro; use `` `return`` for the caller (we used plain
  procedures instead). Jai has no `break` out of an `if x == { case ...}`; wrap it in `for 0..0 { ... }`.
- Positional struct literals `.{a, b}` must give every field, even ones with defaults.
- Code is only type-checked when reachable: a new file compiles cleanly until something calls into it.

- **`cast(T) x << y` casts the whole shift**: `cast(u64) 1 << 63` computes `1 << 63` as s64 and then fails the
  cast check; `cast(u64) a << 32` with a u32 `a` shifts in 32 bits (silently 0). Write `(cast(u64) 1) << n`.
- `x := NONE` gives `x` type s64 (NONE is an untyped constant); write `x: Value_Id = NONE`.
- `for * CONST_ARRAY` iterates a temporary copy: a pointer into a `::` constant array dangles. Copy constant tables
  into a `[..]` array before handing out pointers (passes.jai `pass_table`).
- Procedure names are global across all `#load`ed files and only type-checked when used: a duplicate name added by
  another agent shows up as an "ambiguous overload" error in code that didn't change.
- `table_find` returns `(found, value)`; `found, x := table_find(...)` order matters (we got it backwards twice).

- `for i: 0..n-1` with an unsigned `n == 0` underflows and loops ~4 billion times (and then hits a bounds check).
  Loops over `u32` counts are written `if n > 0 for i: 0..n-1`, or the bound is cast to `s64`.
- `Basic` already defines `is_alpha`, `is_digit`, `is_alnum` (and its `is_alnum` includes `_`!). The lexer uses its
  own `c_isalpha` / `c_isdigit` / `c_isalnum` / `c_isxdigit` with C semantics.
- `is_constant` is a compiler builtin name; declaring a procedure with that name gives a baffling "'(' expected".
- A parameter named like a procedure (`print_type: bool`) shadows the procedure inside the body.
- `ifx c then #char "a" else #char "b"` is `s64`, not `u8`: cast the first branch.
- `NewArray(n, T,, allocator = temp)` / `alloc_string(n,, allocator = temp)`: the allocator goes through the `,,`
  context syntax, not a parameter.
- `Hash_Table.table_find` returns `(found: bool, value)` in this beta (bool first).
- Interning keys are built in shared scratch buffers (`tmp_key` for constants, `type_key`, `md_key`,
  `attr_key_buf`). Never build one key and then call something that interns another kind of thing before the
  lookup (that bug made all `blockaddress` constants of a function the same).

## Design debts

- Instruction payloads live in one fixed-width `Inst_Row` (alignment, orderings, types, attribute list, u32-pool
  indices) instead of per-opcode side tables; fine for now (~64 bytes per instruction). `Inst_Row.addrspace`
  doubles as the number of indirect destinations of a `callbr`.
- MetadataAsValue rows are interned by metadata id at creation; canonicalizeMetadataForValue at resolution time
  rewrites `v_aux` without re-interning, so two MD_VALUE constants can denote the same metadata.
- constfold.jai: the `and (ptrtoint @g), C` alignment fold (needs DataLayout) fails loudly; ppc_fp128 arithmetic
  and conversions of non-double values fail loudly.
- Erased values keep their rows (`v_kind = DEAD`); nothing is compacted.

## mem2reg and SROA (L1.mem2reg 29/30, L1.sroa 57/61)

- Files: `pass_mem2reg.jai` (PromoteMemToReg; `promote_mem_to_reg(allocas, dt, ac)` is shared with SROA),
  `pass_sroa.jai` (SROA, PtrUseVisitor, Loads.cpp subset), `ssa_updater.jai` (SSAUpdater + LoadAndStorePromoter),
  `ir_builder.jai` (`Irb`: IRBuilder<ConstantFolder> with name prefix and debug-record adoption),
  `value_utils.jai` (`sv_*`: GEP constant offsets, stripInBoundsOffsets, stripAndAccumulateConstantOffsets),
  `dbg_records.jai` (record owner/erase/insert, findDbgUsers order, RAUW/deletion of ValueAsMetadata,
  DIExpression queries, DILocation::getMergedLocation, ConvertDebugDeclareToDebugValue).
- `Dbg_Record.owner` is maintained by `attach_records_before` and `erase_inst`; passes that move records must
  keep it. Use `rauw_with_metadata` / `erase_inst_with_metadata` (dbg_records.jai) instead of the plain ir.jai
  calls whenever debug records may refer to the value.
- Remaining failures: the Mem2Reg test with `instcombine`, SROA tests with `debugify`/`gvn` (unported passes),
  and SROA with a known vscale (`vscale_range(N,N)` + scalable loads/stores of fixed allocas) which fails loudly.
  Assignment tracking (`#dbg_assign`, DIAssignID) fails loudly everywhere (3 imported files in the sweep).
- Sweep (every round-tripping imported file, our output vs LLVM, canonicalized): mem2reg 6994/6994 identical;
  sroa, sroa<preserve-cfg>, sroa<aggregate-to-vector> 6989/6994 identical, the other 5 fail loudly (dbg_assign,
  known vscale).
- Perf (x64 build, tests/perf/scaling/allocas): mem2reg and sroa ~8-9x LLVM's CPU time, scaling exponent 1.12 /
  1.10 vs LLVM's 1.11 / 1.14. The ratio is the x64 backend plus Table-heavy bookkeeping; no algorithmic issue.
- Faithfulness traps found while porting: DenseMap bucket order of mem2reg's NewPhiNodes (emulated:
  `M2r_Phi_Map`), Twine "trivially empty" names (`name_ref` / `NAME_STRINGREF_EMPTY` in ir_builder.jai),
  `Instruction::insertBefore` adopting debug records (`insert_at_position`), `for < i: a..b` iterates b down
  to a (write the range ascending).
