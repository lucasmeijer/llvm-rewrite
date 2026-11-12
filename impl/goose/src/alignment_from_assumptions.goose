// AlignmentFromAssumptions: port of llvm/lib/Transforms/Scalar/AlignmentFromAssumptions.cpp
// (AlignmentFromAssumptionsPass).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import scev;
import scev_create;
import assume;
import vt;
import poison;
import apint;
import memintr;
import tli;

fn afa_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << (a - 1) }; }
fn afa_set_align(i: i32, al: i64) {
    var k: u8 = 0;
    while ((1 as i64) << k) < al { k++; }
    insts[inst_of(i)].align = k + 1;
}

// getNewAlignmentDiff: 0 = std::nullopt
fn afa_new_alignment_diff(diff: i32, al: i32) -> i64 {
    let du = sc_get_urem(diff, al);
    if sc_kind(du) == SC_CONST {
        let a = sc_ap(du);
        if (a.w as i64) > 64 { fatal("alignment-from-assumptions: getSExtValue of a constant wider than 64 bits"); }
        let d = ap_sext64(a);
        if d == 0 {
            let av = ap_zext64(sc_ap(al));
            return av as i64;
        }
        let ab: u64 = if d < 0 { (0 - d) as u64 } else { d as u64 };
        if ab != 0 && (ab & (ab - 1)) == 0 { return ab as i64; }
    }
    return 0;
}

fn afa_new_alignment(aa: i32, al: i32, off: i32, p: i32) -> i64 {
    let ps = sc_get_scev(p);
    var diff = sc_get_minus(ps, aa, 0, 0);
    if diff == 0 { return 1; }
    diff = sc_get_noop_or_sign_extend(diff, sc_ty(off));
    diff = sc_add(diff, off);
    let n = afa_new_alignment_diff(diff, al);
    if n != 0 { return n; }
    if sc_kind(diff) == SC_ADDREC {
        let st = sc_op(diff, 0);
        let inc = sc_get_step_recurrence(diff);
        let na = afa_new_alignment_diff(st, al);
        let ni = afa_new_alignment_diff(inc, al);
        if na == 0 || ni == 0 { return 1; }
        if na > ni { return ni; }
        return na;
    }
    return 1;
}

fn afa_process(a: i32, idx: i64) -> bool {
    if bundle_tag_name(a, idx) != "align" { return false; }
    let b = cb_bundle_begin(a, idx);
    let n = cb_bundle_count(a, idx);
    let p = strip_ptr_casts_same_repr(op(a, b));
    var al = sc_get_scev(op(a, b + 1));
    al = sc_get_truncate_or_zero_extend(al, T_I64, 0);
    if sc_kind(al) != SC_CONST { return false; }
    let av = sc_ap(al);
    if !ap_is_pow2(av) { return false; }
    if ap_ugt_u64(av, (1 as u64) << 32) { return false; }
    var off: i32 = -1;
    if n == 3 { off = sc_get_scev(op(a, b + 2)); } else { off = sc_get_zero(T_I64); }
    off = sc_get_truncate_or_zero_extend(off, T_I64, 0);
    if is_constant_data(p) { return false; }
    let aas = sc_get_scev(p);
    vs_clear(VS_PASS0);
    var wl: i32[>..<] = [];
    let fa = inst_func(a);
    var u = vals[p].first_use;
    while u >= 0 {
        let j = uses[u].user;
        u = uses[u].next;
        if j == a { continue; }
        if is_inst(j) && inst_func(j) == fa { wl.push(j); }
    }
    while wl.len > 0 {
        let j = wl.pop();
        let o = iop(j);
        if o == OP_LOAD || o == OP_STORE {
            if valid_assume_for_context(a, j) {
                let na = afa_new_alignment(aas, al, off, if o == OP_LOAD { op(j, 0) } else { op(j, 1) });
                if na > afa_align(j) { afa_set_align(j, na); }
            }
        } else if o == OP_CALL && mi_is_mem_intrinsic(j) {
            if valid_assume_for_context(a, j) {
                let nd = afa_new_alignment(aas, al, off, mi_dest(j));
                let da = mi_dest_align(j);
                if da == 0 { fatal("alignment-from-assumptions: a memory intrinsic without a destination alignment"); }
                if (nd as u64) > da { mi_set_param_align(j, 0, nd as u64); }
                if mi_is_mem_transfer(j) {
                    let ns = afa_new_alignment(aas, al, off, mi_source(j));
                    let sa = mi_source_align(j);
                    if sa == 0 { fatal("alignment-from-assumptions: a memory transfer without a source alignment"); }
                    if (ns as u64) > sa { mi_set_param_align(j, 1, ns as u64); }
                }
            }
        }
        vs_add(VS_PASS0, j);
        if o == OP_GEP || o == OP_PHI {
            if ty_kind(vals[j].ty) == TK_PTR {
                var u2 = vals[j].first_use;
                while u2 >= 0 {
                    let k = uses[u2].user;
                    let opno = u2 - vals[k].ops;
                    u2 = uses[u2].next;
                    if iop(k) == OP_STORE && opno != 1 { continue; }
                    if !vs_has(VS_PASS0, k) { wl.push(k); }
                }
            }
        }
    }
    return true;
}

fn alignment_from_assumptions_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    vt_invalidate_assumes();
    dt_get(fv, DT_DOM);
    scev_get(fv);
    var asms: i32[>..<] = [];
    ac_assumptions(fv, asms);
    var changed = false;
    for a in asms {
        if is_dead(a) { continue; }
        for k in cb_nbundles(a) { if afa_process(a, k) { changed = true; } }
    }
    if !changed { return PA_ALL; }
    return PA_CFG | ((1 as u32) << A_SCEV);
}
