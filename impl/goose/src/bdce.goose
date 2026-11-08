// BDCE: port of llvm/lib/Transforms/Scalar/BDCE.cpp (bitTrackingDCE, clearAssumptionsOfUsers).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import local;
import demandedbits;
import knownbits;

// clearAssumptionsOfUsers (scratch set VS_PASS0 = Visited)
fn clear_assumptions_of_users(i: i32) {
    if db_is_all_ones(i) { return; }
    vs_clear(VS_PASS0);
    var wl: i32[>..<] = [];
    var u = vals[i].first_use;
    while u >= 0 {
        let j = uses[u].user;
        if is_int_ty(vals[j].ty) { vs_add(VS_PASS0, j); wl.push(j); }
        u = uses[u].next;
    }
    while wl.len > 0 {
        let j = wl.pop();
        drop_poison_generating_annotations(j);
        if db_is_all_ones(j) { continue; }
        var u2 = vals[j].first_use;
        while u2 >= 0 {
            let k = uses[u2].user;
            if vs_add(VS_PASS0, k) && is_int_ty(vals[k].ty) { wl.push(k); }
            u2 = uses[u2].next;
        }
    }
}

fn bdce_run(fv: i32) -> u32 {
    db_invalidate();
    var wl: i32[>..<] = [];
    var changed = false;
    each_inst(fv) { i =>
        block {
            if inst_may_have_side_effects(i) && vals[i].first_use < 0 { break; }
            let isint = is_int_ty(vals[i].ty);
            local_have_tli = false;
            let dead = db_is_instruction_dead(i) || (isint && db_demanded_bits(i) == 0 && would_be_trivially_dead(i));
            local_have_tli = true;
            if dead { wl.push(i); changed = true; break; }
            let o = iop(i);
            if o == OP_SEXT {
                let demanded = db_demanded_bits(i);
                let src = op(i, 0);
                let sbits = ty_bits(ty_scalar(vals[src].ty));
                let dt = vals[i].ty;
                let dbits = ty_bits(ty_scalar(dt));
                if i != src && clz_w(demanded, dbits) >= dbits - sbits {
                    clear_assumptions_of_users(i);
                    if is_constant(src) { fatal("bdce: IRBuilder constant folding of zext is not ported yet"); }
                    let z = create_inst(OP_ZEXT, dt, [src]);
                    inst_insert_before(z, i);
                    set_name_from(z, i);
                    rauw(i, z);
                    wl.push(i);
                    changed = true;
                    break;
                }
            }
            if is_binary_op(o) {
                let demanded = db_demanded_bits(i);
                let w = ty_bits(ty_scalar(vals[i].ty));
                if demanded != wmask(w) {
                    let mv = op(i, 1);
                    if match_apint(mv) {
                        let mask = ap_lo64(apint_value(mv));
                        var can = false;
                        if o == OP_OR || o == OP_XOR { can = (demanded & mask) == 0; }
                        else if o == OP_AND { can = (demanded & ~mask) == 0; }
                        if can && i != op(i, 0) {
                            clear_assumptions_of_users(i);
                            rauw(i, op(i, 0));
                            wl.push(i);
                            changed = true;
                            break;
                        }
                    }
                }
            }
            for k in nops(i) {
                let v = op(i, k);
                if !is_int_ty(vals[v].ty) { continue; }
                if !is_inst(v) && !is_arg(v) { continue; }
                if !db_is_use_dead(i, k) { continue; }
                clear_assumptions_of_users(i);
                set_op(i, k, c_null(vals[v].ty));
                changed = true;
            }
        }
    };
    var k = wl.len;
    while k > 0 { k--; drop_all_refs(wl[k]); }
    for i in wl { inst_erase_from_parent(i); }
    db_invalidate();
    if !changed { return 0xFFFFFFFF; }
    return PA_CFG;
}
