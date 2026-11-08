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
    let iid = call_iid(ci);
    if iid == 0 { return visit_call_base(ci); }
    if iid == IID_assume { return visit_assume(ci); }
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

// annotateAnyAllocSite(Call, TLI): the alignment part (getAllocAlignment via allocalign); allocation
// functions known to the TLI and allocsize (getAllocSize) fail loudly.
fn ic_annotate_any_alloc_site(ci: i32) -> bool {
    if ty_kind(vals[ci].ty) != TK_PTR { return false; }
    if is_alloc_like_fn(ci) || call_has_fn_attr(ci, AK_AllocSize) { ic_not_ported("annotateAnyAllocSite"); }
    let a = call_arg_with_attr(ci, AK_AllocAlign);
    if a < 0 || m_constant_int(a) < 0 { return false; }
    let av = ci_ap(a);
    if !ap_ult_u64(av, (1 as u64) << 32) { return false; }
    let al = ap_zext64(av);
    if al == 0 || (al & (al - 1)) != 0 { return false; }
    // Call.getRetAlign(): the call site's, else the callee's
    let l = insts[inst_of(ci)].attrs;
    var ex = aset_int(alist_ret(l), AK_Alignment);
    if ex == 0 {
        let cf = called_function(ci);
        if cf >= 0 { ex = aset_int(alist_ret(globs[glob_of(cf)].attrs), AK_Alignment); }
    }
    if ex == 0 { ex = 1; }
    if al <= ex { return false; }
    var sets: i32[>..<] = [];
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    let need: i64 = 2;
    for j in 0..(if n > need { n } else { need }) {
        var st: i32 = 0;
        if j < n { st = alist_runs[alists[l].at + j]; }
        if j == 1 { st = aset_with(st, attr_int(AK_Alignment, al)); }
        sets.push(st);
    }
    insts[inst_of(ci)].attrs = alist_get(sets);
    return true;
}

// visitCallBase(Call) for a call to an ordinary function
fn visit_call_base(ci: i32) -> i32 {
    var changed = false;
    if ic_annotate_any_alloc_site(ci) { changed = true; }
    let nargs = cb_nargs(ci);
    var argnos: i64[>..<] = [];
    for k in nargs {
        let v = cb_arg(ci, k);
        if ty_kind(vals[v].ty) == TK_PTR {
            let deref = aset_int(alist_param(insts[inst_of(ci)].attrs, k), AK_Dereferenceable) > 0;
            if cb_param_has_attr(ci, k, AK_NonNull) || (deref && !null_pointer_is_defined(inst_func(ci), ptr_as(vals[v].ty))) {
                let res = ic_simplify_non_null_operand(v, deref, 0);
                if res >= 0 { ic_replace_operand(ci, k, res); changed = true; }
            } else {
                kb_cxt = ci;
                if is_known_non_zero(v, 0) { argnos.push(k); }
            }
        }
    }
    if argnos.len > 0 {
        for k in argnos { ic_call_add_param_attr(ci, k, attr_enum(AK_NonNull)); }
        changed = true;
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
        if ic_maybe_libcall(cf) { ic_not_ported("LibCallSimplifier (tryOptimizeCall)"); }
    }
    if vals[callee].kind == VK_INLINEASM && !call_has_fn_attr(ci, AK_NoUnwind) {
        // InlineAsm::canThrow: the 'unwind' flag
        if asms[vals[callee].sub].unwind == 0 { ic_call_set_does_not_throw(ci); changed = true; }
    }
    if !use_empty(ci) && returned_arg_operand(ci) >= 0 { ic_not_ported("calls with a 'returned' argument"); }
    // drop !callee_type from calls that are direct (CallBase::isIndirectCall)
    let indirect = !is_constant(callee) && vals[callee].kind != VK_INLINEASM;
    let kct = md_kind_id("callee_type");
    if inst_get_md(ci, kct) >= 0 && !indirect { inst_erase_md(ci, kct); changed = true; }
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

// visitCallInst for llvm.assume: the generic intrinsic steps (memory intrinsics, vector results, commutative
// operands, constrained FP: none apply), the `case Intrinsic::assume` of the switch, then visitCallBase.
fn visit_assume(ii: i32) -> i32 {
    if cb_nbundles(ii) > 0 { ic_not_ported("llvm.assume operand bundles"); }
    let c = cb_arg(ii, 0);
    if m_logical_and(c) {
        let a = lg_a; let b = lg_b;
        icb_assumption(a);
        icb_assumption(b);
        return ic_erase(ii);
    }
    let n = m_not(c);
    if n >= 0 && m_logical_or(n) {
        let a = lg_a; let b = lg_b;
        icb_assumption(icb_not(a, ""));
        icb_assumption(icb_not(b, ""));
        return ic_erase(ii);
    }
    if is_inst_op(c, OP_ICMP) && inst_pred(c) == 33 && m_zero(op(c, 1)) && ty_kind(vals[op(c, 0)].ty) == TK_PTR {
        ic_not_ported("CreateNonnullAssumption");
    }
    if n >= 0 && is_inst_op(n, OP_TRUNC) && m_ptrtoint_or_addr(op(n, 0)) >= 0 { ic_not_ported("CreateAlignmentAssumption"); }
    if is_inst_op(c, OP_ICMP) && inst_pred(c) == 32 && m_zero(op(c, 1)) && bo(op(c, 0), OP_AND) && m_constant_int(op(op(c, 0), 1)) >= 0 &&
       m_ptrtoint_or_addr(op(op(c, 0), 0)) >= 0 {
        ic_not_ported("CreateAlignmentAssumption");
    }
    if (vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty)) || is_undef_or_poison(c) {
        if vals[c].kind != VK_CINT || cint_lo(c) == 0 { ic_create_non_terminator_unreachable(ii); }
        return ic_erase(ii);
    }
    if ac_fn >= 0 && ac_fn == inst_func(ii) { ac_update_affected(ii); }
    return visit_call_base(ii);
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
