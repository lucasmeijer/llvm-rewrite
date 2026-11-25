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

- **One binary, three names.** `build.sh` compiles `src/opt.jai` once and copies it to `bin/llc` and
  `bin/llvm-link`; `main` (opt.jai) picks the tool from the base name of argv[0]. (Until 2026-11 three programs were
  compiled, in parallel; three optimized compiles at once got OOM-killed.)
- Both modes go through the metaprogram `build.jai` (`jai build.jai - <x64|optimized> <src> <exe> <outdir>`), which
  puts `impl/jai/modules` first in the import path: its `Default_Allocator` (glibc malloc, no trimming) replaces
  Jai's stripped rpmalloc, which decommitted every empty span (madvise) and re-faulted it on the next allocation
  (~1M page faults, 3 s of system time on -O2 SPASS.ll). See "Performance" for what that exposed.
- **`JAI_BUILD=x64`** (default, what `check` builds): the x64 backend, the command line's defaults (bounds checks,
  stack traces), ~3-5 s. Its binaries are 5-8x slower than the optimized build.
- **`JAI_BUILD=optimized`** (`impl/jai/perf.env` sets it for `harness/run perf`): LLVM backend, **OPTIMIZED** (O2),
  no stack traces, **no bounds checks**, no debug info (binary 12 MB instead of 54; callgrind still shows function
  names, without file names). ~3.5 min, peak ~3.7 GB. VERY_OPTIMIZED (what this used to be, = the command line's `-o`)
  executes ~3.5% fewer instructions but its compile peaks at ~12.7 GB (it idles at 3.6 GB and spikes to 12 GB several
  times in LLVM's O3 pipeline); on the shared machine it was OOM-killed more often than not (cgroup `oom_kill`
  counter), so 2026-11 switched to OPTIMIZED. `build.sh` still retries a compile killed with exit 137 (OOM killer, or
  another agent's pkill) up to 3 times. Splitting into LLVM modules (`enable_split_modules`) builds 5x faster but the
  binary is 2.4x slower (no cross-module inlining), and stack traces cost another 2x, so neither is used. The full
  ratchet passes with the optimized binary too (`check --no-build` after a `JAI_BUILD=optimized` build), but keep
  `check` on x64: bounds checks turn silent memory bugs into loud failures.
- Both are cached in `bin/.cache/<mode>-<hash of build.sh, build.jai, modules/, src/, compiler version>/` (4 newest
  per mode); `bin/.stamp` names the installed one. Switching modes (perf, then check) is a copy. The optimized build
  compiles a snapshot of `src/` so edits during the compile can't end up under the wrong hash.
- Decision (2026-11): keep x64 for `check` and time the optimized build in `perf`.
- Profiling: `-time-passes` (time_passes.jai: CPU seconds per pass name, nested passes excluded, analyses charged to
  the pass that asked, plus the peak scratch memory of one run) gives the per-pass split to compare with LLVM's
  `opt -time-passes`; then `valgrind --tool=callgrind` (perf(1) has no hardware counters in this VM) on the optimized
  build, `--toggle-collect='<pass entry>*'` for one pass (e.g. `slp_run_impl*`, `instcombine_run*`), `--tree=caller`
  for call counts per caller. `MALLOC_PERTURB_=165 ./harness/run check --impl jai` (glibc fills freed memory) finds
  stale-pointer bugs (see "Performance").

## Layout of the code

- `src/opt.jai` `#load`s the shared core: `ir.jai` (tables, use lists, RAUW, interning), `apfloat.jai` (bignum,
  APFloat decimal printing/parsing, IEEE arithmetic/compare/conversions), `apint.jai`, `datalayout.jai`,
  `lexer.jai`, `parser.jai`, `printer.jai`, `intrinsics.jai` (intrinsic IDs, signature matching, mangling,
  declarations), `autoupgrade.jai` (AutoUpgrade.cpp + a small constant-folding IRBuilder), `constfold.jai`
  (ConstantFold.cpp), `debuginfo.jai` (DI* nodes, debug records, StripDebugInfo). opt.jai's `main` also runs
  `llc_main` / `llvm_link_main` when the binary is called as llc / llvm-link.
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
  x86 (`autoupgrade_x86.jai`): shouldUpgradeX86Intrinsic, upgradeX86IntrinsicFunction (old-signature
  declarations: rdtscp, ptest, 8-bit immediates, masked fp compares, vpdp*, bf16, xop) with their NewFn call
  rewrites, and all of upgradeX86IntrinsicCall with its helpers, in LLVM's if/else order. Checked: every
  llvm/test/CodeGen/X86/*-upgrade.ll (41 files) prints identically with `opt -S`. The intrinsics the upgrades create
  need entries in gen_intrinsics.jai: tests/roundtrip/intrinsics/x86-upgrade-targets.ll declares the ones no other
  test declares (an upgrade that creates another unknown one fails loudly with the generator hint). C++ argument
  evaluation order (e.g. `CreateAnd(CreateBitCast(a), CreateBitCast(b))`) turned out left to right in the oracle
  binary (avx512dqvl-intrinsics-upgrade.ll mask.and.ps etc. match); the port creates instructions in that order. Other targets' intrinsics are unknown names.
- Debug info: every specialized node kind of LLParser (debuginfo.jai `DI_Kind`, incl. DIEnumerator, DIGenericSubrange,
  DIModule, DIMacro(File), DICommonBlock, DIObjCProperty, DIStringType, DISubrangeType, DIFixedPointType,
  GenericDINode) with the verifier's visit for each; checked against llvm/test/Assembler/{DICommonBlock,DIEnumerator,
  DIMacroFile,dimodule,diobjcproperty,generic-debug-node,debug-info}.ll. DIEnumerator/DIFixedPointType values wider
  than 64 bits (DIEnumeratorBig.ll) fail loudly. A `!dbg` attachment that is not a DILocation is LLParser's
  "invalid !dbg metadata" error. Operands are kept in LLVM's operand order (it decides `!N` numbering), ints
  in a per-kind layout documented next to `parse_di_node`. DICompositeType with an identifier goes through
  buildODRType (opt enables the DITypeMap, so such nodes are distinct and merged by identifier).
  UpgradeDebugInfo strips debug info without "Debug Info Version" 3; with version 3 it runs the verifier
  (verifier.jai) and strips broken debug info with LLVM's warning ("Verifier" below).
- `uselistorder` directives reorder use lists at parse time (stable sort by index).

## Debug records and metadata uses (for passes)

- `Inst_Row.records` chains the debug records before an instruction; `erase_inst` moves them to the next
  instruction like DbgMarker::removeMarker (erasing a terminator with records is fatal).
- ValueAsMetadata does not create uses. The parser updates it when a forward-reference placeholder is resolved
  (`md_value_rauw`), but `replace_all_uses_with` does not (LLVM's ValueAsMetadata::handleRAUW): a pass that
  RAUWs values referenced by `#dbg_value` must call md_value_rauw too (or ir.jai should do it).

## Verifier (L1.verifier: 224/229 ::error, Verifier dir 395/408; DESIGN.md "Verifier")

- Files: verifier.jai (state, diagnostics, the verifier's ModuleSlotTracker `vst`, drivers, globals, functions,
  blocks, non-call instructions, EH pads, dominance), verifier_md.jai (generic metadata, DI nodes, debug records,
  module flags, instruction/function attachments, TBAAVerifier), verifier_calls.jai (calls, attributes, musttail,
  inline asm), verifier_intrinsics.jai (visitIntrinsicCall, VP / constrained FP, statepoints, isSignatureValid with
  LLVM's messages, the convergence verifier). knowledge/llvm/verifier.md has the facts the messages depend on.
- opt runs it like LLVM: in UpgradeDebugInfo (debug info not an error; broken IR is `LLVM ERROR: Broken module
  found, compilation aborted!` and exit 134, broken debug info is stripped with `warning: ignoring invalid debug
  info in <file>`), on the input unless `-disable-verify` (`opt: <file>: error: input module is broken!`, exit 1),
  at the end of the pipeline (VerifierPass), for `verify` / `function(verify)` / `require<verify>`, and after every
  pass with `-verify-each` (we print the pipeline name of the pass where LLVM prints its class name).
- `vcheck` / `vcheck_di` are `#expand` macros whose message and values are `Code`: they are evaluated only when the
  check fails, like the C++ macro's Twine (eager evaluation formatted attribute strings for every call and indexed
  out of range in the phi checks). Trap: an argument with a `,,` named-argument call (`builder_to_string(*s,,
  allocator = temp)`) does not survive the `#insert`: compute it into a variable first.
- Printing goes through printer.jai with `vst_lazy()` hooks at every slot lookup (a no-op outside the verifier):
  module slots and *all* metadata at the first lookup, a function's local slots at the first lookup after an
  instruction of it was printed. The printer state is reset after each run (`vst_end`).
- Representation gaps the port works around: jai doesn't keep `dso_local` for implicitly dso_local values (that
  check is left out; it can't fire in LLVM either); FuncletPadInst keeps the parent pad last (inline_function.jai's
  `eh_parent_pad` reads operand 0, which is wrong for catchpad/cleanuppad); `set_metadata` now removes every
  attachment of the kind (LLVM's MDAttachments::set), which StripDebugInfo needs for a function with two `!dbg`.
- Not ported (unreachable here): checks of DI node kinds our parser rejects (DIEnumerator, DIGenericSubrange,
  DIStringType, DISubrangeType, DIFixedPointType, DIModule, DIMacro*, DICommonBlock, DIObjCProperty, GenericDINode),
  VerifierAMDGPU.cpp, target intrinsics outside our tables (aarch64/arm/nvvm/wasm cases), the
  `-verify-noalias-scope-decl-dom` dominance check (off by default; fails silently), "in another module" checks (one
  module per process).
- Sweeps (every round-tripping file, 10803): `--passes verify --analysis` (stderr compared), `--passes verify`
  (IR) and `--passes 'function(verify)' --analysis`: all identical (the 3 earlier differences were StripDebugInfo
  counting dropped debug records as a change, which printed a spurious "invalid version" warning; fixed).
- Remaining Verifier test failures: DIGenericSubrange (2) and DIEnumerator (4 files) are parser gaps, 3 need x86
  auto-upgrades (`llvm.x86.sse2.pshuf*`) that fail loudly.
- Cost (x64 build, sqlite3.ll, `-disable-output`): parse 0.74 s, input + output verification +0.34 s (LLVM's whole
  run 0.73 s). Caches that keep it there: per-run module flag and md-kind lookups, intrinsic ids per function
  (`vf.iid_cache`), access tags whose TBAA walk passed (`vf.tbaa_ok`), call-site (attribute list, function type)
  pairs that passed verifyFunctionAttrs (`vf.attrs_ok`), one scan of an instruction's attachments
  (`vf_visit_instruction_metadata`), the DominatorTree built on first use.

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
- constfold.jai: the `and (ptrtoint @g), C` alignment fold (needs DataLayout) fails loudly.
- ppc_fp128 (`apfloat_dd.jai`, DoubleAPFloat): words [hi, lo]. add/sub/mul/compare/next/roundToIntegral/
  convertToInteger/convertFromAPInt/ilogb/scalbn/frexp/isDenormal/... are LLVM's double-double algorithms on two
  doubles; divide/remainder/mod/fma, string conversion (parser, printer's toString round trip) and conversion from
  other IEEE formats go through semPPCDoubleDoubleLegacy, which is the internal `Type_Kind.PPC_LEGACY` (an IEEE
  format, p=106, minExponent -969; `PPC_LEGACY_EXT` has double's minExponent) handled by the generic IEEE code.
  Conversion to another format converts only the first double (APFloat::convert). The IEEE-level functions in
  apfloat*.jai dispatch on `.PPC_FP128` first; `fp_encode`/`fp_check_kind` abort if a ppc value reaches IEEE-only
  code. Checked with random ppc_fp128 folds (fadd/fsub/fmul/fdiv/frem/fcmp/fpto[su]i/[su]itofp/fptrunc/fpext,
  rounding intrinsics, fma, ldexp, frexp, min/max, literals) under instsimplify and instcombine: 0 diffs. The
  printer prints `+Inf`/`-Inf` for (inf, -0) like LLVM (toString, then an equal value converts back).
- Erased values keep their rows (`v_kind = DEAD`); nothing is compacted.

## Heap/pointer address order: fail loudly, guess only behind our flags

Policy (decided by /root): where LLVM's output depends on heap or pointer address order (DenseMap/SmallPtrSet
iteration over pointers, sorts by pointer, `std::less<T *>` tie-breaks), impl/jai fails loudly by default and guesses
(usually creation order) only behind an explicit flag of ours, `-<pass>-guess-address-order`. LLVM does not know
these flags, so they cannot be swept against the oracle; they exist to look at what the guess would print.

| Where | Fails when | Flag |
| --- | --- | --- |
| gvn-sink (`InstructionUseExpr` users sorted by address) | two candidates have the same users as a multiset in a different order | `-gvn-sink-guess-address-order` |
| newgvn (`shouldSwapOperands` rank tie, predicate copy of an equality of two different equal-rank operands) | some predicate copy saw such a tie and a second iteration with the ties broken the other way reaches a different fixpoint (reachability, leaders, phi-of-ops temporaries) | `-newgvn-guess-address-order` |
| gvn-hoist (`OutValue` is a `DenseMap<BasicBlock *>`; load keys contain the `Type *`) | an instruction hoisted into one block uses (also through GEPs) one hoisted into another block in the same round; or two loads of different types from one address hoist into one block | `-gvn-hoist-guess-address-order` |
| delinearization (`array_pod_sort` of the terms by SCEV pointer) | findArrayDimensionsRec gives another result with every group of equal-factor-count terms reversed | `-delinearize-guess-address-order` |
| loop-simplifycfg (`SmallPtrSet<BasicBlock *, 2>` of dead successors) | more than two dead successors (DT update order) | `-loop-simplifycfg-guess-address-order` |
| ir-similarity (CheckLargerCands: `DenseSet<IRSimilarityCandidate *>`, colliding group numbers) | the canonical numberings of the possible choices differ (all are computed; never on the corpus) | none |
| iroutliner (the exits of a region: `SmallPtrSet<BasicBlock *, 1>`) | two or more exit blocks contribute PHINode outputs | none |
| structurizecfg (SSAUpdaterBulk's deduplicatePass: a `SmallDenseMap<BasicBlock *, unsigned>` walk) | deduplicating one block's new phis changes whether another block's new phis are identical | `-structurizecfg-guess-address-order` |
| structurizecfg (DenseMap walks with early exits in isPredictableTrue / dominatesPredicates) | only the dominator tree's slow-query count differs; `print<domtree>` of such a tree with invalid DFS numbers fails | none |
| lower-switch (`SmallPtrSet<BasicBlock *, 8>` DeleteList) | more than 8 blocks to delete | none |
| normalize (`reorderInstructionOperandsByNames` sorts `(name, Value *)` pairs) | two different operands of a commutative instruction with the same operand text | `-normalize-guess-address-order` |
| strip-dead-debug-info (`std::set<DICompileUnit *>` LiveCUs rebuilds llvm.dbg.cu) | dead CUs are dropped and more than one CU stays live | `-strip-dead-debug-info-guess-address-order` |
| print<stack-safety-local>, print-stack-safety (`UseInfo::Calls`, a `std::map` by `(ParamNo, Callee *)`) | two different callees for one argument number of a use (~220 corpus files) | `-stack-safety-guess-address-order` |
| attributor -attributor-print-call-graph (rewritten functions join A.Functions in DenseMap<Function *> order) | more than one signature rewrite | none |
| codegenprepare, function-specialization, InstCombine fsqrt, attributor (signature rewrites), SLP reorder | already fail loudly or check order independence where they meet pointer order (see their sections) | none |

Audited and order-independent (no flag): memdep's NonLocalDepEntry sort (GVN only materializes unnamed values in
that order), LazyCallGraph::removeDeadFunctions (RefSCCs split independently), getMinMaxRecurrence's chain (equivalent
early returns), LoopSimplifyCFG/DSE/SimplifyCFG switch sets read for membership only, ScalarEvolution guards
(membership), the verifier's phi sort (only the message order on invalid IR). Sweeps after the change: newgvn 10789
identical, 0 differs, 12 loud (address order) of 10804; gvn-hoist 10809/10809; print<delinearization> 10809/10809;
print<da> 10806/10807 (the 1 differs is stderr interleaving of a `+mpx` warning, not DA); loop-mssa(loop-simplifycfg)
10805/10809 (4 loud).

## mem2reg and SROA (L1.mem2reg 29/30, L1.sroa 57/61)

- Files: `pass_mem2reg.jai` (PromoteMemToReg; `promote_mem_to_reg(allocas, dt, ac)` is shared with SROA),
  `pass_sroa.jai` (SROA, PtrUseVisitor, Loads.cpp subset), `ssa_updater.jai` (SSAUpdater + LoadAndStorePromoter),
  `ir_builder.jai` (`Irb`: IRBuilder<ConstantFolder> with name prefix and debug-record adoption),
  `value_utils.jai` (`sv_*`: GEP constant offsets, stripInBoundsOffsets, stripAndAccumulateConstantOffsets),
  `dbg_records.jai` (record owner/erase/insert, findDbgUsers order, RAUW/deletion of ValueAsMetadata,
  DIExpression queries, DILocation::getMergedLocation, ConvertDebugDeclareToDebugValue).
- `Dbg_Record.owner` is maintained by `attach_records_before` and `erase_inst`; passes that move records must
  keep it. Since 2026-11 the plain ir.jai `replace_all_uses_with` and `erase_inst` do the ValueAsMetadata half too
  (handleRAUW for an instruction/argument within one function, handleDeletion: records get poison), like LLVM's
  Value::replaceAllUsesWith / ~Value; `rauw_with_metadata` / `erase_inst_with_metadata` are now equivalent. Not
  done implicitly: a constant/global turning into a local and a local moving to another function (LLVM drops the
  metadata there, replaceAllUsesWith(nullptr); callers like GlobalOpt handle it). Before, a forgotten `_with_metadata`
  left `<badref>` records (13 bad-ir, ~100 differs in `debugify,default<O2>`). Code that must keep the old value in
  the records uses `replace_non_metadata_uses_with`.
- Known vscale (`vscale_range(N,N)`, jai_tails 2026-11): slice sizes of scalable loads/stores are min size x N,
  `can_convert_value(old, new, vscale)` accepts fixed<->scalable vectors of equal known size (only from
  isVectorPromotionViableForSlice, through the `sroa_vscale` global set in select_partition_type), and
  `irb_bit_preserving_cast_chain` (ir_builder.jai) emits CreateBitCastLike's `llvm.vector.insert`/`extract` (no
  folding: SROA's IRBuilder uses ConstantFolder, whose FoldIntrinsic returns null). L1.sroa COMPLETE 122/122.
  Assignment tracking: see "Assignment tracking" (assignment_tracking.jai).
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
  (invalid debug info, unknown CPU features) or `%"type 0x…"` addresses. GlobalsAA's CallGraph handles `!callback`
  brokers like CallGraph.cpp (callback uses are not address-taking; each callback callee is an extra edge of the
  caller's node): `default<O2>` on the 17 corpus files with `!callback` 13 identical, 4 loud (OpenMP modules then).
  Sweep script:
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
  atom groups, DIArgList debug locations in remapping.
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
  !callsite/!llvm.access.group/!captures/!callee_type fails loudly; DIAssignID: merge_di_assign_id), `erase_unlinked_inst` (`delete I`).
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
  of `!tbaa`/`!tbaa.struct` in SimplifyAnyMemTransfer.
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
  load/store folds, TargetExtType vector elements.
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
  __small_printf `CI->clone()` rewrites (XCore/TCE/Emscripten triples only) fail loudly;
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
  tests that still fail loudly: modular-format,
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
  `-verify-each` (verifier.jai) and `-aa-pipeline X` (space form) are accepted.
- Fail loudly: `-lvi-per-pred-ranges` (unknown flag), JumpThreading's SplitEdge through splitBlockBefore,
  key-instruction atom groups, trailing debug records after duplicating a block into its predecessor,
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

- `pass_aggressive_instcombine.jai` ports AggressiveInstCombine.cpp completely (merged stores get
  mergeDIAssignID); `aic_trunc.jai` ports TruncInstCombine.cpp. Two TTI hooks live in the pass file
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
  LoopIdiom chains of more than 8 adjacent stores (SmallPtrSet iteration order) whose AA tags differ (equal tags:
  the order only feeds the tag merge and the deletion, so it is not observable); LoopSimplifyCFG with more than two
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
  key-instruction atom groups, ehAwareSplitEdge, the MDNodeMapper. `-pgso` /
  `require<profile-summary>` (PSI-based optsize) and `-O<n>` are not supported, which is what the 4 failing unit
  tests need.
- Shared fixes made here: SCEV `prove_no_wrap_by_varying_start` used signed -2/-1 deltas (LLVM's are 32-bit unsigned,
  see knowledge/llvm/loop-unroll.md); `split_landing_pad_predecessors` put the cloned landingpad before the new phis;
  `merge_block_into_predecessor` got the DT (no DTU) mode (`direct_dt`); `tti_instruction_cost` now delegates to
  `tti_instruction_cost_ops` (constant-expression users get at least 3 operand slots so the old reads stay
  identical — callers pass ConstantExprs, whose `inst_op` is garbage: a latent bug in compute_speculation_cost's use);
  `X86_Lowering.tune_cpu`; opt accepts `-disable-verify` (no input/output verification, see "Verifier") and `-disable-loop-unrolling` (no
  effect on -passes runs).
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
- `require<profile-summary>` exists (passes.jai `psi_cached`); ProfileSummaryInfo is psi.jai (`psi_pass_bfi`).
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

## SLPVectorizer (L1.vectorize.slp COMPLETE 1300/1300)

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
  vector variants (4); with test flags other passes' options. Strided / interleaved accesses are
  unreachable on X86 and fail loudly where LLVM would build them.
- Next steps, in order:
  1. Struct-typed scalars: getWidenedType of a struct (a struct of vectors), checkEVsForVecCalls +
     StructEVIndices (getScalarsVectorizationState 10870, buildTreeRec 13284), allStructUsersAreExtractValueInsts,
     the struct paths of buildExternalUses (9644), getEntryCost (17303), getTreeCost's extract costs (20160-20320),
     vectorizeTree (23386, 23624, the call's TysForDecl 24326, the struct external-use extraction with
     StructFieldExtracts 24869-25169) and the driver (31471, 31939).
  2. VFDatabase vector variants (`-vector-library`, vector-function-abi-variant).
  `tools/slp_cost_compare.py` compares whole decision sequences: run it with a `--with-test-flags` sweep's
  results.tsv after every change; DEBUG_SLP also dumps the module after each vectorizeTree ("DBG IR after
  vectorizeTree") and the CheckForShuffledLoads costs ("DBG cfsl").
- Compile time (x64 debug build): `-passes=slp-vectorizer` on tests/perf/compile costs ~2.5 s over parse+print for
  SPASS.ll / sqlite3.ll (LLVM: ~1 s total); no `@perf` benchmark times SLP. (`comes_before` was a linear walk; it uses the lazily renumbered `Inst_Row.order` since jai_perf2.)
- Sorting: LLVM `stable_sort`s go through `gnu_stable_sort` (scev.jai, libstdc++'s algorithm) when the comparator
  may not be a strict weak order (PHICompare, compareCmp); insertion sort elsewhere. Hash-ordered containers that
  decide results fail loudly when the order matters (collectUserStores with several store groups).
  calculateTreeCostAndTrimNonProfitable's PriorityQueue has distinct (cost, Idx) keys, so a sorted list is exact.
- REVEC (`-slp-revec`, jai_tails 2026-11): every `SLPReVec` site of SLPVectorizer.cpp is ported (gated on
  `slp_cl.revec`), plus the generic vector-"scalar" paths the old guards rejected: getWidenedType of a vector,
  transformScalarShuffleIndiciesToVector in createShuffle (cost and IR), subvector insert/extract costs and
  codegen (createInsertVector / createExtractVector), replicateMask / createReplicatedMask (gathers, masked
  loads, select conditions), getShufflevectorNumGroups / calculateShufflevectorMask (non-alternate shufflevector
  nodes), REVEC reductions (createSingleOp, getReductionCost), split nodes (getSplitMask scaled; the resize mask
  that LLVM copies past its buffer fails loudly). Sweeps with -slp-revec (plain, x86 avx2, skylake-avx512;
  --with-test-flags; --per-function avx2 84653 functions; tests/perf/compile): 0 differs.
- Fail loudly already in the helpers: struct-typed scalars, VFDatabase vector variants, operand bundles in
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

## Performance, round 2 (jai_perf2, 2026-11): -O2

`./harness/run perf --impl jai --instr`, optimized build, before (origin/main 1a141d81, VERY_OPTIMIZED build) ->
after (this round, OPTIMIZED build). Ratios to LLVM; geomean over all rows: cpu 0.99x -> 0.78x, instr 1.02x ->
0.93x, rss 0.97x -> 0.78x.

| `opt -O2` on | cpu | instr | rss |
| --- | ---: | ---: | ---: |
| compile/SPASS.ll | 2.17x -> 1.38x | 2.79x -> 2.22x | 5.52x -> 3.91x |
| compile/lua.ll | 2.19x -> 1.54x | 2.63x -> 2.19x | 1.73x -> 1.84x |
| scaling/calls/n8000 | 2.75x -> 1.69x | 2.86x -> 2.26x | 5.09x -> 5.13x |
| scaling/diamonds/n8000 | 9.29x -> 2.46x | 3.11x -> 2.25x | 44.1x -> 8.84x |
| scaling/allocas/n8000 | 4.13x -> 1.53x | 2.71x -> 2.38x | 4.94x -> 2.39x |
| scaling/switch/n32000 | 3.29x -> 3.01x | 3.34x -> 3.83x | 2.01x -> 2.18x |
| scaling/straightline/n64000 | 9.26x -> 1.25x | 5.30x -> 1.37x | 1.64x -> 1.62x |

(The switch row was measured before the simplifycfg/GVN/PredicateInfo switch fixes below landed in the binary;
`-time-passes` on switch/n32000 then had gvn 11x and simplifycfg 12x LLVM's time.) Not at LLVM's speed yet: most
-O2 rows still execute 2-2.5x LLVM's instructions, spread over every pass (InstCombine ~3x, inline cost analysis
~2.5x, GVN ~2x, LVI/ConstantRange in CVP ~3x); the CPU ratio is lower than the instruction ratio (LLVM's code has
more cache misses).

What changed (behaviour unchanged: full ratchet, also under `MALLOC_PERTURB_=165`; sweeps of default<O2>,
default<O3>, instcombine, slp-vectorizer, inline, function-attrs,inline, mergefunc, simplifycfg,
constraint-elimination, gvn show no new differs or failures; L2.pipeline-O2 unchanged at 240/241):
- System time: `modules/Default_Allocator` (glibc malloc) instead of Jai's rpmalloc, which madvise'd every empty
  span away; temp storage gets an 8 MB base block and keeps its overflow pages (temp_pages.jai). SPASS: 1.26M -> 93K
  page faults, 3.2 s -> 0.3 s of system time.
- `temp` is our own bump allocator (ptemp.jai; ir.jai imports Basic `using,except(temp, reset_temporary_storage)`):
  the most recent allocation grows in place, blocks are kept across passes. ~2% of instructions.
- Quadratic or per-call costs: Instruction::comesBefore with lazily renumbered `Inst_Row.order` (was a list walk;
  ConstraintElimination's fact sort on diamonds), the DominatorTree node map indexed by block number with slots that
  name their block (was by block row from the function's lowest row: after inlining that range spans the module, and
  filling it was 5.6% of SPASS), SLP containers reused across the trees of one seed list (2.7 GB -> ~0.3 GB of temp
  on diamonds/n8000; Processed sets as "list ends with this entry"), GVN's and PredicateInfo's switch edge counts and
  SimplifyCFG's IncomingVals / duplicate-predecessor sets as hash maps, InstCombine's worklist map and deferred set as
  stamped dense arrays.
- String building on hot paths: arch_of in instCombineIntrinsic (tprint per call, 3.4% of lua), the inliner's
  inline-remark message (built for every call site even without -inline-remark-attribute), SLP's libm-name check,
  `tconcat` for value names; `md_fixed("kind")` resolves fixed metadata kinds at compile time.
- Lookups: TTI per attribute set id, TLI per function and a name cache in front of the libfunc table, intrinsic ids
  and base names in dense arrays, attribute sets carry a bitmask of their kinds (hasAttribute without a scan).
- Use-after-free bugs that the allocator switch exposed (with rpmalloc freed memory stayed intact): InstCombine's
  cached AAResults outlived the DominatorTree / AssumptionCache of an earlier run on the same function;
  AddAlignmentAssumptions, MergeFunctions (new function / alias) and InstCombine's call_with_default_bundles held a
  pointer into a table (`*Attr`, `glob()`, `inst()`) across an append that moved it. Rule: never hold `inst(x)`,
  `glob(x)`, `block(x)` or attribute pointers across code that creates values, globals or attribute sets.

Still slow / next:
- InstCombine (2-4x LLVM's instructions): no single hotspot; known bits, pattern matching, attribute and TLI queries.
- Inline cost analysis (calls/*): `simplify_binop` on every binary operator is ~4x LLVM's simplifyBinOp.
- diamonds/n8000 RSS: SLP still allocates per-tree arrays (horizontal-reduction operand lists, vl copies,
  scheduling dependencies) from temp, which is only reset between passes.
- CVP/LVI: ConstantRange multiply and the LVI cache (~3x).

## CGSCC, FunctionAttrs, inliner (L2.function-attrs COMPLETE 118/118; L2.inline COMPLETE 466/466)

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
  `always-inline` (MAM.getResult) set it.
- Ported in jai_tails (2026-11): salvageKnowledge(&CB, AC) in InlineFunction (so `--enable-knowledge-retention` works
  under cgscc / the inliners), X86TTIImpl::areTypesABICompatible in areInlineCompatible (reuses attributor_mem.jai's
  ap_are_types_abi_compatible_for), tryPromoteCall's promoteCall (wpd_function_at_vtable_offset + atr_promote_call),
  strictfp hosts (PruningFunctionCloner::cloneInstruction: constrained intrinsics with round.tonearest /
  fpexcept.ignore, `strictfp` on every cloned call; the `.strict` name is overwritten by CloneBlock's suffix rename),
  inlineRetainOrClaimRVCalls, propagateMemProfMetadata with memory_profile_info.jai (MemoryProfileInfo.cpp's
  CallStackTrie built from existing MIB metadata; also for the profile passes). L2.inline COMPLETE 466/466.
  Sweeps: inline 10923/10923, --with-test-flags 0 differs, --enable-knowledge-retention and
  -memprof-callsite-cold-threshold=50 0 differs.
- Fail loudly: the replay / ML advisors, the MDNodeMapper, -memprof-report-hinted-sizes messages.
- Trap: InstCombine's transformConstExprCastCall must call `value_is_rauwd(call, new_call)` when the old call has no
  uses: the CGSCC devirt wrapper's WeakVH on the call follows it, otherwise devirt<N> sees a "new" direct call and
  repeats (Inline/inline-indirect-chain.ll).
- Perf (`./harness/run perf`, optimized build, `-passes=inline` on scaling/calls): 3.9x / 3.9x / 3.5x LLVM's time at
  n = 500 / 2000 / 8000, scaling exponent 0.92 (LLVM 0.97). callgrind (x64 build, 120 functions): the same number of
  simplifyBinOp calls as LLVM (454,972); ~90% of the time is the shared InstSimplify / ConstantFold code called by
  CallAnalyzer::visitBinaryOperator (constant creation hashes a key per folded constant).


## Attributor (`attributor`, `attributor-cgscc`, `attributor-light`, `attributor-light-cgscc`; L1.extra.attributor)

- Files (Attributor.cpp + AttributorAttributes.cpp, about 9.8k lines):
  - `attributor.jai`: the framework. IRPosition as `Irp{enc, v}` with LLVM's encoding bits, the integer states as
    `Bstate{known, assumed, best}`, `Abs_Attr` rows indexed by u32 with a per-kind extension `x` (`*_ext(i)`
    accessors), getOrCreateAAFor = `atr_get_aa`, runTillFixpoint, manifest + AttrsMap, seeding, the
    InformationCache, the MustBeExecutedContextExplorer (`mbe_*`), the cl::opts (`atr_parse_cl_opt`), the passes.
  - `attributor_aas.jai`: the dispatch (`aa_construct` / `aa_initialize` / `aa_update_impl` / `aa_manifest`,
    switches on (kind, position kind)) and the 17 light AAs.
  - `attributor_query.jai`: liveness queries, the checkForAll* iterators, AbstractCallSite (`Acs`, `acs_*`),
    checkForAllUses, getAssumedSimplifiedValues, potential copies, reachability.
  - `attributor_dead.jai` (AAIsDead, AAUndefinedBehavior), `attributor_values.jai` (AAPotentialValues,
    AAPotentialConstantValues, AAValueConstantRange, the generic clamps), `attributor_ptrinfo.jai` (AAPointerInfo),
    `attributor_misc.jai` (NoAlias, Dereferenceable, Align, NoUndef, InstanceInfo, AssumptionInfo, GlobalValueInfo,
    IndirectCallInfo, InvariantLoadPointer, AddressSpace, AllocationInfo, NonConvergent), `attributor_mem.jai`
    (HeapToStack, PrivatizablePtr), `attributor_cleanup.jai` (changeAfterManifest, cleanupIR, signature rewrites,
    indirect call specialization / promoteCall, wrappers, internalization, the CallGraphUpdater steps).
  - knowledge/llvm/attributor.md has the behaviour that matters.
- No closures in Jai: the checkForAll* walks are `for_expansion` iterators (`atr_insts`, `atr_call_like_insts`,
  `atr_rw_insts`, `atr_call_sites` with `it` the call and `acs` the AbstractCallSite) that keep LLVM's interleaving of
  liveness checks and predicate; the body clears `ok` and breaks when the predicate fails. checkForAllUses is an
  explicit walk (`atr_uses_begin` / `atr_uses_next` / `atr_uses_follow`, the EquivalentUseCB as an `EQU_*` kind).
- `optional<Value *>`: `OV_NOVAL` is std::nullopt, `NONE` is nullptr.
- Memory: one run's AAs, extensions, information cache and bookkeeping live in `atr_pool` (a Flat_Pool reset by
  `atr_reset`). Allocate AA state with `atr_new(T)`, which also points every [..] array and Table *directly inside*
  T at the pool. Arrays created later (locals stored into the state, table values) keep their allocator and leak
  per run; that is small. Without the pool the CGSCC pass grew by ~40 MB/s on SPASS.ll (every run's 1-2k AAs kept,
  OOM-killed after 3 min); with it SPASS peaks at 730 MB.
- Trap: `Mbec_State` and followUsesInMBEC hold pointers into an AA's state; follow-ups that create AAs can reach the
  AA being initialized through the map: update its state in place, never a local copy.
- Trap: `md_node_op` returns only MDNode operands; the integer operands of `!callback` encodings need `md_op`.
- Unsupported, fails loudly: `-attributor-enable-call-site-specific-deduction` (IRPositions with a CallBaseContext),
  `-attributor-print-call-graph` / `-attributor-print-dep` / `-attributor-dump-dep-graph` (pointer-valued DOT output),
  several privatizing signature rewrites with call sites in one caller (DenseMap pointer order, see knowledge),
  GPU address spaces (AAAddressSpace / AANoAliasAddrSpace are pessimistic on x86), deep wrappers in the CGSCC pass,
  promoting a call with a byval/inalloca argument of another type or an invoke with another return type.
- Status: 290 of the 301 `@opt` lines of tests/imported/llvm/Transforms/Attributor match (the rest: 4
  call-site-specific, 4 openmp-opt, 2 DenseMap order, 1 print-call-graph). Sweeps `attributor` and
  `attributor-cgscc`, plain, `--with-test-flags` and over tests/perf/compile: 0 differs, 0 bad-ir; loud: the DenseMap
  order (4 files), knownbits-x86-hadd-hsub (ValueTracking), and redundant-left-shift-input-masking-no-widen.ll
  (`i5754496`: LLVM needs 2 min; we get OOM-killed in the APInt code).
- Compile time, x64 build, SPASS.ll: `attributor` 38 s vs LLVM 4.9 s; `attributor-cgscc` 190 s vs LLVM 18 s.
  The ratio (8-10x) is the x64 build's usual one; no perf benchmark runs these passes.
- Next steps:
  1. Call-site-specific deduction: an `Irp` needs a CallBaseContext (part of the AA map key), passed through
     `aa_callee_to_call_site` / the returned-value clamps (cb_liveness_enabled.ll, cb_range_enabled.ll).
  2. The privatizing-rewrite name order is a DenseMap<Function *> walk: only reachable by guessing allocation
     addresses; keep it loud.
  3. Profile the CGSCC pass with the optimized build (`harness/run perf` has no benchmark for it yet).

- `-attributor-print-call-graph` (jai_tails 2026-11): populateAll creates AACallEdges for every function before the
  fixpoint (this changes the IR, so it is not just a printer); print writes the DOT graph to stdout with made-up node
  addresses (LLVM prints pointers). The node and edge order matched LLVM on all Attributor tests that don't fail.

## Code extraction: CodeExtractor, PartialInliner, HotColdSplitting, LoopExtractor, BlockExtractor (L1.extra.code-extraction COMPLETE 194/194)

- Files: `code_extractor.jai` (CodeExtractor.cpp incl. the debug-info fixup), `pass_partial_inliner.jai`
  (PartialInlining.cpp, single- and multi-region), `pass_hot_cold_split.jai` (HotColdSplitting.cpp),
  `pass_loop_extract.jai` (LoopExtractor.cpp and BlockExtractor.cpp). `clone_function(f, *vm)`
  (function_specialization.jai) is LLVM's CloneFunction. `bpi_calculate(..., no_tli = true)` is
  BranchProbabilityInfo(F, LI) without a TLI, as PartialInliner builds it for the clone. Facts:
  knowledge/llvm/code-extraction.md.
- `ce_new(..., suffix, void_return_with_single_output = true)`: the default matches LLVM's constructor; PI and
  HotColdSplit pass false.
- Trap (verified against the assertions opt): computeOutliningInfo's `HasNonEntryPred` lambda captures the `Entries`
  set *by value* before the peeling loop, so a block whose predecessor was only peeled in that loop stops the
  peeling (Inline/inline-byval-bonus.ll: 2 entries, not 4).
- Moving blocks/instructions into the outlined function drops their names from the old function's symbol table and
  re-adds them in the new one (instructions, then the block), like BasicBlock::setParent.
- `ce_extract_code_region` drops the old function's cached analyses (`table_remove(*fam, old)`); LoopExtractor keeps
  using the DT / LoopInfo pointers it already holds, but a later pass recomputes LoopInfo where LLVM keeps the
  preserved (erased-loop) one.
- `inline_function(..., forward_var_args_to)` is InlineFunction's ForwardVarArgsTo (only partial inlining uses it).
- Findings outside these passes: x86_fp80 `+snan(0x0)` from the per-function split reparses to `+snan(0x1)` (the
  only per-function differences); `print<da>` interleaves a `+mpx` target warning differently on stderr.
- Not ported (fail loudly): aggregate arguments, explicit allocation/deallocation blocks, out-of-region lifetime
  markers on in-region casts of an alloca; partial inlining of a function referenced by a blockaddress.
  Optimization remarks are not emitted.
- Sweeps (0 differs everywhere): `hotcoldsplit` 10807/10807, `-hotcoldsplit-threshold=-1` 10790/10791 whole-file and
  83347/83350 per function (the x86_fp80 parse issue), `--with-test-flags` (also with threshold -1) 0 differs, loud =
  other passes' options; `loop-extract` 10803/10803, `function(loop-simplify),loop-extract` 10804/10804 and per
  function 83444/83446 (x86_fp80); `extract-blocks` 10809/10809; `partial-inliner` 10806/10807 with and without
  `-skip-partial-inlining-cost-analysis`, `-min-block-execution=1`, `-pi-force-live-exit-outline` (1 loud:
  blockaddress), `--with-test-flags` 0 differs; tests/perf/compile `function(sroa),hotcoldsplit`,
  `hotcoldsplit -hotcoldsplit-threshold=-1`, `function(loop-simplify),loop-extract`, `partial-inliner` 4/4.
  Debugging aids: JAI_PI_DEBUG prints the outlining costs and the module before the partial inlining, JAI_IC_DEBUG
  prints the CallAnalyzer counters LLVM's `-debug-only=inline-cost` prints.

## IRSimilarityIdentifier, IROutliner (L1.extra.ir-outliner COMPLETE 188/188; /root/jai_outline_r)

- Files: `ir_similarity.jai` (IRSimilarityIdentifier.cpp, SuffixTree.cpp, `print-ir-similarity`),
  `pass_ir_outliner.jai` (IROutliner.cpp, `iroutliner`; also reachable through `-ir-outliner` in default<O*>).
  Facts: knowledge/llvm/ir-outliner.md.
- `Dm32` (ir_similarity.jai) is a bucket-exact model of LLVM 23's `DenseMap<unsigned, unsigned>` / `DenseSet`
  (linear probing, Algorithm R erase, clear/shrink, remove_if rehash, copy): use it wherever LLVM iterates a map with
  integer keys and the order shows. `dm32_alloc` must give the map fresh buffers: `grow` keeps reading the old ones.
- The IRInstructionDataList is rows of `irsim.data` with simple_ilist's exact link updates (row 0 = sentinel), because
  populateMapper links a row to itself and the outliner then inserts/erases around it (knowledge file).
- Address order: CheckLargerCands computes the canonical numbering for every larger-candidate choice LLVM could make
  (pointer-order DenseSets) and fails loudly only if they differ; the outliner fails loudly for a region with two or
  more exit blocks that contribute PHINode outputs (SmallPtrSet order). Neither fires on the corpus.
- Traps met: `fn_add_fn_attr` replaces by kind, and every string attribute is one kind (`.STRING_ATTR`): adding a
  string attribute with it drops the others; use `fn_add_fn_str_attr`. `attr_set_items` is a view into the attribute
  pool, which adding attributes can move: copy the items first. `inst_insert_before` does not move the position's
  debug records; LLVM's insert at an `Instruction *` (no head bit) makes the new instruction adopt them.
- `ce_extract_code_region(ce, cache, inputs_out, outputs_out)` hands back the inputs/outputs (the
  extractCodeRegion(CEAC, Inputs, Outputs) overload).
- Not ported: optimization remarks (`-pass-remarks*` are unknown options here), the multi-module
  findSimilarity(ArrayRef<Module>), SuffixTree's OutlinerLeafDescendants mode (MachineOutliner only).
- Debugging aid: JAI_IOR_DEBUG prints the module before and after each extraction and after the reattach.
- Sweeps (0 differs everywhere): `print-ir-similarity` 10812/10812 identical, `--with-test-flags` 13008/13628 (loud
  = other passes' options); `iroutliner -ir-outlining-no-cost` 10702/10702 (110 LLVM failures skipped), `iroutliner`
  (cost model) 10805/10805, `--with-test-flags` with and without the cost model 0 differs (loud = other options),
  `-no-ir-sim-branch-matching`, `-ir-sim-calls-by-name -enable-linkonceodr-ir-outlining`,
  `-no-ir-sim-intrinsics -no-ir-sim-indirect-calls` 0 differs; tests/perf/compile `iroutliner` with and without the
  cost model and `print-ir-similarity` 4/4; `-O2 -ir-outliner` 2/4 (sqlite3.ll: the PHINode-exit address order, loud;
  SPASS.ll: -O2 alone is over the CPU limit).
- Perf (x64 build, `-passes=iroutliner -disable-output`): SPASS.ll 13.5 s (LLVM 2.5 s), sqlite3.ll 10.4 s (LLVM 5.5 s
  with -ir-outlining-no-cost, 3.7 s with the cost model), lua.ll 2.4 s (0.7 s). Most of SPASS.ll's time is
  findCandidates computing the canonical numbering for every possible larger-candidate choice (354k choices);
  the CodeExtractorAnalysisCache of the analysis phase is lazy (`ce_cache_lazy`) because building it per region
  over the whole function dominated sqlite3.ll. JAI_IRSIM_TIME prints the suffix tree / findCandidates times.

## LoopVectorize (L1.vectorize.loop 463/468 opt, 468/468 roundtrip; .outer/.reductions/.tail-folding/.epilogue COMPLETE)

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

- jai_loopvec5 added: in-loop and ordered reductions (createInLoopReductionRecipes, VPReductionRecipe execute,
  getReductionPatternCost in the legacy model), VPExpressionRecipe + convertToAbstractRecipes (`vplan_expression.jai`:
  member recipes are unlinked rows in `expr_recipes`, placeholders are symbolic values; `vp_duplicate` rebuilds the
  members' user lists), handleMaxMinNumReductions, masked div/rem intrinsics, active lane masks (both styles, the
  ALM phi), masked interleave groups, -force-partial-aliasing-vectorization (alias mask check block), outer-loop
  vectorization (VPlan-native path; the recipe/execution code was already there, the gates were legality, the outer
  VF heuristic, nested regions with a null-typed canonical IV and tryToConvertVPInstructionsToVPRecipes), scalable VFs
  (forced `vscale x N` widths, `-scalable-vectorization` on NoTTI: scalable max VFs, vscale expansion, ScalableLast
  lanes encoded as `LANE_SCALABLE_LAST | k` in vs_get_lane, splats/step vectors/splices/reverses/interleaves via
  intrinsics), struct-typed values (sincos-style intrinsics, extractvalue widening, BuildStructVector), discriminators
  (cloneByMultiplyingDuplicationFactor, also in LoopUnroll), replicated assumes registered in the AssumptionCache,
  operand bundles on widened calls, dereferenceable assumptions, X86 reg usage of extended vector types.
- Traps met (jai_loopvec5): the VPTransformState and epilogue-resume builders are `IRBuilder<>` (ConstantFolder):
  never use InstSimplify-folding helpers (`isf_*`) there (`icmp eq (xor x, true), false` must stay); ConstantFolder
  does not fold intrinsic calls either; `int Stride = getPtrStride(...)` truncates (INT64_MAX is -1, so such
  accesses are reverse-consecutive); isOutsideLoopWorkProfitable receives processLoop's *local* SEL, not the CM's
  (which changes when tail folding fails); a NumActiveLanes VPInstruction does not name its call; outer loops get no
  computeMinimalBitwidths and no LoopAccessInfo (laa is null); a scalable forced width makes supportsScalableVectors
  true even without -force-target-supports-scalable-vectors; for scalable VFs collectLoopScalars only copies the
  uniforms and assume/lifetime replicates become single scalars; X86 getRegisterBitWidth(scalable) is 0, NoTTI's is
  `vscale x 32`. Never push from the middle of a rebase (HEAD is detached there; `git status` first).
- Sweeps at the end of jai_loopvec5: plain, `--with-test-flags`, `--with-test-flags --per-function` (0 differs),
  `sroa,loop-vectorize` on tests/perf/compile, the 919 + 76 -O2 inputs (`tools/o2_lv_inputs.py --compare`): all
  identical; plus extra-flag sweeps that found real bugs: `-prefer-inloop-reductions`, `-force-ordered-reductions`,
  tail folding styles `data` / `data-and-control` with `-tail-folding-policy=prefer-fold-tail`,
  `-force-partial-aliasing-vectorization`, masked interleaving, `-enable-vplan-native-path`,
  `-vplan-build-outerloop-stress-test`, `-force-vector-width=vscale x 4`, `-scalable-vectorization=on
  -force-target-supports-scalable-vectors`, avx2 / avx512 triples, epilogue-forced VFs: all 0 differs.

- `replace-with-veclib` (pass_replace_with_veclib.jai, ReplaceWithVeclib.cpp; jai_tails 2026-11): also llc's IR
  pass. It uses its own TTI-less isVectorIntrinsicWithOverloadTypeAtArg / ...ScalarOpAtArg (VP casts, EVL operands,
  target intrinsics fall through to the generic rules), unlike vplan_execute.jai's, which fails loudly on VP/x86.
  Sweeps: replace-with-veclib with -vector-library=AMDLIBM/SVML/LIBMVEC/sleefgnuabi/ArmPL -mattr=avx512f 10923/10923;
  inject-tli-mappings,loop-vectorize,replace-with-veclib with SVML 10917/10917; --with-test-flags 0 differs.

- `--pass-remarks=loop-vectorize` (opt_remarks.jai; only this pattern, anything else fails loudly): prints LV's
  passed remarks ("remark: <file>:<line>:<col>: vectorized loop (vectorization width: 4, interleaved count: 1)") on
  stderr, turns on ORE->allowExtraAnalysis in legality (every check runs; `lv_do_extra_analysis`) and ORE->enabled(),
  which tags the loops with `llvm.loop.vectorize.body` / `llvm.loop.vectorize.epilogue` (found by the sweep). Sweeps
  with the flag: IR 10922/10922, --with-test-flags IR and --analysis (stderr compared) 0 differs.

- Histograms (`-enable-histogram-loop-vectorization`, jai_tails 2026-11): legality's
  canVectorizeIndirectUnsafeDependences + findHistogram (`Lvl.histograms`), widenIfHistogram in
  lvp_make_mem_op_widening_decisions (after the reduction stores and the scalar-VF clamp), VPHistogramRecipe
  execute/cost (`lv_histogram_cost`, shared with the legacy CM's Add/Sub), the X86 type-based cost of
  histogram.add (uadd.sat/umax/umin stay loud), no scalar interleaving with histograms. tests/pass/loop-vectorize/
  histogram-variants.ll covers sub, constant increments, masks (tail folding, conditional) and X86 (avx512f).
  Sweeps with the flag (plain, x86 avx2, -force-vector-width=4): 0 differs.

### LoopVectorize next steps (each fails loudly with the quoted message today)

1. Histograms (`-enable-histogram-loop-vectorization`, 1 test): LAA histogram detection, VPHistogramRecipe.
2. EVL tail folding (`-force-tail-folding-style=data-with-evl`; needs a target with active vector length, so only
   forced): VPWidenLoadEVL / StoreEVL / ReductionEVL / InterleaveEVL recipes, addExplicitVectorLength.
3. A cached ProfileSummaryInfo (`require<profile-summary>`, optsize.ll: PGSO), `--pass-remarks` output, the
   `replace-with-veclib` and `pseudo-probe` passes (other units' tests that run LV).
4. Uncountable exits with side effects (-enable-early-exit-vectorization-with-side-effects).
5. Scalable leftovers: epilogue vectorization of scalable main loops, scalable epilogue VFs, scalable masks for gaps.
6. `-enable-wide-lane-mask` (tryToReplaceALMWithWideALM), partial reductions (only reachable on targets with
   partial-reduction costs), willGenerateVectors with an EXPRESSION recipe (llvm_unreachable in LLVM).

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
  CorrelatedValuePropagation), `rel-lookup-table-converter`, `cg-profile` (indirect calls: VP targets through
  the pgo-icall-prom InstrProfSymtab, `cg-profile<in-lto-post-link>` for post-link pipelines), `ee-instrument<[post-inline]>`, `memprof-remove-attributes`, `recompute-globalsaa`.
- Early exits that are exact for every module without the feature (and fail loudly otherwise): `alloc-token` (no
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
  the pipeline. Resolved in L2.pipeline-O2: it was ComputeMaxSignificantBits honouring instruction flags (LLVM's
  call passes UseInstrInfo in the Depth slot, see below).

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
  go into the Value_Map's MD map before RemapInstruction. Uniqued metadata cycles fail
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
- LoopInterchange, DependenceAnalysis and Delinearization: see "Default pipelines (L2.pipeline-O2)" below.

## Default pipelines, DependenceAnalysis, LoopInterchange, ExpandMemCmp (L2.pipeline-O2 240/241, L2.phase-ordering 130/144, L1.o2-gaps COMPLETE 380/380, L2.perf-corpus 54/56)

- Files: `pass_builder_pipelines.jai` (PassBuilderPipelines.cpp: `-O#`, `default<O#>`; built as Pass_Node rows,
  `-jai-print-pipeline` diffs against `opt -print-pipeline-passes`), `dependence_analysis.jai` (DependenceAnalysis.cpp,
  `print<da>`, `print<da><normalized-results>`, `require<da>`), `delinearization.jai` (Delinearization.cpp,
  ScalarEvolutionDivision.cpp, ScalarEvolution::getElementSize, `print<delinearization>`, `print<scev-division>`),
  `pass_loop_interchange.jai` (LoopInterchange.cpp). Imported: Analysis/DependenceAnalysis (72/72),
  Analysis/Delinearization (23/23), both in the L1.o2-gaps exit selector.
- Use `./harness/run bisect` for every pipeline mismatch: it names the first diverging opt-bisect position. Then
  rerun that pass (and its neighbours) standalone on LLVM's `-opt-bisect-limit=<n-1>` output: if standalone agrees,
  the difference is pipeline state, not the pass. The state differences found so far:
  - **Block numbers.** `SimplifyCFGPass::run` calls `F.renumberBlocks()` after any change (and
    `DT->updateBlockNumbers()`); mem2reg orders PHI blocks by number, so the renumbering decides the `.N` version
    suffixes of SROA's phis later (fbench.ll). `fn_renumber_blocks` in domtree.jai; nothing else renumbers IR blocks.
  - **ExprValueMap order** (fixed, linpack-pc.ll): SCEV keeps every value with the same SCEV in insertion order and
    SCEVExpander reuses the first dominating one. get_pointers_diff created getSCEV(PtrB) before getSCEV(PtrA)
    (`f(scev(b), scev(a))`); LLVM creates A first. Found by tracing createSCEV in LLVM with gdb against
    `-jai-trace-create-scev` (knowledge/llvm/scalar-evolution.md, "Creation order matters downstream").
- DependenceAnalysis is a per-query object (`da_new`): LoopInterchange builds one per run, `print<da>` one per
  function. `Da_Dependence` is one struct for Dependence and FullDependence (`confused`). Loop levels are u64 masks
  (more than 62 levels fails loudly). `findArrayDimensions` sorts terms by SCEV pointer in LLVM; we use Scev_Id
  (creation order); the following llvm::sort is stable up to 16 terms and fails loudly above.
- LoopInterchange: the LoopNest pass runs only when the LPM starts on a top-level loop; after an interchange the
  current loop is the new inner loop and the rest of the LPM runs on it (LLVM does the same). `cache` profitability:
  `loop_cache_analysis.jai` (LoopCacheAnalysis.cpp, also `print<loop-cache-cost>`; jai_tails 2026-11), computed lazily
  once per nest in `Li_Ctx.cc` like CacheCostManager. Its own saturating fixed-point `Lc_Cost` (tti.jai's `Cost` is
  unscaled). Sweeps: print<loop-cache-cost> 10860/10860 (also with -cache-line-size=64), --with-test-flags 13519
  identical / 0 differs; loop-interchange with `-loop-interchange-profitabilities=cache,instorder,vectorize` (with and
  without -cache-line-size=64) 10860/10860. -loop-interchange-reduction-to-mem is ported. `is_constant` is a Jai builtin
  (compile-time constness), not isa<Constant>: use `is_const`.
- L2.pipeline-O2 and L2.perf-corpus are COMPLETE (2026-11-13). oggenc's mergeConditionalStores and sqlite3's SLP
  external store groups were hash-order spots that provably (resp. checked by permutation) cannot change LLVM's
  output; see knowledge/llvm/simplifycfg.md and vectorizers.md. L1.o2-gaps COMPLETE 380/380 (2026-11, the `cache` rule).
- More pipeline-state fixes (each found with bisect + standalone rerun): the inliner's PHI trimming follows
  removeIncomingValueIf (backwards, last into the hole); LICM's call clones take the original name first (one
  LastUnique bump); CommonPointerBase's NW flags default to all(); ExpandMemCmp ported (pass_expand_memcmp.jai,
  X86 options; it finds memcmp/bcmp without an availability check). knowledge/llvm/dependence-and-interchange.md.
- -O2 compile time, optimized build (user s, jai vs LLVM): SPASS 8.2 vs 5.0, lua 2.3 vs 1.2, sqlite3 (up to the
  SLP failure) 5.3 vs 3.5, scaling/calls/n8000 10.0 vs 5.1, scaling/diamonds/n8000 9.3 vs 1.3 (SLP).
- Perf: tests/perf/scaling/calls/n8000 -O2 takes ~115-130 s on the x64 build (harness limit 120 s; LLVM 4.8 s):
  the inliner's cost analysis (46k CallAnalyzer runs on n500, the same count as LLVM) and instcombine's known-bits
  queries, i.e. the x64 backend's per-call overhead on small helpers (no single hotspot). Inlining the hottest
  helpers (`const_ap`, `type_bits`, `scalar_type`, attribute lookups, `call_*`), a word-wise
  `tli_are_inline_compatible` and a hashed libfunc name set cut callgrind Ir on n500 by 18%.

## llvm-link, LTO pipelines, MergeFunctions (L2.link COMPLETE 574/574, L2.lto COMPLETE 144/144, L2.lto-passes COMPLETE 160/160, L2.phase-ordering 285/288)

- Files: `linker.jai` (llvm-link: llvm-link.cpp's main/linkFiles, ModuleLinker, IRMover/IRLinker, TypeMapTy,
  IdentifiedStructTypeSet and the IRMover half of ValueMapper), `llvm_link_main` (opt's program called as llvm-link), `pass_builder_pipelines.jai` (the four LTO aliases at O0-O3 next to `default<O#>`; the phase is the
  global `pb_phase`), `pass_lto_misc.jai` (the LTO pipelines' module passes, pgo-force-function-attrs with
  `-pgo-kind` / `-pgo-cold-func-opt`), `pass_merge_functions.jai` (MergeFunctions, FunctionComparator,
  StructuralHash, xxh3_64bits), `pass_misc_module.jai` (`-force-attribute` / `-force-remove-attribute`).
- Design (DESIGN.md "llvm-link"): one world = one LLVMContext. While linking, the composite's module state is in `ir`
  and the source module's in a `Module_State` (`lk_swap_module` exchanges them; parsing a file swaps the composite
  out). `lk.owner` (by global row) says which module a global belongs to (IRLinker::materialize needs
  `SGV->getParent()`). Function bodies are moved: the new function takes the old one's argument rows
  (`arg_parents`), blocks and local symbol table, then the linker's mapper rewrites operands and types in place.
- The parser now keeps LLParser's per-module `NamedTypes` in `P.named_types`; `ir.named_types` is the context's
  table (`ctx_set_struct_name`, with `ir.named_struct_uid`). Only parser-created and linker-created structs are
  registered there; a pass that creates a named struct with `type_named_struct` would not be uniqued.
- llvm-link fails loudly on: `-override`, `-import`, ARM/AArch64 module attributes (copyModuleAttrToFunctions),
  two-field `llvm.global_ctors`, blockaddress of a function whose body is not linked yet (DelayedBBs), intrinsics
  whose name mangles a struct type (remangleIntrinsicFunction), uniqued metadata cycles that change, inline asm whose
  type changes.
- The LTO module passes expand-variadics and pgo-icall-prom are ported up to their early exits and fail loudly on
  variadic / value-profile input; drop-type-tests, canonicalize-aliases and name-anon-globals are complete. The CFI
  passes are complete (section "CFI" below).
- MergeFunctions' FnTree is a list searched for an equal node (only equality decides merges; see
  knowledge/llvm/linker-and-lto.md). Its Deferred WeakTrackingVHs follow RAUW through `mf.fwd`.
- `verify` is now also a module pass name (`verify,forceattrs` is a module pipeline, as in LLVM); before, such a
  pipeline was wrapped into one function adaptor.
- Key-instruction atom groups (clang -g emits them): `ir.next_atom_group` is the context's NextAtomGroup (raised
  by every new DILocation, debuginfo.jai `di_get`), `Value_Map.atoms` is ValueToValueMapTy::AtomMap,
  `atom_map_instance` / `atom_remap_source` are mapAtomInstance / RemapSourceAtom. Wired into loop-rotate, full /
  partial unrolling (`clone_basic_block(..., map_atoms = true)` plus the explicit remap) and remap_instruction; the
  other cloners (peeling, runtime unrolling, unswitch, loop versioning, DFA jump threading, function
  specialization, CodeGenPrepare, jump-threading, SimplifyCFG's foldBranchToCommonDest) still fail loudly on an atom
  group until each is checked against where LLVM remaps.
- Remaining: phase-ordering: knowledge retention in loop passes,
  ptrauth protected.field.ptr, LoopVectorize convertToStridedAccesses (preserve-access-group).

## llc's IR pipeline (L1.isel-ir-O0 COMPLETE; L1.codegen-ir COMPLETE)

- `bin/llc` is the opt binary under another name (`main` calls `llc_main` when argv[0] is llc). `codegen_pipeline.jai` builds TargetPassConfig's IR pass list (`Cg_Pass`, `cg_build_pipeline`) and
  runs it with the legacy FPM ordering (`cg_run_pipeline`); llc's and CodeGenPrepare's cl::opts are parsed by
  `cg_parse_cl_opt` (also reachable from opt). Every codegen IR pass also has its opt `-passes=` name
  (codegenprepare, consthoist, partially-inline-libcalls, expand-reductions, unreachableblockelim,
  pre-isel-intrinsic-lowering, atomic-expand, loop-reduce, canon-freeze, loop-term-fold). `atomic-expand` and the
  real pipeline need `require<libcall-lowering-info>` first (a no-op that only marks the module analysis cached).
- Files: `cgp_*.jai` + `bypass_slow_division.jai` (CodeGenPrepare), `pass_consthoist.jai`,
  `pass_partially_inline_libcalls.jai`, `lsr_core.jai` / `lsr_instance.jai` / `lsr_chains.jai` / `lsr_generate.jai` /
  `lsr_rewrite.jai` (LoopStrengthReduce, split in LLVM's source order), `pass_canon_freeze.jai`,
  `pass_loop_term_fold.jai`, `cg_interleaved_access.jai`, `cg_x86_partial_reduction.jai`, `cg_lowering_passes.jai`
  (PreISelIntrinsicLowering, the idempotent-RMW fenced load, ExpandIRInsts guard), `atomic_expand.jai`
  (AtomicExpand), `lower_mem_intrinsics.jai` (LowerMemIntrinsics' unknown-size and memset.pattern loops),
  `vp_expand.jai` + generated `gen_vp.jai` (ExpandVectorPredication; `gen/gen_vp.py` reads VPIntrinsics.def),
  `cg_misc_passes.jai` (UnreachableBlockElim and passes that are no-ops for our inputs, each guarded),
  `cg_todo_passes.jai` (what is left: ScalarizeMaskedMemIntrin as a no-op).
- Guards: a pass that is not fully ported fails loudly exactly where LLVM would change the IR (e.g.
  `interleaved-access: X86 lowering of an interleaved load ...` only for AVX factor-3/4 groups). Grep for
  `is not supported yet` in those files for the list.
- LSR state lives in the global `lsr` (one LSRInstance at a time); formulae are value types (`lf_copy` deep-copies
  BaseRegs). Never keep a `*Lsr_Use` / `*Lsr_Formula` across an insertion into the same array. `JAI_LSR_DEBUG=1`
  prints LLVM-style use/formula lists after each phase, the cross-use work items, the baseline cost and the chosen
  solution (LLVM's release build has no -debug-only, so compare by reasoning from these lists).
- Jai traps met here: `defer x += 1` inside a `while` body also runs on `break`; `cast(T) a >> b` parses as
  `cast(T)(a >> b)` (parenthesise the cast); a named `for` iterator still makes the inner loop's `it_index` shadow
  the outer one inside the inner loop.
- ExpandMemCmp (`pass_expand_memcmp.jai`) was ported under L2.pipeline-O2 (two of us ported it the same day; the
  rebase kept that version).
- CodeGenPrepare with a profile summary: `cgp_should_optimize_for_size` / `cgp_bfi` use the function's BFI as first
  computed; LLVM updates its BFI incrementally (setBlockFreq in dupRetToEnableTailCallOpts / select-to-branch), which
  we do not mirror: a profiled function whose CFG CGP changed before a later size query could differ.
- Not ported (fail loudly): LSR's SCEV-based debug-value salvage (5 imported files hit it), vscale steps, landing-pad
  predecessor splitting in RewriteForPHI; VP expansion of constrained-FP VP intrinsics; AtomicExpand's x86
  bit-test / compare-arithmetic RMW intrinsics (`llvm.x86.atomic.bt*`, `*.cc`), Windows' i128 libcalls.
- AtomicExpand: ReplacementIRBuilder is an InstSimplifyFolder builder (`ae_binop`/`ae_cast`/... fold through
  InstSimplify: `atomicrmw fsub x, 0.0` builds no `fsub`), and its inserter tags every new instruction with the
  replaced one's `!pcsections` / `!mmra` (`ae_md_begin`/`ae_md_end` use the monotonic Value_Id watermark). The
  libcall paths use a plain IRBuilder (no folding beyond constants, no metadata). x86's
  `shouldIssueAtomicLoadForAtomicEmulationLoop` is false: the loop's initial load is non-atomic.
- PreISelIntrinsicLowering: x86 uses the default TTI VP legalization (EVL discard, op convert); LowerMemIntrinsics'
  loop type is always i8 on x86 (no getMemcpyLoopLoweringType override), so only the unknown-size / pattern paths
  were needed.
- Sweeps (atomic-expand with `-mtriple=x86_64-linux-gnu`, with `-mattr=+cx16`, and `--with-test-flags`;
  pre-isel-intrinsic-lowering; codegenprepare): 0 differs. CGP's llvm.objectsize / is.constant are llvm_unreachable
  in LLVM (UB in a release build) and fail loudly here.
- Sweeps (`./harness/run sweep --impl jai --passes loop-reduce`, with and without `--extra=-mtriple=x86_64-unknown-linux-gnu`):
  8048-8073 of 8079 identical, 0 silent mismatches; the loud failures are the items above.

## Sweep-up of L0-L2 remainders (2026-11-13, /root/jai_sweepup)

- New files: `analysis_printers_misc.jai` (print<assumptions>, print-callgraph-sccs, print<phi-values>,
  print<mem-derefs>, print<must-execute> with SimpleLoopSafetyInfo, print-must-be-executed-contexts using
  attributor.jai's explorer with a fresh `atr`), `ic_ptrauth.jai` (ptrauth intrinsics and callees, trampolines,
  gc.statepoint, `ic_call_with_bundles` = CallBase::Create(CB, Bundles)), `pass_make_guards_explicit.jai`.
  The printer has a third annotation hook, `print_annot_info` (printInfoComment).
- **AssumptionCache is lazily scanned** like LLVM's (ac_scan on the first query; registration before that is a
  no-op). Code must read `ac_assumptions(ac)` / `ac_assumptions_for`, never `ac.assumes` before a scan.
- InstCombine's cached AAResults (`ic_aar_state`) is reset at every run: it used to keep the DT/AC pointers of an
  earlier run on the same function (freed meanwhile; the lazy AC turned that into heap corruption on lua.ll).
- PSI: `psi_pass_bfi(f)` gives a pass the (PSI, BFI) LLVM's passes take (BFI only with a module profile summary);
  used by loop-unroll, loop-load-elim, the LibCallSimplifier and LoopVectorize (processLoop's OptForSize =
  shouldOptimizeForSize(header, PSI, BFI); the FAM-cached BFI is then the one getPredBlockCostDivisor reads too).
  `default<O2>` on the 54 corpus files with a ProfileSummary: 46 identical, 0 differs, 6 loud (cg-profile value
  profiles; fixed since), 2 llvm-failed; `require<profile-summary>,function(loop-vectorize)` on them + Transforms/LoopVectorize:
  519/519 identical.
- `-enable-knowledge-retention` is honoured by dce, licm (and allowed for loop-simplify, lcssa, loop-rotate,
  instcombine, the loop adaptor, which never salvage).
- `-denormal-fp-math[-f32]` add `denormal_fpenv` to every function without one (opt_set_function_attributes, which
  now also runs for an unknown-arch triple, with CPU/features cleared).
- `-verify-scev-strict` is accepted: our verify<scalar-evolution> does not recompute (it could only abort).
- Also: `print_uselistorder.jai` (`--preserve-ll-uselistorder`: all directives, globals and constants included,
  identical over the corpus with plain `opt -S` (10118 files) and 0 new differs in instcombine/simplifycfg/sroa sweeps
  with the flag; this needed in-place constant updates in `constant_handle_operand_change`, end-of-module
  dso_local_equivalent placeholders and per-clause landingpad parsing, see knowledge/llvm/textual-ir.md), VP intrinsic costs (BasicTTI's VP
  branch in tti_intrinsics.jai), optimizeModularFormat, x86 auto-upgrades for movnt/storeu/blend/kunpck/vpdp*,
  x87 pseudo-infinities and unnormals decode as NaN (they printed as an endless loop before).
- `harness check --no-build` after a manual `build.sh` can report stale results; run `check` (it builds) when in
  doubt.
- Still failing loudly (my units): SROA with
  scalable vectors and a known vscale (canConvertValue/convertValue/isVectorPromotionViable with VScale),
  LowerTypeTests CFI lowering, LoopCacheAnalysis (loop-interchange `cache`).
- Sweeps after these changes (0 differs everywhere): instcombine 8538/8550 identical (12 loud), instcombine
  --with-test-flags 10868/10927 (59 loud), simplifycfg, loop-rotate, make-guards-explicit, function(loop-mssa(licm)),
  dce/licm with --enable-knowledge-retention all 100%, slp-vectorizer --with-test-flags 10926/10982 (56 loud).

## Whole-corpus sweeps, 2026-11-25 (/root/jai_silentfix)

Every file whose `::roundtrip` passes (10817, tests/perf left out), plain and `--with-test-flags` (13633 runs);
the remaining count to the totals is `llvm-failed` (LLVM's opt fails with those arguments). `failed` with test flags
is almost all `unsupported option` for pass cl::opts we don't implement (-sbvec-*, -whole-program-visibility,
-irce-*, -dfsan-*, ...). Each row is `./harness/run sweep --impl jai --passes <p> [--with-test-flags]`.

| pass | plain: identical / differs / bad-ir / failed | --with-test-flags: identical / differs / bad-ir / failed |
| --- | --- | --- |
| `instsimplify` | 10816 / 0 / 0 / 1 | 13126 / 0 / 0 / 507 |
| `instcombine` | 10754 / 0 / 0 / 1 | 13076 / 0 / 0 / 491 |
| `simplifycfg` | 10817 / 0 / 0 / 0 | 13127 / 0 / 0 / 506 |
| `sroa` | 10809 / 0 / 0 / 8 | 13116 / 0 / 0 / 517 |
| `early-cse<memssa>` | 10816 / 0 / 0 / 1 | 13140 / 0 / 0 / 493 |
| `gvn` | 10816 / 0 / 0 / 1 | 13126 / 0 / 0 / 507 |
| `newgvn` | 10799 / 0 / 0 / 13 | 13123 / 0 / 0 / 505 |
| `sccp` | 10817 / 0 / 0 / 0 | 13141 / 0 / 0 / 492 |
| `ipsccp` | 10815 / 0 / 0 / 0 | 13138 / 0 / 0 / 492 |
| `licm` | 10817 / 0 / 0 / 0 | 13141 / 0 / 0 / 492 |
| `loop-rotate` | 10817 / 0 / 0 / 0 | 13141 / 0 / 0 / 492 |
| `indvars` | 10816 / 0 / 0 / 0 | 13135 / 0 / 0 / 496 |
| `loop-unroll` | 10816 / 0 / 0 / 1 | 13126 / 0 / 0 / 507 |
| `simple-loop-unswitch<nontrivial>` | 10816 / 0 / 0 / 0 | 13136 / 0 / 0 / 496 |
| `dse` | 10817 / 0 / 0 / 0 | 13141 / 0 / 0 / 492 |
| `memcpyopt` | 10817 / 0 / 0 / 0 | 13127 / 0 / 0 / 506 |
| `jump-threading` | 10816 / 0 / 0 / 0 | 13126 / 0 / 0 / 506 |
| `correlated-propagation` | 10816 / 0 / 0 / 0 | 13126 / 0 / 0 / 506 |
| `reassociate` | 10817 / 0 / 0 / 0 | 13127 / 0 / 0 / 506 |
| `inline` | 10804 / 0 / 0 / 13 | 13118 / 0 / 0 / 515 |
| `cgscc(function-attrs)` | 10817 / 0 / 0 / 0 | 13127 / 0 / 0 / 506 |
| `globalopt` | 10814 / 0 / 0 / 0 | 13138 / 0 / 0 / 492 |
| `loop-vectorize` | 10817 / 0 / 0 / 0 | 13126 / 0 / 0 / 507 |
| `slp-vectorizer` | 10816 / 0 / 0 / 1 | 13127 / 0 / 0 / 506 |
| `default<O2>` | 10721 / 0 / 0 / 87 | 13016 / 0 / 0 / 599 |

- The silent mismatches reported before this task (instcombine on GlobalSplit inrange GEPs and DataFlowSanitizer,
  sroa on SampleProfile and tests/lto/ipo/debug_info) were already fixed on main (f73aa02b and the dfsan work);
  this sweep found no differs/bad-ir in any of the 25 pipelines, before or after.
- `default<O2>` crashed on 4 files (loud, 91 -> 87 failed), all fixed with tests in `tests/pass/`:
  MemCpyOpt's merged memset length `End-Start` and SLP's `static_cast<uint64_t>(Dist)` must wrap like LLVM's int64
  arithmetic (Jai's checked `cast(u64)` of a negative s64 panics: use `cast,no_check`); `tti_instruction_cost` pads
  a constant expression's operand list to 3 entries, so the GEP case must only pass the GEP's own `nops` indices; and
  attribute intersection (SimplifyCFG hoist/sink) must drop `nofpclass` when the AND of the masks is 0 (LLVM's
  `addNoFPClassAttr(fcNone)` adds nothing; we printed `nofpclass(none)`, which the verifier rejects).
- Loud, not bugs: ScalarEvolution/avoid-assume-hang.ll under O2 (LLVM 15 s, our x64 build > 60 s CPU) and
  LoopUnroll/pr77842.ll under loop-unroll (LLVM 5 s, us 73 s; see Performance) time out in the sweep's 60 s limit.

## NewGVN (L1.extra.newgvn COMPLETE 296/296; /root/jai_newgvn)

- One file, `pass_newgvn.jai` (NewGVN.cpp + GVNExpression.h + VNCoercion's getConstantValueForLoad /
  getConstantMemInstValueForLoad). Expressions are `Ng_Expr` rows (`et` = the GVNExpression class), congruence classes
  `Ng_Class` rows, the expression-keyed DenseMaps are `Ng_Emap` (hash chains; equality = DenseMapInfo::isEqual, exact
  equality for the `find_as(ExactEqualsExpression)` erasures). The global `ng` is the NewGVN object of the running pass.
  Facts that decide output: knowledge/llvm/newgvn.md.
- `-newgvn-trace` (ours, not an LLVM flag) prints "Processing instruction" and each class move to stderr, to diff
  against the assertions build's `-debug-only=newgvn`.
- TarjanSCC is iterative (same visiting order as the recursive FindSCC).
- `-enable-newgvn` now selects NewGVN in default<O*> and the LTO pipeline. `-enable-knowledge-retention` is allowed
  with newgvn (salvageKnowledge(I, AC) in deleteInstructionsInBlock).
- Regenerated gen_intrinsics.jai (commute.ll needs llvm.sdiv.fix; 400 roundtrips of other directories came with it).
- Sweeps: `newgvn` 10448/10452 identical, 1 differs (SCCP/pr27712.ll: an equality of two different constants on a
  dead edge is ordered by heap address in LLVM; see knowledge), 3 loud (ppc_fp128, x86 hadd known bits);
  `--per-function` 80898/80918, 2 differs (pr27712 and InstCombine/assume.ll @debug_interference, same cause);
  since the address-order policy (section above) these fail loudly: `newgvn` 10789/10804 identical, 0 differs,
  12 loud on the address order (`-newgvn-guess-address-order` restores the old guess);
  `--with-test-flags` 12044/13234, 0 differs (loud = other passes' options); `-enable-store-refinement`,
  `-enable-phi-of-ops=false`: same as plain; tests/perf/compile `newgvn`, `function(sroa),newgvn` and
  `default<O2> -enable-newgvn` 4/4 identical.
- Perf (x64 build, `-passes=newgvn -disable-output`): sqlite3.ll 3.9 s (LLVM 0.49 s; parse 0.7 s); diamonds
  n2000/n8000 0.27/1.10 s (LLVM 0.08/0.27); loops-many n2000/n8000 0.81/16.2 s (LLVM 0.10/1.30). loops-many is
  quadratic in LLVM too (k ~1.9; ours ~2.2): the time is the number of re-evaluations of the touched instructions
  (InstSimplify of the re-numbered adds, hash lookups); no tests/perf benchmark times newgvn.

## GVNHoist, GVNSink (L1.extra.gvn-hoist-sink COMPLETE 106/106; /root/jai_newgvn)

- `pass_gvn_hoist.jai` (GVNHoist.cpp; uses pass_gvn.jai's ValueTable through a `Gvn` with only DT / AA / MemDep set,
  memdep.jai, mssa_updater.jai, the post-dominator IDF), `pass_gvn_sink.jai` (GVNSink.cpp + LockstepReverseIterator.h).
  `-enable-gvn-hoist` / `-enable-gvn-sink` are supported in default<O*>. Facts: knowledge/llvm/gvn-hoist-sink.md.
- gvn-sink fails loudly ("depend on the address order of their users") when two candidates have the same users as a
  multiset but LLVM would compare their value numbers in user-address order; `-gvn-sink-guess-address-order` (our
  flag, not LLVM's) uses creation order instead (right on 18/27 corpus files, wrong after default<O2> on
  tests/perf/compile). A decision is only flagged if the chosen candidate includes the ambiguous step.
- Sweeps: `gvn-hoist` 10803/10803 identical; `gvn-sink` 10778/10802 (0 differs, 24 loud = the address order);
  `--per-function`: 2 differs each, both a parser/printer issue outside the passes (x86_fp80 `+snan(0x0)` from the
  per-function split reparses to `+snan(0x1)`, LLVM gives `0x2000000000000000`); `--with-test-flags` 0 differs;
  `function(sroa),gvn-hoist` on tests/perf/compile 4/4; `default<O2> -enable-gvn-hoist` 3/4 (SPASS.ll exceeds the
  60 s CPU limit: our x64-build default<O2> alone takes 53 s there, gvn-hoist adds ~3 s), `-enable-gvn-sink` 4 loud.
- Perf (x64 build): `function(sroa),gvn-hoist` on SPASS.ll 2.0 s vs sroa alone 1.7 s.

## The profile family (L1.extra.sample-profile, L1.extra.pgo.instr, L1.extra.pgo.instrprof, L1.extra.memprof)

- Options of all these passes are parsed in `profile_cl.jai` (`profile_parse_cl_opt`).
- `add-discriminators` (pass_add_discriminators.jai): complete, 12/12 tests; sweep 10809/10809 identical.
  `diloc_clone_with_base_discriminator` leaves pseudo-probe discriminators alone (LLVM 23).
  `-enable-fs-discriminator` fails loudly.
- `memprof` / `memprof-module` (pass_memprof.jai, MemProfInstrumentation.cpp): complete, 11/11 HeapProfiler tests;
  sweep `function(memprof),memprof-module` 10776/10783 identical (0 differs; loud: scalable masked accesses,
  `kcfi` module flag = setKCFIType/xxHash64 not ported), `--with-test-flags` 0 differs, tests/perf/compile 4/4.
  Both passes are RequiredPassInfoMixin (they run on optnone functions); so is add-discriminators.
- `module_utils.jai`: ModuleUtils.cpp (append_to_global_ctors/dtors, append_to_used / append_to_compiler_used,
  create_sanitizer_ctor_and_init_functions, declare_sanitizer_init_function), fn_create_with_default_attr,
  module_get_or_insert_global, mu_split_block_and_insert_if_then (no DTU). New globals use the DataLayout's
  default globals address space (`dl.globals_as`), like `new GlobalVariable(M, ...)`.
- Trap: `fn_add_fn_attr` with a string attribute goes through `attr_set_with`, which removes *every* string
  attribute (attr_set_remove by kind); use `fn_add_fn_str_attr` for string attributes.
- `instrprof` (pass_instrprof.jai, InstrProfiling.cpp; helpers of InstrProf.cpp in instrprof_common.jai): 19/19
  InstrProfiling tests (L1.extra.pgo.instrprof complete with PGOForceFunctionAttrs); sweep 10808/10808 identical,
  `--with-test-flags` 0 differs. Not ported (loud): GPU profile targets, -enable-vtable-value-profiling,
  -profile-correlate=binary. Counter promotion uses LoadAndStorePromoter's new `.INSTRPROF` hook kind.
- **New dependency: the system zlib** (`#system_library "libz.so.1"` in instrprof_common.jai). The PGO name blob
  (`__llvm_prf_nm`) is zlib-compressed at level 9 (compression::zlib::compress, BestSizeCompression); LLVM's opt
  links the same /usr/lib/x86_64-linux-gnu/libz.so.1 dynamically, so calling it gives byte-identical output.
  Porting deflate bit-exactly would be ~2000 lines of zlib, not LLVM code.

- `pgo-instr-gen` (pass_pgo_instr_gen.jai: PGOInstrumentation.cpp gen side, CFGMST.h, ValueProfileCollector,
  JamCRC, SplitIndirectBrCriticalEdges with IgnoreBlocksWithoutPHI=false and BPI/BFI updates, funclet bundles):
  sweep `pgo-instr-gen` and `pgo-instr-gen,instrprof` 10810/10811 identical. The one differ
  (SampleProfile/profile-correlation-irreducible-loops.ll) is a **BFI bug on irreducible loops** (block_freq.jai):
  `print<block-freq>` already differs there (b3/b8 masses), so the MST weights differ. Not ported (loud):
  ctx-instr-gen, vtable value profiling. `-pgo-block-coverage` is block_coverage_inference.jai (BlockSets are
  SmallSetVectors: insertion-ordered arrays); sweep `pgo-instr-gen -pgo-block-coverage` 10811/10811 identical.
  `-jai-debug-cfgmst` prints the MST edges (jai-only debugging aid).
- `pgo-icall-prom` (pass_pgo_icall_prom.jai: IndirectCallPromotion.cpp, IndirectCallPromotionAnalysis.cpp,
  InstrProfSymtab::create for functions; pgo::promoteIndirectCall and versionCallSite in call_promotion.jai):
  sweep `--with-test-flags` 0 differs. The symtab sorts by MD5 with an unstable llvm::sort: two *different*
  functions with one PGO-name MD5 fail loudly. In the pipelines the node's `in_lto` / `icp_sample_pgo` carry
  PGOIndirectCallPromotion(InLTO, SamplePGO). `-enable-vtable-profile-use` fails loudly when the module has type
  tests (computeVirtualCallSiteTypeInfoMap / vtable comparison are not ported).
- `chr` (pass_chr.jai, ControlHeightReduction.cpp; regions from region_info.jai): 8/8 tests. Not ported: the
  optimization remarks. The pass's DenseSets are only membership-tested, so no address-order dependence. The DT is
  only updated by SplitBlock (the clones are not in it, so `Region::contains` and `dominates` see them as LLVM does).
  Sweeps 0 differs: `require<profile-summary>,function(chr) -force-chr` (whole corpus and --with-test-flags), and
  `sample-profile,prof-inject,require<profile-summary>,function(chr)` with `-force-chr -chr-bias-threshold=0.5
  -profcheck-default-select-true-weight=1000 -profcheck-default-select-false-weight=1` (the sample profile only
  provides a ProfileSummary; this is what makes CHR fire on corpus files), also over tests/perf/compile.
- `ctx-instr-gen` (pass_pgo_instr_gen.jai, CTXPROF: the function itself as the name, llvm.instrprof.callsite, entry
  counter, no value profiling), `ctx-instr-lower` and `noinline-nonprevailing` (pass_ctx_prof_lowering.jai). The GUID
  must be assigned (assign-guid) or the lowering fails loudly (LLVM reads an empty optional). InstrProfCntrInstBase
  includes llvm.instrprof.value.profile (the lowering erases it).
- Instrumentation PGO pipelines: -pgo-kind=pgo-instr-gen-pipeline (pre-inliner = ModuleInlinerWrapperPass with its
  own InlineParams `inl_preinline`, addPGOInstrPasses, post-PGO loop rotation, instrprof with InstrProfOptions on the
  node: `ip_*`, InstrProfileOutput = `sp_file`), -O0 variant, -profile-context-root (ctx pipeline),
  -cspgo-kind=cspgo-instr-gen-pipeline (PGOInstrumentationGenCreateVar, CS gen + instrprof with UseBFIInPromotion
  after rpo-function-attrs / in the LTO pipeline). pgo-instr-use / cspgo-instr-use fail loudly (indexed profile
  reader not ported; the harness skips all `%t.profdata` tests).
- vtable value profiling (-enable-vtable-value-profiling: VTableProfilingPlugin, __profvt_ data, __llvm_prf_vnm) and
  ICP vtable comparison (-enable-vtable-profile-use; Dm_U64 emulates LLVM 23's SmallDenseMap<uint64_t> bucket order
  for updateVPtrValueProfiles).
- Sweeps (jai_pgo_rest): `-O2 -pgo-kind=pgo-instr-gen-pipeline` 10793/10833 identical, 3 differs; `-O2
  -profile-context-root=main` 3 differs; `ctx-instr-gen,assign-guid,ctx-instr-lower` and `pgo-instr-gen,instrprof
  -enable-vtable-value-profiling`: 1 differs (the BFI irreducible-loop bug); `pgo-icall-prom -enable-vtable-profile-use
  --with-test-flags` 0 differs; tests/perf/compile 0 differs. The remaining differs are analysis-state bugs outside
  this unit, all reproducible only in the pipeline (standalone the pass agrees):
  GVN/critical-edge-split-failure.ll (drop-unnecessary-assumes drops a peeled assume LLVM keeps: LLVM's
  AssumptionCache is never invalidated and the peeled clone is not registered; ours is rebuilt),
  IndVarSimplify/eliminate-comparison.ll (CVP: samesign missing, LVI/AC state), LoopVectorize/X86/
  illegal-parallel-loop-uniform-write.ll (a leftover SCEVExpander `add %m, -2`, cached SCEV state), LICM/assume.ll.
  Bugs found and fixed on the way: SROA's global `sroa_pending_dt_updates` kept a stale capacity into temporary storage
  reset by the CGSCC pass manager (corrupted DT updates); removeUnwindEdge did not unique the new catchswitch's name
  (LastUnique counter); hasNonDebugLocLoopMetadata on a DILocation used as !llvm.loop.
- Trap: a global `[..]` array with `allocator = temp` must be reset with `data = null; allocated = 0`, not just
  `count = 0`, at the start of each run: reset_temporary_storage between SCCs frees its buffer.
- `pgo-memop-opt` (pass_pgo_memop_opt.jai, PGOMemOPSizeOpt.cpp; setProfMetadata): 4/4 tests, sweep 0 differs.
  No DomTree updates (the function's analyses are invalidated instead).
- `prof-inject` / `prof-verify` (pass_prof_verify.jai, ProfileVerify.cpp): sweep `prof-inject` 0 differs.
  BPI probabilities all have the denominator 2^31, so the LCM/GCD weights are N / gcd(N...).
  LLVMContext::emitError is `ctx_emit_error`: prints `error: ...`, and opt exits 1 without output after the
  pipeline (NewPMDriver's HasErrors check) — reuse it for other passes that emitError.
- Sample profile loader (pass_sample_profile.jai, sample_prof*.jai, sample_profile_inference.jai,
  sample_profile_matcher.jai, pass_pseudo_probe.jai): text, raw binary, ext-binary (sections, zlib-compressed
  sections, MD5 / fixed-length MD5 name tables, function offset table + module-driven partial reading, function
  metadata, profile symbol list) and GCC (gcov V407) readers; profi; SampleProfileMatcher (anchors, Myers LCS,
  call-graph matching, staleness report / llvm.stats); SampleUse PGOOptions in default / thinlto-pre-link /
  thinlto pipelines. jai_pgo_rest added SampleContextTracker (sample_context_tracker.jai: the CS trie, children
  sorted by SampleContextFrame::getHashCode = libstdc++ _Hash_bytes; promote/merge of context trees; the CS
  ProfiledCallGraph and import walk; the matcher on CS profiles) and the ReplayInlineAdvisor
  (-sample-profile-inline-replay*, `spl_replay`): 89/91 opt. Differential check of every LLVM SampleProfile RUN line
  that does not need lit substitutions: 128/132 identical, 4 loud. Sweeps `sample-profile` with a CS profile and
  `thinlto-pre-link<O2>` SampleUse with csspgo-import-list.prof: 0 differs. Not ported (loud):
  the Itanium remapper (needs ItaniumManglingCanonicalizer), the Itanium demangler of the matcher (a mangled
  name reaching getDemangledBaseName fails loudly; C names never parse as function encodings), SampleUse in the
  O0 and full-LTO pipelines, print-profile-summary, remarks.
  - Address-order policy: the SymbolMap is built from the value symbol table (a StringMap, hash order); when a
    function's stripped name (`getCanonicalFnName(F)` with no suffix-elision attribute strips at the first '.')
    is also another function's name, the entry ends up as that function or nullptr depending on the order. Such
    keys go to `spl.symbol_order_dependent`, and `spl_symbol_lookup` of one fails loudly (eagerly failing made
    ~60 corpus files fail for nothing).
  - Text-format profiles have no partial reading: SampleProfileReader::read(FuncsToUse) returns not_implemented,
    which makes functionMatchesProfileHelper give up (`spm_reader_read`).
  - Jai trap: `a << 56 | b << 48` needs parentheses (sp_magic compared wrong, every binary profile was
    "Unrecognized"). And `cast(float32) u64` of a value >= 2^63 is wrong: use `u64_to_f32`.
  - Sweeps (whole corpus; few functions have `use-sample-profile`, so they mostly exercise the early exits):
    `sample-profile -sample-profile-file=Inputs/inline.prof`, `pseudo-probe,sample-profile` with a probe profile,
    `pseudo-probe --with-test-flags`: 0 differs. `default<O2>` and `thinlto-pre-link<O2>` with
    `-pgo-kind=pgo-sample-use-pipeline -profile-file=Inputs/inline.prof`: 0 differs (the one thinlto-pre-link
    differ was dfa-jump-threading: SSAUpdaterBulk's phis take the frontier block's first debug location; only
    visible without full unrolling). The printed SampleUse pipelines equal LLVM's (`-jai-print-pipeline`).
  - SampleUse implies `DebugInfoForProfiling` (PGOOptions constructor): `function(add-discriminators)` after
    forceattrs in the per-module and ThinLTO pre-link pipelines.
- Jai trap: an untyped constant `0xFFFF_FFFF_FFFF_FFFF :: ` is an s64 -1 in arithmetic (`X / 1000` = 0); give
  such constants an explicit `: u64 :` type.

## Sanitizers (L1.extra.sanitizers.*; jai_sanitizers, 2026-11)

- Files: `sanitizer_common.jai` (ModuleUtils.cpp / Instrumentation.cpp helpers, Function::createWithDefaultAttr,
  setKCFIType + KCFIHash, SplitBlockAndInsertIfThen/Else without DTU (`sbi_if_then`, `sbi_if_then_else`),
  SplitBlockAndInsertSimpleForLoop, ASanStackFrameLayout, replaceDbgDeclare, maybeMarkSanitizerLibraryCallNoBuiltin,
  `San_Callee` = FunctionCallee + `san_call`, `irb_alloca`, `irb_pointer_cast`, `san_takes_value` for `-opt value`
  options), `demangle.jai` (llvm::demangle subset), `stack_safety.jai` (StackSafetyGlobalInfo + StackLifetime Must),
  `pass_asan.jai`.
- **asan** (L1.extra.sanitizers.asan): complete (all 93 opt checks). `win-eh-prepare` (pass_win_eh_prepare.jai, the IR
  part of CodeGen/WinEHPrepare.cpp; no EH state numbering) and `require<basic-aa>` were the last two; CodeGen/WinEH's
  6 opt tests are imported and identical, `win-eh-prepare` sweeps 0 differs (plain, --with-test-flags,
  -disable-cleanups). cloneCommonBlocks walks its ValueToValueMapTy in pointer order: when SSAUpdater PHIs are made
  for two cloned values (named, or in one block) we fail loudly. Sweeps, 0 differs / 0 bad-ir: `asan` whole
  corpus; `forceattrs,asan -force-attribute=sanitize_address` (instruments every function: the real test of the
  function pass) plain, --with-test-flags, with -asan-use-after-scope/-asan-use-stack-safety=0, with
  -asan-instrumentation-with-call-threshold=0/-asan-use-after-return=always/-asan-stack-dynamic-alloca=0, with
  -asan-use-after-return=never/-asan-recover/-asan-detect-invalid-pointer-pair/-asan-max-inline-poisoning-size=0, and
  `forceattrs,sroa,asan` on tests/perf/compile. Loud leftovers: Itanium templates/substitutions and MSVC names other
  than plain variables and string literals in the demangler, a static alloca whose size overflows u64 (LLVM
  dereferences an empty optional: UB), StackSafety on pointers whose index width differs from their size.
- Traps found: `new GlobalVariable(M, ...)` without an address space uses the DataLayout's default globals address
  space (`dl.globals_as`), not 0; `ConstantExpr::getPointerCast` addrspacecasts (`san_ce_pointer_cast`); the stack
  shadow constants depend on endianness; every RAUW of an instruction/argument updates debug records (now done by
  `replace_all_uses_with` itself); `moveBefore` is `inst_move_before_dbg`; BasicBlock::splitBasicBlock gives the new branch the split
  point's location **without its atom group** (fixed in ir_edit.jai `split_basic_block`, affects every pass);
  StackSafety's getInfo is lazy (computed on the first isSafe query, on the IR at that moment).
- Intrinsics LLVM knows but gen_iit.jai does not (llvm.amdgcn.is.shared/private, declared by every asan run) get
  their attributes from `san_set_foreign_intrinsic_attributes` and no "; Unknown intrinsic" comment
  (`san_is_foreign_known_intrinsic`, printer.jai); `san_intrinsic_with_attrs` declares an intrinsic that has no
  gen_intrinsics.jai entry (llvm.asan.check.memaccess).
- Perf (x64 build, sqlite3 with forceattrs,sroa,asan): +1.1 s over forceattrs,sroa (LLVM's whole run: 0.5 s); no
  @perf benchmark times asan.
- **msan** (L1.extra.sanitizers.msan): `pass_msan.jai` (MemorySanitizer + the visitor in one `Msan` per function,
  VarArgAMD64Helper as `Msan_Va`), `msan_intrinsics.jai` (all cross-platform and x86 handlers),
  `gen_msan_switch.jai` (GENERATED by `gen/gen_msan_switch.py` from MemorySanitizer.cpp's two intrinsic switches:
  rerun it after an LLVM update; unknown handler statements stop the script). All 113 + 40 RUN lines of
  MemorySanitizer/ and MemorySanitizer/X86/ identical. Sweeps, 0 differs / 0 bad-ir: `msan` (whole corpus, with and
  without -mtriple=x86_64-unknown-linux-gnu: without a Linux/FreeBSD/NetBSD triple LLVM's msan aborts),
  `forceattrs,msan -force-attribute=sanitize_memory` plain, with -msan-track-origins=2, -msan-kernel=1, with
  call threshold 0 + origins + eager checks + poison-undef-vectors + precise-disjoint-or, --with-test-flags, and
  `forceattrs,sroa,msan` / `forceattrs,sroa,asan,msan` on tests/perf/compile. Not ported (fail loudly): the ARM SIMD
  handlers (maybeHandleArmSIMDIntrinsic, NEON/SVE) and the vararg helpers of other targets.
- msan traps: an `invoke` of an intrinsic is a plain CallBase (InstVisitor only dispatches CallInst to
  visitIntrinsicInst); `CreateAlloca(Ty, 0u)` is address space 0, not an array size; Value::setName on a folded
  constant is a no-op; `IRBuilder::CreateExtractElement/InsertElement` on constants makes constant expressions
  (`ce_*`, not `cf_*`); the shuffle mask / extractvalue indices live in `ir.u32_pool`, which every new shuffle grows,
  so copy them before building; doesNotAccessMemory of a call counts operand bundles (`call_memory_effects`);
  `PA.abandon<GlobalsAA>()` is `Preserved.abandon_globals_aa` (passes.jai, mam_invalidate drops the cached
  GlobalsAA).
- **tsan / tsan-module / rtsan** (L1.extra.sanitizers.tsan-misc): `pass_tsan.jai` (ThreadSanitizer,
  EscapeEnumerator, RealtimeSanitizer). All 29 ThreadSanitizer and 4 RealtimeSanitizer RUN lines identical. Sweeps
  0 differs: `tsan-module,function(tsan)`, the same after `forceattrs -force-attribute=sanitize_thread`, with
  -tsan-distinguish-volatile -tsan-compound-read-before-write -tsan-omit-by-pointer-capturing=0, and `forceattrs,rtsan`
  with sanitize_realtime / sanitize_realtime_blocking (107 loud: C++ names beyond the demangler subset). Every
  sanitizer pass is a RequiredPassInfoMixin (`required` = true in PASS_TABLE: they run on optnone functions);
  EscapeEnumerator's default personality is __gcc_personality_v0 (__gxx_personality_v0 only on PS5);
  CreateGlobalString aligns to the preferred alignment of i8 in address space 0.
- **tysan** (`pass_tysan.jai`): all 28 TypeSanitizer RUN lines identical; sweeps 0 differs: `tysan`,
  `forceattrs,tysan -force-attribute=sanitize_type` with -tysan-outline-instrumentation=0 (the inline checks),
  -tysan-writes-always-set-type, -tysan-verify-outlined-instrumentation. Traps: MemIntrinsic::getDest/getSource
  strip pointer casts; `SetInstDebugLocation(AI)` after moving the builder puts the *next* instruction's !dbg on the
  alloca; PtrShift is countr_zero(pointer bytes) (0 for 40-bit pointers); `Hash.update("\0")` hashes nothing.
- **nsan** (`pass_nsan.jai`, NumericalStabilitySanitizer): all 12 RUN lines identical; sweeps 0 differs:
  `forceattrs,nsan -force-attribute=sanitize_numerical_stability` plain and --with-test-flags over every file.
  Traps: moveFastMathFlags ORs the flags in (`setFastMathFlags` is `|=`); a splat FP vector constant is one C_FP of
  vector type (convert the scalar words); a scalable non-FT store uses the known-minimum store size (LLVM release).
  -check-functions-filter (a Regex) fails loudly.
- **sancov-module** (`pass_sancov.jai`, SanitizerCoverage + PrepareToSplitEntryBlock): all 59 SanitizerCoverage RUN
  lines identical; sweeps 0 differs / 0 bad-ir / 0 failed over the corpus with level 3 + trace-compares/divs/geps +
  pc-table + control-flow, level 4 + 8-bit counters + bool flags + stack-depth + loads/stores + entry-exit, level 2 +
  gated callbacks + stack-depth-callback-min, level 1 + no pruning on x86_64-windows-msvc. Traps: `Align(n)` of a
  store size that is not a power of two (40-bit pointers) is 1 << Log2(n) in a release build; CreateLoad/Store
  without an alignment use the ABI alignment (i1 can be 4); isa<IntrinsicInst> is any callee named llvm.*
  (an unknown `llvm.convergent` too); SplitAllCriticalEdges' IgnoreUnreachableDests is now in pass_dce.jai.
  With inline-bool-flag + stack-depth together LLVM's IRBuilder keeps inserting into the split-off head block
  (LLVM's opt crashes on most files: llvm-failed in the sweep).
- **sanmd-module** (`pass_sanmd.jai`, SanitizerBinaryMetadata): all 4 RUN lines identical; sweeps 0 differs with
  atomics+uar and covered+uar+weak-callbacks=0+nosanitize-attr=0.
- **jmc-instrumenter** (`pass_jmc.jai`, CodeGen/JMCInstrumenter.cpp; `sys_path.jai` = the sys::path subset it needs:
  posix and windows_backslash styles): both RUN lines identical; sweeps 0 differs on x86_64-linux, x86_64-msvc and
  i686-msvc (fastcall). Trap (fixed in 4 places): `ir.md_ops[ir.mds[n].ops + k] = md_tuple(...)` takes the address
  before md_tuple grows `ir.md_ops`; the write lands in the freed buffer. Build the node into a local first.
- **hwasan** (`pass_hwasan.jai`: HWAddressSanitizer + memtag:: MemoryTaggingSupport + CFG.cpp isReachableImpl with
  LoopInfo and exclusion sets; `san_inline_asm` makes InlineAsm values): all 30 RUN lines of HWAddressSanitizer/ and
  X86/ identical. Sweeps 0 differs / 0 bad-ir on x86_64-linux: `hwasan` whole corpus, `forceattrs,hwasan
  -force-attribute=sanitize_hwaddress` with callbacks (the x86-64 default), inline checks
  (-hwasan-instrument-with-calls=0), kernel+recover, page aliases, generate-tags-with-calls + libcall frame records +
  match-all-tag, ifunc/global shadow + no frame record + no use-after-scope + landing pads, no short granules +
  all-globals + tag-bits=5 (1 loud: StackSafety on pointers whose index width differs from their size).
  Not ported, loud: AArch64/RISC-V outlined checks and traps, Android/Darwin thread slots, -hwasan-random-rate.
  Traps: `ConstantInt::get(i32, ~(0x3F << 57))` keeps the high bits in a release build (no implicitTrunc), so the
  "-1" is not the canonical identity and `and %p, -1` stays an instruction (`hwasan_binop_wide_const`); for i128 it
  zero-extends. GlobalVariable::copyAttributesFrom does not copy the comdat. LLVM keeps DT/PDT/LoopInfo updated
  through a DomTreeUpdater; here every instrumented function's analyses are dropped (fam_invalidate) instead.
- **dfsan** (L1.extra.sanitizers.dfsan, complete: 45/45 opt): `pass_dfsan.jai` (DataFlowSanitizer = `Dfs`,
  DFSanFunction = `Dfsf`, the visitor is `dfsv_visit`), `special_case_list.jai` (SpecialCaseList + GlobPattern with
  brace expansion; the -dfsan-abilist files). Sweeps with `-mtriple=x86_64-unknown-linux-gnu` (LLVM's dfsan aborts
  without a Linux triple), 0 differs / 0 bad-ir: plain, --with-test-flags, track-origins=1, track-origins=2 + call
  threshold 0, debug-nonzero-labels + event + conditional callbacks, reaches-function callbacks + origins, the
  combine/gep/select/alignment flags, and ABI lists marking every function uninstrumented as custom / functional /
  discard+warning, and a mixed list (sections, `{a,b}`, `[!a-f]`, escapes, force_zero_labels), each with and without
  origins; tests/perf/compile with origins 4/4. Loud leftovers (LLVM is UB or prints unparsable IR there): origin
  loads on big-endian targets (a 32-bit shift by 32), shadow-mapping constants that don't fit a 32-bit intptr,
  extractvalue/insertvalue of an unsized aggregate (struct of mixed scalable vectors: shadow i8), wrapped calls whose
  arguments don't fit the wrapped function's type; SpecialCaseList v1 regexes beyond literal text and `*`.
- dfsan traps: LLVM 23's BlockAddress has only the block as operand, so `F.replaceUsesWithIf` does not touch
  blockaddress constants (ours have the function as an operand: skip them); `setCalledFunction(&F)` changes the
  call's function type but not its type (a call with another return type stays valid); a struct whose elements
  include scalable vectors of different types is unsized (`type_is_sized` fixed, constfold.jai); the
  DFSanFunction DominatorTree is exact during the visit (recalculated after storeOrigin's split and SplitEdge) but
  stale in the -dfsan-debug-nonzero-labels post-pass (new blocks are "unreachable": dominated by everything).
  Argument shadow loads are inserted before the entry's first instruction each time (so they appear in reverse).
- Perf (x64 build): sqlite3 with -dfsan-track-origins=1 takes 4.2 s (LLVM 0.8 s; parse+print alone 1.1 s); the
  DT recalculation after every conditional origin store is linear per store. No @perf benchmark times dfsan.
- **Next steps (sanitizers / instrumentation)**, by value:
  1. L1.extra.instrumentation.coverage leftovers: Instrumentor (IPO/Instrumentor*.cpp, ~3000 lines with the JSON
     config; 4 tests, all `-passes=instrumentor` with the default config).
- **insert-gcov-profiling** (`pass_gcov.jai`, all of GCOVProfiling.cpp but XCOFF and the clang-only Filter/Exclude
  regexes; /root/jai_instr_rest): the .gcno writer (`Gcov.out` buffer, written with libc open/write), counters,
  writeout/reset/init functions; CFGMST from pass_pgo_instr_gen.jai with a gcov getInstrBB. All 10 GCOVProfiling and
  5 tests/pass/insert-gcov-profiling tests pass, **including the .gcno bytes** (@opt-files, docs/testing.md "Tool
  runs that write files"). Sweeps `--files` (scratch cwd, written files compared): plain 10918/10923 identical,
  `--with-test-flags` 13664 identical, `-gcov-atomic-counter` on tests/e2e + PGOProfile 793/793; 0 differs. Loud: 5
  files with two non-DWO compile units (LLVM reads `FileChecksums[1]` out of bounds: emitGlobalConstructor runs inside
  the CU loop after the first CU). tests/perf/compile has no debug info (nothing to instrument).
  Traps: FuncChecksum is `hash_value(std::string)` = xxh3_64bits ^ 0xff51afd7ed558ccd (release seed), truncated;
  getFirstInsertionPt has the head bit; the `Funcs` list is never cleared between compile units; the cwd comes from
  sys::fs::current_path ($PWD if it names "."); `cast(u32) x << 24` on a u8 shifts the u8 (parenthesize).
- SanitizerCoverage's allow/block lists and SanitizerBinaryMetadata's ignore list go through special_case_list.jai
  (`sancov_allowlist_files` / `sancov_blocklist_files` / `sanmd_ignorelist_files`, the pass constructors' file
  lists); opt's PassRegistry entries pass none, so no test or sweep can reach them.
  2. msan: ARM SIMD handlers.
  None of these passes is timed by a tests/perf benchmark.

## Coroutines (L1.extra.coroutines 298/310: roundtrip 155/155, opt 143/155; /root/jai_coro)

Files: coro_shape.jai (Coroutines.cpp, CoroShape.h / CoroInstr.h accessors as `coro_*` procedures on the
intrinsic calls), pass_coro_early.jai, pass_coro_cleanup.jai (+ Function::createWithDefaultAttr), pass_coro_elide.jai,
coro_spill.jai (SuspendCrossingInfo `Sci`, MaterializationUtils, SpillUtils, libstdc++ `std_sort_by`), coro_frame.jai
(CoroFrame.cpp + performOptimizedStructLayout), coro_debug.jai (frame debug info, resume labels, DIBuilder pieces),
stack_lifetime.jai (StackLifetime for `coro-split<reuse-storage>`), pass_coro_split.jai (CoroSplit, the cloner,
CoroAnnotationElide).

- The 12 `::opt` tests that needed `pgo-instr-gen` / `instrprof` / `sample-profile` pass since those landed
  (155/155).
- Sweeps (whole file, `--with-test-flags`): coro-early, coro-cleanup, coro-elide, `cgscc(coro-split)`,
  `cgscc(coro-split<reuse-storage>)`, `cgscc(coro-annotation-elide)`: 0 differs, 0 bad-ir; the failures are flag
  groups of other units. `module(coro-early),cgscc(coro-split<reuse-storage>,coro-annotation-elide),function(coro-elide),module(coro-cleanup)`:
  10808/10808 identical. `default<O2>` / `default<O0>` on Transforms/Coroutines: 0 differs.
- `coro-split` is a CGSCC pass that takes the `Cgscc_Ur` (cgscc_pm.jai dispatch): the clones go through
  `lcg_add_split_function` / `lcg_add_split_ref_recursive_functions`, then `update_cg_and_am_for_pass` (CGSCC, then
  function pass after `removeUnreachableBlocks` of the ramp), and the SCCs are pushed on `ur.cwl` like LLVM.
- OptimizeFrame: `coro-split<reuse-storage>` by name, or `Pass_Node.opt_level > 0`, which pass_builder_pipelines.jai
  sets on the coro-split nodes of non-O0 pipelines (the printed name stays `coro-split`, like LLVM's).
- Cloning reuses CloneFunctionInto from function_specialization.jai's metadata mapper (`coro_clone_function_into`),
  with a tracking Value_Map (VMap values follow RAUW like WeakTrackingVHs). The arguments map to unlinked
  `freeze poison` dummies that are RAUW'd to poison and dropped afterwards (metadata users become `poison`).
- Pointer-order traps: `sinkLifetimeStartMarkers` iterates a SmallPtrSet<BB, 4>: with more than 3 suspends the order
  is a pointer hash; we pick the unique valid block and fail loudly when several qualify. The AllocaUseVisitor's
  alias map (DenseMap) is iterated in insertion order (LLVM: pointer order; only matters with 2+ aliases created
  before coro.begin). `sinkSpillUsesAfterCoroBegin` sorts with `dominates` (not a strict weak order): std_sort_by is
  libstdc++'s introsort (fails loudly if it would fall back to heap sort).
- Fixed on the way (shared code): fs_map_md wrote a distinct clone's operand into a stale `ir.md_ops` slot when
  mapping the operand grew the array (Jai evaluates the assignment target before the call); erasing the last
  instruction of a block with debug records now leaves them as the block's trailing records
  (`trailing_dbg_records`, adopted by the next `block_append_inst`, like BasicBlock::flushTerminatorDbgRecords /
  adoptDbgRecords); `dbgr_replace_variable_location_op` replaces a #dbg_assign's address too; the ValueMapper remaps
  #dbg_assign addresses and DIAssignIDs.
- Not ported / loud: custom ABIs (`llvm.coro.begin.custom.abi` → "Custom ABI not found"), optimization remarks,
  `-coro-elide-branch-ratio` / `-coro-elide-info-output-file`, giving an unwind destination to a catchswitch /
  cleanupret that unwinds to the caller (rewritePHIsForCleanupPad), a coro.await.suspend invoke with operand bundles.
- Perf: not measured beyond the unit (no tests/perf shape contains coroutines).

### Coroutines next steps
- None left in the unit's tests.

## Layer-1b loop passes: IRCE, guards, fusion/flatten, loop-misc extras, strength reduction (/root/jai_loopextras)

Facts that decide output: knowledge/llvm/loop-extras.md.

- **IRCE** (L1.extra.irce COMPLETE 82/82): `pass_irce.jai` = InductiveRangeCheckElimination.cpp +
  LoopConstrainer.cpp (`Loop_Structure`, `Loop_Constrainer`), plus isKnown{Negative,NonNegative,...}InLoop /
  cannotBe{Min,Max}InLoop (LoopUtils.cpp), InvertBranch and BPI swapSuccEdgesProbabilities. The `-irce-*` options are
  parsed by `irce_parse_cl_opt`. The range check's `Use` is kept as (user, operand number): use ids move when a phi
  grows. Sweeps: `irce` 10812/10812 identical, `-irce-skip-profitability-checks` 10812/10812, `--with-test-flags`
  12774/13628 (0 differs; the loud ones are other passes' options), tests/perf/compile `sroa,irce` 4/4.
- **Guards** (L1.extra.guards COMPLETE 72/72): `guard_utils.jai` = Analysis/GuardUtils.cpp + Utils/GuardUtils.cpp
  widen/setWidenableBranchCond + LowerGuardIntrinsic + LowerWidenableCondition; `pass_loop_predication.jai`,
  `pass_guard_widening.jai` (function pass `GUARD_WIDENING` and loop pass `GUARD_WIDENING_LOOP`: `parse_loop_pass`
  picks the LOOP row of a name registered at both levels). GuardWidening's `llvm::sort` of range checks goes through
  `std_sort_by` on indices. Sweeps (whole corpus, plain and `--with-test-flags`): loop-predication,
  guard-widening, loop-mssa(guard-widening), lower-guard-intrinsic, lower-widenable-condition, make-guards-explicit:
  0 differs.
- **LoopFlatten / LoopFusion** (L1.extra.loop-fusion-flatten COMPLETE 72/72): `pass_loop_flatten.jai` (LoopNest pass
  `LOOP_FLATTEN`, added to loop_pm.jai's loop-nest checks next to LNICM / loop-interchange; fails loudly with more
  than 4 linear IV uses (pointer-ordered SmallPtrSet) or when IV widening deleted one of them), `pass_loop_fuse.jai`
  (`Lfu_Dtu` is a lazy DomTreeUpdater over DT *and* PDT; MergeBlockIntoPredecessor goes through a `Lazy_Dtu` whose
  queue is moved into it), `code_mover_utils.jai`. Sweeps (whole corpus, plain + `--with-test-flags`, and after
  `loop(loop-rotate[,indvars])`, with `-loop-fusion-peel-max-count=8` / `-loop-flatten-widen-iv=false`; tests/perf/compile
  after `sroa,loop(loop-rotate)`): 0 differs.
- **Loop-misc** (L1.extra.loop-misc COMPLETE 94/94): `pass_loop_versioning.jai`, `pass_loop_bound_split.jai`,
  `pass_loop_versioning_licm.jai` (laa_compute gained `no_tti` / `no_tli`), `pass_hardware_loops.jai` (the
  loop-count intrinsics were added to gen_intrinsics.py's EXTRA_DECLS), `pass_loop_unroll_and_jam.jai` (LoopNest pass
  `LOOP_UNROLL_AND_JAM`); canon-freeze and transform-warning already existed. `invalidate<all>` inside a loop
  pipeline is a no-op loop pass. Fixed on the way (shared): `block_single_successor` (value_tracking2.jai) had
  getUniqueSuccessor semantics; it now counts successor edges like BasicBlock::getSingleSuccessor. Sweeps (whole
  corpus, plain and with the unit's flags / `--with-test-flags`): loop-versioning, loop-bound-split,
  loop-versioning-licm (+ `loop-mssa(licm)` after it), hardware-loops (forced, phi/guard/nested/64-bit variants),
  loop-unroll-and-jam (`-allow-unroll-and-jam`, `-unroll-and-jam-count=4`, `-unroll-remainder`, `-unroll-runtime`,
  after loop-rotate): 0 differs.
- **Strength reduction** (L1.extra.strength-reduction COMPLETE 60/60): `pass_nary_reassociate.jai` (also has
  `dt_blocks_preorder` = depth_first(DT)), `pass_separate_const_offset.jai` (`Scof_Gti` = gep_type_iterator, reused
  by SLSR), `pass_slsr.jai` (candidates in an array, indices for Candidate *). Sweeps (whole corpus, plain,
  `--with-test-flags`, with `-mtriple=x86_64-unknown-linux-gnu`, and after instcombine / each other): 0 differs.
- Jai trap: `cast(u64) a << 32` is `cast(u64) (a << 32)` (the shift happens in a's own 32-bit type): build 64-bit
  keys with a typed temporary (`hi: u64 = a; (hi << 32) | b`). It made SeparateConstOffsetFromGEP's map keys
  collide (found by the whole-corpus sweep).

## CFI: LowerTypeTests, CrossDSOCFI, GlobalSplit, SimplifyTypeTests (L1.extra.lowertypetests COMPLETE; /root/jai_cfi)

- Files: `pass_lower_type_tests.jai` (LowerTypeTests.cpp: BitSetBuilder, GlobalLayoutBuilder, ByteArrayBuilder,
  LowerTypeTestsModule, x86 jump tables, branch funnels, summary import/export, dropTypeTests),
  `pass_cfi_misc.jai` (CrossDSOCFI, GlobalSplit, SimplifyTypeTests), `module_summary.jai` (a small YAML reader and
  the ModuleSummaryIndex queries for `-lowertypetests-read-summary` / `-wholeprogramdevirt-read-summary`),
  `replace_constant.jai` (convertUsersOfConstantsToInstructions, ConstantExpr::getAsInstruction).
- Fails loudly: `-lowertypetests-write-summary` (no YAML writer), non-x86 jump tables (ARM/Thumb/AArch64/RISC-V/
  WASM), and a disjoint set with more than 16 type ids of equal UniqueId (std::sort's order there is
  implementation-specific; see knowledge/llvm/cfi-and-devirt.md).
- The EquivalenceClasses is `Ltt_Ec` (nodes in insertion order with leader / next links) so member iteration order
  matches LLVM's without pointer-keyed sets.
- Sweeps (whole-file, `--with-test-flags`): lowertypetests, cross-dso-cfi, globalsplit, simplify-type-tests: 0 differs
  (13156 identical; failures are unrelated unsupported options).
- MergeFunc/cfi-thunk-merging now passes (it needed lowertypetests), so L2.lto-passes is COMPLETE.

## WholeProgramDevirt (L1.extra.wholeprogramdevirt COMPLETE 66/66; /root/jai_cfi)

- `pass_wpd.jai`: DevirtModule (single-impl, uniform / unique return value, virtual constant propagation with the
  Evaluator, branch funnels, summary import and export, `-wholeprogramdevirt-check=trap`), the TypeMetadataUtils
  call finders, and `wpd_opt_startup` (optdriver's AssignGUID + updateVCallVisibilityInModule under
  `-whole-program-visibility`; called in `opt_main` after `source_filename` is set, which the private GUIDs hash).
- The Evaluator honours `cfo_no_tli` (const_folding_calls.jai): WPD's Evaluator has no TLI, so library calls do not
  fold. `llvm.debugtrap` was added to gen/gen_intrinsics.py's EXTRA_DECLS (trap mode creates it).
- Fails loudly: `-wholeprogramdevirt-write-summary`, `-devirtualize-speculatively`, `-wholeprogramdevirt-check=fallback`
  (versionCallSite), devirtualizing a call with a ptrauth bundle. Export mode runs (summary-driven call slots,
  `.llvm.merged` promotion, exported `__typeid_*` aliases) but the resolutions it records are never written.
- Sweeps (whole-file): `wholeprogramdevirt --with-test-flags` 13226 identical / 0 differs, the same with
  `-whole-program-visibility`; on the 92 files with type tests: trap + keep-unreachable=false, export (empty and
  import-vcp.yaml summaries), import (vcp-branch-funnel, unique-ret-val1), threshold 1 + `-wholeprogramdevirt-skip`,
  and `lto<O2>` with whole program visibility: 0 differs. No perf benchmark contains type tests (perf not run).

## ObjC ARC (L1.extra.objcarc COMPLETE 104/104; /root/jai_extras_c)

- `objcarc.jai`: ARCInstKind (ObjCARCInstKind.cpp), the ObjCARCAnalysisUtils / ObjCARCUtil helpers, the runtime entry
  points, EraseInstruction, BundledRetainClaimRVs, ProvenanceAnalysis (`Arc_Pa`: the pair cache keyed by
  `(A << 32) | B`, inserted as `true` before the recursive check exactly like LLVM, and the
  GetUnderlyingObjCPtrCached cache with the WeakVH as a plain id and the WeakTrackingVH as a `Vh` slot),
  DependencyAnalysis and PtrState (TopDown / BottomUp states are one struct with `arc_td_*` / `arc_bu_*` procedures),
  objc-arc-aa (`Aa_Kind.OBJC_ARC` in aa.jai: only getModRefInfo(Call, Loc) and getMemoryEffects(F) do anything,
  alias / getModRefInfoMask reduce to AAResultBase's MayAlias / ModRef).
- `pass_objcarc.jai`: objc-arc (ObjCARCOpt), objc-arc-contract, objc-arc-expand, pa-eval. There is no
  objc-arc-apelim in LLVM 23 (apelim.ll runs objc-arc). The cl::opts `-enable-objc-arc-opts`,
  `-arc-opt-max-ptr-states`, `-arc-contract-use-objc-claim-rv` are parsed by `objcarc_parse_cl_opt`.
- Value::stripPointerCasts looks through calls with a `returned` argument; autoupgrade.jai's `strip_pointer_casts`
  does not, so the ARC code uses `arc_strip` (= `strip_pointer_casts_kind(v, .ZERO_INDICES)`). contract-marker.ll's
  `@returnsArg(ptr returned)` needs it.
- Address order: the RRInfo sets (SmallPtrSet<Instruction *, 2>) are insertion-ordered arrays. Past two elements
  LLVM iterates them in pointer order, but nothing visible depends on it: MoveCalls inserts at distinct points,
  DeadInsts erasure order and PairUpRetainsAndReleases' fixpoint are order-independent. The one place where the
  order reaches state is VisitInstructionTopDown inserting the RC identity roots of a release insertion point into
  the top-down BlotMapVector (its iteration order feeds ProvenanceAnalysis' cycle-breaking cache); that fails loudly
  when more than two roots add more than one new pointer (never on the corpus). BundledRetainClaimRVs'
  destructor walks a DenseMap, but each entry only touches its own calls.
- Not ported (debug only): GatherStatistics, the BBState / Sequence printers. The AutoreleasePoolElimination
  remark is not emitted (no -pass-remarks support).
- `llvm.objc.*` runtime entry points were added to gen/gen_intrinsics.py's EXTRA_DECLS (claimAutoreleasedReturnValue
  is declared by no test).
- Sweeps (whole-file, 10823 files): objc-arc, objc-arc-contract, objc-arc-expand, objc-arc,objc-arc-contract,
  pa-eval (default AA and `-aa-pipeline=`), gvn with `-aa-pipeline=basic-aa,objc-arc-aa`: all identical
  (gvn: 1 loud, an x86 hadd known-bits gap); `--with-test-flags` objc-arc / objc-arc-contract 13325 identical,
  0 differs (314 loud, all other passes' options); `--per-function` on the ObjCARC tests 375/375 for objc-arc,
  objc-arc-contract and the pair; tests/perf/compile objc-arc / objc-arc-contract / sroa,objc-arc 4/4. No perf
  benchmark contains ARC calls (perf not run).
## CFG structurization and scalarization (L1.extra.cfg-structurize COMPLETE 109/109, L1.extra.scalarizer COMPLETE 88/88; /root/jai_extras_b)

- Files: pass_lower_switch.jai, control_flow_utils.jai (ControlFlowHub, invertCondition, SplitCallBrEdge, the
  CycleInfo update methods addBlockToCycle / getSmallestCommonCycle), pass_unify_loop_exits.jai,
  pass_fix_irreducible.jai, region_info.jai (RegionInfo, RegionNode graph and iterators, DominanceFrontier,
  `print<regions>` with `-print-region-style`), pass_structurizecfg.jai (+ SSAUpdaterBulk::RewriteAndOptimizeAllUses,
  EliminateNewDuplicatePHINodes, SSAUpdater::RewriteUseAfterInsertions), pass_scalarizer.jai,
  pass_scalarize_masked_mem_intrin.jai (also the legacy pass of llc's IR pipeline, which used to be a silent no-op
  stub in cg_todo_passes.jai), extras_b_cl.jai (the cl::opts of these passes).
- RegionInfo is computed per call of `ri_get` (not cached in the FAM; LLVM's result would be identical for the
  same IR and trees). It keeps the function's DominatorTree pointer and reads it in `ri_contains`, like LLVM, so
  StructurizeCFG's tree updates are seen by the regions. Regions and nodes are temp rows (`Region_Id`, `Rn_Id`).
- `Dom_Tree.slow_queries_unknown` (domtree.jai) marks a tree whose slow-query count depends on pointer order;
  dt_print fails loudly on it while the DFS numbers are invalid. A crossing of the 32-query threshold that happened
  in our order but not in LLVM's is not detected (a residual, never seen on the corpus).
- `-structurizecfg-trace` (ours) prints the function after each region; `-structurizecfg-guess-address-order`
  (ours) dedups in creation order instead of failing.
- Shared fixes: `replace_uses_of_with` (ic_core.jai) returns when From == To, as User::replaceUsesOfWith does
  (otherwise the use moves to the front of its list); the parser's `snan(0x0)` payload is the bit below the quiet
  bit (APFloat makeNaN), was bit 0 (x86_fp80 `+snan(0x0)` printed `+snan(0x1)`).
- Sweeps (whole corpus, 0 differs / 0 bad-ir in all): lower-switch 10817 identical; unify-loop-exits 10610 (207
  llvm-failed: LLVM asserts on switch terminators); fix-irreducible 10789; `require<loops>,fix-irreducible,
  print<loops>,print<cycles>` 10789; lower-switch,unify-loop-exits / lower-switch,fix-irreducible identical;
  print<regions> 10817; structurizecfg 10737 + 2 loud (dedup address order), per function 84168 + 2 loud;
  structurizecfg,print<domtree> 10734 + 5 loud; --with-test-flags structurizecfg 13045 identical, rest loud (other
  passes' cl::opts); sroa,structurizecfg on tests/perf/compile 4/4. scalarizer 10809 + 3 loud (untruncated
  `ConstantInt::get` indices), `scalarizer<load-store;min-bits=32>` 10811, `scalarizer<load-store;min-bits=16>,dce`
  10810, `--with-test-flags scalarizer<load-store>` 13119 (rest: other passes' flags), tests/perf/compile 4/4;
  scalarize-masked-mem-intrin 10817, --with-test-flags 13129 (rest: other passes' flags).

## GC statepoints (L1.extra.gc-statepoints COMPLETE 156/156; /root/jai_extras_c)

- `pass_rs4gc.jai`: RewriteStatepointsForGC (module pass) with its liveness (`Rs_Liveness`: Kill/Live/LiveIn/LiveOut
  SetVectors per block), findBasePointer's BDVState fixpoint, rematerialization (at uses and after statepoints,
  TTI cast costs; getAddressComputationCost is 0 without a SCEV on every target), statepoint / gc.relocate /
  gc.result creation (IRBuilder's CreateGCStatepointCall/Invoke), relocationViaAlloca + PromoteMemToReg, and
  stripNonValidData. `pass_place_safepoints.jai`: PlaceSafepoints (fresh DT / LoopInfo / SCEV like its legacy FPM,
  the poll is inlined with InlineFunction). `safepoint_ir_verifier.jai`: verify<safepoint-ir>.
- Release-build semantics: RS4GC's asserts ("support for FCA unimplemented", "non-leaf call without deopt info")
  are no-ops in LLVM's release build, so they are no-ops here (such values are never live).
- Address order: relocationViaAlloca walks a DenseMap, but only to place loads and stores that PromoteMemToReg
  removes; the allocas themselves are created in Live order. PlaceSafepoints sorts the poll locations by block name
  with std::sort: below 17 elements that is an insertion sort (stable), so ties keep their order; with more and a
  tie it fails loudly. verify<safepoint-ir> seeds its worklist from a DenseMap: the fixpoint is computed from both
  block orders and fails loudly if the reports differ.
- `for x: b..e-1` over a u32 operand range wraps when the range is empty at 0 (a zero-argument call with an empty
  `"deopt"()` bundle): iterate in s64.
- LoopInfo's `top_level` is already LLVM's TopLevelLoops order (`for (Loop *L : LI)`); iterating it reversed
  placed the polls in another order (only visible with two loops: found by the stress run below).
- `isa<IntrinsicInst>` is true for any callee named `llvm.*` (Function::isIntrinsic), also unknown ones whose
  getIntrinsicID() is not_intrinsic: test `glob(f).intrinsic`, not `call_iid != NOT_INTRINSIC`.
- Sweeps (whole-file): rewrite-statepoints-for-gc 10827/10827, place-safepoints 10743/10743, verify<safepoint-ir>
  10825/10825, rewrite-statepoints-for-gc,verify<safepoint-ir> 10824/10824 identical; `--with-test-flags` 13363 / 13276
  identical, 0 differs (280 loud: other passes' options); the RS4GC tests with -spp-rematerialization-threshold=0/100,
  -rs4gc-clobber-non-live, -rs4gc-remat-derived-at-uses=false, -spp-print-base-pointers, and PlaceSafepoints with
  every -spp-* option: 0 differs; `--per-function` 283 + 19 identical.
- The corpus has almost no gc functions, so a stress run (/tmp script, not committed) added `gc "statepoint-example"`
  to every definition of the passing files, optionally turned every `ptr` into `ptr addrspace(1)` and appended a
  gc.safepoint_poll: rewrite-statepoints-for-gc 4903/4903 identical (the rest LLVM rejects), place-safepoints
  1490/1490, function(place-safepoints),rewrite-statepoints-for-gc 796/796, + verify<safepoint-ir> 1058/1058. No perf
  benchmark has gc functions (perf not run).
## OpenMPOpt (L1.extra.openmp-opt COMPLETE 106/106; /root/jai_openmp)

- Files: `pass_openmp_opt.jai` (the passes, OMPInformationCache = `omp_ic`, OpenMPOpt = `oo`, the host
  transformations), `openmp_aas.jai` (AAICVTracker, AAExecutionDomain, AAHeapToShared, AAFoldRuntimeCall,
  registerAAs / registerAAsForFunction, AA::isPotentiallyAffectedByBarrier, AANoSync::isAlignedBarrier),
  `openmp_kernel_info.jai` (KernelInfoState, AAKernelInfo, SPMDization, the custom state machine,
  getUniqueKernelFor, rewriteDeviceCodeStateMachine), `pass_openmp_opt_merge.jai` (mergeParallelRegions with
  createParallel / createMaster / createBarrier / finalize; the IRBuilder is `omb`), `omp_ir_builder.jai`
  (OpenMPIRBuilder pieces),
  `gen_omp_kinds.jai` (generated from OMPKinds.def by `gen/gen_omp_kinds.py`: runtime functions with signatures,
  attribute sets in both OptimisticAttributes variants, ICVs). Facts: knowledge/llvm/openmp-opt.md.
- Attributor hooks added for it (attributor*.jai): AttributorConfig fields on `atr` (`default_init_live_internals`,
  `omp_init_callback`, `omp_ipo_amendable_kernels`, `max_fixpoint_iterations`), simplification callbacks with kinds
  (`Atr_Simpl_Cb`: SCB_NULL, SCB_FOLD_RUNTIME_CALL; LLVM's getAssumedSimplifiedValues / getAssumedSimplified /
  getAssumedConstant semantics), the kernel-environment GlobalVariableSimplificationCallback
  (`atr.gv_simplification_cbs`), VirtualUseCallbacks (`atr.virtual_use_cbs`, checked by checkForAllUses and
  checkForAllCallSites), the AAExecutionDomain lookups of AAIsDead (fences) and AAPointerInfo (aligned regions,
  initial-thread-only, kernel lifetime of allocas), `atr_internalize_functions`, and the CGSCC CallGraphUpdater split
  into `atr_cgscc_reanalyze` (at cleanupIR time) and `atr_cgscc_finalize` (at the end of the pass).
- A KernelInfoState holds SetVectors: copies (`StateBefore = getState()`, `getState() = FnAA->getState()`) are deep
  (`kis_assign`), Jai array copies would share buffers.
- Fixed on the way: AAHeapToStack's isGlobalizedLocal read only the call-site `alloc-family` (LLVM's
  CB.getFnAttr also looks at the callee, where OpenMPOpt puts it); AbstractCallSite recognized a broker through the
  raw callee instead of getCalledFunction (type check).
- code_extractor.jai gained AggregateArgs (`structArg`, `gep_*` / `loadgep_*` with `!align`), ExcludeArgsFromAggregate,
  AllocationBlock and ArgsInZeroAddressSpace for the parallel region outlining.
- Debug records: an instruction created before another instruction's *iterator* (`Instr->getIterator()`, an
  `Instruction *` insert position, `std::next`) adopts the records attached there; one created at `begin()`,
  `getFirstInsertionPt()` or `getFirstNonPHIIt()` (head bit) does not. `omp_insert_before` / `insert_at_position(...,
  false)` vs. a plain insert. The same rule fixed AAIndirectCallInfo's compare/clone/unreachable and
  AAPrivatizablePtr's replacement loads and `.priv` alloca (`debugify,attributor[-cgscc]` over Transforms/Attributor
  had 4 / 5 differs, now 0).
- Fails loudly: GPU triples (nvptx / amdgcn), merging parallel regions of device code, merging regions of two or
  more blocks of one SCC (BB2PRMap is pointer-ordered), more than 4 outside users of a sequential-region value
  (a SmallPtrSet), a function named `__last` matching OMPRTL___last. Remarks (`-pass-remarks=openmp-opt`) are not
  supported by opt here at all.
- Tests: `tests/pass/openmp-opt/` (32 files) are LLVM's GPU-only OpenMP tests with the target triple and the
  `-mtriple` / remark flags removed (custom state machines, SPMDization with guards, deglobalization, kernel
  environment folding, `--data-layout=A5`, OptimisticAttributes): all pass. The GPU tests that use nvvm / amdgcn
  intrinsics were left out (gen_intrinsics.jai does not know them, so their attributes and AANoSync::isAlignedBarrier
  would differ).
- Sweeps (whole corpus): `default<O2>` 10816 identical / 0 differs / 0 bad-ir / 35 loud (was 87 loud: the 25 OpenMP
  modules, 15 loop-vectorize-with-profile-summary and 13 GlobalsAA-with-!callback files all pass now); remaining
  loud: alloc-token 12, cg-profile value profiles 6, SROA dbg_assign 4, inline ObjC ARC 3, SROA known vscale 3,
  loop-rotate convergence tokens 2, 1 each: avoid-assume-hang timeout, inline strictfp, inline vtable promotion,
  x86 hadd known bits, loop-idiom store chain order. `default<O2> --with-test-flags` 13273 / 0 / 0 / 352 loud;
  tests/perf/compile 4/4. `openmp-opt`, `openmp-opt-cgscc`, `openmp-opt-postlink` (plain and `--with-test-flags`)
  and `default<O2>`, `lto<O2>`, `lto-pre-link<O2>`, `thinlto-pre-link<O2>` on the 25 OpenMP corpus files and on
  tests/pass/openmp-opt: 0 differs; the same 57 files with `-openmp-opt-enable-merging` (openmp-opt-cgscc,
  `attributor,cgscc(openmp-opt-cgscc)`, default<O2>, lto<O2>) and under `debugify,` (openmp-opt, openmp-opt-cgscc,
  attributor, attributor-cgscc, default<O2>): 0 differs.
- Perf: no benchmark has OpenMP (the passes exit early).
## LoadStoreVectorizer (L1.extra.load-store-vectorizer COMPLETE 44/44; /root/jai_extras_d)

- `pass_load_store_vectorizer.jai`, a whole-file port (the Vectorizer object is `Lsv`, chains are `[..] Lsv_Elem`
  in temp storage, the MapVector of equivalence classes is `Lsv_Class_Map` with erased flags, the MRU list of
  gatherChains is an index-linked list). Flags in `extras_d_cl.jai`.
- Address order: mergeEquivalenceClasses walks a `DenseMap<const Value *, const Value *>`; the only visible effect
  is the position of newly created target classes, so we fail loudly when one reduced key creates two or more new
  target classes (`-load-store-vectorizer-guess-address-order` guesses insertion order). deleteExtraElements walks a
  `DenseSet<Instruction *>`, but the set of deleted instructions does not depend on the order (audited).
- Shared fixes made here: `st_isUnalignedMem16Slow` (X86Subtarget clears the i586 tuning bit when SSE4.2/SSE4A is
  available; the default TuneCPU is i586, so without this every `-mattr=+avx` module looked slow at 16-byte
  unaligned accesses), and `tti_allows_misaligned_memory_accesses` now applies isMemoryAccessFast's isBitAligned
  test. `-mcpu haswell` (value as the next argument) is accepted (`extras_d_takes_value`).
- Sweeps: `load-store-vectorizer --with-test-flags` 13341 identical, 0 differs, 241 loud (none from this pass: other
  passes' options/IR); plain 10772/10777 (5 loud); `sroa,instcombine,load-store-vectorizer -mattr=+avx512f` over
  tests/perf/compile + tests/e2e 694/694. No perf shape exercises the pass (its cost is LLVM's: O(n^2) isSafeToMove
  bounded by the 64-chain MRU).

## Hardening: BoundsChecking, AllocToken, LowerAllowCheck, KCFI, SafeStack, StackProtector (L1.extra.hardening COMPLETE 144/144; /root/jai_extras_c)

- `pass_hardening.jai`: kcfi, lower-allow-check (`<cutoffs[..]=N;runtime_check=N>`), bounds-checking (`<trap|rt|rt-abort|
  min-rt|min-rt-abort;merge;handler-preserve-all-regs;guard=N>`, the NoSanitizeInserter as "mark every instruction
  created after this id"), alloc-token (all four modes, module-flag and cl::opt overrides), plus
  `create_rng` = Module::createRNG (std::mt19937_64 seeded by std::seed_seq from `-rng-seed` and the salt
  name + filename(ModuleID); libstdc++'s bernoulli_distribution is `generate_canonical<double,53>() < p`) and
  `get_stable_sip_hash` (SipHash-2-4, the key of llvm/lib/Support/SipHash.cpp). The RNG is checked by
  `alloc-token<mode=random>` (with and without -rng-seed) and `-lower-allow-check-random-rate=0.1/0.5/0.9`: identical.
- `hardening_target.jai`: the x86 TargetLowering hooks (getIRStackGuard with the TLS slot of glibc/musl/Android/
  Fuchsia, insertSSPDeclarations, getSafeStackPointerLocation, the stack-protector-guard* module flags) and the
  stack-protector / safestack rows of the x86 runtime libcall table. Non-x86 triples fail loudly (LLVM needs a
  TargetMachine; with no triple LLVM's opt stops with "pass '<name>' requires TargetMachine", as we do). The MSVC security cookie and -stack-protector-guard-symbol fail
  loudly.
- `pass_stack_protector.jai`: requiresStackProtector, InsertStackProtectors (SelectionDAG SP when the guard is not an
  IR TLS slot: only the prologue), CreateFailBB; isInTailCallPosition for the tail call before a return (aggregate or
  other returned values fail loudly). `pass_safe_stack.jai`: SafeStack + SafeStackLayout (regions as an array;
  LLVM's `Regions.insert(&R, R0); continue;` re-examines the moved region, kept as is), May-liveness live ranges from
  stack_lifetime.jai; inlining a defined __safestack_pointer_address fails loudly.
- These are RequiredPassInfoMixin passes (they also run on optnone functions): bounds-checking, kcfi,
  lower-allow-check, alloc-token, safe-stack, stack-protector, verify<safepoint-ir>.
- Shared fixes: memory_builtins.jai's ObjectSizeOffsetEvaluator cache now follows RAUW like LLVM's WeakTrackingVH
  (a size/offset phi folded to a constant left a dangling id in the cache: `<badref>` in BoundsChecking/phi.ll), it
  strips with Value::stripPointerCasts (through `returned` arguments), and ConstantPointerNull of a vector of
  pointers now has address space 0 (it read the vector's element count).
- bounds-checking fails loudly when the object size, the offset and the pointer's index type have different widths
  (an addrspacecast between address spaces of different index widths): LLVM asserts there (its release build
  compares and folds APInts of mismatched widths).
- Sweeps (whole-file, 10828 files): kcfi, lower-allow-check (+ `<cutoffs[0|1|2]=990000;runtime_check=1>`),
  alloc-token (default, increment, typehash) identical; bounds-checking (trap, rt;merge, min-rt-abort;guard=3) 10825
  identical, 0 differs, 1 loud (the index-width assertion above); stack-protector and safe-stack with -mtriple
  x86_64-pc-linux-gnu / x86_64-unknown / x86_64-linux-android / x86_64-linux-musl / x86_64-apple-darwin /
  x86_64-unknown-openbsd / x86_64-unknown-fuchsia / i386-pc-linux-gnu / x86_64-pc-windows-msvc: 0 differs (after
  fixing Darwin's PIC relocation model for __stack_chk_guard's dso_local), safe-stack with -safe-stack-coloring=0,
  -safe-stack-layout=0, -safestack-use-pointer-address: 0 differs; `--with-test-flags` kcfi / bounds-checking /
  lower-allow-check / stack-protector / safe-stack: 0 differs; tests/perf/compile: identical. The AllocToken and
  LowerAllowCheck tests with random modes / rates and -rng-seed: identical. Stress (/tmp script): sspstrong on every
  function (x86_64 linux) 1186/1186, sspreq (darwin) 597/597, safestack 1194/1194, safestack+sspstrong 796/796,
  bounds-checking<rt;guard=3> 800/800 (the rest LLVM rejects or fail loudly). No perf benchmark has these attributes.
- SafeStack sizes and offsets are LLVM's `unsigned` (32-bit): huge allocas wrap exactly as there. StackLifetime's
  constructor collects the markers, so -safe-stack-coloring=0 still erases them and the full live range has
  Instructions.size() bits.

## Utility passes and misc analysis printers (L1.extra.utility 41/44, L1.extra.analysis-misc COMPLETE 58/58; /root/jai_extras_b)

- Files: pass_utility_misc.jai (instnamer, strip-convergence-intrinsics, strip, strip-nondebug,
  strip-dead-cg-profile, metarenamer), pass_utility_module.jai (reg2mem, lower-global-dtors, lower-ifunc,
  fatlto-cleanup, hipstdpar-interpose-alloc / -math-fixup, ctx-prof-flatten), pass_normalize.jai (IRNormalizer),
  pass_strip_dead_debug_info.jai (+ DebugInfoFinder), pass_lint.jai (Lint + FindInsertedValue),
  ir2vec.jai (vocabulary JSON reader, embedders, `print<ir2vec>`, `print<ir2vec-vocab>`),
  analysis_printers_extras_b.jai (print<hash-recognize> (a loop pass), print<structural-hash>[<detailed>|
  <call-target-ignored>], print-profile-summary, print<stack-safety-local>, print-stack-safety,
  print<stack-lifetime><may|must>, print<func-properties>). The cl::opts are in extras_b_cl.jai.
- Utility remaining: 3 strip-dead-debug-info tests keep several CUs live and fail loudly on the CU set's pointer
  order (see the address-order table). Not ported: strip-debug-declare, hipstdpar-select-accelerator-code,
  ctx-prof-flatten with a contextual profile (`-use-ctx-profile` is not an option of ours: unsupported-option
  error) and ctx-prof-flatten-prethinlink (not registered).
- Shared fixes: `set_name` creates the new name before dropping the old one (setNameImpl; metarenamer's numbering)
  and caps local names at 1024 bytes; `Crit_Edge_Options.preserve_loop_simplify` defaults to true like LLVM's.
- ir2vec.jai calls libc `strtod` (#foreign, for JSON numbers and `cl::opt<float>` values, like LLVM's parsers) and
  formats `%.2f` itself, exactly (ir2vec_fmt2). Not a new dependency: libc is already linked.
- Known residual (silent, 1 corpus file): LLVM 23 has two zero constants for FP vectors that print the same:
  `ConstantAggregateZero` (AutoUpgrade's x86 maskz upgrades call `ConstantAggregateZero::get`) and a ConstantFP
  splat (`Constant::getNullValue`, the parser). impl/jai has one, so print<func-properties> counts an upgraded
  maskz zero as a ConstantFP operand (MemorySanitizer/X86/avx512-intrinsics-upgrade.ll, detailed only).
- Sweeps (whole corpus, 10828 files): instnamer, strip-convergence-intrinsics, strip-dead-cg-profile,
  lower-global-dtors, lower-ifunc, fatlto-cleanup, hipstdpar-*, metarenamer, `require<loops>,break-crit-edges`,
  ctx-prof-flatten all identical; reg2mem 10821 + 7 llvm-failed; strip-dead-debug-info 10826 + 2 loud; normalize
  10610 + 218 loud (metadata operands, same-named operands, unnamed struct types in constants), 0 differs;
  lint 10821 + 1 loud (known bits of x86 hadd) + 6 llvm-failed; print<structural-hash> / <detailed> /
  <call-target-ignored> 10828 each; print-profile-summary 10826; print<hash-recognize> 10828;
  print<stack-safety-local> / print-stack-safety 10603 + 225 loud (callee order); print<stack-lifetime><may> /
  <must> 10828; print<func-properties> (plain and detailed) identical but for the residual above; print<ir2vec>
  symbolic and flow-aware 10828 (with the dummy_3D_nonzero_opc vocabulary).

## Codegen IR passes, Layer 1b (L1.extra.codegen-ir-misc COMPLETE 116/116; /root/jai_extras_d)

- Files: `pass_lower_atomic.jai`, `pass_lower_invoke.jai`, `pass_indirectbr_expand.jai` (replaces llc's guard),
  `pass_consthoist.jai` (now also the -consthoist-gep path, -consthoist-with-block-frequency=false and the optsize
  maximizeConstantsInRange; `should_optimize_for_size_fn` in psi.jai), `cg_interleaved_access.jai` (an opt pass
  now; getMask's IR side effects for masked/vp accesses and the (de)interleave intrinsics) + `x86_interleaved_access.jai`
  (X86InterleavedAccessGroup: AVX factor-3/4 lowering), `pass_infer_address_spaces.jai`, `pass_global_merge.jai`,
  `pass_expand_ir_insts.jai` (replaces llc's guard; also IntegerDivision.cpp). cl::opts in `extras_d_cl.jai`.
- Traps found: the new-PM GlobalMergePass ignores -global-merge-max-offset (MaxOffset comes only from
  `global-merge<max-offset=N>`, default 0 = nothing merges) but doMerge reads -global-merge-group-by-use and
  -global-merge-ignore-single-use directly. InferAddressSpaces does nothing on x86 unless
  -assume-default-is-flat-addrspace. ExpandIRInsts' CreateSelectWithUnknownProfile calls pass "sign" / "saturated"
  as the *pass name* argument (the selects stay unnamed). LowerAtomic's load/store lowering does not count as a change.
- Shared fixes: `take_name` drops the destination's name when the source has none (Value::takeName);
  `set_name` caps local names at 1024 bytes (-non-global-value-max-name-size) and, like createValueName, uniquifies
  a truncated name that equals the current one (repeated block renames in ExpandIRInsts).
- Order notes: InterleavedAccess's tryReplaceExtracts walks a DenseMap of extracts: only the new extracts' use-list
  order depends on it (not printed); we use the load's user order. InferAddressSpaces / GlobalMerge maps are lookups.
- Sweeps (0 differs, 0 bad-ir everywhere): lower-atomic / lower-invoke --with-test-flags 13535 / 13527 identical;
  indirectbr-expand -mattr=+retpoline 2163/2163; consthoist --with-test-flags (also -consthoist-gep
  -consthoist-with-block-frequency=false) 13521; interleaved-access --with-test-flags 5173, -mattr=+avx2 10853/10853,
  sroa,instcombine,loop-vectorize,interleaved-access over LoopVectorize/X86 + perf + e2e 797/797;
  infer-address-spaces -assume-default-is-flat-addrspace 10859/10859, plus LLVM's own InferAddressSpaces tests
  (not imported: AMDGPU/NVPTX dirs) with the triple dropped: 44/44 identical (48/48 with -mtriple=x86_64);
  global-merge<max-offset=100|1000;merge-const;merge-const-aggressive|64;...> --with-test-flags 13555, also with
  -global-merge-group-by-use=false / -global-merge-ignore-single-use=false 10860/10860; expand-ir-insts with
  -expand-div-rem-bits=0 -expand-fp-convert-bits=0 (x86_64 and i686) 10850/10850, --with-test-flags 5191.

## LowerMatrixIntrinsics (L1.extra.lower-matrix COMPLETE 98/98; /root/jai_matrix)

- `pass_lower_matrix.jai`: `lower-matrix-intrinsics`, `lower-matrix-intrinsics<>`, `lower-matrix-intrinsics<minimal>`
  (+ TileInfo from MatrixUtils.cpp), and `-enable-matrix` in the O1-3 pipelines (`lower-matrix-intrinsics,early-cse`
  after lower-constant-intrinsics) and at -O0 (`function(lower-matrix-intrinsics<minimal>)`). All the pass's cl::opts
  are parsed (`lm_cl`). Remarks (RemarkGenerator, ExprLinearizer, the OpInfoTy counters that only feed them) are not
  ported: our opt rejects -pass-remarks*. `-matrix-print-after-transpose-opt` fails loudly.
- `Irb.fmf` (ir_builder.jai) is IRBuilder::setFastMathFlags: irb_insert ORs it into every FPMathOperator it inserts
  (what setFPAttrs does in CreateBinOp/CreateFNeg/CreateCast/CreateCall/CreateSelect/CreatePHI). 0 for every other
  pass, so nothing else changed. The pass relies on the builder keeping the flags after emitMatrixMultiply.
- The release-build LLVM we compare with has assertions off: `llvm.matrix.column.major.load/store` with
  `-matrix-default-layout=row-major` is lowered (row-major), not rejected; we do the same.
- Verified beyond the corpus: the 22 skipped LLVM tests of the directory (aarch64 triple / remarks / asserts) with
  their RUN lines and the triple rewritten to x86_64 or removed: all identical (tiled loop nests, alias checks with
  copies, dot products, remainder splitting, `<minimal>`); and every LLVM test file under 4 targets (none, x86_64,
  +avx2, +avx512f) x 7 argument sets (default, row-major, force-fuse, loops threshold 0, `-O2 -enable-matrix`,
  `-O0 -enable-matrix`, `<minimal>`): 1976 identical, 0 differs, 12 where LLVM itself crashes (`tools/lower_matrix_xcheck.sh`).
- Sweeps (2026-11): `lower-matrix-intrinsics` 10923/10923 identical, `<minimal>` 10923/10923, `--with-test-flags`
  13648 identical + 105 loud (other passes' flags), `-O2 -enable-matrix` 10842 identical + 71 loud (all pre-existing
  -O2 gaps), `-O0 -enable-matrix` 10920 identical, `--with-test-flags -O2 -enable-matrix` 13530 identical + 204 loud;
  0 differs / 0 bad-ir everywhere.
- Compile time: a chain of 4x4 double multiplies + fadds scales linearly (500/2000/8000 ops: 0.7/2.8/11.3 s with the
  x64 build, LLVM 0.3/1.4/6.9 s). Sinking transposes through deep add/multiply trees is exponential in LLVM too
  (it duplicates subtrees); both get killed on a 200-deep (A*A)^t + A*A chain. No tests/perf shape uses the pass.

## Assignment tracking (L1.extra.assignment-tracking)

- `assignment_tracking.jai`: the at:: helpers (getDVRAssignmentMarkers, deleteAssignmentMarkers, RAUW, remapAssignID,
  calculateFragmentIntersect), DbgVariableRecord's assign-specific setters, mergeDIAssignID (`merge_di_assign_id`,
  used by InstCombine, LICM, SLP, MemCpyOpt, AggressiveInstCombine), trackAssignments + the `declare-to-assign` pass,
  and SROA's migrateDebugInfo / calculateFragment. Users: SROA (all rewriter call sites, MigrateOne, the aggregate
  store splitter, deleteDeadInstructions, RemoveRedundantDbgInstrs at the end), mem2reg (AssignmentTrackingInfo,
  cleanUpDbgAssigns), DSE (shortenAssignment), the inliner (trackInlinedStores, fixupAssignments), ADCE (linked
  records stay), ValueMapper / llvm-link / LoopRotate remapping, the verifier.
- Marker order: getAllDbgVariableRecordUsers sorts by the DIAssignID operand's use-map index, descending. Each
  tracked operand has its own index in LLVM, so the DIAssignID stamp (`at_assign_stamp`, default = record index,
  re-stamped by `dbgr_set_assign_id`) is separate from the location stamp (`dbgr_stamp`).
- at::getAssignmentInsts is context-wide in LLVM; `at_rauw` scans every function, `dbg_assign_has_linked_insts`
  only the record's function (an ID shared across functions is invalid IR anyway). ADCE precomputes the set.
- Sweeps 2026-11 (corpus, plus 221 clang `-O2 -g -gno-key-instructions -Xclang -disable-llvm-passes` builds of
  tests/e2e/src, not committed): `declare-to-assign,X` for sroa/mem2reg/instcombine/dse/memcpyopt/simplifycfg and
  `function(declare-to-assign),cgscc(inline)`: 0 differs. `default<O2>` on the `-g` builds: 5 differs, identical with
  and without declare-to-assign (plain dbg_value/DIArgList salvage differences in the O2 pipeline, not assignment
  tracking: memory_static_local_volatile, 2003-04-22-Switch, puzzle, linpack-pc, richards_benchmark) and one loud
  "remapping a DIArgList debug location" (memory_pointers). Not investigated.
- `debugify,cgscc(inline)` (2026-11): 0 differs after making the inliner's `X::Create(.., I->getIterator())`
  insertions adopt the records in front of I (`insert_at_position(.., false)`: the invoke's normal-dest branch,
  merged deopt / funclet call rebuilds, cleanupret / catchswitch rebuilds), the CloneAndPrune simplification keep
  VMap[OrigV] = V for an erased instruction (WeakTrackingVH), and the store-to-load forwarding RAUW with metadata.
  AutoUpgrade's builder (`builder_insert`) adopts the same way (an upgraded `llvm.lifetime.start` ends up after the
  `#dbg_assign` upgraded from the intrinsic in front of the old call).
- findDbgUsers: the DIArgLists containing the value are visited in **ascending** tracking order (fixed 2026-11;
  `debugify,instcombine` 14 -> 4 differs). Remaining `debugify,instcombine` differs: select debug locations
  (2005-04-07-UDivSelectCrash, binop-cast, binop-select-cast-of-select-cond) and bswap.ll; `debugify,default<O2>`:
  82 differs (not triaged).

## Pass registry gaps (L1.extra.registry-gaps; /root/jai_registry_gap, 2026-11)

**Method.** Every name in `lib/Passes/PassRegistry.def` (MODULE/CGSCC/FUNCTION/LOOP/LOOPNEST passes, analyses as
`require<name>`, *_WITH_PARAMS, the *_CALLBACK pipeline names, alias analyses as `-aa-pipeline=`) and the IR passes
of `lib/Target/X86/X86PassRegistry.def`, run by both opts on a trivial x86-64 module with a loop (script: a Python
loop over the .def entries; MACHINE_FUNCTION_PASS rows are MIR and left out). A name counts as a gap when LLVM's opt
accepts it and ours says "unknown pass name". Before: **159 gaps** (of 462 IR names). After this work: **58**, all
excluded, owned by another agent, or listed under "still to port" below; LLVM itself rejects 31 names on that
module without extra arguments (`default<O#>` etc. need parameters, `function-import` a summary file), checked
separately.

**Where.** `src/registry_gaps.jai` holds `GAP_PASS_TABLE` (rows appended to `pass_table` by `lookup_pass`, with a
`Gap_Kind` per row in `pass_gap_kinds`) and the `gap_run_module/function/loop/cgscc` dispatch behind four Pass_Kind
values (GAP_MODULE, GAP_FUNCTION, GAP_LOOP, GAP_CGSCC), so passes.jai only got a handful of lines. Names registered
at several levels (`print`, `invalidate<all>`, `require<pass-instrumentation>`, `trigger-verifier-error`,
`require<verify>`) are looked up with `lookup_pass_at(name, levels...)` in each parse_*_pass. Parametrized gap
names (`*-callbacks<O#>`, `function-simplification<O#>`, `instcount<pre-opt>`) are matched by the longest row name
that prefixes `name<`.

**Ported (LLVM file, lines):**
- Pass-manager names: the 11 extension-point callbacks (opt registers none: no-ops, with LLVM's opt-level parsing),
  `require<>` of no-op / marker analyses (no-op-*, pass-instrumentation, fam-proxy, callgraph, inline-advisor,
  ir-similarity, immutable-module-summary, runtime-libcall-info, collector-metadata, access-info, ephemerals,
  should-run-extra-*, ssp-layout, uniformity, static-data-profile-info, ddg, function-level verify),
  `invalidate<all>` (module / cgscc / function), `no-op-loopnest` (a loop-nest pass: top-level loops only),
  `extra-vector-passes` (empty from text), `function-simplification<O1-3>` (expanded at parse time),
  `inliner-wrapper-no-mandatory-first`, count-visits, instcount (statistics only), helloworld (18),
  trigger-crash-*, function-level trigger-verifier-error.
- IR printers `print` at module / function / loop level (IRPrintingPasses.cpp 78, LoopInfo.cpp printLoop).
  Printing a function is Value::print: ShouldInitializeAllMetadata, which numbers every function's *metadata* but
  not their call-site attribute groups (printer.jai `process_function(md_only)`; the verifier's slot tracker had
  the same bug and is fixed too).
- print<cfg-sccs> (CFGSCCPrinter.cpp 34), print<domfrontier> (DominanceFrontier.cpp 93 + Impl.h; see below),
  print<module-debuginfo> (ModuleDebugInfoPrinter.cpp 141 + DebugInfoFinder in debug_info_finder.jai),
  print<inline-cost> (InlineCost.cpp annotation writer: InstructionCostDetailMap in inline_cost.jai; the printer's
  analyzer has an ORE, so ComputeFullInlineCost is on, and no GetBFI), print<uniformity> (no target we support has
  branch divergence), print<inline-advisor> ("No Inline Advisor"; a cached advisor fails loudly).
- strip-gc-relocates (StripGCRelocates.cpp 80), flatten-cfg (FlattenCFGPass.cpp 106 + Utils/FlattenCFG.cpp 525),
  assume-builder / assume-simplify (AssumeBundleBuilder.cpp 562: salvageKnowledge now takes the DT too),
  lower-emutls (LowerEmuTLS.cpp 173: the new-PM pass lowers every thread_local global, it never asks
  useEmulatedTLS), dwarf-eh-prepare (DwarfEHPrepare.cpp 433, incl. pruneUnreachableResumes at
  -codegen-opt-level>0), sjlj-eh-prepare (SjLjEHPrepare.cpp 525), gc-lowering (GCRootLowering.cpp, IR part) with
  collector-metadata (unknown GC strategies are a fatal error like LLVM's), shadow-stack-gc-lowering
  (ShadowStackGCLowering.cpp 426).
- llc's codegen IR passes as opt passes: x86-partial-reduction (full port, cg_x86_partial_reduction.jai),
  x86-lower-amx-type / inline-asm-prepare (llc's guards: loud only where LLVM would change the IR).
- Passes that are provably no-ops on x86-64 and without a target, registered with the reason in a comment:
  loop-data-prefetch (TTI cache line size 0), loop-idiom-vectorize (needs scalable vectors), complex-deinterleaving
  (X86TargetLowering doesn't support it), x86-lower-amx-intrinsics (-enable-x86-scalar-amx off), rewrite-symbols
  (no -rewrite-map-file), static-data-annotator (loud with a profile summary), cfguard (loud with the "cfguard"
  module flag = Enabled), x86-winehstate (loud for funclet personalities with EH pads).
- X86PassRegistry.def names fail as "unknown pass name" without an x86 triple, like LLVM (no TargetMachine).

**Landed by other agents while this ran:** print<stack-lifetime><may|must> (extras_b; my copy was dropped),
replace-with-veclib (jai_tails/L1.vectorize.loop; mine was dropped in the rebase), the utility and analysis-misc
units, ctx-instr-gen/lower and noinline-nonprevailing (pgo).

**Address order (fails loudly, NOTES "Heap/pointer address order"):** print<domfrontier> prints a
`std::map<BasicBlock *, ...>`: more than one entry fails unless `-domfrontier-guess-address-order` (function block
order; the frontier sets themselves are SetVectors and verified against LLVM). flatten-cfg iterates a
`SmallPtrSet<BasicBlock *, 16>` of predecessors: beyond 16 only an ambiguous LastCondBlock fails.
sjlj-eh-prepare demotes landing-pad phis from a `SmallPtrSet<PHINode *, 8>`: more than 8 fail. print<inline-cost>
prints a simplified constant with a fresh TypePrinting: an unnamed struct type prints as `%"type 0x<addr>"`, fails.

**Excluded (not portable or not x86):** MIR (mir-debugify, mir-check-debugify, mir-strip-debug, reg-usage,
print<reg-usage>, machine-function-info, free-machine-function, bb-sections-profile-reader); non-x86 targets
(dxil-*, wasm-eh-prepare, kernel-info, hipstdpar-select-accelerator-code); output contains heap addresses or
spawns a viewer (print-callgraph `<<0x...>>`, dot-callgraph, view-callgraph, print-lcg-dot, dot-cfg*, view-cfg*,
dot-dom*, view-dom*, dot-post-dom*, view-post-dom*, dot-ddg, print<ddg> "Node Address:0x..."); bitcode
(embed-bitcode, fatlto-pre-link which runs it, function-import which reads a summary file); inliner-ml-advisor-release
(not built into this LLVM).

**Owned by other agents (not touched):** lower-matrix-intrinsics, strip-debug-declare, strip-nonlinetable-debuginfo,
func-properties(-stats), stack-safety(-local), print<alias-sets>, ctx-prof-*, regions / verify<regions>,
sandbox-vectorizer, memprof-context-disambiguation, instrumentor, debug-ata / print<debug-ata>, bare
print<stack-lifetime> (LLVM defaults it to <may>; extras_b only registered the parametrized names).

**Still to port (mine, with LLVM sizes):** declare-runtime-libcalls (81 + RuntimeLibcalls.cpp 503 and the
TableGen'd RuntimeLibcalls.inc: needs a generator from `min-tblgen --gen-runtime-libcalls`, 4 x86 tests in
Transforms/Util/DeclareRuntimeLibcalls), select-optimize (1469; X86 tests CodeGen/X86/select-optimize*.ll),
typepromotion (1063; real work on x86 only for illegal integer widths), interleaved-load-combine (1373; x86 max
interleave factor 4), global-merge-func (622 + StableFunctionMap hashing), the full x86-lower-amx-type (1368),
x86-winehstate (868, i686-windows), cfguard (329) and inline-asm-prepare (268) beyond their guards, and an
llc-side switch from cg_misc_passes.jai's dwarf-eh-prepare / gc-lowering guards to the new ports.

**Sweeps (whole corpus, 10923 files unless noted; 0 differs unless noted):** print, function(print),
function(loop(print)), print<cfg-sccs>: 1 differs each, `DebugInfo/Generic/assignment-tracking/parse-and-verify/
verify.ll`, the verifier's message for an invalid #dbg_assign (also with no-op-module: not these printers);
strip-gc-relocates; flatten-cfg (also debugify,flatten-cfg and the 4 perf programs); assume-builder and
assume-builder+assume-simplify with --enable-knowledge-retention; function-simplification<O2> (0 differs, 62 loud:
SROA dbg_assign, 3 Panics in the Attributor tests and an LVI assertion on SROA/select-load.ll that are not this
pipeline's own code); dwarf-eh-prepare with -mtriple (and -codegen-opt-level=2); lower-emutls; print<inline-cost>
(1 differs: LoopVectorize/X86/int128_no_gather.ll, LLVM's '+mpx' feature warning that our subtarget creation doesn't
print); print<module-debuginfo> (7 differs fixed: M.debug_compile_units() skips NoDebug CUs), print<uniformity> (int128_no_gather.ll again), x86-partial-reduction, the no-op group, gc / sjlj.
