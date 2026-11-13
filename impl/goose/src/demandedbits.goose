// DemandedBits: port of llvm/lib/Analysis/DemandedBits.cpp (performAnalysis, determineLiveOperandBits,
// getDemandedBits, isInstructionDead, isUseDead, print) on APInts of any width.
// State lives in scratch slots (irutil.goose): AliveBits = VM_ANA0 (value -> demanded mask), Visited = VS_ANA0,
// DeadUses and worklist membership are private stamped sets (db_dead_*, db_wl_*): ValueTracking, which the
// analysis calls through computeKnownBits, uses VS_ANA1 (poison.goose, vt.goose) and callers hold VS_PASS*.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import flags;
import knownbits;
import apint;
import gen_iids;
import datalayout;

var db_fn: i32 = -1;          // function the current results are for (-1: none)

// private stamped sets: DeadUses (keyed by use id) and worklist membership (keyed by value id)
var db_dead_stamp: i32[>..];
var db_dead_epoch: i32 = 1;
var db_wl_stamp: i32[>..];
var db_wl_epoch: i32 = 1;
fn db_dead_has(u: i32) -> bool { (u as i64) < db_dead_stamp.len && db_dead_stamp[u] == db_dead_epoch }
fn db_dead_add(u: i32) { while db_dead_stamp.len <= (u as i64) { db_dead_stamp.push(0); } db_dead_stamp[u] = db_dead_epoch; }
fn db_dead_del(u: i32) { if db_dead_has(u) { db_dead_stamp[u] = 0; } }
fn db_wl_add(v: i32) -> bool {
    while db_wl_stamp.len <= (v as i64) { db_wl_stamp.push(0); }
    if db_wl_stamp[v] == db_wl_epoch { return false; }
    db_wl_stamp[v] = db_wl_epoch;
    return true;
}
fn db_wl_del(v: i32) { if (v as i64) < db_wl_stamp.len && db_wl_stamp[v] == db_wl_epoch { db_wl_stamp[v] = 0; } }

fn db_invalidate() { db_fn = -1; }

fn is_int_ty(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn int_width(t: i32) -> i64 { ty_bits(ty_scalar(t)) }

fn db_always_live(i: i32) -> bool { is_terminator(i) || inst_is_eh_pad(i) || inst_may_have_side_effects(i) }

// AliveBits storage (VM_ANA0, value -> i64): the mask itself for widths <= 64; for wider integers the value id of
// an IR constant holding it (APInt words don't outlive a pass, the cached analysis does)
fn db_store(v: i32, a: AP) {
    if a.w <= 64 { vm_set(VM_ANA0, v, a.lo as! i64); return; }
    vm_set(VM_ANA0, v, ap_to_cint(ty_int(a.w as i64), a) as i64);
}
fn db_load(v: i32) -> AP {
    let w = int_width(vals[v].ty);
    let x = vm_get(VM_ANA0, v, 0);
    if w <= 64 { return ap_u64(x as! u64, w); }
    return ci_ap(x as i32);
}

// determineLiveOperandBitsAddCarry
fn live_bits_add_carry(opno: i64, aout: AP, l: KB, r: KB, carry_zero: bool, carry_one: bool) -> AP {
    let w = aout.w as i64;
    let bound = ap_or(ap_and(l.z, r.z), ap_and(l.o, r.o));
    let rbound = ap_reverse_bits(bound);
    let raout = ap_reverse_bits(aout);
    let rprop = ap_add(raout, ap_or(raout, ap_not(rbound)));
    let racarry = ap_xor(rprop, ap_not(rbound));
    let acarry = ap_reverse_bits(racarry);
    var nz = ap_zero(w);
    var no = ap_zero(w);
    if opno == 0 { nz = ap_or(l.z, ap_not(r.z)); no = ap_or(l.o, ap_not(r.o)); }
    else { nz = ap_or(r.z, ap_not(l.z)); no = ap_or(r.o, ap_not(l.o)); }
    let psz = ap_add(ap_add(ap_not(l.z), ap_not(r.z)), ap_u64(if carry_zero { 0 } else { 1 }, w));
    let pso = ap_add(ap_add(l.o, r.o), ap_u64(if carry_one { 1 } else { 0 }, w));
    let need = ap_and(ap_or(ap_not(psz), nz), ap_or(pso, no));
    return ap_or(aout, ap_and(acarry, need));
}

// determineLiveOperandBits: the live bits of operand `opno` of `user` given the user's live output bits.
// kc: known bits cache (Known, Known2, computed) shared between the operands of one user.
struct KBCache { k1: KB, k2: KB, done: bool }

fn determine_live_operand_bits(user: i32, val: i32, opno: i64, aout: AP, ab0: AP, bw: i64, kc: KBCache&) -> AP {
    var ab = ab0;
    fn compute(v1: i32, v2: i32) {
        if kc.done { return; }
        kc.done = true;
        kb_cxt = user;
        kc.k1 = kb_compute_all(v1, 0);
        if v2 >= 0 { kc.k2 = kb_compute_all(v2, 0); }
    }
    fn shifted_range(mn: i64, mx: i64, left: bool) -> AP {
        fn sh(x: AP, s: i64) -> AP { if left { ap_shl(x, s) } else { ap_lshr(x, s) } }
        var range = mx - mn;
        var mask = aout;
        var shifted = aout;
        var amt: i64 = 1;
        while amt <= range {
            if (range & amt) != 0 {
                mask = ap_or(mask, sh(shifted, range - amt + 1));
                range -= amt;
            }
            shifted = ap_or(shifted, sh(shifted, amt));
            amt = amt << 1;
        }
        return sh(mask, mn);
    }
    let o = iop(user);
    let fl = insts[inst_of(user)].flags;
    if o == OP_CALL || o == OP_INVOKE {
        let id = call_iid(user);
        if id == IID_bswap { ab = ap_byte_swap(aout); }
        else if id == IID_bitreverse { ab = ap_reverse_bits(aout); }
        else if id == IID_clmul { ab = ap_low_bits(bw, ap_active_bits(aout)); }
        else if id == IID_ctlz {
            if opno == 0 { compute(val, -1); ab = ap_high_bits(bw, min(bw, kb_max_lz(kc.k1) + 1)); }
        } else if id == IID_cttz {
            if opno == 0 { compute(val, -1); ab = ap_low_bits(bw, min(bw, kb_max_tz(kc.k1) + 1)); }
        } else if id == IID_fshl || id == IID_fshr {
            if opno == 2 {
                if is_pow2_w(bw) { ab = ap_u64((bw - 1) as u64, bw); }
            } else {
                let sa = op(user, 2);
                if match_apint(sa) {
                    var amt = ap_rot_amount(ap_zero(bw), apint_value(sa));
                    if id == IID_fshr { amt = bw - amt; }
                    if opno == 0 { ab = ap_lshr(aout, amt); }
                    else if opno == 1 { ab = ap_shl(aout, bw - amt); }
                }
            }
        } else if id == IID_umax || id == IID_umin || id == IID_smax || id == IID_smin {
            ab = ap_bits_from(bw, ap_countr_zero(aout));
        }
        return ab;
    }
    if o == OP_ADD || o == OP_SUB {
        if ap_is_mask(aout) { return aout; }
        compute(op(user, 0), op(user, 1));
        if o == OP_ADD { return live_bits_add_carry(opno, aout, kc.k1, kc.k2, true, false); }
        let nr = kb_flip(kc.k2);
        return live_bits_add_carry(opno, aout, kc.k1, nr, false, true);
    }
    if o == OP_MUL { return ap_low_bits(bw, ap_active_bits(aout)); }
    if o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
        if opno != 0 { return ab; }
        let s = op(user, 1);
        let exact = (fl & FL_EXACT) != 0;
        if match_apint(s) {
            let sa = limited(apint_value(s), bw - 1);
            if o == OP_SHL {
                ab = ap_lshr(aout, sa);
                if (fl & FL_NSW) != 0 { ab = ap_or(ab, ap_high_bits(bw, sa + 1)); }
                else if (fl & FL_NUW) != 0 { ab = ap_or(ab, ap_high_bits(bw, sa)); }
            } else {
                ab = ap_shl(aout, sa);
                if o == OP_ASHR && ap_intersects(aout, ap_high_bits(bw, sa)) { ab = ap_set_bit(ab, bw - 1); }
                if exact { ab = ap_or(ab, ap_low_bits(bw, sa)); }
            }
            return ab;
        }
        compute(s, -1);
        let mn = limited(kb_min(kc.k1), bw - 1);
        let mx = limited(kb_max(kc.k1), bw - 1);
        if o == OP_SHL {
            ab = shifted_range(mn, mx, false);
            if (fl & FL_NSW) != 0 { ab = ap_or(ab, ap_high_bits(bw, mx + 1)); }
            else if (fl & FL_NUW) != 0 { ab = ap_or(ab, ap_high_bits(bw, mx)); }
        } else {
            ab = shifted_range(mn, mx, true);
            if o == OP_ASHR && mx != 0 && ap_intersects(aout, ap_high_bits(bw, mx)) { ab = ap_set_bit(ab, bw - 1); }
            if exact { ab = ap_or(ab, ap_low_bits(bw, mx)); }
        }
        return ab;
    }
    if o == OP_AND || o == OP_OR {
        ab = aout;
        compute(op(user, 0), op(user, 1));
        if o == OP_AND {
            if opno == 0 { ab = ap_and(ab, ap_not(kc.k2.z)); } else { ab = ap_and(ab, ap_not(ap_and(kc.k1.z, ap_not(kc.k2.z)))); }
        } else {
            if opno == 0 { ab = ap_and(ab, ap_not(kc.k2.o)); } else { ab = ap_and(ab, ap_not(ap_and(kc.k1.o, ap_not(kc.k2.o)))); }
        }
        return ab;
    }
    if o == OP_XOR || o == OP_PHI { return aout; }
    if o == OP_TRUNC { return ap_zext(aout, bw); }        // AOut.zext(BitWidth)
    if o == OP_ZEXT { return ap_trunc(aout, bw); }        // AOut.trunc(BitWidth)
    if o == OP_SEXT {
        ab = ap_trunc(aout, bw);
        let ow = aout.w as i64;
        if ap_intersects(aout, ap_bits_from(ow, bw)) { ab = ap_set_bit(ab, bw - 1); }
        return ab;
    }
    if o == OP_SELECT { if opno != 0 { return aout; } return ab; }
    if o == OP_EXTRACTELEMENT { if opno == 0 { return aout; } return ab; }
    if o == OP_INSERTELEMENT || o == OP_SHUFFLEVECTOR { if opno == 0 || opno == 1 { return aout; } return ab; }
    return ab;
}

// performAnalysis
fn db_analyze(fv: i32) {
    if db_fn == fv { return; }
    db_fn = fv;
    vs_clear(VS_ANA0);
    db_dead_epoch += 1;
    vm_clear(VM_ANA0);
    db_wl_epoch += 1;
    var wl: i32[>..<] = [];
    fn wl_insert(i: i32) { if db_wl_add(i) { wl.push(i); } }
    each_inst(fv) { i =>
        if db_always_live(i) {
            if is_int_ty(vals[i].ty) {
                if !vm_has(VM_ANA0, i) { db_store(i, ap_zero(int_width(vals[i].ty))); wl_insert(i); }
            } else {
                for k in nops(i) {
                    let j = op(i, k);
                    if !is_inst(j) { continue; }
                    if is_int_ty(vals[j].ty) { db_store(j, ap_ones(int_width(vals[j].ty))); }
                    else { vs_add(VS_ANA0, j); }
                    wl_insert(j);
                }
            }
        }
    };
    while wl.len > 0 {
        let user = wl.pop();
        db_wl_del(user);
        var aout = ap_zero(1);
        var dead_in = false;
        if is_int_ty(vals[user].ty) {
            aout = db_load(user);
            dead_in = ap_is_zero(aout) && !db_always_live(user);
        }
        var kc = KBCache { k1: kb_unknown(1), k2: kb_unknown(1), done: false };
        for k in nops(user) {
            let ov = op(user, k);
            let isi = is_inst(ov);
            if !isi && !is_arg(ov) { continue; }
            let t = vals[ov].ty;
            if is_int_ty(t) {
                let bw = int_width(t);
                var ab = ap_ones(bw);
                let u = vals[user].ops + k as i32;
                if dead_in {
                    ab = ap_zero(bw);
                } else {
                    ab = determine_live_operand_bits(user, ov, k, aout, ab, bw, kc);
                    if ap_is_zero(ab) { db_dead_add(u); } else { db_dead_del(u); }
                }
                if isi {
                    if !vm_has(VM_ANA0, ov) {
                        db_store(ov, ab);
                        wl_insert(ov);
                    } else {
                        let old = db_load(ov);
                        let nw = ap_or(ab, old);
                        if ap_ne(nw, old) { db_store(ov, nw); wl_insert(ov); }
                    }
                }
            } else if isi && vs_add(VS_ANA0, ov) {
                wl_insert(ov);
            }
        }
    }
}

// getDemandedBits(I)
fn db_demanded_bits_ap(i: i32) -> AP {
    db_analyze(inst_func(i));
    if vm_has(VM_ANA0, i) { return db_load(i); }
    return ap_ones(int_width(vals[i].ty));
}
// getDemandedBits(I) for widths of at most 64 bits
fn db_demanded_bits(i: i32) -> u64 {
    if int_width(vals[i].ty) > 64 { fatal("internal: db_demanded_bits on an integer wider than 64 bits (use db_demanded_bits_ap)"); }
    return ap_lo64(db_demanded_bits_ap(i));
}
fn db_is_all_ones(i: i32) -> bool { ap_is_all_ones(db_demanded_bits_ap(i)) }

fn db_is_instruction_dead(i: i32) -> bool {
    db_analyze(inst_func(i));
    return !vs_has(VS_ANA0, i) && !vm_has(VM_ANA0, i) && !db_always_live(i);
}

// isUseDead(user's operand k)
fn db_is_use_dead(user: i32, k: i64) -> bool {
    let v = op(user, k);
    if !is_int_ty(vals[v].ty) { return false; }
    if db_always_live(user) { return false; }
    db_analyze(inst_func(user));
    if db_dead_has(vals[user].ops + k as i32) { return true; }
    if is_int_ty(vals[user].ty) && vm_has(VM_ANA0, user) && ap_is_zero(db_load(user)) { return true; }
    return false;
}

// getDemandedBits(Use *)
fn db_demanded_bits_use(user: i32, k: i64) -> AP {
    let v = op(user, k);
    let t = vals[v].ty;
    if !is_int_ty(t) {
        let sz = ty_size_in_bits_for_print(t);
        return ap_ones(sz);
    }
    let bw = int_width(t);
    if db_is_use_dead(user, k) { return ap_zero(bw); }
    db_analyze(inst_func(user));
    let aout = db_demanded_bits_ap(user);
    var kc = KBCache { k1: kb_unknown(1), k2: kb_unknown(1), done: false };
    return determine_live_operand_bits(user, v, k, aout, ap_ones(bw), bw, kc);
}

// DL.getTypeSizeInBits of a non-integer scalar type (pointer sizes come from the module's DataLayout); the printer
// shows APInt::getLimitedValue, so anything wider than 64 bits prints as 64 ones
fn ty_size_in_bits_for_print(t0: i32) -> i64 {
    let k = ty_kind(ty_scalar(t0));
    if k == TK_METADATA || k == TK_TOKEN || k == TK_VOID {
        // DataLayout::getTypeSizeInBits hits llvm_unreachable (undefined in a release build)
        fatal("print<demanded-bits>: the size of a metadata/token operand is undefined in LLVM (not supported)");
    }
    let sz = dl_size_bits(ty_scalar(t0));
    return if sz > 64 { 64 } else { sz };
}

// DemandedBits::print. LLVM iterates a DenseMap keyed by pointers (unordered; tests compare sorted lines);
// we print in instruction order.
fn print_demanded_bits(fv: i32) {
    errs("Printing analysis 'Demanded Bits Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    db_analyze(fv);
    each_inst(fv) { i =>
        if vm_has(VM_ANA0, i) {
            errs("DemandedBits: 0x");
            db_errs_hex(db_load(i));
            errs(" for ");
            errs_inst(i, fv);
            errs("\n");
            for k in nops(i) {
                errs("DemandedBits: 0x");
                db_errs_hex(db_demanded_bits_use(i, k));
                errs(" for ");
                errs_operand(op(i, k), fv, false);
                errs(" in ");
                errs_inst(i, fv);
                errs("\n");
            }
        }
    };
}

// the printer's Twine::utohexstr(A.getLimitedValue())
fn db_errs_hex(a: AP) { errs_hex(ap_limited(a, 0xFFFFFFFFFFFFFFFF)); }
