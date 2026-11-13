// LoopVersioning: port of llvm/lib/Transforms/Utils/LoopVersioning.cpp (whole: versionLoop, addPHINodes,
// prepareNoAliasMetadata, annotateLoopWithNoAlias, annotateInstWithNoAlias, the loop-versioning pass), with
// addRuntimeChecks / expandBounds / findDefsUsedOutsideOfLoop (llvm/lib/Transforms/Utils/LoopUtils.cpp),
// CloneBasicBlock / cloneLoopWithPreheader / remapInstructionsInBlocks (llvm/lib/Transforms/Utils/CloneFunction.cpp,
// for an innermost loop), MDNode::concatenate (llvm/lib/IR/Metadata.cpp) and MDBuilder::createAnonymousAARoot
// (llvm/lib/IR/MDBuilder.cpp).
// One versioning at a time: VMap is lver_vmap (an HMap value -> clone).
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import loopinfo;
import loopsimplify;
import lcssa;
import dinfo;
import memloc;
import profdata;
import instsimplify;
import vt;
import scev;
import scev_create;
import scev_update;
import scev_lt;
import scev_expander;
import scev_range;
import scev_guards;
import scev_eval;
import scev_btc;
import pse;
import laa;
import loop_utils;

fn lver_not_ported(what: const u8[:]) { fatal(str("LoopVersioning: ", what, " is not ported yet")); }

var lver_vmap = hm_new();
var lver_vmap_cur: i32 = 0;     // which VMap (0 = LoopVersioning's, 1 + n = LoopDistribute partition n's)
var lver_vmap_n: i32[>..<];     // entries per VMap (VMap.empty())
fn lver_key(v: i32) -> u64 { ((lver_vmap_cur as u64) << 32) | (v as u64) }
fn lver_map(v: i32) -> i32 { hm_get(lver_vmap, lver_key(v), -1) as i32 }
fn lver_map_set(k: i32, v: i32) {
    while lver_vmap_n.len <= lver_vmap_cur as i64 { lver_vmap_n.push(0); }
    if lver_map(k) < 0 { lver_vmap_n[lver_vmap_cur] += 1; }
    hm_put(lver_vmap, lver_key(k), v as i64);
}
fn lver_map_empty() -> bool { lver_vmap_cur as i64 >= lver_vmap_n.len || lver_vmap_n[lver_vmap_cur] == 0 }
fn lver_map_or_self(v: i32) -> i32 { let m = lver_map(v); if m >= 0 { m } else { v } }

// CloneBasicBlock(BB, VMap, NameSuffix, F)
fn lver_clone_basic_block(bb: i32, suffix: const u8[:], fv: i32) -> i32 {
    let nb = create_block_after(fv, globs[glob_of(fv)].last_block, "");
    if vals[bb].name >= 0 {
        var nm: u8[>..] = [];
        nm.append(val_name(bb));
        nm.append(suffix);
        set_name(nb, nm);
    }
    var i = block_first(bb);
    while i >= 0 {
        let c = inst_clone(i);
        block_append_inst(nb, c);
        if vals[i].name >= 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(i));
            nm.append(suffix);
            set_name(c, nm);
        }
        // cloneDebugInfoFrom(&I)
        var r = inst_first_dbg(i);
        while r >= 0 {
            if dbgrecs[r].kind as i64 == DR_ASSIGN { lver_not_ported("cloning dbg_assign records"); }
            let nr = dbg_clone_record(r);
            inst_add_dbg(c, nr);
            r = dbgrecs[r].next;
        }
        lver_map_set(i, c);
        i = inst_next(i);
    }
    return nb;
}

// cloneLoopWithPreheader(Before, LoopDomBB, OrigLoop, VMap, NameSuffix, LI, DT, Blocks)
fn lver_clone_loop_with_preheader(before: i32, loop_dom_bb: i32, orig: i32, suffix: const u8[:], out: i32[>..<]&) -> i32 {
    let fv = block_func(loop_header(orig));
    if loop_nsubs(orig) != 0 { lver_not_ported("cloning a loop with subloops"); }
    let parent = loop_parent(orig);
    let nl = li_allocate_loop(fv);
    if parent >= 0 { loop_add_child(parent, nl); } else { li_add_top_level_loop(fv, nl); }
    let oph = loop_preheader(orig);
    let nph = lver_clone_basic_block(oph, suffix, fv);
    lver_map_set(oph, nph);
    out.push(nph);
    if parent >= 0 { loop_add_basic_block_to_loop(parent, nph); }
    dt_add_new_block(fv, DT_DOM, nph, loop_dom_bb);
    var obs: i32[>..<] = [];
    for k in loop_nblocks(orig) { obs.push(loop_block(orig, k)); }
    for bb in obs {
        let nb = lver_clone_basic_block(bb, suffix, fv);
        lver_map_set(bb, nb);
        loop_add_basic_block_to_loop(nl, nb);
        dt_add_new_block(fv, DT_DOM, nb, nph);
        out.push(nb);
    }
    for bb in obs {
        if bb == loop_header(orig) { loop_move_to_header(nl, lver_map(bb)); }
        let idom = dt_idom(DT_DOM, bb);
        dt_change_idom(fv, DT_DOM, lver_map(bb), lver_map(idom));
    }
    // F->splice(Before, F, NewPH); F->splice(Before, F, NewLoop->getHeader(), F->end())
    block_move_before(nph, before);
    var x = loop_header(nl);
    while x >= 0 {
        let nx = block_next(x);
        block_move_before(x, before);
        x = nx;
        if x == before { break; }
    }
    return nl;
}

// remapInstructionsInBlocks(Blocks, VMap) (RF_NoModuleLevelChanges | RF_IgnoreMissingLocals)
fn lver_remap_blocks(bbs: const i32[:]) {
    for bb in bbs {
        var i = block_first(bb);
        while i >= 0 {
            // RemapDbgRecordRange
            var r = inst_first_dbg(i);
            while r >= 0 {
                var ops: i32[>..<] = [];
                dbg_location_ops(r, ops);
                for k in ops.len {
                    let m = lver_map(ops[k]);
                    if m >= 0 { dbg_replace_location_op_idx(r, k, m); }
                }
                r = dbgrecs[r].next;
            }
            for k in nops(i) {
                let o = op(i, k);
                if o < 0 { continue; }
                if vals[o].kind == VK_MDVAL {
                    let md = vals[o].sub;
                    if mds[md].kind == MK_VALUE && lver_map(mds[md].extra) >= 0 { lver_not_ported("remapping a metadata-as-value operand"); }
                    continue;
                }
                let m = lver_map(o);
                if m >= 0 { set_op(i, k, m); }
            }
            if iop(i) == OP_PHI {
                for k in nops(i) {
                    let b = phi_block(i, k);
                    let m = lver_map(b);
                    if m >= 0 { phi_set_block(i, k, m); }
                }
            }
            i = inst_next(i);
        }
    }
}

// IRBuilder<InstSimplifyFolder> (no expander attached)
var lvb_pos: i32 = -1;
var lvb_dl: i32 = -1;
fn lvb_set_before(i: i32) { lvb_pos = i; lvb_dl = inst_get_md(i, 0); }
fn lvb_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_before(iv, lvb_pos);
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if lvb_dl >= 0 { inst_set_md(iv, 0, lvb_dl); }
    return iv;
}
fn lvb_binop(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    let f = sxf_binop(o, a, b);
    if f >= 0 { return f; }
    return lvb_insert(create_inst(o, vals[a].ty, [a, b]), name);
}
fn lvb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    let f = sxf_cmp(p, a, b);
    if f >= 0 { return f; }
    let c = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(c)].pred = p as u8;
    return lvb_insert(c, name);
}

// expandBounds(CG, TheLoop, Loc, Exp, HoistRuntimeChecks): start, end, stride to check (-1 = none)
fn lver_expand_bounds_h(g: i64, l: i32, loc: i32, hoist: bool) -> i32, i32, i32 {
    let grp = rpc_groups[g];
    let pty = ty_ptr(grp.as_);
    var low = grp.low;
    var high = grp.high;
    var stride: i32 = -1;
    if hoist && loop_parent(l) >= 0 && sc_is_addrec(high) && sc_is_addrec(low) {
        let outer = loop_parent(l);
        let recur = sc_get_step_recurrence(low);
        if recur == sc_get_step_recurrence(high) && sc_loop(high) == outer && sc_loop(low) == outer {
            let oec = sc_get_exit_count(outer, loop_latch(outer), BTC_EXACT, false);
            if !sc_is_cnc(oec) && ty_is_int(sc_ty(oec)) {
                let nh = sc_evaluate_at_iteration(high, oec);
                if !sc_is_cnc(nh) {
                    let hl = sc_loop(high);
                    high = nh;
                    low = sc_op(low, 0);
                    if !sc_is_known_non_negative(sc_apply_loop_guards(recur, hl)) { stride = recur; }
                }
            }
        }
    }
    var start = sx_expand_code_for_at(low, pty, loc);
    var end = sx_expand_code_for_at(high, pty, loc);
    if grp.freeze {
        lvb_set_before(loc);
        var nm: u8[>..] = [];
        if vals[start].name >= 0 { nm.append(val_name(start)); }
        nm.append(".fr");
        start = lvb_insert(create_inst(OP_FREEZE, vals[start].ty, [start]), nm);
        var nm2: u8[>..] = [];
        if vals[end].name >= 0 { nm2.append(val_name(end)); }
        nm2.append(".fr");
        end = lvb_insert(create_inst(OP_FREEZE, vals[end].ty, [end]), nm2);
    }
    let sv = if stride >= 0 { sx_expand_code_for_at(stride, sc_ty(stride), loc) } else { -1 };
    return start, end, sv;
}

// addRuntimeChecks(Loc, TheLoop, PointerChecks, Exp, HoistRuntimeChecks = false): -1 = nullptr
fn lver_add_runtime_checks(loc: i32, checks: const i64[:]) -> i32 { lver_add_runtime_checks_h(loc, -1, checks, false) }
// addRuntimeChecks(Loc, TheLoop, PointerChecks, Exp, HoistRuntimeChecks)
fn lver_add_runtime_checks_h(loc: i32, l: i32, checks: const i64[:], hoist: bool) -> i32 {
    var bs: i32[>..<] = [];
    for c in checks {
        let a_s, a_e, a_st = lver_expand_bounds_h(c / 4294967296, l, loc, hoist);
        let b_s, b_e, b_st = lver_expand_bounds_h(c % 4294967296, l, loc, hoist);
        bs.push(a_s); bs.push(a_e); bs.push(a_st); bs.push(b_s); bs.push(b_e); bs.push(b_st);
    }
    lvb_set_before(loc);
    var mrc: i32 = -1;
    for k in checks.len {
        let a_s = bs[6 * k];
        let a_e = bs[6 * k + 1];
        let a_st = bs[6 * k + 2];
        let b_s = bs[6 * k + 3];
        let b_e = bs[6 * k + 4];
        let b_st = bs[6 * k + 5];
        let c0 = lvb_icmp(P_ULT, a_s, b_e, "bound0");
        let c1 = lvb_icmp(P_ULT, b_s, a_e, "bound1");
        var conflict = lvb_binop(OP_AND, c0, c1, "found.conflict");
        if a_st >= 0 {
            let neg = lvb_icmp(P_SLT, a_st, c_int(vals[a_st].ty as i32, 0), "stride.check");
            conflict = lvb_binop(OP_OR, conflict, neg, "");
        }
        if b_st >= 0 {
            let neg = lvb_icmp(P_SLT, b_st, c_int(vals[b_st].ty as i32, 0), "stride.check");
            conflict = lvb_binop(OP_OR, conflict, neg, "");
        }
        if mrc >= 0 { conflict = lvb_binop(OP_OR, mrc, conflict, "conflict.rdx"); }
        mrc = conflict;
    }
    sx_erase_dead_instructions(mrc);
    return mrc;
}

// findDefsUsedOutsideOfLoop(L)
fn lver_defs_used_outside(l: i32, out: i32[>..<]&) {
    out.clear();
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            var u = vals[i].first_use;
            while u >= 0 {
                if !loop_contains(l, inst_parent(uses[u].user)) { out.push(i); break; }
                u = uses[u].next;
            }
            i = inst_next(i);
        }
    }
}

// The LoopVersioning object
var lver_l: i32 = -1;            // VersionedLoop
var lver_nl: i32 = -1;           // NonVersionedLoop
var lver_checks: i64[>..<];      // AliasChecks (pairs of LAA group indices)
var lver_preds: i32 = -1;        // Preds (the LAI's union predicate)
// noalias metadata
var lver_group_scope: i32[>..<];     // GroupToScope (by group index)
var lver_ptr_key: i32[>..<];         // PtrToGroup
var lver_ptr_grp: i32[>..<];
var lver_nonalias_list: i32[>..<];   // GroupToNonAliasingScopeList (by group index; -1 = none)

fn lver_init(l: i32, checks: const i64[:]) {
    lver_l = l;
    lver_nl = -1;
    lver_checks.clear();
    for c in checks { lver_checks.push(c); }
    lver_preds = pse_union(lai_pse);
    hm_clear(lver_vmap);
    lver_vmap_n.clear();
    lver_vmap_cur = 0;
}

// versionLoop(DefsUsedOutside)
fn lver_version_loop(defs: const i32[:]) {
    let l = lver_l;
    let fv = block_func(loop_header(l));
    let rcbb = loop_preheader(l);
    sx_begin("induction", true);
    let mrc = lver_add_runtime_checks(block_terminator(rcbb), lver_checks);
    sx_end();
    sx_begin("scev.check", true);
    let src = sx_expand_union_predicate(lver_preds, block_terminator(rcbb));
    var rc: i32 = -1;
    if mrc >= 0 && src >= 0 {
        lvb_set_before(block_terminator(rcbb));
        rc = lvb_binop(OP_OR, mrc, src, "lver.safe");
    } else { rc = if mrc >= 0 { mrc } else { src }; }
    sx_erase_dead_instructions(src);
    sx_end();
    var nm: u8[>..] = [];
    nm.append(val_name(loop_header(l)));
    nm.append(".lver.check");
    set_name(rcbb, nm);
    var phn: u8[>..] = [];
    phn.append(val_name(loop_header(l)));
    phn.append(".ph");
    let ph = lu_split_block_named(rcbb, block_terminator(rcbb), phn, false);
    var nbs: i32[>..<] = [];
    lver_nl = lver_clone_loop_with_preheader(ph, rcbb, l, ".lver.orig", nbs);
    lver_remap_blocks(nbs);
    let ot = block_terminator(rcbb);
    lvb_set_before(ot);
    let bi = lvb_insert(create_inst(OP_CONDBR, T_VOID, [rc, loop_preheader(lver_nl), loop_preheader(l)]), "");
    lver_set_unknown_weights_if_profiled(bi, fv);
    inst_erase_from_parent(ot);
    dt_change_idom(fv, DT_DOM, lver_exit_block(l), rcbb);
    lver_add_phi_nodes(defs);
    let save = ls_mssau;
    ls_mssau = false;
    form_dedicated_exit_blocks(lver_nl, true);
    form_dedicated_exit_blocks(l, true);
    ls_mssau = save;
}

// setExplicitlyUnknownBranchWeightsIfProfiled(BI, "loop-versioning")
fn lver_set_unknown_weights_if_profiled(i: i32, fv: i32) {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd {
        if md_att[globs[g].md + 2 * j] != k { continue; }
        let m = md_att[globs[g].md + 2 * j + 1];
        if mds[m].nops < 2 || !pd_md_string_is(md_op(m, 0), "function_entry_count") { return; }
        let o = md_op(m, 1);
        if o < 0 || mds[o].kind != MK_VALUE || !is_cint(mds[o].extra) || cint_is_zero(mds[o].extra) { return; }
        let ops: i32[2] = [md_string("unknown"), md_string("loop-versioning")];
        inst_set_md(i, MDK_PROF, md_get(MK_TUPLE, -1, ops, false));
        return;
    }
}

// Loop::getExitBlock
fn lver_exit_block(l: i32) -> i32 {
    var r: i32 = -1;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if loop_contains(l, s) { continue; }
            if r >= 0 { return -1; }
            r = s;
        }
    }
    return r;
}

// addPHINodes(DefsUsedOutside)
fn lver_add_phi_nodes(defs: const i32[:]) {
    let pb = lver_exit_block(lver_l);
    for inst in defs {
        var found: i32 = -1;
        var p = block_first(pb);
        while p >= 0 && iop(p) == OP_PHI {
            if op(p, 0) == inst {
                sc_forget_lcssa_phi_with_new_predecessor(lver_l, p);
                found = p;
                break;
            }
            p = inst_next(p);
        }
        if found < 0 {
            let pn = new_inst(OP_PHI, vals[inst].ty, 2);
            vals[pn].nops = 0;
            inst_insert_before_head(pn, block_first(pb));
            var nm: u8[>..] = [];
            if vals[inst].name >= 0 { nm.append(val_name(inst)); }
            nm.append(".lver");
            set_name(pn, nm);
            var users: i32[>..<] = [];
            var u = vals[inst].first_use;
            while u >= 0 {
                let us = uses[u].user;
                if !loop_contains(lver_l, inst_parent(us)) { users.push(us); }
                u = uses[u].next;
            }
            for us in users { for k in nops(us) { if op(us, k) == inst { set_op(us, k, pn); } } }
            phi_add_incoming(pn, inst, loop_exiting_block(lver_l));
        }
    }
    var p = block_first(pb);
    while p >= 0 && iop(p) == OP_PHI {
        let cv = lver_map_or_self(phi_value(p, 0));
        phi_add_incoming(p, cv, loop_exiting_block(lver_nl));
        p = inst_next(p);
    }
}

// MDBuilder::createAnonymousAARoot(Name, Extra): distinct !{self, [Extra,] [!"Name"]}
fn lver_anonymous_root(name: const u8[:], extra: i32) -> i32 {
    var ops: i32[>..<] = [];
    ops.push(-1);
    if extra >= 0 { ops.push(extra); }
    if name.len > 0 { ops.push(md_string(name)); }
    let r = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[r].ops] = r;
    return r;
}

// prepareNoAliasMetadata
fn lver_prepare_noalias_metadata() {
    let domain = lver_anonymous_root("LVerDomain", -1);
    lver_group_scope.clear();
    lver_ptr_key.clear();
    lver_ptr_grp.clear();
    lver_nonalias_list.clear();
    for g in rpc_groups.len {
        lver_group_scope.push(lver_anonymous_root("", domain));
        lver_nonalias_list.push(-1);
        let grp = rpc_groups[g];
        for k in grp.n as i64 {
            let p = rpc_ptrs[rpc_gmem[(grp.at as i64) + k]].ptr;
            var f = false;
            for j in lver_ptr_key.len { if lver_ptr_key[j] == p { lver_ptr_grp[j] = g as i32; f = true; } }
            if !f { lver_ptr_key.push(p); lver_ptr_grp.push(g as i32); }
        }
    }
    for g in rpc_groups.len {
        var ops: i32[>..<] = [];
        for c in lver_checks { if c / 4294967296 == g { ops.push(lver_group_scope[c % 4294967296]); } }
        if ops.len > 0 { lver_nonalias_list[g] = md_get(MK_TUPLE, -1, ops, false); }
    }
}

// MDNode::concatenate(A, B)
fn lver_md_concatenate(a: i32, b: i32) -> i32 {
    if a < 0 { return b; }
    if b < 0 { return a; }
    var ops: i32[>..<] = [];
    for k in mds[a].nops as i64 { let o = md_op(a, k); var d = false; for x in ops { if x == o { d = true; } } if !d { ops.push(o); } }
    for k in mds[b].nops as i64 { let o = md_op(b, k); var d = false; for x in ops { if x == o { d = true; } } if !d { ops.push(o); } }
    // getOrSelfReference
    if ops.len > 0 && ops[0] >= 0 && md_is_node(ops[0]) {
        let n = ops[0];
        if mds[n].nops as i64 == ops.len && md_op(n, 0) == n {
            var same = true;
            for k in 1..ops.len { if ops[k] != md_op(n, k) { same = false; } }
            if same { return n; }
        }
    }
    return md_get(MK_TUPLE, -1, ops, false);
}

// getNoAliasMetadataFor(OrigInst): (alias.scope, noalias), -1 = nullptr
fn lver_noalias_md_for(oi: i32) -> i32, i32 {
    if !flag_bool("loop-version-annotate-no-alias", true) { return -1, -1; }
    let ptr = if iop(oi) == OP_LOAD { op(oi, 0) } else { op(oi, 1) };
    var g: i32 = -1;
    for j in lver_ptr_key.len { if lver_ptr_key[j] == ptr { g = lver_ptr_grp[j]; } }
    if g < 0 { return -1, -1; }
    let one: i32[1] = [lver_group_scope[g]];
    let scope = lver_md_concatenate(inst_get_md(oi, MDK_ALIAS_SCOPE), md_get(MK_TUPLE, -1, one, false));
    var noalias: i32 = -1;
    if lver_nonalias_list[g] >= 0 { noalias = lver_md_concatenate(inst_get_md(oi, MDK_NOALIAS), lver_nonalias_list[g]); }
    return scope, noalias;
}

// annotateInstWithNoAlias(VersionedInst, OrigInst)
fn lver_annotate_inst_with_noalias(vi: i32, oi: i32) {
    if !flag_bool("loop-version-annotate-no-alias", true) { return; }
    let ptr = if iop(oi) == OP_LOAD { op(oi, 0) } else { op(oi, 1) };
    var g: i32 = -1;
    for j in lver_ptr_key.len { if lver_ptr_key[j] == ptr { g = lver_ptr_grp[j]; } }
    if g < 0 { return; }
    let one: i32[1] = [lver_group_scope[g]];
    let scope = lver_md_concatenate(inst_get_md(oi, MDK_ALIAS_SCOPE), md_get(MK_TUPLE, -1, one, false));
    var noalias: i32 = -1;
    if lver_nonalias_list[g] >= 0 { noalias = lver_md_concatenate(inst_get_md(oi, MDK_NOALIAS), lver_nonalias_list[g]); }
    if scope >= 0 { inst_set_md(vi, MDK_ALIAS_SCOPE, scope); }
    if noalias >= 0 { inst_set_md(vi, MDK_NOALIAS, noalias); }
}

// annotateLoopWithNoAlias
fn lver_annotate_loop_with_noalias() {
    if !flag_bool("loop-version-annotate-no-alias", true) { return; }
    lver_prepare_noalias_metadata();
    var seen: i32[>..<] = [];
    for i in mdc_inst {
        lver_annotate_inst_with_noalias(i, i);
        let unused = seen;
    }
}

// Loop::isRecursivelyLCSSAForm for an innermost loop
fn lver_is_lcssa_form(l: i32) -> bool {
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            if vals[i].ty != T_TOKEN {
                var u = vals[i].first_use;
                while u >= 0 {
                    let us = uses[u].user;
                    var ubb = inst_parent(us);
                    if iop(us) == OP_PHI { ubb = use_aux[u]; }
                    if ubb != bb && !loop_contains(l, ubb) && dt_has_node(DT_DOM, ubb) { return false; }
                    u = uses[u].next;
                }
            }
            i = inst_next(i);
        }
    }
    return true;
}
// Loop::isRotatedForm
fn lver_is_rotated_form(l: i32) -> bool { let lt = loop_latch(l); lt >= 0 && loop_is_exiting(l, lt) }

// LoopVersioningPass::run
fn loop_versioning_run(fv: i32) -> u32 {
    li_get(fv);
    dt_get(fv, DT_DOM);
    scev_get(fv);
    aa_begin_lv(fv);
    var wl: i32[>..<] = [];
    lver_innermost_preorder(fv, wl);
    var changed = false;
    for l in wl {
        if !loop_is_simplify_form(l) || !lver_is_rotated_form(l) || loop_exiting_block(l) < 0 { continue; }
        lai_compute(l, false);
        if !lai_has_convergent && (rpc_checks.len != 0 || !su_always_true(pse_union(lai_pse))) {
            if !lver_is_lcssa_form(l) {
                let s = lcssa_se; lcssa_se = true; form_lcssa_recursively(l); lcssa_se = s;
            }
            lver_init(l, rpc_checks);
            var defs: i32[>..<] = [];
            lver_defs_used_outside(l, defs);
            lver_version_loop(defs);
            lver_annotate_loop_with_noalias();
            changed = true;
        }
    }
    pse_reset();
    if changed { return PA_NONE; }
    return PA_ALL;
}
fn aa_begin_lv(fv: i32) { aa_begin(fv); tli_cur_fn = fv; }

// for (Loop *TopLevelLoop : LI) for (Loop *L : depth_first(TopLevelLoop)) if innermost
fn lver_innermost_preorder(fv: i32, out: i32[>..<]&) {
    for k in li_ntop(fv) {
        var st: i32[>..<] = [];
        st.push(li_top(fv, k));
        while st.len > 0 {
            let l = st.pop();
            if loop_is_innermost(l) { out.push(l); }
            var c = loop_nsubs(l) - 1;
            while c >= 0 { st.push(loop_sub(l, c)); c--; }
        }
    }
}
