// InstCombine visitors that are not ported yet (they fail loudly), and the parts of other files the
// ported visitors need: visitCallInst / visitCallBase for calls to ordinary functions
// (llvm/lib/Transforms/InstCombine/InstCombineCalls.cpp), simplifyNonNullOperand and mergeStoreIntoSuccessor
// (InstCombineLoadStoreAlloca.cpp).
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import pm;
import vt;
import tli;
import gen_tli;
import datalayout;
import local;
import instsimplify;
import ic;
import ic_builder;
import ic_common;
import autoupgrade;
import apint;
import ic_calls;
import memorybuiltins;
import ic_combining;
import ic_loadstorealloca;

var ic_experiment_lenient: bool = false;
fn ic_visit_other(i: i32) -> i32 {
    let o = iop(i);
    if ic_experiment_lenient { errs(str("LENIENT ", opcode_name(o), "\n")); return -1; }
    var nm: u8[>..] = [];
    nm.append("the InstCombine visitor for '");
    nm.append(opcode_name(o));
    nm.append("'");
    ic_not_ported(nm);
    return -1;
}

fn opcode_name(o: i64) -> const u8[:] {
    match o {
        OP_FNEG => "fneg", OP_FADD => "fadd", OP_FSUB => "fsub", OP_FMUL => "fmul", OP_FDIV => "fdiv", OP_FREM => "frem",
        OP_SHL => "shl", OP_LSHR => "lshr", OP_ASHR => "ashr", OP_AND => "and", OP_OR => "or", OP_XOR => "xor",
        OP_ALLOCA => "alloca", OP_LOAD => "load", OP_STORE => "store", OP_GEP => "getelementptr", OP_FENCE => "fence",
        OP_CMPXCHG => "cmpxchg", OP_ATOMICRMW => "atomicrmw", OP_TRUNC => "trunc", OP_ZEXT => "zext", OP_SEXT => "sext",
        OP_FPTOUI => "fptoui", OP_FPTOSI => "fptosi", OP_UITOFP => "uitofp", OP_SITOFP => "sitofp", OP_FPTRUNC => "fptrunc",
        OP_FPEXT => "fpext", OP_PTRTOINT => "ptrtoint", OP_PTRTOADDR => "ptrtoaddr", OP_INTTOPTR => "inttoptr",
        OP_BITCAST => "bitcast", OP_ADDRSPACECAST => "addrspacecast", OP_ICMP => "icmp", OP_FCMP => "fcmp", OP_PHI => "phi",
        OP_SELECT => "select", OP_VAARG => "va_arg", OP_EXTRACTELEMENT => "extractelement", OP_INSERTELEMENT => "insertelement",
        OP_SHUFFLEVECTOR => "shufflevector", OP_EXTRACTVALUE => "extractvalue", OP_INSERTVALUE => "insertvalue",
        OP_LANDINGPAD => "landingpad", OP_FREEZE => "freeze", OP_SWITCH => "switch", OP_INVOKE => "invoke",
        OP_RESUME => "resume", OP_INDIRECTBR => "indirectbr", OP_CALLBR => "callbr",
        _ => "other",
    }
}

// ---------------------------------------------------------------------------------------------
// Calls

// CallBase::setDoesNotThrow: add nounwind to the call site's function attributes
fn ic_call_set_does_not_throw(ci: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    var sets: i32[>..<] = [];
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    let fs = if n > 0 { alist_runs[alists[l].at] } else { 0 };
    sets.push(aset_add_enum(fs, AK_NoUnwind));
    for k in 1..n { sets.push(alist_runs[alists[l].at + k]); }
    insts[ii].attrs = alist_get(sets);
}
fn aset_add_enum(s: i32, kind: i64) -> i32 {
    var xs: i32[>..<] = [];
    for k in aset_n(s) { xs.push(aset_attr(s, k)); }
    xs.push(attr_enum(kind));
    return aset_get(xs);
}

// annotateAnyAllocSite(Call, TLI)
fn ic_annotate_any_alloc_site(ci: i32) -> bool {
    var changed = false;
    if ty_kind(vals[ci].ty) != TK_PTR { return false; }
    let ok, size = mb_get_alloc_size(ci, false);
    if ok && !ap_is_zero(size) {
        let bytes = ap_limited(size, 0xFFFFFFFFFFFFFFFF);
        if cb_has_ret_attr(ci, AK_NonNull) {
            changed = !cb_has_ret_attr(ci, AK_Dereferenceable);
            ic_call_add_ret_attr(ci, attr_int(AK_Dereferenceable, bytes));
        } else {
            changed = !cb_has_ret_attr(ci, AK_DereferenceableOrNull);
            ic_call_add_ret_attr(ci, attr_int(AK_DereferenceableOrNull, bytes));
        }
    }
    // getAllocAlignment(Call, TLI)
    var a: i32 = -1;
    let k = mb_alloc_data(ci, MB_ANY);
    if k >= 0 && TLI_ALLOC_DATA[k + 5] >= 0 { a = op(ci, TLI_ALLOC_DATA[k + 5] as i64); }
    else { a = call_arg_with_attr(ci, AK_AllocAlign); }
    if a < 0 { return changed; }
    if m_constant_int(a) < 0 { return changed; }
    let av = ci_ap(a);
    if !ap_ult_u64(av, (1 as u64) << 32) { return changed; }
    let al = ap_zext64(av);
    if al == 0 || (al & (al - 1)) != 0 { return changed; }
    // Call.getRetAlign(): the call site's, else the callee's
    let l = insts[inst_of(ci)].attrs;
    var ex = aset_int(alist_ret(l), AK_Alignment);
    if ex == 0 {
        let cf = called_function(ci);
        if cf >= 0 { ex = aset_int(alist_ret(globs[glob_of(cf)].attrs), AK_Alignment); }
    }
    if ex == 0 { ex = 1; }
    if al <= ex { return changed; }
    ic_call_add_ret_attr(ci, attr_int(AK_Alignment, al));
    return true;
}
// CallBase::addRetAttr(Attr): replaces an attribute of the same kind
fn ic_call_add_ret_attr(ci: i32, at: i32) {
    let l = insts[inst_of(ci)].attrs;
    var sets: i32[>..<] = [];
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    for j in 0..(if n > 2 { n } else { 2 }) {
        var st: i32 = 0;
        if j < n { st = alist_runs[alists[l].at + j]; }
        if j == 1 { st = aset_with(st, at); }
        sets.push(st);
    }
    insts[inst_of(ci)].attrs = alist_get(sets);
}

// ---------------------------------------------------------------------------------------------
// Loads and stores

// AttributeList::addParamAttribute(Ctx, ArgNo, Attr) on a call site
fn ic_call_add_param_attr(ci: i32, k: i64, a: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    let need = k + 3;
    for j in 0..(if n > need { n } else { need }) {
        var s: i32 = 0;
        if j < n { s = alist_runs[alists[l].at + j]; }
        if j == k + 2 {
            var xs: i32[>..<] = [];
            for q in aset_n(s) { xs.push(aset_attr(s, q)); }
            xs.push(a);
            s = aset_get(xs);
        }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}

// IRBuilder::CreateAssumption(Cond)
fn icb_assumption(c: i32) -> i32 {
    let call = ic_new_intrinsic(IID_assume, [], [c]);
    return icb_insert(call, "");
}

// Could LibCallSimplifier::optimizeCall recognize this callee? TLI->getLibFunc (tli_get_libfunc), or a TLI name
// whose prototype tli.goose can't check (the manually checked prototypes such as cabs are reported as not
// matching there).
fn ic_maybe_libcall(f: i32) -> bool {
    if tli_get_libfunc(f) >= 0 { return true; }
    if globs[glob_of(f)].intrinsic != 0 || vals[f].name < 0 { return false; }
    var nm = sbytes(vals[f].name);
    if nm.len > 0 && nm[0] == 1 { nm = nm[1..]; }
    if nm.len == 0 { return false; }
    let lf = tli_lookup_name(nm);
    if lf < 0 { return false; }
    return TLI_SIGS[lf][0] == '?' || starts_with(nm, "__size_returning_new");
}

// ---------------------------------------------------------------------------------------------
// atomicrmw (llvm/lib/Transforms/InstCombine/InstCombineAtomicRMW.cpp). Operation ids are the parser's rmw_op
// order: 0 xchg, 1 add, 2 sub, 3 and, 4 nand, 5 or, 6 xor, 7 max, 8 min, 9 umax, 10 umin, 11 fadd, 12 fsub,
// 13 fmax, 14 fmin, ...

fn rmw_scalar_cint(v: i32) -> bool { vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) }
fn rmw_scalar_cfp(v: i32) -> bool { vals[v].kind == VK_CFP && !ty_is_vector(vals[v].ty) }

// isIdempotentRMW
fn rmw_is_idempotent(i: i32, o: i64) -> bool {
    let v = op(i, 1);
    if rmw_scalar_cfp(v) {
        if o == 11 { return cfp_is_zero(v) && cfp_is_neg(v); }
        if o == 12 { return cfp_is_zero(v) && !cfp_is_neg(v); }
        return false;
    }
    if !rmw_scalar_cint(v) { return false; }
    let a = ci_ap(v);
    if o == 1 || o == 2 || o == 5 || o == 6 { return ap_is_zero(a); }
    if o == 3 { return ap_is_all_ones(a); }
    if o == 8 { return ap_is_max_signed(a); }
    if o == 7 { return ap_is_min_signed(a); }
    if o == 10 { return ap_is_all_ones(a); }
    if o == 9 { return ap_is_zero(a); }
    return false;
}
// isSaturating
fn rmw_is_saturating(i: i32, o: i64) -> bool {
    let v = op(i, 1);
    if rmw_scalar_cfp(v) {
        if o == 13 { return !cfp_is_neg(v) && cfp_is_inf(v); }
        if o == 14 { return cfp_is_neg(v) && cfp_is_inf(v); }
        if o == 11 || o == 12 { return cfp_is_nan(v); }
        return false;
    }
    if !rmw_scalar_cint(v) { return false; }
    let a = ci_ap(v);
    if o == 0 { return true; }
    if o == 5 { return ap_is_all_ones(a); }
    if o == 3 { return ap_is_zero(a); }
    if o == 8 { return ap_is_min_signed(a); }
    if o == 7 { return ap_is_max_signed(a); }
    if o == 10 { return ap_is_zero(a); }
    if o == 9 { return ap_is_all_ones(a); }
    return false;
}
fn visit_atomicrmw(i: i32) -> i32 {
    if inst_is_volatile(i) { return -1; }
    let ii = inst_of(i);
    let o = insts[ii].pred as i64;
    if rmw_is_saturating(i, o) && o != 0 { insts[ii].pred = 0; return i; }
    if o == 1 || o == 2 {
        let x = m_neg(op(i, 1));
        if x >= 0 {
            insts[ii].pred = if o == 1 { 2 } else { 1 };
            return ic_replace_operand(i, 1, x);
        }
    }
    if !rmw_is_idempotent(i, o) { return -1; }
    let t = vals[i].ty;
    if ty_is_int(t) && o != 5 {
        insts[ii].pred = 5;
        return ic_replace_operand(i, 1, c_int(t, 0));
    } else if ty_is_fp(t) && o != 11 {
        insts[ii].pred = 11;
        return ic_replace_operand(i, 1, c_fp_neg_zero(t));
    }
    return -1;
}
