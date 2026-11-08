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
import demandedbits;

// ---------------------------------------------------------------------------------------------
// Pass ids. Add a new pass: an id here, a row in PASS_TABLE, a case in run_function_pass (or
// run_module_pass), and the analyses it preserves.

let P_NONE = 0;
// module passes
let P_VERIFY_MODULE = 1;
let P_NOOP_MODULE = 2;
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

// "<level>:<name>:<id>:<required>" — level m/f; required passes are not counted by -opt-bisect-limit
// (PassInfoMixin::isRequired: printers, verifier, require/invalidate, adaptors).
let PASS_TABLE: const u8[:][] = [
    "m:verify:1:1",
    "m:no-op-module:2:0",
    "f:dce:100:0",
    "f:adce:101:0",
    "f:bdce:102:0",
    "f:print<domtree>:103:1",
    "f:print<postdomtree>:104:1",
    "f:print<demanded-bits>:105:1",
    "f:no-op-function:108:0",
    "f:verify:109:1",
];

// LLVM pass class names, for -opt-bisect-limit messages.
fn pass_class_name(p: i64) -> const u8[:] {
    match p {
        P_DCE => "DCEPass",
        P_ADCE => "ADCEPass",
        P_BDCE => "BDCEPass",
        P_NOOP_MODULE => "NoOpModulePass",
        P_NOOP_FUNCTION => "NoOpFunctionPass",
        _ => "Pass",
    }
}

// Analyses (bit i of a preserved set). CFG analyses are those LLVM marks preserved by preserveSet<CFGAnalyses>.
let A_DOMTREE = 0;
let A_POSTDOMTREE = 1;
let A_DEMANDED_BITS = 2;     // computed per query; listed so require<>/invalidate<> parse
let PA_ALL: u32 = 0xFFFFFFFF;
let PA_NONE: u32 = 0;
let PA_CFG: u32 = 3;          // domtree | postdomtree

fn analysis_id(name: const u8[:]) -> i64 {
    if name == "domtree" { return A_DOMTREE; }
    if name == "postdomtree" { return A_POSTDOMTREE; }
    if name == "demanded-bits" { return A_DEMANDED_BITS; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Pipeline tree (PassBuilder::PipelineElement)

let PK_MODULE = 0;      // module(...) pass manager
let PK_FUNCTION = 1;    // function(...) adaptor
let PK_LOOP = 2;
let PK_CGSCC = 3;
let PK_PASS = 4;

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
        if name == "loop" || name == "loop-mssa" { not_implemented(name); }
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
    let r = pass_row(name, 'f');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
    if llvm_knows(name, 'f') { not_implemented(name); }
    if is_loop_pass_name(name) { not_implemented(name); }
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
    let r = pass_row(name, 'm');
    if r >= 0 { return new_pnode(PK_PASS, row_id(r), 0, row_required(r), pelems[e].name); }
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
            not_implemented(fname);
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
        pass_class_name(pnodes[n].pass as i64), " on ", unit, "\n"));
    return run;
}

// Drop analyses of fv that the pass didn't preserve.
fn invalidate_function(fv: i32, preserved: u32) {
    if preserved == PA_ALL { return; }
    slots_invalidate();
    if (preserved & (1 << A_DOMTREE)) == 0 { dt_invalidate(fv, DT_DOM); }
    if (preserved & (1 << A_POSTDOMTREE)) == 0 { dt_invalidate(fv, DT_POST); }
}

fn require_analysis(fv: i32, a: i64) {
    if a == A_DOMTREE { dt_get(fv, DT_DOM); }
    else if a == A_POSTDOMTREE { dt_get(fv, DT_POST); }
}

fn run_function_pass(n: i32, fv: i32) -> u32 {
    let p = pnodes[n].pass as i64;
    match p {
        P_DCE => { return dce_run(fv); },
        P_ADCE => { return adce_run(fv); },
        P_BDCE => { return bdce_run(fv); },
        P_PRINT_DOMTREE => { print_domtree(fv, DT_DOM); return PA_ALL; },
        P_PRINT_POSTDOMTREE => { print_domtree(fv, DT_POST); return PA_ALL; },
        P_PRINT_DEMANDED_BITS => { print_demanded_bits(fv); return PA_ALL; },
        P_REQUIRE => { require_analysis(fv, pnodes[n].arg as i64); return PA_ALL; },
        P_INVALIDATE => { return PA_ALL & ~((1 as u32) << pnodes[n].arg); },
        P_NOOP_FUNCTION, P_VERIFY_FUNCTION => { return PA_ALL; },
        _ => { fatal("internal: unknown function pass id"); return PA_ALL; },
    }
}

// Runs a function-level node (a pass or a nested function pass manager) on fv.
recursive fn run_function_node(n: i32, fv: i32) {
    if pnodes[n].kind == PK_FUNCTION {
        var c = pnodes[n].first;
        while c >= 0 { run_function_node(c, fv); c = pnodes[c].next; }
        return;
    }
    if !should_run(n, str("function (", val_name(fv), ")")) { return; }
    let pa = run_function_pass(n, fv);
    invalidate_function(fv, pa);
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
    if !should_run(n, "module") { return; }
    if p == P_VERIFY_MODULE || p == P_NOOP_MODULE { return; }
    fatal("internal: unknown module pass id");
}

fn run_pipeline(root: i32, m: i32) {
    run_module_node(root, m);
    slots_end();
}
