// Pass infrastructure: textual pipelines, the pass registry, pass and analysis managers, opt's command line.
// Ported from llvm/lib/Passes/PassBuilder.cpp (parsePipelineText, parsePassPipeline, parseModulePass,
// parseFunctionPass, the auto-wrapping of a pipeline whose first pass isn't a module pass), llvm/include/llvm/IR/
// PassManager.h (PreservedAnalyses, ModuleToFunctionPassAdaptor: declarations are skipped, analyses invalidated per
// function), llvm/lib/Passes/StandardInstrumentations.cpp (OptNoneInstrumentation, OptPassGateInstrumentation) and
// llvm/lib/IR/OptBisect.cpp (-opt-bisect-limit).
//
// No OOP: a parsed pipeline is a flat array of Pass_Node rows (a tree through first_child/next), every pass is a
// Pass_Kind enum value, and running a pass is a `switch` in run_function_pass (see DESIGN.md "Pass infrastructure"
// and "How to add a pass").

// ---------------------------------------------------------------- analyses

Analysis_Kind :: enum u8 { DOMTREE; POSTDOMTREE; DEMANDED_BITS; }
ANALYSIS_NAMES :: string.["domtree", "postdomtree", "demanded-bits"];

// PreservedAnalyses. `cfg` = preserveSet<CFGAnalyses>().
Preserved :: struct {
    all: bool;
    cfg: bool;
    mask: u32;
}
PRESERVE_ALL :: Preserved.{all = true};
PRESERVE_NONE :: Preserved.{};
preserve :: (pa: *Preserved, k: Analysis_Kind) { pa.mask |= (cast(u32) 1) << cast(u32) k; }
preserved_cfg :: () -> Preserved { pa: Preserved; pa.cfg = true; return pa; }
is_preserved :: (pa: Preserved, k: Analysis_Kind) -> bool { return pa.all || (pa.mask & ((cast(u32) 1) << cast(u32) k)) != 0; }

// Whether a cached result survives (Result::invalidate). DominatorTree/PostDominatorTree are CFG analyses.
analysis_survives :: (k: Analysis_Kind, pa: Preserved) -> bool {
    if is_preserved(pa, k) return true;
    if k == .DOMTREE || k == .POSTDOMTREE return pa.cfg;
    return false;
}

// FunctionAnalysisManager: the cached results of one function (heap-allocated, freed on invalidation).
Fn_Analyses :: struct {
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    db: *Demanded_Bits;
}
fam: Table(Value_Id, Fn_Analyses);

fam_entry :: (f: Value_Id) -> *Fn_Analyses {
    e := table_find_pointer(*fam, f);
    if e return e;
    blank: Fn_Analyses;
    table_set(*fam, f, blank);
    return table_find_pointer(*fam, f);
}

// AM.getResult<DominatorTreeAnalysis>(F)
get_domtree :: (f: Value_Id) -> *Dom_Tree {
    e := fam_entry(f);
    if !e.dt {
        e.dt = dt_new(false);
        dt_recalculate(e.dt, f);
    }
    return e.dt;
}
// AM.getResult<PostDominatorTreeAnalysis>(F)
get_postdomtree :: (f: Value_Id) -> *Dom_Tree {
    e := fam_entry(f);
    if !e.pdt {
        e.pdt = dt_new(true);
        dt_recalculate(e.pdt, f);
    }
    return e.pdt;
}
// AM.getCachedResult<...>(F)
cached_domtree :: (f: Value_Id) -> *Dom_Tree { e := table_find_pointer(*fam, f); if e return e.dt; return null; }
cached_postdomtree :: (f: Value_Id) -> *Dom_Tree { e := table_find_pointer(*fam, f); if e return e.pdt; return null; }
// AM.getResult<DemandedBitsAnalysis>(F) (DemandedBitsAnalysis::run also requests AssumptionAnalysis and DominatorTree)
get_demanded_bits :: (f: Value_Id) -> *Demanded_Bits {
    e := fam_entry(f);
    if !e.db {
        dt := get_domtree(f);
        e = fam_entry(f);
        e.db = New(Demanded_Bits);
        e.db.fn = f;
        e.db.dt = dt;
    }
    return e.db;
}

dt_new :: (post: bool) -> *Dom_Tree {
    dt := New(Dom_Tree);
    dt.post = post;
    return dt;
}
dt_free :: (dt: *Dom_Tree) {
    array_free(dt.nodes); array_free(dt.roots); deinit(*dt.node_of);
    free(dt);
}

fam_invalidate :: (f: Value_Id, pa: Preserved) {
    e := table_find_pointer(*fam, f);
    if !e return;
    if e.dt && !analysis_survives(.DOMTREE, pa) { dt_free(e.dt); e.dt = null; }
    if e.pdt && !analysis_survives(.POSTDOMTREE, pa) { dt_free(e.pdt); e.pdt = null; }
    if e.db && !analysis_survives(.DEMANDED_BITS, pa) { db_free(e.db); e.db = null; }
    // a DemandedBits result points at the DominatorTree it was built with
    if e.db && !e.dt { db_free(e.db); e.db = null; }
}
fam_require :: (f: Value_Id, k: Analysis_Kind) {
    if k == {
        case .DOMTREE; get_domtree(f);
        case .POSTDOMTREE; get_postdomtree(f);
        case .DEMANDED_BITS; get_demanded_bits(f);
    }
}
fam_invalidate_one :: (f: Value_Id, k: Analysis_Kind) {
    pa := PRESERVE_ALL; pa.all = false;
    pa.mask = ~((cast(u32) 1) << cast(u32) k);
    fam_invalidate(f, pa);
}

// ---------------------------------------------------------------- the registry

Pass_Level :: enum u8 { MODULE; FUNCTION; LOOP; }

Pass_Kind :: enum u8 {
    // structure
    MODULE_PM; FUNCTION_ADAPTOR;
    // analysis utilities (required: they run on optnone functions and don't count for -opt-bisect-limit)
    REQUIRE; INVALIDATE; PRINT_DOMTREE; PRINT_POSTDOMTREE; PRINT_DEMANDED_BITS; NO_OP_FUNCTION; NO_OP_MODULE;
    // transforms
    DCE; ADCE; BDCE; BREAK_CRIT_EDGES;
}

Pass_Info :: struct {
    name: string;
    level: Pass_Level;
    kind: Pass_Kind;
    required: bool;
    analysis: Analysis_Kind;   // REQUIRE / INVALIDATE
}

// Add a row here (and a case in run_function_pass) to register a pass. Names are the PassRegistry.def names.
PASS_TABLE :: Pass_Info.[
    .{"no-op-module", .MODULE, .NO_OP_MODULE, false, .DOMTREE},
    .{"no-op-function", .FUNCTION, .NO_OP_FUNCTION, false, .DOMTREE},
    .{"dce", .FUNCTION, .DCE, false, .DOMTREE},
    .{"adce", .FUNCTION, .ADCE, false, .DOMTREE},
    .{"bdce", .FUNCTION, .BDCE, false, .DOMTREE},
    .{"break-crit-edges", .FUNCTION, .BREAK_CRIT_EDGES, false, .DOMTREE},
    .{"print<domtree>", .FUNCTION, .PRINT_DOMTREE, true, .DOMTREE},
    .{"print<postdomtree>", .FUNCTION, .PRINT_POSTDOMTREE, true, .DOMTREE},
    .{"print<demanded-bits>", .FUNCTION, .PRINT_DEMANDED_BITS, true, .DOMTREE},
    .{"require<domtree>", .FUNCTION, .REQUIRE, true, .DOMTREE},
    .{"require<postdomtree>", .FUNCTION, .REQUIRE, true, .POSTDOMTREE},
    .{"require<demanded-bits>", .FUNCTION, .REQUIRE, true, .DEMANDED_BITS},
    .{"invalidate<domtree>", .FUNCTION, .INVALIDATE, true, .DOMTREE},
    .{"invalidate<postdomtree>", .FUNCTION, .INVALIDATE, true, .POSTDOMTREE},
    .{"invalidate<demanded-bits>", .FUNCTION, .INVALIDATE, true, .DEMANDED_BITS},
];

// Passes LLVM has that we don't: recognised so that the error says "not implemented" rather than "unknown".
pass_table: [..] Pass_Info;   // PASS_TABLE copied into memory, so that pointers to rows stay valid
lookup_pass :: (name: string) -> *Pass_Info {
    if pass_table.count == 0 for PASS_TABLE array_add(*pass_table, it);
    for * pass_table if it.name == name return it;
    return null;
}

// ---------------------------------------------------------------- pipeline text

Pipeline_Element :: struct {
    name: string;
    first_child: s32 = -1;
    next: s32 = -1;
    has_children: bool;   // `name(...)` even if empty
}

Pass_Node :: struct {
    kind: Pass_Kind;
    info: *Pass_Info;      // null for MODULE_PM / FUNCTION_ADAPTOR
    name: string;
    first_child: s32 = -1;
    next: s32 = -1;
}

pipeline: struct {
    elems: [..] Pipeline_Element;
    nodes: [..] Pass_Node;
};

pipeline_error :: (fmt: string, args: .. Any) {
    msg := tprint(fmt, ..args);
    fatal("invalid pass pipeline: %", msg);
}

// PassBuilder::parsePipelineText: elements separated by ',', nesting with '(' ')'. Returns the first element of
// the top-level list.
parse_pipeline_text :: (text: string) -> s32 {
    Frame :: struct { first: s32; last: s32; parent: s32; }
    stack: [..] Frame; stack.allocator = temp;
    array_add(*stack, .{-1, -1, -1});
    pos := 0;
    append_elem :: (stack: *[..] Frame, name: string) -> s32 {
        e: Pipeline_Element; e.name = name;
        id := cast(s32) pipeline.elems.count;
        array_add(*pipeline.elems, e);
        top := *stack.*[stack.count - 1];
        if top.last >= 0 pipeline.elems[top.last].next = id; else top.first = id;
        top.last = id;
        return id;
    }
    while true {
        // find_first_of(",()")
        end := pos;
        while end < text.count && text[end] != #char "," && text[end] != #char "(" && text[end] != #char ")" end += 1;
        name := slice(text, pos, end - pos);
        id := append_elem(*stack, name);
        if end == text.count {
            pos = end;
            break;
        }
        c := text[end];
        pos = end + 1;
        if c == #char "(" {
            pipeline.elems[id].has_children = true;
            array_add(*stack, .{-1, -1, id});
            continue;
        }
        if c == #char "," continue;
        // ')': close as many levels as there are ')'
        while true {
            if stack.count <= 1 pipeline_error("unbalanced ')' in '%'", text);
            fr := pop(*stack);
            pipeline.elems[fr.parent].first_child = fr.first;
            if pos < text.count && text[pos] == #char ")" { pos += 1; continue; }
            break;
        }
        if pos == text.count break;
        if text[pos] != #char "," pipeline_error("expected ',' after ')' in '%'", text);
        pos += 1;
    }
    if stack.count != 1 pipeline_error("unbalanced '(' in '%'", text);
    for pipeline.elems if it.name.count == 0 && !it.has_children pipeline_error("empty pass name in '%'", text);
    return stack[0].first;
}

is_module_pass_name :: (name: string) -> bool {
    if name == "module" return true;
    if name == "function" || begins_with(name, "function<") return true;   // still a module-level element
    if name == "cgscc" || name == "loop" || name == "loop-mssa" return false;
    p := lookup_pass(name);
    return p != null && p.level == .MODULE;
}

new_node :: (kind: Pass_Kind, info: *Pass_Info, name: string) -> s32 {
    n: Pass_Node; n.kind = kind; n.info = info; n.name = name;
    id := cast(s32) pipeline.nodes.count;
    array_add(*pipeline.nodes, n);
    return id;
}
link_child :: (parent: s32, last: *s32, child: s32) {
    if last.* >= 0 pipeline.nodes[last.*].next = child; else pipeline.nodes[parent].first_child = child;
    last.* = child;
}

unknown_pass :: (name: string) {
    if name == "loop" || name == "loop-mssa" || name == "cgscc" || name == "machine-function"
        fatal("pass pipeline: '%' pass managers are not supported yet", name);
    fatal("unknown pass name '%' (not implemented in the Jai opt yet)", name);
}

// parseFunctionPass: one element inside a function pipeline
parse_function_pass :: (fpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "function" fatal("pass pipeline: nested function pipelines are not supported");
        unknown_pass(el.name);
    }
    p := lookup_pass(el.name);
    if p == null || p.level == .MODULE unknown_pass(el.name);
    if p.level == .LOOP unknown_pass(el.name);
    link_child(fpm, last, new_node(p.kind, p, el.name));
}

// parseModulePass
parse_module_pass :: (mpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "module" {
            inner := new_node(.MODULE_PM, null, "module");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_module_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            link_child(mpm, last, inner);
            return;
        }
        if el.name == "function" || el.name == "function<eager-inv>" {
            fa := new_node(.FUNCTION_ADAPTOR, null, el.name);
            flast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_function_pass(fa, *flast, c); c = pipeline.elems[c].next; }
            link_child(mpm, last, fa);
            return;
        }
        unknown_pass(el.name);
    }
    p := lookup_pass(el.name);
    if p == null unknown_pass(el.name);
    if p.level == .MODULE { link_child(mpm, last, new_node(p.kind, p, el.name)); return; }
    if p.level == .FUNCTION {
        // a function pass in a module pipeline gets its own ModuleToFunctionPassAdaptor
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        link_child(fa, *flast, new_node(p.kind, p, el.name));
        link_child(mpm, last, fa);
        return;
    }
    unknown_pass(el.name);
}

// PassBuilder::parsePassPipeline(MPM, Text): returns the root MODULE_PM node.
parse_pass_pipeline :: (text: string) -> s32 {
    first := parse_pipeline_text(text);
    if first < 0 pipeline_error("empty pipeline");
    root := new_node(.MODULE_PM, null, "module");
    last: s32 = -1;
    name := pipeline.elems[first].name;
    if !is_module_pass_name(name) {
        p := lookup_pass(name);
        if p == null || p.level != .FUNCTION unknown_pass(name);
        // Pipeline = {{"function", std::move(*Pipeline)}}
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        e := first;
        while e >= 0 { parse_function_pass(fa, *flast, e); e = pipeline.elems[e].next; }
        link_child(root, *last, fa);
        return root;
    }
    e := first;
    while e >= 0 { parse_module_pass(root, *last, e); e = pipeline.elems[e].next; }
    return root;
}

// ---------------------------------------------------------------- command-line options (cl::opt)

Cl_Kind :: enum u8 { BOOL; INT; IGNORED; }
Cl_Opt :: struct {
    name: string;
    kind: Cl_Kind;
    b: *bool;
    i: *s64;
}

opts: struct {
    adce_remove_control_flow := true;    // ADCE.cpp -adce-remove-control-flow
    adce_remove_loops := false;          // ADCE.cpp -adce-remove-loops
    opt_bisect_limit: s64 = -1;          // OptBisect.cpp -opt-bisect-limit
    verify_dom_info := false;            // -verify-dom-info (only checks; output unaffected)
};

cl_opts :: () -> [] Cl_Opt {
    // pointers into the global `opts`
    list := NewArray(4, Cl_Opt,, allocator = temp);
    list[0] = .{"adce-remove-control-flow", .BOOL, *opts.adce_remove_control_flow, null};
    list[1] = .{"adce-remove-loops", .BOOL, *opts.adce_remove_loops, null};
    list[2] = .{"opt-bisect-limit", .INT, null, *opts.opt_bisect_limit};
    list[3] = .{"verify-dom-info", .BOOL, *opts.verify_dom_info, null};
    return list;
}

// Parse `-name`, `--name`, `-name=value`. Returns false if the option isn't known.
parse_cl_opt :: (arg: string) -> bool {
    a := arg;
    if begins_with(a, "--") a = slice(a, 2, a.count - 2); else if begins_with(a, "-") a = slice(a, 1, a.count - 1); else return false;
    name := a; value := ""; has_value := false;
    eq := find_index_from_left(a, #char "=");
    if eq >= 0 { name = slice(a, 0, eq); value = slice(a, eq + 1, a.count - eq - 1); has_value = true; }
    for cl_opts() {
        if it.name != name continue;
        if it.kind == .BOOL {
            if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" it.b.* = true;
            else if value == "false" || value == "0" || value == "FALSE" || value == "False" it.b.* = false;
            else fatal("invalid boolean value '%' for option -%", value, name);
        } else if it.kind == .INT {
            if !has_value fatal("option -% needs a value", name);
            v, ok := string_to_int(value);
            if !ok fatal("invalid integer value '%' for option -%", value, name);
            it.i.* = v;
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- running

bisect_count: s64 = 0;

// PassInstrumentation::runBeforePass: every shouldRun callback is called (OptNone, then OptPassGate).
should_run_pass :: (node: *Pass_Node, f: Value_Id) -> bool {
    if node.info && node.info.required return true;
    run := true;
    // OptNoneInstrumentation
    if f != NONE && attr_set_has(attr_list_fn(glob(f).attrs), .OptimizeNone) run = false;
    // OptPassGateInstrumentation -> OptBisect::shouldRunPass
    if opts.opt_bisect_limit >= 0 {
        bisect_count += 1;
        ok := bisect_count <= opts.opt_bisect_limit;
        desc := ifx f != NONE then vname(f) else "[module]";
        print_stderr("BISECT: %running pass (%) % on %\n", ifx ok then "" else "NOT ", bisect_count, node.name, desc);
        if !ok run = false;
    }
    return run;
}

print_stderr :: (fmt: string, args: .. Any) {
    s := tprint(fmt, ..args);
    write_string(s, to_standard_error = true);
}

run_module_pm :: (n: s32) {
    c := pipeline.nodes[n].first_child;
    while c >= 0 {
        node := *pipeline.nodes[c];
        if node.kind == {
            case .MODULE_PM; run_module_pm(c);
            case .FUNCTION_ADAPTOR; run_function_adaptor(c);
            case .NO_OP_MODULE; should_run_pass(node, NONE);
            case; fatal("internal: '%' is not a module pass", node.name);
        }
        c = pipeline.nodes[c].next;
    }
}

// ModuleToFunctionPassAdaptor::run: every defined function in module order
run_function_adaptor :: (n: s32) {
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        i += 1;
        if is_declaration(f) continue;
        c := pipeline.nodes[n].first_child;
        while c >= 0 {
            node := *pipeline.nodes[c];
            if should_run_pass(node, f) {
                pa := run_function_pass(node, f);
                if !pa.all printer_note_ir_changed();
                fam_invalidate(f, pa);
            }
            reset_temporary_storage();
            c = pipeline.nodes[c].next;
        }
    }
}

stderr_builder: String_Builder;

run_function_pass :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    if node.kind == {
        case .NO_OP_FUNCTION; return PRESERVE_ALL;
        case .REQUIRE; fam_require(f, node.info.analysis); return PRESERVE_ALL;
        case .INVALIDATE; fam_invalidate_one(f, node.info.analysis); return PRESERVE_ALL;
        case .PRINT_DOMTREE;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "DominatorTree for function: %\n", vname(f));
            dt_print(get_domtree(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_POSTDOMTREE;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "PostDominatorTree for function: %\n", vname(f));
            dt_print(get_postdomtree(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_DEMANDED_BITS;
            sb: String_Builder; sb.allocator = temp;
            db_print(get_demanded_bits(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .DCE; return dce_run(f);
        case .ADCE; return adce_run(f);
        case .BDCE; return bdce_run(f);
        case .BREAK_CRIT_EDGES; return break_crit_edges_run(f);
    }
    fatal("internal: '%' is not a function pass", node.name);
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- opt's main

opt_main :: () {
    tool_name = "opt";
    args := get_command_line_arguments();
    input := "";
    output := "-";
    passes := "";
    disable_output := false;
    have_passes := false;
    i := 1;
    while i < args.count {
        a := args[i];
        i += 1;
        if a == "-S" continue;
        if a == "-o" { if i >= args.count fatal("-o needs a file"); output = args[i]; i += 1; continue; }
        if a == "-disable-output" || a == "--disable-output" { disable_output = true; continue; }
        if begins_with(a, "-passes=") || begins_with(a, "--passes=") {
            eq := find_index_from_left(a, #char "=");
            passes = slice(a, eq + 1, a.count - eq - 1);
            have_passes = true;
            continue;
        }
        if a == "-passes" || a == "--passes" { if i >= args.count fatal("-passes needs a value"); passes = args[i]; i += 1; have_passes = true; continue; }
        if a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" || a == "-Os" || a == "-Oz"
            fatal("'%' pipelines are not implemented yet (only -passes=<pipeline> with the passes in impl/jai/src/passes.jai)", a);
        if begins_with(a, "-") && a != "-" {
            if parse_cl_opt(a) continue;
            fatal("unsupported option '%'", a);
        }
        input = a;
    }
    root: s32 = -1;
    if have_passes root = parse_pass_pipeline(passes);
    if input.count == 0 fatal("no input file");
    if input == "-" fatal("reading from stdin is not supported");
    src, ok := read_entire_file(input);
    if !ok fatal("could not open input file '%'", input);
    ir_init();
    ir.module_id = input;
    parse_module(src, input);
    if ir.source_filename.count == 0 && !saw_source_filename ir.source_filename = input;
    if root >= 0 run_module_pm(root);
    if disable_output return;
    text := print_module_fresh();
    if output == "-" write_string(text);
    else if !write_entire_file(output, text) fatal("could not write '%'", output);
}
