// The pass manager: textual pipeline parsing, nesting adaptors, analysis caching/invalidation, opt-bisect.
// Ports llvm/lib/Passes/PassBuilder.cpp (parsePipelineText, parsePassPipeline, parseModulePass,
// parseFunctionPass, isModulePassName/isFunctionPassName/...), llvm/include/llvm/IR/PassManager.h
// (ModuleToFunctionPassAdaptor: functions in module order, declarations skipped) and llvm/lib/IR/OptBisect.cpp.
// Passes are dispatched by a match on a pass id (no function pointers); see DESIGN.md §9 "How to add a pass".
import std;
import os;
import ir;
import misc_passes;
import irutil;
import flags;
import gen_passes;
import domtree;
import anaprint;
import dce;
import adce;
import bdce;
import instsimplify;
import ic;
import mem2reg;
import sroa;
import earlycse;
import demandedbits;
import tti;
import analyses;
import loopinfo;
import cycleinfo;
import breakcrit;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import aaeval;
import memoryssa;
import aa;
import mssaupdater;
import licm;
import looprotate;
import apint;
import sccp;
import build_libcalls;
import globalsaa;
import lpm;
import tli;
import scev;
import indvars;
import loop_deletion;
import loop_instsimplify;
import loop_simplifycfg;
import loop_idiom;
import laa;
import lle;
import loop_versioning;
import loop_distribute;
import ivusers;
import loopnest;
import simplifycfg;
import subtarget;
import debugify;
import dbgutil;
import lvi;
import cvp;
import jt;
import bpi;
import bfi;
import gvn;
import dse;
import memcpyopt;
import reassociate;
import constraint_elimination;
import aggressive_instcombine;
import vector_combine2;
import slp;
import lcg;
import cgscc;
import inliner;
import function_attrs;
import psi;
import loop_unroll_pass;
import lv_pass;
import simple_loop_unswitch_nt;
import ipo_globals;
import ipo_args;
import globalopt;

// ---------------------------------------------------------------------------------------------
// Pass ids. Add a new pass: an id here, a row in PASS_TABLE, a case in run_function_pass (or
// run_module_pass), and the analyses it preserves.

let P_NONE = 0;
// module passes
let P_VERIFY_MODULE = 1;
let P_NOOP_MODULE = 2;
let P_IPSCCP = 3;          // arg: 1 = func-spec
let P_REQUIRE_GLOBALS_AA = 5;
let P_INVALIDATE_GLOBALS_AA = 6;
let P_DEBUGIFY = 7;
let P_CHECK_DEBUGIFY = 8;
let P_INFERATTRS = 9;
let P_PRINT_LCG = 10;
let P_PRINT_LCG_DOT = 11;
let P_ALWAYS_INLINE = 12;
let P_MODULE_INLINE = 13;
let P_INLINER_WRAPPER = 14;     // arg: 1 = inliner-wrapper-no-mandatory-first
let P_RPO_FUNCTION_ATTRS = 15;
let P_REQUIRE_PSI = 16;         // require<profile-summary>
let P_INVALIDATE_PSI = 17;
let P_REQUIRE_LCG = 18;
let P_INVALIDATE_LCG = 19;
let P_NORECURSE_LTO = 20;
let P_STRIP_DEAD_PROTOTYPES = 21;
let P_ELIM_AVAIL_EXTERN = 22;
let P_CONSTMERGE = 23;
let P_GLOBALDCE = 24;           // arg: 1 = vfe-linkage-unit-visibility (InLTOPostLink)
let P_GLOBALOPT = 25;
let P_DEADARGELIM = 26;
let P_DEADARGHAX = 27;          // deadarghaxor (DeadArgumentEliminationSAPass)
let P_INTERNALIZE = 28;
let P_ASSIGN_GUID = 29;
// CGSCC passes
let P_FUNCTION_ATTRS = 300;     // arg: 1 = skip-non-recursive-function-attrs
let P_INLINE = 301;             // arg: 1 = only-mandatory
let P_NOOP_CGSCC = 302;         // also require<no-op-cgscc>
let P_CG_INVALIDATE = 303;      // invalidate<no-op-cgscc>
let P_ARGPROMOTION = 304;
// function passes
let P_DCE = 100;
let P_REDUNDANT_DBG_INST_ELIM = 120;
let P_ADCE = 101;
let P_BDCE = 102;
let P_PRINT_DOMTREE = 103;
let P_PRINT_POSTDOMTREE = 104;
let P_PRINT_DEMANDED_BITS = 105;
let P_REQUIRE = 106;        // require<analysis>: params = analysis id
let P_INVALIDATE = 107;     // invalidate<analysis>
let P_NOOP_FUNCTION = 108;
let P_VERIFY_FUNCTION = 109;
let P_MEM2REG = 130;
let P_SROA = 131;          // arg: 1 = preserve-cfg, 2 = aggregate-to-vector
let P_INSTSIMPLIFY = 140;
let P_SIMPLIFYCFG = 141;   // arg: index into scf_opt_table
let P_INSTCOMBINE = 175;   // arg: bit 0 = verify-fixpoint, bits 1.. = max-iterations
let P_BREAK_CRIT_EDGES = 110;
let P_PRINT_LOOPS = 111;
let P_PRINT_CYCLES = 112;
let P_VERIFY_CYCLES = 113;
let P_VERIFY_DOMTREE = 114;
let P_VERIFY_LOOPS = 115;
let P_LOOP_SIMPLIFY = 116;
let P_LCSSA = 117;
let P_AA_EVAL = 150;
let P_PRINT_MEMORYSSA = 151;      // arg 1: no-ensure-optimized-uses
let P_PRINT_MEMORYSSA_WALKER = 152;
let P_VERIFY_MEMORYSSA = 153;
let P_SCCP = 160;
let P_EARLY_CSE = 170;     // arg: 1 = memssa
let P_GVN = 171;           // arg: gvn<...> options (gvn.goose gvn_opt)
let P_DSE = 190;
let P_MEMCPYOPT = 191;
let P_PRINT_ACCESS_INFO = 195;   // arg: AllowPartial
let P_LOOP_LOAD_ELIM = 196;
let P_LOOP_VERSIONING = 197;
let P_LOOP_DISTRIBUTE = 198;
let P_REASSOCIATE = 260;
let P_CONSTRAINT_ELIMINATION = 261;
let P_AGGRESSIVE_INSTCOMBINE = 262;
let P_VECTOR_COMBINE = 420;
let P_SLP_VECTORIZER = 421;
let P_LOOP_VECTORIZE = 422;    // arg: bit 0 = interleave-forced-only, bit 1 = vectorize-forced-only
let P_PRINT_SCEV = 118;
let P_PRINT_LVI = 180;
let P_CVP = 181;
let P_JUMP_THREADING = 182;  // arg: threshold + 1 (0 = default)
let P_PRINT_BPI = 183;
let P_PRINT_BFI = 184;
let P_PRINT_COST_MODEL = 185;
let P_VERIFY_SCEV = 119;
// loop passes
let P_PRINT_LOOPNEST = 200;
let P_NOOP_LOOP = 201;
let P_PRINT_LOOP = 202;
let P_LREQUIRE = 203;      // require<analysis> in a loop pipeline (arg = analysis id; none are cached)
let P_LINVALIDATE = 204;
let P_LOOP_ROTATE = 206;   // arg: bit 0 = header-duplication, 1 = prepare-for-lto, 2 = check-exit-count
let P_LICM = 205;          // arg: bit 0 = AllowSpeculation, bit 1 = lnicm (a loop-nest pass)
let P_INDVARS = 207;
let P_LOOP_DELETION = 210;
let P_LOOP_INSTSIMPLIFY = 211;
let P_LOOP_SIMPLIFYCFG = 212;
let P_LOOP_IDIOM = 213;
let P_PRINT_IV_USERS = 208;
let P_LOOP_UNROLL = 290;      // function pass; arg: index into lu_opt_table
let P_LOOP_UNROLL_FULL = 291; // loop pass
let P_SIMPLE_LOOP_UNSWITCH = 292;  // loop pass; arg: bit 0 = nontrivial, bit 1 = trivial

// "<level>:<name>:<id>:<required>" — level m/f; required passes are not counted by -opt-bisect-limit
// (PassInfoMixin::isRequired: printers, verifier, require/invalidate, adaptors).
let PASS_TABLE: const u8[:][] = [
    "m:verify:1:1",
    "m:no-op-module:2:0",
    "m:debugify:7:0",
    "m:check-debugify:8:0",
    "m:inferattrs:9:0",
    "m:print-lcg:10:1",
    "m:print-lcg-dot:11:1",
    "m:always-inline:12:1",
    "m:module-inline:13:0",
    "m:inliner-wrapper:14:0",
    "m:rpo-function-attrs:15:0",
    "m:norecurse-lto-inference:20:0",
    "m:strip-dead-prototypes:21:0",
    "m:elim-avail-extern:22:0",
    "m:constmerge:23:0",
    "m:assign-guid:29:1",
    "m:deadargelim:26:0",
    "m:globalopt:25:0",
    "f:reassociate:260:0",
    "f:constraint-elimination:261:0",
    "f:aggressive-instcombine:262:0",
    "f:vector-combine:420:0",
    "f:slp-vectorizer:421:0",
    "f:loop-vectorize:422:0",
    "f:dce:100:0",
    "f:redundant-dbg-inst-elim:120:0",
    "f:adce:101:0",
    "f:bdce:102:0",
    "f:print<domtree>:103:1",
    "f:print<postdomtree>:104:1",
    "f:print<demanded-bits>:105:1",
    "f:print<cost-model>:185:1",
    "f:no-op-function:108:0",
    "f:verify:109:1",
    "f:mem2reg:130:0",
    "f:instsimplify:140:0",
    "f:break-crit-edges:110:0",
    "f:print<loops>:111:1",
    "f:print<cycles>:112:1",
    "f:verify<cycles>:113:1",
    "f:verify<domtree>:114:1",
    "f:verify<loops>:115:1",
    "f:loop-simplify:116:0",
    "f:lcssa:117:0",
    "f:aa-eval:150:0",
    "f:print<memoryssa-walker>:152:1",
    "f:verify<memoryssa>:153:1",
    "f:sccp:160:0",
    "f:dse:190:0",
    "f:memcpyopt:191:0",
    "f:print<scalar-evolution>:118:1",
    "f:verify<scalar-evolution>:119:1",
    "f:print<lazy-value-info>:180:1",
    "f:correlated-propagation:181:0",
    "f:jump-threading:182:0",
    "f:print<branch-prob>:183:1",
    "f:print<block-freq>:184:1",
    "f:loop-load-elim:196:0",
    "f:loop-versioning:197:0",
    "f:loop-distribute:198:0",
    "l:print<loopnest>:200:1",
    "l:no-op-loop:201:0",
    "l:indvars:207:0",
    "l:loop-deletion:210:0",
    "l:loop-instsimplify:211:0",
    "l:loop-simplifycfg:212:0",
    "l:loop-idiom:213:0",
    "l:print<iv-users>:208:1",
    "l:loop-unroll-full:291:0",
];

// LLVM pass class names, for -opt-bisect-limit messages.
fn pass_class_name(p: i64) -> const u8[:] {
    match p {
        P_DCE => "DCEPass",
        P_REDUNDANT_DBG_INST_ELIM => "RedundantDbgInstEliminationPass",
        P_ADCE => "ADCEPass",
        P_BDCE => "BDCEPass",
        P_MEM2REG => "PromotePass",
        P_SROA => "SROAPass",
        P_INSTSIMPLIFY => "InstSimplifyPass",
        P_SIMPLIFYCFG => "SimplifyCFGPass",
        P_INSTCOMBINE => "InstCombinePass",
        P_BREAK_CRIT_EDGES => "BreakCriticalEdgesPass",
        P_LOOP_SIMPLIFY => "LoopSimplifyPass",
        P_LCSSA => "LCSSAPass",
        P_AA_EVAL => "AAEvaluator",
        P_SCCP => "SCCPPass",
        P_EARLY_CSE => "EarlyCSEPass",
        P_CVP => "CorrelatedValuePropagationPass",
        P_JUMP_THREADING => "JumpThreadingPass",
        P_GVN => "GVNPass",
        P_DSE => "DSEPass",
        P_MEMCPYOPT => "MemCpyOptPass",
        P_LOOP_LOAD_ELIM => "LoopLoadEliminationPass",
        P_LOOP_VERSIONING => "LoopVersioningPass",
        P_LOOP_DISTRIBUTE => "LoopDistributePass",
        P_REASSOCIATE => "ReassociatePass",
        P_CONSTRAINT_ELIMINATION => "ConstraintEliminationPass",
        P_AGGRESSIVE_INSTCOMBINE => "AggressiveInstCombinePass",
        P_VECTOR_COMBINE => "VectorCombinePass",
        P_SLP_VECTORIZER => "SLPVectorizerPass",
        P_LOOP_VECTORIZE => "LoopVectorizePass",
        P_IPSCCP => "IPSCCPPass",
        P_DEBUGIFY => "NewPMDebugifyPass",
        P_CHECK_DEBUGIFY => "NewPMCheckDebugifyPass",
        P_INFERATTRS => "InferFunctionAttrsPass",
        P_NOOP_MODULE => "NoOpModulePass",
        P_NOOP_FUNCTION => "NoOpFunctionPass",
        P_FUNCTION_ATTRS => "PostOrderFunctionAttrsPass",
        P_INLINE => "InlinerPass",
        P_ARGPROMOTION => "ArgumentPromotionPass",
        P_NOOP_CGSCC => "NoOpCGSCCPass",
        P_ALWAYS_INLINE => "AlwaysInlinerPass",
        P_MODULE_INLINE => "ModuleInlinerPass",
        P_INLINER_WRAPPER => "ModuleInlinerWrapperPass",
        P_RPO_FUNCTION_ATTRS => "ReversePostOrderFunctionAttrsPass",
        P_NORECURSE_LTO => "NoRecurseLTOInferencePass",
        P_STRIP_DEAD_PROTOTYPES => "StripDeadPrototypesPass",
        P_ELIM_AVAIL_EXTERN => "EliminateAvailableExternallyPass",
        P_CONSTMERGE => "ConstantMergePass",
        P_GLOBALDCE => "GlobalDCEPass",
        P_GLOBALOPT => "GlobalOptPass",
        P_DEADARGELIM => "DeadArgumentEliminationPass",
        P_DEADARGHAX => "DeadArgumentEliminationSAPass",
        P_INTERNALIZE => "InternalizePass",
        P_ASSIGN_GUID => "AssignGUIDPass",
        P_PRINT_LCG => "LazyCallGraphPrinterPass",
        P_LOOP_UNROLL => "LoopUnrollPass",
        _ => mp_class_name(p),
    }
}

// Analyses: ids and preserved sets are in analyses.goose.

fn analysis_id(name: const u8[:]) -> i64 {
    if name == "domtree" { return A_DOMTREE; }
    if name == "postdomtree" { return A_POSTDOMTREE; }
    if name == "demanded-bits" { return A_DEMANDED_BITS; }
    if name == "verify" { return A_VERIFY; }
    if name == "loops" { return A_LOOPS; }
    if name == "cycles" { return A_CYCLES; }
    if name == "memoryssa" { return A_MEMORYSSA; }
    if name == "aa" { return A_AA; }
    if name == "scalar-evolution" { return A_SCEV; }
    if name == "target-ir" { return A_TARGET_IR; }
    if name == "opt-remark-emit" { return A_ORE; }
    if name == "lazy-value-info" { return A_LVI; }
    if name == "branch-prob" { return A_BPI; }
    if name == "block-freq" { return A_BFI; }
    if name == "phi-values" { return A_PHI_VALUES; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Pipeline tree (PassBuilder::PipelineElement)

let PK_MODULE = 0;      // module(...) pass manager
let PK_FUNCTION = 1;    // function(...) adaptor
let PK_LOOP = 2;
let PK_CGSCC = 3;
let PK_PASS = 4;
let PK_LPM = 5;         // a nested loop(...) inside a loop pipeline (LoopPassManager)
let PK_CGSCC_PM = 6;    // a nested cgscc(...) CGSCC pass manager
let PK_DEVIRT = 7;      // devirt<N>(...): arg = N, children = the nested CGSCC pass manager
let PK_CGFN = 8;        // CGSCCToFunctionPassAdaptor: arg bit 0 eager-inv, bit 1 no-rerun; pass 1 = a function(...) manager

struct PNode { kind: u8, pass: i32, arg: i32, required: bool, name: i32, first: i32, next: i32 }
var pnodes: PNode[>..];

// Raw parse tree (parsePipelineText): elements with names and inner pipelines.
struct PElem { name: i32, first: i32, next: i32 }
var pelems: PElem[>..];

fn perr_pipeline(msg: const u8[:]) {
    write_stderr(str("opt: ", msg, "\n"));
    exit(1);
}

// parsePipelineText; returns the first element of the top-level list (-1 on error).
fn parse_pipeline_text(text: const u8[:]) -> i32 {
    var stack: i32[>..<] = [];      // per level: index of the last element pushed (-1 if none), parent element
    var parents: i32[>..<] = [];
    stack.push(-1);
    parents.push(-1);
    var first_top: i32 = -1;
    var pos: i64 = 0;
    fn add_elem(nm: const u8[:]) -> i32 {
        let id = pelems.len as i32;
        pelems.push(PElem { name: intern(nm), first: -1, next: -1 });
        let lastk = stack.len - 1;
        let last = stack[lastk];
        if last >= 0 { pelems[last].next = id; }
        else {
            let par = parents[lastk];
            if par >= 0 { pelems[par].first = id; } else { first_top = id; }
        }
        stack[lastk] = id;
        return id;
    }
    loop {
        var e = pos;
        while e < text.len && text[e] != ',' && text[e] != '(' && text[e] != ')' { e++; }
        let id = add_elem(text[pos..e]);
        if e == text.len { break; }
        let sep = text[e];
        pos = e + 1;
        if sep == ',' { continue; }
        if sep == '(' { stack.push(-1); parents.push(id); continue; }
        // ')': pop greedily
        loop {
            if stack.len == 1 { return -1; }
            stack.pop();
            parents.pop();
            if pos < text.len && text[pos] == ')' { pos++; continue; }
            break;
        }
        if pos == text.len { break; }
        if text[pos] != ',' { return -1; }
        pos++;
    }
    if stack.len > 1 { return -1; }
    return first_top;
}

fn pass_row(name: const u8[:], level: u8) -> i64 {
    for row, i in PASS_TABLE {
        if row[0] != level { continue; }
        let rest = row[2..];
        var c = rest.len - 1;
        // name is everything up to the ':' before the id
        var k: i64 = 0;
        var colons = 0;
        var end1: i64 = -1;
        while k < rest.len { if rest[k] == ':' { colons++; if colons == 1 { end1 = k; } } k++; }
        if rest[..end1] == name { return i; }
    }
    return -1;
}

fn row_id(i: i64) -> i32 {
    let row = PASS_TABLE[i];
    var parts = 0;
    var k: i64 = 0;
    var st: i64 = 0;
    var id: i64 = 0;
    while k <= row.len {
        if k == row.len || row[k] == ':' {
            if parts == 2 { let v, ok = parse_int(row[st..k]); id = v; }
            parts++;
            st = k + 1;
        }
        k++;
    }
    return id as i32;
}
fn row_required(i: i64) -> bool { let row = PASS_TABLE[i]; return row[row.len - 1] == '1'; }

// PassBuilder::checkParametrizedPassName
fn is_param_name(name: const u8[:], base: const u8[:]) -> bool {
    if !starts_with(name, base) { return false; }
    let rest = name[base.len..];
    if rest.len == 0 { return true; }
    return rest[0] == '<' && rest[rest.len - 1] == '>';
}

// Is `name` known to LLVM at level tag ('m', 'c', 'f', 'l', 'n')?
fn llvm_knows(name: const u8[:], level: u8) -> bool {
    for e in LLVM_PASS_NAMES {
        if e[0] != level { continue; }
        var c: i64 = 1;
        var kind: u8 = 0;   // 0 plain, 'p' params, 'a' analysis
        if e[1] != ':' { kind = e[1]; c = 2; }
        let nm = e[c + 1..];
        if kind == 0 && name == nm { return true; }
        if kind == 'p' && is_param_name(name, nm) { return true; }
        if kind == 'a' {
            if starts_with(name, "require<") || starts_with(name, "invalidate<") {
                let lt = find(name, "<");
                if name[lt + 1..name.len - 1] == nm && name[name.len - 1] == '>' { return true; }
            }
        }
    }
    return false;
}

fn name_no_bracket(name: const u8[:]) -> const u8[:] {
    let k = find(name, "<");
    return if k < 0 { name } else { name[..k] };
}

fn is_module_pass_name(name: const u8[:]) -> bool {
    if name == "module" || name == "cgscc" || name_no_bracket(name) == "function" || name == "coro-cond" { return true; }
    if starts_with(name, "default<") || starts_with(name, "thinlto-pre-link<") || starts_with(name, "thinlto<") ||
       starts_with(name, "lto-pre-link<") || starts_with(name, "lto<") || starts_with(name, "fatlto-pre-link<") { return true; }
    return llvm_knows(name, 'm');
}
fn is_cgscc_pass_name(name: const u8[:]) -> bool {
    if name == "cgscc" || name_no_bracket(name) == "function" { return true; }
    if starts_with(name, "devirt<") { return true; }
    return llvm_knows(name, 'c');
}
fn is_function_pass_name(name: const u8[:]) -> bool {
    if name_no_bracket(name) == "function" || name == "loop" || name == "loop-mssa" || name == "machine-function" { return true; }
    return llvm_knows(name, 'f');
}
fn is_loop_pass_name(name: const u8[:]) -> bool { llvm_knows(name, 'l') || llvm_knows(name, 'n') || is_param_name(name, "licm") || is_param_name(name, "lnicm") }

fn new_pnode(kind: i64, pass: i32, arg: i32, required: bool, name: i32) -> i32 {
    let id = pnodes.len as i32;
    pnodes.push(PNode { kind: kind as u8, pass: pass, arg: arg, required: required, name: name, first: -1, next: -1 });
    return id;
}

fn not_implemented(name: const u8[:]) {
    perr_pipeline(str("pass '", name, "' is not implemented yet in the Goose opt"));
}

// Appends child `c` to the node list whose last element is `last` (or as first child of parent).
fn link_child(parent: i32, last: i32, c: i32) -> i32 {
    if last >= 0 { pnodes[last].next = c; } else { pnodes[parent].first = c; }
    return c;
}

// A function-level pass element (parseFunctionPass) -> pnode.
recursive fn parse_function_elem(e: i32) -> i32 {
    let name = sbytes(pelems[e].name);
    if pelems[e].first >= 0 {
        if name_no_bracket(name) == "function" {
            let fpm = new_pnode(PK_FUNCTION, 0, 0, true, pelems[e].name);
            parse_function_list(fpm, pelems[e].first);
            return fpm;
        }
        if name == "loop" || name == "loop-mssa" {
            let ad = new_loop_adaptor(name == "loop-mssa", pelems[e].name);
            parse_loop_list(ad, pelems[e].first);
            check_loop_nest_mode(ad);
            return ad;
        }
        if name == "machine-function" { not_implemented(name); }
        perr_pipeline(str("invalid use of '", name, "' pass as function pipeline"));
    }
    if starts_with(name, "require<") || starts_with(name, "invalidate<") {
        let lt = find(name, "<");
        let an = name[lt + 1..name.len - 1];
        let a = analysis_id(an);
        if a < 0 {
            let rmid, rmarg, rmreq = mp_parse_function(name);
            if rmid >= 0 { return new_pnode(PK_PASS, rmid, rmarg, rmreq, pelems[e].name); }
            if llvm_knows(name, 'f') { not_implemented(name); }
            perr_pipeline(str("unknown function pass '", name, "'"));
        }
        let p: i32 = if starts_with(name, "require<") { P_REQUIRE as i32 } else { P_INVALIDATE as i32 };
        return new_pnode(PK_PASS, p, a as i32, true, pelems[e].name);
    }
    if is_param_name(name, "print<access-info>") {
        var arg: i32 = 0;
        if name != "print<access-info>" {
            let ps = name[19..name.len - 1];
            if ps == "allow-partial" { arg = 1; }
            else { perr_pipeline(str("invalid LoopAccessInfoPrinterPass pass parameter '", ps, "'")); }
        }
        return new_pnode(PK_PASS, P_PRINT_ACCESS_INFO as i32, arg, true, pelems[e].name);
    }
    if is_param_name(name, "print<memoryssa>") {
        var arg: i32 = 0;
        if name != "print<memoryssa>" {
            let ps = name[17..name.len - 1];
            if ps == "no-ensure-optimized-uses" { arg = 1; }
            else { perr_pipeline(str("invalid MemorySSAPrinterPass parameter '", ps, "' ")); }
        }
        return new_pnode(PK_PASS, P_PRINT_MEMORYSSA as i32, arg, true, pelems[e].name);
    }
    if is_param_name(name, "gvn") {
        // parseGVNOptions: bits 2k (set) and 2k+1 (value); k: 0 scalar-pre, 1 load-pre, 2 split-backedge-load-pre,
        // 3 memdep, 4 memoryssa (memdep and memoryssa set each other's opposite)
        var arg: i32 = 0;
        if name != "gvn" {
            let ps = name[4..name.len - 1];
            var st: i64 = 0;
            while st < ps.len {
                var j = st;
                while j < ps.len && ps[j] != ';' { j++; }
                var pn = ps[st..j];
                st = j + 1;
                var en: i32 = 1;
                if starts_with(pn, "no-") { en = 0; pn = pn[3..]; }
                if pn == "scalar-pre" { arg = (arg & ~3) | 1 | (en << 1); }
                else if pn == "load-pre" { arg = (arg & ~12) | 4 | (en << 3); }
                else if pn == "split-backedge-load-pre" { arg = (arg & ~48) | 16 | (en << 5); }
                else if pn == "memdep" { arg = (arg & ~960) | 64 | (en << 7) | 256 | ((1 - en) << 9); }
                else if pn == "memoryssa" { arg = (arg & ~960) | 256 | (en << 9) | 64 | ((1 - en) << 7); }
                else { perr_pipeline(str("invalid GVN pass parameter '", pn, "'")); }
            }
        }
        return new_pnode(PK_PASS, P_GVN as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "early-cse") {
        // parseEarlyCSEPassOptions: parseSinglePassOption(Params, "memssa", "EarlyCSE")
        var arg: i32 = 0;
        if name != "early-cse" {
            let ps = name[10..name.len - 1];
            var st: i64 = 0;
            while st < ps.len {
                var j = st;
                while j < ps.len && ps[j] != ';' { j++; }
                let pn = ps[st..j];
                st = j + 1;
                if pn == "memssa" { arg = 1; }
                else { perr_pipeline(str("invalid EarlyCSE pass parameter '", pn, "'")); }
            }
        }
        return new_pnode(PK_PASS, P_EARLY_CSE as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "instcombine") {
        // parseInstCombineOptions: verify-fixpoint is on by default for "instcombine" in -passes
        var verify = true;
        var maxit: i64 = 1;
        if name != "instcombine" {
            let ps = name[12..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                var pn = ps[st..j];
                st = j + 1;
                var enable = true;
                if starts_with(pn, "no-") { enable = false; pn = pn[3..]; }
                if pn == "verify-fixpoint" { verify = enable; }
                else if enable && starts_with(pn, "max-iterations=") {
                    let num = pn[15..];
                    var v: i64 = 0;
                    var ok = num.len > 0;
                    for c in num { if c < '0' || c > '9' { ok = false; } else { v = v * 10 + ((c - '0') as i64); } }
                    if !ok { perr_pipeline(str("invalid argument to InstCombine pass max-iterations parameter: '", num, "'")); }
                    maxit = v;
                } else { perr_pipeline(str("invalid InstCombine pass parameter '", pn, "'")); }
            }
        }
        var arg: i32 = 0;
        if verify { arg = 1; }
        arg |= (maxit as i32) << 1;
        return new_pnode(PK_PASS, P_INSTCOMBINE as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "simplifycfg") {
        // parseSimplifyCFGOptions
        var o = scf_default_opts();
        if name != "simplifycfg" {
            let ps = name[12..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                var pn = ps[st..j];
                st = j + 1;
                var en = true;
                if starts_with(pn, "no-") { en = false; pn = pn[3..]; }
                if pn == "speculate-blocks" { o.spec_blocks = en; }
                else if pn == "simplify-cond-branch" { o.simplify_condbr = en; }
                else if pn == "forward-switch-cond" { o.fwd_switch_cond = en; }
                else if pn == "switch-range-to-icmp" { o.range_to_icmp = en; }
                else if pn == "switch-to-arithmetic" { o.to_arith = en; }
                else if pn == "switch-to-lookup" { o.to_lookup = en; }
                else if pn == "keep-loops" { o.keep_loops = en; }
                else if pn == "hoist-common-insts" { o.hoist_common = en; }
                else if pn == "hoist-loads-stores-with-cond-faulting" { o.hoist_ldst_cf = en; }
                else if pn == "sink-common-insts" { o.sink_common = en; }
                else if pn == "speculate-unpredictables" { o.spec_unpred = en; }
                else if en && starts_with(pn, "bonus-inst-threshold=") {
                    let v, ok = parse_int(pn[21..]);
                    if !ok { perr_pipeline(str("invalid argument to SimplifyCFG pass bonus-threshold parameter: '", pn[21..], "'")); }
                    o.bonus = v;
                } else { perr_pipeline(str("invalid SimplifyCFG pass parameter '", pn, "'")); }
            }
        }
        let idx = scf_opt_table.len as i32;
        scf_opt_table.push(o);
        return new_pnode(PK_PASS, P_SIMPLIFYCFG as i32, idx, false, pelems[e].name);
    }
    if is_param_name(name, "loop-vectorize") {
        // parseLoopVectorizeOptions; LoopVectorizePass(Opts): -interleave-loops / -vectorize-loops (default true)
        var ilv: bool = false;
        var vec: bool = false;
        if name != "loop-vectorize" {
            let ps = name[15..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                var pn = ps[st..j];
                st = j + 1;
                if pn.len == 0 { continue; }
                var en = true;
                if starts_with(pn, "no-") { en = false; pn = pn[3..]; }
                if pn == "interleave-forced-only" { ilv = en; }
                else if pn == "vectorize-forced-only" { vec = en; }
                else { perr_pipeline(str("invalid LoopVectorize parameter '", pn, "'")); }
            }
        }
        if !flag_bool("interleave-loops", true) { ilv = true; }
        if !flag_bool("vectorize-loops", true) { vec = true; }
        var arg: i32 = 0;
        if ilv { arg = arg | 1; }
        if vec { arg = arg | 2; }
        return new_pnode(PK_PASS, P_LOOP_VECTORIZE as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "loop-unroll") {
        // parseLoopUnrollOptions
        var o = LUOpts { opt_level: 2, only_when_forced: false, forget_scev: false, allow_partial: -1, allow_peeling: -1,
                         allow_runtime: -1, allow_upper_bound: -1, allow_profile_peeling: -1, full_unroll_max_count: -1 };
        if name != "loop-unroll" {
            let ps = name[12..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                var pn = ps[st..j];
                st = j + 1;
                if pn == "O0" || pn == "O1" || pn == "O2" || pn == "O3" { o.opt_level = (pn[1] - '0') as i64; continue; }
                if pn == "Os" || pn == "Oz" {
                    write_stderr(str("LLVM ERROR: The optimization level \"", pn, "\" is no longer supported. Use O2 in conjunction with the optsize attribute instead.\n"));
                    exit(1);
                }
                if starts_with(pn, "full-unroll-max=") {
                    let v, ok = parse_int(pn[16..]);
                    if !ok { perr_pipeline(str("invalid LoopUnrollPass parameter '", pn[16..], "'")); }
                    o.full_unroll_max_count = v & 0xFFFFFFFF;
                    continue;
                }
                var en: i64 = 1;
                if starts_with(pn, "no-") { en = 0; pn = pn[3..]; }
                if pn == "partial" { o.allow_partial = en; }
                else if pn == "peeling" { o.allow_peeling = en; }
                else if pn == "profile-peeling" { o.allow_profile_peeling = en; }
                else if pn == "runtime" { o.allow_runtime = en; }
                else if pn == "upperbound" { o.allow_upper_bound = en; }
                else { perr_pipeline(str("invalid LoopUnrollPass parameter '", pn, "'")); }
            }
        }
        let idx = lu_opt_table.len as i32;
        lu_opt_table.push(o);
        return new_pnode(PK_PASS, P_LOOP_UNROLL as i32, idx, false, pelems[e].name);
    }
    if is_param_name(name, "sroa") {
        // parseSROAOptions: default modify-cfg
        var arg: i32 = 0;
        var saw_cfg = false;
        if name != "sroa" {
            let ps = name[5..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                let pn = ps[st..j];
                st = j + 1;
                if pn == "modify-cfg" || pn == "preserve-cfg" {
                    if saw_cfg { perr_pipeline("multiple SROA CFG options specified"); }
                    saw_cfg = true;
                    if pn == "preserve-cfg" { arg |= 1; } else { arg &= ~1; }
                } else if pn == "aggregate-to-vector" { arg |= 2; }
                else { perr_pipeline(str("invalid SROA pass parameter '", pn, "' (expected preserve-cfg, modify-cfg, or aggregate-to-vector)")); }
            }
        }
        return new_pnode(PK_PASS, P_SROA as i32, arg, false, pelems[e].name);
    }
    let r = pass_row(name, 'f');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
    let mpid, mparg, mpreq = mp_parse_function(name);
    if mpid >= 0 { return new_pnode(PK_PASS, mpid, mparg, mpreq, pelems[e].name); }
    if llvm_knows(name, 'f') { not_implemented(name); }
    if is_loop_pass_name(name) {
        // LOOP_PASS / LOOPNEST_PASS in a function pipeline: its own adaptor (createFunctionToLoopPassAdaptor)
        let ad = new_loop_adaptor(false, pelems[e].name);
        pnodes[ad].first = parse_loop_elem(e);
        check_loop_nest_mode(ad);
        return ad;
    }
    perr_pipeline(str("unknown function pass '", name, "'"));
    return -1;
}

recursive fn parse_function_list(parent: i32, first: i32) {
    var last: i32 = -1;
    var e = first;
    while e >= 0 {
        let c = parse_function_elem(e);
        last = link_child(parent, last, c);
        e = pelems[e].next;
    }
}

// FunctionToLoopPassAdaptor node: pass = the first of its two canonicalization pass nodes (loop-simplify,
// then lcssa, linked by next), arg = UseMemorySSA.
fn new_loop_adaptor(mssa: bool, name: i32) -> i32 {
    let ls = new_pnode(PK_PASS, P_LOOP_SIMPLIFY as i32, 0, false, intern("loop-simplify"));
    let lc = new_pnode(PK_PASS, P_LCSSA as i32, 0, false, intern("lcssa"));
    pnodes[ls].next = lc;
    return new_pnode(PK_LOOP, ls, if mssa { 1 } else { 0 }, true, name);
}

// A loop-nest pass (LOOPNEST_PASS: lnicm)
fn is_nest_pass_node(c: i32) -> bool { pnodes[c].kind == PK_PASS as u8 && pnodes[c].pass == P_LICM as i32 && (pnodes[c].arg & 2) != 0 }
// createFunctionToLoopPassAdaptor(LPM): loop-nest mode if the LoopPassManager has no loop passes (a nested
// loop(...) manager counts as a loop pass). Kept in the adaptor's arg bit 1.
fn check_loop_nest_mode(ad: i32) {
    var c = pnodes[ad].first;
    var any_loop = false;
    while c >= 0 { if !is_nest_pass_node(c) { any_loop = true; } c = pnodes[c].next; }
    if !any_loop && pnodes[ad].first >= 0 { pnodes[ad].arg |= 2; }
}

// parseLoopPass
recursive fn parse_loop_elem(e: i32) -> i32 {
    let name = sbytes(pelems[e].name);
    if pelems[e].first >= 0 {
        if name == "loop" {
            let lpm = new_pnode(PK_LPM, 0, 0, true, pelems[e].name);
            parse_loop_list(lpm, pelems[e].first);
            return lpm;
        }
        perr_pipeline(str("invalid use of '", name, "' pass as loop pipeline"));
    }
    if name == "require<iv-users>" { return new_pnode(PK_PASS, P_LREQUIRE as i32, 1, true, pelems[e].name); }
    if starts_with(name, "require<") || starts_with(name, "invalidate<") {
        if llvm_knows(name, 'l') { not_implemented(name); }
        perr_pipeline(str("unknown loop pass '", name, "'"));
    }
    if is_param_name(name, "loop-rotate") {
        // parseLoopRotateOptions
        var arg: i32 = 1;
        let lt = find(name, "<");
        if lt >= 0 {
            let params = name[(lt as i64) + 1..name.len - 1];
            var start: i64 = 0;
            while start <= params.len {
                var end = start;
                while end < params.len && params[end] != ';' { end++; }
                var pn = params[start..end];
                var en = true;
                if starts_with(pn, "no-") { en = false; pn = pn[3..]; }
                var bit: i32 = -1;
                if pn == "header-duplication" { bit = 1; }
                else if pn == "prepare-for-lto" { bit = 2; }
                else if pn == "check-exit-count" { bit = 4; }
                else { perr_pipeline(str("invalid LoopRotate pass parameter '", pn, "'")); }
                if en { arg |= bit; } else { arg &= ~bit; }
                start = end + 1;
            }
        }
        return new_pnode(PK_PASS, P_LOOP_ROTATE as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "simple-loop-unswitch") {
        // parseLoopUnswitchOptions: {NonTrivial = false, Trivial = true}
        var arg: i32 = 2;
        let lt = find(name, "<");
        if lt >= 0 {
            let params = name[(lt as i64) + 1..name.len - 1];
            var start: i64 = 0;
            while start <= params.len {
                var end = start;
                while end < params.len && params[end] != ';' { end++; }
                var pn = params[start..end];
                var en = true;
                if starts_with(pn, "no-") { en = false; pn = pn[3..]; }
                var bit: i32 = -1;
                if pn == "nontrivial" { bit = 1; }
                else if pn == "trivial" { bit = 2; }
                else { perr_pipeline(str("invalid LoopUnswitch pass parameter '", pn, "'")); }
                if en { arg |= bit; } else { arg &= ~bit; }
                start = end + 1;
            }
        }
        return new_pnode(PK_PASS, P_SIMPLE_LOOP_UNSWITCH as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "licm") || is_param_name(name, "lnicm") {
        // parseLICMOptions
        let nest = is_param_name(name, "lnicm");
        var arg: i32 = 1;
        let lt = find(name, "<");
        if lt >= 0 {
            let params = name[(lt as i64) + 1..name.len - 1];
            var start: i64 = 0;
            while start <= params.len {
                var end = start;
                while end < params.len && params[end] != ';' { end++; }
                var pn = params[start..end];
                var en = true;
                if starts_with(pn, "no-") { en = false; pn = pn[3..]; }
                if pn == "allowspeculation" { if en { arg |= 1; } else { arg &= ~1; } }
                else { perr_pipeline(str("invalid LICM pass parameter '", pn, "'")); }
                start = end + 1;
            }
        }
        if nest { arg |= 2; }
        return new_pnode(PK_PASS, P_LICM as i32, arg, false, pelems[e].name);
    }
    let r = pass_row(name, 'l');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
    if llvm_knows(name, 'l') || llvm_knows(name, 'n') || is_param_name(name, "licm") || is_param_name(name, "lnicm") { not_implemented(name); }
    perr_pipeline(str("unknown loop pass '", name, "'"));
    return -1;
}

recursive fn parse_loop_list(parent: i32, first: i32) {
    var last: i32 = -1;
    var e = first;
    while e >= 0 {
        let c = parse_loop_elem(e);
        last = link_child(parent, last, c);
        e = pelems[e].next;
    }
}

// parseSinglePassOption for `<base><opt>` passes: 1 if the option is given
fn parse_single_option(name: const u8[:], base: const u8[:], opt: const u8[:], class: const u8[:]) -> i32 {
    if name == base { return 0; }
    let ps = name[base.len + 1..name.len - 1];
    var r: i32 = 0;
    var st: i64 = 0;
    for j in 0..ps.len + 1 {
        if j < ps.len && ps[j] != ';' { continue; }
        let pn = ps[st..j];
        st = j + 1;
        if pn == opt { r = 1; } else { perr_pipeline(str("invalid ", class, " pass parameter '", pn, "'")); }
    }
    return r;
}

// parseFunctionPipelineName: function<eager-inv;no-rerun>; -1 if the name isn't a function pipeline name
fn parse_function_pipeline_params(name: const u8[:]) -> i32 {
    if name == "function" { return 0; }
    if !is_param_name(name, "function") { return -1; }
    let ps = name[9..name.len - 1];
    var r: i32 = 0;
    var st: i64 = 0;
    for j in 0..ps.len + 1 {
        if j < ps.len && ps[j] != ';' { continue; }
        let pn = ps[st..j];
        st = j + 1;
        if pn == "eager-inv" { r |= 1; } else if pn == "no-rerun" { r |= 2; } else { return -1; }
    }
    return r;
}

// parseCGSCCPass
recursive fn parse_cgscc_elem(e: i32) -> i32 {
    let name = sbytes(pelems[e].name);
    if pelems[e].first >= 0 {
        if name == "cgscc" {
            let pm = new_pnode(PK_CGSCC_PM, 0, 0, true, pelems[e].name);
            parse_cgscc_list(pm, pelems[e].first);
            return pm;
        }
        let fp = parse_function_pipeline_params(name);
        if fp >= 0 {
            if (fp & 2) != 0 { not_implemented("function<no-rerun>"); }
            let ad = new_pnode(PK_CGFN, 1, fp, true, pelems[e].name);
            parse_function_list(ad, pelems[e].first);
            return ad;
        }
        if starts_with(name, "devirt<") && name[name.len - 1] == '>' {
            let v, ok = parse_int(name[7..name.len - 1]);
            if ok && v >= 0 {
                let dv = new_pnode(PK_DEVIRT, 0, v as i32, true, pelems[e].name);
                parse_cgscc_list(dv, pelems[e].first);
                return dv;
            }
        }
        perr_pipeline(str("invalid use of '", name, "' pass as cgscc pipeline"));
    }
    if is_param_name(name, "function-attrs") {
        let a = parse_single_option(name, "function-attrs", "skip-non-recursive-function-attrs", "PostOrderFunctionAttrs");
        return new_pnode(PK_PASS, P_FUNCTION_ATTRS as i32, a, false, pelems[e].name);
    }
    if is_param_name(name, "inline") {
        let a = parse_single_option(name, "inline", "only-mandatory", "InlinerPass");
        return new_pnode(PK_PASS, P_INLINE as i32, a, false, pelems[e].name);
    }
    if name == "argpromotion" { return new_pnode(PK_PASS, P_ARGPROMOTION as i32, 0, false, pelems[e].name); }
    if name == "no-op-cgscc" { return new_pnode(PK_PASS, P_NOOP_CGSCC as i32, 0, false, pelems[e].name); }
    if name == "require<no-op-cgscc>" { return new_pnode(PK_PASS, P_NOOP_CGSCC as i32, 0, true, pelems[e].name); }
    if name == "invalidate<no-op-cgscc>" { return new_pnode(PK_PASS, P_CG_INVALIDATE as i32, 0, true, pelems[e].name); }
    let cmid, cmarg, cmreq = mp_parse_cgscc(name);
    if cmid >= 0 { return new_pnode(PK_PASS, cmid, cmarg, cmreq, pelems[e].name); }
    if llvm_knows(name, 'c') { not_implemented(name); }
    // a function or loop pass in a CGSCC pipeline gets its own adaptor (createCGSCCToFunctionPassAdaptor)
    if is_function_pass_name(name) || is_loop_pass_name(name) || starts_with(name, "require<") || starts_with(name, "invalidate<") {
        let ad = new_pnode(PK_CGFN, 0, 0, true, pelems[e].name);
        pnodes[ad].first = parse_function_elem(e);
        return ad;
    }
    perr_pipeline(str("unknown cgscc pass '", name, "'"));
    return -1;
}

recursive fn parse_cgscc_list(parent: i32, first: i32) {
    var last: i32 = -1;
    var e = first;
    while e >= 0 {
        let c = parse_cgscc_elem(e);
        last = link_child(parent, last, c);
        e = pelems[e].next;
    }
}

// parseModulePass
recursive fn parse_module_elem(e: i32) -> i32 {
    let name = sbytes(pelems[e].name);
    if pelems[e].first >= 0 {
        if name == "module" {
            let mpm = new_pnode(PK_MODULE, 0, 0, true, pelems[e].name);
            parse_module_list(mpm, pelems[e].first);
            return mpm;
        }
        if name_no_bracket(name) == "function" {
            let fpm = new_pnode(PK_FUNCTION, 0, 0, true, pelems[e].name);
            parse_function_list(fpm, pelems[e].first);
            return fpm;
        }
        if name == "cgscc" {
            let ad = new_pnode(PK_CGSCC, 0, 0, true, pelems[e].name);
            parse_cgscc_list(ad, pelems[e].first);
            return ad;
        }
        if name == "coro-cond" { not_implemented(name); }
        perr_pipeline(str("invalid use of '", name, "' pass as module pipeline"));
    }
    if starts_with(name, "default<") || starts_with(name, "thinlto") || starts_with(name, "lto") || starts_with(name, "fatlto") {
        not_implemented(name);
    }
    if is_param_name(name, "ipsccp") {
        // parseIPSCCPOptions: func-spec / no-func-spec, default AllowFuncSpec = true
        var arg: i32 = 1;
        if name != "ipsccp" {
            let ps = name[7..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                let pn = ps[st..j];
                st = j + 1;
                if pn == "func-spec" { arg = 1; }
                else if pn == "no-func-spec" { arg = 0; }
                else { perr_pipeline(str("invalid IPSCCP pass parameter '", pn, "'")); }
            }
        }
        return new_pnode(PK_PASS, P_IPSCCP as i32, arg, false, pelems[e].name);
    }
    if name == "inliner-wrapper" || name == "inliner-wrapper-no-mandatory-first" {
        // ModuleInlinerWrapperPass: cgscc(inline<only-mandatory>, inline) (MaxDevirtIterations = 0)
        let ad = new_pnode(PK_CGSCC, 0, 0, true, pelems[e].name);
        let nm = intern("inline");
        let last = new_pnode(PK_PASS, P_INLINE as i32, 0, false, nm);
        if name == "inliner-wrapper" {
            let mand = new_pnode(PK_PASS, P_INLINE as i32, 1, false, nm);
            pnodes[ad].first = mand;
            pnodes[mand].next = last;
        } else { pnodes[ad].first = last; }
        return ad;
    }
    if is_param_name(name, "globaldce") {
        // parseGlobalDCEPassOptions: vfe-linkage-unit-visibility
        var arg: i32 = 0;
        if name != "globaldce" {
            let ps = name[10..name.len - 1];
            var st: i64 = 0;
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                let pn = ps[st..j];
                st = j + 1;
                if pn == "vfe-linkage-unit-visibility" { arg = 1; }
                else { perr_pipeline(str("invalid GlobalDCE pass parameter '", pn, "'")); }
            }
        }
        return new_pnode(PK_PASS, P_GLOBALDCE as i32, arg, false, pelems[e].name);
    }
    if is_param_name(name, "internalize") {
        // parseInternalizeGVs: preserve-gv=NAME (any number); with none, the -internalize-public-api-* lists
        var arg: i32 = -1;
        if name != "internalize" {
            let ps = name[12..name.len - 1];
            var st: i64 = 0;
            arg = ints.len as i32;
            ints.push(0);
            for j in 0..ps.len + 1 {
                if j < ps.len && ps[j] != ';' { continue; }
                let pn = ps[st..j];
                st = j + 1;
                if starts_with(pn, "preserve-gv=") { ints.push(intern(pn[12..])); ints[arg] = ints[arg] + 1; }
                else { perr_pipeline(str("invalid Internalize pass parameter '", pn, "'")); }
            }
        }
        return new_pnode(PK_PASS, P_INTERNALIZE as i32, arg, false, pelems[e].name);
    }
    let r = pass_row(name, 'm');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
    let mmid, mmarg, mmreq = mp_parse_module(name);
    if mmid >= 0 { return new_pnode(PK_PASS, mmid, mmarg, mmreq, pelems[e].name); }
    // module VerifierAnalysis: nothing to compute (no verifier yet; the harness verifies our output)
    if name == "require<verify>" || name == "invalidate<verify>" { return new_pnode(PK_PASS, P_NOOP_MODULE as i32, 0, true, pelems[e].name); }
    if name == "require<globals-aa>" { return new_pnode(PK_PASS, P_REQUIRE_GLOBALS_AA as i32, 0, true, pelems[e].name); }
    if name == "invalidate<globals-aa>" { return new_pnode(PK_PASS, P_INVALIDATE_GLOBALS_AA as i32, 0, true, pelems[e].name); }
    if name == "require<profile-summary>" { return new_pnode(PK_PASS, P_REQUIRE_PSI as i32, 0, true, pelems[e].name); }
    if name == "invalidate<profile-summary>" { return new_pnode(PK_PASS, P_INVALIDATE_PSI as i32, 0, true, pelems[e].name); }
    if name == "require<lcg>" { return new_pnode(PK_PASS, P_REQUIRE_LCG as i32, 0, true, pelems[e].name); }
    if name == "invalidate<lcg>" { return new_pnode(PK_PASS, P_INVALIDATE_LCG as i32, 0, true, pelems[e].name); }
    if llvm_knows(name, 'm') { not_implemented(name); }
    if is_cgscc_pass_name(name) {
        // a CGSCC pass in a module pipeline gets its own adaptor (createModuleToPostOrderCGSCCPassAdaptor)
        let ad = new_pnode(PK_CGSCC, 0, 0, true, pelems[e].name);
        pnodes[ad].first = parse_cgscc_elem(e);
        return ad;
    }
    // a function pass in a module pipeline gets its own adaptor (createModuleToFunctionPassAdaptor)
    if is_function_pass_name(name) || is_loop_pass_name(name) || starts_with(name, "require<") || starts_with(name, "invalidate<") {
        let fpm = new_pnode(PK_FUNCTION, 0, 0, true, pelems[e].name);
        let c = parse_function_elem(e);
        pnodes[fpm].first = c;
        return fpm;
    }
    perr_pipeline(str("unknown module pass '", name, "'"));
    return -1;
}

recursive fn parse_module_list(parent: i32, first: i32) {
    var last: i32 = -1;
    var e = first;
    while e >= 0 {
        let c = parse_module_elem(e);
        last = link_child(parent, last, c);
        e = pelems[e].next;
    }
}

// PassBuilder::parsePassPipeline(MPM, Text): returns the root module pass manager node.
fn parse_pass_pipeline(text: const u8[:]) -> i32 {
    let first = parse_pipeline_text(text);
    if first < 0 { perr_pipeline(str("invalid pipeline '", text, "'")); }
    let fname = sbytes(pelems[first].name);
    var top = first;
    if !is_module_pass_name(fname) {
        if is_cgscc_pass_name(fname) {
            let w = pelems.len as i32;
            pelems.push(PElem { name: intern("cgscc"), first: first, next: -1 });
            top = w;
        } else if is_function_pass_name(fname) {
            let w = pelems.len as i32;
            pelems.push(PElem { name: intern("function"), first: first, next: -1 });
            top = w;
        } else if is_loop_pass_name(fname) {
            let mssa = is_param_name(fname, "licm") || is_param_name(fname, "lnicm");
            let lp = pelems.len as i32;
            pelems.push(PElem { name: intern(if mssa { "loop-mssa" } else { "loop" }), first: first, next: -1 });
            let w = pelems.len as i32;
            pelems.push(PElem { name: intern("function"), first: lp, next: -1 });
            top = w;
        } else {
            let what = if pelems[first].first >= 0 { "pipeline" } else { "pass" };
            perr_pipeline(str("unknown ", what, " name '", fname, "'"));
        }
    }
    let root = new_pnode(PK_MODULE, 0, 0, true, intern("module"));
    parse_module_list(root, top);
    return root;
}

// ---------------------------------------------------------------------------------------------
// Running

var bisect_limit: i64 = -1;     // -opt-bisect-limit (-1: disabled)
var bisect_count: i64 = 0;

// OptBisect::shouldRunPass
fn should_run(n: i32, unit: const u8[:]) -> bool {
    if pnodes[n].required || bisect_limit < 0 { return true; }
    bisect_count++;
    let run = bisect_count <= bisect_limit;
    write_stderr(str("BISECT: ", if run { "" } else { "NOT " }, "running pass (", bisect_count, ") ",
        name_no_bracket(sbytes(pnodes[n].name)), " on ", unit, "\n"));
    return run;
}

// Drop analyses of fv that the pass didn't preserve.
fn invalidate_function(fv: i32, preserved: u32) {
    if preserved == PA_ALL { return; }
    // a pass that changed fv and kept its ScalarEvolution (see scev_get)
    if (preserved & (1 << A_SCEV)) != 0 && (preserved & (1 << A_DOMTREE)) != 0 && (preserved & (1 << A_LOOPS)) != 0 { scev_note_preserved_change(fv); }
    if (preserved & PA_FN) == PA_FN { return; }
    slots_invalidate();
    if (preserved & (1 << A_LRT)) == 0 { ic::ic_lrt_invalidate(fv); }
    if (preserved & (1 << A_DOMTREE)) == 0 { dt_invalidate(fv, DT_DOM); }
    if (preserved & (1 << A_POSTDOMTREE)) == 0 { dt_invalidate(fv, DT_POST); }
    if (preserved & (1 << A_LOOPS)) == 0 { li_invalidate(fv); }
    if (preserved & (1 << A_CYCLES)) == 0 { ci_invalidate(fv); }
    // MemorySSAAnalysis::Result::invalidate: not preserved, or AAManager / DominatorTree invalidated. AAManager is
    // stateless (preservedWhenStateless): only invalidate<aa> abandons it (PA_ALL without the A_AA bit).
    let aa_abandoned = preserved == (PA_ALL & ~((1 as u32) << A_AA));
    if (preserved & (1 << A_MEMORYSSA)) == 0 || (preserved & (1 << A_DOMTREE)) == 0 || aa_abandoned { mssa_invalidate(fv); }
    // ScalarEvolution::invalidate: also when the domtree or loops go
    if (preserved & (1 << A_SCEV)) == 0 || (preserved & (1 << A_DOMTREE)) == 0 || (preserved & (1 << A_LOOPS)) == 0 { scev_invalidate(fv); }
    // LazyValueInfo::invalidate: only when not preserved (its AssumptionCache is never invalidated)
    if (preserved & (1 << A_LVI)) == 0 { lvi_invalidate(fv); }
    // BranchProbabilityInfo / BlockFrequencyInfo::invalidate: kept when preserved or when the CFG analyses are
    if (preserved & (1 << A_BPI)) == 0 && (preserved & PA_CFG) != PA_CFG { bpi_invalidate(); }
    if (preserved & (1 << A_BFI)) == 0 && (preserved & PA_CFG) != PA_CFG { bfi_invalidate(fv); }
}

fn require_analysis(fv: i32, a: i64) {
    if a == A_DOMTREE { dt_get(fv, DT_DOM); }
    else if a == A_POSTDOMTREE { dt_get(fv, DT_POST); }
    else if a == A_LOOPS { li_get(fv); }
    else if a == A_CYCLES { ci_get(fv); }
    else if a == A_MEMORYSSA { mssa_get(fv); }
    else if a == A_AA { aa_begin(fv); }
    else if a == A_SCEV { scev_get(fv); }
    else if a == A_LVI { lvi_get(fv); }
    else if a == A_BPI { bpi_get(fv); }
    else if a == A_BFI { bfi_get(fv); }
}

// Passes whose LLVM counterpart asks for TargetIRAnalysis (directly or through AssumptionAnalysis) before it
// prints anything; print<scalar-evolution> does it after its header (scev_print.goose).
fn pass_creates_subtarget(n: i32) -> bool {
    let p = pnodes[n].pass as i64;
    if p == P_REQUIRE {
        let a = pnodes[n].arg as i64;
        return a == A_MEMORYSSA || a == A_AA || a == A_SCEV || a == A_TARGET_IR;
    }
    return p == P_BDCE || p == P_MEM2REG || p == P_SROA || p == P_INSTSIMPLIFY || p == P_SIMPLIFYCFG ||
        p == P_INSTCOMBINE || p == P_PRINT_DEMANDED_BITS || p == P_PRINT_COST_MODEL || p == P_LOOP_SIMPLIFY || p == P_AA_EVAL ||
        p == P_PRINT_MEMORYSSA || p == P_PRINT_MEMORYSSA_WALKER || p == P_VERIFY_MEMORYSSA || p == P_SCCP ||
        p == P_EARLY_CSE || p == P_VERIFY_SCEV || p == P_CVP || p == P_JUMP_THREADING || p == P_GVN || p == P_DSE || p == P_MEMCPYOPT ||
        p == P_CONSTRAINT_ELIMINATION || p == P_AGGRESSIVE_INSTCOMBINE || p == P_LOOP_UNROLL || p == P_VECTOR_COMBINE || p == P_SLP_VECTORIZER;
}

fn run_function_pass(n: i32, fv: i32) -> u32 {
    let p = pnodes[n].pass as i64;
    if pass_creates_subtarget(n) { st_touch(fv); }
    match p {
        P_DCE => { return dce_run(fv); },
        P_REDUNDANT_DBG_INST_ELIM => { return redundant_dbg_inst_elim_run(fv); },
        P_ADCE => { return adce_run(fv); },
        P_BDCE => { return bdce_run(fv); },
        P_MEM2REG => { return mem2reg_run(fv); },
        P_SROA => { let a = pnodes[n].arg; return sroa_run(fv, (a & 1) != 0, (a & 2) != 0); },
        P_INSTSIMPLIFY => { return instsimplify_run(fv); },
        P_SIMPLIFYCFG => { return simplifycfg_run(fv, scf_opt_table[pnodes[n].arg]); },
        P_INSTCOMBINE => { let a = pnodes[n].arg; return ic::instcombine_run(fv, (a & 1) != 0, (a >> 1) as i64); },
        P_PRINT_DOMTREE => { print_domtree(fv, DT_DOM); return PA_ALL; },
        P_PRINT_POSTDOMTREE => { print_domtree(fv, DT_POST); return PA_ALL; },
        P_PRINT_DEMANDED_BITS => { print_demanded_bits(fv); return PA_ALL; },
        P_PRINT_COST_MODEL => { print_cost_model(fv); return PA_ALL; },
        P_REQUIRE => { require_analysis(fv, pnodes[n].arg as i64); return PA_ALL; },
        P_INVALIDATE => { return PA_ALL & ~((1 as u32) << pnodes[n].arg); },
        P_NOOP_FUNCTION, P_VERIFY_FUNCTION => { return PA_ALL; },
        P_BREAK_CRIT_EDGES => { return break_crit_edges_run(fv); },
        P_PRINT_LOOPS => { print_loops(fv); return PA_ALL; },
        P_PRINT_CYCLES => { print_cycles(fv); return PA_ALL; },
        P_VERIFY_CYCLES => { ci_get(fv); return PA_ALL; },
        P_VERIFY_DOMTREE => { dt_get(fv, DT_DOM); return PA_ALL; },
        P_VERIFY_LOOPS => { li_get(fv); return PA_ALL; },
        P_LOOP_SIMPLIFY => { return loop_simplify_run(fv); },
        P_LCSSA => { return lcssa_run(fv); },
        P_AA_EVAL => { aa_eval_run(fv); return PA_ALL; },
        P_PRINT_MEMORYSSA => { mssa_print(fv, pnodes[n].arg == 0); return PA_ALL; },
        P_PRINT_MEMORYSSA_WALKER => { mssa_print_walker(fv); return PA_ALL; },
        P_VERIFY_MEMORYSSA => { mssa_get(fv); mssa_verify(fv); return PA_ALL; },
        P_SCCP => { return sccp_run(fv); },
        P_EARLY_CSE => { return early_cse_run(fv, pnodes[n].arg != 0); },
        P_GVN => { return gvn_run(fv, pnodes[n].arg); },
        P_DSE => { return dse_run(fv); },
        P_MEMCPYOPT => { return memcpyopt_run(fv); },
        P_REASSOCIATE => { return reassociate_run(fv); },
        P_CONSTRAINT_ELIMINATION => { return constraint_elimination_run(fv); },
        P_AGGRESSIVE_INSTCOMBINE => { return aggressive_instcombine_run(fv); },
        P_VECTOR_COMBINE => { return vector_combine_run(fv); },
        P_SLP_VECTORIZER => { return slp_vectorizer_run(fv); },
        P_LOOP_VECTORIZE => {
            let a = pnodes[n].arg as i64;
            let pa = loop_vectorize_run(fv, (a & 1) != 0, (a & 2) != 0);
            ap_pool_reset();
            return pa;
        },
        P_PRINT_SCEV => { print_scev(fv); return PA_ALL; },
        P_PRINT_LVI => { lvi_print(fv); return PA_ALL; },
        P_LOOP_LOAD_ELIM => { let pa = loop_load_elim_run(fv); ap_pool_reset(); return pa; },
        P_LOOP_VERSIONING => { let pa = loop_versioning_run(fv); ap_pool_reset(); return pa; },
        P_LOOP_DISTRIBUTE => { let pa = loop_distribute_run(fv); ap_pool_reset(); return pa; },
        P_PRINT_ACCESS_INFO => { print_access_info(fv, pnodes[n].arg == 1); ap_pool_reset(); return PA_ALL; },
        P_PRINT_BPI => { bpi_print(fv); return PA_ALL; },
        P_PRINT_BFI => { bfi_print(fv); return PA_ALL; },
        P_CVP => { return cvp_run(fv); },
        P_JUMP_THREADING => { return jump_threading_run(fv, (pnodes[n].arg as i64) - 1); },
        P_VERIFY_SCEV => { scev_get(fv); return PA_ALL; },     // ScalarEvolution::verify reports only mismatches
        P_LOOP_UNROLL => { let pa = loop_unroll_pass_run(fv, lu_opt_table[pnodes[n].arg]); ap_pool_reset(); return pa; },
        _ => {
            if mp_is_ours(p) { let pa = mp_run_function(p, pnodes[n].arg, fv); ap_pool_reset(); return pa; }
            fatal("internal: unknown function pass id");
            return PA_ALL;
        },
    }
}

// A loop pass on loop l (PassModel::run); returns the preserved set.
var lpm_use_mssa: bool = false;   // the running adaptor's UseMemorySSA

fn run_loop_pass(n: i32, l: i32, fv: i32) -> u32 {
    let p = pnodes[n].pass as i64;
    match p {
        P_PRINT_LOOPNEST => { print_loopnest(l); return PA_ALL; },
        P_NOOP_LOOP => { return PA_ALL; },
        P_LREQUIRE => {
            // require<iv-users>: IVUsers(L, AC, LI, DT, SE) is built (its getSCEV calls fill ScalarEvolution's caches)
            if pnodes[n].arg == 1 { iu_build(l); ap_pool_reset(); }
            return PA_ALL;
        },
        P_LOOP_ROTATE => {
            let a = pnodes[n].arg;
            let pa = loop_rotate_pass_run(l, (a & 1) != 0, (a & 2) != 0, (a & 4) != 0, lpm_use_mssa);
            ap_pool_reset();
            return pa;
        },
        P_PRINT_IV_USERS => { print_iv_users(l); return PA_ALL; },
        P_LOOP_DELETION => { let pa = loop_deletion_pass_run(l, lpm_use_mssa); ap_pool_reset(); return pa; },
        P_LOOP_INSTSIMPLIFY => { let pa = loop_instsimplify_pass_run(l, lpm_use_mssa); ap_pool_reset(); return pa; },
        P_LOOP_SIMPLIFYCFG => { let pa = loop_simplifycfg_pass_run(l, lpm_use_mssa); ap_pool_reset(); return pa; },
        P_LOOP_IDIOM => { let pa = loop_idiom_pass_run(l, lpm_use_mssa); ap_pool_reset(); return pa; },
        P_SIMPLE_LOOP_UNSWITCH => {
            let a = pnodes[n].arg;
            let pa = simple_loop_unswitch_pass_run(l, (a & 1) != 0, (a & 2) != 0, lpm_use_mssa);
            ap_pool_reset();
            return pa;
        },
        P_LOOP_UNROLL_FULL => {
            let pa = loop_full_unroll_pass_run(l, 2, false, false);
            ap_pool_reset();
            return pa;
        },
        P_INDVARS => {
            let pa = indvars_pass_run(l, lpm_use_mssa);
            ap_pool_reset();
            return pa;
        },
        P_LICM => {
            let a = pnodes[n].arg;
            let nest = (a & 2) != 0;
            if !lpm_use_mssa {
                write_stderr(if nest { "LLVM ERROR: LNICM requires MemorySSA (loop-mssa)\n" } else { "LLVM ERROR: LICM requires MemorySSA (loop-mssa)\n" });
                exit(1);
            }
            let pa = licm_pass_run(l, (a & 1) != 0, nest);
            ap_pool_reset();
            return pa;
        },
        _ => { fatal("internal: unknown loop pass id"); return PA_ALL; },
    }
}

// LoopPassManager::runSinglePass + PassInstrumentation (bisect, optnone). Returns -1 (as u64) when skipped.
fn loop_single_pass(n: i32, l: i32, fv: i32) -> u32, bool {
    if !should_run(n, str("loop %", loop_name(l), " in function ", val_name(fv))) { return PA_ALL, false; }
    if !pnodes[n].required && aset_has(alist_fn(globs[glob_of(fv)].attrs), AK_OptimizeNone) { return PA_ALL, false; }
    return run_loop_pass(n, l, fv), true;
}

// LoopPassManager::runWithoutLoopNestPasses over the children of node n (an adaptor or a nested loop(...)).
recursive fn run_loop_list(n: i32, l: i32, fv: i32) -> u32 {
    var pa = PA_ALL;
    var c = pnodes[n].first;
    // LoopPassManager::run: loop-nest passes run only when the current loop is a top-level one
    let outermost = loop_is_outermost(l);
    while c >= 0 {
        if is_nest_pass_node(c) && !outermost { c = pnodes[c].next; continue; }
        var ppa = PA_ALL;
        var ran = true;
        if pnodes[c].kind == PK_LPM { ppa = run_loop_list(c, l, fv); }
        else { let r, ok = loop_single_pass(c, l, fv); ppa = r; ran = ok; }
        if ran {
            pa &= ppa;
            if lpm_skip { break; }
        }
        c = pnodes[c].next;
    }
    return pa;
}

// FunctionToLoopPassAdaptor::run
fn run_loop_adaptor(n: i32, fv: i32) {
    st_touch(fv);   // LoopStandardAnalysisResults (TTI, AC), requested even for a function without loops
    // the canonicalization pipeline (LoopSimplifyPass, LCSSAPass), a required function pass manager
    var pa = PA_ALL;
    var c = pnodes[n].pass;
    while c >= 0 {
        if should_run(c, val_name(fv)) && !aset_has(alist_fn(globs[glob_of(fv)].attrs), AK_OptimizeNone) {
            let p = run_function_pass(c, fv);
            invalidate_function(fv, p);
            pa &= p;
        }
        c = pnodes[c].next;
    }
    li_get(fv);
    if li_ntop(fv) == 0 { fn_pa_acc &= pa; invalidate_function(fv, pa); return; }
    // MSSA = UseMemorySSA ? &AM.getResult<MemorySSAAnalysis>(F) : nullptr; LoopStandardAnalysisResults: AA, AC,
    // DT, LI, SE, TLI, TTI
    let use_mssa = (pnodes[n].arg & 1) != 0;
    lpm_use_mssa = use_mssa;
    if use_mssa { mssa_get(fv); msu_reset(); }
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    scev_get(fv);
    tli_cur_fn = fv;
    lpm_nest_mode = (pnodes[n].arg & 2) != 0;
    if !lpm_nest_mode { lpm_append_function_loops(fv); }
    else { for k in li_ntop(fv) { lpm_wl_insert(li_top(fv, k)); } }
    loop {
        let l = lpm_wl_pop();
        lpm_cur = l;
        lpm_skip = false;
        let ppa = run_loop_list(n, l, fv);
        if use_mssa && (ppa & ((1 as u32) << A_MEMORYSSA)) == 0 {
            write_stderr("LLVM ERROR: Loop pass manager using MemorySSA contains a pass that does not preserve MemorySSA\n");
            exit(1);
        }
        if use_mssa && flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
        pa &= ppa;
        if lpm_wl_empty() { break; }
    }
    lpm_cur = -1;
    pa |= ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    fn_pa_acc &= pa;
    invalidate_function(fv, pa);
}

// The intersection of the preserved sets of the function passes run since it was last reset (a function pass
// manager's PreservedAnalyses, without the AllAnalysesOn<Function> set it adds).
var fn_pa_acc: u32 = 0xFFFFFFFF;

// Runs a function-level node (a pass or a nested function pass manager) on fv.
recursive fn run_function_node(n: i32, fv: i32) {
    if pnodes[n].kind == PK_FUNCTION {
        var c = pnodes[n].first;
        while c >= 0 { run_function_node(c, fv); c = pnodes[c].next; }
        return;
    }
    if pnodes[n].kind == PK_LOOP { run_loop_adaptor(n, fv); return; }
    if !should_run(n, val_name(fv)) { return; }
    // OptNoneInstrumentation::shouldRun (after OptBisect has counted the pass, as both callbacks run)
    if !pnodes[n].required && aset_has(alist_fn(globs[glob_of(fv)].attrs), AK_OptimizeNone) { return; }
    let pa = run_function_pass(n, fv);
    fn_pa_acc &= pa;
    invalidate_function(fv, pa);
    // APInt words of the pass are dead now (apint.goose: no AP outlives its pass)
    ap_pool_reset();
}

recursive fn run_module_node(n: i32, m: i32) {
    let k = pnodes[n].kind;
    if k == PK_MODULE {
        var c = pnodes[n].first;
        while c >= 0 { run_module_node(c, m); c = pnodes[c].next; }
        return;
    }
    if k == PK_FUNCTION {
        // ModuleToFunctionPassAdaptor: every function definition in module order
        fn_pa_acc = PA_ALL;
        var f = modules[m].first_func;
        while f >= 0 {
            let nf = globs[glob_of(f)].next;
            if !func_is_decl(f) {
                var c = pnodes[n].first;
                while c >= 0 { run_function_node(c, f); c = pnodes[c].next; }
            }
            f = nf;
        }
        // the adaptor preserves AllAnalysesOn<Function> and the proxy, not module analyses
        module_invalidate(m, fn_pa_acc | PA_FN);
        return;
    }
    if k == PK_CGSCC {
        let pa = cg_run_adaptor(n, m);
        if pa != PA_ALL { gm_invalidate(); }
        module_invalidate(m, pa);
        return;
    }
    let p = pnodes[n].pass as i64;
    if !should_run(n, "[module]") { return; }
    if p == P_VERIFY_MODULE || p == P_NOOP_MODULE { return; }
    // module passes: call ap_pool_reset() after each one (apint.goose: no AP outlives its pass)
    if p == P_IPSCCP {
        var tf = modules[m].first_func;
        while tf >= 0 { if !func_is_decl(tf) { st_touch(tf); } tf = globs[glob_of(tf)].next; }
        if ipsccp_run(m, pnodes[n].arg != 0) {
            lcg_invalidate();
            // preserves DominatorTreeAnalysis, PostDominatorTreeAnalysis and the function analysis proxy
            var f = modules[m].first_func;
            while f >= 0 {
                if !func_is_decl(f) { invalidate_function(f, (1 << A_DOMTREE) | (1 << A_POSTDOMTREE)); }
                f = globs[glob_of(f)].next;
            }
        }
        ap_pool_reset();
        return;
    }
    if p == P_INFERATTRS {
        if inferattrs_run(m) {
            lcg_invalidate();
            var f = modules[m].first_func;
            while f >= 0 {
                if !func_is_decl(f) { invalidate_function(f, PA_NONE); }
                f = globs[glob_of(f)].next;
            }
            gm_invalidate();
        }
        ap_pool_reset();
        return;
    }
    if p == P_REQUIRE_GLOBALS_AA { if !gm_valid { gm_compute(m); } return; }
    if p == P_PRINT_LCG { lcg_print_pass(m); return; }
    if p == P_PRINT_LCG_DOT { lcg_print_dot_pass(m); return; }
    if p == P_REQUIRE_LCG { lcg_get(m); return; }
    if p == P_INVALIDATE_LCG { lcg_invalidate(); return; }
    if p == P_REQUIRE_PSI { psi_get(m); return; }
    if p == P_INVALIDATE_PSI { psi_invalidate(); return; }
    if p == P_ALWAYS_INLINE { let pa = always_inliner_run(m); module_invalidate(m, pa); ap_pool_reset(); return; }
    if p == P_MODULE_INLINE { let pa = module_inliner_run(m); module_invalidate(m, pa); ap_pool_reset(); return; }
    if p == P_INLINER_WRAPPER { let pa = inliner_wrapper_run(m, pnodes[n].arg != 0); module_invalidate(m, pa); ap_pool_reset(); return; }
    if p == P_RPO_FUNCTION_ATTRS { let pa = rpo_function_attrs_run(m); module_invalidate(m, pa); ap_pool_reset(); return; }
    if p == P_NORECURSE_LTO { let pa = norecurse_lto_run(m); module_invalidate(m, pa); ap_pool_reset(); return; }
    if p == P_DEBUGIFY { lcg_invalidate(); debugify_run(m); invalidate_module_functions(m, PA_CFG); return; }
    if p == P_CHECK_DEBUGIFY { check_debugify_run(m); return; }
    if p == P_INVALIDATE_GLOBALS_AA { gm_invalidate(); return; }
    if p == P_ASSIGN_GUID { assign_guid_run(m); return; }
    if p == P_GLOBALOPT {
        if globalopt_run(m) {
            gm_invalidate();
            // PreservedAnalyses::none() + FunctionAnalysisManagerModuleProxy + CFGAnalyses
            module_invalidate(m, PA_CFG);
        }
        ap_pool_reset();
        return;
    }
    if p == P_DEADARGELIM || p == P_INTERNALIZE {
        var changed = false;
        if p == P_DEADARGELIM { changed = deadargelim_run(m); }
        else {
            in_preserve_gv.clear();
            let a = pnodes[n].arg;
            in_has_preserve_param = a >= 0 && ints[a] > 0;
            if a >= 0 { for k in ints[a] as i64 { in_preserve_gv.push(ints[a + 1 + k]); } }
            changed = internalize_run(m);
        }
        if changed { gm_invalidate(); module_invalidate(m, PA_NONE); }
        ap_pool_reset();
        return;
    }
    if p == P_STRIP_DEAD_PROTOTYPES || p == P_ELIM_AVAIL_EXTERN || p == P_CONSTMERGE || p == P_GLOBALDCE {
        var changed = false;
        if p == P_STRIP_DEAD_PROTOTYPES { changed = strip_dead_prototypes_run(m); }
        else if p == P_ELIM_AVAIL_EXTERN { changed = elim_avail_extern_run(m); }
        else if p == P_CONSTMERGE { changed = constmerge_run(m); }
        else { gd_in_lto_post_link = pnodes[n].arg != 0; changed = globaldce_run(m); }
        if changed { gm_invalidate(); module_invalidate(m, PA_NONE); }
        ap_pool_reset();
        return;
    }
    if mp_is_ours(p) {
        let pa = mp_run_module(p, pnodes[n].arg, m);
        if pa != PA_ALL { gm_invalidate(); module_invalidate(m, pa); }
        ap_pool_reset();
        return;
    }
    fatal("internal: unknown module pass id");
}

// A module pass's PreservedAnalyses: module analyses (the call graph, the profile summary is immutable) and,
// through FunctionAnalysisManagerModuleProxy, the function analyses of every definition.
fn module_invalidate(m: i32, pa: u32) {
    if pa == PA_ALL { return; }
    if (pa & ((1 as u32) << A_LCG)) == 0 { lcg_invalidate(); }
    if (pa & PA_FN) != PA_FN { invalidate_module_functions(m, pa); }
}

// invalidate the function analyses of every definition not in the preserved set (a module pass's result)
fn invalidate_module_functions(m: i32, pa: u32) {
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) { invalidate_function(f, pa); }
        f = globs[glob_of(f)].next;
    }
}

fn run_pipeline(root: i32, m: i32) {
    flags_check_unsupported();
    st_init_target_machine(m);
    // NewPMDriver: -enable-debugify wraps the pipeline in NewPMDebugifyPass / NewPMCheckDebugifyPass
    let enable_debugify = flag_bool("enable-debugify", false);
    if flag_bool("debugify-each", false) { fatal("opt: -debugify-each is not supported yet in the Goose opt"); }
    if enable_debugify { debugify_run(m); invalidate_module_functions(m, PA_CFG); }
    run_module_node(root, m);
    if enable_debugify { check_debugify_run(m); }
    aa_eval_finish();
    slots_end();
}
