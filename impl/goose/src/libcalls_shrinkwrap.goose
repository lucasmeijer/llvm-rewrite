// LibCallsShrinkWrap: port of llvm/lib/Transforms/Utils/LibCallsShrinkWrap.cpp (LibCallsShrinkWrapPass).
// In a strictfp function the conditions are constrained fcmp intrinsics: not ported (fails loudly).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import dtu;
import tli;
import constfold;
import cfgutil;
import simplifycfg;
import profdata;
import aic_trunc;
import gen_attrs;
import gen_iids;
import parser;
import inline_function;
import binary;
import fpu;

fn lsw_const(arg: i32, val: f64) -> i32 {
    let v = c_fp_from_f64(T_FLOAT, val);
    let t = vals[arg].ty;
    if types[t].kind as i64 == TK_FLOAT { return v; }
    return cf_cast(OP_FPEXT, v, t);
}

// createCond(BBBuilder, Arg, Cmp, Val) with the builder at the call
fn lsw_cond(ci: i32, arg: i32, p: i64, val: f64) -> i32 {
    let v = lsw_const(arg, val);
    ab_set(ci);
    if func_has_fn_attr(inst_func(ci), AK_StrictFP) {
        // IRBuilder::CreateConstrainedFPCmp (setIsFPConstrained): fpexcept.strict, the call gets strictfp
        let pn: const u8[:] = match p { 1 => "oeq", 2 => "ogt", 3 => "oge", 4 => "olt", _ => "ole" };
        let pv = get_md_as_value(md_string(pn));
        let ev = get_md_as_value(md_string("fpexcept.strict"));
        let c = ab_intrinsic(IID_experimental_constrained_fcmp, [vals[arg].ty as i32], [arg, v, pv, ev], -1, "");
        cb_add_fn_attr_enum(c, AK_StrictFP);
        return c;
    }
    if is_constant(arg) {
        let r = cf_compare(p, arg, v);
        if r >= 0 { return r; }
    }
    let c = create_inst(OP_FCMP, T_I1, [arg, v]);
    insts[inst_of(c)].pred = p as u8;
    return ab_insert(c, "");
}

// createOrCond(CI, Arg, Cmp, Val, Arg2, Cmp2, Val2)
fn lsw_or_cond(ci: i32, a1: i32, p1: i64, v1: f64, a2: i32, p2: i64, v2: f64) -> i32 {
    let c2 = lsw_cond(ci, a2, p2, v2);
    let c1 = lsw_cond(ci, a1, p1, v1);
    ab_set(ci);
    // IRBuilder::CreateOr: LHS | -1 -> -1, LHS | 0 -> LHS
    if is_cint(c2) { if cint_lo(c2) == 1 { return c2; } return c1; }
    return ab_binop(OP_OR, c1, c2, 0, "");
}

let LSW_OEQ = 1;
let LSW_OGT = 2;
let LSW_OGE = 3;
let LSW_OLT = 4;
let LSW_OLE = 5;

fn lsw_shrink_wrap(ci: i32, cond: i32) {
    let ws: u64[2] = [1, 1048575];
    let bw = pd_create(ws, false);
    let nt = split_block_and_insert_if_then(cond, ci, false, bw);
    let call_bb = inst_parent(nt);
    set_name(call_bb, "cdce.call");
    let succ = block_succ(call_bb, 0);
    set_name(succ, "cdce.end");
    var pos = first_non_phi(call_bb);
    if pos >= 0 && inst_is_eh_pad(pos) { pos = inst_next(pos); }
    inst_move_impl(ci, call_bb, pos, true, false);
}

fn lsw_perform(ci: i32) -> bool {
    let f = called_function(ci);
    let nm = tli_name(tli_get_libfunc(f) as i64);
    let x = cb_arg(ci, 0);
    var cond: i32 = -1;
    // performCallDomainErrorOnly
    if nm == "acos" || nm == "acosf" || nm == "acosl" || nm == "asin" || nm == "asinf" || nm == "asinl" {
        cond = lsw_or_cond(ci, x, LSW_OLT, -1.0, x, LSW_OGT, 1.0);
    } else if nm == "cos" || nm == "cosf" || nm == "cosl" || nm == "sin" || nm == "sinf" || nm == "sinl" {
        cond = lsw_or_cond(ci, x, LSW_OEQ, binary::f64_of_bits(0x7FF0000000000000), x, LSW_OEQ, binary::f64_of_bits(0xFFF0000000000000));
    } else if nm == "acosh" || nm == "acoshf" || nm == "acoshl" {
        cond = lsw_cond(ci, x, LSW_OLT, 1.0);
    } else if nm == "sqrt" || nm == "sqrtf" || nm == "sqrtl" {
        cond = lsw_cond(ci, x, LSW_OLT, 0.0);
    }
    if cond >= 0 { lsw_shrink_wrap(ci, cond); return true; }
    // performCallRangeErrorOnly
    var lo: f64 = 0.0;
    var hi: f64 = 0.0;
    var two = true;
    if nm == "cosh" || nm == "sinh" { lo = -710.0; hi = 710.0; }
    else if nm == "coshf" || nm == "sinhf" { lo = -89.0; hi = 89.0; }
    else if nm == "coshl" || nm == "sinhl" { lo = -11357.0; hi = 11357.0; }
    else if nm == "exp" { lo = -745.0; hi = 709.0; }
    else if nm == "expf" { lo = -103.0; hi = 88.0; }
    else if nm == "expl" { lo = -11399.0; hi = 11356.0; }
    else if nm == "exp10" { lo = -323.0; hi = 308.0; }
    else if nm == "exp10f" { lo = -45.0; hi = 38.0; }
    else if nm == "exp10l" { lo = -4950.0; hi = 4932.0; }
    else if nm == "exp2" { lo = -1074.0; hi = 1023.0; }
    else if nm == "exp2f" { lo = -149.0; hi = 127.0; }
    else if nm == "exp2l" { lo = -16445.0; hi = 11383.0; }
    else if nm == "expm1" { two = false; hi = 709.0; }
    else if nm == "expm1f" { two = false; hi = 88.0; }
    else if nm == "expm1l" { two = false; hi = 11356.0; }
    else { two = false; hi = -1.0; }
    if hi != -1.0 {
        if two { cond = lsw_or_cond(ci, x, LSW_OGT, hi, x, LSW_OLT, lo); }
        else { cond = lsw_cond(ci, x, LSW_OGT, hi); }
        lsw_shrink_wrap(ci, cond);
        return true;
    }
    // performCallErrors
    if nm == "atanh" || nm == "atanhf" || nm == "atanhl" {
        cond = lsw_or_cond(ci, x, LSW_OLE, -1.0, x, LSW_OGE, 1.0);
    } else if nm == "log" || nm == "logf" || nm == "logl" || nm == "log10" || nm == "log10f" || nm == "log10l" ||
              nm == "log2" || nm == "log2f" || nm == "log2l" || nm == "logb" || nm == "logbf" || nm == "logbl" {
        cond = lsw_cond(ci, x, LSW_OLE, 0.0);
    } else if nm == "log1p" || nm == "log1pf" || nm == "log1pl" {
        cond = lsw_cond(ci, x, LSW_OLE, -1.0);
    } else if nm == "pow" {
        // generateCondForPow
        let base = x;
        let ex = cb_arg(ci, 1);
        if vals[base].kind == VK_CFP {
            let k = types[vals[base].ty].kind as i64;
            var bits = cint_lo(base);
            if k != TK_DOUBLE { let l2, h2 = fp_convert(k, TK_DOUBLE, cint_lo(base), cint_hi(base)); bits = l2; }
            let d = binary::f64_of_bits(bits);
            if d < 1.0 || d > 255.0 { return false; }
            cond = lsw_cond(ci, ex, LSW_OGT, 127.0);
        } else if is_inst(base) && (iop(base) == OP_UITOFP || iop(base) == OP_SITOFP) {
            let bw2 = ty_bits(vals[op(base, 0)].ty);
            var up: f64 = 0.0;
            if bw2 == 8 { up = 128.0; } else if bw2 == 16 { up = 64.0; } else if bw2 == 32 { up = 32.0; } else { return false; }
            cond = lsw_or_cond(ci, base, LSW_OLE, 0.0, ex, LSW_OGT, up);
        } else { return false; }
    } else { return false; }
    lsw_shrink_wrap(ci, cond);
    return true;
}

fn libcalls_shrinkwrap_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    if func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) { return PA_ALL; }
    let use_dt = dt_valid(fv, DT_DOM);
    dtu_begin(fv, true, false, true);
    cu_dtu = use_dt;
    var wl: i32[>..<] = [];
    each_inst(fv) { ci =>
        if iop(ci) == OP_CALL && !call_is_nobuiltin(ci) && vals[ci].first_use < 0 {
            let f = called_function(ci);
            if f >= 0 {
                let lf = tli_get_libfunc(f);
                if lf >= 0 && tli_has(lf) && cb_nargs(ci) > 0 {
                    let k = types[vals[cb_arg(ci, 0)].ty].kind as i64;
                    if k == TK_FLOAT || k == TK_DOUBLE || k == TK_X86_FP80 { wl.push(ci); }
                }
            }
        }
    };
    var changed = false;
    for ci in wl { if lsw_perform(ci) { changed = true; } }
    cu_dtu = false;
    dtu_end();
    if !changed { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}
