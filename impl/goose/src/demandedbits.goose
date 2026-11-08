// DemandedBits: port of llvm/lib/Analysis/DemandedBits.cpp (performAnalysis, determineLiveOperandBits,
// getDemandedBits, isInstructionDead, isUseDead, print), for integers of at most 64 bits.
// State lives in scratch slots (irutil.goose): AliveBits = VM_ANA0 (value -> demanded mask), Visited = VS_ANA0,
// DeadUses = VS_ANA1 (keyed by use id), worklist membership = VS_PASS1 while the analysis runs.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import flags;
import knownbits;
import gen_iids;

var db_fn: i32 = -1;          // function the current results are for (-1: none)

fn db_invalidate() { db_fn = -1; }

fn is_int_ty(t: i32) -> bool { ty_is_int(ty_scalar(t)) }
fn int_width(t: i32) -> i64 {
    let w = ty_bits(ty_scalar(t));
    if w > 64 { fatal("DemandedBits: integers wider than 64 bits are not supported yet"); }
    return w;
}

fn db_always_live(i: i32) -> bool { is_terminator(i) || inst_is_eh_pad(i) || inst_may_have_side_effects(i) }

fn shl_w(x: u64, s: i64, w: i64) -> u64 { if s >= w { 0 } else { (x << s) & wmask(w) } }
fn lshr_w(x: u64, s: i64, w: i64) -> u64 { if s >= w { 0 } else { (x & wmask(w)) >> s } }
fn active_bits(x: u64) -> i64 { 64 - clz(x) }
fn is_mask_w(x: u64) -> bool { x != 0 && (x & (x + 1)) == 0 }

// determineLiveOperandBitsAddCarry
fn live_bits_add_carry(opno: i64, aout: u64, l: KB, r: KB, carry_zero: bool, carry_one: bool) -> u64 {
    let w = l.w as i64;
    let m = wmask(w);
    let bound = (l.z & r.z) | (l.o & r.o);
    let rbound = reverse_bits_w(bound, w);
    let raout = reverse_bits_w(aout, w);
    let rprop = (raout + (raout | (~rbound & m))) & m;
    let racarry = (rprop ^ (~rbound & m)) & m;
    let acarry = reverse_bits_w(racarry, w);
    var nz: u64 = 0;
    var no: u64 = 0;
    if opno == 0 { nz = l.z | (~r.z & m); no = l.o | (~r.o & m); }
    else { nz = r.z | (~l.z & m); no = r.o | (~l.o & m); }
    let psz = ((~l.z & m) + (~r.z & m) + (if carry_zero { 0 } else { 1 })) & m;
    let pso = (l.o + r.o + (if carry_one { 1 } else { 0 })) & m;
    let need = ((~psz & m) | nz) & (pso | no);
    return (aout | (acarry & need)) & m;
}

// determineLiveOperandBits: the live bits of operand `opno` of `user` given the user's live output bits.
// kc: known bits cache (Known, Known2, computed) shared between the operands of one user.
struct KBCache { k1: KB, k2: KB, done: bool }

fn determine_live_operand_bits(user: i32, val: i32, opno: i64, aout: u64, ab0: u64, bw: i64, kc: KBCache&) -> u64 {
    var ab = ab0;
    let m = wmask(bw);
    fn compute(v1: i32, v2: i32) {
        if kc.done { return; }
        kc.done = true;
        kb_cxt = user;
        kc.k1 = kb_compute_all(v1, 0);
        if v2 >= 0 { kc.k2 = kb_compute_all(v2, 0); }
    }
    fn shifted_range(mn: i64, mx: i64, left: bool) -> u64 {
        fn sh(x: u64, s: i64) -> u64 { if left { shl_w(x, s, bw) } else { lshr_w(x, s, bw) } }
        var range = mx - mn;
        var mask = aout;
        var shifted = aout;
        var amt: i64 = 1;
        while amt <= range {
            if (range & amt) != 0 {
                mask |= sh(shifted, range - amt + 1);
                range -= amt;
            }
            shifted |= sh(shifted, amt);
            amt = amt << 1;
        }
        return sh(mask, mn);
    }
    let o = iop(user);
    let fl = insts[inst_of(user)].flags;
    if o == OP_CALL || o == OP_INVOKE {
        let id = call_iid(user);
        if id == IID_bswap { ab = byte_swap_w(aout, bw); }
        else if id == IID_bitreverse { ab = reverse_bits_w(aout, bw); }
        else if id == IID_clmul { ab = low_bits(active_bits(aout)); }
        else if id == IID_ctlz {
            if opno == 0 { compute(val, -1); ab = high_bits(bw, min(bw, kb_max_lz(kc.k1) + 1)); }
        } else if id == IID_cttz {
            if opno == 0 { compute(val, -1); ab = low_bits(min(bw, kb_max_tz(kc.k1) + 1)); }
        } else if id == IID_fshl || id == IID_fshr {
            if opno == 2 {
                if is_pow2_w(bw) { ab = (bw - 1) as u64; }
            } else {
                let sa = op(user, 2);
                if match_apint(sa) {
                    var amt = (apint_value(sa) % (bw as u64)) as i64;
                    if id == IID_fshr { amt = bw - amt; }
                    if opno == 0 { ab = lshr_w(aout, amt, bw); }
                    else if opno == 1 { ab = shl_w(aout, bw - amt, bw); }
                }
            }
        } else if id == IID_umax || id == IID_umin || id == IID_smax || id == IID_smin {
            ab = m & ~low_bits(ctz_w(aout, bw));
        }
        return ab;
    }
    if o == OP_ADD || o == OP_SUB {
        if is_mask_w(aout) { return aout; }
        compute(op(user, 0), op(user, 1));
        if o == OP_ADD { return live_bits_add_carry(opno, aout, kc.k1, kc.k2, true, false); }
        let nr = KB { z: kc.k2.o, o: kc.k2.z, w: kc.k2.w };
        return live_bits_add_carry(opno, aout, kc.k1, nr, false, true);
    }
    if o == OP_MUL { return low_bits(active_bits(aout)); }
    if o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
        if opno != 0 { return ab; }
        let s = op(user, 1);
        let exact = (fl & FL_EXACT) != 0;
        if match_apint(s) {
            let sa = limited(apint_value(s), bw - 1);
            if o == OP_SHL {
                ab = lshr_w(aout, sa, bw);
                if (fl & FL_NSW) != 0 { ab |= high_bits(bw, sa + 1); }
                else if (fl & FL_NUW) != 0 { ab |= high_bits(bw, sa); }
            } else {
                ab = shl_w(aout, sa, bw);
                if o == OP_ASHR && (aout & high_bits(bw, sa)) != 0 { ab |= sbit(bw); }
                if exact { ab |= low_bits(sa); }
            }
            return ab;
        }
        compute(s, -1);
        let mn = limited(kb_min(kc.k1), bw - 1);
        let mx = limited(kb_max(kc.k1), bw - 1);
        if o == OP_SHL {
            ab = shifted_range(mn, mx, false);
            if (fl & FL_NSW) != 0 { ab |= high_bits(bw, mx + 1); }
            else if (fl & FL_NUW) != 0 { ab |= high_bits(bw, mx); }
        } else {
            ab = shifted_range(mn, mx, true);
            if o == OP_ASHR && mx != 0 && (aout & high_bits(bw, mx)) != 0 { ab |= sbit(bw); }
            if exact { ab |= low_bits(mx); }
        }
        return ab;
    }
    if o == OP_AND || o == OP_OR {
        ab = aout;
        compute(op(user, 0), op(user, 1));
        if o == OP_AND {
            if opno == 0 { ab &= ~kc.k2.z; } else { ab &= ~(kc.k1.z & ~kc.k2.z); }
        } else {
            if opno == 0 { ab &= ~kc.k2.o; } else { ab &= ~(kc.k1.o & ~kc.k2.o); }
        }
        return ab & m;
    }
    if o == OP_XOR || o == OP_PHI { return aout; }
    if o == OP_TRUNC { return aout; }                       // AOut.zext(BitWidth)
    if o == OP_ZEXT { return aout & m; }                    // AOut.trunc(BitWidth)
    if o == OP_SEXT {
        ab = aout & m;
        let ow = int_width(vals[user].ty);
        if (aout & high_bits(ow, ow - bw)) != 0 { ab |= sbit(bw); }
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
    vs_clear(VS_ANA1);
    vm_clear(VM_ANA0);
    vs_clear(VS_PASS1);
    var wl: i32[>..<] = [];
    fn wl_insert(i: i32) { if vs_add(VS_PASS1, i) { wl.push(i); } }
    each_inst(fv) { i =>
        if db_always_live(i) {
            if is_int_ty(vals[i].ty) {
                if !vm_has(VM_ANA0, i) { vm_set(VM_ANA0, i, 0); wl_insert(i); }
            } else {
                for k in nops(i) {
                    let j = op(i, k);
                    if !is_inst(j) { continue; }
                    if is_int_ty(vals[j].ty) { vm_set(VM_ANA0, j, wmask(int_width(vals[j].ty)) as! i64); }
                    else { vs_add(VS_ANA0, j); }
                    wl_insert(j);
                }
            }
        }
    };
    while wl.len > 0 {
        let user = wl.pop();
        vs_del(VS_PASS1, user);
        var aout: u64 = 0;
        var dead_in = false;
        if is_int_ty(vals[user].ty) {
            aout = vm_get(VM_ANA0, user, 0) as! u64;
            dead_in = aout == 0 && !db_always_live(user);
        }
        var kc = KBCache { k1: kb_unknown(1), k2: kb_unknown(1), done: false };
        for k in nops(user) {
            let ov = op(user, k);
            let isi = is_inst(ov);
            if !isi && !is_arg(ov) { continue; }
            let t = vals[ov].ty;
            if is_int_ty(t) {
                let bw = int_width(t);
                var ab = wmask(bw);
                let u = vals[user].ops + k as i32;
                if dead_in {
                    ab = 0;
                } else {
                    ab = determine_live_operand_bits(user, ov, k, aout, ab, bw, kc);
                    if ab == 0 { vs_add(VS_ANA1, u); } else { vs_del(VS_ANA1, u); }
                }
                if isi {
                    if !vm_has(VM_ANA0, ov) {
                        vm_set(VM_ANA0, ov, ab as! i64);
                        wl_insert(ov);
                    } else {
                        let old = vm_get(VM_ANA0, ov, 0) as! u64;
                        let nw = ab | old;
                        if nw != old { vm_set(VM_ANA0, ov, nw as! i64); wl_insert(ov); }
                    }
                }
            } else if isi && vs_add(VS_ANA0, ov) {
                wl_insert(ov);
            }
        }
    }
}

fn db_demanded_bits(i: i32) -> u64 {
    db_analyze(inst_func(i));
    if vm_has(VM_ANA0, i) { return vm_get(VM_ANA0, i, 0) as! u64; }
    return wmask(int_width(vals[i].ty));
}
fn db_is_all_ones(i: i32) -> bool { db_demanded_bits(i) == wmask(int_width(vals[i].ty)) }

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
    if vs_has(VS_ANA1, vals[user].ops + k as i32) { return true; }
    if is_int_ty(vals[user].ty) && vm_has(VM_ANA0, user) && vm_get(VM_ANA0, user, 0) == 0 { return true; }
    return false;
}

// getDemandedBits(Use *)
fn db_demanded_bits_use(user: i32, k: i64) -> u64 {
    let v = op(user, k);
    let t = vals[v].ty;
    if !is_int_ty(t) {
        let sz = ty_size_in_bits_for_print(t);
        return wmask(sz);
    }
    let bw = int_width(t);
    if db_is_use_dead(user, k) { return 0; }
    db_analyze(inst_func(user));
    let aout = db_demanded_bits(user);
    var kc = KBCache { k1: kb_unknown(1), k2: kb_unknown(1), done: false };
    return determine_live_operand_bits(user, v, k, aout, wmask(bw), bw, kc);
}

// DL.getTypeSizeInBits of a scalar type, as far as the printer needs it (pointers, FP).
fn ty_size_in_bits_for_print(t0: i32) -> i64 {
    let t = ty_scalar(t0);
    let k = ty_kind(t);
    if k == TK_PTR { return 64; }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    fatal("print<demanded-bits>: operand type size not supported");
    return 0;
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
            errs_hex(vm_get(VM_ANA0, i, 0) as! u64);
            errs(" for ");
            errs_inst(i, fv);
            errs("\n");
            for k in nops(i) {
                errs("DemandedBits: 0x");
                errs_hex(db_demanded_bits_use(i, k));
                errs(" for ");
                errs_operand(op(i, k), fv, false);
                errs(" in ");
                errs_inst(i, fv);
                errs("\n");
            }
        }
    };
}
