// The inliner passes: port of llvm/lib/Transforms/IPO/Inliner.cpp (InlinerPass::run, makeFunctionBodyUnreachable;
// ModuleInlinerWrapperPass is expanded by the pipeline parser into cgscc(inline<only-mandatory>,inline)),
// llvm/lib/Transforms/IPO/AlwaysInliner.cpp (AlwaysInlineImpl with flattening),
// llvm/lib/Transforms/IPO/ModuleInliner.cpp (ModuleInlinerPass::run), llvm/lib/Analysis/InlineOrder.cpp (PriorityInlineOrder with the
// size / cost / cost-benefit / ml priorities on libstdc++'s heap algorithms), llvm/lib/Analysis/InlineAdvisor.cpp
// (DefaultInlineAdvisor, the mandatory advice, getDefaultInlineAdvice, shouldInline / shouldBeDeferred,
// setInlineRemark / inlineCostStr), FindAvailableLoadedValue without AA (llvm/lib/Analysis/Loads.cpp:
// findAvailablePtrLoadStore with areNonOverlapSameBaseLoadAndStore), filterDeadComdatFunctions
// (llvm/lib/Transforms/Utils/ModuleUtils.cpp), tryPromoteCall / isLegalToPromote / promoteCall
// (llvm/lib/Transforms/Utils/CallPromotionUtils.cpp) and getFunctionAtVTableOffset / getPointerAtOffset
// (llvm/lib/Analysis/TypeMetadataUtils.cpp).
// Not ported (fail loudly): replay / ML advisors (the ML *priority* is ported), promoting a call whose types
// differ from the callee's, contextual profiles, remarks.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import analyses;
import flags;
import apint;
import pm;
import vt;
import memloc;
import loads;
import tli;
import scev;
import ivec;
import lcg;
import cgscc;
import psi;
import bfi;
import ipoutil;
import inline_cost;
import inline_function;
import passmgr;

fn inl_not_ported(what: const u8[:]) { fatal(str("Inliner: ", what, " is not ported yet")); }

fn inl_check_flags() {
    if flag_str("cgscc-inline-replay").len > 0 { inl_not_ported("-cgscc-inline-replay"); }
    if flag_bool("enable-scc-inline-advisor-printing", false) { inl_not_ported("-enable-scc-inline-advisor-printing"); }
}

// ---------------------------------------------------------------------------------------------
// Inline remarks (setInlineRemark: the "inline-remark" call-site attribute with -inline-remark-attribute)

// AttributeSet::addAttribute for a string attribute (replaces the same key)
fn aset_with_str(s: i32, a: i32) -> i32 {
    var xs: i32[>..<] = [];
    let key = attrs[a].skey;
    for k in aset_n(s) {
        let x = aset_attr(s, k);
        if attrs[x].kind == 0 && attrs[x].skey == key { continue; }
        xs.push(x);
    }
    xs.push(a);
    return aset_get(xs);
}
// CallBase::addFnAttr(Attribute)
fn cb_add_fn_attr(cb: i32, a: i32) {
    let ii = inst_of(cb);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 1) {
        var s: i32 = 0;
        if j < n { s = alist_runs[alists[l].at + j]; }
        if j == 0 {
            if attrs[a].kind == 0 { s = aset_with_str(s, a); }
            else {
                var xs: i32[>..<] = [];
                for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind != attrs[a].kind { xs.push(x); } }
                xs.push(a);
                s = aset_get(xs);
            }
        }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}
fn set_inline_remark(cb: i32, msg: const u8[:]) {
    if !flag_bool("inline-remark-attribute", false) { return; }
    var m: u8[>..] = [];
    m.append(msg);
    cb_add_fn_attr(cb, attr_str("inline-remark", m, true));
}
// inlineCostStr(IC)
fn inline_cost_str(out: u8[>..]&, c: ICost) {
    if icost_is_always(c) { out.append("(cost=always)"); }
    else if icost_is_never(c) { out.append("(cost=never)"); }
    else { format(out, "(cost=", c.cost, ", threshold=", c.threshold, ")"); }
    if c.reason >= 0 { out.append(": "); out.append(sbytes(c.reason)); }
}

// ---------------------------------------------------------------------------------------------
// The default inline advisor

// shouldBeDeferred
fn should_be_deferred(caller: i32, c: ICost, p: IParams, with_psi: bool) -> bool {
    if !gv_has_local_linkage(caller) && gv_linkage(caller) != LK_LINKONCE_ODR { return false; }
    if c.cost <= 0 { return false; }
    var total: i64 = 0;
    let cand = c.cost - 1;
    var apply_last = gv_has_local_linkage(caller) && !inl_has_one_use(caller);
    var prevents = false;
    var ncallers: i64 = 0;
    var u = first_use(caller);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if vals[us].kind == VK_BLOCKADDR { continue; }
        if !(is_inst(us) && is_callbase(us)) || called_function(us) != caller { apply_last = false; continue; }
        let c2 = get_inline_cost(us, called_function(us), p, true, with_psi);
        if !icost_bool(c2) { apply_last = false; continue; }
        if icost_is_always(c2) { continue; }
        if icost_delta(c2) <= cand {
            prevents = true;
            total = w32(total + c2.cost);
            ncallers++;
        }
    }
    if !prevents { return false; }
    if apply_last { total -= tti_inlining_last_call_to_static_bonus(); }
    let scale = flag_int("inline-deferral-scale", 2);
    if scale < 0 { return total < c.cost; }
    let total_cost = w32(total + c.cost * ncallers);
    let allowance = w32(c.cost * scale);
    return total_cost < allowance;
}
fn inl_has_one_use(f: i32) -> bool {
    var n: i64 = 0;
    var u = first_use(f);
    while u >= 0 { if vals[uses[u].user].kind != VK_BLOCKADDR { n++; } u = use_next(u); }
    return n == 1;
}

// getDefaultInlineAdvice + shouldInline -> (inline?, the cost)
fn get_default_inline_advice(cb: i32, p: IParams, with_psi: bool) -> bool, ICost {
    let callee = called_function(cb);
    let c = get_inline_cost(cb, callee, p, true, with_psi);
    if icost_is_always(c) { return true, c; }
    if !icost_bool(c) {
        if flag_bool("inline-remark-attribute", false) {
            var m: u8[>..] = [];
            inline_cost_str(m, c);
            set_inline_remark(cb, m);
        }
        return false, c;
    }
    let deferral = if p.has_enable_deferral { p.enable_deferral } else { flag_bool("inline-deferral", false) };
    if deferral && should_be_deferred(inst_func(cb), c, p, with_psi) {
        set_inline_remark(cb, "deferred");
        return false, c;
    }
    return true, c;
}

// InlineAdvisor::getAdvice(CB, MandatoryOnly) -> (has advice, recommended, mandatory, cost)
fn get_advice(cb: i32, mandatory_only: bool, p: IParams, with_psi: bool) -> bool, ICost {
    if !mandatory_only { let r, c = get_default_inline_advice(cb, p, with_psi); return r, c; }
    let callee = called_function(cb);
    var rec = false;
    if inst_func(cb) != callee {
        let d, why = get_attribute_based_inlining_decision(cb, callee);
        rec = d == 1;
    }
    return rec, icost_always("");
}

// FindAvailableLoadedValue(LI, BB, BBI, MaxInstsToScan) without AA
fn inl_find_available_loaded_value(li: i32, max_scan0: i64) -> i32 {
    if !ld_is_unordered(li) { return -1; }
    var max_scan = if max_scan0 == 0 { 0xFFFFFFFF } else { max_scan0 };
    let ptr = op(li, 0);
    let sp = strip_ptr_casts(ptr);
    let access_ty = vals[li].ty;
    let at_least_atomic = ld_is_atomic(li);
    var x = inst_prev(li);
    while x >= 0 {
        let cur = x;
        x = inst_prev(x);
        if ld_is_debug_or_pseudo(cur) { continue; }
        if max_scan == 0 { return -1; }
        max_scan--;
        let av = ld_get_available_load_store(cur, sp, access_ty, at_least_atomic);
        if av >= 0 { return av; }
        if iop(cur) == OP_STORE {
            let stp = strip_ptr_casts(op(cur, 1));
            let a1 = is_inst_op(sp, OP_ALLOCA) || vals[sp].kind == VK_GVAR;
            let a2 = is_inst_op(stp, OP_ALLOCA) || vals[stp].kind == VK_GVAR;
            if a1 && a2 && sp != stp { continue; }
            if inl_non_overlap_same_base(ptr, access_ty, op(cur, 1), vals[op(cur, 0)].ty) { continue; }
            return -1;
        }
        if inst_may_write_memory(cur) { return -1; }
    }
    return -1;
}
// areNonOverlapSameBaseLoadAndStore
fn inl_non_overlap_same_base(lp: i32, lt: i32, stp: i32, st: i32) -> bool {
    let lw = dl_ptr(ptr_as(vals[lp].ty)).idx;
    let sw = dl_ptr(ptr_as(vals[stp].ty)).idx;
    if lw != sw { return false; }
    let lb = strip_and_accumulate_offsets(lp, false, false, false);
    let lo = vt_off;
    let sb = strip_and_accumulate_offsets(stp, false, false, false);
    let so = vt_off;
    if lb != sb { return false; }
    if ty_size_scalable(lt) || ty_size_scalable(st) { inl_not_ported("scalable access sizes in areNonOverlapSameBaseLoadAndStore"); }
    let lsz = dl_store_size(lt) as i64;
    let ssz = dl_store_size(st) as i64;
    // ConstantRange(LoadOffset, LoadOffset + size) ∩ ConstantRange(StoreOffset, ...) is empty (index-width wrap)
    let w = lw;
    let lr = rg_new(ap_i64(lo, w), ap_add(ap_i64(lo, w), ap_i64(lsz, w)));
    let sr = rg_new(ap_i64(so, w), ap_add(ap_i64(so, w), ap_i64(ssz, w)));
    return rg_is_empty(rg_intersect(lr, sr));
}

// tryPromoteCall(CB) (llvm/lib/Transforms/Utils/CallPromotionUtils.cpp): a virtual call through a vtable
// pointer the constructor stored into an alloca becomes a direct call
fn try_promote_call(cb: i32) -> bool {
    let callee = cb_callee(cb);
    if !is_inst_op(callee, OP_LOAD) { return false; }
    let vbase = strip_and_accumulate_offsets(op(callee, 0), true, false, false);
    let vtable_off = vt_off;
    if !is_inst_op(vbase, OP_LOAD) { return false; }
    let obase = strip_and_accumulate_offsets(op(vbase, 0), true, false, false);
    if !(is_inst_op(obase, OP_ALLOCA) && vt_off == 0) { return false; }
    let vp = inl_find_available_loaded_value(vbase, 0);
    if vp < 0 || ty_kind(vals[vp].ty) != TK_PTR { return false; }
    let gvb = strip_and_accumulate_offsets(vp, true, false, false);
    let gv_off = vt_off;
    if vals[gvb].kind != VK_GVAR || globs[glob_of(gvb)].is_const == 0 || !gv_has_definitive_initializer(gvb) { return false; }
    let off = (gv_off + vtable_off) as! u64;
    // getFunctionAtVTableOffset
    let p = get_pointer_at_offset(op(gvb, 0), off, gvb);
    if p < 0 { return false; }
    let c = fa_strip_pointer_casts(p);
    var f: i32 = -1;
    if is_func(c) { f = c; }
    else if vals[c].kind == VK_ALIAS { let a = op(c, 0); if is_func(a) { f = a; } }
    if f < 0 { return false; }
    if !is_legal_to_promote(cb, f) { return false; }
    promote_call(cb, f);
    return true;
}
// getPointerAtOffset (llvm/lib/Analysis/TypeMetadataUtils.cpp); -1 = nullptr
recursive fn get_pointer_at_offset(i0: i32, off: u64, top: i32) -> i32 {
    var i = i0;
    if vals[i].kind == VK_DSOLOCAL { i = op(i, 0); }
    let t = vals[i].ty;
    if ty_kind(t) == TK_PTR { if off == 0 { return i; } return -1; }
    if vals[i].kind == VK_CSTRUCT {
        if off >= dl_struct_size(t) as u64 { return -1; }
        // StructLayout::getElementContainingOffset
        var k: i64 = 0;
        while k + 1 < ty_count(t) && dl_struct_offset(t, k + 1) as u64 <= off { k++; }
        return get_pointer_at_offset(op(i, k), off - dl_struct_offset(t, k) as u64, top);
    }
    if vals[i].kind == VK_CARRAY {
        let es = dl_alloc_size(ty_elem(t)) as u64;
        let k = off / es;
        if k >= nops(i) as u64 { return -1; }
        return get_pointer_at_offset(op(i, k as i64), off % es, top);
    }
    if vals[i].kind == VK_CINT { if off == 0 && cint_lo(i) == 0 && ty_bits(t) <= 64 { return i; } return -1; }
    if vals[i].kind == VK_CEXPR {
        let o = opcode_of(i);
        if o == OP_TRUNC || o == OP_PTRTOINT { return get_pointer_at_offset(op(i, 0), off, top); }
        if o == OP_SUB {
            var t1 = get_pointer_at_offset(op(i, 1), 0, -1);
            if t1 >= 0 && opcode_of(t1) == OP_GEP && vals[t1].kind == VK_CEXPR { t1 = op(t1, 0); }
            if t1 != top { return -1; }
            return get_pointer_at_offset(op(i, 0), off, top);
        }
        return -1;
    }
    return -1;
}
// isLegalToPromote
fn is_legal_to_promote(cb: i32, f: i32) -> bool {
    let fty = globs[glob_of(f)].vty;
    if vals[cb].ty != ty_fn_ret(fty) { inl_not_ported("isLegalToPromote with a different return type"); }
    let np = ty_fn_nparams(fty);
    let na = cb_nargs(cb);
    if na != np && !ty_fn_vararg(fty) { return false; }
    for k in np {
        if fn_has(f, k + 2, AK_ByVal) != aset_has(alist_param(insts[inst_of(cb)].attrs, k), AK_ByVal) { return false; }
        if fn_has(f, k + 2, AK_InAlloca) != aset_has(alist_param(insts[inst_of(cb)].attrs, k), AK_InAlloca) { return false; }
        if ty_fn_param(fty, k) != vals[cb_arg(cb, k)].ty { inl_not_ported("isLegalToPromote with different argument types"); }
    }
    for k in np..na { if call_param_has_attr(cb, k, AK_StructRet) { return false; } }
    // target feature compatibility: every "+feature" of the callee is in the caller's string
    let x = aset_find_str(alist_fn(func_attrs(f)), "target-features");
    if x >= 0 && attrs[x].sval >= 0 {
        let y = aset_find_str(alist_fn(func_attrs(inst_func(cb))), "target-features");
        let cf = if y >= 0 && attrs[y].sval >= 0 { sbytes(attrs[y].sval) } else { "" };
        let fs = sbytes(attrs[x].sval);
        var st: i64 = 0;
        for j in 0..fs.len + 1 {
            if j == fs.len || fs[j] == ',' {
                let feat = fs[st..j];
                if feat.len > 0 && feat[0] == '+' && !str_contains(cf, feat) { return false; }
                st = j + 1;
            }
        }
    }
    return true;
}
fn str_contains(h: const u8[:], n: const u8[:]) -> bool {
    if n.len == 0 { return true; }
    if n.len > h.len { return false; }
    for i in 0..h.len - n.len + 1 { if h[i..i + n.len] == n { return true; } }
    return false;
}
// promoteCall: the call's function type equals the callee's here (isLegalToPromote fails loudly otherwise)
fn promote_call(cb: i32, f: i32) {
    set_op(cb, nops(cb) - 1, f);
    inst_erase_md(cb, md_kind_id("prof"));
    inst_erase_md(cb, md_kind_id("callees"));
    if insts[inst_of(cb)].ty2 != globs[glob_of(f)].vty { inl_not_ported("promoteCall with a different function type"); }
}

// Function::isDefTriviallyDead
fn fn_is_def_trivially_dead(f: i32) -> bool {
    if !gv_has_linkonce_linkage(f) && !gv_has_local_linkage(f) && !gv_has_available_externally_linkage(f) { return false; }
    return fn_use_empty(f);
}
// Value::use_empty (a blockaddress is not a user of its function in LLVM 23)
fn fn_use_empty(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 { if vals[uses[u].user].kind != VK_BLOCKADDR { return false; } u = use_next(u); }
    return true;
}

// filterDeadComdatFunctions
fn filter_dead_comdat_functions(fs: i32[>..<]&) {
    var dead_comdats: i32[>..<] = [];
    var maybe: i32[>..<] = [];
    for f in fs { let c = globs[glob_of(f)].comdat; if c >= 0 { var seen = false; for x in maybe { if x == c { seen = true; } } if !seen { maybe.push(c); } } }
    let m = globs[glob_of(fs[0])].module;
    for c in maybe {
        var all = true;
        // every global object with this comdat must be one of the dead functions
        var g = modules[m].first_func;
        while g >= 0 {
            if globs[glob_of(g)].comdat == c {
                var dead = false;
                for f in fs { if f == g { dead = true; } }
                if !dead { all = false; }
            }
            g = globs[glob_of(g)].next;
        }
        g = modules[m].first_gvar;
        while g >= 0 { if globs[glob_of(g)].comdat == c { all = false; } g = globs[glob_of(g)].next; }
        if all { dead_comdats.push(c); }
    }
    var keep: i32[>..<] = [];
    for f in fs {
        let c = globs[glob_of(f)].comdat;
        var ok = c < 0;
        if !ok { for x in dead_comdats { if x == c { ok = true; } } }
        if ok { keep.push(f); }
    }
    fs.resize(0);
    for f in keep { fs.push(f); }
}

// ---------------------------------------------------------------------------------------------
// InlinerPass::run

fn inl_run_cgscc(c: i32, only_mandatory: bool) -> u32 {
    inl_check_flags();
    let p = get_inline_params();
    let m = globs[glob_of(lcg_fn(lcg_scc_node(c, 0)))].module;
    let with_psi = psi_cached();
    var calls: i32[>..<] = [];
    let n = lcg_scc_size(c);
    for k in n {
        let f = lcg_fn(lcg_scc_node(c, k));
        each_inst(f) { i =>
            if is_callbase(i) {
                let callee = called_function(i);
                if callee >= 0 {
                    if !func_is_decl(callee) { calls.push(i); }
                    else if inst_iid(i) == 0 { set_inline_remark(i, "unavailable definition"); }
                }
            }
        };
    }
    var cur_c = c;
    if calls.len == 0 { return PA_ALL; }
    var changed = false;
    var inlined_callees: i32[>..<] = [];
    var dead_fns: i32[>..<] = [];
    var dead_comdat_fns: i32[>..<] = [];
    var i: i64 = 0;
    while i < calls.len {
        let f = inst_func(calls[i]);
        let nd = lcg_lookup(f);
        if lcg_lookup_scc(nd) != cur_c { i++; continue; }
        var did_inline = false;
        while i < calls.len && inst_func(calls[i]) == f {
            let cb = calls[i];
            i++;
            let callee = called_function(cb);
            let callee_n = lcg_lookup(callee);
            let callee_scc = lcg_lookup_scc(callee_n);
            if callee_scc == cur_c && hm_has(ur_inlined_internal, hk2(nd, cur_c)) {
                set_inline_remark(cb, "recursive SCC split");
                continue;
            }
            if did_inline {
                let na = cb_nargs(cb);
                for k in na {
                    let li = cb_arg(cb, k);
                    if !is_inst_op(li, OP_LOAD) || !ld_is_simple(li) { continue; }
                    let av = inl_find_available_loaded_value(li, flag_int("inliner-forwarding-scan-limit", 16));
                    if av < 0 || !is_constant(av) { continue; }
                    var cv = av;
                    if vals[cv].ty != vals[li].ty {
                        if is_null_value(cv) { cv = c_null(vals[li].ty); } else { continue; }
                    }
                    rauw(li, cv);
                    inst_erase_from_parent(li);
                }
            }
            let rec, oic = get_advice(cb, only_mandatory, p, with_psi);
            if !rec { continue; }
            let mok, mult0 = ic_call_str_int(cb, "function-inline-cost-multiplier");
            let mult = if mok { mult0 } else { 1 };
            let track = lcg_scc_size(callee_scc) != 1 || lcg_rc_size(lcg_sccs[callee_scc].rc) != 1 || lcg_has_edge(callee_n, callee_n);
            if !inline_function(cb, true, true, track, with_psi, true, inst_func(cb)) {
                // recordUnsuccessfulInlining
                if !only_mandatory && flag_bool("inline-remark-attribute", false) {
                    var msg: u8[>..] = [];
                    msg.append(sbytes(if_fail_reason));
                    msg.append("; ");
                    inline_cost_str(msg, oic);
                    set_inline_remark(cb, msg);
                }
                continue;
            }
            did_inline = true;
            var seen = false;
            for x in inlined_callees { if x == callee { seen = true; } }
            if !seen { inlined_callees.push(callee); }
            if ifi_inlined_call_sites.len > 0 {
                var k = ifi_inlined_call_sites.len - 1;
                while k >= 0 {
                    let icb = ifi_inlined_call_sites[k];
                    k--;
                    var nc = called_function(icb);
                    if nc < 0 { if try_promote_call(icb) { nc = called_function(icb); } }
                    if nc >= 0 && !func_is_decl(nc) {
                        calls.push(icb);
                        if callee_scc != cur_c && callee_scc == lcg_lookup_scc(lcg_get_node(nc)) {
                            var v: u8[>..] = [];
                            format(v, w32(mult * flag_int("intra-scc-cost-multiplier", 2)));
                            cb_add_fn_attr(icb, attr_str("function-inline-cost-multiplier", v, true));
                        }
                    }
                }
            }
            if gv_is_discardable_if_unused(callee) && ipo_has_zero_live_uses(callee) && !lcg_is_lib_function(callee) {
                if gv_has_local_linkage(callee) || globs[glob_of(callee)].comdat < 0 {
                    var rest: i32[>..<] = [];
                    for x in i..calls.len { if inst_func(calls[x]) != callee { rest.push(calls[x]); } }
                    calls.resize(i);
                    for x in rest { calls.push(x); }
                    func_make_body_unreachable(callee);
                    dead_fns.push(callee);
                } else {
                    dead_comdat_fns.push(callee);
                }
            }
        }
        i--;
        i++;
        if !did_inline { continue; }
        changed = true;
        let old_c = cur_c;
        cur_c = cg_update_for_pass(cur_c, nd, false);
        if cur_c != old_c || hm_has(ur_cwl_idx, (old_c as i64) as u64) {
            var any = false;
            for x in inlined_callees { if lcg_lookup_scc(lcg_lookup(x)) == old_c { any = true; } }
            if any { hm_put(ur_inlined_internal, hk2(nd, old_c), 1); }
        }
        inlined_callees.resize(0);
        invalidate_function(f, PA_NONE);
    }
    if dead_comdat_fns.len > 0 {
        filter_dead_comdat_functions(dead_comdat_fns);
        for f in dead_comdat_fns { func_make_body_unreachable(f); dead_fns.push(f); }
    }
    for f in dead_fns {
        lcg_mark_dead_function(f);
        let dc = lcg_lookup_scc(lcg_lookup(f));
        invalidate_function(f, PA_NONE);
        ur_mark_invalid(dc);
        ur_dead_fns.push(f);
    }
    if !changed { return PA_ALL; }
    gm_invalidate_if_valid();
    return PA_FN | ((1 as u32) << A_FAMPROXY);
}
fn gm_invalidate_if_valid() { }

// ---------------------------------------------------------------------------------------------
// AlwaysInlinerPass

fn always_inliner_run(m: i32) -> u32 {
    inl_check_flags();
    psi_get(m);
    var changed = false;
    var comdat_fns: i32[>..<] = [];
    var need_flatten: i32[>..<] = [];
    var calls: i32[>..<] = [];
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if fn_has(f, 0, AK_Flatten) { need_flatten.push(f); }
        if fn_has(f, 0, AK_PresplitCoroutine) { f = nf; continue; }
        let viable, why = is_inline_viable(f);
        if func_is_decl(f) || !viable { f = nf; continue; }
        calls.resize(0);
        var u = first_use(f);
        while u >= 0 {
            let us = uses[u].user;
            u = use_next(u);
            if is_inst(us) && is_callbase(us) && called_function(us) == f && call_has_fn_attr(us, AK_AlwaysInline) &&
               !aset_has(alist_fn(insts[inst_of(us)].attrs), AK_NoInline) {
                var seen = false;
                for x in calls { if x == us { seen = true; } }
                if !seen { calls.push(us); }
            }
        }
        for cb in calls {
            if ai_try_inline(cb, f, false) { changed = true; }
        }
        sc_remove_dead_constant_users(f);
        if fn_has(f, 0, AK_AlwaysInline) && fn_is_def_trivially_dead(f) {
            if globs[glob_of(f)].comdat >= 0 { comdat_fns.push(f); }
            else {
                invalidate_function(f, PA_NONE);
                func_erase_from_parent(f);
                changed = true;
            }
        }
        f = nf;
    }
    for ff in need_flatten {
        var wl_cb: i32[>..<] = [];
        var wl_h: i64[>..<] = [];
        var hist_f: i32[>..<] = [];
        var hist_p: i64[>..<] = [];
        var b = func_first_block(ff);
        while b >= 0 {
            var i = block_first(b);
            while i >= 0 {
                if is_callbase(i) {
                    let callee = called_function(i);
                    if callee >= 0 && !func_is_decl(callee) { wl_cb.push(i); wl_h.push(-1); }
                }
                i = inst_next(i);
            }
            b = block_next(b);
        }
        while wl_cb.len > 0 {
            let cb = wl_cb.pop();
            let hid = wl_h.pop();
            let callee = called_function(cb);
            if callee < 0 { continue; }
            if callee == ff { continue; }
            let d, why = get_attribute_based_inlining_decision(cb, callee);
            if d != 1 { continue; }
            if !ai_try_inline(cb, callee, true) { continue; }
            changed = true;
            if ifi_inlined_call_sites.len > 0 {
                let nid = hist_f.len as i64;
                hist_f.push(callee);
                hist_p.push(hid);
                for ncb in ifi_inlined_call_sites {
                    let nc = called_function(ncb);
                    if nc >= 0 && !func_is_decl(nc) { wl_cb.push(ncb); wl_h.push(nid); }
                }
            }
        }
    }
    if comdat_fns.len > 0 {
        filter_dead_comdat_functions(comdat_fns);
        for cf in comdat_fns {
            invalidate_function(cf, PA_NONE);
            func_erase_from_parent(cf);
            changed = true;
        }
    }
    if !changed { return PA_ALL; }
    lcg_invalidate();
    return PA_FN;
}
// TryInline
fn ai_try_inline(cb: i32, callee: i32, want_sites: bool) -> bool {
    let caller = inst_func(cb);
    let d, why = get_attribute_based_inlining_decision(cb, callee);
    if d != 1 { return false; }
    if !inline_function(cb, true, true, want_sites, true, false, callee) { return false; }
    invalidate_function(caller, PA_NONE);
    if !want_sites { ifi_inlined_call_sites.resize(0); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ModuleInlinerPass with the PriorityInlineOrder

// priorities per call: (cost / size, static bonus)
var io_heap: i32[>..<];
var io_prio = hm_new();
var io_bonus = hm_new();
var io_mode: i64 = 0;       // 0 size, 1 cost (and ml), 2 cost-benefit
var io_params: IParams;
var io_with_psi: bool = false;

fn io_compute(cb: i32) {
    if io_mode == 0 {
        var n: i64 = 0;
        let f = called_function(cb);
        var b = func_first_block(f);
        while b >= 0 { var i = block_first(b); while i >= 0 { n++; i = inst_next(i); } b = block_next(b); }
        hm_put(io_prio, (cb as i64) as u64, n);
        return;
    }
    let c = get_inline_cost(cb, called_function(cb), io_params, true, io_with_psi);
    var cost: i64 = 0;
    var bonus: i64 = 0;
    if !icost_is_always(c) && !icost_is_never(c) { cost = c.cost; bonus = c.bonus; }
    else { cost = if icost_is_never(c) { INT_MAX32 } else { INT_MIN32 }; }
    hm_put(io_prio, (cb as i64) as u64, cost);
    hm_put(io_bonus, (cb as i64) as u64, if io_mode == 2 { bonus } else { 0 });
}
// PriorityT::isMoreDesirable(P1, P2) for two calls' current priorities
fn io_more_desirable_v(c1: i64, b1: i64, c2: i64, b2: i64) -> bool {
    if io_mode == 2 {
        let top = flag_int("module-inliner-top-priority-threshold", 0);
        let r1 = c1 + b1 < top;
        let r2 = c2 + b2 < top;
        if r1 || r2 {
            if r1 != r2 { return r1; }
            return c1 < c2;
        }
        return c1 < c2;
    }
    return c1 < c2;
}
fn io_prio_of(cb: i32) -> i64 { hm_get(io_prio, (cb as i64) as u64, 0) }
fn io_bonus_of(cb: i32) -> i64 { hm_get(io_bonus, (cb as i64) as u64, 0) }
// isLess(L, R) = hasLowerPriority(L, R) = isMoreDesirable(R, L)
fn io_less(l: i32, r: i32) -> bool { io_more_desirable_v(io_prio_of(r), io_bonus_of(r), io_prio_of(l), io_bonus_of(l)) }

// libstdc++ heap algorithms over io_heap[0..n)
fn io_push_heap_at(hole0: i64, top: i64, v: i32) {
    var hole = hole0;
    var parent = (hole - 1) / 2;
    while hole > top && io_less(io_heap[parent], v) {
        io_heap[hole] = io_heap[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    io_heap[hole] = v;
}
fn io_adjust_heap(hole0: i64, len: i64, v: i32) {
    let top = hole0;
    var hole = hole0;
    var child = hole;
    while child < (len - 1) / 2 {
        child = 2 * (child + 1);
        if io_less(io_heap[child], io_heap[child - 1]) { child--; }
        io_heap[hole] = io_heap[child];
        hole = child;
    }
    if (len & 1) == 0 && child == (len - 2) / 2 {
        child = 2 * (child + 1);
        io_heap[hole] = io_heap[child - 1];
        hole = child - 1;
    }
    io_push_heap_at(hole, top, v);
}
fn io_push_heap() { let n = io_heap.len; io_push_heap_at(n - 1, 0, io_heap[n - 1]); }
fn io_pop_heap() {
    let n = io_heap.len;
    if n <= 1 { return; }
    let v = io_heap[n - 1];
    io_heap[n - 1] = io_heap[0];
    io_adjust_heap(0, n - 1, v);
}
fn io_make_heap() {
    let n = io_heap.len;
    if n < 2 { return; }
    var parent = (n - 2) / 2;
    loop {
        let v = io_heap[parent];
        io_adjust_heap(parent, n, v);
        if parent == 0 { break; }
        parent--;
    }
}
fn io_push(cb: i32) {
    io_heap.push(cb);
    io_compute(cb);
    io_push_heap();
}
// pop_heap_adjust + pop_back_val
fn io_pop() -> i32 {
    io_pop_heap();
    loop {
        let b = io_heap[io_heap.len - 1];
        let oc = io_prio_of(b);
        let ob = io_bonus_of(b);
        io_compute(b);
        if !io_more_desirable_v(oc, ob, io_prio_of(b), io_bonus_of(b)) { break; }
        io_push_heap();
        io_pop_heap();
    }
    return io_heap.pop();
}

fn module_inliner_run(m: i32) -> u32 {
    inl_check_flags();
    let mode = flag_str("inline-priority-mode");
    io_mode = 0;
    // MLPriority (InlineOrder.cpp) is CostPriority under another name: the cost of a variable InlineCost, else
    // INT_MAX / INT_MIN, smaller first; no model is involved
    if mode == "cost" || mode == "ml" { io_mode = 1; } else if mode == "cost-benefit" { io_mode = 2; }
    else if mode.len > 0 && mode != "size" { fatal(str("opt: for the --inline-priority-mode option: Cannot find option named '", mode, "'!")); }
    io_params = get_inline_params();
    io_with_psi = psi_cached();
    io_heap.resize(0);
    hm_clear(io_prio);
    hm_clear(io_bonus);
    var changed = false;
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) {
            each_inst(f) { i =>
                if is_callbase(i) {
                    let callee = called_function(i);
                    if callee >= 0 {
                        if !func_is_decl(callee) { io_push(i); }
                        else if inst_iid(i) == 0 { set_inline_remark(i, "unavailable definition"); }
                    }
                }
            };
        }
        f = globs[glob_of(f)].next;
    }
    if io_heap.len == 0 { return PA_ALL; }
    var dead: i32[>..<] = [];
    while io_heap.len > 0 {
        let cb = io_pop();
        let callee = called_function(cb);
        let rec, oic = get_advice(cb, false, io_params, io_with_psi);
        if !rec { continue; }
        if !inline_function(cb, true, true, true, io_with_psi, true, inst_func(cb)) {
            if flag_bool("inline-remark-attribute", false) {
                var msg: u8[>..] = [];
                msg.append(sbytes(if_fail_reason));
                msg.append("; ");
                inline_cost_str(msg, oic);
                set_inline_remark(cb, msg);
            }
            continue;
        }
        changed = true;
        if ifi_inlined_call_sites.len > 0 {
            var k = ifi_inlined_call_sites.len - 1;
            while k >= 0 {
                let icb = ifi_inlined_call_sites[k];
                k--;
                let nc = called_function(icb);
                if nc >= 0 && !func_is_decl(nc) { io_push(icb); }
            }
        }
        if gv_has_local_linkage(callee) {
            sc_remove_dead_constant_users(callee);
            tli_cur_fn = callee;
            if fn_use_empty(callee) && tli_get_libfunc(callee) < 0 {
                var rest: i32[>..<] = [];
                for x in io_heap { if inst_func(x) != callee { rest.push(x); } }
                io_heap.resize(0);
                for x in rest { io_heap.push(x); }
                io_make_heap();
                func_drop_all_references(callee);
                dead.push(callee);
            }
        }
    }
    for d in dead {
        invalidate_function(d, PA_NONE);
        func_erase_from_parent(d);
    }
    if !changed { return PA_ALL; }
    return PA_NONE;
}

fn inliner_wrapper_run(m: i32, nomand: bool) -> u32 { fatal("internal: inliner-wrapper is expanded by the pipeline parser"); return PA_ALL; }
