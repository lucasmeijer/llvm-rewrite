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
import local;
import instsimplify;
import ic;
import ic_builder;
import ic_common;

var ic_experiment_lenient: bool = false;
fn ic_visit_other(i: i32) -> i32 {
    let o = iop(i);
    if o == OP_CALL { return visit_call(i); }
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

// visitCallInst(CI)
fn visit_call(ci: i32) -> i32 {
    if !use_empty(ci) {
        let mark = is_ops.len;
        let n = nops(ci);
        for k in n { is_ops.push(op(ci, k)); }
        let nb = cb_bundle_ops(ci);
        let v = simplify_call(ci, is_ops[mark + n - 1], mark, n - 1 - nb, sq_at(ci));
        is_ops.resize(mark);
        if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    }
    if get_freed_operand(ci) >= 0 { ic_not_ported("visitFree"); }
    let fv = inst_func(ci);
    if func_has_fn_attr(fv, AK_NoUnwind) && !call_has_fn_attr(ci, AK_NoUnwind) {
        ic_call_set_does_not_throw(ci);
        return ci;
    }
    if call_iid(ci) == 0 { return visit_call_base(ci); }
    if ic_experiment_lenient { errs(str("LENIENT ", intr_name(call_iid(ci) as i64), "\n")); return -1; }
    var nm: u8[>..] = [];
    nm.append("the InstCombine visitor for the intrinsic ");
    nm.append(intr_name(call_iid(ci) as i64));
    ic_not_ported(nm);
    return -1;
}

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

// visitCallBase(Call) for a call to an ordinary function
fn visit_call_base(ci: i32) -> i32 {
    var changed = false;
    if ty_kind(vals[ci].ty) == TK_PTR && is_alloc_like_fn(ci) { ic_not_ported("annotateAnyAllocSite"); }
    let nargs = cb_nargs(ci);
    for k in nargs {
        let v = cb_arg(ci, k);
        if ty_kind(vals[v].ty) == TK_PTR {
            ic_not_ported("visitCallBase pointer arguments (nonnull inference)");
        }
    }
    let callee = cb_callee(ci);
    let cf = called_function(ci);
    if cf < 0 && is_func(callee) { ic_not_ported("transformConstExprCastCall"); }
    if cf < 0 && !is_func(callee) {
        if is_constant(callee) { ic_not_ported("calls through constant callees"); }
    }
    if cf >= 0 {
        if call_has_fn_attr(ci, AK_Convergent) { ic_not_ported("convergent calls"); }
        if insts[inst_of(ci)].cc != globs[glob_of(cf)].cc { ic_not_ported("calls with a mismatched calling convention"); }
        if tli_get_libfunc(cf) >= 0 { ic_not_ported("LibCallSimplifier (tryOptimizeCall)"); }
    }
    if !use_empty(ci) && returned_arg_operand(ci) >= 0 { ic_not_ported("calls with a 'returned' argument"); }
    if cb_nbundles(ci) > 0 { ic_not_ported("calls with operand bundles in visitCallBase"); }
    return if changed { ci } else { -1 };
}

// ---------------------------------------------------------------------------------------------
// Loads and stores

// simplifyNonNullOperand(V, HasDereferenceable, Depth)
fn ic_simplify_non_null_operand(v: i32, deref: bool, depth: i64) -> i32 {
    if is_select_inst(v) {
        if vals[op(v, 1)].kind == VK_CNULL { return op(v, 2); }
        if vals[op(v, 2)].kind == VK_CNULL { return op(v, 1); }
    }
    if !one_use(v) { return -1; }
    if depth == 3 { return -1; }
    if is_inst_op(v, OP_GEP) || is_phi_inst(v) { ic_not_ported("simplifyNonNullOperand through GEPs/PHIs"); }
    return -1;
}

// mergeStoreIntoSuccessor(SI)
fn ic_merge_store_into_successor(si: i32) -> bool {
    ic_not_ported("mergeStoreIntoSuccessor");
    return false;
}
