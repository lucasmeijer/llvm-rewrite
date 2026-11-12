// DropUnnecessaryAssumes: port of llvm/lib/Transforms/Scalar/DropUnnecessaryAssumes.cpp
// (DropUnnecessaryAssumesPass), with AssumptionCache::findValuesAffectedByOperandBundle and
// findValuesAffectedByCondition (assume.goose, collecting mode).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import assume;
import vt;
import local;
import instsimplify;
import tli;
import gen_iids;

// affectedValuesAreEphemeral
fn du_affected_ephemeral(aff: const i32[:]) -> bool {
    var wl: i32[>..<] = [];
    vs_clear(VS_PASS0);
    fn add_users(v: i32, wl: i32[>..<]&) -> bool {
        var u = vals[v].first_use;
        while u >= 0 {
            if wl.len >= 32 { return false; }
            let us = uses[u].user;
            if vs_add(VS_PASS0, us) { wl.push(us); }
            u = uses[u].next;
        }
        return true;
    }
    for v in aff {
        if !is_inst(v) && !is_arg(v) { return false; }
        if !add_users(v, wl) { return false; }
    }
    var idx: i64 = 0;
    while idx < wl.len {
        let i = wl[idx];
        idx++;
        if iop(i) == OP_CALL && inst_iid(i) == IID_assume { continue; }
        if inst_may_have_side_effects(i) || is_terminator(i) { return false; }
        if !add_users(i, wl) { return false; }
    }
    return true;
}

fn du_add_affected_val(v: i32, out: i32[>..<]&) { if is_arg(v) || is_global(v) || is_inst(v) { out.push(v); } }

fn drop_unnecessary_assumes_run(fv: i32, drop_deref: bool) -> u32 {
    tli_cur_fn = fv;
    vt_invalidate_assumes();
    ac_invalidate();
    var asms: i32[>..<] = [];
    ac_assumptions(fv, asms);
    var changed = false;
    for a in asms {
        if is_dead(a) { continue; }
        let nb = cb_nbundles(a);
        if nb > 0 {
            var dead_args: i32[>..<] = [];
            var kept: i32[>..<] = [];   // bundle indices
            for k in nb {
                let tag = bundle_tag_name(a, k);
                let b = cb_bundle_begin(a, k);
                let n = cb_bundle_count(a, k);
                var dead = false;
                if tag == "ignore" { dead = true; }
                else if tag == "dereferenceable" { dead = drop_deref; }
                else if n == 0 { dead = false; }
                else {
                    var aff: i32[>..<] = [];
                    if tag == "separate_storage" {
                        du_add_affected_val(get_underlying_object(op(a, b), 10), aff);
                        du_add_affected_val(get_underlying_object(op(a, b + 1), 10), aff);
                    } else if n > 0 {
                        du_add_affected_val(op(a, b), aff);
                    }
                    dead = du_affected_ephemeral(aff);
                }
                if dead { for j in n { dead_args.push(op(a, b + j)); } }
                else { kept.push(k as i32); }
            }
            if kept.len != nb {
                if kept.len == 0 {
                    inst_erase_from_parent(a);
                } else {
                    // CallBase::Create(Assume, KeptBundles, Assume): same callee, args, name, tail kind, cc,
                    // attributes and debug location; other metadata is not copied
                    var ops: i32[>..<] = [];
                    let na = cb_nargs(a);
                    for j in na { ops.push(cb_arg(a, j)); }
                    var pairs: i32[>..<] = [];
                    for k in kept {
                        let b = cb_bundle_begin(a, k as i64);
                        let n = cb_bundle_count(a, k as i64);
                        for j in n { ops.push(op(a, b + j)); }
                        pairs.push(cb_bundle_tag(a, k as i64));
                        pairs.push(n as i32);
                    }
                    ops.push(cb_callee(a));
                    let c = create_inst(OP_CALL, vals[a].ty, ops);
                    let ci = inst_of(c);
                    let oi = inst_of(a);
                    insts[ci].ty2 = insts[oi].ty2;
                    insts[ci].pred = insts[oi].pred;
                    insts[ci].cc = insts[oi].cc;
                    insts[ci].attrs = insts[oi].attrs;
                    insts[ci].flags = insts[oi].flags;
                    insts[ci].fmf = insts[oi].fmf;
                    cb_set_bundles(c, na, pairs, 0);
                    inst_insert_before(c, a);
                    let dl = inst_get_md(a, 0);
                    if dl >= 0 { inst_set_md(c, 0, dl); }
                    ac_replace_assumption(a, c);
                    inst_erase_from_parent(a);
                }
                // RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadBundleArgs) (WeakTrackingVH)
                var dl2: i32[>..<] = [];
                for x in dead_args { if is_inst(x) && !is_dead(x) { dl2.push(x); } }
                local_have_tli = false;
                recursively_delete_trivially_dead(dl2);
                local_have_tli = true;
                changed = true;
            }
            continue;
        }
        let cond = cb_arg(a, 0);
        if is_inst(cond) && iop(cond) == OP_CALL && (inst_iid(cond) == IID_type_test || inst_iid(cond) == IID_public_type_test) { continue; }
        ac_coll.clear();
        ac_collecting = true;
        ac_affected_by_condition(cond, a);
        ac_collecting = false;
        var aff: i32[>..<] = [];
        for x in ac_coll { aff.push(x); }
        if !du_affected_ephemeral(aff) { continue; }
        inst_erase_from_parent(a);
        if is_inst(cond) {
            var d1: i32[>..<] = [cond];
            local_have_tli = false;
            recursively_delete_trivially_dead(d1);
            local_have_tli = true;
        }
        changed = true;
    }
    if !changed { return PA_ALL; }
    return PA_CFG;
}
