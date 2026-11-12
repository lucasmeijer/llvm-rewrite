# impl/jai notes

- The compiler (beta 0.2.030) isn't in the workspace image, because its download URL is private. `build.sh` calls
  `scripts/ensure-jai.sh`, which installs it once into `/persistent/toolchains/jai` from the `JAI_COMPILER_URL`
  environment variable. Never write that URL into the repo, reports or logs. If it's missing, stop and say so in a
  challenge report.
- Docs: `/persistent/toolchains/jai/how_to/*.jai` (numbered tutorials), `README.txt`, `CHANGELOG.txt`, and the module
  sources in `/persistent/toolchains/jai/modules`. Training data for Jai is thin and the language changes between
  betas, so check against the how_to files and modules rather than relying on memory.
- `build.sh` compiles each `src/<tool>.jai` with the x64 backend (`-x64`, bounds checks and stack traces on) by
  default: ~3 s for all three tools. See "Build modes" below for the optimized build that `perf` uses.

## Build modes and compile-time performance

- **`JAI_BUILD=x64`** (default, what `check` builds): the x64 backend, ~3 s. Its binaries are 5-8x slower than the
  optimized build (parse+print sqlite3.ll 1.2 s vs 0.15 s; `-passes=gvn` 4.9 s vs 0.6 s).
- **`JAI_BUILD=optimized`** (`impl/jai/perf.env` sets it for `harness/run perf`): `build_optimized.jai`, a metaprogram
  with the `-o` settings (LLVM backend, VERY_OPTIMIZED, no stack traces, **no bounds checks**). ~2 min under load (one
  thread per tool; the three tools build in parallel). Splitting into LLVM modules (`enable_split_modules`) builds
  5x faster but the binary is 2.4x slower (no cross-module inlining), and stack traces on cost another 2x, so neither
  is used. The full ratchet passes with the optimized binary too (`check --no-build` after a `JAI_BUILD=optimized`
  build), but keep `check` on x64: bounds checks turn silent memory bugs into loud failures.
- Both are cached in `bin/.cache/<mode>-<hash of build.sh, build_optimized.jai, src/, compiler version>/` (4 newest
  per mode); `bin/.stamp` names the installed one. Switching modes (perf, then check) is a copy. The optimized build
  compiles a snapshot of `src/` so edits during the two minutes can't end up under the wrong hash; each build has its
  own `.build` directory (a concurrent build's cleanup used to delete the other's object files).
- Decision (2026-11): keep x64 for `check` (the harness rebuilds before every check; 2 min would dominate an edit/check
  loop) and time the optimized build in `perf`. `perf` after a source change therefore costs ~2 min extra once.
- Profiling: `valgrind --tool=callgrind` works on both builds (perf(1) has no hardware counters in this VM); profile
  the optimized build (the x64 build's hotspots are mostly backend artefacts). Function names come out as
  `file.jai:proc_<hash>`; with `--tree=caller` you get call counts per caller.

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
- Perf (x64 build, no `@perf` benchmark runs these passes; tests/perf/scaling/loops-many, `-disable-output`,
  minus `loop(loop-rotate)`): n500 loop-instsimplify / loop-simplifycfg ~+0.0 s (LLVM the same), loop-idiom and
  loop-deletion +0.8 s each (LLVM +0.03 s); all four at n2000 46.6 s vs LLVM 3.2 s. The time is ScalarEvolution's
  backedge-taken counts (loop guards of every preceding loop), the same superlinear cost as indvars above.
- Shared fixes on the way: li_make_loop_invariant moves with LLVM's moveBefore (debug records stay), opt no longer
  adds `"target-cpu"` for `-mcpu` on a triple-less module, dl_type_alloc_size computes arrays in bytes.

## LoopAccessAnalysis and PredicatedScalarEvolution (L1.analysis.laa COMPLETE 72/72 + tests/analysis/access-info)

- `loop_access.jai`: LAA (`Laa` = LoopAccessInfo, `Mdc` = MemoryDepChecker, `Rpc` = RuntimePointerChecking,
  `Access_Analysis`, `Eqc` = EquivalenceClasses<MemAccessInfo> as leader -> member list, `Mai` = MemAccessInfo
  packed in a u64), print<access-info>[<allow-partial>]. `scev_pred.jai` now has PredicatedScalarEvolution (`Pse`),
  SCEVUnionPredicate as a `[..] u32` of predicate rows (`sc_union_implies/_add/_is_always_true`), and the
  SCEVPredicateRewriter's Pred form (`sc_rewrite_using_predicate`).
- The LoopAccessInfoManager is not cached across passes: each print<access-info>, loop-load-elim and loop-distribute
  run computes a fresh LAI per loop (`laa_cached_info`). LLVM keeps LAIs across passes until LoopAccessAnalysis is
  invalidated; a pipeline where that matters (two LAA users with nothing invalidating in between) may differ.
- Loud: VFDatabase mappings (calls with `vector-function-abi-variant`), printing a non-global, non-argument,
  non-instruction pointer. `getKnowledgeForValue` is ported only for the Dereferenceable bundles LAA asks for.
- `GEPOperator::hasNoUnsignedSignedWrap` is true for `inbounds` too (the jai flags keep F_INBOUNDS and F_NUSW apart).
- Sweeps: `print<access-info>` whole-file 7746/7754 identical (7 loud, pr12351 diagnostic), `--per-function` 0 differs,
  `sroa,instcombine,loop-mssa(loop-rotate,licm),print<access-info>` 0 differs from LAA.

## LoopLoadElimination, LoopDistribute, LoopVersioning (L1.loop-misc: 144/153 ::opt, 153/153 roundtrip)

- Files: `pass_loop_load_elim.jai` (LLE; `Lel` holds a *copy* of the LAI's PSE, as LLVM's member does),
  `pass_loop_distribute.jai` (`Ld_Part` / `Ld_Parts`: std::list of partitions with `removed` flags),
  `loop_versioning.jai` (LoopVersioning `Lver`, addRuntimeChecks / expandBounds, cloneLoopWithPreheader, the
  SCEVExpander predicate expansion, MDNode::concatenate, an InstSimplifyFolder IRBuilder `isf_*`).
  CloneBasicBlock / remapInstructionsInBlocks / Value_Map come from clone_function.jai / value_mapper.jai.
- `addRuntimeChecks` defaults to HoistRuntimeChecks = false and LoopVersioning does not pass it: the hoisting of
  bounds to the outer loop is only for LoopVectorize (a linpack-pc.ll sweep difference found this).
- LoopDistribute's forced-failure diagnostic (`llvm.loop.distribute.enable` and the loop is not distributed) is
  printed without LLVM's source-location prefix (stderr is not compared by ::opt).
- Remaining unit failures all need unported passes: loop-vectorize (5), simple-loop-unswitch (2), sccp (1),
  require<profile-summary> (1).
- Perf (x64 build, no `@perf` benchmark; tests/perf/scaling/loops-many/n500, minus `loop(loop-rotate)`):
  loop-load-elim / loop-distribute / print<access-info> +0.9-1.0 s each (LLVM +0.05-0.07 s). The cost is the
  symbolic max backedge-taken count every LAI asks for (the loop-guard walk, as for indvars/loop-deletion).
- Sweeps (0 differs): `loop-load-elim` whole-file and `--per-function`, `loop-distribute -enable-loop-distribute`
  whole-file and `--per-function`, `sroa,instcombine,loop-mssa(loop-rotate,licm),loop-distribute,loop-load-elim,
  loop(loop-idiom,loop-deletion)`. Loud: 6 files with VFDatabase mappings.
## LoopUnroll, runtime unrolling, peeling, ValueMapper (L1.loop-unroll 252/256: roundtrip 128/128, opt 124/128)

- Files: `pass_loop_unroll.jai` (LoopUnrollPass.cpp + LoopUnrollAnalyzer.cpp + BasicTTI's unrolling/peeling
  preferences + CodeMetrics with convergence kinds), `loop_unroll_utils.jai` (Utils/LoopUnroll.cpp, loadCSE with a
  loop-scoped MemorySSA `mssa_build_loop`), `loop_unroll_runtime.jai` (LoopUnrollRuntime.cpp, SplitEdge,
  splitBlockBefore), `loop_peel.jai` (LoopPeel.cpp), `value_mapper.jai`, `clone_function.jai`, `loop_utils.jai`
  (loop metadata helpers, BranchProbability as `Bprob`), generated `gen_x86_sched.jai` (`gen/gen_x86_sched.py`:
  CPU -> scheduling model -> LoopMicroOpBufferSize; rerun after an LLVM bump). DESIGN.md "Cloning".
- **Reusable for the inliner / LoopVersioning / unswitch**: `Value_Map` + `map_value` / `remap_instruction` /
  `remap_dbg_record_range` (RF_* flags), `clone_basic_block(bb, *vm, suffix, f)` (f = NONE: detached block, link with
  `fn_insert_detached_block_before`), `remap_instructions_in_blocks`, `identify_no_alias_scopes_to_clone` +
  `clone_and_adapt_no_alias_scopes` (jump threading still has its own copy: jt_clone_no_alias_scopes),
  `clone_loop`, `fn_splice_blocks`, `split_edge`, `split_block_before`, `unroll_loop(li, l, ulo, dt, ac, tti, ...)`,
  `peel_loop`, `compute_peel_count`, `simplify_loop_after_unroll`, `make_followup_loop_id`,
  `add_string_metadata_to_loop`, `li_set_loop_already_unrolled`, `li_loop_estimated_trip_count`, `li_*_loop_attribute`,
  `tti_instruction_cost_ops` (getInstructionCost with replacement operands). The inliner needs the MDNodeMapper
  (module-level metadata cloning) and value handles in `Value_Map`: both fail loudly / are documented as missing.
- Fail loudly: `-unroll-add-parallel-reductions` (parallel reduction phis; no x86 TTI enables AddAdditionalAccumulators),
  discriminator cloning for `debugInfoForProfiling` compile units (cloneByMultiplyingDuplicationFactor),
  key-instruction atom groups, `#dbg_assign` remapping, ehAwareSplitEdge, the MDNodeMapper. `-pgso` /
  `require<profile-summary>` (PSI-based optsize) and `-O<n>` are not supported, which is what the 4 failing unit
  tests need.
- Shared fixes made here: SCEV `prove_no_wrap_by_varying_start` used signed -2/-1 deltas (LLVM's are 32-bit unsigned,
  see knowledge/llvm/loop-unroll.md); `split_landing_pad_predecessors` put the cloned landingpad before the new phis;
  `merge_block_into_predecessor` got the DT (no DTU) mode (`direct_dt`); `tti_instruction_cost` now delegates to
  `tti_instruction_cost_ops` (constant-expression users get at least 3 operand slots so the old reads stay
  identical — callers pass ConstantExprs, whose `inst_op` is garbage: a latent bug in compute_speculation_cost's use);
  `X86_Lowering.tune_cpu`; opt accepts `-disable-verify` and `-disable-loop-unrolling` (no effect on -passes runs).
- Sweeps (whole-file and `--per-function`): `loop-unroll`, `loop(loop-unroll-full)`: 0 differs, 0 bad-ir; loud only
  ppc_fp128 literals and LoopUnroll/pr77842.ll timing out (below). Also 0 differs with `--extra` `-unroll-runtime`,
  `-unroll-runtime -unroll-runtime-epilog=false`, `-unroll-force-peel-count=2`, `-unroll-count=3`,
  `-unroll-allow-partial -unroll-runtime -unroll-threshold=300` (loud: the discriminator case, timeouts).
  `loop(indvars)` and `print<scalar-evolution>` sweeps unchanged after the SCEV fix.
- Perf (x64 build, `-disable-output`, no @perf benchmark times loop-unroll): tests/perf/scaling/loops n2000/n8000
  0.29/4.2 s (LLVM 0.04/0.27), loops-many n500/n2000 3.0/72 s (LLVM 0.18/5.2; n8000 > 300 s for LLVM too). Almost all
  of it is ScalarEvolution trip-count computation (howManyLessThans -> loop-entry guards over every preceding loop,
  the same superlinear path as indvars) and SimplifyIndVar's SCEV queries after partial unrolling; the unroller
  itself is linear. pr77842.ll (an unroll-by-2048 pragma) takes LLVM 6 s and us > 60 s (simplifyLoopIVs on the
  unrolled body); IndVarSimplify/eliminate-exit.ll with -unroll-count=3 takes LLVM 31 s.

## SimpleLoopUnswitch (L1.unswitch 130/134: roundtrip 67/67, opt 63/67)

- `pass_simple_loop_unswitch.jai` ports SimpleLoopUnswitch.cpp (everything the pass does; not the O3-only
  ShouldRunExtraSimpleLoopUnswitch analysis / extra-simple-loop-unswitch-passes), LoopUtils' hasPartialIVCondition and
  SplitBlockAndInsertIfThen with an eager DomTreeUpdater + LoopInfo. `mssa_updater.jai` got updateForClonedLoop and
  updateExitBlocksForClonedLoop (Mssa_Clone_Ctx.region_set = IsInClonedRegion over loop + exit blocks). The cl::opts
  (`-enable-nontrivial-unswitch`, `-unswitch-threshold`, `-freeze-loop-unswitch-cond`, ...) are parsed by
  `unswitch_parse_cl_opt`. TTI.hasBranchDivergence is false for every target we support.
- The 4 failing tests need cgscc(inline), scc-oz-module-inliner, loop-interchange and `default<O1/2/3>`.
- `require<profile-summary>` exists now (passes.jai `psi_cached`; ProfileSummaryInfo itself is not ported). The passes
  that read a cached PSI (LoopUnroll, LoopLoadElimination, the LibCallSimplifier inside InstCombine) call `psi_check`,
  which fails loudly when the module has a `ProfileSummary` flag; without one every PSI query answers like a null PSI.
- ValueToValueMapTy semantics that matter here: values are WeakTrackingVHs (an erased cloned block must read as
  absent: `slu_vlookup` treats DEAD values as missing), and the one key RAUW (exit-block phi -> `.us-phi`) moves the
  key like ValueMap's FollowRAUW. Nothing else RAUWs a key while the maps are used.
- Debug records: LLVM keeps the records of a block whose terminator was erased as "trailing" records, and the next
  instruction inserted at the end adopts them (also a terminator moved with non-preserving moveBefore leaves its records
  behind). `slu.trailing` + `slu_erase_terminator_keep_trailing` / `slu_append` / `slu_move_terminator_to_end` model it;
  the pass fails loudly if trailing records are left at the end. `split_block(..., head = true)` is SplitBlock at
  `BB->begin()` (the head bit survives only when no phi / EH pad is skipped).
- Shared fixes: OptBisect prints the registered pass name without parameters (`simple-loop-unswitch`, `instcombine`,
  `loop-rotate`, not `instcombine<max-iterations=1>`); repeated `-mattr` options accumulate (cl::list, CommaSeparated).
- Sweeps (every round-tripping file; whole-file, `--per-function`, `--with-test-flags`, `--per-function
  --with-test-flags`) of `simple-loop-unswitch<nontrivial>` and `loop-mssa(simple-loop-unswitch<nontrivial>)`: 0 differs
  (loud only: other passes' options, `-enable-knowledge-retention` with loop pipelines, the ppc_fp128 parser gap).
  Also 0 differs: `sroa,loop-mssa(loop-rotate,licm,simple-loop-unswitch<nontrivial>)`, `sroa,loop(loop-rotate,
  simple-loop-unswitch<nontrivial>),loop-mssa(licm,simple-loop-unswitch<nontrivial>)`, `debugify,function(loop-mssa(
  simple-loop-unswitch<nontrivial>))`, `debugify,function(sroa,loop(loop-rotate,simple-loop-unswitch<nontrivial>))`, the
  4 tests/perf/compile programs, and the analysis sweeps `...,print<memoryssa>` (-verify-memoryssa) and `...,print<loops>`.
  `...,print<domtree>` shows 2 differences that are LLVM's own nondeterminism (pointer-ordered containers; LLVM gives
  different output on repeated runs: knowledge/llvm/loops-and-cycles.md).
- Perf (x64 build, `-disable-output`, no @perf benchmark times the pass): `sroa,loop-mssa(loop-rotate,licm,
  simple-loop-unswitch<nontrivial>)` minus the same without unswitch: sqlite3.ll +0.07 s, oggenc.ll +0.18 s (LLVM
  +0.02 / +0.0); the tests/perf/scaling loop shapes have no unswitch candidates (no measurable cost).

## VectorCombine (L1.vectorize.vector-combine COMPLETE 130/130)

- Files: `pass_vector_combine.jai` (VectorCombine.cpp, every fold in LLVM's order, the worklist driver),
  `tti_vectorizer.jai` (the TTI queries vectorizers ask: register classes/widths, getVectorInstrCost with explicit
  operands, getScalarizationOverhead with demanded lanes, arithmetic/min-max/extended/mul-acc reduction costs,
  commonOperandInfo; NoTTI answers for module without an x86 triple), `vector_utils.jai` (narrow/widenShuffleMaskElts,
  propagateIRFlags, reduction-intrinsic mappings, isVectorIntrinsicWithScalarOpAtArg with the splice/war-mask cases).
- State is one global `vc: Vc_State` per run (worklist `vc.wl` + `vc.wl_map` = a second InstructionWorklist, the pass's
  IRBuilder<InstSimplifyFolder> as `vc.b` with `vcb_*` creators). Local `IRBuilder<>` builders are plain `Irb`s with
  `irb_*` (ConstantFolder).
- Use `value_has_one_use` (not `has_one_use`) for anything that can be ConstantData: LLVM 23's constants have no use
  lists (knowledge/llvm/vectorizers.md).
- Fail loudly: VP intrinsics (scalarizeVPIntrinsic, foldBitcastOfVPLoad, isVectorIntrinsicWithScalarOpAtArg of a vp.*
  id), foldSelectsFromBitcast with more than one profitable condition group (DenseMap order).
- Sweeps (`--passes vector-combine`): whole-file 7754/7754 identical; `--extra='-mtriple=x86_64-unknown-linux-gnu
  -mcpu=X'` for x86-64, corei7-avx, skylake-avx512, znver4, btver2: 7752/7752 identical (2 llvm-failed);
  `--with-test-flags` 9455 identical / 0 differs (579 loud: other passes' cl::opts, -enable-knowledge-retention);
  `--per-function --with-test-flags` 93568 identical / 0 differs (3230 loud, same causes + 2 ppc_fp128 literals).
- Perf: no `@perf` benchmark times vector-combine; on tests/perf the pass is a no-op walk.

## SLPVectorizer (in progress; L1.vectorize.slp: 615/650 `::opt`)

- `-passes=slp-vectorizer` is registered (passes.jai) and its cl::opts are parsed (`slp_parse_cl_opt`). Files, in
  data-flow order (each names its LLVM functions in the header):
  - `slp_utils.jai` (cl::opts, static helpers, InstructionsState, getSameOpcode, SLPUtils.cpp), `slp_lookahead.jai`,
    `slp_operands.jai` (VLOperands), `slp_tree.jai` (state `slp`, Tree_Entry rows), `slp_ica.jai`
    (InstructionsCompatibilityAnalysis, PHIHandler).
  - `slp_driver.jai`: SLPVectorizerPass (complete). `slp_hor_reduction.jai`: HorizontalReduction matching,
    tryToReduce / tryToReduceOrdered with their emission (TrackedVals as WeakTrackingVHs, VectorizedVals,
    RequiredExtract, VectorValuesAndScales, const.rdx, emitScaleForReusedOps / emitReusedOps, emitReduction,
    createSingleOp, createOp, the final bool-logic-safe reduction ops), getReductionCost. The reduction has its own
    IRBuilder<TargetFolder> (`Hr_Builder`); `hrb_use(hb)` points the `sgb_*` calls at it for the rest of a scope.
  - `slp_build.jai`: BoUpSLP entry points + more state (`slpx`). `slp_build_tree.jai`: buildTree/buildTreeRec,
    legality, getScalarsVectorizationState, tryToFindDuplicates, canBuildSplitNode, canReuseExtract,
    canVectorizeLoads (with isMaskedLoadCompress and CheckForShuffledLoads; X86 has no strided accesses),
    isMaskedStoreCompress, isTreeTinyAndNotFullyVectorizable. `slp_sched.jai`: BlockScheduling (tryScheduleBundle,
    calculateDependencies, schedule) including ScheduleCopyableData (copyable elements are `Sched_Data` rows with
    `copyable` set, outside data_map; their four maps are `cd_*`), and scheduleBlock (its std::set ready list is
    `bs.ready` kept sorted by priority while `bs.sorted_ready` is set; equal priorities are one key, as in LLVM).
  - `slp_reorder.jai`: reorderTopToBottom / reorderBottomToTop (+ getReorderingData, libstdc++ heap for the
    PriorityQueue). `slp_gather.jai`: tryToGatherExtractElements, isGatherShuffledEntry,
    getLastInstructionInBundle, findReusedOrderedScalars. `slp_transform.jai`: transformNodes (incl.
    matchesShlZExt / matchesSelectOfBits / matchesInversedZExtSelect), reorderGatherNode. `slp_minbw.jai`:
    computeMinimumValueSizes / collectValuesToDemote (DenseSet<unsigned> order emulated). `slp_gathered_loads.jai`:
    gatherPossiblyVectorizableLoads, tryToVectorizeGatheredLoads.
  - The cost model: `slp_cost.jai` (getEntryCost with the GetCostDiff lambdas as `Slp_Ec` + `ec_scalar_elt_cost` /
    `ec_vector_cost` switches, loop-trip-count scales, getVectorSpillReloadCost, getGatherCost, getGEPCosts, the
    small TTI queries tti*.jai lacked), `slp_shuffle.jai` (BaseShuffleAnalysis, ShuffleCostEstimator,
    processBuildVector over `Bv_Builder`), `slp_tree_cost.jai` (buildExternalUses, getNumScalar/VectorInsts,
    calculateTreeCostAndTrimNonProfitable, getTreeCost with performExtractsShuffleAction, getSpillCost).
  - Code generation: `slp_codegen.jai` (the Builder = IRBuilder<TargetFolder> as `sgb_*` over `slpg.cb`,
    setInsertPointAfterBundle, gather, ShuffleInstructionBuilder as the `.IR` kind of `Bv_Builder` (processBuildVector
    is shared: every `bv_*` call switches on the kind; it returns `Bv_Res`), vectorizeTree(E) per opcode incl.
    compressed / masked-gather loads, expanded (masked) stores, insertvalue through a stack slot, reduced (cmp)
    bitcasts), `slp_codegen2.jai` (vectorizeTree() with postponed gathers, external-use extraction, shuffled
    insertelement users, scalar removal, removeInstructionsAndOperands, optimizeGatherSequence, ~BoUpSLP).
    TreeEntry::VectorizedValue is a WeakTrackingVH (`te_vv` / `te_set_vv` over value_handles.jai). eraseInstruction
    only marks (`slp_erase_instruction`, insertion-ordered `slpg.deleted_list`); removed-from-parent instructions
    drop their name (LLVM's symbol table forgets it) and their debug records move to the next instruction.
- Verified: every getTreeCost decision ("SLP: Found cost = ...", trees after earlier vectorizations included) on
  the whole corpus with each file's test flags equals LLVM's (`tools/slp_cost_compare.py`, 0 of 10293 runs differ).
- Frontier (fails loudly), per-function sweep: struct-typed scalars (42: calls returning structs, e.g.
  `llvm.sadd.with.overflow`, and the extractvalue nodes over them), target extension element types (7), VFDatabase
  vector variants (4); with test flags also REVEC (20) and other passes' options. Strided / interleaved accesses are
  unreachable on X86 and fail loudly where LLVM would build them.
- Next steps, in order:
  1. Struct-typed scalars: getWidenedType of a struct (a struct of vectors), checkEVsForVecCalls +
     StructEVIndices (getScalarsVectorizationState 10870, buildTreeRec 13284), allStructUsersAreExtractValueInsts,
     the struct paths of buildExternalUses (9644), getEntryCost (17303), getTreeCost's extract costs (20160-20320),
     vectorizeTree (23386, 23624, the call's TysForDecl 24326, the struct external-use extraction with
     StructFieldExtracts 24869-25169) and the driver (31471, 31939).
  2. VFDatabase vector variants (`-vector-library`, vector-function-abi-variant), REVEC.
  `tools/slp_cost_compare.py` compares whole decision sequences: run it with a `--with-test-flags` sweep's
  results.tsv after every change; DEBUG_SLP also dumps the module after each vectorizeTree ("DBG IR after
  vectorizeTree") and the CheckForShuffledLoads costs ("DBG cfsl").
- Compile time (x64 debug build): `-passes=slp-vectorizer` on tests/perf/compile costs ~2.5 s over parse+print for
  SPASS.ll / sqlite3.ll (LLVM: ~1 s total); no `@perf` benchmark times SLP. `comes_before` is a linear walk.
- Sorting: LLVM `stable_sort`s go through `gnu_stable_sort` (scev.jai, libstdc++'s algorithm) when the comparator
  may not be a strict weak order (PHICompare, compareCmp); insertion sort elsewhere. Hash-ordered containers that
  decide results fail loudly when the order matters (collectUserStores with several store groups).
  calculateTreeCostAndTrimNonProfitable's PriorityQueue has distinct (cost, Idx) keys, so a sorted list is exact.
- Fail loudly already in the helpers: REVEC, struct-typed scalars, VFDatabase vector variants, operand bundles in
  getSameOpcode / generateKeySubkey, VP intrinsics, target extension element types.
- Sweeps `--passes slp-vectorizer` (0 differs / 0 bad-ir in all): whole-file 7957 identical / 23 loud;
  `--with-test-flags` 10035 identical / 258 loud; `--per-function` 70407 identical / 55 loud; tests/perf/compile 4/4
  identical.
- Debugging:
  - `DEBUG_SLP` (slp_driver.jai) is a compile-time switch for `#if DEBUG_SLP` traces (tree entries, per-entry costs,
    "SLP: Adding cost C for bundle Idx: N" and "SLP: Found cost = X ..." in LLVM's -debug-only=SLP format, minbw
    roots, gather costs). They go to stdout, so build such a binary separately (set the switch, build, copy bin/opt to
    /tmp/opt_dbg, unset, rebuild).
  - An assertions build of LLVM's opt is at /persistent/llvm-rewrite/llvm-23.1.5-assert/bin/opt (rebuild with
    `tools/build_llvm_assert.sh` if missing): `-debug-only=SLP` dumps every tree entry with its scalar/vector costs.
    For LLVM internals it does not print (ShuffleCostEstimator, matchAssociativeReduction), add temporary
    `LLVM_DEBUG(dbgs() << "TRACE ...")` lines to /persistent/llvm-rewrite/llvm-assert-src/src/llvm/lib/Transforms/
    Vectorize/SLPVectorizer.cpp, `ninja opt` in ../build (~1-2 min), copy bin/opt elsewhere, restore the file and
    rebuild (the source tree and build dir are shared by every workspace: keep the edit window short).
  - `tools/slp_cost_compare.py LIST` diffs the decision sequences of both; `-pass-remarks=slp-vectorizer
    -pass-remarks-missed=slp-vectorizer` on the release opt also reports costs.
- LLVM quirks reproduced: TreeEntry::findLaneForValue's ValueToLane cache is never invalidated (stale lanes after
  reordering are used); in isGatherShuffledSingleRegisterEntry the `break` after CheckAndUseSameNode leaves only the
  gather-node loop, but the ones in the split / vectorized-entry checks leave the whole VL loop.
- Jai traps met here (all fixed): `cast(u64) x << 32` is `cast(u64) (x << 32)` - a 32-bit `x` loses its bits (it
  broke the (entry, edge) -> operand-entry map, the alias cache and X86 load-ext actions); write `(cast(u64) x) <<
  32`. A loop step written as `defer i += k` also runs on `return` / `break`, unlike a C `for` increment.

## Performance (compile time; jai_perf task, 2026-11)

`perf --impl jai` geomean CPU ratio: 3.88x (x64 build) -> 0.78x (optimized build of the same sources) -> 0.66x
(after the changes below); `--instr` on allocas, straightline and sqlite3.ll: 0.77x LLVM's instructions. Measured
with the optimized build, callgrind instruction counts (`valgrind --tool=callgrind`,
the "Ir" totals of one run). LLVM's own counts in the last column.

| workload (instructions, M) | before | after | LLVM |
| --- | ---: | ---: | ---: |
| `-S` sqlite3.ll (parse + print) | 1371 | 1141 | 2032 |
| `-passes=gvn` sqlite3.ll | 5018 | 3711 | 2640 |
| `-passes=dse` sqlite3.ll | 3640 | 2654 | 2305 |
| `-passes=sroa` allocas/n8000 | 1823 | 713 | 897 |
| `-passes=mem2reg` allocas/n8000 | 1563 | 621 | 837 |
| `-passes=instcombine` straightline/n16000 | 1710 | 1474 | 627 |
| `loop(loop-rotate,indvars)` loops-many/n500 | 1906 | 1167 | 757 |
| `loop(loop-rotate,indvars)` loops-many/n2000 (CPU s) | 6.3 | 4.1 | 3.6 |

What changed (behaviour identical: full ratchet, and sweeps of print<scalar-evolution>, indvars, loop-unroll,
loop-deletion, mem2reg, sroa, gvn, dse, instcombine, simplifycfg, adce, licm, memcpyopt, jump-threading,
print<domtree>, reassociate, aa-eval and `sroa,loop(loop-rotate,indvars,loop-idiom,loop-deletion)` show no new
differs or failures):
- Interning keys (`Key`) were built with one `array_add` per byte (~12% of parsing): now direct little-endian stores.
- `md_kind_id(literal)` was a string-hash lookup per call (10% of GVN/DSE via get_aa_metadata and memdep): hot paths
  use the `MDK_*` constants of the fixed kinds, others go through a verified direct-mapped cache.
- `type_int` caches widths <= 256. Trap: const_folding.jai has its own `type_int :: (bits: u32)` overload; it now
  forwards to the cached one (it was bypassing every cache: all SCEV constants went through it).
- mem2reg / SROA: block numbers moved from a global Table into `Block_Row.number`; IDF's visited sets are stamp
  arrays; mem2reg's def / live-in sets are `Block_Set`s; PHI and SROA names use `tconcat` instead of `tprint`
  (4 KB memset per call): sroa/mem2reg 2.5x fewer instructions.
- `dt_node` is a dense array lookup (was a Table per query; 18% of indvars on loops-many n2000 through
  compare_scev_complexity's dominance check of AddRec loops).
- SCEV: GroupByComplexity's grouping scan is O(n^2) per run of one kind (36% of indvars on loops-many n2000: umax/umin
  of hundreds of distinct loop guards); it only acts on duplicates, so it is skipped when there are none
  (`sc_has_duplicate_ids`). constantFoldAndGroupOps erased constants one by one (quadratic in Jai, whose ordered
  remove is an element loop): one compacting pass. `sc_get_constant` has a (width, value) cache.
- DataLayout struct layouts are cached (`dl_cached_struct_layout`); GEP offsets in GVN/BasicAA recomputed them
  recursively per query.
- Stack buffers instead of temp `[..]` arrays in `simplify_instruction` and `strip_pointer_casts_for_alias_analysis`.

Still slow / known:
- instcombine on straightline is 2.3x LLVM's instructions: known-bits recursion makes about as many calls as LLVM's
  computeKnownBits, each ~2x the work (KnownBits/APInt by value, pattern helpers). No single hotspot left.
- GVN and DSE, pass only (minus parsing): ~3x LLVM's instructions; spread over memdep, BasicAA, temp arrays.
- LoopUnroll/pr77842.ll (`-passes=loop-unroll`): 9.6 s vs LLVM 5.4 s and **5.7 GB RSS**: temp storage is only reset
  between passes, and the unrolled body's SCEV folding makes ~76M temp allocations (operand lists). Resetting temp
  inside SCEV is unsafe (wide APInts and ranges in caches may live in temp); fixing it means pooled operand lists.
- Every `[..]` with `allocator = temp` costs an allocator call on its first add (~100 instructions with
  array_reserve); in SCEV that's 6-8% of the time.

## CGSCC, FunctionAttrs, inliner (L2.function-attrs 106/118: roundtrip 59/59, opt 47/59; L2.inline 438/466: roundtrip 233/233, opt 205/233)

- Files: `lazy_call_graph.jai` (LazyCallGraph.cpp + print-lcg), `cgscc_pm.jai` (CGSCCPassManager.cpp, the
  `cgscc(...)` / `devirt<N>(...)` adaptors), `pass_function_attrs.jai` (FunctionAttrs.cpp, ConstantRangeList),
  `inline_cost.jai` (InlineCost.cpp + TTI inlining hooks + CodeMetrics ephemeral values), `inline_function.jai`
  (InlineFunction.cpp + CloneAndPruneFunctionInto), `pass_inliner.jai` (Inliner.cpp, AlwaysInliner.cpp,
  ModuleInliner.cpp, InlineOrder.cpp, the default InlineAdvisor, `inliner-wrapper`), `psi.jai` (ProfileSummaryInfo,
  ProfileSummary::getFromMD, SizeOpts' block query). DESIGN.md "CGSCC".
- Sweeps, every round-tripping corpus file, 0 differs: `cgscc(function-attrs)`, `inline`, `always-inline`,
  `module-inline`, `inliner-wrapper`, `require<profile-summary>,cgscc(inline)`, `cgscc(function-attrs,inline)`,
  `cgscc(inline,function(instcombine,simplifycfg))`, all also `--with-test-flags`;
  `cgscc(devirt<4>(inline,function(sroa,instcombine)))` 0 differs whole-file, 1 with test flags
  (InstCombine/new-delete-msvc.ll: an instcombine-only Windows `operator new/delete` pair, not an inliner issue).
  print-lcg: 7753/7754 identical; Analysis/GlobalsModRef/pr12351.ll differs (not investigated).
- APIs others can use: `lcg_get()` / `lcg_invalidate()`, `run_cgscc_adaptor`, `inline_function(cb, *ifi, merge_attrs,
  *aar, insert_lifetime, track_inlined_call_sites)`, `get_inline_cost(cb, params)`, `get_inline_params_t(threshold)`,
  `is_inline_viable(f)`, `get_attribute_based_inlining_decision`, `clone_and_prune_function_into`,
  `update_profile_callee`, `scale_prof_data`, `fn_set_entry_count`, `psi_get()` / `psi_cached_or_null()` /
  `psi_require()`, `psi_is_hot_call_site`, `should_optimize_for_size_bb(bb, psi, bfi)`, `value_is_rauwd(old, new)`
  (ValueHandleBase::ValueIsRAUWd without moving uses), `vmap_track_begin/_end` (tracking Value_Maps).
- ProfileSummaryInfo: `psi_cached` (passes.jai) = the module analysis exists; `require<profile-summary>` and
  `always-inline` (MAM.getResult) set it. The other PSI users (loop-unroll, loop-load-elim, LibCallSimplifier) still
  fail loudly through `psi_check` when a summary is cached; they can now use psi.jai instead.
- Fail loudly: `--enable-knowledge-retention` under `cgscc`, X86TTIImpl::areTypesABICompatible with differing
  features, `!memprof` / `!callsite`, strictfp callers, ObjC ARC attached calls, assignment tracking, the replay / ML
  advisors, `promoteCall` (devirtualising an indirect call with a known callee), the MDNodeMapper. Remaining L2.inline
  failures are those plus `-O<n>` / `default<O<n>>`, mergefunc, partial-inliner, scc-oz-module-inliner, globalopt,
  globaldce, early-cse, verify<domtree>. L2.function-attrs: attributor-light, `-O3` and inline pipelines.
- Trap: InstCombine's transformConstExprCastCall must call `value_is_rauwd(call, new_call)` when the old call has no
  uses: the CGSCC devirt wrapper's WeakVH on the call follows it, otherwise devirt<N> sees a "new" direct call and
  repeats (Inline/inline-indirect-chain.ll).
- Perf (`./harness/run perf`, optimized build, `-passes=inline` on scaling/calls): 3.9x / 3.9x / 3.5x LLVM's time at
  n = 500 / 2000 / 8000, scaling exponent 0.92 (LLVM 0.97). callgrind (x64 build, 120 functions): the same number of
  simplifyBinOp calls as LLVM (454,972); ~90% of the time is the shared InstSimplify / ConstantFold code called by
  CallAnalyzer::visitBinaryOperator (constant creation hashes a key per folded constant).


## LoopVectorize (in progress; L1.vectorize.loop 383/468 opt, 468/468 roundtrip)

- Files: `iv_descriptors.jai` (IVDescriptors.cpp), `lv_legality.jai` (LoopVectorizationLegality, LoopVectorizeHints,
  isDereferenceableAndAlignedInLoop), `lv_pass.jai` (runImpl / processLoop, computeMaxVF, collectValuesToIgnore, every
  cl::opt in `lv_opts`), `lv_cm.jai` (widening decisions incl. interleave groups, uniforms, scalars, X86 masked /
  gather legality), `lv_cost.jai` (the legacy LoopVectorizationCostModel costs: getInstructionCost and its memory /
  scalarization / call / div-rem / reduction-pattern helpers, collectInstsToScalarize + computePredInstDiscount,
  expectedCost, getPredBlockCostDivisor, interleave-group costs), `lv_interleave.jai` (InterleavedAccessInfo),
  `lv_plan.jai` (plan(), tryToBuildVPlan1 / buildVPlans / tryToBuildVPlan, the recipe builder, mem-op and call
  widening decisions, reductions result computation, FOR middle users, computeMinimumValueSizes), `lv_execute.jai`
  (the processLoop tail after computeBestVF: GeneratedRTChecks, isOutsideLoopWorkProfitable, epilogue gate,
  executePlan, skeleton, loop metadata, legacyCSE), `vplan*.jai`: `vplan.jai` (data model, VPBuilder, VPDT),
  `vplan_utils.jai`, `vplan_props.jai`, `vplan_construction.jai` (incl. foldTailByMasking, LoopVersioning noalias
  metadata `Lv_Noalias`), `vplan_simplify.jai`, `vplan_transforms.jai` (optimize(), licm, truncateToMinimalBitwidths,
  reassociateHeaderMask, materializeHeaderMask, ...), `vplan_predicator.jai`, `vplan_unroll.jai` (unrollByUF,
  replicateByVF), `vplan_replicate.jai` (replicate regions: create / sink / merge, unroll by UF, dissolve by VF, block
  and region cloning), `vplan_interleave.jai` (VPInterleaveRecipe, createInterleaveGroups, the narrowInterleaveGroups
  checks), `vplan_cost.jai` (VPCostContext, every recipe's computeCost, VPlan / region / block cost, precomputeCosts,
  cost(), computeBestVF, isMoreProfitable, willGenerateVectors, calculateRegisterUsageForPlan, selectInterleaveCount),
  `vplan_exec_transforms.jai`, `vplan_execute.jai`, `vplan_print.jai`; the X86 interleaved-access costs are
  `tti_interleaved.jai` (tables generated into gen_x86_tti.jai, keyed by the factor). `lv_epilogue.jai`: epilogue
  vectorization (selectBestEpiloguePlan, preparePlanForMain/EpilogueVectorLoop, connectEpilogueVectorLoop); the two
  executePlan runs share `lvp_execute_plan` (its `kind` parameter is EpilogueVectorizationKind).
- Done: the whole cost-model path for fixed VFs (legacy + VPlan costs, VF selection with isMoreProfitable and the
  trip-count tie breaks, interleave-count selection with register usage, the runtime-check / minimum-profitable
  trip-count gate), call widening (intrinsic vs. scalarized; vector library variants still loud), predicated
  scalarization with replicate regions, interleave groups (loads and stores, gaps without masks, reverse groups),
  tail folding by masking with the data-without-lane-mask style (header mask, masked loads / stores, tail-folded
  reductions and live-outs, narrowed canonical IVs), plus everything listed for the forced-VF path before. Then
  (jai_loopvec4): epilogue vectorization incl. forced epilogue VFs, optimizeFindIVReductions (sentinel and AnyOf
  forms), handleMultiUseReductions (+ handleFirstArgMinOrMax), replaceSymbolicStrides, the narrowInterleaveGroups
  transform, vector-library / VFDatabase variants (VPWidenCallRecipe), read-only uncountable early exits (dispatch
  blocks, FirstActiveLane / cttz.elts), LastActiveLane expansion, branch weights and estimated trip counts, final
  invariant stores of reductions, switches in the loop (switch edge masks), hoistPredicatedLoads /
  sinkPredicatedStores. `-passes=loop-vectorize` on the IR LLVM's -O2 pipeline feeds to LoopVectorize for every e2e /
  function / -O2-imported / perf file (`tools/o2_lv_inputs.py`, 919 modules): all identical.
- **Costs are fixed point**: LLVM 23's InstructionCost stores 4 * the cost (CostGranularity), so a block divided by a
  block-frequency divisor gives e.g. 8.5. The LV computes in that domain: `Lc` (= Cost scaled by 4; COST_INVALID is
  still invalid), `lcv` converts a TTI answer, `lt_*` wrap the tti_* queries, `lc_value` is getValue() (truncating),
  `lc_str` prints like InstructionCost::print. Keep TTI code in plain integers; only the LV scales.
- Debugging: `JAI_LV_DEBUG=1 bin/opt ...` prints LLVM's `-debug-only=loop-vectorize` cost lines ("LV: Scalar loop
  costs", "Cost of C for VF V: <recipe>", "Cost for VF V: C", "LV: Selecting VF", "LV: IC is" ...).
  `tools/lv_cost_compare.py FILE...` (or `-l results.tsv`) runs the assertions opt and ours on each `; @opt:` line
  and prints the first differing decision line and the first differing per-recipe cost. Over all LoopVectorize tests
  only `optimal-epilog-vectorization.ll` (forced epilogue VF, loud anyway) differs. `JAI_VPLAN_DEBUG=1` dumps plans.
- Sweeps `--passes loop-vectorize` (plain 8065 identical / 14 loud; `--with-test-flags` 10260 / 183 loud;
  `--with-test-flags --per-function` 97243 / 796 loud): 0 differs, 0 bad-ir. `sroa,loop-vectorize` on tests/perf/compile/*: 4/4
  identical. LV time is negligible next to sroa there.
- `tools/o2_lv_inputs.py OUT FILE...` collects (with LLVM's `-O2 -print-before=loop-vectorize`) the modules the -O2
  pipeline hands to LoopVectorize; `--compare OUT` runs both opts on them. Useful to rank what -O2 needs.
- Traps met: VPRegionValue is a VPSymbolicValue (m_LiveIn, getValueForPart, State.get accept it); int_pred_ty matchers
  look through Broadcast; m_Not also matches `xor x, -1`; GeneratedRTChecks treat a check folded to false as no
  check; handleFindLastReductions' `hasScalarVFOnly()` is false while building; a replicate clone is unnamed;
  VPlan live-in intrinsic folding is simplifyIntrinsic; createScalarCast without flags uses getDefaultFlags; X86 does
  not override enableMaskedInterleavedAccessVectorization; `int IndexA` in analyzeInterleaving truncates;
  getCostForRecipeWithOpcode's select matchers keep their last (partial) bindings (an OR's second operand info can be
  the `true` constant); isUniformAfterVectorization returns true for VF 1 *before* the pseudo-probe check;
  supportsEfficientVectorElementLoadStore is false, so scalarized loads do pay the insert overhead; the
  interleave-group metadata (addMetadata) intersects the members in DenseMap<int32_t> order (bucket (k * 37) & 63).
  `array_add(*vb(b).succs, vp_create_basic_block(...))` is a use-after-realloc: Jai evaluates `*vb(b).succs` (a
  pointer into `vpl.blocks`) before the call grows the array; create the block into a local first (a switch with
  four cases lost a successor this way). The same holds for `vr(r)` / `vv(v)` pointers across recipe / value creation.

### LoopVectorize next steps (each fails loudly with the quoted message today; counts are unit tests)

1. Outer loops (18: "outer-loop vectorization (VPlan-native path)"): legality for loop nests, buildVPlan for outer
   loops (nested regions), VPWidenPHIRecipe execution.
2. convertToStridedAccesses (10: "non-consecutive widened loads"): strided loads as `vp.strided.load` only when the
   target says legal (X86: never), so mostly the decision code plus gathers.
3. Scalable VFs (14: "scalable -force-vector-width", "scalable vectorization"): X86 has no scalable vectors, these
   tests force them; needs ElementCount arithmetic with vscale everywhere.
4. In-loop / ordered reductions (6): createInLoopReductionRecipes, VPReductionRecipe execute/cost,
   getReductionPatternCost; FMinNum/FMaxNum reductions (3: handleMaxMinNumReductions).
5. Tail folding leftovers: masked div/rem intrinsics (5), m_HeaderMask on materialized masks (4), active lane masks
   (1), masked interleave groups (1), unmasking uniform predicated stores (1); -force-partial-aliasing-vectorization
   (4); uncountable exits with side effects (canUncountableExitConditionLoadBeMoved, only with
   -enable-early-exit-vectorization-with-side-effects).
6. Small ones: struct-typed values (3), replicating llvm.assume (2), extract-lane execution for some VF (2),
   dereferenceable assumptions, constant-folding reduction intrinsics, PGSO (profile summary), discriminators,
   operand bundles on widened intrinsics, histograms.

## IPO: GlobalOpt, GlobalDCE, ConstantMerge, Internalize, DeadArgElim, ArgumentPromotion (L2.globals 443/450, L2.ipo-args COMPLETE 206/206)

- Files: `ipo_utils.jai` (GlobalValue/GlobalVariable/Function helpers: linkage predicates, setLinkage, getComdat,
  copyAttributesFrom, setInitializer, deleteBody, eraseFromParent incl. metadata, destroyConstant,
  collectUsedGlobalVariables, CtorUtils' optimizeGlobalCtorsList, GlobalStatus, and the signature-rewriting helpers
  `ipo_fn_create` / `ipo_fn_copy_attributes_from` / `ipo_fn_splice_body` / `ipo_create_call_like`),
  `evaluator.jai` (Evaluator; MutableValue/MutableAggregate are rows), `pass_global_opt.jai`, `pass_global_dce.jai`
  (+ TypeMetadataUtils' getPointerAtOffset), `pass_constant_merge.jai`, `pass_strip_dead_prototypes.jai`,
  `pass_elim_avail_extern.jai` (+ getUniqueModuleId), `pass_internalize.jai` (+ GlobPattern matching),
  `pass_assign_guid.jai`, `md5.jai`, `pass_dead_arg_elim.jai`, `pass_arg_promotion.jai` (a CGSCC pass:
  `run_cgscc_pass` case). knowledge/llvm/ipo-globals-and-arguments.md has the LLVM facts.
- Sweeps, every round-tripping file, 0 differs plain and `--with-test-flags`: globalopt (also `--per-function`),
  globaldce, constmerge, strip-dead-prototypes, elim-avail-extern, internalize, deadargelim,
  `deadargelim,function(instcombine),function(dce)`, argpromotion. Remaining L2.globals failures need `-O2`,
  `lto<O2>`, `default<O0>` or early-cse.
- Traps: a blockaddress is a constant *user* of its function in our IR but not in LLVM 23: skip `C_BLOCKADDR` users
  whenever a pass walks a function's uses (`go_users`, `dae_call_users`, `ap_fn_users`, `fn_use_empty`;
  `fn_has_address_taken` now skips them too). RAUW of a global or argument must also move its metadata
  (`ipo_rauw` / `rauw_with_metadata`); erasing a global goes through `gv_erase_from_parent` (MetadataAsValue
  operands become `!{}`, MDTuple operands null). Module lists are plain arrays: `list_index_of_hint` keeps the
  early-inc loops linear.
- `-f` and `-emulated-tls` are accepted and ignored by opt_main (they don't change IR passes).
- Fail loudly: `-avail-extern-to-local` (convertToLocalCopy of functions), X86 areTypesABICompatible for extended
  value types / AVX-512 masks / bf16 across subtargets, rewriting callbr call sites, replacing the type of a uniqued
  DISubprogram.
- Perf (optimized build): `-passes=globalopt` on scaling/globals 0.73-0.87x LLVM's CPU, k = 1.00 (LLVM 1.09);
  globalopt / globaldce / deadargelim / argpromotion on SPASS.ll and sqlite3.ll are below LLVM's time.

## L1.scalar-misc: LowerExpect, LowerConstantIntrinsics, InferAlignment, DivRemPairs, Float2Int, Sink, TailCallElim, MergedLoadStoreMotion, SpeculativeExecution, CallSiteSplitting (217/218)

- Files: `pass_lower_expect.jai`, `pass_lower_constant_intrinsics.jai` (+ `replace_and_recursively_simplify`),
  `pass_infer_alignment.jai`, `pass_div_rem_pairs.jai` (+ `tti_has_div_rem_op` in tti.jai), `pass_float2int.jai`
  (its own EquivalenceClasses: Members in insertion order, leader lists), `pass_sink.jai`, `pass_tailcallelim.jai`
  (+ FoldReturnIntoUncondBranch, an eager DT+PDT updater `Tre_Dtu`), `pass_mldst_motion.jai`
  (`mldst-motion<[no-]split-footer-bb>`), `pass_speculative_execution.jai` (`<only-if-divergent-target>`: X86 and
  NoTTI have no branch divergence, so that form is a no-op), `pass_callsite_splitting.jai`. All their cl::opts are
  parsed in `scalar_misc_cl.jai`, which also lists the integer ones LLVM's tests write as `-name value`
  (`scalar_misc_takes_value`, called from opt_main).
- `require<memdep>` is a registered no-op: MemoryDependenceAnalysis is a lazily filled cache and no pass we have
  reads a *cached* memdep (GVN builds its own).
- `remap_debug_variable` (DuplicateInstructionsInSplitBetween, shared with JumpThreading) now also remaps a
  `#dbg_assign`'s address operand (RemapAssignAddress) instead of failing.
- The one remaining exit test is `MergedLoadStoreMotion/st_sink_bugfix_22613.ll` (`-O2`).
- Sweeps (every round-tripping file, plain and `--with-test-flags`, and `sroa,<pass>` on tests/perf/compile): 0
  differs / 0 bad-ir for all ten passes. Loud failures are only other passes' options (`-earlycse-debug-hash`,
  `-slp-revec`, ...), `-enable-knowledge-retention`, and 2 files with ppc_fp128 constant folding (float2int).
- Perf: no tests/perf benchmark times these passes alone (`-O2` rows don't run yet). Sink keeps its store set as a
  table (SmallPtrSet); MLSM is bounded by MagicCompileTimeControl like LLVM.

## The rest of the -O2 pipeline's small passes (jai_scalar_misc, 2026-11)

- Ported in full: `loop-sink` (pass_loop_sink.jai; profile-only, uses licm_can_sink_or_hoist_inst on a Licm state),
  `transform-warning` (warnings on stderr in the default handler's format), `drop-unnecessary-assumes[<drop-deref>]`,
  `jump-table-to-switch` (incl. value-profile weights and the !guid / MD5(PGO name) lookup), `move-auto-init`,
  `alignment-from-assumptions`, `libcalls-shrinkwrap` (incl. strictfp constrained compares),
  `called-value-propagation` (+ a SparseSolver specialized to its lattice; prefix `clv_`, `cvp_` is
  CorrelatedValuePropagation), `rel-lookup-table-converter`, `cg-profile` (indirect calls with VP data fail
  loudly), `ee-instrument<[post-inline]>`, `memprof-remove-attributes`, `recompute-globalsaa`.
- Early exits that are exact for every module without the feature (and fail loudly otherwise): `coro-early`,
  `coro-cleanup`, `coro-elide`, `coro-split`, `coro-annotation-elide` (no coroutine intrinsics / presplit
  functions / `.noalloc` callees), `openmp-opt`, `openmp-opt-cgscc` (no "openmp" module flag), `alloc-token` (no
  sanitize_alloc_token, no llvm.alloc.token.id), `lower-comment-string` (non-AIX), `forceattrs` (its flags are
  rejected), `annotation2metadata` / `annotation-remarks` (remarks are never enabled), `inject-tli-mappings` (no
  vector library).
- Pipeline structure: `function<eager-inv;no-rerun>` (parse_function_pipeline_name; module-level eager-inv now
  invalidates after each function), `require<should-not-run-function-passes>` (Analysis_Kind.SHOULD_NOT_RUN; the
  no-rerun CGSCC adaptor skips functions that have it cached), `invalidate<aa>` (no AA state is cached),
  `extra-simple-loop-unswitch-passes` (empty when parsed from text, see knowledge/llvm/scalar-misc.md), `-relocation-model`
  (static / pic / dynamic-no-pic: X86TargetMachine's effective model; `-code-model` is still rejected).
- gen_intrinsics.jai only knows intrinsics declared somewhere in tests/: tests/roundtrip/intrinsics/pass-created.ll
  declares the ones passes create (llvm.returnaddress, llvm.load.relative); add more there.
- Sweeps (plain, every round-tripping file): 0 differs for every pass above; `--with-test-flags` for
  rel-lookup-table-converter 0 differs.
- With the 8 passes still missing removed from `default<O2>`'s printed pipeline (early-cse x2, ipsccp, sccp,
  mergeicmps, expand-memcmp, dfa-jump-threading, loop-interchange; /tmp-style: sed them out of
  `opt -passes='default<O2>' -print-pipeline-passes`), a sweep over tests/e2e/pipeline + tests/function/pipeline
  gives 170 identical / 241, 69 loud (vectorizers: InterleavedAccessInfo, SLP vectorizeTree, ...), 2 differs:
  e2e/pipeline/memory/heap.ll and calls/function_pointers.ll get `trunc nuw` where LLVM has `trunc nuw nsw` after
  the first correlated-propagation in the CGSCC pipeline (opt-bisect position 20). The same passes run standalone
  on the bisected input agree, so it is a difference in cached analysis state carried through the earlier part of
  the pipeline (LVI / AssumptionCache / DT caching): a lead for L2.pipeline-O2.

## EarlyCSE (L1.early-cse COMPLETE 96/96)

- File: `pass_early_cse.jai` (`early-cse`, `early-cse<memssa>`, `-earlycse-mssa-optimization-cap`,
  `-earlycse-debug-hash` accepted and ignored). The five ScopedHashTables share one bucket store (`Ec_Bucket`: key of
  the first insertion + hash at insertion time, chained per hash) and one value list (`Ec_Val` = ScopedHashTableVal);
  every dominator-tree scope starts its own `next_scope` chain at -1 (forgetting that made a scope exit pop the
  parent's entries too). A lookup that would read a value LLVM has already freed (a stale bucket) fails loudly.
- `salvage_knowledge(i, ac)` (assume_builder.jai) now has LLVM's AssumptionCache form (tryToPreserveWithoutAddingAssume
  and registering the new assume); `knowledge_retention_check` allows early-cse.
- `replace_dominated_uses_with_edge` (pass_early_cse.jai) is LLVM's replaceDominatedUsesWith(From, To, DT, Edge).
- Sweeps (0 differs / 0 bad-ir): `early-cse` and `early-cse<memssa>` whole-file 7817/7826 (9 loud: nextafter,
  frexp ranges, ppc_fp128 folding, x86 hadd known bits, operand-bundle capture tracking), `--with-test-flags`
  10003/10113 (loud: other passes' options), `--per-function` 69904/70067; `sroa,early-cse[<memssa>]` on
  tests/perf/compile 4/4. No tests/perf benchmark times early-cse alone.

## SCCP, IPSCCP, PredicateInfo, FunctionSpecialization (L1.sccp COMPLETE 340/340)

- Files: `predicate_info.jai`, `sccp_solver.jai`, `pass_sccp.jai`, `function_specialization.jai` (DESIGN.md file map).
  Also imported `tests/imported/llvm/Transforms/FunctionSpecialization` (59 files; 58/59 `::opt` pass, the other needs
  `default<O3>`); `tests/imported/llvm/Transforms/Util/PredicateInfo` 8/8 `::analysis`.
- Shared changes: `isa_constant_int` (value_lattice.jai): scalable int splats are C_INT here but a shufflevector
  constant expression in LLVM, so ValueLatticeElement::markConstant must not treat them as ConstantInt (also affects
  LVI); `change_to_unreachable` now moves the erased terminator's debug records onto the new `unreachable`
  (flushTerminatorDbgRecords) instead of dropping them; `verify<domtree>` is a registered no-op requiring the DT;
  `salvage_knowledge(i, ac)`; TTI: scalar `llvm.modf/sincos/sincospi` costs no longer fail (only struct-of-vector
  results take getMultipleResultIntrinsicVectorLibCallCost).
- Data layout: one `Sccp` per pass run. `lat: [..] Vle` holds every lattice value, `value_state` / `struct_state`
  (key `v << 32 | i`) / tracked globals / return values hold indices, so references survive insertions (LLVM re-fetches
  DenseMap references in the same places). Iteration orders: TrackedRetVals / TrackedMultipleRetVals MapVectors,
  InstWorkList a SetVector popped from the back, AdditionalUsers a SetVector per value, SmallPtrSets in insertion order
  (LLVM's are in small mode at the sizes that occur; where LLVM's order is pointer order and the result depends on
  it, function specialization fails loudly: OriginalFuncs with more than 8 functions calling each other).
- FunctionSpecialization: CloneFunction maps metadata like the MDNodeMapper under createIdentityMDPredicate
  (distinct nodes reachable from the function are cloned, uniqued ones re-uniqued when an operand changed); the results
  go into the Value_Map's MD map before RemapInstruction. `#dbg_assign` records and uniqued metadata cycles fail
  loudly. The candidate selection uses libstdc++'s make_heap / push_heap / pop_heap (fs_make_heap & co.).
- Sweeps (0 differs / 0 bad-ir; loud only ppc_fp128 folding, other passes' options): `sccp`, `ipsccp` whole-file
  7823/7826, `--with-test-flags` ~10000/10113, `function(sroa),sccp|ipsccp` on tests/perf/compile 4/4,
  `print<predicate-info>` 7825/7826 (pr12351 debug-info warning, the known diagnostic gap). FS stress:
  `ipsccp --extra=-force-specialization` 7823/7826, `-funcspec-min-function-size=1` 7823/7826, perf/compile with
  `-force-specialization` 2 identical / 2 loud (SmallPtrSet order).
- Perf: no tests/perf benchmark times sccp/ipsccp alone.

## MergeICmps, DFAJumpThreading (L1.o2-gaps: MergeICmps 23/23, DFAJumpThreading 10/10)

- Files: `pass_mergeicmps.jai`, `pass_dfa_jump_threading.jai` (DESIGN.md file map). Imported tests:
  Transforms/MergeICmps, Transforms/DFAJumpThreading, Transforms/LoopInterchange (roadmap unit L1.o2-gaps).
- MergeICmps runs only with a target (X86's enableMemCmpExpansion; the default target has no memcmp expansion).
  `AM.getResult<AAManager>` comes first: BasicAA computes the DominatorTree, which the pass then updates through
  its eager DTU (and which a later print<domtree> shows). llvm::sort of the comparisons is an insertion sort up to
  16 elements; larger chains with equal keys fail loudly (introsort order). `EntryBlock_->isEntryBlock()` is asked
  after the merged blocks were inserted in front of it (so setNewRoot practically never runs; ported as is).
- DFAJumpThreading requests DT / LoopInfo / TTI before the optsize early exit (LoopInfo updates the DT's DFS
  numbers, visible in print<domtree>); `LI->verify(DTU->getDomTree())` in a release build only flushes the DTU.
  SSAUpdaterBulk::RewriteAllUses is ported inside the pass (new phis go to the front of the IDF blocks).
- Sweeps (0 differs / 0 bad-ir / 0 loud): `mergeicmps -mtriple=x86_64-unknown-linux-gnu` 7884/7884,
  `--with-test-flags` 10075/10189 (loud: other passes' options), `mergeicmps,print<domtree>`;
  `dfa-jump-threading` 7885/7885, stressed with `-dfa-cost-threshold=100000 -dfa-early-exit-heuristic=false
  -dfa-max-cloned-rate=1000` (also `,print<domtree>`); `function(sroa),<pass>` on tests/perf/compile 4/4 for both.
- Not done: LoopInterchange (`loop-interchange`, the last -O2 gap besides expand-memcmp). It is a LoopNest pass that
  needs DependenceInfo::depends (lib/Analysis/DependenceAnalysis.cpp + Delinearization.cpp; SCEV-based subscript
  tests) for its direction matrix in every configuration, and LoopCacheAnalysis (CacheCost) only for the `cache`
  profitability rule, which is not in the default list (`instorder,vectorize`). Plan: port DependenceAnalysis with
  its `print<da>` printer first (tests/imported/llvm/Analysis/DependenceAnalysis, import it), then the pass;
  `-loop-interchange-profitabilities=cache` can fail loudly until LoopCacheAnalysis is ported.
