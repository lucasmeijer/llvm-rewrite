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
- known_bits.jai was replaced by the full ValueTracking port (value_tracking.jai, see "InstSimplify" below).
- TLI: the full TargetLibraryInfo is in tli.jai (see "Library calls"); the MemoryBuiltins tables, isMathLibCallNoop
  (host libm + fenv via `#foreign`) and constant folding of libm calls consult it.
- Debug info: see "Debug info utilities" below (salvageDebugInfo is ported; dce/adce/bdce/instsimplify use it).
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

## Alias analysis and MemorySSA (L1.analysis.aa 234/237, L1.analysis.memoryssa 79/86)

- Files: `capture_tracking.jai`, `aa.jai`, `basic_aa.jai`, `tbaa.jai`, `scoped_noalias_aa.jai`, `globals_aa.jai`,
  `memoryssa.jai` (see DESIGN.md "Alias analysis and MemorySSA"). Remaining failures: `inferattrs` (3 BasicAA tests,
  pass not ported) and `loop-mssa(licm|loop-rotate|simple-loop-unswitch)` (7 MemorySSA tests).
- Sweep (every round-tripping file + tests/e2e + tests/function, ~7700 files; LLVM vs us on stderr):
  `aa-eval -print-all-alias-modref-info` (basic-aa, and default pipeline with `-evaluate-aa-metadata`),
  `require<globals-aa>,aa-eval`, `print<memoryssa>`, `print<memoryssa><no-ensure-optimized-uses>`,
  `print<memoryssa-walker>`, `-memssa-check-limit=3`: all identical except files where LLVM prints diagnostics
  (invalid debug info, unknown CPU features) or `%"type 0x…"` addresses, and 4 SCCP files with `!callback`
  (GlobalsAA's CallGraph fails loudly on callback calls). Sweep script:
  same scheme as "Sweep beyond the unit's tests" above (compare stderr of `-disable-output` runs).
- **For pass porters** (GVN, DSE, LICM, MemCpyOpt, EarlyCSE with MemorySSA):
  - `aar := aa_results_for(f)` once per pass run, then `q := aa_query_new(*aar)` per BatchAAResults (keep it for the
    pass if LLVM uses BatchAA; make a new one per query where LLVM calls `AA.alias(...)` on the AAResults directly).
    DSE/MemCpyOpt use `BatchAAResults(AA, &EI)`: `aa_query_new_earliest_escape(*aar, dt)`, and call
    `aa_query_remove_instruction(q, i)` where LLVM calls `EI.removeInstruction`.
  - Everything is in `temp`: an `Aa_Query` must not outlive the pass (reset_temporary_storage between passes).
  - CaptureTracking: `ct_use_capture_kind` is the full DetermineUseCaptureKind (operand bundles, `!captures`); the
    older `determine_use_capture_kind` in inst_simplify.jai fails loudly on those. `pointer_may_be_captured_before`
    has no LoopInfo/CycleInfo parameter yet (LLVM's callers that pass LI get more precise reachability).
  - MemorySSA: `get_memoryssa(f)` builds and caches it (heap). It survives a pass only if the pass preserves
    `.MEMORYSSA` and the DominatorTree survives (the AssumptionCache its BasicAA uses is rebuilt and re-pointed when
    freed, see fam_invalidate). Update it with the MemorySSAUpdater (mssa_updater.jai, LLVM's method names with
    `mssau_`); `verify<memoryssa>` / `-verify-memoryssa` run `mssa_verify`. No loop-scoped MemorySSA.
  - `mssa_clobbers_query` = instructionClobbersQuery, `mssa_def_clobbers_use_or_def` = MemorySSAUtil::
    defClobbersUseOrDef, `phi_translate_value` = PHITransAddr::translateValue (no select-condition variant yet; GVN's
    MemoryDependence needs that one).
- Shared fixes made here: `get_underlying_object`'s default MaxLookup is 10 (was 6); `gv_is_interposable` now
  includes `noipa` definitions and the SemanticInterposition module flag.
- Perf (x64 build): building MemorySSA on lua.ll +0.08 s, sqlite3.ll +0.19 s over parsing (LLVM: +0.02 s each).
  `printer_begin_function` used to re-run TypeFinder and process_module for every printed function (lua
  print<memoryssa> 8.7 s vs LLVM 0.9 s); it now keeps the module part and only drops the previous function's
  metadata / attribute-group slots (print<domtree> on tests/perf/scaling/globals/n8000.ll: 100 s -> 0.5 s).
- GlobalsAA: `UnknownFunctionsWithLocalLinkage` is forced false after computing, matching LLVM's move-constructor
  quirk (knowledge/llvm/alias-analysis-and-memoryssa.md).
- Jai trap: `print`/`tprint` treat every `%` as a placeholder (even `"%/"`); write a literal percent sign as
  `"\x1f"` (Basic's formatter prints byte 31 as `%`), see `aa_eval_report`.

## InstSimplify, ValueTracking, constant folding (L1.instsimplify 238/249)

Reusable analysis modules (all take a `Simplify_Query {dt, ac, cxt, use_instr_info, can_use_undef,
allow_ephemerals, have_tli}` by value; `sq_with_instruction` / `sq_without_undef` like SimplifyQuery's helpers):
- `apint.jai`: APInt with an inline u64 for <= 64 bits (no allocation on the common path), `w` words above.
  `knownbits.jai`: KnownBits.cpp. `constant_range.jai`: ConstantRange.cpp (`cr_*`). `cmp_pred.jai`: CmpInst
  predicate algebra, isImpliedByMatchingCmp. `pattern.jai`: PatternMatch (`pm_*`) + `APFloat` value struct.
- `value_tracking.jai` / `value_tracking2.jai`: computeKnownBits (`known_bits`, `known_bits_de`), isKnownNonZero,
  isKnownToBeAPowerOfTwo, ComputeNumSignBits, isKnownNonEqual, matchSelectPattern (integer part), isImpliedCondition,
  isImpliedByDomCondition, computeConstantRange, computeOverflowFor*, canCreate(Undef)OrPoison, impliesPoison,
  isGuaranteedNotToBe(Undef)OrPoison, getUnderlyingObject, strip*/accumulate offsets.
- `fpclass.jai`: KnownFPClass (`kfpc_*`), computeKnownFPClass (`compute_known_fp_class[_de][_fmf]`),
  fcmpImpliesClass / fcmpToClassTest, ConstantFPRange (`cfr_*`), FPClassTest helpers.
- `analysis_base.jai`: Simplify_Query, AssumptionCache (`ac_*`, kept current by `replace_all_uses_with` via
  `ac_note_rauw`), dominance helpers on instructions/edges/uses, isGuaranteedToTransferExecution.
- `const_folding.jai` (ConstantFolding.cpp: `cfo_*`, loads, GEP, casts, compares, FP denormal flushing),
  `const_folding_calls.jai` (canConstantFoldCallTo / ConstantFoldCall: every non-target intrinsic plus the x86 SSE/AVX512
  conversions, libm calls evaluated with the host libm under fenv/errno checks like LLVM, and the TLI subset it needs:
  names, prototypes with LDbl = any fp type, `*_finite` only on linux-gnu, no-builtin attributes,
  `-disable-simplify-libcalls`), `apfloat_ops.jai` (APFloat with rounding modes: fma, roundToIntegral, next,
  remainder, scalbn/ilogb/frexp, convertToInteger, min/max family; everything is computed exactly and rounded once).
- `inst_simplify.jai`: InstructionSimplify.cpp, entry points `simplify_instruction(i, q)`,
  `simplify_instruction_with_operands`, `simplify_with_op_replaced`, the `simplify_*_inst` functions (binops, cmps,
  select, GEP, casts, shuffles, FP ops incl. constrained, calls/intrinsics, loads, freeze, phi).
- Sweep (every round-tripping imported file, instsimplify, canonicalized vs LLVM): 6976/6994 identical, 18 fail
  loudly (11 salvageDebugInfo, 2 ppc_fp128 arithmetic, 2 computeConstantRange of frexp, x86 hadd known bits, capture
  tracking through bundles, funclets). The 11 unit failures need instcombine (5), early-cse (3, with
  -earlycse-debug-hash), loop-unroll, jump-threading, always-inline.
- Perf (x64 build, `-disable-output`, tests/perf/scaling): linear in size; straightline n64000 0.52 s (no-op pipeline
  0.32 s, LLVM instsimplify 0.10 s), diamonds n8000 0.51 s (0.36 / 0.11). Pass cost ~2x LLVM's whole run; parsing
  dominates. No `@perf` benchmark runs instsimplify alone.
- Representation facts that matter (all verified against the oracle, see knowledge/llvm/instsimplify-jai-sweep.md):
  fixed-length int splats are ConstantDataVector (a vector-typed C_INT only with
  `-use-constant-int-for-fixed-length-splat`), `ConstantInt::get(vec, 0)` is zeroinitializer, FP vector nulls and
  splats are vector-typed ConstantFP (`dyn_cast<ConstantFP>` succeeds on them), scalable int splats are kept as
  vector-typed C_INT (LLVM builds a shufflevector expression; prints the same, `get_splat_value` sees through both).
- Not ported (answers "don't know", or fails loudly where an answer would be wrong): DomConditionCache /
  CondContext (InstSimplify passes neither), the FP half of matchSelectPattern, ppc_fp128 arithmetic.

## Loops (L1.analysis.loops COMPLETE, L1.loop-canonical 58/92 ::opt)

- Files and APIs: see DESIGN.md "Loops". print<loopnest> is loop_nest.jai (needs ScalarEvolution).
- What fails loudly (and the remaining L1.loop-canonical checks): passes not ported (indvars,
  simple-loop-unswitch, loop-deletion, loop-unroll, loop-idiom, loop-reduce, `require<domfrontier>`), LoopRotate's noalias-scope cloning, key-instruction
  atom groups, DIArgList debug locations in remapping, `#dbg_assign`.
- LoopRotate's header-size check uses the real cost model: CodeMetrics `num_insts` from
  `tti_instruction_cost(TCK_CODE_SIZE)` (tti.jai); the old 0..2 cost bounds are gone.
- `isSafeToSpeculativelyExecute` (pass_loop_simplify.jai) has no load support (isDereferenceableAndAlignedPointer)
  and no context instruction; its callers here never need either (makeLoopInvariant rejects loads anyway,
  shouldSpeculateInstrs only accepts a fixed opcode list). Use ValueTracking's when it lands.
- Sweeps (tools/sweep.py, every round-tripping file + e2e/function, ~7780 files): `loop-simplify`, `lcssa`,
  `loop(loop-rotate)` IR identical to LLVM wherever we don't fail loudly (loop-simplify: all; loop-rotate: 35 fail
  loudly, mostly cost bounds); `loop-simplify,lcssa,print<loops>` and `print<cycles>` identical except files where
  LLVM prints diagnostics. `tools/fuzz_cfg.py` (random CFGs; adapted from impl/goose) ran 2000+3000 programs clean
  over loops/cycles/domtree printers and loop-simplify, lcssa, loop-rotate IR. Run both after touching any of
  these files: `python3 impl/jai/tools/sweep.py 'loop(loop-rotate)'`, `python3 impl/jai/tools/fuzz_cfg.py 2000 7`.
- Perf (x64 build, tests/perf/scaling/loops-many): `-passes=loop-rotate` 3.2x (n2000) to 5.5x (n8000) LLVM's CPU
  time, mostly parse/print; scaling exponent 1.06 vs LLVM's 1.11.
- `li_erase` of a nested loop (UnloopUpdater port) is untested: no test or fuzz case reaches it yet
  (SplitBlockPredecessors erases a loop only when a split makes it irreducible).
- Traps: `for < k: a..b` iterates b down to a, so reversing over an index range is `for < k: 0..n-1`; Jai's
  formatter needs `\x1f` for a literal `%` (`loop %header` in OptBisect names); procedure names collide across
  agents' files (`block_unique_predecessor`, `drop_ub_implying_attrs_and_metadata`, `ic_clone_inst` live in
  ic_core.jai and are reused here).
- MemorySSAUpdater (all but updateForClonedLoop / updateExitBlocksForClonedLoop) is ported; `loop-mssa(loop-rotate)`
  uses `dt_apply_updates_post_view` (DT.applyUpdates(Updates, PostViewUpdates)) through `mssau_apply_updates`, and
  `idf_calculate(..., gd)` for the GraphDiff IDF of applyInsertUpdates (forward children come in *reverse* successor
  order through a GraphDiff, even an empty one). Sweeps `loop-mssa(loop-rotate),print<memoryssa>` and
  `print<memoryssa>,loop-mssa(licm),print<memoryssa>` (-verify-memoryssa) are identical except 3 files whose
  differences are inliner diagnostics that every printer sweep shows.

## LICM (L1.licm 111/134 ::opt, L1.analysis.memoryssa 39/41)

- Files: pass_licm.jai (LICM.cpp incl. LNICM and ControlFlowHoister), must_execute.jai (ICFLoopSafetyInfo,
  InstructionPrecedenceTracking, colorEHFunclets), alias_set_tracker.jai, LoadAndStorePromoter hooks in
  ssa_updater.jai (`Lsp_Hooks`, kind SROA_BASIC / LICM), `split_block_predecessors(..., use_dtu = true)` (the
  DomTreeUpdater path of UpdateAnalysisInformation: Insert/Delete updates instead of DT->splitBlock).
- LNICM: a loop pipeline with only `lnicm` runs the adaptor in LoopNestMode (top-level loops only); `lnicm` in a mixed
  pipeline runs on the outermost loop of the current one (LoopPassManager::runWithLoopNestPasses).
- Remaining unit failures need other passes (gvn, loop-deletion, loop-unroll, simple-loop-unswitch, reassociate,
  loop-simplifycfg, early-cse<memssa>, make-guards-explicit, loop-sink (needs BlockFrequencyInfo)), plus
  `--enable-knowledge-retention` (salvageKnowledge / AssumeBundleBuilder, not ported).
- Fail loudly: sinking a call that has a funclet bundle or into a funclet (needs a funclet bundle added).
- Sweeps (every round-tripping file): `licm`, `loop-mssa(licm)`, `loop-mssa(lnicm)`, `licm -licm-control-flow-hoisting=1`,
  `loop-mssa(loop-rotate,licm)` all identical (2 loop-rotate loud failures). Rerun after touching LICM, MemorySSA or
  the updater, also with `print<memoryssa>` after it (`--analysis --extra=-verify-memoryssa`).
- Trap: LICM re-reads `L->getLoopPreheader()` in hoistArithmetics and promotion (ControlFlowHoister replaces the
  preheader); only the runOnLoop guard uses the original one.
- Perf (x64, tests/perf/scaling/loops-many, `opt -passes=licm`): 5.8x LLVM CPU at n8000 (parse/print dominate),
  fitted k 1.42 vs LLVM 1.18 (both in the "too little work" range). Value-handle RAUW/deletion scans every live handle
  of the current updater call; fine for loop bodies, a candidate if a huge function shows up.

## InstCombine (L1.instcombine.arith 68/115, bitwise 40/86 ::opt; DESIGN.md §11)

- Ported completely, in LLVM's order: the driver (InstructionCombining.cpp `prepareWorklist`/`run`/sinking/
  fixpoint verification), the shared binop folds, InstCombineAddSub.cpp (incl. FAddCombine and the FP visitors),
  InstCombineNegator.cpp, InstCombineMulDivRem.cpp (int and FP), the integer half of
  InstCombineSimplifyDemanded.cpp, `convertOrOfShiftsToFunnelShift`, `mergeStoreIntoSuccessor`.
- **Bitwise (L1.instcombine.bitwise 53/86 ::opt, arith 78/115)**: InstCombineAndOrXor.cpp (ic_andorxor.jai) and
  InstCombineShifts.cpp (ic_shifts.jai) are ported completely, in LLVM's order, plus the Local.cpp
  recognizeBSwapOrBitReverseIdiom/collectBitParts that visitOr needs. A function-by-function comparison of every
  InstCombine test (only functions using int binops/icmp) and a random differential fuzzer (~40k straight-line
  functions over and/or/xor/shifts/add/sub/icmp, scalar and `<2 x i8>` with poison lanes) show no difference left
  that comes from these files. The remaining bitwise failures need the cast visitors (`zext (trunc X)` -> `and`,
  `trunc (lshr X, C) to i1` -> bit test, canEvaluateTruncated), the call visitor (fshl/fshr amount folding,
  `range` on ctpop/cttz, umin/umax, is.fpclass -> fcmp), vector ops (shufflevector/extractelement/bitcast) and
  foldVectorBinop's unshuffleConstant. Tools: `python3 impl/jai/tools/ic_funcdiff.py <files>` (per-function
  LLVM-vs-us comparison of the functions whose bodies only use ported opcodes; edit its `PORTED` set as visitors
  land) and `python3 impl/jai/tools/fuzz_bitwise.py SEED COUNT`; rerun both after touching these files.
  Fail loudly: getInsertionPointAfterDef of invoke/callbr (freelyInvert),
  replaceUsesWithIf with a constant user.
- **Partial visitors** (ic_misc.jai: their comments say where they stop): casts (commonCastTransforms; zext/sext/trunc/[su]itofp flag folds), call (InstSimplify +
  nounwind inference), phi, gep, load, freeze, extractvalue, vector ops (InstSimplify only), terminators (ret,
  unreachable, br, condbr complete; switch not at all). A fold missing from these silently does not fire, so most
  arith tests that still fail do so because of folds in those files (select/cast/call canonicalizations).
- Fail loudly (grep `not supported yet` in ic_*.jai): sin/cos -> tan, convertFSqrtDivIntoFMul, `!annotation`
  metadata, transformCallThroughTrampoline, transformConstExprCastCall of an invoke, gc.statepoint, ptrauth.
  (SimplifyDemandedFPClass, LowerDbgDeclare, debug-user sinking/salvaging, visitAtomicRMWInst and the call half of
  transformConstExprCastCall are ported now: see "InstCombine: FP classes, debug info, per-function sweep".)
- Remaining arith failures that are not about other visitors: `sdiv-1` (cgscc inline), `storemerge-dbg`
  (debugify), `fptoui-of-fdiv` (ppc_fp128 folding), `sub-gep` (scalable GEP strides), `simplify-demanded-fpclass-fdiv`,
  `fsqrtdiv-transform`.
- `instcombine` runs a second iteration and fails like LLVM (`did not reach a fixpoint`) if it changes anything;
  with this partial port that usually means a missing fold that would have revisited an instruction in iteration 1
  (fold-vector-zero.ll: the unported `icmp slt (add X, C), C2` fold is what makes LLVM revisit and infer `nsw`).
- The Negator records its instructions through `negator` (global pointer) in `icb_insert`; anything that builds
  while it runs must go through `icb_*`.
- Shared changes: Simplify_Query has `dc: *Dom_Cond_Cache` (analysis_base.jai), used by computeKnownBitsFromContext,
  isKnownToBeAPowerOfTwo, isKnownNonEqualFromContext and computeKnownFPClassFromContext like LLVM; InstSimplify does
  not set it. `cl::opt`s: `-instcombine-code-sinking`, `-instcombine-lower-dbg-declare`,
  `-instcombine-max-sink-users`, `-instcombine-maxarray-size`, `-instcombine-negator-enabled`; `-mtriple X` (space
  form) is accepted.
- Perf (x64 build, tests/perf/scaling/straightline): `opt -passes=instcombine` is ~21x (~33x with the and/or/xor/shift visitors, which add known-bits queries) LLVM's CPU time (parse
  alone 4.4x), scaling exponent 1.05 (LLVM 1.09): linear. The time is ValueTracking (computeKnownBits /
  ComputeNumSignBits with temp-allocating APInt ops, ~60% inclusive), not the combiner.
- Jai traps: `xx` is the auto-cast operator, not an identifier; `for < k: 0..n-1` iterates n-1 down to 0 (the
  reverse of what the range text suggests if you write `n-1..0`, which silently runs zero times).

## InstCombine compares (L1.instcombine.cmp 114/154: roundtrip 77/77, opt 37/77)

- `ic_compares.jai` ports InstCombineCompares.cpp completely (icmp and fcmp, every helper, LLVM's order). The
  remaining cmp/arith failures were triaged function by function: they need other visitors (select, and/or/xor,
  shifts, casts, calls incl. assume/copysign/fabs, phi, freeze, gep, shufflevector), e.g. `icmp-logical.ll` is
  and/or-of-icmps, `fcmp-*select*` is the select visitor. Only `icmp-gep.ll` fails loudly (emitGEPOffset with
  scalable strides).
- Differential fuzzing (not in the repo; generator idea): random functions of add/sub/mul/div/rem with flags feeding
  one icmp (i8..i32), and fadd/fmul/fdiv/fneg/fabs/fpext feeding one fcmp, compared with LLVM per function: all
  remaining differences were traced to unported visitors (shl canonicalization, `not` → sub, select of
  `sdiv 1, x`, fmul flag inference). Avoid power-of-two constants and `x op x` to keep the noise down.
- Shared changes: `Capture_Tracker` has an `ALLOCA_CMP` kind (foldAllocaCmp's CmpCaptureTracker);
  `const_integer_value` handles pointer types (inttoptr, folded); `fp_convert` reports overflow to infinity and
  underflow to zero as inexact (it said exact; LLParser and fcmp-of-fpext folds depend on it).
- Traps: the ICMP_*/FCMP_* constants are untyped, so `ifx c then ICMP_EQ else ICMP_NE` is s64 and does not convert
  to `u8` (write `cast(u8)` on the first branch). LLVM's `isSignTest(Pred&, C)` updates the predicate even when the
  caller's other condition then fails; foldICmpMulConstant keeps using the updated predicate.

## ScalarEvolution (L1.analysis.scev 504/505; DESIGN.md "ScalarEvolution")

- Files: scev.jai (nodes, uniquing, folding constructors, printing, std::stable_sort), scev_create.jai (getSCEV /
  createSCEV, PHIs, selects, GEPs, the rewriters, memoization bookkeeping), scev_range.jai (ranges, constant
  multiples, no-wrap inference), scev_btc.jai (trip counts, exit limits, values at scopes, constant evolution,
  quadratic solvers, howFarToZero / howManyLessThans), scev_implied.jai (SimplifyICmpOperands, isKnownPredicate,
  isImpliedCond and helpers), scev_guards.jai (dispositions, loop finiteness, LoopGuards), scev_pred.jai (SCEV
  predicates, convertSCEVToAddRecWithPredicates, createAddRecFromPHIWithCasts), scev_update.jai (forget*, value
  handles), scev_print.jai (analysis result, printer, verify, cl::opts), scev_aa.jai, loop_nest.jai, iv_users.jai.
- The one missing check is `loop(indvars),print<scalar-evolution>` (IndVarSimplify is not ported).
- Sweeps (tools/sweep.py --analysis over ~7780 files, all identical except LLVM diagnostics lines and ValueTracking
  gaps (pdep/pext/ucmp known bits, extractelement of scalable splats)): `print<scalar-evolution>`,
  `loop(loop-rotate),print<scalar-evolution>`, `print<scalar-evolution>,loop(loop-rotate),print<scalar-evolution>`
  (checks that the forget* calls leave the cached SE exactly like LLVM's), `...,verify<scalar-evolution>`,
  `print<loopnest>`, `loop(print<iv-users>)`, `aa-eval -aa-pipeline=scev-aa -print-all-alias-modref-info`.
  Rerun them after touching any scev file or any pass that runs with a ScalarEvolution.
- verify<scalar-evolution> checks the bookkeeping invariants only; LLVM's recomputation in a second
  ScalarEvolution is not ported (it can only abort, which LLVM never does on a valid test).
- Not ported (fail loudly or unreachable from the printers): ScalarEvolutionExpander, PredicatedScalarEvolution
  (getAsAddRec, addPredicate), SCEVUnionPredicate, rewriteUsingPredicate, getLoopInvariantPredicate /
  getLoopInvariantExitCondDuringFirstIterations, isKnownMultipleOf, canReuseInstruction, SCEVUnknown with a null
  value after deletion is never printed. -scalar-evolution-use-expensive-range-sharpening fails loudly when the
  constant max trip count is unknown (LLVM reads the type of SCEVCouldNotCompute there).
- The AssumptionCache: LLVM never invalidates it (AssumptionCache::invalidate returns false), so a surviving SE
  must not be dropped when fam_invalidate frees and rebuilds our AC; the SE is re-pointed at the new AC instead.
- Perf (x64 build, print<scalar-evolution>): ~8-10x LLVM on tests/perf/scaling/loops-many (n500 1.0 s vs 0.12 s,
  n2000 47 s vs 4.8 s), the same super-linear growth as LLVM (loop guards collect every dominating exit condition of
  the 500 preceding loops into umin chains; GroupByComplexity's grouping is quadratic in LLVM too). The constant
  factor is the x64 backend plus Table lookups. (Modules with thousands of functions were dominated by the printer
  re-running process_module per function; fixed in print_util.jai, see "Alias analysis and MemorySSA".)
  loop-rotate now gets a ScalarEvolution from the loop PM: `perf 'tests/perf/scaling/loops-many/*'` k = 1.04
  (LLVM 1.11). No @perf benchmark times SCEV itself.
- Traps: `return f()` with several results, `for < i: a..b` order (gnu_merge_adaptive), Table key types, untyped
  ICMP_* constants in `ifx` (write `cast(u8) ICMP_EQ`), procedure-name collisions (`Select_Pattern`, `is_const_int`,
  `block_unique_successor`, `icmp_is_lt` existed already). value_tracking2.jai's `block_single_successor` has
  getUniqueSuccessor semantics; loop_nest.jai has the exact getSingleSuccessor (`block_get_single_successor`).

## InstCombine select and phi (L1.instcombine.select 76/98: roundtrip 49/49, opt 27/49)

- `ic_select.jai` ports InstCombineSelect.cpp completely, in LLVM's order. Helpers from other LLVM files that it
  needed and that are now shared: SimplifyDemandedVectorElts (`ic_simplify_demanded_vector_elts`, ic_demanded.jai;
  the X86 target intrinsic hook fails loudly), the FP half of matchSelectPattern + lookThroughCast/CastOp
  (`match_select_pattern_cast`, `match_decomposed_select_pattern_full`, value_tracking2.jai; plain
  `match_select_pattern` now also recognizes fcmp min/max), CondContext (`Simplify_Query.cc`, `Cond_Context`;
  dropped at every phi recursion like `getWithoutCondContext`), canIgnoreSignBitOfNaN.
- Fixed on the way: `const_is_element_wise_equal` (isElementWiseEqual) accepted non-constant/scalar operands and
  built constant expressions over instructions (corrupted use lists); hasPoisonGeneratingFlags of ctlz/cttz/abs
  with `i1 true`; dropUBImplyingAttrsAndMetadata now strips noundef/dereferenceable(_or_null) from calls.
- Remaining select failures were triaged: they need visitPHINode (phi of i1 constants → branch condition, then
  foldSelectToPhi), visitCall (min/max canonicalization, ctpop/ctlz range attributes), casts (trunc/zext/sext),
  GEP canonicalization (`gep i8`), shufflevector/extract/insertelement visitors, and the shift/and folds.
- Sweep (`sweep --passes instcombine`) vs main before this port: 168 files went differs→identical, 0 new silent
  mismatches except minmax-fold.ll (failed→differs: now runs, still differs elsewhere); 7 differs→failed (loud: X86
  SimplifyDemandedVectorElts intrinsics, unshuffleConstant, a fixpoint in assume-icmp-null-select.ll).
- `ic_phi.jai` ports InstCombinePHI.cpp completely (visitPHINode and every helper, LLVM's order). Shared pieces
  added there: `combine_metadata_for_cse` (Local.cpp combineMetadata; getMostGeneric{Range,AliasScope,NoFPClass,
  AlignmentOrDereferenceable}, MDNode::intersect, TBAA via tbaa_most_generic; merging !mmra/!prof/!memprof/
  !callsite/!llvm.access.group/!captures/!callee_type/DIAssignID fails loudly), `erase_unlinked_inst` (`delete I`).
  SliceUpIllegalIntegerPHI sorts its records stably (LLVM's array_pod_sort = qsort; glibc sorts small arrays by
  insertion sort). Sweep after the phi port: no file regressed from identical; 5 more fail loudly (2 fixpoint
  differences that need other visitors, !annotation, !mmra, !llvm.access.group).

## InstCombine casts, calls, X86 intrinsics (L1.instcombine.cast 29/40 ::opt; DESIGN.md §11)

- `ic_casts.jai` ports InstCombineCasts.cpp completely (LLVM's order); `ic_calls.jai` ports InstCombineCalls.cpp
  except the parts listed below; `ic_x86.jai` ports X86InstCombineIntrinsic.cpp completely (the 256-case
  ternary-logic table was generated from the C++ switch by a throwaway Python script: rerun the idea, don't hand-edit).
  Effect on the unit counts (::opt): cast 15→29/40, select 27→44/49, cmp 59→72/77, arith 78→96/115,
  bitwise 53→69/86; InstCombine directory 745→1290/1635, InstCombine/X86 1→51/55.
- Sweep `--passes instcombine` vs main before this work: identical 3603→6332 (also includes the memory unit's
  work landing meanwhile), no identical→differs; 20 identical→failed are loud X86-target or other fail-loud paths
  that the new code now reaches (gc.statepoint, ptrauth callee folds).
- Not ported in InstCombineCalls.cpp (fail loudly where they would act): `optimizeModularFormat`, the transform half of `transformConstExprCastCall` (the bail-outs
  are ported, so calls to declarations with a different prototype are fine), `transformCallThroughTrampoline`,
  ptrauth folds, `gc.statepoint`, `experimental.vp.reverse`, the ARM/AArch64/Hexagon intrinsic cases and every
  non-x86 TTI::instCombineIntrinsic (fails loudly only when the module triple selects that target),
  objectsize with `dynamic=true` (left alone: ObjectSizeOffsetEvaluator is not ported), AAMDNodes::adjustForAccess
  of `!tbaa`/`!tbaa.struct` in SimplifyAnyMemTransfer, DIAssignID updates.
- Shared changes: the `ptrmask` case of SimplifyDemandedUseBits (ic_demanded.jai) and the x86 target hooks there;
  visitReturnInst uses `ic_simplify_non_null_operand`; `intrinsic_ids.jai` gained stacksave/va_*/matrix/trampoline/
  ptrauth ids; canBeCastedExactlyIntToFP moved from ic_compares.jai to ic_casts.jai.
- Traps: Jai `for k: 0..n-1` with an unsigned `n == 0` runs 2^32 times — cast loop bounds to s64; `ifx` cannot
  pick between two multi-value calls; several helpers already existed under the same name in other agents' files
  (icb_fabs, pm_extract_value_idx, call_param_align, icb_vector_splat, ...): grep `^name ::` before adding one.

## InstCombine memory, GEPs, vector ops (L1.instcombine.memory 102/102 roundtrip, 56/102 ::opt; DESIGN.md §11)

- Ported completely, in LLVM's order: InstCombineLoadStoreAlloca.cpp (ic_loadstorealloca.jai),
  InstCombineVectorOps.cpp (ic_vectorops.jai), and the remaining InstructionCombining.cpp visitors (ic_combining.jai:
  GEP, alloc sites, free, switch, extractvalue, landingpad, freeze; foldVectorBinop with unshuffleConstant, reverse,
  vp.reverse, splice and vector.insert in ic_binop.jai). Shared analyses added for them: loads.jai (Loads.cpp:
  isDereferenceableAndAlignedPointer incl. assume bundles, isSafeToLoadUnconditionally, FindAvailableLoadedValue with
  BatchAA; Value::canBeFreed, willNotFreeBetween, isBitOrNoopPointerCastable, isIdenticalToWhenDefined) and
  memory_builtins.jai (MemoryBuiltins.cpp: allocation tables with families, getAllocSize with the visitor's Mapper,
  ObjectSizeOffsetVisitor in all 4 modes incl. load tracking through AA, ObjectSizeOffsetEvaluator for dynamic
  `llvm.objectsize`, lowerObjectSizeCall; ValueTracking's getConstantDataArrayInfo/GetStringLength).
  The older tables in inst_props.jai/basic_aa.jai/aa.jai now use these.
- The 46 failing memory tests are almost all calls: LibCallSimplifier (mem*/str* families, `__*_chk`), nonnull/
  dereferenceable call-argument inference in visitCallBase, memcpy/memset folds that need AAMDNodes::adjustForAccess;
  plus `debugify` (storemerge-dbg), `-instcombine-lower-dbg-declare=0` (alloca-cast-debuginfo) and InstSimplify's
  "load folding through scalable types" (load-store-forward).
- Sweep `--passes instcombine` vs main before this work (a0f750d): identical 3716→6744, no identical→differs,
  1 identical→failed (gc.statepoint, a calls path). Remaining loud failures in these areas: LowerDbgDeclare
  (27 files, needs Local.cpp LowerDbgDeclare + RemoveRedundantDbgInstrs), the ptrauth `llvm.protected.field.ptr`
  load/store folds, DIAssignID merging in mergeStoreIntoSuccessor, TargetExtType vector elements.
- Fixed on the way (shared code): `create_shuffle`, `create_extract_value`, `icb_insert_value` copy their index
  arrays first (`shuffle_mask(sv)`/`inst_indices(i)` are views into `ir.u32_pool`; appending to the pool while
  reading such a view produced garbage masks); `ic_take_name` is a no-op on constants (LLVM's getSymTab fails, the
  source keeps its name — a folded OptimizeOverflowCheck result got named `%x`); constant-folding GEPs with a
  scalable source type is refused (isSupportedGetElementPtr); emitGEPOffset handles splatted scalar indices and
  scalable strides (CreateTypeSize: vscale * min, nuw); CommonPointerBase's no-wrap flags default to all();
  has_poison_generating_flags no longer reads `inst()` of a constant expression.
- Tools: `tools/ic_funcdiff.py` (PORTED now includes the memory/vector/cast opcodes; calls are still excluded)
  found the u32_pool bug (masks like `<3, 31721, 2, 0>`); 53 function diffs remain in InstCombine, none in these files.
- Traps: `type_info` is a reserved identifier; `xx` likewise; `for e: 0..n-1` with `n: u32 == 0` (empty structs)
  loops forever; Jai `cast(u32)` of a -1 mask element fails the bounds check — use `cast,no_check`.

## Library calls: TargetLibraryInfo, BuildLibCalls, LibCallSimplifier, inferattrs (DESIGN.md §11)

- `tli.jai` ports TargetLibraryInfo.cpp/.h (everything but the vector-library tables) and the Triple.cpp pieces it
  needs (parse, normalize, OS/environment versions, the is*() predicates). The LibFunc enum, names and signatures
  are generated: `python3 impl/jai/gen/gen_tli.py > impl/jai/src/gen_tli.jai` (from TargetLibraryInfo.td), the
  Triple OS/environment/vendor tables by `gen/gen_triple.py` (TripleName.def). Rerun both after an LLVM bump.
  `tli_for(f)` is the per-function result (no-builtins / no-builtin-<f>, cached for the run like LLVM, which never
  invalidates it); the baseline is built once from `ir.triple` plus `-disable-simplify-libcalls`,
  `-disable-builtin=`, `-enable-builtin=`. The old ad-hoc TLI helpers (`tli_available`, `tli_has`,
  `tli_valid_proto`, `mb_tli_knows`, `tli_lib_func_of_call`, `math_libfunc`) now delegate to it.
- `-vector-library=` is not ported (unknown flag, fails loudly); nothing in InstCombine asks for mappings.
- `build_lib_calls.jai` = BuildLibCalls.cpp (complete); `simplify_lib_calls.jai` + `simplify_lib_calls2.jai` =
  SimplifyLibCalls.cpp (LibCallSimplifier + FortifiedLibCallSimplifier, complete except: the iprintf /
  __small_printf `CI->clone()` rewrites (XCore/TCE/Emscripten triples only) and `nan()` of ppc_fp128 fail loudly;
  optimization remarks are dropped). `value_tracking_strings.jai`: getConstantDataArrayInfo, getConstantStringInfo,
  GetStringLength, isOnlyUsedInZero(Equality)Comparison (the single copy: memory_builtins.jai had a second one).
  Wired in as `ic_try_optimize_call` (ic_calls.jai, tryOptimizeCall). `optimizeModularFormat` fails loudly.
- The simplifier builds with InstCombine's builder (`icb_*`). Differences from icb_* that matter: LLVM's
  CreateIntrinsic constant-folds all-constant calls without inserting a declaration, CreateUnary/BinaryIntrinsic
  insert the declaration first and then fold (`lcs_intrinsic`, `lcs_unary_intrinsic`, `lcs_binary_intrinsic`;
  the shared `icb_intrinsic` doesn't fold at all, `icb_unary/binary_intrinsic` fold without declaring — a debt of
  ic_core.jai left alone). Default operand bundles: while a call is simplified `ic.default_bundles_src` is set and
  `icb_insert` rebuilds every new call with that call's bundles (`call_with_default_bundles`).
- `inferattrs` (pass_inferattrs.jai, a module pass) = InferFunctionAttrs.cpp + Local.cpp inferAttributesFromOthers;
  L1.analysis.aa is COMPLETE with it.
- `normalize_triple` (parser.jai, `-mtriple`) is now the real Triple::normalize: `x86_64-linux-gnu` becomes
  `x86_64-unknown-linux-gnu`, `x86_64` stays `x86_64`.
- New functions (getOrInsertFunction, intrinsic declarations) are created in the DataLayout program address space.
- Sweep `--passes instcombine` vs main before this work: identical 6724 -> 7470, differs 804 -> 81, no
  identical->differs. Every remaining silent InstCombine-directory diff is outside the libcall code (fmul/fpext
  flag inference = SimplifyDemandedInstructionFPClass, is.fpclass canonicalization, vector folds, ...). Libcall
  tests that still fail loudly: nanl-ppc-fp128, remquol-ppc-fp128 (ppc_fp128 folding), modular-format,
  fputs-opt-size (`require<profile-summary>`), constant-fold-next* (isMathLibCallNoop of nextafter).
- Perf: no benchmark has library calls; straightline instcombine unchanged.

## Procedure-typed parameters that remain (audited for the "no hand-rolled vtables" rule)

No struct has a procedure-pointer field and there are no procedure-pointer tables (the SCEV `Sc_Rewriter.hook` and
`Sc_Visitor.follow/is_done` were the last; they are now `kind` enums, see DESIGN.md). What is left are plain
predicate/comparator parameters that mirror an LLVM `function_ref`, lambda template or function pointer at a single
call, not an interface with subclasses: PatternMatch predicates (`pm_int_pred`, `pm_apint_pred`, `pm_fp_pred`,
`pm_int_pred_arg`, `const_fp_all`), `phi_remove_incoming_if` (removeIncomingValueIf), `ic_remove_trivially_empty_range`,
`handle_guaranteed_{well_defined,non_poison}_ops` (function_ref Handle), `mvt_list`, the `gnu_stable_sort` comparator
(std::stable_sort's Compare) and `Host_Fn1/2` (ConstantFoldFP's `double (*NativeFP)(double)`).

## X86 TTI and print<cost-model> (L1.analysis.cost-model COMPLETE; DESIGN.md "Target cost model")

- Files: `tti.jai` (TargetTransformInfo / CostModel.cpp: `Tti`, `tti_get(f)` per-function subtarget cache,
  `tti_instruction_cost`, shuffle-mask predicates `svm_*`, cl::opts `-mcpu -mattr -cost-kind
  -intrinsic-cost-strategy -predictable-branch-threshold -costmodel-reduxcost`, opt's `-mcpu/-mattr` function
  attributes), `tti_x86.jai` (arith/cast/cmp-select/scalar memory/intrinsic tables, addressing modes),
  `tti_x86_vec.jai` (shuffles, insert/extract, scalarization overhead, replication, vector memory ops, masked and
  gather/scatter memory intrinsics, isLegal* queries), `tti_intrinsics.jai` (BasicTTI getIntrinsicInstrCost /
  getTypeBasedIntrinsicInstrCost, reductions), `x86_lowering.jai` + generated `gen_x86_lowering.jai`
  (TargetLoweringBase type legalization and operation actions), generated `gen_x86_tti.jai` (all cost tables,
  CPUs and feature implications). Regenerate with `python3 impl/jai/gen/gen_x86_tti.py > ...` /
  `gen_x86_lowering.py`; never hand-edit the gen files.
- Cost is `s64` with `COST_INVALID`; always combine with `cost_add`/`cost_mul` (raw `*` on an Invalid cost
  overflows silently).
- Still failing loudly: VP intrinsics, strided/histogram/vector.match/active.lane.mask costs, cttz.elts on
  scalable vectors, multiple-result vector libcalls (modf/sincos), MMRA combine with >1 tag per side,
  getInterleavedMemoryOpCost / getIntImmCost* / getAddressComputationCost (no pass needs them yet).
- Sweep `--passes 'print<cost-model>' --analysis`: 7750/7753 identical; the 3 left were stderr ordering/IR-reader
  issues, fixed after the sweep (UpgradeDebugInfo warning, verifier message, metadata renumbering after stripping).

## SimplifyCFG (L1.simplifycfg 288/289 ::opt, roundtrip 289/289)

- Files: `pass_simplifycfg.jai` (options, cl::opts, value-equality folding), `pass_simplifycfg2.jai` (hoist,
  sink, speculate, threading, two-entry phis, FoldBranchToCommonDest, conditional faulting),
  `pass_simplifycfg3.jai` (simplifyOnce driver, tail merging, `simplifycfg_run`), `pass_simplifycfg_switch.jai`
  (switch transforms, lookup tables, invokes, EH, stores), `scfg_util.jai` (ProfDataUtils, switch API, eager DTU,
  attribute intersection, MMRA), `local_utils.jai` (Local.cpp helpers: ConstantFoldTerminator,
  removeUnreachableBlocks, changeToCall, hoistAllInstructionsInto, `block_splice` with LLVM's debug-record splice
  rules, `inst_insert_before_adopt`).
- The only failing test is nomerge.ll (`-O1` pipeline). unreachable_assume.ll passes now that LibCallSimplifier
  folds `abs`.
- Sweeps: `--passes simplifycfg` 7753/7754 identical (1 loud: gc.relocate dereferenceability);
  `--passes 'debugify,simplifycfg'` 0 differs / 0 bad-ir (2 loud).
- Perf (tests/perf/scaling, `-passes=simplifycfg`): 3.3x-5x LLVM's time; growth k=1.35 (diamonds) / 1.24
  (switch) vs LLVM's ~1.1. The quadratic `unique_successors` on big switches is fixed; what remains is spread over
  hashing (md_kind_id string lookups, set_name uniquing, md_value_deleted on every erase), no single hotspot.
- Debug-record rule to remember: an instruction inserted at `I->getIterator()` adopts `I`'s records
  (`insert_at_position(.., head=false)`); `getFirstInsertionPt()`/`begin()` carry the head bit and insert in
  front of them. Most simplifycfg debug-info mismatches were a wrong head bit.

## Debug info utilities (debugify, salvage, dbg.declare lowering)

- Files: `pass_debugify.jai` (Debugify.cpp synthetic mode: `debugify`, `check-debugify`, `-enable-debugify`,
  `-debugify-level/-quiet/-atoms`; the DIBuilder calls it makes are inlined as `di_get` rows), `salvage_debug.jai`
  (Local.cpp salvageDebugInfo / salvageDebugInfoImpl / replaceAllDbgUsesWith / LowerDbgDeclare, BasicBlockUtils
  RemoveRedundantDbgInstrs, the `redundant-dbg-inst-elim` pass, DIExpression appendOffset / appendOpsToArg /
  prependOpcodes / append / appendToStack / appendExt / foldConstantMath, DbgVariableRecord location edits).
  `-strip-debug` is opt's StripDebugInfo after parsing (pass_simplifycfg.jai owns the flag).
- Use `dbgr_set_raw_location` / `dbgr_replace_variable_location_op` / `dbgr_add_variable_location_ops` /
  `dbgr_set_kill_location` to change a record's location: they keep the value -> records index and the
  "tracking stamp" (MetadataTracking's use-map index, which orders findDbgUsers) right. A new DIArgList is made with
  `di_arg_list_get` (it gets a tracking stamp for findDbgUsers' arg-list order).
- `md_value_rauw` keeps the old ValueAsMetadata row as an alias of the new value's row when that one already exists
  (`vam_aliases`): records keep their Md_Id, and a later RAUW/deletion of the new value updates both. Without it a
  record pointed at a dead value (`<badref>`).
- Head bits: LLVM iterators from `getFirstInsertionPt`, `getFirstNonPHIIt`, `BasicBlock::begin()` and
  `getInsertionPointAfterDef` insert *before* the records at that position; `I->getIterator()` / `Instruction*`
  positions adopt them (`insert_at_position(.., head)`, `ic_link_before(.., head)`, `irb_set_at(.., head)`).
  `moveBefore` (not Preserving) leaves the moved instruction's records behind: `inst_move_before_dbg`.
  `split_basic_block(.., head=false)` leaves the split point's records in the old block on the new branch.
- Sweeps after this work (`debugify,<pass>` vs LLVM, ~7600 files): dce/adce/bdce/sroa/mem2reg/lcssa/instsimplify 0
  silent; instcombine 89 differs, all of which also differ without debugify except ~11 (DIArgList record order after
  sinking: LLVM re-tracks an arg list when one of its values is RAUW'd onto an existing ValueAsMetadata, our
  stamps approximate that; debug locations of a few folds).

## InstCombine: FP classes, debug info, per-function sweep

- `ic_demanded_fp.jai` ports the FP half of InstCombineSimplifyDemanded.cpp completely (SimplifyDemandedFPClass,
  SimplifyDemandedUseFPClass, SimplifyMultipleUseDemandedFPClass, SimplifyDemandedInstructionFPClass and their
  helpers); it runs for `nofpclass` returns (visitReturnInst) and at the end of visitFMul. `ic_atomicrmw.jai` is
  InstCombineAtomicRMW.cpp. transformConstExprCastCall is ported for calls (invokes fail loudly).
- `sweep --per-function --passes instcombine`: 147 -> 12 differs (69329 identical of 69711). Fixed on the way:
  FPClassTest masks written `~cast(u32) FC_NAN & FC_ALL_FLAGS` (Jai's cast swallows the whole `&` expression: use
  `fc_not`), `Builder.Insert(I)` clearing an unlinked instruction's name, canRewriteGEPAsOffset's PHI-user check
  (a no-op in LLVM), m_SpecificInt(APInt) is APInt::isSameValue, OverflowTracking::applyFlags in
  foldBinopWithRecurrence, assume-align on ptradd, powi(2.0 splat), known bits of llvm.pext/pdep, call-site-only
  getParamDereferenceableBytes, memset forwarding's `APInt::ult(uint64_t)`, Negator zext-of-signbit poison lanes,
  visitMul's m_CheckedInt over vector divisors.
- Remaining per-function differs: modref/BasicAA load forwarding, ctor-memset (store to addrspacecast constant),
  icmp-shr/select/trunc/and-or poison-lane folds, objectsize of huge allocas, active.lane.mask, ppc_fp128 copysign,
  ldexp(intmin) metadata; loud: gc.statepoint, ptrauth, trampolines, nextafter folding, `!annotation`.
- `pm_specific_int_ap` allows poison lanes although LLVM's m_SpecificInt(APInt) doesn't: two callers depend on that
  (and-or-icmp-const-icmp, unsigned-add-lack-of-overflow-check) and should use an allow-poison matcher instead.

## DSE and MemCpyOpt (L1.dse COMPLETE 83/83, L1.memcpyopt COMPLETE 56/56)

- Files: `pass_dse.jai` (DeadStoreElimination.cpp, DSEState as `Dse`), `pass_memcpyopt.jai` (MemCpyOptimizer.cpp,
  `Mco`), `assume_builder.jai` (salvageKnowledge for `-enable-knowledge-retention`; only the AC = DT = null form DSE
  uses; every other pass fails loudly with that flag, see `knowledge_retention_check`).
- Shared pieces added: EarliestEscapeAnalysis with CycleInfo (`Aa_Query.ee_ci`; DSE builds `EA(DT, nullptr, &CI)`, so
  capture-before queries use CFG.cpp's cycle-aware reachability: `is_potentially_reachable_*_ci`), one EEA cache shared
  by several BatchAAs (`aa_query_new_sharing_ee`; MemCpyOpt's EEA_ lives for the whole run while every
  `BatchAAResults BAA(*AA, EEA)` has its own alias cache), `aa_is_must_alias_values` (isMustAlias(V1, V2) queries
  *precise(1)* locations, not beforeOrAfter: getting this wrong turns BasicAA's identical-GEP MustAlias into MayAlias),
  `is_bytewise_value`, `value_pointer_offset_from` (Value::getPointerOffsetFrom), `combine_aa_metadata`,
  `ci_exit_blocks` / `ci_top_level_parent`, `mi_dest` / `mi_source` (getDest/getSource strip pointer casts, incl.
  all-zero GEPs; getRawDest does not), `call_param_only_reads` now honours operand bundles instead of failing.
- Fixed on the way: `dt_find_nearest_common_dominator_inst` (FindEarliestCapture) asserted on unreachable blocks; LLVM
  returns the other instruction first.
- Sweeps (whole-file and `--per-function`, ~7750 files / ~69800 functions): `dse`, `memcpyopt`, `memcpyopt,dse`,
  `dse -enable-knowledge-retention`: 0 differs, 0 bad-ir (per-function: 2 loud ppc_fp128 parser failures);
  `dse,print<memoryssa>` and `memcpyopt,print<memoryssa>` (MemorySSA updates): identical except
  GlobalsModRef/pr12351.ll, which differs with plain `print<memoryssa>` too (debug-info version warning).
- Perf (no @perf benchmark times these passes; x64 build, `-disable-output`): sqlite3.ll dse 3.4 s (parse 0.97 s;
  LLVM 0.45 / 0.28 s), memcpyopt 1.5 s (LLVM 0.35 s); tests/perf/scaling/allocas n2000 -> n8000 dse 0.33 -> 0.99 s,
  memcpyopt 0.16 -> 0.60 s: linear, like LLVM. The DSE pass itself is ~15x LLVM's, mostly BasicAA queries.
- Traps: LLVM 23's conditional branch is a separate opcode here (`.CONDBR`, not a 3-operand `.BR`); a `defer x = next`
  in a loop also runs on `break` (it moved MemCpyOpt's memset insertion point one instruction too far);
  `Retained_Knowledge` already exists in loads.jai (assume bundles), the builder's is `Ab_Knowledge`.
## GVN (L1.gvn 397/404: roundtrip 202/202, opt 195/202)

- Files: `pass_gvn.jai` (GVN.cpp: ValueTable, LeaderMap, load elimination with MemDep or MemorySSA, load PRE,
  scalar PRE, propagateEquality, dead blocks), `memdep.jai` (MemoryDependenceAnalysis.cpp; a `*Mem_Dep_Results`
  per GVN run, in temp), `vn_coercion.jai` (VNCoercion.cpp), `phi_trans_addr.jai` (PHITransAddr.cpp, moved out of
  memoryssa.jai; select-condition translation and translateWithInsertion added).
- `merge_block_into_predecessor` takes an optional `*Lazy_Dtu` (DomTreeUpdater::Lazy: updates and deleted blocks
  queued, `lazy_dtu_flush`); `eliminate_duplicate_phi_nodes_collect` is EliminateDuplicatePHINodes(BB, ToRemove).
- MemDep keeps one EarliestEscapeAnalysis query (`md.ee`) for its lifetime and every BatchAA shares it
  (`aa_query_new_sharing_ee`, from jai_dse): the cache staleness is observable (knowledge/llvm/gvn.md).
- GVN's MemorySSA path builds `EarliestEscapeAnalysis(DT, LI)` per load; ours has no LoopInfo/CycleInfo there
  (reachability is slightly less precise). No sweep difference came from it.
- Shared fixes: `type_is_scalable` handles target extension types (layout type); `value_can_be_freed` handles the
  `statepoint-example` GC; `-capture-tracking-max-uses-to-explore` is a cl::opt (`capture_tracking_max_uses`);
  `legalize_updates` sorted with an O(n^2) insertion sort (GVN's lazy merge batch of 6000 updates took 50 s on
  diamonds/n8000; now a merge sort, same order since keys are unique).
- `gvn_gep_collect_offset` is a faithful GEPOperator::collectOffset; `gep_collect_offset_map` (simplify_lib_calls.jai)
  treats splat vector indices as constants and doesn't bail on scalable types (left alone: its callers may rely on it).
- Remaining unit failures need other passes: mldst-motion (2, + memcpyopt), loop-simplifycfg (2), sccp,
  jump-threading, `default<O1>`.
- Sweeps (every round-tripping file): `gvn`, `gvn<memoryssa>`, `require<memoryssa>,gvn -verify-memoryssa`: 7745/7754
  identical, 0 differs, 9 loud (non-GVN: nextafter folding, frexp ranges, ppc_fp128, x86 hadd known bits, capture
  tracking through bundles); `gvn --per-function`: 69569/69778 identical, 0 differs, all loud failures non-GVN.
  `gvn<memoryssa>,print<memoryssa>` (analysis): 2 differences, both printer issues outside GVN (x86_fp80 snan
  printing in print_util, a debug-info warning's position).
- Perf (x64 build, `-passes=gvn -disable-output`): sqlite3.ll 5.6 s vs LLVM 0.46 s (parse alone 1.0 s);
  diamonds n2000/n8000 0.25/0.96 s (LLVM 0.06/0.20, linear); loops-many n2000/n8000 0.23/1.84 s (LLVM 0.05/0.13):
  k ~1.5 there, from PHITransAddr scanning all users of `%p` (thousands of GEPs) with a dominance query each — LLVM
  does the same scan but its dominance check is cheaper. No `@perf` benchmark times GVN.

## IndVarSimplify and SCEVExpander (L1.indvars 434/446: roundtrip 223/223, opt 211/223; L1.analysis.scev COMPLETE)

- Files: `scev_expander.jai` (ScalarEvolutionExpander.cpp + the SE queries it needs: canReuseInstruction,
  getStrengthenedNoWrapFlagsFromBinOp, getWiderType; Loop::getCanonicalInductionVariable,
  movementPreservesLCSSAForm, normalizeForPostIncUse, X86 getIntImmCostInst for the minsize cost), `simplify_indvar.jai`
  (SimplifyIndVar.cpp: SimplifyIndvar = `Siv`, WidenIV = `Widen_IV`), `pass_indvars.jai` (IndVarSimplify.cpp,
  LoopUtils' rewriteLoopExitValues, Local.cpp's RecursivelyDeleteDeadPHINode / DeleteDeadPHIs with TLI and
  MemorySSAUpdater, mustExecuteUBIfPoisonOnPathTo), `value_handles.jai` (WeakTrackingVH / TrackingVH),
  getLoopInvariantPredicate / getLoopInvariantExitCondDuringFirstIterations / evaluatePredicateAt at the end of
  scev_implied.jai.
- **Reusable SCEVExpander API** (for LSR, LoopUnroll runtime, LoopIdiom, LoopVectorize, LoopPredication):
  `x: Scev_Expander; sx_init(*x, "name", preserve_lcssa)`; `sx_expand_code_for_at(*x, s, ty, insert_before)`,
  `sx_expand_code_for(*x, s, ty)` (at the current point), `sx_set_insert_point`, `sx_clear_insert_point`,
  `sx_is_safe_to_expand(_at)`, `sx_is_high_cost_expansion(*x, exprs, l, budget, tti, at)`
  (`scev_cheap_expansion_budget` = `-scev-cheap-expansion-budget`), `sx_has_related_existing_expansion`,
  `sx_replace_congruent_ivs`, `sx_hoist_iv_inc`, `sx_get_iv_inc_operand`, `sx_find_insert_point_after`,
  `sx_is_inserted_instruction`, `sx_all_inserted_instructions`, `sx_erase_dead_instructions`, `sx_cleanup`
  (SCEVExpanderCleaner with ResultUsed = false), modes `sx_disable_canonical_mode`, `sx_enable_lsr_mode`,
  `sx_set_post_inc` / `sx_clear_post_inc`, `sx_set_iv_inc_insert_pos`, `sx_set_chained_phi`, `sx_clear`. The
  expander works on the global `se` (set it first) and uses se.dt / se.li. Not ported: the SCEVPredicate
  expansions (`sx_expand_code_for_predicate` fails loudly).
- Also reusable: `simplify_loop_ivs(l, li, dt, tti, *dead)` (simplifyLoopIVs, for LoopUnroll),
  `simplify_users_of_iv`, `create_wide_iv`, `rewrite_loop_exit_values`, `is_almost_dead_iv`,
  `must_execute_ub_if_poison_on_path_to`, `ivs_recursively_delete_trivially_dead(v, mssau)`,
  `ivs_delete_dead_phis(bb, mssau)`, `li_canonical_induction_variable`, `li_movement_preserves_lcssa_form`,
  `form_lcssa_for_instructions(..., phis_to_remove, inserted_phis)` (the optional outputs are new).
- **Value handles**: `vh_new(v) -> Vh`, `vh_get`, `vh_set`, `vh_release_all()` (the pass that creates handles
  releases them before returning; indvars_run does). replace_all_uses_with / erase_inst call vh_note_rauw /
  vh_note_erase. Plain WeakVH / AssertingVH need nothing (ids are never reused: check `vkind != .DEAD`).
- IRBuilder flavours: the expander's own `sx_create_*` (InstSimplifyFolder + remember the instruction);
  IndVarSimplify's `IRBuilder<>` is `Irb` (ConstantFolder); `irb_trunc_flags` = CreateTrunc with nuw/nsw.
  `new X(..., InsertBefore)` is `siv_insert_before` (adopts the position's debug records, then names).
- `-replexitval=unusedindvarinloop` fails loudly (needs InductionDescriptor::isInductionPHI with its ID).
- Remaining unit failures: loop-deletion (9), simple-loop-unswitch, inline + function-attrs
  (`-disable-nounwind-inference`).
- Sweeps (every round-tripping corpus file): `loop(indvars)` 7754/7754 identical; `--per-function` 69776/69778
  identical (2 loud: ppc_fp128 literal); `sroa,loop(loop-rotate,indvars)` 7747 identical, 0 differs (7 loud, all in
  SROA / loop-rotate); `sroa,instcombine,loop-mssa(loop-rotate,licm),loop(indvars)`: the 9 differences are the
  same as without indvars (InstCombine); with a trailing instcombine ~37 more files differ, all identical after
  indvars, so they are InstCombine bugs on post-indvars IR (lftr-promote.ll, pr28705.ll, LoopVectorize/*: worth a
  look for L1.instcombine). `print<scalar-evolution>` and `loop(indvars),print<scalar-evolution>` (analysis):
  3 differences left, none from SCEV/indvars: GlobalsModRef/pr12351.ll (debug-info warning position),
  InstSimplify/ConstProp/extractelement-vscale.ll (sign bits of an extractelement from a scalable splat: LLVM
  gives full-set), LoopVectorize/X86/int128_no_gather.ll (`'+mpx' is not a recognized feature` warning printed
  before instead of after the first printer header). uscmp.ll was fixed (call_range now intersects call site and
  callee like CallBase::getRange).
- Perf (x64 build, `-passes=sroa,loop(loop-rotate,indvars)` minus `sroa,loop(loop-rotate)`): loops n2000/n8000
  +0.25/+5.0 s (LLVM +0.02/+0.24), loops-many n500/n2000 +1.7/+61 s (LLVM +0.07/+4.2). LLVM is superlinear too
  (k ~1.9 / ~2.8) because computing each sequential loop's trip count walks every dominating loop guard
  (isBasicBlockEntryGuardedByCond up the predecessor chain); ours is k ~2.2 / ~2.6 with a much larger constant
  (isImpliedCond and range computations, temp APInt allocation). No `@perf` benchmark times indvars.

## LazyValueInfo, CVP, JumpThreading, BPI/BFI (L1.cvp, L1.jump-threading, L1.analysis.lvi, L1.analysis.bfi: COMPLETE)

- Files: `value_lattice.jai`, `lazy_value_info.jai`, `pass_cvp.jai`, `pass_jump_threading.jai`, `branch_prob.jai`,
  `block_freq.jai` (DESIGN.md "LazyValueInfo, CVP, JumpThreading, BPI/BFI"). Unit counts: cvp 104/104,
  jump-threading 194/194, analysis.lvi 6/6, analysis.bfi 64/64 (roundtrip + opt/analysis).
- Sweeps (every round-tripping file; LLVM vs us): `correlated-propagation` and `jump-threading` whole-file and
  `--per-function`: 0 differs, only loud failures from the ppc_fp128 parser gap; `jump-threading,print<lazy-value-info>`,
  `print<branch-prob>`, `print<block-freq>` (--analysis): identical except GlobalsModRef/pr12351.ll (the debug-info
  version warning every printer sweep shows). Rerun after touching LVI, CVP, JT, BPI/BFI, the lazy DTU, or the
  AssumptionCache invalidation rule.
- Shared changes: `Dtu` got a Lazy mode (scfg_util.jai, see DESIGN.md); `call_range` intersects call-site and callee
  `range` (CallBase::getRange); `contains_undef_element` no longer counts poison; `block_terminating_deoptimize_call`
  matches LLVM (no extra "returns the call" check); fam_invalidate keeps the AssumptionCache while a surviving LVI
  holds it (LLVM never invalidates the AC; see knowledge/llvm/lazy-value-info-and-jump-threading.md);
  `-verify-each` (no-op) and `-aa-pipeline X` (space form) are accepted.
- Fail loudly: `-lvi-per-pred-ranges` (unknown flag), JumpThreading's SplitEdge through splitBlockBefore, `#dbg_assign`
  remapping, key-instruction atom groups, trailing debug records after duplicating a block into its predecessor,
  ScaledNumber printing of numbers below 2^-120 (toStringAPFloat), `-use-iterative-bfi-inference` (unknown flag).
- Value::print in annotation writers: `value_print_isolated` / `printer_isolated_inst_to_string` (value_lattice.jai)
  save and restore the AsmWriter state (`W`, `print_state`, the annotation hooks) around a print with a fresh
  SlotTracker; reuse them for any printer that prints values from inside `print_function`.
- Perf (x64 build, `-disable-output`, no @perf benchmark times these passes): diamonds n2000/n8000 jump-threading
  0.20/0.86 s (LLVM 0.11/0.30; parse alone 0.23/0.82), CVP 0.36/0.98 s (LLVM 0.13/0.20); sqlite3.ll JT 2.3 s,
  CVP 1.3 s (LLVM 0.59/0.32, parse 1.7 s). Linear; a linear `isBBPendingDeletion` scan made JT quadratic on
  diamonds before `Dtu.deleted_set`.
- Jai traps met here: `cast(u64) x << 32` is `cast(u64) (x << 32)` (the cast swallows the whole binary expression:
  write `(cast(u64) x) << 32`) — it silently collapsed LVI's (block, value) stack keys; `0xFFFF_FFFF_FFFF_FFFF >> 4`
  on an untyped literal shifts a negative s64 (cast to u64 first); `return f()` with several results, `remove` is a
  reserved word, `for < k: a..b` order, names that already existed elsewhere (`clz64`, `ctz64`, `fn_entry_count`,
  `block_terminating_deoptimize_call`).

## Reassociate (L1.reassociate 159/164: roundtrip 82/82, opt 77/82)

- `pass_reassociate.jai` ports Reassociate.cpp completely (rank map, LinearizeExprTree, RewriteExprTree, NegateValue,
  OptimizeAdd/Mul/Xor/AndOrXor, factoring, BreakUpSubtract/Distribute, ConvertShiftToMul, the pair map and the
  CSE-local heuristic, `-reassociate-use-cse-local`), plus ValueTracking's `may_have_non_def_use_dependency`.
  RedoInsts (SetVector over a deque) is `Ra_Set` (array + tombstones + index table). EmitAddTreeOfValues' operands
  are WeakTrackingVHs (value_handles.jai), released at the end of the run.
- The 5 failing tests need early-cse (2) or inline (3). `-run-twice` is accepted as a no-op (knowledge/llvm/reassociate.md).
- Sweeps: `reassociate` whole-file 7754/7754, `--per-function` 69776/69778 (2 loud ppc_fp128 parser), `debugify,reassociate`
  and `reassociate,reassociate -reassociate-use-cse-local=false`: 0 differs.
- Perf (x64 build, `-disable-output`, no @perf benchmark times it): straightline n16000/n64000 0.23/0.87 s (LLVM
  0.035/0.16; parse+print alone 0.07/0.33): linear, the pass itself ~7x LLVM. sqlite3.ll +0.1 s over parsing.

## ConstraintElimination (L1.constraint-elimination COMPLETE 208/208)

- `pass_constraint_elimination.jai` ports ConstraintElimination.cpp except the reproducer
  (`-constraint-elimination-dump-reproducers` fails loudly) and remarks; `constraint_system.jai` ports
  ConstraintSystem.cpp (int64 checked arithmetic: `add_ov_s64`/`sub_ov_s64`/`mul_ov_s64`, reusable). The solver
  copies the system for every query; `cs_is_condition_implied` releases those temp allocations with a
  temporary-storage mark, so a function with thousands of checks doesn't keep every copy alive.
- `gep_operator_collect_offset` is GEPOperator::collectOffset for instructions *and* constant expressions
  (gvn_gep_collect_offset only handles instructions).
- Sweeps: `constraint-elimination` whole-file 7753/7754 and `--per-function` 69774/69778 (loud: x86 hadd known bits,
  ppc_fp128 parser), `debugify,…`, `sroa,…`, `-constraint-elimination-max-rows=3`: 0 differs;
  `constraint-elimination,print<scalar-evolution>` only shows the two known printer differences.
- Perf (x64 build, `-disable-output`, no @perf benchmark): diamonds n500/n2000/n8000 0.05/0.15/0.64 s (parse alone
  0.04/0.10/0.35; LLVM 0.03/0.04/0.12): linear. sqlite3.ll +0.3 s over parsing (LLVM +0.04 s).

## AggressiveInstCombine (L1.aggressive-instcombine COMPLETE 88/88)

- `pass_aggressive_instcombine.jai` ports AggressiveInstCombine.cpp completely (only merging stores that carry
  `!DIAssignID` fails loudly); `aic_trunc.jai` ports TruncInstCombine.cpp. Two TTI hooks live in the pass file
  (`tti_have_fast_sqrt`, `tti_allows_misaligned_memory_accesses`), as do `split_block_dtu` (SplitBlock's
  DomTreeUpdater path), `aa_tags_concat` (AAMDNodes::concat), `gep_operator_collect_offset` users and
  `irb_zext_or_trunc_any` (CreateZExtOrTrunc for any int/vector type).
- Shared changes: `Simplify_Query.no_tli_libcalls` (TLI == nullptr for ConstantFoldCall; `have_tli = false` is set by
  several callers that do pass a TLI in LLVM, so it could not be reused), `simplify_instructions_in_block(bb,
  use_tli)` (JT keeps the default), ConstantFoldLoadThroughBitcast returns null for a scalable load from a fixed
  constant instead of failing. `ra_has_one_use` became `value_has_one_use` (Value::hasOneUse: false for
  ConstantData, which has no use list in LLVM).
- Sweeps: whole-file 7753/7754 + per-function 69776/69778 (loud: ppc_fp128 parser), `-mtriple=x86_64-unknown-linux-gnu`
  and `debugify,…`: 0 differs.
- Perf (x64 build, `-disable-output`, no @perf benchmark): straightline n16000/n64000 +0.01/+0.1 s over parsing,
  sqlite3.ll +0.23 s (LLVM +0.02): linear.

## L1.loop-misc: LoopDeletion, LoopInstSimplify, LoopSimplifyCFG, LoopIdiomRecognize (+ LastRunTracking)

- Files: `pass_loop_deletion.jai` (LoopDeletion.cpp, LoopUtils' deleteDeadLoop / breakLoopBackedge,
  containsIrreducibleCFG on a LoopBlocksRPO), `pass_loop_instsimplify.jai` (+ the WeakTrackingVH-list form of
  RecursivelyDeleteTriviallyDeadInstructions with MSSAU: `recursively_delete_trivially_dead_list`),
  `pass_loop_simplifycfg.jai` (ConstantTerminatorFoldingImpl = `Ctf`), `pass_loop_idiom.jai` (`Lir`),
  `hash_recognize.jai` (HashRecognize: CRC detection + Sarwate table), `loop_access.jai` (the start of the LAA port:
  getPointersDiff, isConsecutiveAccess). `require<iv-users>` computes IVUsers every time (LLVM caches it per loop;
  recomputing only repeats memoized getSCEV calls).
- **LastRunTrackingAnalysis** (passes.jai `Fn_Analyses.lrt_instcombine`, Analysis_Kind `.LAST_RUN_TRACKING`):
  InstCombine is skipped when it already ran on the function and every pass since preserved everything. This was
  the cause of the ~37 extra differences of `...,loop(indvars),instcombine`: LLVM's indvars can change flags and
  still return PreservedAnalyses::all (knowledge/llvm/indvars-and-scev-expander.md). `-disable-last-run-tracking`.
  Any pass that wrongly returns PRESERVE_ALL after changing IR (or the reverse) now changes InstCombine's output.
- Loop passes in a module pipeline (`debugify,loop-idiom`) get their own function+loop adaptor (parse_module_pass).
- Unported corners, all loud: SplitEdge through splitBlockBefore in breakLoopBackedge (never hit in the corpus),
  LoopIdiom chains of more than 8 adjacent stores (SmallPtrSet iteration order); LoopSimplifyCFG with more than two
  dead successors uses insertion order where LLVM uses pointer order (DT child order only; sweeps identical).
- Sweeps (all identical except pre-existing loud failures and the pr12351.ll diagnostic): `loop(loop-deletion)`,
  `loop-mssa(loop-deletion),print<memoryssa>` (-verify-memoryssa), `loop(loop-instsimplify)`,
  `loop-mssa(loop-instsimplify)`, `loop(loop-simplifycfg)`, `loop-mssa(loop-simplifycfg)`, `loop(loop-idiom)`
  (also `-mcpu=corei7`, `-mtriple=x86_64 -mcpu=corei7 --per-function`, and `debugify,function(loop(loop-idiom),
  loop-mssa(loop-idiom))`), `sroa,loop(loop-rotate,indvars,loop-idiom,loop-deletion)`,
  `sroa,instcombine,loop-mssa(loop-instsimplify,loop-simplifycfg,licm),loop(loop-deletion)` (+ --per-function),
  `instcombine` whole-file and `--per-function`: 0 differs.
- Shared fixes on the way: li_make_loop_invariant moves with LLVM's moveBefore (debug records stay), opt no longer
  adds `"target-cpu"` for `-mcpu` on a triple-less module, dl_type_alloc_size computes arrays in bytes.
