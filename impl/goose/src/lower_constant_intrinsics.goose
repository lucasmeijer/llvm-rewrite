// LowerConstantIntrinsics: port of llvm/lib/Transforms/Scalar/LowerConstantIntrinsics.cpp.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import dtu;
import cfgutil;
import tli;
import memorybuiltins;
import misc_util;
import gen_iids;
import pm;
import cfold;

// replaceConditionalBranchesOnConstant
fn lci_replace_branches(ii: i32, nv: i32, use_dtu: bool) -> bool {
    var dead_blocks = false;
    var unsimp: i32[>..<] = [];
    mu_replace_and_recursively_simplify(ii, nv, unsimp);
    for bi in unsimp {
        if is_dead(bi) || iop(bi) != OP_CONDBR { continue; }
        let c = op(bi, 0);
        var target: i32 = -1;
        var other: i32 = -1;
        if is_cint(c) && cint_is_zero(c) { target = term_succ(bi, 1); other = term_succ(bi, 0); }
        else if is_cint(c) && cint_lo(c) == 1 { target = term_succ(bi, 0); other = term_succ(bi, 1); }
        if target >= 0 && target != other {
            let src = inst_parent(bi);
            block_remove_predecessor(other, src, false);
            let nb = create_inst(OP_BR, T_VOID, [target]);
            block_append_inst(src, nb);
            let dl = inst_get_md(bi, 0);
            if dl >= 0 { inst_set_md(nb, 0, dl); }
            inst_erase_from_parent(bi);
            if use_dtu {
                let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: src, to: other }];
                dtu_apply_updates(ups);
            }
            if pred_count(other) == 0 { dead_blocks = true; }
        }
    }
    return dead_blocks;
}

fn lower_constant_intrinsics_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    let use_dtu = dt_valid(fv, DT_DOM);
    if use_dtu { dtu_begin(fv, true, false, true); }
    var dead_blocks = false;
    var rpo: i32[>..<] = [];
    mu_rpo(fv, rpo);
    var wl: i32[>..<] = [];
    for bb in rpo {
        var i = block_first(bb);
        while i >= 0 {
            if iop(i) == OP_CALL {
                let id = inst_iid(i);
                if id == IID_is_constant || id == IID_objectsize { wl.push(i); }
            }
            i = inst_next(i);
        }
    }
    // WeakTrackingVH: an erased intrinsic is skipped; one replaced in place can't happen without a callback here
    for ii in wl {
        if is_dead(ii) || !is_inst(ii) || iop(ii) != OP_CALL { continue; }
        let id = inst_iid(ii);
        var nv: i32 = -1;
        if id == IID_is_constant {
            let a = op(ii, 0);
            nv = if is_constant(a) && cf_is_manifest_constant(a) { c_int(vals[ii].ty, 1) } else { c_int(vals[ii].ty, 0) };
        } else if id == IID_objectsize {
            nv = mb_lower_object_size_call_aa(ii, true, false);
        } else { continue; }
        if lci_replace_branches(ii, nv, use_dtu) { dead_blocks = true; }
    }
    if dead_blocks {
        cu_dtu = use_dtu;
        cu_remove_unreachable_blocks(fv);
        cu_dtu = false;
    }
    if use_dtu { dtu_end(); }
    if wl.len == 0 { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}
