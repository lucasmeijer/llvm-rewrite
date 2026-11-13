// LoopExtractor (`loop-extract`, `loop-extract<single>`): a port of llvm/lib/Transforms/IPO/LoopExtractor.cpp
// (LoopExtractor::runOnModule / runOnFunction / extractLoops / extractLoop, LoopExtractorPass::run), and
// BlockExtractor (`extract-blocks`): a port of llvm/lib/Transforms/IPO/BlockExtractor.cpp (loadFile,
// splitLandingPadPreds, runOnModule). The extraction is code_extractor.jai.
//
// Analyses: the DominatorTree and LoopInfo of the function analysis manager are used and updated like LLVM's
// (LI.erase, the CodeExtractor's DT updates); after an extraction code_extractor.jai drops the function's cached
// analyses, so a later pass recomputes LoopInfo instead of reusing the preserved one.

// ---------------------------------------------------------------- LoopExtractor

Loop_Extractor :: struct {
    num_loops: u32;
}

// parseLoopExtractorPassOptions: `loop-extract` / `loop-extract<>` (all loops) or `loop-extract<single>`
loop_extract_parse_params :: (name: string) -> u32 {
    if name == "loop-extract" || name == "loop-extract<>" return 0xFFFF_FFFF;
    if name == "loop-extract<single>" return 1;
    params := slice(name, "loop-extract<".count, name.count - "loop-extract<".count - 1);
    fatal(tprint("invalid pass pipeline: invalid LoopExtractorPass pass parameter '%'", params));
    return 0;
}

// LoopExtractorPass::run
loop_extract_run :: (name: string) -> Preserved {
    le: Loop_Extractor;
    le.num_loops = loop_extract_parse_params(name);
    if !le_run_on_module(*le) return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    preserve(*pa, .LOOPS);
    return pa;
}

// LoopExtractor::runOnModule: the functions present at the start (E = --M.end())
le_run_on_module :: (le: *Loop_Extractor) -> bool {
    if ir.m_functions.count == 0 return false;
    if le.num_loops == 0 return false;
    changed := false;
    last := ir.m_functions.count - 1;
    k := 0;
    while true {
        f := ir.m_functions[k];
        changed |= le_run_on_function(le, f);
        if le.num_loops == 0 break;
        if k == last break;
        k += 1;
    }
    return changed;
}

// LoopExtractor::runOnFunction
le_run_on_function :: (le: *Loop_Extractor, f: Value_Id) -> bool {
    if fn_has_fn_attr(f, .OptimizeNone) return false;
    if is_declaration(f) return false;
    li := get_loop_info(f);
    if li.top_level.count == 0 return false;
    dt := get_domtree(f);
    if li.top_level.count > 1 return le_extract_loops(le, li.top_level, li, dt);
    tll := li.top_level[0];
    if li_is_loop_simplify_form(li, tll) {
        should := false;
        et := block_terminator(fn_entry(f));
        if inst_op(et) == .BR && get_successor(et, 0) != li_header(li, tll) {
            should = true;
        } else {
            exits: [..] Value_Id; exits.allocator = temp;
            li_exit_blocks(li, tll, *exits);
            for exits if inst_op(block_terminator(it)) != .RET { should = true; break; }
        }
        if should return le_extract_loop(le, tll, li, dt);
    }
    return le_extract_loops(le, li_subloops(li, tll), li, dt);
}

// LoopExtractor::extractLoops
le_extract_loops :: (le: *Loop_Extractor, from: [] Loop_Id, li: *Loop_Info, dt: *Dom_Tree) -> bool {
    changed := false;
    loops: [..] Loop_Id; loops.allocator = temp;
    for from array_add(*loops, it);
    for l: loops {
        if !li_is_loop_simplify_form(li, l) continue;
        changed |= le_extract_loop(le, l, li, dt);
        if le.num_loops == 0 break;
    }
    return changed;
}

// LoopExtractor::extractLoop
le_extract_loop :: (le: *Loop_Extractor, l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree) -> bool {
    f := block_fn(li_header(li, l));
    ac := cached_assumption_cache(f);
    cache := ce_cache_new(f);
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, l) array_add(*blocks, it);
    ce := ce_new(blocks, dt, null, null, ac, false, false);
    if !ce_is_eligible(*ce) return false;
    li_erase(li, l);
    out := ce_extract_code_region(*ce, *cache);
    if out == NONE fatal("loop-extract: internal: CodeExtractor didn't extract an eligible loop");
    le.num_loops -= 1;
    return true;
}

// ---------------------------------------------------------------- BlockExtractor

be_cl: struct {
    file: string;          // -extract-blocks-file
    erase_funcs := false;  // -extract-blocks-erase-funcs
};

block_extractor_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "extract-blocks-file" { be_cl.file = copy_string(value); return true; }
    if name == "extract-blocks-erase-funcs" {
        be_cl.erase_funcs = !has_value || value == "true" || value == "1";
        if has_value && !(value == "true" || value == "1" || value == "false" || value == "0")
            fatal(tprint("opt: invalid boolean value '%' for option -%", value, name));
        return true;
    }
    return false;
}

Be_By_Name :: struct { func: string; blocks: [..] string; }

// BlockExtractor::loadFile
be_load_file :: () -> [..] Be_By_Name {
    r: [..] Be_By_Name; r.allocator = temp;
    text, ok := read_entire_file(be_cl.file);
    if !ok fatal("LLVM ERROR: BlockExtractor couldn't load the file.");
    for line: split(text, "\n") {
        if line.count == 0 continue;
        parts: [..] string; parts.allocator = temp;
        for split(line, " ") if it.count array_add(*parts, it);
        if parts.count == 0 continue;
        if parts.count != 2 fatal("LLVM ERROR: Invalid line format, expecting lines like: 'funcname bb1[;bb2..]'");
        e: Be_By_Name; e.func = parts[0]; e.blocks.allocator = temp;
        for split(parts[1], ";") if it.count array_add(*e.blocks, it);
        if e.blocks.count == 0 fatal("LLVM ERROR: Missing bbs name");
        array_add(*r, e);
    }
    return r;
}

// BlockExtractor::splitLandingPadPreds
be_split_landing_pad_preds :: (f: Value_Id) {
    bb := fn_entry(f);
    while bb != NONE {
        i := block_first(bb);
        while i != NONE {
            if inst_op(i) == .INVOKE {
                parent := inst_block(i);
                lpad := get_successor(i, 1);
                split := false;
                preds: [..] Value_Id; preds.allocator = temp;
                block_predecessors(lpad, *preds);
                for p: preds {
                    if block_is_landing_pad(p) && p != parent && inst_op(block_terminator(parent)) == .INVOKE { split = true; break; }
                }
                if split {
                    nbs: [..] Value_Id; nbs.allocator = temp;
                    split_landing_pad_predecessors(lpad, .[parent], ".1", ".2", *nbs, null, null, null, false);
                }
            }
            i = inst_next(i);
        }
        bb = block(bb).next;
    }
}

// BlockExtractorPass::run (no groups of blocks from the API; -extract-blocks-file adds some)
block_extractor_run :: () -> Preserved {
    changed := false;
    functions: [..] Value_Id; functions.allocator = temp;
    for f: ir.m_functions {
        if !is_declaration(f) be_split_landing_pad_preds(f);
        array_add(*functions, f);
    }
    groups: [..] [..] Value_Id; groups.allocator = temp;
    if be_cl.file.count {
        for e: be_load_file() {
            f := module_get_function(e.func);
            if f == NONE fatal("LLVM ERROR: Invalid function name specified in the input file");
            g: [..] Value_Id; g.allocator = temp;
            for name: e.blocks {
                found: Value_Id = NONE;
                for b: fn_blocks(f) if vname(b) == name { found = b; break; }
                if found == NONE fatal("LLVM ERROR: Invalid block name specified in the input file");
                array_add(*g, found);
            }
            array_add(*groups, g);
        }
    }
    for bbs: groups {
        vec: [..] Value_Id; vec.allocator = temp;
        for bb: bbs {
            array_add(*vec, bb);
            t := block_terminator(bb);
            if inst_op(t) == .INVOKE array_add(*vec, get_successor(t, 1));
            changed = true;
        }
        if bbs.count == 0 continue;
        cache := ce_cache_new(block_fn(bbs[0]));
        ce := ce_new(vec, null, null, null, null, false, false);
        ce_extract_code_region(*ce, *cache);
    }
    if be_cl.erase_funcs {
        for functions fn_delete_body(it);
        for ir.m_functions gv_set_linkage(it, .EXTERNAL);
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
