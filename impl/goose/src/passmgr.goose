// The pass manager: textual pipeline parsing, nesting adaptors, analysis caching/invalidation, opt-bisect.
// Ports llvm/lib/Passes/PassBuilder.cpp (parsePipelineText, parsePassPipeline, parseModulePass,
// parseFunctionPass, isModulePassName/isFunctionPassName/...), llvm/include/llvm/IR/PassManager.h
// (ModuleToFunctionPassAdaptor: functions in module order, declarations skipped) and llvm/lib/IR/OptBisect.cpp.
// Passes are dispatched by a match on a pass id (no function pointers); see DESIGN.md §9 "How to add a pass".
import std;
import os;
import ir;
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
import analyses;
import loopinfo;
import cycleinfo;
import breakcrit;
import loopsimplify;
import lcssa;
import aaeval;
import memoryssa;
import aa;
import mssaupdater;
import licm;
import apint;
import sccp;
import build_libcalls;
import globalsaa;
import lpm;
import tli;
import scev;
import loopnest;
import simplifycfg;
import subtarget;
import debugify;

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
// function passes
let P_DCE = 100;
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
let P_PRINT_SCEV = 118;
let P_VERIFY_SCEV = 119;
// loop passes
let P_PRINT_LOOPNEST = 200;
let P_NOOP_LOOP = 201;
let P_PRINT_LOOP = 202;
let P_LREQUIRE = 203;      // require<analysis> in a loop pipeline (arg = analysis id; none are cached)
let P_LINVALIDATE = 204;
let P_LICM = 205;          // arg: bit 0 = AllowSpeculation, bit 1 = lnicm (a loop-nest pass)

// "<level>:<name>:<id>:<required>" — level m/f; required passes are not counted by -opt-bisect-limit
// (PassInfoMixin::isRequired: printers, verifier, require/invalidate, adaptors).
let PASS_TABLE: const u8[:][] = [
    "m:verify:1:1",
    "m:no-op-module:2:0",
    "m:debugify:7:0",
    "m:check-debugify:8:0",
    "m:inferattrs:9:0",
    "f:dce:100:0",
    "f:adce:101:0",
    "f:bdce:102:0",
    "f:print<domtree>:103:1",
    "f:print<postdomtree>:104:1",
    "f:print<demanded-bits>:105:1",
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
    "f:print<scalar-evolution>:118:1",
    "f:verify<scalar-evolution>:119:1",
    "l:print<loopnest>:200:1",
    "l:no-op-loop:201:0",
];

// LLVM pass class names, for -opt-bisect-limit messages.
fn pass_class_name(p: i64) -> const u8[:] {
    match p {
        P_DCE => "DCEPass",
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
        P_IPSCCP => "IPSCCPPass",
        P_DEBUGIFY => "NewPMDebugifyPass",
        P_CHECK_DEBUGIFY => "NewPMCheckDebugifyPass",
        P_INFERATTRS => "InferFunctionAttrsPass",
        P_NOOP_MODULE => "NoOpModulePass",
        P_NOOP_FUNCTION => "NoOpFunctionPass",
        _ => "Pass",
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
            if llvm_knows(name, 'f') { not_implemented(name); }
            perr_pipeline(str("unknown function pass '", name, "'"));
        }
        let p: i32 = if starts_with(name, "require<") { P_REQUIRE as i32 } else { P_INVALIDATE as i32 };
        return new_pnode(PK_PASS, p, a as i32, true, pelems[e].name);
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
    if starts_with(name, "require<") || starts_with(name, "invalidate<") {
        if llvm_knows(name, 'l') { not_implemented(name); }
        perr_pipeline(str("unknown loop pass '", name, "'"));
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
        if name == "cgscc" || name == "coro-cond" { not_implemented(name); }
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
    let r = pass_row(name, 'm');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
    // module VerifierAnalysis: nothing to compute (no verifier yet; the harness verifies our output)
    if name == "require<verify>" || name == "invalidate<verify>" { return new_pnode(PK_PASS, P_NOOP_MODULE as i32, 0, true, pelems[e].name); }
    if name == "require<globals-aa>" { return new_pnode(PK_PASS, P_REQUIRE_GLOBALS_AA as i32, 0, true, pelems[e].name); }
    if name == "invalidate<globals-aa>" { return new_pnode(PK_PASS, P_INVALIDATE_GLOBALS_AA as i32, 0, true, pelems[e].name); }
    if llvm_knows(name, 'm') { not_implemented(name); }
    if llvm_knows(name, 'c') { not_implemented(name); }
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
            not_implemented("cgscc");
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
}

fn require_analysis(fv: i32, a: i64) {
    if a == A_DOMTREE { dt_get(fv, DT_DOM); }
    else if a == A_POSTDOMTREE { dt_get(fv, DT_POST); }
    else if a == A_LOOPS { li_get(fv); }
    else if a == A_CYCLES { ci_get(fv); }
    else if a == A_MEMORYSSA { mssa_get(fv); }
    else if a == A_AA { aa_begin(fv); }
    else if a == A_SCEV { scev_get(fv); }
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
        p == P_INSTCOMBINE || p == P_PRINT_DEMANDED_BITS || p == P_LOOP_SIMPLIFY || p == P_AA_EVAL ||
        p == P_PRINT_MEMORYSSA || p == P_PRINT_MEMORYSSA_WALKER || p == P_VERIFY_MEMORYSSA || p == P_SCCP ||
        p == P_EARLY_CSE || p == P_VERIFY_SCEV;
}

fn run_function_pass(n: i32, fv: i32) -> u32 {
    let p = pnodes[n].pass as i64;
    if pass_creates_subtarget(n) { st_touch(fv); }
    match p {
        P_DCE => { return dce_run(fv); },
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
        P_PRINT_SCEV => { print_scev(fv); return PA_ALL; },
        P_VERIFY_SCEV => { scev_get(fv); return PA_ALL; },     // ScalarEvolution::verify reports only mismatches
        _ => { fatal("internal: unknown function pass id"); return PA_ALL; },
    }
}

// A loop pass on loop l (PassModel::run); returns the preserved set.
var lpm_use_mssa: bool = false;   // the running adaptor's UseMemorySSA

fn run_loop_pass(n: i32, l: i32, fv: i32) -> u32 {
    let p = pnodes[n].pass as i64;
    match p {
        P_PRINT_LOOPNEST => { print_loopnest(l); return PA_ALL; },
        P_NOOP_LOOP => { return PA_ALL; },
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
    if li_ntop(fv) == 0 { invalidate_function(fv, pa); return; }
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
    invalidate_function(fv, pa);
}

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
        var f = modules[m].first_func;
        while f >= 0 {
            let nf = globs[glob_of(f)].next;
            if !func_is_decl(f) {
                var c = pnodes[n].first;
                while c >= 0 { run_function_node(c, f); c = pnodes[c].next; }
            }
            f = nf;
        }
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
    if p == P_DEBUGIFY { debugify_run(m); invalidate_module_functions(m, PA_CFG); return; }
    if p == P_CHECK_DEBUGIFY { check_debugify_run(m); return; }
    if p == P_INVALIDATE_GLOBALS_AA { gm_invalidate(); return; }
    fatal("internal: unknown module pass id");
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
