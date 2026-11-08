# impl/goose notes

- Goose is [aardappel/goose](https://github.com/aardappel/goose), installed at `/opt/goose-v2026.4` (`goose` on PATH).
  It's a very new language, so you have almost no prior knowledge of it. Read the docs before writing code:
  `/opt/goose-v2026.4/docs/` has `tutorial.md`, `reference.md`, `goose_spec.md`, `stdlib.md`,
  `command_line.md`, and "Goose for C++ and Rust Programmers Translating Common Patterns.md". There are also
  31 programs in `/opt/goose-v2026.4/samples/`.
- Goose's memory model shapes the design: there's no heap, no allocator, no GC. All dynamic data lives on
  compiler-managed data stacks, with at most one growable value on top of each stack, freed at scope exit.
  Recursive functions can't keep growable data across a recursive call. See `DESIGN.md` for how the IR lives in
  global id-indexed tables because of this.
- `build.sh` runs `goose build --cc /opt/llvm-23.1.5/bin/clang -o bin/<tool> src/<tool>.goose`. Build products live
  under `~/.goose` (`GOOSE_HOME`). `goose build --debug` turns on overflow, range and tag checks. Use it when
  chasing a crash.
- `llc` and `llvm-link` are still placeholders that exit with "not implemented yet". `opt` runs `-passes=`
  pipelines (DESIGN.md §9) with dce, adce, bdce and the domtree/postdomtree/demanded-bits printers; `-O<n>` and
  unported passes exit 1 with "not implemented yet".

## Status

- L1.analysis.aa 79/84 analysis (+153 roundtrip). Left: `128-bit-ptr.ll` and `pr35843.ll` need APInt offsets
  wider than 64 bits in BasicAA (fails loudly); `libfuncs.ll`, `libfuncs-darwin.ll`, `memset-pattern.ll` run
  `-mtriple=… -passes=inferattrs,…` (opt's `-mtriple`, the InferFunctionAttrs pass with BuildLibCalls' attribute
  table, and a Darwin TLI are not ported). L1.analysis.memoryssa 34/41: the 7 left run loop passes
  (`loop-mssa(licm|loop-rotate|simple-loop-unswitch)`). aa-eval and both MemorySSA printers agree with LLVM on
  every one of the 5007 `tests/imported/llvm/Transforms/*/*.ll` files except a few parser/printer issues
  (below) and give byte-identical `print<memoryssa>` on sqlite3.ll. Speed (by hand; no `@perf` line times
  them): building MemorySSA is faster than LLVM (sqlite3 +0.03 s vs +0.05 s) and linear on tests/perf/scaling;
  aa-eval is ~2.5x slower than LLVM's on sqlite3 (2.8 s vs 1.1 s; per-query attribute/TLI lookups), same
  O(pointers²) shape.

- L1.mem2reg 59/60 (the one left runs `instcombine`). L1.sroa 119/122 (left: 2 tests run `debugify`, 1 runs
  `gvn,instcombine,simplifycfg`). Both give output identical to LLVM's on all tests/e2e O0 and pipeline inputs
  and on the four tests/perf/compile programs, and run 1.3-2.5x faster than LLVM there; linear on
  scaling/allocas (k 1.04 mem2reg, 1.07 sroa; LLVM 1.19, 1.25).
- L1.analysis.domtree and L1.analysis.demanded-bits complete. L1.analysis.loops 24/28: LoopInfo and CycleInfo
  complete, the 4 left are `print<loopnest>` (a loop pass: needs the loop pass manager, LoopSimplify+LCSSA
  canonicalization in the adaptor, and ScalarEvolution for `Loop::getBounds`). L1.loop-canonical: loop-simplify and
  lcssa pass 31 of their 58 `::opt` tests; every other one stops loudly (other passes in the pipeline: licm,
  loop-mssa, instcombine, debugify, verify<scalar-evolution>, -keep-loops; and LoopSimplify's exit merging,
  which needs SimplifyCFG's foldBranchToCommonDest). loop-simplify, lcssa, break-crit-edges and adce give
  byte-identical `-S` output (use-list order included) on all four tests/perf/compile programs and run faster
  than LLVM's there and on tests/perf/scaling (no `@perf` line times them; measured by hand). L1.dce 99/112 (the 13 left need other passes, `--preserve-ll-uselistorder`,
  `--enable-knowledge-retention` or salvageDebugInfo). dce/adce/bdce run 2-4x faster than LLVM's on
  tests/perf/compile and scale linearly on tests/perf/scaling (measured by hand: no `@perf` line times them).
  bdce on sqlite3.ll stops at a loud "isKnownNonZero not ported".
- L0.design, L0.print-basic, L0.print-clang, L0.print-imported complete (6994/6994). Parse+print is ~3x faster
  than LLVM's opt (`perf`). x86 intrinsic upgrades: `shouldUpgradeX86Intrinsic` is ported whole, but only the
  call rewrites the corpus needs (autoupgrade_x86.goose); any other upgraded name stops loudly.

## Source map

| File | What |
| --- | --- |
| `src/ir.goose` | All IR tables: strings, types, values, uses, constants, instructions, blocks, globals, symbol tables, attributes, metadata |
| `src/lexer.goose` | LLLexer port (tokens as global state; `lex_save`/restore by position) |
| `src/parser.goose` | LLParser port: module, globals, functions, instructions, constants, attributes, metadata, forward refs |
| `src/printer.goose` | AsmWriter port: SlotTracker, TypeFinder, all printing, attribute `getAsString` |
| `src/apfloat.goose` | FP formats: decompose/encode, correctly rounded decimal parsing, `APFloat::toString` port |
| `src/bignum.goose` | u32-limb bignums for wide ints and exact FP conversion |
| `src/datalayout.goose` | DataLayout (sizes, alignments, struct layout) and x86 `computeDataLayout` |
| `src/gen_attrs.goose` | generated by `tools/gen_tables.py`: AttrKind enum order and names, fixed metadata kinds |
| `src/gen_intrinsics.goose` | generated by `tools/gen_intrinsics.py` from TableGen's IntrinsicImpl.inc (`tools/build_min_tblgen.sh` builds llvm-min-tblgen from the LLVM sources, ~15 s): names, overload bits, IIT signatures, attributes |
| `src/intrinsics.goose` | Intrinsics.cpp port: `intr_lookup` (lookupIntrinsicID), `func_iid`, signature matching, `intr_get_type`, name mangling, `intr_attributes` |
| `src/autoupgrade.goose` | AutoUpgrade.cpp subset: intrinsic remangling/renames, masked/mem*/lifetime/objectsize/annotation/coro.end/convert.fp16/struct-return upgrades, dbg intrinsics -> records, TBAA tags, module flags, UpgradeDebugInfo/StripDebugInfo |
| `src/autoupgrade_x86.goose` | shouldUpgradeX86Intrinsic (whole) and an IRBuilder-with-ConstantFolder subset for the ported x86 call upgrades |
| `src/calls.goose` | CallBase layout accessors (`cb_*`): args, operand bundles, invoke/callbr destinations |
| `src/dinfo.goose` | `!DI*` node schemas (field order/types/defaults, MDNode operand order), DWARF name tables, debug records |
| `src/constfold.goose` | ConstantFold.cpp + `ConstantExpr::get*` (`ce_*` create-or-fold, `cf_*` fold-or-`-1`), APInt<=128 subset |
| `src/gen_dwarf.goose`, `src/gen_cc.goose` | generated by `tools/gen_dwarf.py` / `tools/gen_cc.py` from Dwarf.def, DebugInfoFlags.def, CallingConv.h and AsmWriter |
| `src/domtree.goose`, `src/dtu.goose` | Dominator trees with incremental updates; DomTreeUpdater |
| `src/loopinfo.goose`, `src/cycleinfo.goose` | LoopInfo (+ update API, loop metadata), CycleInfo |
| `src/breakcrit.goose`, `src/loopsimplify.goose`, `src/lcssa.goose` | SplitCriticalEdge/break-crit-edges, SplitBlockPredecessors + LoopSimplify, LCSSA |
| `src/analyses.goose` | Analysis ids, preserved sets |
| `src/memloc.goose` | MemoryLocation/LocationSize, ModRef, MemoryEffects, CaptureInfo, CallBase operand attribute queries, identified objects, stripPointerCastsForAliasAnalysis |
| `src/aa.goose` | AAResults aggregation, AAQueryInfo (cache, assumptions, capture analyses), BasicAA, getBaseObjectSize |
| `src/tbaa.goose`, `src/globalsaa.goose` | TypeBasedAA + ScopedNoAliasAA; GlobalsAA with CallGraph and Tarjan SCCs |
| `src/capture.goose`, `src/aautil.goose` | CaptureTracking (3 trackers); private stamp sets (`ss_*`) and CFG reachability (`cfr_*`) |
| `src/memoryssa.goose`, `src/phitrans.goose` | MemorySSA (build, walker, OptimizeUses, printers); PHITransAddr |
| `src/aaeval.goose` | the aa-eval pass |
| `tools/gb.sh` | `tools/gb.sh src/opt.goose bin/opt` builds with warnings hidden (Goose has no `-w`) |

## Goose traps (cost me time)

- `block`, `type`, `in`, `self`, `pad` are keywords: they can't be field names.
- Integers don't mix: `u32 + i32` is an error, `i32` into an `i64` parameter is fine, the reverse needs `as`.
  `x as T` is range-checked in `--debug`, `as!` never. `%` is Euclidean, `/` truncates.
  Every `as i64` of a narrower value is a *warning* ("redundant"), and the compiler prints hundreds of them; there is
  no flag to silence warnings, hence `tools/gb.sh`.
- Error line numbers are sometimes beyond the end of the file (`src/ir.goose:1371` for a 1100-line file); search for
  the quoted source line instead.
- `std::split` returns slices whose root the checker ties to unrelated arrays. Calling a function that shrinks a
  global (`src.resize(...)`) while such slices are live is rejected. Parse by index instead (see `dl_parse`).
- A function whose result is a slice of a global (`fn sbytes(id) -> const u8[:]`) is fine; storing those slices in
  growing tables is not what we do: all cross-references are `i32` ids.
- Recursive functions (type/constant/metadata parsing and printing) must not have growable locals in scope at a
  recursive call; they use shared global stacks (`tstack`, `vstack`, `mstack`, `astack`) with a mark and `resize`.
- A grow-only global can be shrunk (`resize`) when nothing points into it.
- All modules share one namespace for functions: two files defining `is_cint` make every caller ambiguous
  ("multiple overloads match equally well"). Prefix helpers of a new file (`cf_*`, `au_*`, `di_*`).
- `var`, `f32` (and other type names) can't be used as field or variable names.
- A call cycle through several functions needs every function on it declared `recursive fn`; the compiler names
  one per error, so adding constant folding (mutually recursive `ce_*`/`cf_*`) took a loop of rebuilds.
- Array literals with ~10^4 elements make `goose build` take minutes (gen_intrinsics first took 4m43s); one long
  string literal decoded at run time compiles in a second.
- A function that can shrink a global (`out.resize`) may not be called inside a `for` over a literal array of
  strings (the checker assumes the strings may point into the global). Write into a local buffer instead.
- Trailing blocks as comparators work: `sort(xs) { a, b => ... }`.

## Design debts / things a pass porter must know

- **Ids, not references.** Every entity is an `i32` index; `-1` is none. `vals[v].sub` points into the kind's
  table (`insts`, `blocks`, `globs`, `csts`, `args_parent`). `op(v, k)` / `set_op(v, k, x)` / `push_op` are the
  operand API; `set_op` is `Use::set` (pushes at the head of the new value's use list). `rauw` is LLVM's loop.
  The parser uses `rauw_with_constants`, which re-uniques constant users (`handleOperandChange`).
- **Erase**: passes use `inst_erase_from_parent` (irutil.goose), which also removes the name from the symbol
  table (the raw `inst_erase` doesn't). Ids are never reused (DESIGN.md §2.3, §8).
- **Operand growth**: `add_op_slot` grows like `PHINode::growOperands` via `grow_ops`, which reproduces
  `growHungoffUses`' use-list effect. Switch (`3n`) and indirectbr (`2n`) growth must call `grow_ops` with their
  own capacity first.
- **Constants are folded on creation** like LLVM: the parser builds constant expressions only through
  constfold.goose (`ce_cast`, `ce_binop`, `ce_gep`, `ce_extractelement`, ...). `c_splat` is ConstantVector::getSplat
  (a scalable splat is a `shufflevector(insertelement ...)` expression, printed `splat (...)`); a null vector of
  pointers is a vector-typed `VK_CNULL`.
- **Metadata**: specialized nodes are `MK_DI` with one slot per schema field (dinfo.goose; integers are
  `MK_INTLIT`, normalized to -1 when equal to the default so uniquing matches). `MK_DIEXPR` is a node without a
  slot, `MK_DIARGLIST` is not a node. Forward references are temporaries overwritten in place; `md_merge_uniqued`
  (end of parse) merges uniqued nodes that became equal, like re-uniquing after RAUW. SlotTracker/TypeFinder walk DI
  operands in LLVM's MDNode operand order (`DIK_OPORDER`), not field order.
- **Debug records** (`dinfo.goose`): `inst_first_dbg(iv)`/`dbgrecs[r].next`. Call `dbg_records_to_next(iv)` before
  erasing an instruction (DbgMarker::removeMarker moves them to the next instruction).
- **Intrinsics**: all ~16400 intrinsics are known (`func_iid`), with exact attributes and signatures. Re-run
  `tools/build_min_tblgen.sh && python3 tools/gen_intrinsics.py` only when LLVM changes; then rerun
  `tools/gen_iids.py` (IID_* constants are derived from the names table). Big generated tables are hex strings:
  Goose takes minutes to compile array literals with tens of thousands of elements, seconds for one long string.
- **Not parsed yet** (fail loudly): `GenericDINode`, hex float literals (`0x1.8p+1`), most x86 intrinsic call
  upgrades (see autoupgrade_x86.goose for the ported ones), arm/aarch64/nvvm/amdgcn upgrades, `llvm.dbg.addr`, most of the Verifier's debug-info checks (only "inlinable call
  without !dbg" strips debug info), ppc_fp128 values that need two doubles.
- **DataLayout inference** only knows x86 triples; other triples fail loudly.
- No verifier yet.

## Pass infrastructure (L1.dce)

- Files: `passmgr.goose` (pipeline + dispatch), `flags.goose` (cl::opt, errs, value printing for printers),
  `irutil.goose` (CFG, mutation, scratch sets), `instinfo.goose` (instruction/call properties), `domtree.goose`,
  `anaprint.goose`, `tli.goose` + `gen_tli.goose` (`tools/gen_tli.py`), `local.goose` (Local.cpp dead predicates),
  `knownbits.goose`, `demandedbits.goose`, `dce.goose`, `adce.goose`, `bdce.goose`, `gen_passes.goose`
  (`tools/gen_passes.py`), `gen_iids.goose` (`tools/gen_iids.py`, reads `gen_intrinsics.goose`: rerun it when that
  file is regenerated).
- Goose trap: `a[f()]` where `f` grows `a` reads `a`'s bounds before `f` runs ("index out of bounds (length 0)").
  Compute the index into a local first. domtree.goose grows its tables in `dt_compute` only for this reason.
- Goose trap: mutually recursive functions all need `recursive fn`, including the entry of the cycle as seen from
  outside (parse_module_list, not only parse_module_elem).
- Goose trap: a `const u8[:][]` parameter can't take a literal list; declare it `const u8[:][:]`.
- `pad` is a keyword (also as a local name).
- TLI supports Linux and generic (no OS) triples; Darwin/Windows/BSD/GPU triples fail loudly in `tli_init`.
- computeKnownBits (knownbits.goose) is a full port for integers <= 64 bits; what remains fails loudly (see the
  file header). isImpliedCondition (implied.goose) is fully ported, including fcmps (fpclass.goose).
- ADCE perf trap: LLVM's `SetVector::remove` and the IDF priority queue were first ported as linear scans, which
  made ADCE quadratic on `scaling/switch`; membership is now the scratch set and the queue a heap. Integers > 64 bits fail loudly in KnownBits and DemandedBits.
- Not ported in ADCE/BDCE/DCE: debug-info salvaging, `--enable-knowledge-retention` (salvageKnowledge). ADCE
  applies its deleted edges to DT/PDT with an eager DomTreeUpdater and preserves both, as LLVM does.

## CFG analyses and loop canonicalization (domtree, dtu, loopinfo, cycleinfo, breakcrit, loopsimplify, lcssa)

- How to keep a cached tree up to date: change the CFG first, then `dt_apply_updates(fv, DT_DOM, ups)` (or through
  `dtu_begin/dtu_apply_updates/dtu_end`), and return the tree's bit in the preserved set. Pass a tree only if LLVM
  has it (`getCachedResult` = `dt_valid`; `getResult` = `dt_get` first). Recomputing instead gives a different
  child order and different DFS numbers / slow-query counts, which `print<domtree>` shows and passes that walk the
  tree see. Any pass that computes IDFs (mem2reg, ADCE) must call `dt_update_dfs_numbers` like
  `IDFCalculatorBase::calculate` does.
- `dt_dominates_block` mutates the tree (SlowQueries, DFS numbers after 33 slow queries), exactly like LLVM; don't
  call it where LLVM doesn't (use `dt_has_node`/levels for internal checks).
- `tools/fuzz_cfg.py [count] [seed]` compares random CFGs (branches, switches, unreachable regions, PHIs) against
  LLVM through the dominator/post-dominator/loop/cycle printers before and after break-crit-edges, adce and
  loop-simplify, and the `-S` output of loop-simplify, lcssa, break-crit-edges and adce. Run it after touching
  any of these files; 4000 programs ran clean when this was written.
- LoopSimplify/LCSSA fail loudly on: LoopInfo::erase, the exit-merging foldBranchToCommonDest (only when it would
  fold, or when the exiting block has bonus instructions), PreserveLCSSA paths, isGuaranteedNotToBePoison beyond
  constants (simplifyPHINode with undef inputs), setExplicitlyUnknownBranchWeightsIfProfiled.
  simplifyPHINode (ssaupdater.goose) and isSafeToSpeculativelyExecute (loopsimplify.goose) are local partial
  ports; switch to InstSimplify's / ValueTracking's when they land.
- SSAUpdater (ssaupdater.goose): one updater at a time (`ssa_init(ty, name)`, `ssa_add_available_value`,
  `ssa_get_value_in_middle_of_block`, `ssa_get_value_at_end_of_block`, `ssa_rewrite_use(use id)`,
  `ssa_rewrite_use_after_insertions`); inserted PHIs are in `ssa_inserted`. Uses are use ids, which change when a
  user's operand list grows (`grow_ops`): don't hold use ids across adding operands to their user.
- `inst_clone` (irutil.goose) is Instruction::clone: operands, flags, attributes, metadata; no name, no debug
  records, not inserted.
- Not ported: the loop pass manager (`loop(...)`, `loop-mssa(...)`), so loop passes and `print<loopnest>` fail as
  "not implemented yet".
- `print<demanded-bits>` prints in instruction order; LLVM's order is a DenseMap's, the test compares sorted lines.
- L1.dce can't be COMPLETE on its own: its exit selector includes tests whose pipelines need simplifycfg, sroa, gvn,
  licm, instcombine, debugify, redundant-dbg-inst-elim, and `--preserve-ll-uselistorder`, plus debug-info parsing.

## mem2reg / SROA (mem2reg.goose, sroa.goose)

- mem2reg ports `NewPhiNodes` (a `DenseMap<pair<unsigned,unsigned>, PHINode*>`) bit for bit (`m2r_pm_*`: LLVM 23's
  linear-probing, tombstone-free DenseMap with the splitmix `mix` hash and rehash after `remove_if`), because PHI
  simplification and the poison-filling loop walk it in bucket order. Keys use `BasicBlock::getNumber`, which is
  now tracked (`block_set_parent` / `block_number` in ir.goose: numbers are assigned from a per-function counter
  when a block's parent changes, exactly like `BasicBlock::setParent`). Any code that moves a block into a
  function must go through `block_set_parent`.
- Debug records know their instruction (`DbgRec.owner`, kept by `inst_add_dbg`/`dbg_records_to_next`), so
  `dbg_erase_record` is O(record list). mem2reg/SROA keep a per-run list of the function's records and the set of
  values they mention (VS_PASS1), which makes `ValueAsMetadata::handleRAUW`/`handleDeletion` (`m2r_dbg_rauw`,
  `m2r_erase`: RAUW follows into debug locations, erased values become poison) cost nothing for unmentioned
  values. `inst_erase_from_parent` still fails loudly when a record uses the erased value (it would need
  salvageDebugInfo); mem2reg/SROA use `m2r_erase` because LLVM does not salvage there.
- `m2r_insert_before_adopting` is `Instruction::insertBefore` without the head bit: the new instruction takes over
  the debug records attached to the position. IRBuilder insertions do this; `BB->begin()` insertions (PHIs) don't.
- SROA's IRBuilder (`irb_*`): insertion point, current debug location (set from the insertion instruction, as
  `SetInsertPoint(Instruction*)` does), name prefix (`IRBuilderPrefixedInserter`; a `StringRef` name that is empty
  still gets the prefix, a literal `""` does not: pass `named = false` for the latter), ConstantFolder semantics
  through constfold.goose. Different LLVM builders (rewriter, runOnAlloca's, presplit, `IRBuilder<>`) are the one
  global builder with the prefix reset at each switch; forgetting a reset shows up as `%a.sroa.3.4.` name prefixes.
- SROA scratch: its own 20-slot stamped sets/maps over value and use ids (`sr_*`, slots `S_*` listed in
  sroa.goose). It calls `promote_mem_to_reg`, which uses VM_PASS0/1, VS_PASS0/1, so SROA doesn't use those.
- Partitions are materialized up front (`compute_partitions`) with the partition_iterator's exact advance/end
  logic; the slices don't change while one partition walk runs.
- isSafeToLoadUnconditionally / isDereferenceableAndAlignedPointer are partial ports inside sroa.goose (allocas,
  arguments with dereferenceable, globals, GEP/bitcast/select/addrspacecast recursion, the block scan); calls,
  !dereferenceable loads, byval/sret arguments fail loudly.
- Not ported (fail loudly): assignment tracking (dbg_assign/DIAssignID) in both passes, migrating dbg_value records
  of split allocas, DIArgList locations in SROA debug migration, DW_OP_LLVM_extract_bits fragments.
- Goose trap: two files defining the same function name (`cint_sext`, `cint_is_zero`) is an "ambiguous call" error
  at every caller in *other* files. Prefix pass-private helpers (`sr_`, `m2r_`).
- Process trap: another agent's commit (77b3349) silently deleted sroa.goose and reverted several files while
  resolving a merge; check `git show --stat` of upstream commits that touch your files after a rebase.

## InstSimplify and the value-tracking analyses (L1.instsimplify)

- Files and entry points, all usable by later passes (instcombine, early-cse, gvn, sccp, simplifycfg):
  - `instsimplify.goose`: `simplify_instruction(iv)`, `simplify_inst_with_ops`, `simplify_binop`, `simplify_cmp`,
    `simplify_with_op_replaced`, `instsimplify_run`. Query = `SQ { cxt, undef }`; recursion operands live on the
    global `is_ops` stack (mark/resize), because Goose can't keep growable locals across recursive calls.
  - `pm.goose` (PatternMatch: `m_apint`, `m_not`, `m_minmax` → `mm_a/mm_b`, `m_logical` → `lg_a/lg_b`; copy the
    globals before recursing), `vt.goose` (isKnownNonZero, isKnownToBeAPowerOfTwo, isKnownNonEqual,
    ComputeNumSignBits, dominance helpers, getUnderlyingObject(s), stripAndAccumulateConstantOffsets → `vt_off`,
    matchSelectPattern, computeConstantRange), `poison.goose`, `knownbits.goose`, `fpclass.goose`
    (computeKnownFPClass: `known_fp_class(v, interested, fmf, depth)`, `known_fp_class_de`,
    `cannot_be_negative_zero`, `is_known_never_nan/_infinity/_inf_or_nan`, fcmpImpliesClass/fcmpToClassTest,
    ConstantFPRange subset `fpr_*`), `assume.goose` (AssumptionCache), `implied.goose`
    (`implied_condition`, `implied_condition_v`, `implied_by_dom_condition`), `crange.goose` (64-bit ConstantRange),
    `cfold.goose` (Analysis/ConstantFolding with a DataLayout), `fpu.goose` (exact IEEE arithmetic).
  - Context: analyses read the context instruction from the global `kb_cxt`; DT from `dt_get(fv, DT_DOM)`.
    `sq_no_dt` / `sq_no_ac` / `sq_no_tli` (vt.goose) model a SimplifyQuery without DT/AC/TLI (SCCP uses them).
  - Denormal modes come from `denormal_fpenv` (`fn_denormal_mode`); constant folding still fails loudly on it.
- Not ported (fail loudly): integers wider than 64 bits in PatternMatch/KnownBits/ConstantRange and wider than
  128 bits in constant folding (the biggest remaining category, ~20 tests: needs an arbitrary-width APInt through
  every analysis); FP libcalls and transcendental intrinsics (sin, sqrt, ldexp, pow, …: need exact host-libm
  equivalent results); scalable-vector call folding; non-integral address spaces; vscale_range; gc.relocate,
  load.relative, capture tracking; ConstantFPRange for x86_fp80/fp128/ppc_fp128.
- Goose traps met here: `self` is a keyword; a `fn` returning two values must `let a, b = f(); return a, b;`
  (not `{ f() }`); name clashes across modules (apfloat's FC_NAN vs FPClassTest → `FCL_*`).
- Perf: no `@opt -passes=instsimplify` perf benchmark exists. Timed by hand: straightline n4000/n16000/n64000 took
  0.026/0.037/0.062 s (LLVM 0.031/0.045/0.099 s), so it scales linearly.

## Memory analyses (aa, memoryssa)

- API and data layout: DESIGN.md §8.6. Call `aa_begin(fv)` before any AA query (it also sets `tli_cur_fn` and
  computes the DT). Every query takes an AAQueryInfo `q` (`aq_push`/`aq_pop`, stack order); use one `q` for what
  LLVM does with one BatchAAResults, a fresh one per query where LLVM uses `AAResults::alias(...)` directly
  (`aa_*_simple`). Results depend on this (assumption-based PHI caching).
- `get_underlying_object` must be called with 10 (MaxLookupSearchDepth); vt.goose/instsimplify still pass 6 in a
  few places (reported to the instsimplify owner).
- AA files keep private stamp sets (`aautil.goose` `SS_*`) so they never touch the pass scratch slots of
  irutil.goose; a pass may hold any VS_/VM_ slot across AA queries.
- MemorySSA: one instance (`mssa_fn`); `mssa_get(fv)` builds; invalidated by `invalidate_function` unless the
  pass preserves `A_MEMORYSSA`, `A_DOMTREE` and `A_AA`. A pass that keeps it must update it — there is no
  MemorySSAUpdater yet (needed by LICM, MemCpyOpt, DSE, loop-mssa): port it next to memoryssa.goose, using the
  use lists (`mssa_first_use`…) and the list helpers there. GVN needs MemoryDependenceAnalysis (not ported).
- Not ported (fail loudly or absent): separate_storage assumptions in BasicAA, APInt widths over 64 bits,
  `!callback` metadata in the CallGraph, MemorySSA's loop constructor and verifier, the
  `scev-aa`, `objc-arc-aa`. EarliestEscapeAnalysis and the CFG reachability with LoopInfo/CycleInfo are ported
  but no printer exercises them (first checked by DSE/MemCpyOpt).
- Printer issues seen in the sweeps (not AA bugs): `errs_inst` numbers metadata like a function-local SlotTracker;
  LLVM uses a module-wide one (`ShouldInitializeAllMetadata`) when the instruction has an MDNode operand
  (`llvm.read_register(metadata !1)` prints `!1` in LLVM, `!0` here); the parser doesn't print LLVM's "warning:
  ignoring debug info with an invalid version" / "inlinable function call ... must have a !dbg location".
- Goose: `block` is a keyword (MemoryAccess's field is `bb`); helper names collide across modules, so every AA
  helper has a prefix (`aa_ bas_ ml_ ct_ cfr_ ss_ tb_ sna_ gm_ cg_ mssa_ ma_ mphi_ cw_ mo_ pta_`).
- DataLayout now caches StructLayout per type (dl_struct_layout; cleared by dl_reset/dl_set_spec), and attribute
  sets carry a bitmap of their enum kinds (aset_find of an absent kind is O(1)); both were the top of the aa-eval
  profile.
