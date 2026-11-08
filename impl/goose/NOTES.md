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

- L1.simplifycfg 563/578 (all 289 roundtrip, 274/289 opt). Left, other passes/flags: debugify ×3,
  `-strip-debug`, `-O1`, instcombine visitors/LibCallSimplifier ×4 (`duplicate-phis`, `merge-cond-stores`,
  `unreachable_assume`, ...); SimplifyCFG pieces still failing loudly: cloning debug records (bonus instructions,
  threading), salvageDebugInfo on erase (`speculate-dbgvalue`), mergeDIAssignID, conditional-faulting
  load/store hoisting (`+cf`), isSafeToSpeculateStore from a preceding load (isWritableObject), X86
  getShuffleCost. Speed (`perf`): diamonds k 1.01 (LLVM 1.19); switch k 1.57 vs LLVM 1.15: n32000 is 1.8x
  LLVM's time, something per-case is linear in the case count (debt, not yet looked at).
- L1.instcombine.arith 126/230 (all 115 roundtrip, 11/115 opt); 120 of the 1635 InstCombine `::opt` tests
  pass. The framework is complete (DESIGN.md §12); ported visitors: add, sub, mul, udiv/sdiv/urem/srem, shl/lshr/ashr,
  trunc/zext/sext, ret, br, unreachable, calls to ordinary functions, llvm.assume (no bundles). Every other
  visitor fails loudly ("the InstCombine visitor for 'icmp' is not ported yet"), and so do unported sub-folds of
  the ported visitors. What blocks the remaining arith tests (first blocker per test, `tools/ic_failures.py
  'add*' 'sub*' 'mul*' '*div*' '*rem*'`): icmp 34, and 16, select 12, or 8, xor 6, then insertelement, libcalls,
  min/max intrinsics, GEP, load, fdiv, other passes (cgscc/inline, debugify). With `-goose-ic-lenient` (unported
  visitors do nothing) 25 arith tests already match, so most remaining work is the other visitors, not arith.
- L1.early-cse 93/96 (all 48 roundtrip, 45/48 opt). Left: `math-2.ll` (ConstantFolding of `remainder`),
  `masked-intrinsics.ll` (ValueTracking demanded elements of a `<128 x i8>`), `reuse-preserved-memoryssa.ll`
  (runs `gvn`). early-cse, early-cse<memssa> (both also with `--enable-knowledge-retention`), instsimplify and dce
  give output identical to LLVM's on all 5007 `tests/imported/llvm/Transforms/*/*.ll` files that don't stop
  loudly (~75 do), on every tests/e2e and tests/function O0/pipeline input after sroa, and on the four
  tests/perf/compile programs. Speed (`perf`, scaling/straightline is the only `@perf` line): 0.5-0.65x LLVM's
  time, k 1.04 (LLVM 1.15); by hand `sroa,early-cse<memssa>` on sqlite3/SPASS is 0.30/0.29 s vs LLVM's
  0.38/0.49 s, and every tests/perf/scaling shape is 1-4.5x faster than LLVM. Found by the sweeps and fixed on
  the way: InstSimplify silently differed (isEliminableCastPair needs the DataLayout; BinaryOp_match matches no
  ConstantExprs; findScalarElement; m_FPOne; isAssumeWithEmptyBundle; InstSimplifyPass checks deadness without
  TLI; the dereferenceable-argument case of isKnownNonNullFromDominatingCondition), and x86 cvt folding.
- L1.sccp 331/340 (all 170 roundtrip, 161/170 opt). Left: 7 tests run other passes (simplifycfg ×2,
  loop-deletion, internalize, deadargelim, instcombine, debugify); `overdefined-ext.ll` passes its
  `-use-constant-int-for-fixed-length-splat=false` line but not the `=true` line (vector-typed ConstantInt
  splats are not supported: fails loudly); `2007-05-16-InvokeCrash.ll` needs libm folding of `sin`
  (ConstantFolding uses the host's libm; Goose's std has no libm). sccp and ipsccp also agree with LLVM
  on 6711 of the other imported test files (the rest stop loudly, mostly in ConstantFolding; one silent
  difference: InstSimplify/ConstProp/avx512.ll, x86 avx512 cvt intrinsics not folded) and on all tests/e2e O0
  inputs after sroa. Speed (by hand, no `@perf` line times them): `sroa,sccp` on sqlite3 is 0.29 s vs LLVM's
  0.38 s (sccp itself +0.06 s vs +0.04 s); same picture on SPASS and lua. ipsccp on those programs stops at
  the function-specialization check (below). Linear on every tests/perf/scaling shape and faster than LLVM on
  all but loops-many (n8000: 74 ms vs 63 ms). Perf trap fixed on the way: `Instruction::comesBefore` by
  walking the list made the worklist push quadratic on one big block (scaling/straightline n64000 took 2 s);
  the solver now numbers each block's instructions once (the IR doesn't change while it runs).
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
- L1.analysis.scev 501/505 (all 266 roundtrip; 243/247 `print<scalar-evolution>` lines of the corpus): the 4 left
  run `print<iv-users>` (2), `indvars` and `-aa-pipeline=scev-aa`. `print<scalar-evolution>` also matches LLVM on
  all 723 tests/e2e and tests/function inputs, the four tests/perf/compile programs and 6913 of the 6989 imported
  test files (the rest stop loudly, mostly in computeKnownBits gaps, or differ only in LLVM's debug-info and
  `-mattr` warnings on stderr). Speed: like LLVM's or faster on tests/perf/scaling (both are superlinear on
  `loops-many`: n500 0.16 s / 0.11 s, n2000 5.1 s / 5.0 s, LLVM vs Goose); no `@perf` line times it.
- L1.analysis.loops complete (print<loopnest> through the loop pass manager).
- L1.analysis.domtree and L1.analysis.demanded-bits complete. L1.loop-canonical: loop-simplify and
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
| `src/constfold.goose` | ConstantFold.cpp + `ConstantExpr::get*` (`ce_*` create-or-fold, `cf_*` fold-or-`-1`), any width via apint.goose |
| `src/apint.goose` | APInt of any width (DESIGN.md §10); `tools/aptest.py` tests it against Python |
| `src/hostmath.goose`, `src/hostmath.c`, `src/opt.build` | host libm for FP constant folding (DESIGN.md §11) |
| `src/gen_dwarf.goose`, `src/gen_cc.goose` | generated by `tools/gen_dwarf.py` / `tools/gen_cc.py` from Dwarf.def, DebugInfoFlags.def, CallingConv.h and AsmWriter |
| `src/apint.goose`, `src/constrange.goose` | APInt (any width), ConstantRange.cpp (`rg_*`, `CRange`) |
| `src/valuelattice.goose`, `src/predinfo.goose`, `src/sccp.goose` | ValueLatticeElement, PredicateInfo, SCCP solver + sccp/ipsccp |
| `src/domtree.goose`, `src/dtu.goose` | Dominator trees with incremental updates; DomTreeUpdater |
| `src/loopinfo.goose`, `src/cycleinfo.goose` | LoopInfo (+ update API, loop metadata), CycleInfo |
| `src/breakcrit.goose`, `src/loopsimplify.goose`, `src/lcssa.goose` | SplitCriticalEdge/break-crit-edges, SplitBlockPredecessors + LoopSimplify, LCSSA |
| `src/lpm.goose` | Loop pass manager worklist (SmallPriorityWorklist) and LPMUpdater; the adaptor runs in passmgr.goose |
| `src/scev.goose` | ScalarEvolution nodes, uniquing, folding constructors (add/mul/udiv/addrec/min/max/casts), complexity order, printing |
| `src/scev_create.goose` | getSCEV/createSCEV, AddRecs from PHIs, selects, GEPs, value maps, forgetMemoizedResults, rewriters |
| `src/scev_range.goose` | Constant multiples, ranges, isKnown* sign queries |
| `src/scev_btc.goose`, `src/scev_lt.goose` | Backedge-taken counts and exit limits; howManyLessThans/GreaterThans, SCEV predicates |
| `src/scev_eval.goose` | evaluateAtIteration, constant evolution, getSCEVAtScope, howFarToZero, quadratic solvers, dispositions |
| `src/scev_pred.goose`, `src/scev_guards.goose` | isKnownPredicate / isImpliedCond families; LoopGuards |
| `src/scev_print.goose`, `src/loopnest.goose` | print<scalar-evolution>; print<loopnest> (LoopNest, Loop::getBounds, isInductionPHI) |
| `src/analyses.goose` | Analysis ids, preserved sets |
| `src/memloc.goose` | MemoryLocation/LocationSize, ModRef, MemoryEffects, CaptureInfo, CallBase operand attribute queries, identified objects, stripPointerCastsForAliasAnalysis |
| `src/aa.goose` | AAResults aggregation, AAQueryInfo (cache, assumptions, capture analyses), BasicAA, getBaseObjectSize |
| `src/tbaa.goose`, `src/globalsaa.goose` | TypeBasedAA + ScopedNoAliasAA; GlobalsAA with CallGraph and Tarjan SCCs |
| `src/capture.goose`, `src/aautil.goose` | CaptureTracking (3 trackers); private stamp sets (`ss_*`) and CFG reachability (`cfr_*`) |
| `src/memoryssa.goose`, `src/phitrans.goose` | MemorySSA (build, walker, OptimizeUses, printers); PHITransAddr |
| `src/aaeval.goose` | the aa-eval pass |
| `src/mssaupdater.goose` | MemorySSAUpdater (removal: removeMemoryAccess, tryRemoveTrivialPhi) |
| `src/earlycse.goose` | EarlyCSE (early-cse, early-cse<memssa>): scoped hash tables, combineMetadataForCSE, replaceDominatedUsesWith |
| `src/instident.goose` | isIdenticalToWhenDefined, hasSameSpecialState, attribute intersection, andIRFlags |
| `src/salvage.goose` | salvageDebugInfo and the DIExpression helpers it needs (foldConstantMath, appendOpsToArg, ...) |
| `src/knowledge.goose` | salvageKnowledge (`--enable-knowledge-retention`, AssumeBundleBuilder) |
| `src/simplifycfg.goose` | SimplifyCFG.cpp + SimplifyCFGPass.cpp: `simplifycfg_run(fv, SCOpts)`, every `simplifycfg<...>` option (`scf_` prefix) |
| `src/cfgutil.goose` | Local.cpp/BasicBlockUtils.cpp CFG helpers (`cu_*`): ConstantFoldTerminator, MergeBlockIntoPredecessor, removeUnreachableBlocks, DeleteDeadBlocks, changeToUnreachable, combineMetadata, SplitBlockPredecessors, block RAUW incl. BlockAddress, debug-record splice/drop |
| `src/speculate.goose` | isSafeToSpeculativelyExecute (`spec_safe`), isDereferenceableAndAlignedPointer incl. assume bundles, canBeFreed, willNotFreeBetween |
| `src/profdata.goose` | branch weights (`pd_*`), SwitchInstProfUpdateWrapper (`swp_*`), switch accessors (`sw_*`) |
| `src/tti.goose` | TargetTransformInfo front end: NoTTIImpl costs, getInstructionCost dispatch, getOperandInfo, BranchProbability |
| `src/tti_x86.goose`, `src/gen_x86costs.goose` | X86TTIImpl/BasicTTIImplBase: subtarget features (`x86_has`), type legalization (`x86_legalize`), cost tables generated by `tools/gen_x86costs.py` |
| `src/subtarget.goose`, `src/gen_x86st.goose` | x86 subtarget creation diagnostics ("'+mpx' is not a recognized feature"); CPU/feature names generated by `tools/gen_x86st.py` from `llc -mattr=help` |
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
- C interop: `extern fn name(x: u64, ok: i32&) -> u64;` binds a C function; the C file is listed in the root's
  sidecar (`src/opt.build`: `c_sources = [...]`). Only the root file's sidecar counts, so every root that
  (transitively) imports a module with `extern fn`s needs one. Pass doubles as u64 bit patterns to keep the
  conversion out of Goose.

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
- computeKnownBits (knownbits.goose) is a full port for integers of any width; what remains fails loudly (see the
  file header). isImpliedCondition (implied.goose) is fully ported, including fcmps (fpclass.goose).
- ADCE perf trap: LLVM's `SetVector::remove` and the IDF priority queue were first ported as linear scans, which
  made ADCE quadratic on `scaling/switch`; membership is now the scratch set and the queue a heap. Integers > 64 bits fail loudly in DemandedBits (KnownBits is any width).
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
- The loop pass manager is in passmgr.goose/lpm.goose (DESIGN.md §9); `loop-mssa` fails loudly until MemorySSA
  is wired into it, loop-nest passes are not ported.
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

## SCCP / IPSCCP (sccp.goose, predinfo.goose, valuelattice.goose, constrange.goose)

- Files: `constrange.goose` (ConstantRange.cpp, whole, on apint.goose's AP: `rg_*`, type `CRange`),
  `valuelattice.goose` (ValueLatticeElement: `vl_*`, type `VL`; merges take `VL&` and return "changed"),
  `predinfo.goose` (PredicateInfo: `pi_reset`, `pi_build(fv)`, `pi_info_for(v)`, `pi_constraint(info)`),
  `sccp.goose` (solver `sc_*`, `sccp_run(fv)`, `ipsccp_run(m, func_spec)`). Facts: knowledge/llvm/sccp.md.
- One solver at a time: `sc_init()` bumps the epoch of the per-value `ScRec` table. Lattice elements live in
  `sc_vls` and are addressed by index; the Goose trap "`a[f()]` where f grows a" bites here, so read them via
  `sc_gv(v)` / `sc_vsv(v)` / `sc_gsv(v, i)` (index computed first), never `sc_vls[sc_gvs(v)]`.
- Debug records: the transform phase RAUWs with `sc_rauw` (rauw + `m2r_dbg_rauw`) and erases with
  `m2r_erase`; call `m2r_collect_records(fv)` before transforming a function.
- Function specialization (FunctionSpecialization.cpp, with CodeMetrics and the TTI code-size model) is not
  ported. `ipsccp` enables it by default; we fail loudly only when a function passes `isCandidateFunction`,
  has an executable direct call site that passes a candidate constant to an interesting argument (or is
  recursive with pointer arguments), and an over-estimate of its code size reaches 500. That still trips on
  real programs (sqlite3's vxprintf, lua's lua_replace, SPASS), although LLVM's output there equals the
  no-specialization output: porting the specializer's cost model is the next step for `-O2`.
- `ipsccp<func-spec|no-func-spec>` is parsed; `no-func-spec` skips the check.
- Changes in shared files: cfold.goose (FlushFPConstant/denormal modes from `denormal_fpenv` for FP binops
  and fcmp, Dynamic without a context instruction; constrained fcmp/fcmps folding; FoldBitCast for
  vector->scalar and element-count-changing vector bitcasts; scalable GEP source types are not folded;
  uniform loads need size == store size), datalayout.goose `dl_gep_stride` (vector elements use the store size;
  used by cfold and vt), flags.goose (`-use-constant-*-splat=false` accepted, `=true` fails loudly).

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
    (`implied_condition`, `implied_condition_v`, `implied_by_dom_condition`), `constrange.goose` (ConstantRange, any width; crange.goose's 64-bit CR is BasicAA's only),
    `cfold.goose` (Analysis/ConstantFolding with a DataLayout), `fpu.goose` (exact IEEE arithmetic).
  - Context: analyses read the context instruction from the global `kb_cxt`; DT from `dt_get(fv, DT_DOM)`.
    `sq_no_dt` / `sq_no_ac` / `sq_no_tli` (vt.goose) model a SimplifyQuery without DT/AC/TLI (SCCP uses them).
  - Denormal modes come from `denormal_fpenv` (`fn_denormal_mode`); constant folding still fails loudly on it.
- Integers are arbitrary-width everywhere in InstSimplify/ValueTracking/KnownBits/ConstantRange/constant folding
  (apint.goose, DESIGN.md §10). In new code use `ci_ap(c)` (AP of a ConstantInt of any width), `c_int_ap(ty, AP)`,
  `m_specific_int_apv`; `ci_val` still fails loudly above 64 bits and is only right where LLVM takes
  `getZExtValue()`. `m_specific_int(v, u64)` has LLVM's `uint64_t` semantics (no truncation of the constant).
  Still 64-bit (fail loudly): DemandedBits, GEP offset accumulation (index widths > 64), crange.goose's `CR`
  (BasicAA only), demanded-element masks (vectors of more than 64 elements).
- FP call folding (cfold.goose, DESIGN.md §11): math intrinsics and libcalls through the host libm, exact
  rounding/fma/scalbn/fptoi.sat/frexp. Not ported (fail loudly): canonicalize, constrained-FP rounding and
  arithmetic, fp128 `log`/`logl` (logf128), remainder, nextafter/nexttoward, nvvm/amdgcn/wasm intrinsics,
  scalable-vector calls, byte-typed vector bitcasts.
- Not ported (fail loudly): scalable-vector call folding; non-integral address spaces; vscale_range;
  gc.relocate, load.relative, capture tracking; ConstantFPRange for x86_fp80/fp128/ppc_fp128.
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
  pass preserves `A_MEMORYSSA`, `A_DOMTREE` and `A_AA`. A pass that keeps it must update it through
  mssaupdater.goose (DESIGN.md §8.6): only removal is ported (EarlyCSE); LICM, MemCpyOpt, DSE and loop-mssa need
  the insertion/move parts, to be added there using the use lists (`mssa_first_use`…) and `msu_use_set`. GVN needs MemoryDependenceAnalysis (not ported).
- Not ported (fail loudly or absent): separate_storage assumptions in BasicAA, APInt widths over 64 bits,
  `!callback` metadata in the CallGraph, MemorySSA's loop constructor and verifier, the
  `scev-aa`, `objc-arc-aa`. EarliestEscapeAnalysis and the CFG reachability with LoopInfo/CycleInfo are ported
  but no printer exercises them (first checked by DSE/MemCpyOpt).
- Printer issues seen in the sweeps (not AA bugs): `errs_inst` numbers metadata like a function-local SlotTracker;
  LLVM uses a module-wide one (`ShouldInitializeAllMetadata`) when the instruction has an MDNode operand
  (`llvm.read_register(metadata !1)` prints `!1` in LLVM, `!0` here). The parser now prints LLVM's debug-info
  warnings (see Sweeps).
- Goose: `block` is a keyword (MemoryAccess's field is `bb`); helper names collide across modules, so every AA
  helper has a prefix (`aa_ bas_ ml_ ct_ cfr_ ss_ tb_ sna_ gm_ cg_ mssa_ ma_ mphi_ cw_ mo_ pta_`).
- DataLayout now caches StructLayout per type (dl_struct_layout; cleared by dl_reset/dl_set_spec), and attribute
  sets carry a bitmap of their enum kinds (aset_find of an absent kind is O(1)); both were the top of the aa-eval
  profile.

## ScalarEvolution (scev.goose, scev_create, scev_range, scev_btc, scev_pred, scev_eval, scev_lt, scev_guards, scev_print)

- Layout and conventions: DESIGN.md §8.7. Every function in these files is `recursive fn` (one cycle, like LLVM's).
  A function with a growable local can't be in the cycle: use the mark-based scratch stacks.
- Goose trap: `ss[b] = f(...)` where `f` may shrink `ss` is rejected; bind the call result first.
- Goose trap: `var x = -1;` is an i64; SCEV ids are i32 (`var x: i32 = -1;`).
- Order traps found by the port (all verified against opt): `AddRec->getNoWrapFlags(ComputeFlags(...))` evaluates
  ComputeFlags first (it adds flags to the AddRec through its range computation); loop guards erase an entry
  before re-rewriting it; nested sequential-min/max deduplicators have their own SeenOps; computeKnownBits without
  a context uses the instruction itself (`safeCxtI`); getConstantMultiple allows ephemeral assumptions.
- Fails loudly: createAddRecFromPHIWithCasts (casted-PHI predicated rewrites), sizeof of aggregates with scalable
  vectors, scalable allocas; ValueTracking gaps it relies on (vectors > 64 lanes, pext/pdep, ...).
- Not ported: SCEVExpander, PredicatedScalarEvolution, `verify<scalar-evolution>` (accepted, prints nothing:
  LLVM only prints on a mismatch), IVUsers, SCEVAA, getLoopInvariantPredicate & co (transform helpers).
- The function names use the prefix `sc_`, which SCCP also uses for a few helpers (`sc_alist_set`, ...): check for
  a clash before adding one.
- `tools`: /tmp scripts were used to sweep `print<scalar-evolution>` over the corpus in parallel (compare stdout+
  stderr with LLVM's for every file); worth turning into a harness command.

## InstCombine (ic*.goose)

- Layout, conventions and how to add a fold: DESIGN.md §12. Everything is in `namespace ic;` because common
  helper names (`has_nsw`, `opcode_name`, `minmax_pred`) collide with global functions of other files.
- Development tools: `tools/ic_failures.py [globs]` summarizes the first error of each failing InstCombine test
  from `.harness-out` (run a `check` first); `opt -goose-ic-lenient` makes unported visitors no-ops (never use
  it for real output: it can be wrong) to find tests that only need already-ported folds.
- The DomConditionCache (domcond.goose) hooks into knownbits/vt/fpclass behind `dc_active`; other passes
  never set it. Keep `kb_cxt` set right before each ValueTracking call: InstSimplify and other helpers overwrite it.
- Names: set them on unattached instructions freely (stored, registered at insertion by `ic_register_name`);
  never pass a `val_name(...)` slice to `set_name` directly when the target may grow the string pool (copy it).
- Fixed in shared code on the way: TLI size_t is now the DataLayout index size of AS 0 (`tli_sizet_bits`,
  was a constant 64); `ac_register_assumption` / `ac_update_affected` (assume.goose) for assumes created or
  changed by a pass.
- Not ported / known gaps (fail loudly): SimplifyDemandedVectorElts, SimplifyDemandedFPClass, foldVectorBinop
  with shuffle/intrinsic operands, OptimizePointerDifference, LibCallSimplifier, alloc-site handling, salvaging
  debug info (erasing an instruction used by a debug record), dropDroppableUses when sinking, AliasScopeTracker,
  LowerDbgDeclare, the !annotation copy, branch-weight updates, foldBinopWithRecurrence, symmetric PHI pairs.
- Perf: not measurable yet (`tests/perf/scaling/straightline/*` has an `@perf: opt -passes=instcombine` line,
  but it stops at the unported `xor` visitor). Known linear scans to revisit when it matters: removing an
  entry from the deferred worklist, DeadEdges, DomConditionCache dedupe per value, the cast TypeEvaluationHelper
  visited map, the Negator cache (all small in practice).

## EarlyCSE (earlycse.goose, mssaupdater.goose, instident.goose, salvage.goose, knowledge.goose)

- Design: DESIGN.md §13. Facts: knowledge/llvm/early-cse.md.
- `-earlycse-debug-hash` is accepted and ignored: it only changes hashing under `#ifndef NDEBUG`, and the LLVM we
  compare with is a release build. The tests that pass it check release behaviour.
- `simplify_instruction` is called on every instruction (EarlyCSE does, InstSimplifyPass only on used ones), so
  InstSimplify must not choke on stores, branches or void calls.
- The sweep that found every silent mismatch here: run LLVM's and our opt with one pipeline on every
  `tests/imported/llvm/Transforms/*/*.ll`, canonicalize both with llvm-as|llvm-dis, compare (16 parallel jobs,
  ~20 s). `./harness/run sweep` now does this; run it after touching instsimplify, cfold or vt.
- Not ported (fail loudly): combineMetadataForCSE for `!fpmath`/`!captures` that differ, DIAssignID, `!mmra`,
  `!memprof`, `!callsite`, `!prof`, `!callee_type`; GEP offsets with index widths over 64 bits; dbg_assign address
  salvaging. TTI.getTgtMemIntrinsic is false (x86 and the default target have no target memory intrinsics).
- Trap: `msu_remove_memory_access` is recursive (through tryRemoveTrivialPhi), so its PhisToCheck set lives on the
  global `msu_check` stack with a mark, not in a local growable array.

## SimplifyCFG and the TTI (simplifycfg, cfgutil, speculate, profdata, tti, tti_x86)

- Reusable entry points: `cu_*` in cfgutil.goose (set `cu_dtu` + `dtu_begin` when a DomTreeUpdater is wanted;
  `cu_dead_ba` holds destroyed BlockAddresses), `spec_safe(i, cxt, use_ac)`, `pd_*`/`swp_*`, and the TTI:
  call `tti_init_function(fv, module)` at the start of a pass, then `tti_instruction_cost(i, kind)`,
  `tti_arith_cost`, `tti_cast_cost_i`, `tti_cmpsel_cost_i`, `tti_memory_op_cost_i`, `tti_intrinsic_cost(_args)`,
  `tti_is_type_legal`, `tti_branch_mispredict_penalty`, ... (all dispatch on `tti_kind`).
- X86 TTI: the subtarget is built per function like X86TargetMachine::getSubtargetImpl (target-cpu/-features/
  tune-cpu/prefer-vector-width/min-legal-vector-width/use-soft-float attributes, else -mcpu/-mattr; CPU
  "generic" + tune "i586" by default; the triple adds `+64bit-mode,...,+sse2`). Only the CPUs generic, i586,
  x86-64, x86-64-v2/v3/v4 are known (others fail loudly); add more in `CPUS` in tools/gen_x86costs.py. Unknown
  feature names fail loudly here, while subtarget.goose (another agent's) prints LLVM's warning: the two feature
  parsers should be merged. Type legalization ports computeRegisterProperties' per-MVT actions and
  getTypeConversion for EVTs. The ported cost paths are the SizeAndLatency/CodeSize ones (what SimplifyCFG asks);
  RecipThroughput fallbacks into BasicTTIImplBase that need the SelectionDAG operation-action tables
  (isOperationLegalOrPromote, ...) fail loudly (`x86_np`), as do getShuffleCost and the generic BasicTTI
  getIntrinsicInstrCost.
- opt applies -mcpu/-mattr to every function as "target-cpu"/"target-features" attributes (opt.goose
  `set_function_attributes`, codegen::setFunctionAttributes) — this shows up in the printed IR.
- Debug records: Goose attaches records to the instruction after them, like LLVM's DbgMarker, but
  `inst_insert_before` does not adopt the records at the insertion point the way Instruction::insertBefore does
  without the head bit. SimplifyCFG compensates locally (`scf_adopt_records` in sb_insert and the hoisting
  moves, `cu_splice_before_dbg`, `cu_prepend_records` in MergeBlockIntoPredecessor). A pass that inserts before
  an instruction carrying records must decide which LLVM iterator (head bit or not) it is porting.
- simplifycfg collects the debug records at pass start (`m2r_collect_records`, slot VS_PASS1) so `scf_rauw` and
  `scf_erase` keep records up to date (ValueAsMetadata RAUW / deletion -> poison). cfgutil's own RAUWs don't;
  they fail loudly at the erase instead.

## Sweeps (`./harness/run sweep`, 2026-11-08: every round-tripping corpus file, ~7750)

Silent mismatches (`differs` + `bad-ir`) per pipeline, before and after the sweep-fix round; `failed` (loud) are
not counted. Rerun after touching a shared file (ValueTracking, constant folding, printers, the parser).

| Pipeline | before | after |
| --- | --- | --- |
| `instsimplify` | 2 (21 earlier the same day) | 0 |
| `print<scalar-evolution>` --analysis | 4 | 0 |
| `print<demanded-bits>` --unordered | 154 | 0 |
| `aa-eval` (basic-aa / default / tbaa,scoped-noalias-aa,basic-aa, `-print-all-alias-modref-info`) | 4 | 0 |
| `print<memoryssa>`, `print<memoryssa-walker>`, `print<loopnest>` | 4 each | 0 |
| `print<domtree>`, `print<postdomtree>`, `print<loops>`, `print<cycles>` | 3 each | 0 |
| `sccp`, `ipsccp`, `ipsccp<no-func-spec>` | 4 each | 0 |
| `bdce` | 1 | 0 |
| `dce`, `adce`, `mem2reg`, `sroa`, `sroa<modify-cfg>`, `break-crit-edges`, `loop-simplify`, `lcssa`, `sroa,sccp`, `mem2reg,instsimplify`, `bdce,adce,dce`, `loop-simplify,lcssa,print<scalar-evolution>` | 0 | 0 |

What they were:
- stderr diagnostics (every analysis printer): the parser's debug-info warnings were missing or short
  (`ignoring debug info with an invalid version (0) in <file>`, the Verifier's `inlinable function call ... must
  have a !dbg location` + instruction, `ignoring invalid debug info in <file>`); x86 subtarget warnings for
  unknown `target-features` (subtarget.goose: printed when a pass first asks for TTI/AssumptionCache, see
  knowledge/llvm/tools-and-flags.md). Unknown `target-cpu`/`tune-cpu`/`-mcpu` names fail loudly. Printing the
  Verifier's instruction numbers the module's metadata, so it must reset all slots afterwards
  (`slots_reset_all`), or the stripped debug metadata keeps its numbers in the final printout.
- DemandedBits: its DeadUses lived in scratch slot VS_ANA1, which ValueTracking (poison.goose, getUnderlyingObjects)
  also uses during the known-bits queries: uses came out dead (0x0). Now private stamped arrays. Non-integer
  operands print the DataLayout size (pointers are 32 bits under `p:32`).
- SCCP erased folded math libcalls (`log(1.0)`): its wouldInstructionBeTriviallyDead has no TLI, so
  `local_have_tli` must be off too, not only `sq_no_tli`.
- InstSimplify: `"align"(ptr, A, Off)` assume bundles imply non-null (assumeBundleImpliesNonNull); x86 SSE cvt
  intrinsics don't fold a vector-typed ConstantFP (`zeroinitializer`, FP splats). The FP-vector null from
  `c_null`/`c_splat` (LLVM's getNullValue/getSplat: a ConstantFP) is now a VK_AGGZERO with `flags = 1`, distinct
  from the ConstantAggregateZero that `c_aggregate` makes of all-zero elements (`c_is_vector_cfp`).
- bdce (freeze-signedness-missed.ll) was the same DeadUses clobbering.
- After rebasing onto salvageDebugInfo (salvage.goose), `instsimplify` showed 1 new `differs`: zext salvaging
  wrote `DW_ATE_unsigned_char` (8) for `DW_ATE_unsigned` (7). Fixed.
