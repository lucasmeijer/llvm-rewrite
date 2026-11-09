// Cloning basic blocks and loops: port of llvm/lib/Transforms/Utils/CloneFunction.cpp (CloneBasicBlock,
// remapInstructionsInBlocks, cloneLoopWithPreheader, cloneNoAliasScopes, adaptNoAliasScopes,
// cloneAndAdaptNoAliasScopes (both overloads), identifyNoAliasScopesToClone (both overloads)).
// ValueToValueMapTy and RemapInstruction are value_mapper.goose.
//
// Not ported (fail loudly): key-instruction atom groups (mapAtomInstance), function cloning
// (CloneFunctionInto / CloneAndPruneFunctionInto, for the inliner).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import dinfo;
import domtree;
import loopinfo;
import loopsimplify;
import parser;
import value_mapper;

// ClonedCodeInfo (the parts CloneBasicBlock fills in)
var cln_contains_calls: bool = false;
var cln_contains_dynamic_allocas: bool = false;
var cln_contains_memprof: bool = false;

fn cln_clone_insts(bb: i32, nb: i32, m: i32, suffix: const u8[:], map_atoms: bool) {
    var i = block_first(bb);
    while i >= 0 {
        let ni = inst_clone(i);
        block_append_inst(nb, ni);
        if vals[i].name >= 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(i));
            nm.append(suffix);
            set_name(ni, nm);
        }
        var recs: i32[>..<] = [];
        inst_clone_debug_info_from(ni, i, -1, false, recs);
        vmm_set(m, i, ni);
        if map_atoms { vmp_check_atom(ni); }
        if iop(i) == OP_CALL && !inst_is_debug_or_pseudo(i) {
            cln_contains_calls = true;
            if inst_get_md(i, 34) >= 0 || inst_get_md(i, 35) >= 0 { cln_contains_memprof = true; }
        }
        if iop(i) == OP_ALLOCA && !cln_is_static_alloca(i) { cln_contains_dynamic_allocas = true; }
        i = inst_next(i);
    }
}
// AllocaInst::isStaticAlloca
fn cln_is_static_alloca(a: i32) -> bool {
    if vals[op(a, 0)].kind != VK_CINT { return false; }
    let b = inst_parent(a);
    return func_entry(block_func(b)) == b && (insts[inst_of(a)].bits & 1) == 0;
}
// Instruction::isDebugOrPseudoInst: llvm.pseudoprobe (debug intrinsics are records now)
fn inst_is_debug_or_pseudo(i: i32) -> bool { inst_iid(i) == IID_pseudoprobe }

// CloneBasicBlock(BB, VMap, NameSuffix, F, CodeInfo, MapAtoms) with F != nullptr: the new block is appended to
// F (and named) first, then each clone is inserted and named in order.
fn clone_basic_block(bb: i32, m: i32, suffix: const u8[:], fv: i32, map_atoms: bool) -> i32 {
    let nb = create_block_after(fv, func_last_block(fv), "");
    if vals[bb].name >= 0 {
        var nm: u8[>..] = [];
        nm.append(val_name(bb));
        nm.append(suffix);
        set_name(nb, nm);
    }
    cln_clone_insts(bb, nb, m, suffix, map_atoms);
    return nb;
}
// CloneBasicBlock(BB, VMap, NameSuffix) without a function followed at once by F->insert(It, New): the names
// are registered when the block joins the function, the instructions' in order and then the block's. `before`
// is the block It points at (-1 = end()).
fn clone_basic_block_insert(bb: i32, m: i32, suffix: const u8[:], before: i32, map_atoms: bool) -> i32 {
    let fv = block_func(bb);
    let after = if before < 0 { func_last_block(fv) } else { block_prev(before) };
    let nb = if after < 0 { cln_create_block_first(fv) } else { create_block_after(fv, after, "") };
    cln_clone_insts(bb, nb, m, suffix, map_atoms);
    if vals[bb].name >= 0 {
        var nm: u8[>..] = [];
        nm.append(val_name(bb));
        nm.append(suffix);
        set_name(nb, nm);
    }
    return nb;
}
fn cln_create_block_first(fv: i32) -> i32 {
    let nb = create_block_after(fv, func_last_block(fv), "");
    block_move_before(nb, func_entry(fv));
    return nb;
}
fn func_last_block(fv: i32) -> i32 { globs[glob_of(fv)].last_block }

// remapInstructionsInBlocks(Blocks, VMap)
fn remap_instructions_in_blocks(bbs: const i32[:], m: i32) {
    for bb in bbs {
        var i = block_first(bb);
        while i >= 0 {
            remap_dbg_record_range(i, m, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            remap_instruction(i, m, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            i = inst_next(i);
        }
    }
}

// Loop::getLoopsInPreorder
fn loop_loops_in_preorder(l: i32, out: i32[>..<]&) {
    out.push(l);
    var wl: i32[>..<] = [];
    var k = loop_nsubs(l);
    while k > 0 { k--; wl.push(loop_sub(l, k)); }
    while wl.len > 0 {
        let x = wl.pop();
        var j = loop_nsubs(x);
        while j > 0 { j--; wl.push(loop_sub(x, j)); }
        out.push(x);
    }
}

// cloneLoopWithPreheader(Before, LoopDomBB, OrigLoop, VMap, NameSuffix, LI, DT, Blocks)
fn clone_loop_with_preheader(before: i32, loop_dom_bb: i32, orig: i32, m: i32, suffix: const u8[:], out: i32[>..<]&) -> i32 {
    let fv = block_func(loop_header(orig));
    let parent = loop_parent(orig);
    // LMap: orig loop -> new loop (pairs)
    var lm_o: i32[>..<] = [];
    var lm_n: i32[>..<] = [];
    fn lmap(x: i32) -> i32 { for k in lm_o.len { if lm_o[k] == x { return lm_n[k]; } } return -1; }
    let nl = li_allocate_loop(fv);
    lm_o.push(orig); lm_n.push(nl);
    if parent >= 0 { loop_add_child(parent, nl); } else { li_add_top_level_loop(fv, nl); }
    let oph = loop_preheader(orig);
    let nph = clone_basic_block(oph, m, suffix, fv, false);
    vmm_set(m, oph, nph);
    out.push(nph);
    if parent >= 0 { loop_add_basic_block_to_loop(parent, nph); }
    dt_add_new_block(fv, DT_DOM, nph, loop_dom_bb);
    var pre: i32[>..<] = [];
    loop_loops_in_preorder(orig, pre);
    for cur in pre {
        if lmap(cur) < 0 {
            let x = li_allocate_loop(fv);
            let op_ = loop_parent(cur);
            let np = lmap(op_);
            lm_o.push(cur); lm_n.push(x);
            loop_add_child(np, x);
        }
    }
    let nblocks = loop_nblocks(orig);
    for k in nblocks {
        let bb = loop_block(orig, k);
        let cur = li_loop_for(bb);
        let x = lmap(cur);
        let nb = clone_basic_block(bb, m, suffix, fv, false);
        vmm_set(m, bb, nb);
        loop_add_basic_block_to_loop(x, nb);
        dt_add_new_block(fv, DT_DOM, nb, nph);
        out.push(nb);
    }
    for k in nblocks {
        let bb = loop_block(orig, k);
        let cur = li_loop_for(bb);
        if bb == loop_header(cur) { loop_move_to_header(lmap(cur), vmm_get(m, bb)); }
        let idom = dt_idom(DT_DOM, bb);
        dt_change_idom(fv, DT_DOM, vmm_get(m, bb), vmm_get(m, idom));
    }
    // F->splice(Before, F, NewPH); F->splice(Before, F, NewLoop->getHeader(), F->end())
    block_move_before(nph, before);
    var b = loop_header(nl);
    while b >= 0 { let nx = block_next(b); block_move_before(b, before); b = nx; }
    return nl;
}

// ---------------------------------------------------------------------------------------------
// noalias scopes

// identifyNoAliasScopesToClone(BBs, NoAliasDeclScopes)
fn identify_noalias_scopes_to_clone(bbs: const i32[:], out: i32[>..<]&) {
    for bb in bbs {
        var i = block_first(bb);
        while i >= 0 {
            if inst_iid(i) == IID_experimental_noalias_scope_decl { out.push(cln_scope_list(i)); }
            i = inst_next(i);
        }
    }
}
// identifyNoAliasScopesToClone(Start, End, NoAliasDeclScopes); end = -1 is the block's end
fn identify_noalias_scopes_to_clone_range(start: i32, end: i32, out: i32[>..<]&) {
    var i = start;
    while i >= 0 && i != end {
        if inst_iid(i) == IID_experimental_noalias_scope_decl { out.push(cln_scope_list(i)); }
        i = inst_next(i);
    }
}
fn cln_scope_list(decl: i32) -> i32 { vals[cb_arg(decl, 0)].sub }

// cloneNoAliasScopes(NoAliasDeclScopes, ClonedScopes, Ext): ClonedScopes is the pair list smap (old, new)
fn clone_noalias_scopes(scopes: const i32[:], smap: i32[>..<]&, ext: const u8[:]) {
    for sl in scopes {
        for k in mds[sl].nops as i64 {
            let md = md_op(sl, k);
            if md < 0 || !md_is_node(md) { continue; }
            var dom: i32 = -1;
            if mds[md].nops >= 2 { let d = md_op(md, 1); if d >= 0 && md_is_node(d) { dom = d; } }
            var nm: u8[>..] = [];
            if mds[md].nops > 2 {
                let n = md_op(md, 2);
                if n >= 0 && mds[n].kind == MK_STRING && sbytes(mds[n].extra).len > 0 { nm.append(sbytes(mds[n].extra)); nm.append(":"); }
            }
            nm.append(ext);
            // MDBuilder::createAnonymousAliasScope(Domain, Name)
            var ops: i32[>..] = [];
            ops.push(-1);
            if dom >= 0 { ops.push(dom); }
            if nm.len > 0 { ops.push(md_string(nm)); }
            let root = md_get(MK_TUPLE, -1, ops, true);
            md_ops[mds[root].ops] = root;
            if cln_smap_lookup(smap, md) < 0 { smap.push(md); smap.push(root); }
        }
    }
}
fn cln_smap_lookup(smap: i32[>..<]&, md: i32) -> i32 {
    var j: i64 = 0;
    while j < smap.len { if smap[j] == md { return smap[j + 1]; } j += 2; }
    return -1;
}
fn cln_clone_scope_list(sl: i32, smap: i32[>..<]&) -> i32 {
    var need = false;
    var ops: i32[>..] = [];
    for k in mds[sl].nops as i64 {
        let md = md_op(sl, k);
        if md >= 0 && md_is_node(md) {
            let n = cln_smap_lookup(smap, md);
            if n >= 0 { ops.push(n); need = true; continue; }
            ops.push(md);
        }
    }
    if need { return md_get(MK_TUPLE, -1, ops, false); }
    return -1;
}
// adaptNoAliasScopes(I, ClonedScopes)
fn adapt_noalias_scopes(i: i32, smap: i32[>..<]&) {
    if inst_iid(i) == IID_experimental_noalias_scope_decl {
        let n = cln_clone_scope_list(cln_scope_list(i), smap);
        if n >= 0 { set_op(i, 0, get_md_as_value(n)); }
    }
    let kinds: i32[2] = [8, 7];   // MD_noalias, MD_alias_scope
    for kd in kinds {
        let md = inst_get_md(i, kd);
        if md >= 0 {
            let n = cln_clone_scope_list(md, smap);
            if n >= 0 { inst_set_md(i, kd, n); }
        }
    }
}
// cloneAndAdaptNoAliasScopes(NoAliasDeclScopes, NewBlocks, Context, Ext)
fn clone_and_adapt_noalias_scopes(scopes: const i32[:], bbs: const i32[:], ext: const u8[:]) {
    if scopes.len == 0 { return; }
    var smap: i32[>..<] = [];
    clone_noalias_scopes(scopes, smap, ext);
    for bb in bbs {
        var i = block_first(bb);
        while i >= 0 { adapt_noalias_scopes(i, smap); i = inst_next(i); }
    }
}
// cloneAndAdaptNoAliasScopes(NoAliasDeclScopes, IStart, IEnd, Context, Ext): IEnd included
fn clone_and_adapt_noalias_scopes_range(scopes: const i32[:], istart: i32, iend: i32, ext: const u8[:]) {
    if scopes.len == 0 { return; }
    var smap: i32[>..<] = [];
    clone_noalias_scopes(scopes, smap, ext);
    var i = istart;
    while i >= 0 {
        adapt_noalias_scopes(i, smap);
        if i == iend { break; }
        i = inst_next(i);
    }
}
