// Interleave groups in VPlan: VPlanTransforms::createInterleaveGroups, the VPInterleaveRecipe constructor,
// VPInterleaveBase::computeCost and VPInterleaveRecipe::execute (with interleaveVectors, concatenateVectors,
// createBitOrPointerCast, InterleaveGroup::addMetadata / propagateMetadata).
// Ported from llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp, VPlanRecipes.cpp and
// llvm/lib/Analysis/VectorUtils.cpp (LLVM 23.1.5). Masked groups (block masks, gap masks) and reverse groups fail
// loudly.
import std;
import ir;
import irutil;
import instinfo;
import datalayout;
import autoupgrade;
import cfgutil;
import tbaa;
import laa;
import lv_interleave;
import lv_cost;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_execute;
import vplan_transforms;
import vplan_exec_transforms;
import tti_vec;
import lv_plan;

// a VPIRMetadata as a flat list of (kind, node) pairs
fn vig_md_of_recipe(r: i32, out: i32[>..<]&) {
    out.clear();
    let h = vpr[r].md;
    if h < 0 { return; }
    for k in xv_len(h) { out.push(xv_get(h, k)); }
}
fn vig_md_of_inst(i: i32, out: i32[>..<]&) {
    out.clear();
    let ii = inst_of(i);
    for k in insts[ii].nmd as i64 {
        let kind = md_att[(insts[ii].md as i64) + 2 * k];
        let node = md_att[(insts[ii].md as i64) + 2 * k + 1];
        if kind == 0 { continue; }
        if vp_md_is_propagated(kind) { out.push(kind); out.push(node); }
    }
}
// VPIRMetadata::intersect
fn vig_md_intersect(a: i32[>..<]&, b: const i32[:]) {
    var out: i32[>..<] = [];
    var k: i64 = 0;
    while k < a.len {
        var j: i64 = 0;
        while j < b.len {
            if a[k] == b[j] && a[k + 1] == b[j + 1] { out.push(a[k]); out.push(a[k + 1]); break; }
            j += 2;
        }
        k += 2;
    }
    a.clear();
    for x in out { a.push(x); }
}

// VPInterleaveRecipe(IG, Addr, StoredValues, Mask, NeedsMaskForGaps, MD, DL)
fn vp_new_interleave(g: i32, addr: i32, stored: const i32[:], mask: i32, gaps: bool, md: const i32[:], dl: i32) -> i32 {
    let r = vp_new_recipe(VPR_INTERLEAVE, [addr], dl);
    vpr[r].ig = g;
    vpr[r].ir_inst = ig_insert_pos(g);
    vpr[r].gaps = gaps;
    var k: i64 = 0;
    while k < md.len { vp_md_set(r, md[k], md[k + 1]); k += 2; }
    if stored.len == 0 {
        for x in ig_factor(g) {
            let m = ig_member(g, x);
            if m >= 0 { vp_add_multi_def_value(r, m, vals[m].ty as i32); }
        }
    } else {
        for v in stored { vp_add_operand(r, v); }
    }
    if mask >= 0 { vpr[r].masked = true; vp_add_operand(r, mask); }
    return r;
}
fn vp_interleave_mask(r: i32) -> i32 { if vpr[r].masked { vp_op(r, vp_nops(r) - 1) } else { -1 } }
fn vp_interleave_stored_values(r: i32, out: i32[>..<]&) {
    out.clear();
    let n = vp_interleave_num_store_operands(r);
    for k in n { out.push(vp_op(r, 1 + k)); }
}

// VPlanTransforms::createInterleaveGroups(Plan, InterleaveGroups, EpilogueAllowed)
fn vpt_create_interleave_groups(groups: const i32[:], epilogue_allowed: bool) {
    if groups.len == 0 { return; }
    var m2r = hm_new();       // IRMemberToRecipe
    var blocks: i32[>..<] = [];
    vp_depth_first(vpb[vp_vector_loop_region()].entry, false, blocks);
    vp_only_basic(blocks);
    for b in blocks {
        var r = vpb[b].first;
        while r >= 0 {
            if vp_is_widen_memory_kind(vpr[r].kind) { hm_put(m2r, vpr[r].ir_inst as u64, r as i64); }
            r = vpr[r].next;
        }
    }
    fn lookup(i: i32) -> i32 { hm_get(m2r, i as u64, -1) as i32 }
    vp_dt_build();
    for g in groups {
        var start: i32 = -1;
        var start_member: i32 = -1;
        for x in ig_factor(g) {
            let m = ig_member(g, x);
            if m < 0 { continue; }
            let r = lookup(m);
            if r >= 0 { start_member = m; start = r; break; }
        }
        if start_member < 0 { continue; }
        var md: i32[>..<] = [];
        vig_md_of_recipe(start, md);
        var stored: i32[>..<] = [];
        var tmp: i32[>..<] = [];
        for x in ig_factor(g) {
            let m = ig_member(g, x);
            if m < 0 { continue; }
            let mr = lookup(m);
            if mr >= 0 {
                if vpr[mr].kind == VPR_WIDEN_STORE { stored.push(vp_op(mr, 1)); }
                vig_md_of_recipe(mr, tmp);
            } else {
                vig_md_of_inst(m, tmp);
            }
            vig_md_intersect(md, tmp);
        }
        let gaps = (ig_requires_scalar_epilogue(g) && !epilogue_allowed) || (stored.len != 0 && !ig_is_full(g));
        var ir_ip = ig_insert_pos(g);
        var ip = lookup(ir_ip);
        if ip < 0 {
            if vpr[start].kind != VPR_WIDEN_LOAD { fatal("internal: Dead member in non-load group?"); }
            ip = start;
            for x in ig_factor(g) {
                let m = ig_member(g, x);
                if m < 0 { continue; }
                let mr = lookup(m);
                if mr >= 0 && vp_dt_properly_dominates(mr, ip) { ip = mr; }
            }
            ir_ip = vpr[ip].ir_inst;
        }
        var nw: u8 = 0;
        let gp = strip_pointer_casts(laa_ldst_ptr(ir_ip));
        if is_inst(gp) && iop(gp) == OP_GEP { nw = insts[inst_of(gp)].flags & ~GEP_NUW; }
        var addr = vp_op(start, 0);
        let ad = vp_def(addr);
        if ig_index_of(g, start_member) != 0 || (ad >= 0 && !vp_dt_properly_dominates(ad, ip)) {
            let idx = ig_index_of(g, ir_ip);
            if idx == 0 { fatal("internal: index of insert position shouldn't be zero"); }
            let off = dl_alloc_size(laa_ldst_type(ir_ip)) * idx;
            let offv = vp_const_int(T_I32, ((-off) as u64) & 0xFFFFFFFF);
            vpb_set_before(ip);
            addr = vp_val(vpb_nary(VPI_PTR_ADD, [vp_op(ip, 0), offv], vpf_gep(nw), -1, "", -1));
        }
        if ig_is_reverse(g) { vp_unported("reverse interleave groups"); }
        let mask = if vpr[ip].masked { vp_op(ip, vp_nops(ip) - 1) } else { -1 };
        if mask >= 0 || gaps { vp_unported("masked interleave groups"); }
        let vpig = vp_new_interleave(g, addr, stored, mask, gaps, md, vpr[ip].dl);
        vp_insert_before(vpig, ip);
        var j: i64 = 0;
        for x in ig_factor(g) {
            let m = ig_member(g, x);
            if m < 0 { continue; }
            let mr = lookup(m);
            if vals[m].ty as i32 != T_VOID {
                if mr >= 0 { vp_rauw(vpr[mr].def, vp_defined_value(vpig, j)); }
                j++;
            }
            if mr >= 0 { vp_erase_recipe(mr); }
        }
    }
}

// VPInterleaveBase::computeCost(VF, Ctx)
fn vpc_interleave_cost(r: i32, vf: i64) -> i64 {
    let g = vpr[r].ig;
    let ip = ig_insert_pos(g);
    var ip_idx: i64 = 0;
    for x in ig_factor(g) {
        let m = ig_member(g, x);
        if m < 0 { continue; }
        if m == ip { break; }
        ip_idx++;
    }
    var valv: i32 = -1;
    if vp_num_defined_values(r) > 0 { valv = vp_defined_value(r, ip_idx); }
    else { valv = vp_op(r, 1 + ip_idx); }
    let vt = vp_scalar_type(valv);
    let vty = lv_vec_ty(vt, vf);
    let as_ = lv_ptr_as(vp_scalar_type(vp_op(r, 0)));
    let f = ig_factor(g);
    let wide = ty_vector(vt, vf * f, false);
    var idx: i64[>..<] = [];
    for x in f { if ig_member(g, x) >= 0 { idx.push(x); } }
    let c = lt_interleaved(iop(ip), wide, f, idx, ig_align(g), as_, vpr[r].masked, vpr[r].gaps);
    if !ig_is_reverse(g) { return c; }
    return lc_add(c, lc_mul(lt_shuffle(SK_REVERSE, vty, 0), ig_num_members(g)));
}

// InterleaveGroup::addMetadata(NewInst): propagateMetadata over Members (DenseMap<int32_t, ...>) in bucket order
fn vig_add_metadata(g: i32, ni: i32) {
    var vl: i32[>..<] = [];
    var bk: i64[>..<] = [];
    let gr = iai_groups[g];
    let f = gr.factor as i64;
    var nb: i64 = 64;
    while (gr.n as i64) * 4 >= nb * 3 { nb *= 2; }
    for s in 2 * f - 1 {
        let m = iai_slots[gr.at as i64 + s];
        if m < 0 { continue; }
        let key = s - (f - 1);
        vl.push(m);
        bk.push(((key * 37) as u32 as i64) & (nb - 1));
    }
    // no collisions: 37 is odd, so key * 37 is a bijection modulo the bucket count on the small key range
    for a in vl.len {
        for b in a + 1..vl.len {
            if bk[b] < bk[a] { let t = bk[a]; bk[a] = bk[b]; bk[b] = t; let u = vl[a]; vl[a] = vl[b]; vl[b] = u; }
        }
    }
    vig_propagate_metadata(ni, vl);
}
// propagateMetadata(Inst, VL)
fn vig_propagate_metadata(inst: i32, vl: const i32[:]) {
    if vl.len == 0 { return; }
    var md: i32[>..<] = [];
    vig_md_of_inst(vl[0], md);
    let k_tbaa = md_kind_id("tbaa");
    let k_scope = md_kind_id("alias.scope");
    let k_fpmath = md_kind_id("fpmath");
    let k_noalias = md_kind_id("noalias");
    let k_nt = md_kind_id("nontemporal");
    let k_inv = md_kind_id("invariant.load");
    let k_ag = md_kind_id("llvm.access.group");
    let k_mmra = md_kind_id("mmra");
    var k: i64 = 0;
    while k < md.len {
        let kind = md[k];
        var n = md[k + 1];
        k += 2;
        if kind == k_mmra { vp_unported("MMRA metadata on interleave groups"); }
        var j: i64 = 1;
        while n >= 0 && j < vl.len {
            let imd = inst_get_md(vl[j], kind);
            if kind == k_tbaa { n = tb_most_generic_tbaa(n, imd); }
            else if kind == k_scope { n = cu_most_generic_alias_scope(n, imd); }
            else if kind == k_fpmath { n = cu_most_generic_fpmath(n, imd); }
            else if kind == k_noalias || kind == k_nt || kind == k_inv { n = cu_md_intersect(n, imd); }
            else if kind == k_ag { n = cu_intersect_access_groups(inst, vl[j]); }
            else { fatal("internal: unhandled metadata"); }
            j++;
        }
        inst_set_md(inst, kind, n);
    }
}

// CreateVectorReverse(V, Name) for a fixed vector
fn vxb_vector_reverse(v: i32, name: const u8[:]) -> i32 {
    let n = ty_count(vals[v].ty);
    var mask: i32[>..<] = [];
    for k in n { mask.push((n - 1 - k) as i32); }
    return vxb_shuffle(v, c_poison(vals[v].ty as i32), mask, name);
}
// CreateBitOrPointerCast(V, DestTy)
fn vxb_bit_or_pointer_cast(v: i32, dst: i32) -> i32 {
    let src = vals[v].ty as i32;
    if src == dst { return v; }
    let se = ty_scalar(src);
    let de = ty_scalar(dst);
    if ty_kind(se) == TK_PTR && ty_is_int(de) { return vxb_cast(OP_PTRTOINT, v, dst, ""); }
    if ty_is_int(se) && ty_kind(de) == TK_PTR { return vxb_cast(OP_INTTOPTR, v, dst, ""); }
    return vxb_cast(OP_BITCAST, v, dst, "");
}
// createBitOrPointerCast(Builder, V, DstVTy, DL)
fn vig_bit_or_pointer_cast(v: i32, dst: i32) -> i32 {
    let se = ty_scalar(vals[v].ty);
    let de = ty_scalar(dst);
    let sp = ty_kind(se) == TK_PTR;
    let dp = ty_kind(de) == TK_PTR;
    // CastInst::isBitOrNoopPointerCastable: a ptr <-> non-int (FP) pair is not
    if sp == dp || (sp && ty_is_int(de)) || (dp && ty_is_int(se)) {
        if (sp && ty_is_int(de) && dl_size_bits(de) != dl_size_bits(se)) || (dp && ty_is_int(se) && dl_size_bits(se) != dl_size_bits(de)) {
            vp_unported("interleave member casts between pointers and integers of another width");
        }
        return vxb_bit_or_pointer_cast(v, dst);
    }
    let it = ty_vector(ty_int(dl_size_bits(se)), ty_count(dst), false);
    return vxb_bit_or_pointer_cast(vxb_bit_or_pointer_cast(v, it), dst);
}
// concatenateVectors(Builder, Vecs)
fn vxb_concatenate_vectors(vecs: const i32[:]) -> i32 {
    var res: i32[>..<] = [];
    for v in vecs { res.push(v); }
    while res.len > 1 {
        var tmp: i32[>..<] = [];
        var i: i64 = 0;
        while i < res.len - 1 {
            let v0 = res[i];
            var v1 = res[i + 1];
            let n1 = ty_count(vals[v0].ty);
            let n2 = ty_count(vals[v1].ty);
            if n1 > n2 {
                var m: i32[>..<] = [];
                for k in n2 { m.push(k as i32); }
                for k in n1 - n2 { m.push(-1); }
                v1 = vxb_shuffle(v1, c_poison(vals[v1].ty as i32), m, "");
            }
            var cm: i32[>..<] = [];
            for k in n1 + n2 { cm.push(k as i32); }
            tmp.push(vxb_shuffle(v0, v1, cm, ""));
            i += 2;
        }
        if res.len % 2 != 0 { tmp.push(res[res.len - 1]); }
        res.clear();
        for x in tmp { res.push(x); }
    }
    return res[0];
}

// VPInterleaveRecipe::execute(State)
fn vp_interleave_execute(r: i32) {
    if vpr[r].masked || vpr[r].gaps { vp_unported("masked interleave groups"); }
    let g = vpr[r].ig;
    let ip = ig_insert_pos(g);
    let sty = laa_ldst_type(ip);
    let f = ig_factor(g);
    let vf = vts_vf;
    let vecty = ty_vector(sty, vf * f, false);
    let res_addr = vts_get_lane(vp_op(r, 0), 0);
    if iop(ip) == OP_LOAD {
        let ld = vxb_load(vecty, res_addr, ig_align(g), "wide.vec");
        vp_apply_metadata(r, ld);
        vig_add_metadata(g, ld);
        var j: i64 = 0;
        for x in f {
            let m = ig_member(g, x);
            if m < 0 { continue; }
            var mask: i32[>..<] = [];
            for e in vf { mask.push((x + e * f) as i32); }
            var sv = vxb_shuffle(ld, c_poison(vecty), mask, "strided.vec");
            if vals[m].ty as i32 != sty { sv = vig_bit_or_pointer_cast(sv, ty_vector(vals[m].ty as i32, vf, false)); }
            if ig_is_reverse(g) { sv = vxb_vector_reverse(sv, "reverse"); }
            vts_set(vp_defined_value(r, j), sv, false);
            j++;
        }
        return;
    }
    let subvt = ty_vector(sty, vf, false);
    var vecs: i32[>..<] = [];
    var si: i64 = 0;
    for x in f {
        let m = ig_member(g, x);
        if m < 0 { vecs.push(c_poison(subvt)); continue; }
        var sv = vts_get(vp_op(r, 1 + si), false);
        si++;
        if ig_is_reverse(g) { sv = vxb_vector_reverse(sv, "reverse"); }
        if vals[sv].ty as i32 != subvt { sv = vig_bit_or_pointer_cast(sv, subvt); }
        vecs.push(sv);
    }
    let wide = vxb_concatenate_vectors(vecs);
    var im: i32[>..<] = [];
    for e in vf { for x in f { im.push((x * vf + e) as i32); } }
    let iv = vxb_shuffle(wide, c_poison(vals[wide].ty as i32), im, "interleaved.vec");
    let st = vxb_store(iv, res_addr, ig_align(g));
    vp_apply_metadata(r, st);
    vig_add_metadata(g, st);
}

// ---------------------------------------------------------------------------------------------
// VPlanTransforms::narrowInterleaveGroups

// canNarrowLoad(WideMember0, OpIdx, OpV, Idx)
fn vig_can_narrow_load(m0: i32, op_idx: i64, opv: i32, idx: i64) -> bool {
    let m0op = vp_op(m0, op_idx);
    if vp_is_defined_outside_loop_regions(m0op) {
        if m0op == opv { return true; }
        return vp_is_defined_outside_loop_regions(opv) && vp_scalar_type(opv) == vp_scalar_type(m0op);
    }
    let r = vp_def(m0op);
    if vpr[r].kind == VPR_WIDEN_LOAD { return !vpr[r].masked && vpr[r].consecutive && m0op == opv; }
    if vpr[r].kind == VPR_INTERLEAVE { return ig_is_full(vpr[r].ig) && vp_defined_value(r, idx) == opv; }
    return false;
}
fn vig_has_predicate(r: i32) -> bool { vpr[r].f.ot == VOT_CMP || vpr[r].f.ot == VOT_FCMP }
// canNarrowOps(Ops): the ops are vig_stk[at .. at + n] (a scratch stack: recursion only pushes beyond)
var vig_stk: i32[>..<];
recursive fn vig_can_narrow_ops(at: i64, n: i64) -> bool {
    let m0 = vp_def(vig_stk[at]);
    if m0 < 0 || !vp_is_recipe_with_ir_flags(vpr[m0].kind) { return false; }
    for j in n {
        let v = vig_stk[at + j];
        let r = vp_def(v);
        if r < 0 || (vpr[r].kind != VPR_WIDEN && vpr[r].kind != VPR_WIDEN_CAST) { return false; }
        if vpr[r].opcode != vpr[m0].opcode || (vpr[m0].kind != VPR_WIDEN && vpr[m0].kind != VPR_WIDEN_CAST) { return false; }
        if vp_scalar_type(v) != vp_scalar_type(vig_stk[at]) { return false; }
        if vig_has_predicate(r) && (!vig_has_predicate(m0) || vpr[r].f.pred != vpr[m0].f.pred) { return false; }
    }
    for idx in vp_nops(m0) {
        let b = vig_stk.len;
        for j in n { let o = vp_op(vp_def(vig_stk[at + j]), idx); vig_stk.push(o); }
        if vig_can_narrow_ops(b, n) { vig_stk.resize(b); continue; }
        for k in n { if !vig_can_narrow_load(m0, idx, vig_stk[b + k], k) { vig_stk.resize(b); return false; } }
        vig_stk.resize(b);
    }
    return true;
}
fn vig_can_narrow_ops_of(ops: const i32[:]) -> bool {
    let b = vig_stk.len;
    for v in ops { vig_stk.push(v); }
    let r = vig_can_narrow_ops(b, ops.len);
    vig_stk.resize(b);
    return r;
}
// isConsecutiveInterleaveGroup(InterleaveR, VFs, TTI): the VF or 0
fn vig_consecutive_group_vf(r: i32, vfs: const i64[:]) -> i64 {
    if vpr[r].masked { return 0; }
    var et: i32 = -1;
    var stored: i32[>..<] = [];
    vp_interleave_stored_values(r, stored);
    if stored.len == 0 {
        et = vp_scalar_type(vp_defined_value(r, 0));
        for k in vp_num_defined_values(r) { if vp_scalar_type(vp_defined_value(r, k)) != et { return 0; } }
    } else {
        et = vp_scalar_type(stored[0]);
        for v in stored { if vp_scalar_type(v) != et { return 0; } }
    }
    let g = vpr[r].ig;
    if ig_factor(g) != ig_num_members(g) { return 0; }
    let width = tv_register_bit_width(1);
    for vf in vfs {
        // getScalarSizeInBits: the primitive size (0 for pointers)
        let st = ty_scalar(et);
        let gs = (if ty_kind(st) == TK_PTR { 0 } else { dl_size_bits(st) }) * vf;
        if ig_factor(g) == vf && gs == width { return vf; }
    }
    return 0;
}
// isAlreadyNarrow
fn vig_is_already_narrow(v: i32) -> bool {
    if vpv[v].kind == VVK_IR { return true; }
    let r = vp_def(v);
    return r >= 0 && vpr[r].kind == VPR_REPLICATE && vpr[r].single_scalar;
}
// narrowInterleaveGroupOp(Members, NarrowedOps, Preheader): the members are vig_stk[at .. at + n]
var vig_narrowed: i32[>..<];
recursive fn vig_narrow_op(at: i64, n: i64, preheader: i32) -> i32 {
    let v = vig_stk[at];
    for x in vig_narrowed { if x == v { return v; } }
    if vp_is_defined_outside_loop_regions(v) {
        var ms: i32[>..<] = [];
        for j in n { ms.push(vig_stk[at + j]); }
        let bv = vp_new_instruction(VPI_BUILD_VECTOR, ms, vpf_none(), -1, "", -1);
        vp_append_recipe(preheader, bv);
        vig_narrowed.push(vpr[bv].def);
        return vpr[bv].def;
    }
    if vig_is_already_narrow(v) { return v; }
    let r = vp_def(v);
    let k = vpr[r].kind;
    if k == VPR_WIDEN || k == VPR_WIDEN_CAST {
        for j in 1..n { vpx_intersect_flags(r, vpr[vp_def(vig_stk[at + j])].f); }
        for idx in vp_nops(r) {
            let b = vig_stk.len;
            for j in n { let o = vp_op(vp_def(vig_stk[at + j]), idx); vig_stk.push(o); }
            let nv = vig_narrow_op(b, n, preheader);
            vig_stk.resize(b);
            vp_set_operand(r, idx, nv);
        }
        return v;
    }
    if k == VPR_INTERLEAVE {
        let li = ig_insert_pos(vpr[r].ig);
        let l = vp_new_widen_load(li, vp_op(r, 0), vp_interleave_mask(r), true, r, vpr[r].dl);
        vp_insert_before(l, r);
        vig_narrowed.push(vpr[l].def);
        return vpr[l].def;
    }
    if k == VPR_REPLICATE {
        vig_narrowed.push(v);
        return v;
    }
    if k != VPR_WIDEN_LOAD { fatal("internal: narrowInterleaveGroupOp: expected a wide load"); }
    var ptr = vp_op(r, 0);
    let pr = vp_def(ptr);
    if pr >= 0 && vpr[pr].kind == VPR_VECTOR_POINTER { ptr = vp_op(pr, 0); }
    let nr = vp_new_replicate(vpr[r].ir_inst, [ptr], true, -1, vpf_none(), r, -1);
    vp_insert_before(nr, r);
    vig_narrowed.push(vpr[nr].def);
    return vpr[nr].def;
}

// narrowInterleaveGroups(Plan, TTI): the loaded plan is narrowed in place; returns the archive slot of the
// un-narrowed copy with the other VFs (-1 = none)
fn vpt_narrow_interleave_groups() -> i32 {
    let region = vp_vector_loop_region();
    if region < 0 { return -1; }
    let e = vpb[region].entry;
    if e != vpb[region].exiting { return -1; }
    if !vpm_vpi_r(vpb[e].last, VPI_BRANCH_ON_COUNT, 2) { return -1; }
    var store_groups: i32[>..<] = [];
    var vf_opt: i64 = 0;
    var r = vpb[e].first;
    while r >= 0 {
        let cur = r;
        r = vpr[r].next;
        let k = vpr[cur].kind;
        if (k == VPR_DERIVED_IV || k == VPR_SCALAR_IV_STEPS) && vp_only_first_lane_used(vpr[cur].def) { continue; }
        if vp_is_phi_recipe(cur) { return -1; }
        let is_ig = k == VPR_INTERLEAVE;
        if vp_may_write_to_memory(cur) && !is_ig { return -1; }
        for d in vp_num_defined_values(cur) {
            let v = vp_defined_value(cur, d);
            for j in vp_num_users(v) { if vpb[vpr[vp_user(v, j)].parent].parent != region { return -1; } }
        }
        if !is_ig { continue; }
        var vfs: i64[>..<] = [];
        if vf_opt != 0 { vfs.push(vf_opt); } else { for j in xv_len(vph.vfs) { vfs.push(xv_get(vph.vfs, j) as i64); } }
        let nvf = vig_consecutive_group_vf(cur, vfs);
        if nvf == 0 || (vf_opt != 0 && nvf != vf_opt) { return -1; }
        vf_opt = nvf;
        var stored: i32[>..<] = [];
        vp_interleave_stored_values(cur, stored);
        if stored.len == 0 { continue; }
        let m0 = stored[0];
        var all_eq = true;
        for v in stored { if v != m0 { all_eq = false; } }
        if vig_is_already_narrow(m0) && all_eq { store_groups.push(cur); continue; }
        var all_loads = true;
        for si in stored.len {
            let dr = vp_def(stored[si]);
            if dr < 0 || vpr[dr].kind != VPR_INTERLEAVE || !ig_is_full(vpr[dr].ig) || vp_defined_value(dr, si) != stored[si] { all_loads = false; break; }
        }
        if all_loads { store_groups.push(cur); continue; }
        if !vig_can_narrow_ops_of(stored) { return -1; }
        store_groups.push(cur);
    }
    if store_groups.len == 0 { return -1; }
    let middle = vp_middle_block();
    let rse = vp_nsuccs(middle) == 1 && vp_single_succ(middle) == vp_scalar_preheader();
    if vp_nsuccs(middle) != 2 && !rse { return -1; }
    var new_plan: i32 = -1;
    if xv_len(vph.vfs) != 1 {
        let orig = vp_save();
        vp_duplicate_load(orig);
        // NewPlan->removeVF(VFToOptimize)
        let fi = xv_find(vph.vfs, vf_opt as i32);
        if fi >= 0 { xv_erase(vph.vfs, fi); }
        new_plan = vp_save();
        vp_load(orig);
        vp_set_vf(vf_opt);
    }
    vig_narrowed.clear();
    let preheader = vp_vector_preheader();
    for sg in store_groups {
        var stored: i32[>..<] = [];
        vp_interleave_stored_values(sg, stored);
        let b = vig_stk.len;
        for x in stored { vig_stk.push(x); }
        let res = vig_narrow_op(b, stored.len, preheader);
        vig_stk.resize(b);
        let si = ig_insert_pos(vpr[sg].ig);
        let s = vp_new_widen_store(si, vp_op(sg, 0), res, -1, true, sg, vpr[sg].dl);
        vp_insert_before(s, sg);
        vp_erase_recipe(sg);
    }
    let inc = vpx_find_canonical_iv_increment(region);
    let can_ty = vpv[vpb[region].can_iv].ty;
    let vector_ph = vp_vector_preheader();
    let step = vph.uf;
    vp_rauw(vph.vf, vp_const_int(can_ty, 1));
    vpx_materialize_vector_trip_count(vector_ph, false, rse, step);
    vp_set_operand(inc, 1, step);
    vp_rauw(vph.vfxuf, step);
    vpt_remove_dead_recipes();
    return new_plan;
}
