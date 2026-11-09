// Command-line options of passes (LLVM's cl::opt), the analysis printers' output stream, and the
// value-as-operand text helper the printers use.
import std;
import ir;
import printer;

// ---------------------------------------------------------------------------------------------
// cl::opt flags. opt.goose records every "-name[=value]" it doesn't handle itself; flag_known() decides which
// are accepted (unknown ones fail loudly, as `opt` does with "Unknown command line argument").

struct Flag { name: i32, value: i32 }
var cl_flags: Flag[>..];
var cl_mattr: u8[>..];     // -mattr (target features for the TargetTransformInfo)
var cl_mcpu: u8[>..];      // -mcpu

// Options passes read. Options that would change output in ways we don't implement are not listed, so they
// fail loudly. Options listed as no-ops change nothing we print (e.g. extra verification).
let KNOWN_FLAGS: const u8[:][] = [
    "adce-remove-loops", "adce-remove-control-flow",
    "verify-dom-info",                                   // no-op: extra verification only
    "verify-each",                                       // no-op: the verifier would only report broken IR
    "verify-loop-info", "verify-loop-lcssa",             // no-op: extra verification only
    "simplifycfg-require-and-preserve-domtree",          // read by simplifycfg
    "bonus-inst-threshold", "keep-loops", "switch-range-to-icmp", "switch-to-lookup", "forward-switch-cond",
    "hoist-common-insts", "hoist-loads-stores-with-cond-faulting", "sink-common-insts", "speculate-unpredictables",
    "phi-node-folding-threshold", "two-entry-phi-node-folding-threshold", "simplifycfg-hoist-common",
    "simplifycfg-hoist-loads-with-cond-faulting", "simplifycfg-hoist-stores-with-cond-faulting",
    "hoist-loads-stores-with-cond-faulting-threshold", "simplifycfg-hoist-common-skip-limit",
    "simplifycfg-sink-common", "simplifycfg-hoist-cond-stores", "simplifycfg-merge-cond-stores",
    "simplifycfg-merge-cond-stores-aggressively", "speculate-one-expensive-inst", "max-speculation-depth",
    "simplifycfg-max-small-block-size", "simplifycfg-branch-fold-threshold",
    "simplifycfg-branch-fold-common-dest-vector-multiplier", "simplifycfg-merge-compatible-invokes",
    "max-switch-cases-per-result", "max-jump-threading-live-blocks",
    "jump-threading-threshold", "jump-threading-implication-search-threshold",   // read by jump-threading
    "jump-threading-phi-threshold", "jump-threading-across-loop-headers",
    "max-phi-entries-increase-after-removing-empty-block",   // read by simplifycfg (Local.cpp)
    "sroa-skip-mem2reg",                                 // read by sroa
    "aa-pipeline",                                       // the AAManager pipeline (aa.goose)
    "print-all-alias-modref-info", "print-no-aliases", "print-may-aliases", "print-partial-aliases",
    "print-must-aliases", "print-no-modref", "print-ref", "print-mod", "print-modref",
    "evaluate-aa-metadata",                              // read by aa-eval
    "use-dereferenceable-at-point-semantics",            // no-op for BasicAA (only affects canBeFreed queries)
    "basic-aa-recphi", "basic-aa-separate-storage", "enable-tbaa", "enable-scoped-noalias",
    "capture-tracking-max-uses-to-explore",
    "memssa-check-limit",                                // read by MemorySSA
    "verify-memoryssa",                                  // MemorySSA verification (fails loudly; never changes output)
    "disable-licm-promotion", "licm-control-flow-hoisting", "licm-force-thread-model-single",   // read by licm
    "licm-max-num-uses-traversed", "licm-max-num-fp-reassociations", "licm-max-num-int-reassociations",
    "licm-mssa-optimization-cap", "licm-mssa-max-acc-promotion", "alias-set-saturation-threshold",
    "rotation-max-header-size", "rotation-prepare-for-lto", "enable-loop-header-duplication-at-minsize",   // loop-rotate
    "use-constant-int-for-fixed-length-splat", "use-constant-int-for-scalable-splat",   // Constants.cpp (ir.goose)
    "scalar-evolution-max-iterations", "scalar-evolution-classify-expressions",      // read by ScalarEvolution
    "scalar-evolution-max-arith-depth", "scalar-evolution-max-cast-depth", "scalar-evolution-max-add-rec-size",
    "scalar-evolution-huge-expr-threshold", "scev-addops-inline-threshold", "scev-mulops-inline-threshold",
    "scev-range-iter-threshold", "scalar-evolution-use-expensive-range-sharpening",
    "enable-knowledge-retention",                        // salvageKnowledge (knowledge.goose): dce, early-cse
    "earlycse-debug-hash",                               // no-op in release builds (see earlycse.goose)
    "earlycse-mssa-optimization-cap",                    // read by early-cse<memssa>
    "verify-scev",                                       // no-op: extra verification only
    "replexitval", "indvars-post-increment-ranges", "disable-lftr", "indvars-predicate-loops",   // indvars
    "indvars-predicate-loop-traps", "indvars-widen-indvars", "scev-cheap-expansion-budget",
    "scalar-evolution-use-context-for-no-wrap-flag-inference",
    "enable-scalar-pre", "enable-load-pre", "enable-load-in-loop-pre", "enable-split-backedge-in-load-pre",   // gvn
    "enable-gvn-memdep", "enable-gvn-memoryssa", "gvn-max-num-deps", "gvn-max-block-speculations",
    "gvn-max-num-visited-insts", "gvn-max-num-insns", "gvn-scan-users-limit", "gvn-add-phi-translation",
    "memdep-block-scan-limit", "memdep-block-number-limit", "memdep-cache-global-limit",   // MemoryDependence
    "disable-basic-aa",                                  // no-op: only read by the legacy AAResultsWrapperPass
    "verify-analysis-invalidation",                      // no-op: extra verification only
    "instcombine-code-sinking", "instcombine-max-sink-users", "instcombine-negator-enabled",   // read by instcombine
    "instcombine-negator-max-depth", "instcombine-lower-dbg-declare", "disable-last-run-tracking",
    "debugify-quiet", "debugify-level", "debugify-atoms",   // read by debugify / check-debugify
    "enable-debugify", "debugify-each", "strip-debug",      // opt driver options (debugify.goose)
    "enable-double-float-shrink", "optimize-hot-cold-new", "optimize-existing-hot-cold-new",   // LibCallSimplifier
    "optimize-nobuiltin-hot-cold-new-new", "cold-new-hint-value", "notcold-new-hint-value", "hot-new-hint-value",
    "ambiguous-new-hint-value",
    "enable-dse-partial-overwrite-tracking", "enable-dse-partial-store-merging", "dse-memoryssa-scanlimit",   // dse
    "dse-memoryssa-walklimit", "dse-memoryssa-partial-store-limit", "dse-memoryssa-defs-per-block-limit",
    "dse-memoryssa-samebb-cost", "dse-memoryssa-otherbb-cost", "dse-memoryssa-path-check-limit",
    "dse-optimize-memoryssa", "enable-dse-initializes-attr-improvement", "dse-max-dom-cond-depth",
    "enable-memcpyopt-without-libcalls",                 // memcpyopt
    "reassociate-use-cse-local",                         // reassociate
    "run-twice",                                         // no-op: optdriver.cpp only reads it on the legacy-PM path
    "goose-ic-lenient",
    "goose-scev-trace",                                  // development only: ScalarEvolution value map events                                  // development only: unported InstCombine visitors do nothing
];

// Flags whose non-default value is not supported (checked before the pipeline runs).
fn flags_check_unsupported() {
}

fn flag_known(name: const u8[:]) -> bool {
    for k in KNOWN_FLAGS { if k == name { return true; } }
    return false;
}

fn flag_set(name: const u8[:], value: const u8[:]) {
    cl_flags.push(Flag { name: intern(name), value: intern(value) });
}

// cl::opt<bool>: absent -> dflt; "-x" -> true; "-x=true/1/false/0".
fn flag_bool(name: const u8[:], dflt: bool) -> bool {
    var r = dflt;
    for f in cl_flags {
        if sbytes(f.name) != name { continue; }
        let v = sbytes(f.value);
        if v == "" || v == "true" || v == "1" || v == "TRUE" || v == "True" { r = true; }
        else if v == "false" || v == "0" || v == "FALSE" || v == "False" { r = false; }
        else { fatal(str("opt: for the --", name, " option: '", v, "' is invalid value for boolean argument!")); }
    }
    return r;
}

// cl::opt<std::string>: the last value given, "" when absent
fn flag_str(name: const u8[:]) -> const u8[:] {
    var r: i32 = -1;
    for f in cl_flags { if sbytes(f.name) == name { r = f.value; } }
    if r < 0 { return ""; }
    return sbytes(r);
}

// cl::opt::getNumOccurrences() > 0
fn flag_given(name: const u8[:]) -> bool {
    for f in cl_flags { if sbytes(f.name) == name { return true; } }
    return false;
}

fn flag_int(name: const u8[:], dflt: i64) -> i64 {
    var r = dflt;
    for f in cl_flags {
        if sbytes(f.name) != name { continue; }
        let v, ok = parse_int(sbytes(f.value));
        if !ok { fatal(str("opt: for the --", name, " option: '", sbytes(f.value), "' value invalid for integer argument!")); }
        r = v;
    }
    return r;
}

// ---------------------------------------------------------------------------------------------
// errs(): analysis printers write here; opt flushes it to stderr at exit.

var errbuf: u8[>..];

fn errs(s: const u8[:]) { errbuf.append(s); }
fn errs_int(v: i64) { format(errbuf, v); }
fn errs_u64(v: u64) { format_u64_dec(errbuf, v); }
fn errs_hex(v: u64) {
    if v == 0 { errbuf.push('0'); return; }
    var buf: u8[16] = [0; 16];
    var n = 0;
    var x = v;
    while x > 0 { buf[n] = "0123456789abcdef"[(x & 15) as i64]; x = x >> 4; n++; }
    while n > 0 { n--; errbuf.push(buf[n]); }
}

// ---------------------------------------------------------------------------------------------
// Value::printAsOperand / Instruction::print into errbuf. LLVM builds a ModuleSlotTracker for the function;
// we number the module and the function with the printer's SlotTracker and undo the metadata/attribute-group
// slots the function added, so a later print_module numbers them as if this never happened.

var slots_fn: i32 = -1;
var slots_md_mark: i64 = 0;
var slots_as_mark: i64 = 0;
var slots_module_done: bool = false;

fn slots_begin(fv: i32) {
    if slots_fn == fv { return; }
    if slots_fn >= 0 { slots_end(); }
    ensure_slot_arrays();
    if !slots_module_done {
        mnext = 0;
        process_module(globs[glob_of(fv)].module);
        type_finder(globs[glob_of(fv)].module);   // TypePrinter.incorporateTypes: numbered struct types
        slots_module_done = true;
    }
    slots_md_mark = md_order.len;
    slots_as_mark = as_order.len;
    process_function(fv);
    slots_fn = fv;
}

fn slots_end() {
    if slots_fn < 0 { return; }
    purge_function();
    while md_order.len > slots_md_mark { mdslot[md_order[md_order.len - 1]] = -1; md_order.resize(md_order.len - 1); }
    while as_order.len > slots_as_mark { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
    slots_fn = -1;
}

// The IR changed: slot numbers must be recomputed before the next printout, the module's included (a pass can add
// declarations or attribute sets; LLVM numbers the module afresh for every print).
fn slots_invalidate() { slots_reset_all(); }

fn errs_operand(v: i32, fv: i32, with_type: bool) {
    slots_begin(fv);
    let mark = out.len;
    put_operand(v, with_type);
    errbuf.append(out[mark..]);
    out.resize(mark);
}

// Instruction::print (`OS << *I`): the instruction line as the module printer prints it, without the newline.
// Instruction::print uses a SlotTracker that numbers the metadata of every function (in module order) when the
// instruction is an intrinsic call with an MDNode operand (isReferencingMDNode in AsmWriter.cpp).
fn errs_referencing_md_node(iv: i32) -> bool {
    if iop(iv) != OP_CALL || !is_intrinsic_call(iv) { return false; }
    for k in nops(iv) { let o = op(iv, k); if vals[o].kind == VK_MDVAL && md_is_node(vals[o].sub) { return true; } }
    return false;
}
fn slots_begin_all_metadata(fv: i32) {
    slots_end();
    slots_begin(fv);
    slots_end();
    // module slots are done; number every function's metadata in module order
    slots_md_mark = md_order.len;
    slots_as_mark = as_order.len;
    var f = modules[globs[glob_of(fv)].module].first_func;
    while f >= 0 {
        if !func_is_decl(f) {
            let am = as_order.len;
            process_function(f);
            purge_function();
            while as_order.len > am { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
        }
        f = globs[glob_of(f)].next;
    }
    process_function(fv);
    slots_fn = fv;
}

// Instruction::print with a ModuleSlotTracker(&M) (ShouldInitializeAllMetadata), as the Verifier's Write does
fn errs_inst_module_slots(iv: i32, fv: i32) {
    slots_begin_all_metadata(fv);
    let mark = out.len;
    print_inst(iv);
    var end = out.len;
    if end > mark && out[end - 1] == '\n' { end--; }
    errbuf.append(out[mark..end]);
    out.resize(mark);
    slots_reset_all();
}

// Forget all slot numbers, the module's included (for printing before the module's metadata changes: the
// Verifier runs before UpgradeDebugInfo strips debug info).
fn slots_reset_all() {
    slots_end();
    while md_order.len > 0 { mdslot[md_order[md_order.len - 1]] = -1; md_order.resize(md_order.len - 1); }
    while as_order.len > 0 { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
    slots_md_mark = 0;
    slots_as_mark = 0;
    slots_module_done = false;
}

fn errs_inst(iv: i32, fv: i32) {
    if errs_referencing_md_node(iv) {
        slots_begin_all_metadata(fv);
        let mark = out.len;
        print_inst(iv);
        var end = out.len;
        if end > mark && out[end - 1] == '\n' { end--; }
        errbuf.append(out[mark..end]);
        out.resize(mark);
        slots_end();
        return;
    }
    slots_begin(fv);
    let mark = out.len;
    print_inst(iv);
    if iop(iv) == OP_CALL && is_gc_relocate(iv) { print_gc_relocate_comment(iv); }
    var end = out.len;
    if end > mark && out[end - 1] == '\n' { end--; }
    errbuf.append(out[mark..end]);
    out.resize(mark);
}
