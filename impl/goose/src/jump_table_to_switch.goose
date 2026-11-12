// JumpTableToSwitch: port of llvm/lib/Transforms/Scalar/JumpTableToSwitch.cpp (JumpTableToSwitchPass), with
// getValueProfDataFromInst (llvm/lib/ProfileData/InstrProf.cpp) and downscaleWeights (ProfDataUtils.cpp).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import domtree;
import dtu;
import datalayout;
import apint;
import pm;
import cfold;
import gvn;
import instsimplify;
import ipo_globals;
import ipoutil;
import md5;
import profdata;
import loads;

fn jt2_inst_count(f: i32) -> i64 {
    var n: i64 = 0;
    each_inst(f) { i => n++; };
    return n;
}

// parseJumpTable: the functions (or false)
fn jt2_parse(gep: i32, pty: i32, cfty: i32, funcs: i32[>..<]&) -> bool {
    funcs.clear();
    let p = op(gep, 0);
    if !is_constant(p) || vals[p].kind != VK_GVAR { return false; }
    let g = globs[glob_of(p)];
    if g.is_const == 0 || !gv_has_definitive_initializer(p) { return false; }
    let w = dl_ptr(ptr_as(ty_scalar(vals[gep].ty))).idx;
    if w > 64 { fatal("jump-table-to-switch: index widths over 64 bits are not ported yet"); }
    if !gvn_collect_offset(gep, w) { return false; }
    if gco_vals.len != 1 { return false; }
    if gco_const != 0 { return false; }
    let stride = gco_scale[0];
    let size = dl_alloc_size(g.vty) as u64;
    if stride == 0 || size % stride != 0 { return false; }
    let n = size / stride;
    if n > (flag_int("jump-table-to-switch-size-threshold", 10) as u64) { return false; }
    let fthr = flag_int("jump-table-to-switch-function-size-threshold", 50);
    let init = op(p, 0);
    for k in n as i64 {
        let off = (k as u64) * stride;
        let c = cf_fold_load_from_const(init, pty, off as i64);
        if c < 0 || !is_func(c) || func_is_decl(c) || globs[glob_of(c)].vty != cfty || jt2_inst_count(c) > fthr { return false; }
        funcs.push(c);
    }
    return true;
}

// GetGuidForFunction: !guid, else MD5 of getIRPGOFuncName (InLTO = false: the global identifier)
fn jt2_guid(f: i32) -> u64 {
    let m = func_get_md_jt2(f, md_kind_id("guid"));
    if m >= 0 {
        let o = md_op(m, 0);
        return cint_lo(mds[o].extra);
    }
    var id: u8[>..] = [];
    ig_global_identifier(f, id);
    return md5_hash_u64(id);
}
fn func_get_md_jt2(f: i32, kind: i32) -> i32 {
    let g = glob_of(f);
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == kind { return md_att[globs[g].md + 2 * j + 1]; } }
    return -1;
}

fn jt2_expand(cb: i32, index: i32, funcs: const i32[:]) -> i32 {
    let is_void = vals[cb].ty == T_VOID;
    var ups: DTUpdate[>..<] = [];
    let bb = inst_parent(cb);
    let fv = block_func(bb);
    // SplitBlock(BB, CB, &DTU, nullptr, nullptr, BB->getName() + ".tail")
    let tail = split_block(bb, cb, str(val_name(bb), ".tail"));
    {
        var sups: DTUpdate[>..<] = [];
        sups.push(DTUpdate { kind: DT_INSERT, from: bb, to: tail });
        var seen: i32[>..<] = [];
        for k in block_nsucc(tail) {
            let s = block_succ(tail, k);
            var dup = false;
            for x in seen { if x == s { dup = true; } }
            if dup { continue; }
            seen.push(s);
            sups.push(DTUpdate { kind: DT_INSERT, from: tail, to: s });
            sups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
        }
        dtu_apply_updates(sups);
    }
    ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: tail });
    inst_erase_from_parent(block_terminator(bb));
    let unr = create_block_before(fv, tail, "default.switch.case.unreachable");
    block_append_inst(unr, create_inst(OP_UNREACHABLE, T_VOID, []));
    let sw = create_inst(OP_SWITCH, T_VOID, [index, unr]);
    grow_ops(sw, 22);    // CreateSwitch's NumCases = 10: ReservedSpace 12
    block_append_inst(bb, sw);
    ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: unr });
    var phi: i32 = -1;
    if !is_void {
        phi = create_inst(OP_PHI, vals[cb].ty, []);
        inst_insert_before(phi, cb);
        let dl = inst_get_md(cb, 0);
        if dl >= 0 { inst_set_md(phi, 0, dl); }
    }
    let prof = inst_get_md(cb, MDK_PROF);
    let had = prof >= 0 && mds[prof].nops > 0 && pd_md_string_is(md_op(prof, 0), "VP");
    var ws: u64[>..<] = [];
    var g_ids: u64[>..<] = [];
    var g_cnt: u64[>..<] = [];
    if had {
        ws.push(0);
        // getValueProfDataFromInst(IPVK_IndirectCallTarget): !{!"VP", i32 0, i64 total, (i64 value, i64 count)*}
        let n = mds[prof].nops as i64;
        if n >= 3 && pd_md_weight(prof, 1) == 0 {
            var k: i64 = 3;
            while k + 1 < n {
                let v = pd_md_weight(prof, k);
                let c = pd_md_weight(prof, k + 1);
                if c != 0xFFFFFFFFFFFFFFFF { g_ids.push(v); g_cnt.push(c); }
                k += 2;
            }
        }
    }
    let callee_slot = nops(cb) - 1;
    for fi, i in funcs {
        let b = create_block_before(fv, tail, str("call.", i));
        ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: b });
        ups.push(DTUpdate { kind: DT_INSERT, from: b, to: tail });
        let call = inst_clone(cb);
        inst_erase_md(call, MDK_PROF);
        set_op(call, callee_slot, fi);
        insts[inst_of(call)].ty2 = globs[glob_of(fi)].vty;
        inst_insert_at(call, b, -1, false);
        sw_add_case_raw(sw, c_int(vals[index].ty, i), b);
        let id = jt2_guid(fi);
        var w: u64 = 0;
        if id != 0 { for j in g_ids.len { if g_ids[j] == id { w = g_cnt[j]; } } }
        ws.push(w);
        block_append_inst(b, create_inst(OP_BR, T_VOID, [tail]));
        if phi >= 0 { phi_add_incoming(phi, call, b); }
    }
    dtu_apply_updates(ups);
    var any = false;
    for w in ws { if w != 0 { any = true; } }
    if had && any {
        // downscaleWeights
        var mx: u64 = 0;
        for w in ws { if w > mx { mx = w; } }
        let scale: u64 = if mx < 0xFFFFFFFF { 1 } else { mx / 0xFFFFFFFF + 1 };
        var ds: u64[>..<] = [];
        for w in ws { ds.push(w / scale); }
        pd_set(sw, ds, false, false);
    } else {
        inst_set_md(sw, MDK_PROF, md_get(MK_TUPLE, -1, [md_string("unknown"), md_string("jump-table-to-switch")], false));
    }
    if phi >= 0 { rauw(cb, phi); }
    inst_erase_from_parent(cb);
    return tail;
}

fn jump_table_to_switch_run(fv: i32) -> u32 {
    let has_dt = dt_valid(fv, DT_DOM);
    let has_pdt = dt_valid(fv, DT_POST);
    dtu_begin(fv, true, true, true);
    var changed = false;
    var funcs: i32[>..<] = [];
    var bb = func_first_block(fv);
    while bb >= 0 {
        let nbb = block_next(bb);
        var cur = bb;
        while cur >= 0 {
            var tail: i32 = -1;
            var i = block_first(cur);
            while i >= 0 {
                let call = i;
                i = inst_next(i);
                if iop(call) != OP_CALL || called_function(call) >= 0 || insts[inst_of(call)].pred == 2 { continue; }
                let l = cb_callee(call);
                if !is_inst(l) || iop(l) != OP_LOAD || !ld_is_simple(l) { continue; }
                let gep = op(l, 0);
                if !is_inst(gep) || iop(gep) != OP_GEP { continue; }
                if !jt2_parse(gep, vals[l].ty, insts[inst_of(call)].ty2, funcs) { continue; }
                tail = jt2_expand(call, gco_vals[0], funcs);
                changed = true;
                break;
            }
            cur = tail;
        }
        bb = nbb;
    }
    dtu_end();
    if !changed { return PA_ALL; }
    var pa: u32 = 0;
    if has_dt { pa |= (1 as u32) << A_DOMTREE; }
    if has_pdt { pa |= (1 as u32) << A_POSTDOMTREE; }
    return pa;
}
