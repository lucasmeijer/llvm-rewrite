// InferAlignment: port of llvm/lib/Transforms/Scalar/InferAlignment.cpp (InferAlignmentPass), with
// ScopedHashTable<Value *, Align> as a stack of shadowing entries.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import datalayout;
import knownbits;
import domcond;
import vt;
import assume;
import apint;
import pm;
import tli;
import autoupgrade;
import gen_iids;
import gen_attrs;
import ic;

fn ia_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << (a - 1) }; }
fn ia_set_align(i: i32, al: i64) {
    var k: u8 = 0;
    while ((1 as i64) << k) < al { k++; }
    insts[inst_of(i)].align = k + 1;
}

// MinAlign(A, B) for an alignment and a 64-bit offset
fn ia_common_align(a: i64, off: u64) -> i64 {
    let x = (a as u64) | off;
    return (x & (0 - x)) as i64;
}

// ScopedHT: entries (key, value, previous entry of the key); VM_PASS0 maps key -> top entry index + 1
var ia_ent_key: i32[>..<];
var ia_ent_val: i64[>..<];
var ia_ent_prev: i64[>..<];
fn ia_lookup(k: i32) -> i64 {
    let e = vm_get(VM_PASS0, k, 0) - 1;
    return if e >= 0 { ia_ent_val[e] } else { 1 };
}
fn ia_insert(k: i32, v: i64) {
    ia_ent_key.push(k);
    ia_ent_val.push(v);
    ia_ent_prev.push(vm_get(VM_PASS0, k, 0) - 1);
    vm_set(VM_PASS0, k, ia_ent_key.len as i64);
}
fn ia_pop_scope(mark: i64) {
    while ia_ent_key.len > mark {
        let e = ia_ent_key.len - 1;
        let k = ia_ent_key[e];
        vm_set(VM_PASS0, k, ia_ent_prev[e] + 1);
        ia_ent_key.pop(); ia_ent_val.pop(); ia_ent_prev.pop();
    }
}

var ia_mode: i64 = 0;    // 0: enforce preferred alignment, 1: known bits + base pointers
var ia_cur: i32 = -1;    // the instruction being improved (the known-bits context)

fn ia_from_known_bits(p: i32) -> i64 {
    let sv = dc_active;
    dc_active = false;
    kb_cxt = ia_cur;
    let known = kb_compute_all(p, 0);
    dc_active = sv;
    var tz = kb_min_tz(known);
    if tz > 32 { tz = 32; }
    let bw = kb_bw(known);
    let e = if bw - 1 < tz { bw - 1 } else { tz };
    return (1 as i64) << e;
}

fn ia_from_base_pointer(p0: i32, ls_align: i64) -> i64 {
    let p = strip_and_accumulate_offsets(p0, true, false, false);
    let off = vt_off as u64;
    let bpa = ia_common_align(ls_align, off);
    let best = ia_lookup(p);
    if best != 1 && best > bpa { return ia_common_align(best, off); }
    ia_insert(p, bpa);
    return ls_align;
}

fn ia_fn(p: i32, old: i64, pref: i64) -> i64 {
    if ia_mode == 0 {
        if pref > old { return max(old, ic::lsa_try_enforce_alignment(p, pref)); }
        return old;
    }
    let a = ia_from_known_bits(p);
    let b = ia_from_base_pointer(p, old);
    return max(a, b);
}

fn ia_try_improve(i: i32) -> bool {
    ia_cur = i;
    let o = iop(i);
    if o == OP_LOAD || o == OP_STORE {
        let p = if o == OP_LOAD { op(i, 0) } else { op(i, 1) };
        let old = ia_align(i);
        let lt: i32 = if o == OP_LOAD { vals[i].ty } else { vals[op(i, 0)].ty };
        let pref = dl_align(lt, false);
        let nw = ia_fn(p, old, pref);
        if nw > old { ia_set_align(i, nw); return true; }
    }
    if o == OP_AND {
        let a = op(i, 0);
        let c = op(i, 1);
        if is_op(a, OP_PTRTOINT) || is_op(a, OP_PTRTOADDR) {
            let cc = m_apint(c);
            if cc >= 0 {
                let p = op(a, 0);
                let actual = ia_fn(p, 1, 1);
                let cv = ci_ap(cc);
                if ap_ult_u64(cv, actual as u64) { rauw(i, c_null(vals[i].ty)); return true; }
                var lg: i64 = 0;
                while ((1 as i64) << lg) < actual { lg++; }
                let w = cv.w as i64;
                if ap_uge(cv, ap_shl(ap_ones(w), lg)) { rauw(i, op(i, 0)); return true; }
            }
        }
    }
    if o == OP_TRUNC {
        let a = op(i, 0);
        if is_op(a, OP_PTRTOINT) || is_op(a, OP_PTRTOADDR) {
            let actual = ia_fn(op(a, 0), 1, 1);
            var lg: i64 = 0;
            while ((1 as i64) << lg) < actual { lg++; }
            if lg >= ty_bits(ty_scalar(vals[i].ty)) { rauw(i, c_null(vals[i].ty)); return true; }
        }
    }
    if o != OP_CALL { return false; }
    let id = inst_iid(i);
    if id == IID_masked_load || id == IID_masked_store {
        let k: i64 = if id == IID_masked_load { 0 } else { 1 };
        let p = cb_arg(i, k);
        let t: i32 = if id == IID_masked_load { vals[i].ty } else { vals[cb_arg(i, 0)].ty };
        var old = ic::aset_int(alist_param(insts[inst_of(i)].attrs, k), AK_Alignment) as i64;
        if old == 0 { old = 1; }
        let pref = dl_align(t, false);
        let nw = ia_fn(p, old, pref);
        if nw <= old { return false; }
        let l = insts[inst_of(i)].attrs;
        let s = aset_with(alist_param(l, k), attr_int(AK_Alignment, nw as u64));
        insts[inst_of(i)].attrs = alist_set_param(l, k, s);
        return true;
    }
    return false;
}

fn infer_alignment_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    vt_invalidate_assumes();
    dt_get(fv, DT_DOM);
    ia_mode = 0;
    var bb = func_first_block(fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 { let nx = inst_next(i); ia_try_improve(i); i = nx; }
        bb = block_next(bb);
    }
    ia_mode = 1;
    vm_clear(VM_PASS0);
    ia_ent_key.clear(); ia_ent_val.clear(); ia_ent_prev.clear();
    // DFS over the dominator tree; a node's scope opens when it is pushed
    var stk_node: i32[>..<] = [];
    var stk_child: i32[>..<] = [];
    var stk_mark: i64[>..<] = [];
    var stk_done: bool[>..<] = [];
    let root = dt_root(fv, DT_DOM);
    stk_node.push(root); stk_child.push(dt_first_child(fv, DT_DOM, root)); stk_mark.push(ia_ent_key.len); stk_done.push(false);
    while stk_node.len > 0 {
        let t = stk_node.len - 1;
        if !stk_done[t] {
            var i = block_first(stk_node[t]);
            while i >= 0 { let nx = inst_next(i); ia_try_improve(i); i = nx; }
            stk_done[t] = true;
        }
        let c = stk_child[t];
        if c >= 0 {
            stk_child[t] = dt_next_sibling(DT_DOM, c);
            stk_node.push(c); stk_child.push(dt_first_child(fv, DT_DOM, c)); stk_mark.push(ia_ent_key.len); stk_done.push(false);
        } else {
            ia_pop_scope(stk_mark[t]);
            stk_node.pop(); stk_child.pop(); stk_mark.pop(); stk_done.pop();
        }
    }
    vm_clear(VM_PASS0);
    return PA_ALL;
}
