// Inlining a call site: port of llvm/lib/Transforms/Utils/InlineFunction.cpp (CanInlineCallSite,
// InlineFunctionImpl and its helpers: HandleByValArgument(Init), AddAlignmentAssumptions,
// ScopedAliasMetadataDeepCloner, AddAliasScopeMetadata, AddReturnAttributes, AddParamAndFnBasicAttributes,
// PropagateCallSiteMetadata, propagateAllocTokenMetadata, PropagateInlinedFromMetadata, fixupLineNumbers /
// inlineDebugLoc (DebugLoc::appendInlinedAt, updateLoopMetadataDebugLocations), the landing-pad EH handling
// (LandingPadInliningInfo, HandleInlinedLandingPad, HandleCallsInBlockInlinedThroughInvoke), static alloca
// hoisting, lifetime markers, stacksave/stackrestore, tail-call kinds, musttail varargs forwarding, the inline
// history, updateCallerBFI / updateCallProfile / updateProfileCallee), CloneAndPruneFunctionInto with the
// PruningFunctionCloner (llvm/lib/Transforms/Utils/CloneFunction.cpp), changeToInvokeAndSplitBasicBlock (Local.cpp),
// AttributeFuncs::mergeAttributesForInlining (the MergeRules of Attributes.td) and MDNode::concatenate;
// funclet EH (getUnwindDestToken, HandleInlinedEHPad, PropagateOperandBundles), convergence control tokens,
// ObjC ARC attached calls (inlineRetainOrClaimRVCalls with objcarc::GetRCIdentityRoot), strictfp callers
// (PruningFunctionCloner::cloneInstruction with getConstrainedIntrinsicID, llvm/lib/IR/FPEnv.cpp), memprof
// metadata (propagateMemProfMetadata with CallStackTrie, llvm/lib/Analysis/MemoryProfileInfo.cpp).
// Not ported (fail loudly): assignment tracking, contextual profiles, -memprof-report-hinted-sizes output.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import analyses;
import flags;
import apint;
import pm;
import vt;
import poison;
import memloc;
import aa;
import aautil;
import capture;
import domtree;
import dinfo;
import dbgutil;
import local;
import cfgutil;
import autoupgrade;
import knowledge;
import knownbits;
import constrange;
import scev;
import wvh;
import ic;
import instsimplify;
import cfold;
import value_mapper;
import clone_function;
import mem2reg;
import ic_loadstorealloca;
import profdata;
import bfi;
import psi;
import ipoutil;
import inline_cost;
import function_attrs;
import loopsimplify;

fn if_not_ported(what: const u8[:]) { fatal(str("InlineFunction: ", what, " is not ported yet")); }

// The result of the last InlineFunction: the failure reason (-1 = success) and IFI.InlinedCallSites
var if_fail_reason: i32 = -1;
var ifi_inlined_call_sites: i32[>..<];
var ifi_static_allocas: i32[>..<];
var ifi_convergence_token: i32 = -1;     // IFI.ConvergenceControlToken
// getConvergenceEntry: the llvm.experimental.convergence.entry call in a block
fn if_convergence_entry(bb: i32) -> i32 {
    var i = first_non_phi(bb);
    while i >= 0 { if inst_iid(i) == IID_experimental_convergence_entry { return i; } i = inst_next(i); }
    return -1;
}
var ifi_callsite_ehpad: i32 = -1;        // IFI.CallSiteEHPad (the call site's "funclet" bundle ehp)

fn mdk(name: const u8[:]) -> i32 { md_kind_id(name) }

// ---------------------------------------------------------------------------------------------
// CanInlineCallSite

fn can_inline_call_site(cb: i32) -> bool {
    if_fail_reason = -1;
    ifi_callsite_ehpad = -1;
    ifi_convergence_token = -1;
    if iop(cb) == OP_CALLBR { if_fail_reason = intern("We don't inline callbr yet."); return false; }
    let callee = called_function(cb);
    if callee < 0 || func_is_decl(callee) { if_fail_reason = intern("external or indirect"); return false; }
    let ih = inst_get_md(cb, mdk("inline_history"));
    if ih >= 0 {
        for k in mds[ih].nops as i64 {
            let o = md_op(ih, k);
            if o >= 0 && mds[o].kind == MK_VALUE && mds[o].extra == callee { if_fail_reason = intern("inline history"); return false; }
        }
    }
    let nb = cb_nbundles(cb);
    for k in nb {
        let t = sbytes(cb_bundle_tag(cb, k));
        if t == "deopt" || t == "funclet" || t == "clang.arc.attachedcall" || t == "kcfi" { continue; }
        if t == "convergencectrl" { ifi_convergence_token = op(cb, cb_bundle_begin(cb, k)); continue; }
        if_fail_reason = intern("unsupported operand bundle");
        return false;
    }
    // A convergent call without a token into a callee using controlled convergence (getConvergenceEntry)
    if call_has_fn_attr(cb, AK_Convergent) && ifi_convergence_token < 0 && if_convergence_entry(func_entry(callee)) >= 0 {
        if_fail_reason = intern("convergent call needs convergencectrl operand");
        return false;
    }
    let caller = inst_func(cb);
    let cg = globs[glob_of(callee)].gc;
    if cg >= 0 {
        let rg = globs[glob_of(caller)].gc;
        if rg >= 0 && cg != rg { if_fail_reason = intern("incompatible GC"); return false; }
    }
    let cp = if globs[glob_of(callee)].has_personality != 0 { fa_strip_pointer_casts(op(callee, 0)) } else { -1 };
    let rp = if globs[glob_of(caller)].has_personality != 0 { fa_strip_pointer_casts(op(caller, 0)) } else { -1 };
    if cp >= 0 && rp >= 0 && cp != rp { if_fail_reason = intern("incompatible personality"); return false; }
    // We need to figure out which funclet the callsite was in so that we may properly nest the callee.
    if rp >= 0 && if_is_scoped_eh(rp) {
        for k in nb { if sbytes(cb_bundle_tag(cb, k)) == "funclet" { ifi_callsite_ehpad = op(cb, cb_bundle_begin(cb, k)); break; } }
        if ifi_callsite_ehpad >= 0 {
            let pn = sbytes(vals[rp].name);
            if pn == "__CxxFrameHandler3" {
                // The MSVC personality cannot tolerate catches getting inlined into cleanup funclets.
                if iop(ifi_callsite_ehpad) == OP_CLEANUPPAD {
                    var b = func_first_block(callee);
                    while b >= 0 {
                        let f = first_non_phi(b);
                        if f >= 0 && iop(f) == OP_CATCHSWITCH { if_fail_reason = intern("catch in cleanup funclet"); return false; }
                        b = block_next(b);
                    }
                }
            } else if pn == "_except_handler3" || pn == "_except_handler4" || pn == "__C_specific_handler" {
                // SEH is even less tolerant, there may not be any sort of exceptional funclet in the callee.
                var b = func_first_block(callee);
                while b >= 0 {
                    let f = first_non_phi(b);
                    if f >= 0 && inst_is_eh_pad(f) { if_fail_reason = intern("SEH in cleanup funclet"); return false; }
                    b = block_next(b);
                }
            }
        }
    }
    return true;
}
// isScopedEHPersonality(classifyEHPersonality(P))
fn if_is_scoped_eh(p: i32) -> bool {
    if !is_func(p) || vals[p].name < 0 { return false; }
    let n = sbytes(vals[p].name);
    return n == "__CxxFrameHandler3" || n == "__C_specific_handler" || n == "_except_handler3" || n == "_except_handler4" ||
        n == "ProcessCLRException" || n == "__gxx_wasm_personality_v0";
}

// ---------------------------------------------------------------------------------------------
// Funclet EH: getUnwindDestToken (a memo map from pads to their unwind destination token; -1 = nullptr)

var uw_memo_k: i32[>..<];
var uw_memo_v: i32[>..<];
fn uw_memo_reset() { uw_memo_k.resize(0); uw_memo_v.resize(0); }
fn uw_memo_find(p: i32) -> i64 { for k in uw_memo_k.len { if uw_memo_k[k] == p { return k; } } return -1; }
fn uw_memo_has(p: i32) -> bool { uw_memo_find(p) >= 0 }
fn uw_memo_get(p: i32) -> i32 { let k = uw_memo_find(p); if k < 0 { -1 } else { uw_memo_v[k] } }
fn uw_memo_set(p: i32, v: i32) {
    let k = uw_memo_find(p);
    if k >= 0 { uw_memo_v[k] = v; return; }
    uw_memo_k.push(p);
    uw_memo_v.push(v);
}
fn token_none() -> i32 { c_simple(VK_CTOKENNONE, T_TOKEN) }
fn is_token_none(v: i32) -> bool { v >= 0 && vals[v].kind == VK_CTOKENNONE }
// FuncletPadInst::getParentPad (the last operand) / CatchSwitchInst::getParentPad (operand 0)
fn eh_parent_pad(p: i32) -> i32 { if iop(p) == OP_CATCHSWITCH { op(p, 0) } else { op(p, nops(p) - 1) } }
fn eh_set_parent_pad(p: i32, v: i32) { if iop(p) == OP_CATCHSWITCH { set_op(p, 0, v); } else { set_op(p, nops(p) - 1, v); } }
fn catchswitch_first_handler(cs: i32) -> i64 { if catchswitch_unwinds_to_caller(cs) { 1 } else { 2 } }
fn catchswitch_unwind_dest(cs: i32) -> i32 { if catchswitch_unwinds_to_caller(cs) { -1 } else { op(cs, 1) } }
fn is_child_pad(u: i32) -> bool { is_inst(u) && (iop(u) == OP_CLEANUPPAD || iop(u) == OP_CATCHSWITCH) }

// getUnwindDestTokenHelper: the descendant-ward part of the search
fn uw_helper(ehpad: i32) -> i32 {
    var wl: i32[>..<] = [ehpad];
    while wl.len > 0 {
        let cur = wl.pop();
        var tok: i32 = -1;
        if iop(cur) == OP_CATCHSWITCH {
            if !catchswitch_unwinds_to_caller(cur) {
                tok = first_non_phi(catchswitch_unwind_dest(cur));
            } else {
                var h = catchswitch_first_handler(cur);
                while h < nops(cur) && tok < 0 {
                    let cp = first_non_phi(op(cur, h));
                    var u = first_use(cp);
                    while u >= 0 {
                        let child = use_user(u);
                        u = use_next(u);
                        if !is_child_pad(child) { continue; }
                        if !uw_memo_has(child) { wl.push(child); continue; }
                        let ct = uw_memo_get(child);
                        if ct < 0 { continue; }
                        if is_token_none(ct) { tok = ct; break; }
                    }
                    h++;
                }
            }
        } else {
            var u = first_use(cur);
            while u >= 0 {
                let us = use_user(u);
                u = use_next(u);
                if is_inst(us) && iop(us) == OP_CLEANUPRET {
                    if !cleanupret_unwinds_to_caller(us) { tok = first_non_phi(op(us, 1)); } else { tok = token_none(); }
                    break;
                }
                var ct: i32 = -1;
                if is_inst(us) && iop(us) == OP_INVOKE {
                    ct = first_non_phi(invoke_unwind_dest(us));
                } else if is_child_pad(us) {
                    if !uw_memo_has(us) { wl.push(us); continue; }
                    ct = uw_memo_get(us);
                    if ct < 0 { continue; }
                } else { continue; }
                if is_inst(ct) && eh_parent_pad(ct) == cur { continue; }
                tok = ct;
                break;
            }
        }
        if tok < 0 { continue; }
        let uparent = if is_inst(tok) { eh_parent_pad(tok) } else { -1 };
        var exited_orig = false;
        var ex = cur;
        while ex >= 0 && ex != uparent {
            if iop(ex) != OP_CATCHPAD {
                uw_memo_set(ex, tok);
                if ex == ehpad { exited_orig = true; }
            }
            let pp = eh_parent_pad(ex);
            ex = if is_inst(pp) { pp } else { -1 };
        }
        if exited_orig { return tok; }
    }
    return -1;
}

// getUnwindDestToken: the ehp (or ConstantTokenNone for "unwinds to caller") EHPad unwinds to, -1 if unknown
fn get_unwind_dest_token(pad0: i32) -> i32 {
    var ehp = pad0;
    if iop(ehp) == OP_CATCHPAD { ehp = eh_parent_pad(ehp); }
    let mk = uw_memo_find(ehp);
    if mk >= 0 { return uw_memo_v[mk]; }
    var tok = uw_helper(ehp);
    if tok >= 0 { return tok; }
    uw_memo_set(ehp, -1);
    var last_useless = ehp;
    var anc = eh_parent_pad(ehp);
    while is_inst(anc) {
        if iop(anc) == OP_CATCHPAD { anc = eh_parent_pad(anc); continue; }
        let am = uw_memo_find(anc);
        if am < 0 { tok = uw_helper(anc); } else { tok = uw_memo_v[am]; }
        if tok >= 0 { break; }
        last_useless = anc;
        uw_memo_set(last_useless, -1);
        anc = eh_parent_pad(anc);
    }
    var wl: i32[>..<] = [last_useless];
    while wl.len > 0 {
        let up = wl.pop();
        let m = uw_memo_find(up);
        if m >= 0 && uw_memo_v[m] >= 0 { continue; }
        uw_memo_set(up, tok);
        if iop(up) == OP_CATCHSWITCH {
            var h = catchswitch_first_handler(up);
            while h < nops(up) {
                let cp = first_non_phi(op(up, h));
                var u = first_use(cp);
                while u >= 0 { let us = use_user(u); u = use_next(u); if is_child_pad(us) { wl.push(us); } }
                h++;
            }
        } else {
            var u = first_use(up);
            while u >= 0 { let us = use_user(u); u = use_next(u); if is_child_pad(us) { wl.push(us); } }
        }
    }
    return tok;
}

// ---------------------------------------------------------------------------------------------
// ClonedCodeInfo

var cci_contains_calls: bool = false;
var cci_contains_memprof: bool = false;
var cci_contains_dynamic_allocas: bool = false;
var cci_orig_vmap: i32 = -1;             // OrigVMap (a plain map)
var cci_bundle_sites: i32[>..<];         // OperandBundleCallSites (handles)
var cci_orig_indirect: i32[>..<];        // OriginallyIndirectCalls (SmallSetVector)
fn cci_is_simplified(from: i32, to: i32) -> bool { vmm_get(cci_orig_vmap, from) != to }
fn cci_indirect_has(v: i32) -> bool { for x in cci_orig_indirect { if x == v { return true; } } return false; }
fn cci_indirect_remove(v: i32) -> bool {
    var j: i64 = 0;
    while j < cci_orig_indirect.len {
        if cci_orig_indirect[j] == v {
            for k in j + 1..cci_orig_indirect.len { cci_orig_indirect[k - 1] = cci_orig_indirect[k]; }
            cci_orig_indirect.pop();
            return true;
        }
        j++;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// CloneAndPruneFunctionInto (PruningFunctionCloner)

fn if_name_with(dst: i32, src: i32, suffix: const u8[:]) {
    if vals[src].name < 0 { return; }
    var nm: u8[>..] = [];
    nm.append(val_name(src));
    nm.append(suffix);
    set_name(dst, nm);
}

// PruningFunctionCloner::cloneInstruction: into a strictfp function, FP operations and their intrinsics become
// constrained intrinsic calls with the default rounding mode and exception behavior (getConstrainedIntrinsicID,
// llvm/lib/IR/FPEnv.cpp and llvm/IR/ConstrainedOps.def)
var pfc_host_strictfp: bool = false;
// the constrained intrinsic for an instruction (0 = none), whether it has a rounding mode operand, and its
// overload kind (0: [ret], 1: [ret, arg0], 2: [ret, arg1], 3: [arg0])
fn constrained_iid(i: i32) -> i64, bool, i64 {
    let o = iop(i);
    if o == OP_FCMP { return IID_experimental_constrained_fcmp, false, 3; }
    if o == OP_FADD { return IID_experimental_constrained_fadd, true, 0; }
    if o == OP_FSUB { return IID_experimental_constrained_fsub, true, 0; }
    if o == OP_FMUL { return IID_experimental_constrained_fmul, true, 0; }
    if o == OP_FDIV { return IID_experimental_constrained_fdiv, true, 0; }
    if o == OP_FREM { return IID_experimental_constrained_frem, true, 0; }
    if o == OP_FPEXT { return IID_experimental_constrained_fpext, false, 1; }
    if o == OP_SITOFP { return IID_experimental_constrained_sitofp, true, 1; }
    if o == OP_UITOFP { return IID_experimental_constrained_uitofp, true, 1; }
    if o == OP_FPTOSI { return IID_experimental_constrained_fptosi, false, 1; }
    if o == OP_FPTOUI { return IID_experimental_constrained_fptoui, false, 1; }
    if o == OP_FPTRUNC { return IID_experimental_constrained_fptrunc, true, 1; }
    if o != OP_CALL { return 0, false, 0; }
    let id = inst_iid(i);
    if id == IID_acos { return IID_experimental_constrained_acos, true, 0; }
    if id == IID_asin { return IID_experimental_constrained_asin, true, 0; }
    if id == IID_atan { return IID_experimental_constrained_atan, true, 0; }
    if id == IID_atan2 { return IID_experimental_constrained_atan2, true, 0; }
    if id == IID_ceil { return IID_experimental_constrained_ceil, false, 0; }
    if id == IID_cos { return IID_experimental_constrained_cos, true, 0; }
    if id == IID_cosh { return IID_experimental_constrained_cosh, true, 0; }
    if id == IID_exp { return IID_experimental_constrained_exp, true, 0; }
    if id == IID_exp2 { return IID_experimental_constrained_exp2, true, 0; }
    if id == IID_floor { return IID_experimental_constrained_floor, false, 0; }
    if id == IID_fma { return IID_experimental_constrained_fma, true, 0; }
    if id == IID_log { return IID_experimental_constrained_log, true, 0; }
    if id == IID_log10 { return IID_experimental_constrained_log10, true, 0; }
    if id == IID_log2 { return IID_experimental_constrained_log2, true, 0; }
    if id == IID_lrint { return IID_experimental_constrained_lrint, true, 1; }
    if id == IID_llrint { return IID_experimental_constrained_llrint, true, 1; }
    if id == IID_lround { return IID_experimental_constrained_lround, false, 1; }
    if id == IID_llround { return IID_experimental_constrained_llround, false, 1; }
    if id == IID_maxnum { return IID_experimental_constrained_maxnum, false, 0; }
    if id == IID_minnum { return IID_experimental_constrained_minnum, false, 0; }
    if id == IID_maximum { return IID_experimental_constrained_maximum, false, 0; }
    if id == IID_minimum { return IID_experimental_constrained_minimum, false, 0; }
    if id == IID_nearbyint { return IID_experimental_constrained_nearbyint, true, 0; }
    if id == IID_pow { return IID_experimental_constrained_pow, true, 0; }
    if id == IID_powi { return IID_experimental_constrained_powi, true, 0; }
    if id == IID_ldexp { return IID_experimental_constrained_ldexp, true, 2; }
    if id == IID_rint { return IID_experimental_constrained_rint, true, 0; }
    if id == IID_round { return IID_experimental_constrained_round, false, 0; }
    if id == IID_roundeven { return IID_experimental_constrained_roundeven, false, 0; }
    if id == IID_sin { return IID_experimental_constrained_sin, true, 0; }
    if id == IID_sinh { return IID_experimental_constrained_sinh, true, 0; }
    if id == IID_sqrt { return IID_experimental_constrained_sqrt, true, 0; }
    if id == IID_tan { return IID_experimental_constrained_tan, true, 0; }
    if id == IID_tanh { return IID_experimental_constrained_tanh, true, 0; }
    if id == IID_trunc { return IID_experimental_constrained_trunc, false, 0; }
    if id == IID_fmuladd { return IID_experimental_constrained_fmuladd, true, 0; }
    return 0, false, 0;
}
fn pfc_clone_instruction(ii: i32, nf: i32) -> i32 {
    if !pfc_host_strictfp { return inst_clone(ii); }
    let cid, rounding, ovk = constrained_iid(ii);
    if cid == 0 { return inst_clone(ii); }
    var args: i32[>..<] = [];
    var n = nops(ii);
    if iop(ii) == OP_CALL { n = nops(ii) - 1; }   // every operand but the callee
    for k in n { args.push(op(ii, k)); }
    if iop(ii) == OP_FCMP {
        let names: const u8[:][] = ["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
        args.push(get_md_as_value(md_string(names[insts[inst_of(ii)].pred as i64])));
    }
    if rounding { args.push(get_md_as_value(md_string("round.tonearest"))); }
    args.push(get_md_as_value(md_string("fpexcept.ignore")));
    var ov: i32[>..<] = [];
    if ovk == 0 { ov.push(vals[ii].ty); }
    else if ovk == 1 { ov.push(vals[ii].ty); ov.push(vals[args[0]].ty); }
    else if ovk == 2 { ov.push(vals[ii].ty); ov.push(vals[args[1]].ty); }
    else { ov.push(vals[args[0]].ty); }
    let f = au_get_declaration(cid, ov);
    var opsv: i32[>..<] = [];
    for a in args { opsv.push(a); }
    opsv.push(f);
    let ci = create_inst(OP_CALL, vals[ii].ty, opsv);
    insts[inst_of(ci)].ty2 = globs[glob_of(f)].vty;
    return ci;
}

// PruningFunctionCloner::CloneBlock; the worklist is to_clone
fn pfc_clone_block(bb: i32, start: i32, nf: i32, m: i32, suffix: const u8[:], to_clone: i32[>..<]&) {
    if vmm_get(m, bb) >= 0 { return; }
    let nbb = create_block_after(nf, func_last_block(nf), "");
    if_name_with(nbb, bb, suffix);
    vmm_set(m, bb, nbb);
    if ic_block_address_taken(bb) { if_not_ported("inlining a block whose address is taken"); }
    var has_calls = false;
    var has_dyn = false;
    var has_static = false;
    var cursor = start;      // DbgCursor
    fn clone_dbg_to_here(ni: i32, ii: i32) {
        var recs: i32[>..<] = [];
        while cursor != ii { inst_clone_debug_info_from(ni, cursor, -1, false, recs); cursor = inst_next(cursor); }
        inst_clone_debug_info_from(ni, ii, -1, false, recs);
        cursor = inst_next(ii);
    }
    let old_ti = block_terminator(bb);
    var ii = start;
    while ii != old_ti {
        let cur = ii;
        ii = inst_next(ii);
        if inst_iid(cur) == IID_fake_use { continue; }
        let ni = pfc_clone_instruction(cur, nf);
        block_append_inst(nbb, ni);
        // All function calls inlined into a strictfp function get 'strictfp'
        if pfc_host_strictfp && iop(ni) == OP_CALL { cb_add_fn_attr_enum(ni, AK_StrictFP); }
        if iop(ni) != OP_PHI {
            remap_instruction(ni, m, RF_NO_MODULE_LEVEL_CHANGES);
            let v = ic::ic_constant_fold_instruction(ni);
            if v >= 0 && is_instruction_trivially_dead(ni) {
                vmm_set(m, cur, v);
                inst_erase_from_parent(ni);
                continue;
            }
        }
        if is_callbase(cur) && !is_func(cb_callee(cur)) && !is_constant(cb_callee(cur)) && vals[cb_callee(cur)].kind != VK_INLINEASM { cci_orig_indirect.push(ni); }
        if_name_with(ni, cur, suffix);
        vmm_set(m, cur, ni);
        if iop(cur) == OP_CALL && inst_iid(cur) != IID_pseudoprobe {
            has_calls = true;
            if inst_get_md(cur, mdk("memprof")) >= 0 || inst_get_md(cur, mdk("callsite")) >= 0 { cci_contains_memprof = true; }
        }
        clone_dbg_to_here(ni, cur);
        vmm_set(cci_orig_vmap, cur, ni);
        if is_callbase(cur) && cb_nbundles(cur) > 0 { cci_bundle_sites.push(wvh_new(ni, WVH_WEAK_TRACKING)); }
        if iop(cur) == OP_ALLOCA {
            if ia_is_cint(op(cur, 0)) { has_static = true; } else { has_dyn = true; }
        }
    }
    var done = false;
    let to = iop(old_ti);
    if to == OP_CONDBR || to == OP_SWITCH {
        var cond = op(old_ti, 0);
        if !ia_is_cint(cond) { let v = vmm_get(m, cond); cond = if ia_is_cint(v) { v } else { -1 }; }
        if cond >= 0 {
            var dest: i32 = -1;
            if to == OP_CONDBR { dest = term_succ(old_ti, if cint_is_zero(cond) { 1 } else { 0 }); }
            else { dest = ca_switch_case_dest(old_ti, cond); }
            let nbi = create_inst(OP_BR, T_VOID, [dest]);
            block_append_inst(nbb, nbi);
            let dl = inst_get_md(old_ti, 0);
            if dl >= 0 { inst_set_md(nbi, 0, dl); }
            vmm_set(m, old_ti, nbi);
            to_clone.push(dest);
            done = true;
        }
    }
    if !done {
        let ni = inst_clone(old_ti);
        block_append_inst(nbb, ni);
        if_name_with(ni, old_ti, suffix);   // named before insertInto: uniqued on insertion
        clone_dbg_to_here(ni, old_ti);
        vmm_set(m, old_ti, ni);
        vmm_set(cci_orig_vmap, old_ti, ni);
        if is_callbase(old_ti) && cb_nbundles(old_ti) > 0 { cci_bundle_sites.push(wvh_new(ni, WVH_WEAK_TRACKING)); }
        let ns = term_nsucc(old_ti);
        for k in ns { to_clone.push(term_succ(old_ti, k)); }
    } else {
        clone_dbg_to_here(block_terminator(nbb), old_ti);
    }
    if has_calls { cci_contains_calls = true; }
    if has_dyn { cci_contains_dynamic_allocas = true; }
    if has_static && bb != func_entry(block_func(bb)) { cci_contains_dynamic_allocas = true; }
}

// CloneAndPruneIntoFromInst(NewFunc, OldFunc, &OldFunc->front().front(), VMap, false, Returns, ".i", CodeInfo)
fn clone_and_prune_function_into(nf: i32, of: i32, m: i32, returns: i32[>..<]&) {
    pfc_host_strictfp = fn_has(nf, 0, AK_StrictFP);
    let suffix = ".i";
    let start_bb = func_entry(of);
    var wl: i32[>..<] = [];
    pfc_clone_block(start_bb, block_first(start_bb), nf, m, suffix, wl);
    while wl.len > 0 {
        let bb = wl.pop();
        pfc_clone_block(bb, block_first(bb), nf, m, suffix, wl);
    }
    var phis: i32[>..<] = [];
    var b = func_first_block(of);
    while b >= 0 {
        let nbb = vmm_get(m, b);
        if nbb >= 0 {
            block_move_before_end(nbb, nf);
            var p = block_first(b);
            while p >= 0 && iop(p) == OP_PHI {
                let mp = vmm_get(m, p);
                if mp >= 0 && is_inst_op(mp, OP_PHI) { phis.push(p); } else { break; }
                p = inst_next(p);
            }
            remap_instruction(block_terminator(nbb), m, RF_NO_MODULE_LEVEL_CHANGES);
        }
        b = block_next(b);
    }
    var phino: i64 = 0;
    while phino < phis.len {
        var opn = phis[phino];
        let npreds0 = nops(opn);
        let old_bb = inst_parent(opn);
        let new_bb = vmm_get(m, old_bb);
        while phino < phis.len && inst_parent(phis[phino]) == old_bb {
            opn = phis[phino];
            let pn = vmm_get(m, opn);
            var pred = npreds0 - 1;
            while pred >= 0 {
                let mb = vmm_get(m, phi_block(pn, pred));
                if mb >= 0 {
                    let inv = map_value(phi_value(pn, pred), m, RF_NO_MODULE_LEVEL_CHANGES);
                    set_op(pn, pred, inv);
                    phi_set_block(pn, pred, mb);
                } else {
                    phi_remove_incoming(pn, pred);
                }
                pred--;
            }
            phino++;
        }
        var pn = block_first(new_bb);
        let np = pred_count(new_bb);
        if np != nops(pn) {
            // PredCount: predecessors with multiplicity
            var pb: i32[>..<] = [];
            var pc: i64[>..<] = [];
            each_pred(new_bb) { p =>
                var f = false;
                for j in pb.len { if pb[j] == p { pc[j] += 1; f = true; } }
                if !f { pb.push(p); pc.push(1); }
            };
            var i = block_first(new_bb);
            while i >= 0 && iop(i) == OP_PHI {
                var seen: i64[>..<] = [];
                for j in pb.len { seen.push(0); }
                // removeIncomingValueIf(pred, DeletePHIIfEmpty = false): keeps the order of the survivors
                var k: i64 = 0;
                var keep_v: i32[>..<] = [];
                var keep_b: i32[>..<] = [];
                let n = nops(i);
                for x in n {
                    let ib = phi_block(i, x);
                    var j: i64 = -1;
                    for q in pb.len { if pb[q] == ib { j = q; } }
                    var rm = true;
                    if j >= 0 && seen[j] < pc[j] { seen[j] += 1; rm = false; }
                    if !rm { keep_v.push(phi_value(i, x)); keep_b.push(ib); }
                }
                if keep_v.len != n { phi_remove_incoming_if_rebuild(i, keep_v, keep_b); }
                k++;
                i = inst_next(i);
            }
        }
        pn = block_first(new_bb);
        if nops(pn) == 0 {
            var i = block_first(new_bb);
            var oi = block_first(old_bb);
            while i >= 0 && iop(i) == OP_PHI {
                let nx = inst_next(i);
                let nv = c_poison(vals[i].ty);
                rauw(i, nv);
                vmm_set(m, oi, nv);
                inst_erase_from_parent(i);
                oi = inst_next(oi);
                i = nx;
            }
        }
    }
    // NewFunc's incompatible return attributes are dropped and restored later (setAttributes(Attrs))
    let saved_attrs = globs[glob_of(nf)].attrs;
    b = func_first_block(of);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            let ni = vmm_get(m, i);
            if ni >= 0 && is_inst(ni) {
                let v = if_simplify_instruction(ni);
                if v >= 0 {
                    rauw(ni, v);
                    if is_instruction_trivially_dead(ni) { inst_erase_from_parent(ni); }
                    else { vmm_set(m, i, ni); }
                }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    globs[glob_of(nf)].attrs = saved_attrs;
    let begin = vmm_get(m, start_bb);
    b = begin;
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 { remap_dbg_record_range(i, m, RF_NO_MODULE_LEVEL_CHANGES); i = inst_next(i); }
        b = block_next(b);
    }
    b = begin;
    while b >= 0 { let nb = block_next(b); cu_dtu = false; cu_constant_fold_terminator(b, false); b = nb; }
    // remove unreachable blocks
    {
        var reach = hm_new();
        var wl2: i32[>..<] = [begin];
        while wl2.len > 0 {
            let x = wl2.pop();
            if hm_has(reach, (x as i64) as u64) { continue; }
            hm_put(reach, (x as i64) as u64, 1);
            let ns = block_nsucc(x);
            for k in ns { wl2.push(block_succ(x, k)); }
        }
        var dead: i32[>..<] = [];
        b = begin;
        while b >= 0 { if !hm_has(reach, (b as i64) as u64) { dead.push(b); } b = block_next(b); }
        if dead.len > 0 { cu_dtu = false; cu_delete_dead_blocks(dead, false); }
    }
    // merge a block into its unconditional single predecessor
    var it = begin;
    while it >= 0 {
        let t = block_terminator(it);
        if iop(t) != OP_BR { it = block_next(it); continue; }
        let dest = op(t, 0);
        if single_pred(dest) < 0 || ic_block_address_taken(dest) { it = block_next(it); continue; }
        inst_erase_from_parent(t);
        cu_block_rauw(dest, it);
        block_splice(it, -1, false, dest, block_first(dest), true, -1, false);
        block_erase(dest);
    }
    b = vmm_get(m, start_bb);
    while b >= 0 {
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_RET { returns.push(t); }
        b = block_next(b);
    }
}
fn block_move_before_end(bb: i32, f: i32) { block_move_before(bb, -1); }
// PHINode::removeIncomingValueIf: rebuild the incoming list keeping the survivors in order
fn phi_remove_incoming_if_rebuild(p: i32, vs: i32[:], bs: i32[:]) {
    let n = nops(p);
    // remove from the back so the earlier slots keep their order, then rewrite the survivors
    var k = n - 1;
    while k >= vs.len { phi_remove_incoming(p, k); k--; }
    for j in vs.len { set_op(p, j, vs[j]); phi_set_block(p, j, bs[j]); }
}
// simplifyInstruction(I, DL): only the DataLayout
fn if_simplify_instruction(i: i32) -> i32 {
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    kb_cxt = -1;
    let r = simplify_instruction(i);
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return r;
}

// ---------------------------------------------------------------------------------------------
// MemProf: propagateMemProfMetadata and CallStackTrie (llvm/lib/Analysis/MemoryProfileInfo.cpp)

let AT_NOTCOLD = 1;
let AT_COLD = 2;
let AT_HOT = 4;
struct TrieNode { types: u8, callers: i32, ncallers: i32 }
var tr_nodes: TrieNode[>..<];
var tr_ckey: u64[>..<];      // caller links: stack id, child node, next link (a list; sorted when walked)
var tr_cchild: i32[>..<];
var tr_cnext: i32[>..<];
var tr_ctx_node: i32[>..<];  // ContextInfo entries: node, full stack id, total size, original alloc type
var tr_ctx_id: u64[>..<];
var tr_ctx_size: u64[>..<];
var tr_ctx_at: i32[>..<];
var tr_alloc: i32 = -1;
var tr_alloc_id: u64 = 0;
fn tr_reset() {
    tr_nodes.resize(0); tr_ckey.resize(0); tr_cchild.resize(0); tr_cnext.resize(0);
    tr_ctx_node.resize(0); tr_ctx_id.resize(0); tr_ctx_size.resize(0); tr_ctx_at.resize(0);
    tr_alloc = -1; tr_alloc_id = 0;
}
fn tr_new(t: i64) -> i32 { tr_nodes.push(TrieNode { types: t as u8, callers: -1, ncallers: 0 }); return (tr_nodes.len - 1) as i32; }
fn md_cint_u64(m: i32) -> u64 { cint_lo(mds[m].extra) }
// getMIBAllocType
fn mib_alloc_type(mib: i32) -> i64 {
    let s = md_op(mib, 1);
    if s >= 0 && mds[s].kind == MK_STRING {
        let t = sbytes(mds[s].extra);
        if t == "cold" { return AT_COLD; }
        if t == "hot" { return AT_HOT; }
    }
    return AT_NOTCOLD;
}
fn at_string(t: i64) -> const u8[:] { if t == AT_COLD { "cold" } else if t == AT_HOT { "hot" } else { "notcold" } }
fn single_alloc_type(t: i64) -> bool { t == 1 || t == 2 || t == 4 }
// CallStackTrie::addCallStack(MIB)
fn tr_add_call_stack(mib: i32) {
    let at = mib_alloc_type(mib);
    let st = md_op(mib, 0);
    var cur: i32 = -1;
    for k in mds[st].nops as i64 {
        let id = md_cint_u64(md_op(st, k));
        if k == 0 {
            if tr_alloc >= 0 { tr_nodes[tr_alloc].types |= at as u8; } else { tr_alloc_id = id; tr_alloc = tr_new(at); }
            cur = tr_alloc;
            continue;
        }
        // the caller list is kept sorted by stack id (std::map order)
        var prev: i32 = -1;
        var l = tr_nodes[cur].callers;
        while l >= 0 && tr_ckey[l] < id { prev = l; l = tr_cnext[l]; }
        if l >= 0 && tr_ckey[l] == id { cur = tr_cchild[l]; tr_nodes[cur].types |= at as u8; continue; }
        let nn = tr_new(at);
        tr_ckey.push(id); tr_cchild.push(nn); tr_cnext.push(l);
        let nl = (tr_ckey.len - 1) as i32;
        if prev < 0 { tr_nodes[cur].callers = nl; } else { tr_cnext[prev] = nl; }
        tr_nodes[cur].ncallers++;
        cur = nn;
    }
    for k in 2..(mds[mib].nops as i64) {
        let pr = md_op(mib, k);
        tr_ctx_node.push(cur); tr_ctx_id.push(md_cint_u64(md_op(pr, 0))); tr_ctx_size.push(md_cint_u64(md_op(pr, 1))); tr_ctx_at.push(at as i32);
    }
}
// collectContextInfo: the ContextInfo entries of a subtrie (indices, appended to tr_ctx_buf), the node's first,
// then its callers' in stack id order
var tr_ctx_buf: i32[>..<];
recursive fn tr_collect_ctx(n: i32) {
    for k in tr_ctx_node.len { if tr_ctx_node[k] == n { tr_ctx_buf.push(k as i32); } }
    var l = tr_nodes[n].callers;
    while l >= 0 { tr_collect_ctx(tr_cchild[l]); l = tr_cnext[l]; }
}
recursive fn tr_hot_to_notcold(n: i32) {
    if (tr_nodes[n].types & (AT_HOT as u8)) != 0 { tr_nodes[n].types = (tr_nodes[n].types & ~(AT_HOT as u8)) | (AT_NOTCOLD as u8); }
    var l = tr_nodes[n].callers;
    while l >= 0 { tr_hot_to_notcold(tr_cchild[l]); l = tr_cnext[l]; }
}
fn mp_includes_all_ctx_size_info() -> bool {
    return flag_bool("memprof-report-hinted-sizes", false) || flag_bool("memprof-keep-context-size-info", false) ||
        flag_int("memprof-cloning-cold-threshold", 100) < 100;
}
fn md_i64(x: u64) -> i32 { md_value(c_int(T_I64, x as! i64)) }
// createMIBNode (built from existing metadata: every cold context's size info is kept); the stack is tr_stack,
// the context info tr_ctx_buf
var tr_stack: u64[>..<];
fn payload_finish(payload: i32[>..<]&, at: i64, total: u64&, cold: u64&) -> i32 {
    if tr_ctx_buf.len == 0 { return md_get(MK_TUPLE, -1, payload, false); }
    for k in tr_ctx_buf {
        total += tr_ctx_size[k];
        var large = false;
        if at == AT_COLD { cold += tr_ctx_size[k]; large = true; }
        if mp_includes_all_ctx_size_info() || large {
            payload.push(md_get(MK_TUPLE, -1, [md_i64(tr_ctx_id[k]), md_i64(tr_ctx_size[k])], false));
        }
    }
    return md_get(MK_TUPLE, -1, payload, false);
}
fn mp_report(what: const u8[:]) { if flag_bool("memprof-report-hinted-sizes", false) { if_not_ported(what); } }
// saveFilteredNewMIBNodes (BuiltFromExistingMetadata: never "mostly cold"): the new nodes are tr_buf[mark..],
// replaced by the saved ones
var tr_buf: i32[>..<];
fn tr_save_filtered(mark: i64, caller_len: i64) {
    var newn: i32[>..<] = [];
    for k in mark..tr_buf.len { newn.push(tr_buf[k]); }
    tr_buf.resize(mark);
    if flag_bool("memprof-keep-all-not-cold-contexts", false) { for x in newn { tr_buf.push(x); } return; }
    var longer = false;
    for x in newn {
        if mib_alloc_type(x) == AT_COLD { continue; }
        if (mds[md_op(x, 0)].nops as i64) > caller_len { longer = true; break; }
    }
    var keep_first = !longer;
    for x in newn {
        if mib_alloc_type(x) != AT_COLD {
            if (mds[md_op(x, 0)].nops as i64) > caller_len { tr_buf.push(x); continue; }
            if keep_first { keep_first = false; tr_buf.push(x); continue; }
            mp_report("-memprof-report-hinted-sizes");
            continue;
        }
        tr_buf.push(x);
    }
}
// CallStackTrie::buildMIBNodes: appends the MIB nodes to tr_buf
recursive fn tr_build_mib_nodes(n: i32, callee_ambiguous: bool, total: u64&, cold: u64&) -> bool {
    if single_alloc_type(tr_nodes[n].types as i64) {
        tr_ctx_buf.resize(0);
        tr_collect_ctx(n);
        tr_buf.push(tr_create_mib_ctx(tr_nodes[n].types as i64, total, cold));
        return true;
    }
    if tr_nodes[n].callers >= 0 {
        let ambiguous = tr_nodes[n].ncallers > 1;
        var all = true;
        let mark = tr_buf.len;
        var ct: u64 = 0;
        var cc: u64 = 0;
        var l = tr_nodes[n].callers;
        while l >= 0 {
            tr_stack.push(tr_ckey[l]);
            let r = tr_build_mib_nodes(tr_cchild[l], ambiguous, ct, cc);
            all = all && r;
            tr_stack.pop();
            l = tr_cnext[l];
        }
        tr_save_filtered(mark, tr_stack.len + 1);
        total += ct;
        cold += cc;
        if all { return true; }
    }
    if !callee_ambiguous { return false; }
    tr_ctx_buf.resize(0);
    tr_collect_ctx(n);
    tr_buf.push(tr_create_mib_ctx(AT_NOTCOLD, total, cold));
    return true;
}
// createMIBNode with the context info already in tr_ctx_buf
fn tr_create_mib_ctx(at: i64, total: u64&, cold: u64&) -> i32 {
    var sv: i32[>..<] = [];
    for id in tr_stack { sv.push(md_i64(id)); }
    var payload: i32[>..<] = [md_get(MK_TUPLE, -1, sv, false), md_string(at_string(at))];
    return payload_finish(payload, at, total, cold);
}
// call-site string function attributes
fn cb_fn_str_attr(c: i32, key: const u8[:]) -> i32 {
    let l = insts[inst_of(c)].attrs;
    if l == 0 { return -1; }
    return aset_find_str(alist_fn(l), key);
}
fn cb_set_fn_attrs(c: i32, s: i32) {
    let ii = inst_of(c);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 1) {
        var x: i32 = 0;
        if j < n { x = alist_runs[alists[l].at + j]; }
        if j == 0 { x = s; }
        sets.push(x);
    }
    insts[ii].attrs = alist_get(sets);
}
fn cb_remove_fn_str_attr(c: i32, key: const u8[:]) {
    let l = insts[inst_of(c)].attrs;
    if l == 0 { return; }
    let s = alist_fn(l);
    var xs: i32[>..<] = [];
    var changed = false;
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind == 0 && sbytes(attrs[x].skey) == key { changed = true; continue; } xs.push(x); }
    if changed { cb_set_fn_attrs(c, aset_get(xs)); }
}
fn cb_put_fn_str_attr(c: i32, key: const u8[:], val: const u8[:]) {
    let l = insts[inst_of(c)].attrs;
    let s = if l == 0 { 0 } else { alist_fn(l) };
    var xs: i32[>..<] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind == 0 && sbytes(attrs[x].skey) == key { continue; } xs.push(x); }
    xs.push(attr_str(key, val, true));
    cb_set_fn_attrs(c, aset_get(xs));
}
// addSingleAllocTypeAttribute (no remarks)
fn tr_add_single_alloc_type_attribute(c: i32, at: i64) {
    if cb_fn_str_attr(c, "memprof") >= 0 { cb_remove_fn_str_attr(c, "memprof"); }
    cb_put_fn_str_attr(c, "memprof", at_string(at));
    mp_report("-memprof-report-hinted-sizes");
}
// CallStackTrie::buildAndAttachMIBMetadata: true if !memprof was attached
fn tr_build_and_attach(c: i32) -> bool {
    if single_alloc_type(tr_nodes[tr_alloc].types as i64) { tr_add_single_alloc_type_attribute(c, tr_nodes[tr_alloc].types as i64); return false; }
    if (tr_nodes[tr_alloc].types & (AT_HOT as u8)) != 0 {
        tr_hot_to_notcold(tr_alloc);
        if single_alloc_type(tr_nodes[tr_alloc].types as i64) { tr_add_single_alloc_type_attribute(c, tr_nodes[tr_alloc].types as i64); return false; }
    }
    tr_stack.resize(0);
    tr_stack.push(tr_alloc_id);
    tr_buf.resize(0);
    var total: u64 = 0;
    var cold: u64 = 0;
    if tr_build_mib_nodes(tr_alloc, false, total, cold) {
        inst_set_md(c, mdk("memprof"), md_get(MK_TUPLE, -1, tr_buf, false));
        // addAmbiguousAttribute
        if flag_bool("memprof-ambiguous-attributes", true) && cb_fn_str_attr(c, "memprof") < 0 { cb_put_fn_str_attr(c, "memprof", "ambiguous"); }
        return true;
    }
    tr_add_single_alloc_type_attribute(c, AT_NOTCOLD);
    return false;
}
// haveCommonPrefix
fn mp_have_common_prefix(a: i32, b: i32) -> bool {
    let n = min(mds[a].nops as i64, mds[b].nops as i64);
    for k in n { if md_cint_u64(md_op(a, k)) != md_cint_u64(md_op(b, k)) { return false; } }
    return true;
}
// propagateMemProfHelper
fn propagate_memprof_helper(cc: i32, inlined_cs: i32) {
    let kc = mdk("callsite");
    let km = mdk("memprof");
    let ocs = inst_get_md(cc, kc);
    var ncs: i32 = -1;
    if ocs >= 0 {
        ncs = md_concatenate(ocs, inlined_cs);
        inst_set_md(cc, kc, ncs);
    }
    let omp = inst_get_md(cc, km);
    if omp < 0 { return; }
    var mibs: i32[>..<] = [];
    for k in mds[omp].nops as i64 {
        let mib = md_op(omp, k);
        if mp_have_common_prefix(md_op(mib, 0), ncs) { mibs.push(mib); }
    }
    if mibs.len == 0 { inst_erase_md(cc, km); inst_erase_md(cc, kc); return; }
    if mibs.len < (mds[omp].nops as i64) {
        // updateMemprofMetadata
        inst_erase_md(cc, km);
        tr_reset();
        for x in mibs { tr_add_call_stack(x); }
        if !tr_build_and_attach(cc) { inst_erase_md(cc, kc); }
    }
}
// propagateMemProfMetadata: over the VMap's (original call -> cloned call) entries
fn propagate_memprof_metadata(callee: i32, cb: i32, m: i32) {
    let cs = inst_get_md(cb, mdk("callsite"));
    if cs < 0 && !cci_contains_memprof { return; }
    var b = func_first_block(callee);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if is_callbase(i) {
                let c = vmm_get(m, i);
                if c >= 0 && is_inst(c) && !is_dead(c) && is_callbase(c) {
                    if cs < 0 { inst_erase_md(c, mdk("memprof")); inst_erase_md(c, mdk("callsite")); }
                    else { propagate_memprof_helper(c, cs); }
                }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
}

// ---------------------------------------------------------------------------------------------
// Metadata helpers

// MDNode::concatenate(A, B) (getOrSelfReference)
fn md_concatenate(a: i32, b: i32) -> i32 {
    if a < 0 { return b; }
    if b < 0 { return a; }
    var ops: i32[>..] = [];
    fn add(x: i32) { for y in ops { if y == x { return; } } ops.push(x); }
    for k in mds[a].nops as i64 { add(md_op(a, k)); }
    for k in mds[b].nops as i64 { add(md_op(b, k)); }
    if ops.len > 0 {
        let n = ops[0];
        if n >= 0 && md_is_node(n) && (mds[n].nops as i64) == ops.len && md_op(n, 0) == n {
            var same = true;
            for k in 1..ops.len { if ops[k] != md_op(n, k) { same = false; } }
            if same { return n; }
        }
    }
    return md_get(MK_TUPLE, -1, ops, false);
}

// ScopedAliasMetadataDeepCloner: the scope metadata reachable from the callee's !alias.scope / !noalias and
// noalias.scope.decl scope lists, cloned (a distinct self-referential node gives a new distinct one)
var dc_nodes: i32[>..<];
var dc_map = hm_new();
fn dc_add(m: i32) { if m >= 0 && md_is_node(m) { for x in dc_nodes { if x == m { return; } } dc_nodes.push(m); } }
fn dc_collect(callee: i32) {
    dc_nodes.resize(0);
    hm_clear(dc_map);
    each_inst(callee) { i =>
        dc_add(inst_get_md(i, MDK_ALIAS_SCOPE));
        dc_add(inst_get_md(i, MDK_NOALIAS));
        if inst_iid(i) == IID_experimental_noalias_scope_decl { dc_add(vals[cb_arg(i, 0)].sub); }
    };
    // addRecursiveMetadataUses (queue order only affects the set's order)
    var q: i32[>..<] = [];
    for x in dc_nodes { q.push(x); }
    while q.len > 0 {
        let m = q.pop();
        for k in mds[m].nops as i64 {
            let o = md_op(m, k);
            if o >= 0 && md_is_node(o) {
                var seen = false;
                for x in dc_nodes { if x == o { seen = true; } }
                if !seen { dc_nodes.push(o); q.push(o); }
            }
        }
    }
}
// clone(): MDMap[I] = MDNode::get(new ops); a node whose only cycle is a self reference becomes distinct
recursive fn dc_clone_node(m: i32, depth: i64) -> i32 {
    let f = hm_get(dc_map, (m as i64) as u64, -1);
    if f >= 0 { return f as i32; }
    if depth > 64 { if_not_ported("cyclic scoped-alias metadata"); }
    let n = mds[m].nops as i64;
    if mds[m].kind != MK_TUPLE { if_not_ported("non-tuple scoped-alias metadata"); }
    var self_ref = false;
    for k in n { if md_op(m, k) == m { self_ref = true; } }
    let mark = dc_ops.len;
    for k in n {
        let o = md_op(m, k);
        if o == m { dc_ops.push(-3); continue; }
        if o >= 0 && md_is_node(o) && dc_in_set(o) { let c = dc_clone_node(o, depth + 1); dc_ops.push(c); }
        else { dc_ops.push(o); }
    }
    var ops: i32[>..] = [];
    for k in mark..dc_ops.len { ops.push(dc_ops[k]); }
    dc_ops.resize(mark);
    var r: i32 = -1;
    if self_ref {
        for k in ops.len { if ops[k] == -3 { ops[k] = -1; } }
        r = md_get(MK_TUPLE, -1, ops, true);
        for k in n { if md_op(m, k) == m { md_ops[(mds[r].ops as i64) + k] = r; } }
    } else {
        r = md_get(MK_TUPLE, -1, ops, false);
    }
    hm_put(dc_map, (m as i64) as u64, r as i64);
    return r;
}
var dc_ops: i32[>..<];
fn dc_in_set(m: i32) -> bool { for x in dc_nodes { if x == m { return true; } } return false; }
fn dc_clone() { for x in dc_nodes { dc_clone_node(x, 0); } }
fn dc_lookup(m: i32) -> i32 { if m < 0 { -1 } else { hm_get(dc_map, (m as i64) as u64, -1) as i32 } }
fn dc_remap(first: i32) {
    if dc_nodes.len == 0 { return; }
    var b = first;
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            let a = dc_lookup(inst_get_md(i, MDK_ALIAS_SCOPE));
            if a >= 0 { inst_set_md(i, MDK_ALIAS_SCOPE, a); }
            let n = dc_lookup(inst_get_md(i, MDK_NOALIAS));
            if n >= 0 { inst_set_md(i, MDK_NOALIAS, n); }
            if inst_iid(i) == IID_experimental_noalias_scope_decl {
                let d = dc_lookup(vals[cb_arg(i, 0)].sub);
                if d >= 0 { set_op(i, 0, get_md_as_value(d)); }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
}

// MDBuilder::createAnonymousAliasScopeDomain(Name) / createAnonymousAliasScope(Domain, Name)
fn md_anon_scope(domain: i32, name: const u8[:]) -> i32 {
    var ops: i32[>..] = [];
    ops.push(-1);
    if domain >= 0 { ops.push(domain); }
    if name.len > 0 { ops.push(md_string(name)); }
    let r = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[r].ops] = r;
    return r;
}

// ---------------------------------------------------------------------------------------------
// AddAliasScopeMetadata

fn add_alias_scope_metadata(cb: i32, m: i32, callee: i32, aa_fn: i32) {
    if !flag_bool("enable-noalias-to-md-conversion", true) { return; }
    var noalias_args: i32[>..<] = [];
    for k in func_nargs(callee) {
        let a = func_arg(callee, k);
        if cb_param_has_attr(cb, k, AK_NoAlias) && first_use(a) >= 0 { noalias_args.push(a); }
    }
    if noalias_args.len == 0 { return; }
    // a dominator tree of the callee (for PointerMayBeCapturedBefore)
    dt_invalidate(callee, DT_DOM);
    dt_get(callee, DT_DOM);
    var scopes: i32[>..<] = [];
    let dom = md_anon_scope(-1, val_name(callee));
    for i in noalias_args.len {
        let a = noalias_args[i];
        var nm: u8[>..] = [];
        nm.append(val_name(callee));
        if vals[a].name >= 0 { nm.append(": %"); nm.append(val_name(a)); }
        else { format(nm, ": argument ", i); }
        let sc = md_anon_scope(dom, nm);
        scopes.push(sc);
        if flag_bool("use-noalias-intrinsic-during-inlining", true) {
            let sl = md_get(MK_TUPLE, -1, [sc], false);
            let d = au_get_declaration(IID_experimental_noalias_scope_decl, []);
            let ci = create_inst(OP_CALL, T_VOID, [get_md_as_value(sl), d]);
            insts[inst_of(ci)].ty2 = globs[glob_of(d)].vty;
            inst_insert_before(ci, cb);
            if_copy_dbg_loc_builder(ci, cb);
        }
    }
    var e = vmm_first(m);
    while e >= 0 {
        let i = vmm_ent_key(e);
        let ni = vmm_ent_val(e);
        e = vmm_next(e);
        if i < 0 || !is_inst(i) || ni < 0 || !is_inst(ni) || cci_is_simplified(i, ni) { continue; }
        var argmem_only = false;
        var is_call = false;
        var ptrs: i32[>..<] = [];
        let o = iop(i);
        if o == OP_LOAD || o == OP_VAARG { ptrs.push(op(i, 0)); }
        else if o == OP_STORE { ptrs.push(op(i, 1)); }
        else if o == OP_CMPXCHG || o == OP_ATOMICRMW { ptrs.push(op(i, 0)); }
        else if is_callbase(i) {
            if call_memory_effects(i) == 0 { continue; }
            is_call = true;
            if aa_fn >= 0 {
                aa_begin(aa_fn);
                let me = aa_call_me_simple(i);
                if me_only_inaccessible(me) { continue; }
                if me_only_arg(me) { argmem_only = true; }
            }
            for k in cb_nargs(i) { let x = cb_arg(i, k); if ty_kind(vals[x].ty) == TK_PTR { ptrs.push(x); } }
        }
        if ptrs.len == 0 && !is_call { continue; }
        var objs: i32[>..<] = [];
        for p in ptrs {
            var os: i32[>..<] = [];
            get_underlying_objects(p, os);
            for x in os { var seen = false; for y in objs { if y == x { seen = true; } } if !seen { objs.push(x); } }
        }
        var req_nocap = false;
        var aliasing = false;
        var unknown = false;
        for v in objs {
            let k = vals[v].kind;
            if ia_is_cint(v) || k == VK_CFP || k == VK_CNULL || k == VK_CDVECTOR || k == VK_UNDEF || k == VK_POISON { continue; }
            if is_arg(v) {
                if !cb_param_has_attr(cb, args_no[vals[v].sub] as i64, AK_NoAlias) { aliasing = true; }
            } else { aliasing = true; }
            if aa_is_escape_source(v) { req_nocap = true; }
            else if !is_arg(v) && !aa_is_identified_object(v) { unknown = true; }
        }
        if unknown { continue; }
        if is_call && !argmem_only { req_nocap = true; }
        var noaliases: i32[>..] = [];
        for j in noalias_args.len {
            let a = noalias_args[j];
            var in_objs = false;
            for x in objs { if x == a { in_objs = true; } }
            if in_objs { continue; }
            if !req_nocap || cc_nothing(ct_may_be_captured_before(a, false, i, false, CC_PROVENANCE, CT_STOP_ANY, false)) {
                noaliases.push(scopes[j]);
            }
        }
        if noaliases.len > 0 {
            inst_set_md(ni, MDK_NOALIAS, md_concatenate(inst_get_md(ni, MDK_NOALIAS), md_get(MK_TUPLE, -1, noaliases, false)));
        }
        var can_add = !aliasing;
        if can_add && is_call { can_add = argmem_only; }
        if can_add {
            var sc: i32[>..] = [];
            for j in noalias_args.len {
                for x in objs { if x == noalias_args[j] { sc.push(scopes[j]); break; } }
            }
            if sc.len > 0 {
                inst_set_md(ni, MDK_ALIAS_SCOPE, md_concatenate(inst_get_md(ni, MDK_ALIAS_SCOPE), md_get(MK_TUPLE, -1, sc, false)));
            }
        }
    }
    dt_invalidate(callee, DT_DOM);
}
fn me_only_inaccessible(m: u64) -> bool { me_without(m, LOC_INACCESSIBLE) == 0 }
// IRBuilder(&CB): new instructions get the call site's debug location
fn if_copy_dbg_loc_builder(ni: i32, at: i32) {
    let dl = inst_get_md(at, 0);
    if dl >= 0 { inst_set_md(ni, 0, dl); }
}

// ---------------------------------------------------------------------------------------------
// Debug locations (fixupLineNumbers)

fn if_dil(line: i64, col: i64, scope: i32, ia: i32, implicit: bool, distinct: bool) -> i32 {
    var slots: i32[7] = [-1, -1, -1, -1, -1, -1, -1];
    if line != 0 { slots[0] = md_int(line); }
    if col != 0 { slots[1] = md_int(col); }
    slots[2] = scope;
    slots[3] = ia;
    if implicit { slots[4] = md_int(1); }
    return md_get(MK_DI, DIK_LOCATION as i32, slots, distinct);
}
fn dil_line(l: i32) -> i64 { di_int(l, "line") }
fn dil_col(l: i32) -> i64 { di_int(l, "column") }
fn dil_scope(l: i32) -> i32 { di_slot(l, "scope") }
fn dil_ia(l: i32) -> i32 { di_slot(l, "inlinedAt") }
fn dil_implicit(l: i32) -> bool { di_int(l, "isImplicitCode") != 0 }
fn dil_check_atoms(l: i32) {
    if di_int(l, "atomGroup") != 0 || di_int(l, "atomRank") != 0 { if_not_ported("key-instruction atom groups in inlined debug locations"); }
}
var ia_cache = hm_new();     // IANodes
// DebugLoc::appendInlinedAt
fn append_inlined_at(dl: i32, inlined_at: i32) -> i32 {
    var chain: i32[>..<] = [];
    var last = inlined_at;
    var cur = dl;
    loop {
        let ia = dil_ia(cur);
        if ia < 0 { break; }
        let f = hm_get(ia_cache, (ia as i64) as u64, -1);
        if f >= 0 { last = f as i32; break; }
        chain.push(ia);
        cur = ia;
    }
    var k = chain.len - 1;
    while k >= 0 {
        let md = chain[k];
        last = if_dil(dil_line(md), dil_col(md), dil_scope(md), last, false, true);
        hm_put(ia_cache, (md as i64) as u64, last as i64);
        k--;
    }
    return last;
}
// inlineDebugLoc
fn inline_debug_loc(dl: i32, inlined_at: i32) -> i32 {
    dil_check_atoms(dl);
    let ia = append_inlined_at(dl, inlined_at);
    return if_dil(dil_line(dl), dil_col(dl), dil_scope(dl), ia, dil_implicit(dl), false);
}
// updateLoopMetadataDebugLocationsRecursive with the inlining updater
recursive fn loop_md_update_rec(md: i32, ia: i32) -> i32 {
    if md < 0 || mds[md].kind != MK_TUPLE || mds[md].nops < 1 { return md; }
    let o0 = md_op(md, 0);
    if o0 < 0 || mds[o0].kind != MK_STRING { return md; }
    var updated = false;
    let mark = lmu_ops.len;
    lmu_ops.push(o0);
    for k in 1..(mds[md].nops as i64) {
        let o = md_op(md, k);
        if o < 0 { lmu_ops.push(-1); continue; }
        let r = loop_md_updater(loop_md_update_rec(o, ia), ia);
        if r >= 0 { lmu_ops.push(r); }
        if r != o { updated = true; }
    }
    var ops: i32[>..] = [];
    for k in mark..lmu_ops.len { ops.push(lmu_ops[k]); }
    lmu_ops.resize(mark);
    return if updated { md_get(MK_TUPLE, -1, ops, false) } else { md };
}
var lmu_ops: i32[>..<];
recursive fn loop_md_updater(md: i32, ia: i32) -> i32 {
    if md >= 0 && mds[md].kind == MK_DI && di_kind(md) == DIK_LOCATION { return inline_debug_loc(md, ia); }
    return md;
}
fn update_loop_md_debug_locations(i: i32, ia: i32) {
    let lid = inst_get_md(i, MDK_LOOP);
    if lid < 0 { return; }
    var ops: i32[>..] = [];
    ops.push(-1);
    for k in 1..(mds[lid].nops as i64) {
        let o = md_op(lid, k);
        if o < 0 { ops.push(-1); continue; }
        let r = loop_md_updater(loop_md_update_rec(o, ia), ia);
        if r >= 0 { ops.push(r); }
    }
    let n = md_get(MK_TUPLE, -1, ops, true);
    md_ops[mds[n].ops] = n;
    inst_set_md(i, MDK_LOOP, n);
}

fn fixup_line_numbers(caller: i32, first: i32, cb: i32, callee_has_di: bool) {
    let cdl = inst_get_md(cb, 0);
    if cdl < 0 { return; }
    // TheCallDL->getWithoutAtom()
    var call_dl = cdl;
    if di_int(cdl, "atomGroup") != 0 || di_int(cdl, "atomRank") != 0 {
        call_dl = if_dil(dil_line(cdl), dil_col(cdl), dil_scope(cdl), dil_ia(cdl), dil_implicit(cdl), false);
    }
    let ia_node = if_dil(dil_line(call_dl), dil_col(call_dl), dil_scope(call_dl), dil_ia(call_dl), false, true);
    hm_clear(ia_cache);
    let no_lt = aset_find_str(alist_fn(func_attrs(caller)), "no-inline-line-tables") >= 0;
    var b = first;
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            update_loop_md_debug_locations(i, ia_node);
            let dl = inst_get_md(i, 0);
            var done = false;
            if !no_lt && dl >= 0 { inst_set_md(i, 0, inline_debug_loc(dl, ia_node)); done = true; }
            if !done && (!callee_has_di || no_lt) {
                var skip = false;
                if iop(i) == OP_ALLOCA && is_constant(op(i, 0)) && (insts[inst_of(i)].bits & 2) == 0 { skip = true; }
                if inst_iid(i) == IID_pseudoprobe { skip = true; }
                if !skip { inst_set_md(i, 0, call_dl); }
            }
            var r = inst_first_dbg(i);
            while r >= 0 {
                dbgrecs[r].dl = if no_lt { call_dl } else { inline_debug_loc(dbgrecs[r].dl, ia_node) };
                r = dbgrecs[r].next;
            }
            i = inst_next(i);
        }
        if no_lt {
            var j = block_first(b);
            while j >= 0 { cu_drop_dbg_records(j); j = inst_next(j); }
        }
        b = block_next(b);
    }
}

// ---------------------------------------------------------------------------------------------
// Attributes of the inlined calls

fn cb_param_set(c: i32, k: i64) -> i32 { alist_param(insts[inst_of(c)].attrs, k) }
fn cb_set_param_set(c: i32, k: i64, s: i32) {
    let ii = inst_of(c);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, k + 3) {
        var x: i32 = 0;
        if j < n { x = alist_runs[alists[l].at + j]; }
        if j == k + 2 { x = s; }
        sets.push(x);
    }
    insts[ii].attrs = alist_get(sets);
}
fn cb_ret_set(c: i32) -> i32 { alist_ret(insts[inst_of(c)].attrs) }
fn cb_set_ret_set(c: i32, s: i32) {
    let ii = inst_of(c);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 2) {
        var x: i32 = 0;
        if j < n { x = alist_runs[alists[l].at + j]; }
        if j == 1 { x = s; }
        sets.push(x);
    }
    insts[ii].attrs = alist_get(sets);
}
// AttributeSet with attribute `a` added (replacing its kind)
fn aset_put(s: i32, a: i32) -> i32 {
    var xs: i32[>..<] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind != attrs[a].kind { xs.push(x); } }
    xs.push(a);
    return aset_get(xs);
}
fn aset_drop(s: i32, kind: i64) -> i32 { if aset_has(s, kind) { aset_without(s, [kind]) } else { s } }
fn aset_int_of(s: i32, kind: i64) -> u64 { let a = aset_find(s, kind); if a < 0 { 0 } else { attrs[a].i1 } }
// CallBase::getParamAttr(ArgNo, Kind): the call site's, else the callee's (-1 none)
fn cb_param_attr(c: i32, k: i64, kind: i64) -> i32 {
    let a = aset_find(cb_param_set(c, k), kind);
    if a >= 0 { return a; }
    let f = called_function(c);
    if f < 0 { return -1; }
    return aset_find(alist_param(func_attrs(f), k), kind);
}
fn cb_ret_attr(c: i32, kind: i64) -> i32 {
    let a = aset_find(cb_ret_set(c), kind);
    if a >= 0 { return a; }
    let f = called_function(c);
    if f < 0 { return -1; }
    return aset_find(alist_ret(func_attrs(f)), kind);
}
// a range attribute as a CRange
fn range_of_attr(a: i32) -> CRange {
    let wi = attrs[a].i1 as i64;
    return rg_new(ci_ap(words[wi + 1] as i32), ci_ap(words[wi + 2] as i32));
}
fn range_attr_of(c: CRange) -> i32 {
    let t = ty_int(rg_w(c) as i64);
    let wi = words.len;
    words.push(rg_w(c) as u64);
    words.push(ap_to_cint(t, c.lo) as u64);
    words.push(ap_to_cint(t, c.hi) as u64);
    return attr_int(AK_Range, wi as u64);
}

// AddParamAndFnBasicAttributes
fn add_param_and_fn_basic_attributes(cb: i32, m: i32, callee: i32) {
    let exact_kinds: i64[6] = [AK_Dereferenceable, AK_DereferenceableOrNull, AK_NonNull, AK_NoFPClass, AK_Alignment, AK_Range];
    let na = cb_nargs(cb);
    var obj_sets: i32[>..<] = [];
    var exact_sets: i32[>..<] = [];
    var any = false;
    for k in na {
        var os: i32[>..<] = [];
        if cb_param_has_attr(cb, k, AK_ReadNone) { os.push(attr_enum(AK_ReadNone)); }
        if cb_param_has_attr(cb, k, AK_ReadOnly) { os.push(attr_enum(AK_ReadOnly)); }
        var es: i32[>..<] = [];
        for kd in exact_kinds { let a = cb_param_attr(cb, k, kd); if a >= 0 { es.push(a); } }
        let o = aset_get(os);
        let e = aset_get(es);
        obj_sets.push(o);
        exact_sets.push(e);
        if aset_n(o) > 0 || aset_n(e) > 0 { any = true; }
    }
    if !any { return; }
    var b = func_first_block(callee);
    while b >= 0 {
        var ins = block_first(b);
        while ins >= 0 {
            let inner = ins;
            ins = inst_next(ins);
            if !is_callbase(inner) { continue; }
            let ncb = vmm_get(m, inner);
            if ncb < 0 || !is_inst(ncb) || !is_callbase(ncb) { continue; }
            if cci_is_simplified(inner, ncb) { continue; }
            let n_inner = cb_nargs(inner);
            for i in n_inner {
                if cb_param_has_attr(ncb, i, AK_ByVal) { continue; }
                let narg = cb_arg(ncb, i);
                if pm_imm_constant(narg) { continue; }
                let oarg = cb_arg(inner, i);
                var argno: i64 = -1;
                var s = cb_param_set(ncb, i);
                if is_arg(oarg) && args_parent[vals[oarg].sub] == callee {
                    argno = args_no[vals[oarg].sub] as i64;
                    var nab = exact_sets[argno];
                    if aset_int_of(s, AK_Dereferenceable) > aset_int_of(nab, AK_Dereferenceable) { nab = aset_drop(nab, AK_Dereferenceable); }
                    if aset_int_of(s, AK_DereferenceableOrNull) > aset_int_of(nab, AK_DereferenceableOrNull) { nab = aset_drop(nab, AK_DereferenceableOrNull); }
                    let ea = aset_int_of(s, AK_Alignment);
                    let na2 = aset_int_of(nab, AK_Alignment);
                    if max(ea, 1) > max(na2, 1) { nab = aset_drop(nab, AK_Alignment); }
                    let er = aset_find(s, AK_Range);
                    if er >= 0 {
                        let nr = aset_find(nab, AK_Range);
                        if nr >= 0 { nab = aset_put(nab, range_attr_of(rg_intersect(range_of_attr(er), range_of_attr(nr)))); }
                    }
                    let enf = aset_int_of(s, AK_NoFPClass);
                    if enf != 0 { nab = aset_put(nab, attr_int(AK_NoFPClass, enf | aset_int_of(nab, AK_NoFPClass))); }
                    for k in aset_n(nab) { s = aset_put(s, aset_attr(nab, k)); }
                } else if ty_kind(vals[narg].ty) == TK_PTR {
                    let u = get_underlying_object(oarg, 10);
                    if !is_arg(u) || args_parent[vals[u].sub] != callee { continue; }
                    argno = args_no[vals[u].sub] as i64;
                } else { continue; }
                let ob = obj_sets[argno];
                for k in aset_n(ob) { s = aset_put(s, aset_attr(ob, k)); }
                if aset_has(s, AK_ReadOnly) && aset_has(s, AK_WriteOnly) { s = aset_put(s, attr_enum(AK_ReadNone)); }
                if aset_has(s, AK_ReadNone) { s = aset_drop(aset_drop(s, AK_ReadOnly), AK_WriteOnly); }
                if aset_has(s, AK_ReadOnly) || aset_has(s, AK_ReadNone) { s = aset_drop(s, AK_Writable); }
                cb_set_param_set(ncb, i, s);
            }
        }
        b = block_next(b);
    }
}
// m_ImmConstant: a constant that is not (and contains no) constant expression
fn pm_imm_constant(v: i32) -> bool { is_constant(v) && !c_contains_constant_expression(v) }
recursive fn c_contains_constant_expression(v: i32) -> bool {
    if vals[v].kind == VK_CEXPR { return true; }
    if is_global(v) { return false; }
    for k in nops(v) { if c_contains_constant_expression(op(v, k)) { return true; } }
    return false;
}

// IdentifyValidUBGeneratingAttributes / IdentifyValidPoisonGeneratingAttributes as attribute lists
fn valid_ub_attrs(cb: i32, out: i32[>..<]&) {
    let d = cb_ret_attr_int(cb, AK_Dereferenceable);
    if d != 0 { out.push(attr_int(AK_Dereferenceable, d)); }
    let dn = cb_ret_attr_int(cb, AK_DereferenceableOrNull);
    if dn != 0 { out.push(attr_int(AK_DereferenceableOrNull, dn)); }
    if cb_has_ret_attr(cb, AK_NoAlias) { out.push(attr_enum(AK_NoAlias)); }
    if cb_has_ret_attr(cb, AK_NoUndef) { out.push(attr_enum(AK_NoUndef)); }
}
fn valid_pg_attrs(cb: i32, out: i32[>..<]&) {
    if cb_has_ret_attr(cb, AK_NonNull) { out.push(attr_enum(AK_NonNull)); }
    if cb_has_ret_attr(cb, AK_Alignment) { out.push(attr_int(AK_Alignment, cb_ret_attr_int(cb, AK_Alignment))); }
    let r = cb_ret_attr(cb, AK_Range);
    if r >= 0 { out.push(r); }
    if cb_has_ret_attr(cb, AK_NoFPClass) { out.push(attr_int(AK_NoFPClass, fa_cb_ret_nofpclass(cb))); }
}
fn list_find(xs: i32[>..<]&, kind: i64) -> i64 { for k in xs.len { if attrs[xs[k]].kind as i64 == kind { return k; } } return -1; }
fn list_remove(xs: i32[>..<]&, kind: i64) {
    let k = list_find(xs, kind);
    if k < 0 { return; }
    for j in k + 1..xs.len { xs[j - 1] = xs[j]; }
    xs.pop();
}
fn list_int(xs: i32[>..<]&, kind: i64) -> u64 { let k = list_find(xs, kind); if k < 0 { 0 } else { attrs[xs[k]].i1 } }

// MayContainThrowingOrExitingCallAfterCB
fn may_contain_throwing_after(b: i32, e: i32) -> bool {
    let lim = flag_int("max-inst-checked-for-throw-during-inlining", 4) + 1;
    var n: i64 = 0;
    var i = inst_next(b);
    while i >= 0 && i != e {
        // isGuaranteedToTransferExecutionToSuccessor(Range, ScanLimit): `if (--ScanLimit == 0) return false`
        n++;
        if n >= lim { return true; }
        if !guaranteed_to_transfer(i) { return true; }
        i = inst_next(i);
    }
    return false;
}

// AddReturnAttributes
fn add_return_attributes(cb: i32, m: i32, callee: i32) {
    var ub0: i32[>..<] = [];
    var pg0: i32[>..<] = [];
    valid_ub_attrs(cb, ub0);
    valid_pg_attrs(cb, pg0);
    if ub0.len == 0 && pg0.len == 0 { return; }
    var b = func_first_block(callee);
    while b >= 0 {
        let ri = block_terminator(b);
        b = block_next(b);
        if iop(ri) != OP_RET || nops(ri) == 0 || !is_inst(op(ri, 0)) || !is_callbase(op(ri, 0)) { continue; }
        let rv = op(ri, 0);
        let nrv = vmm_get(m, rv);
        if nrv < 0 || !is_inst(nrv) || !is_callbase(nrv) { continue; }
        if cci_is_simplified(rv, nrv) { continue; }
        if inst_parent(ri) != inst_parent(rv) || may_contain_throwing_after(rv, ri) { continue; }
        var ub: i32[>..<] = [];
        var pg: i32[>..<] = [];
        valid_ub_attrs(cb, ub);
        valid_pg_attrs(cb, pg);
        let al = cb_ret_set(nrv);
        if list_int(ub, AK_Dereferenceable) < aset_int_of(al, AK_Dereferenceable) { list_remove(ub, AK_Dereferenceable); }
        if list_int(ub, AK_DereferenceableOrNull) < aset_int_of(al, AK_DereferenceableOrNull) { list_remove(ub, AK_DereferenceableOrNull); }
        var nal = al;
        for a in ub { nal = aset_put(nal, a); }
        if max(list_int(pg, AK_Alignment), 1) < max(aset_int_of(al, AK_Alignment), 1) { list_remove(pg, AK_Alignment); }
        if pg.len > 0 {
            let rk = list_find(pg, AK_Range);
            if rk >= 0 {
                let nr = aset_find(al, AK_Range);
                if nr >= 0 { pg[rk] = range_attr_of(rg_intersect(range_of_attr(pg[rk]), range_of_attr(nr))); }
            }
            let fk = list_find(pg, AK_NoFPClass);
            if fk >= 0 && aset_has(al, AK_NoFPClass) { pg[fk] = attr_int(AK_NoFPClass, attrs[pg[fk]].i1 | aset_int_of(al, AK_NoFPClass)); }
            if cb_has_ret_attr(cb, AK_NoUndef) || (if_has_one_use(rv) && !cb_has_ret_attr(rv, AK_NoUndef)) {
                for a in pg { nal = aset_put(nal, a); }
            }
        }
        cb_set_ret_set(nrv, nal);
    }
}
fn if_has_one_use(v: i32) -> bool { let u = first_use(v); u >= 0 && use_next(u) < 0 }

// ---------------------------------------------------------------------------------------------
// Builders

// a call of intrinsic `id` (overloaded on `ov`) inserted before `before` (before = -1: at the end of `bb`)
fn if_intrinsic_call(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:], before: i32, bb: i32) -> i32 {
    return if_intrinsic_call_at(id, ov, argsv, name, before, bb, false);
}
// head: the insertion point is an iterator with the head bit (BB->begin()): before `before`'s debug records
fn if_intrinsic_call_at(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:], before: i32, bb: i32, head: bool) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let ci = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(ci)].ty2 = fty;
    if before >= 0 {
        if head { inst_insert_before_head(ci, before); } else { inst_insert_before(ci, before); }
        if_copy_dbg_loc_builder(ci, before);
    } else { block_append_inst(bb, ci); }
    if name.len > 0 { set_name(ci, name); }
    return ci;
}
fn if_align_set(a: u64) -> i32 { if a <= 1 && a == 0 { 0 } else { aset_get([attr_int(AK_Alignment, a)]) } }

// CreateAlignmentAssumption(DL, Ptr, Alignment) before cb
fn create_alignment_assumption(p: i32, al: u64, before: i32) -> i32 {
    let f = au_get_declaration(IID_assume, []);
    let ci = create_inst(OP_CALL, T_VOID, [c_true(), p, c_int(T_I64, al as! i64), f]);
    insts[inst_of(ci)].ty2 = globs[glob_of(f)].vty;
    cb_set_bundles(ci, 1, [intern("align"), 2], 0);
    inst_insert_before(ci, before);
    if_copy_dbg_loc_builder(ci, before);
    return ci;
}

// ---------------------------------------------------------------------------------------------
// byval arguments

fn cb_param_byval_type(c: i32, k: i64) -> i32 {
    let a = cb_param_attr(c, k, AK_ByVal);
    if a >= 0 { return attrs[a].ty; }
    return -1;
}

// HandleByValArgument -> the value to use for the argument
fn handle_byval_argument(bty: i32, arg: i32, cb: i32, callee: i32, byval_align: u64) -> i32 {
    let caller = inst_func(cb);
    if me_only_reads(fn_memory_effects(callee)) {
        if max(byval_align, 1) == 1 { return arg; }
        if (ic::lsa_get_or_enforce_known_alignment(arg, byval_align as i64, cb) as u64) >= byval_align { return arg; }
    }
    var al = dl_align(bty, false) as u64;
    if byval_align > al { al = byval_align; }
    let ai = create_inst(OP_ALLOCA, ty_ptr(ptr_as(vals[arg].ty)), [c_int(T_I32, 1)]);
    insts[inst_of(ai)].ty2 = bty;
    insts[inst_of(ai)].align = (log2_ceil(al as i64) + 1) as u8;
    insts[inst_of(ai)].as_ = ptr_as(vals[arg].ty) as i32;
    let entry = func_entry(caller);
    // NewAlloca->insertBefore(Caller->begin()->begin()): the head bit puts it in front of the entry's records
    inst_insert_at(ai, entry, block_first(entry), true);
    if vals[arg].name >= 0 { var nm: u8[>..] = []; nm.append(val_name(arg)); set_name(ai, nm); }
    ifi_static_allocas.push(ai);
    return ai;
}
// HandleByValArgumentInit: memcpy at the start of the inlined code
fn handle_byval_argument_init(bty: i32, dst: i32, src: i32, src_align: u64, bb: i32, callee: i32) {
    let size = c_int(T_I64, dl_store_size(bty) as i64);
    kb_cxt = -1;
    let dal = pointer_alignment(dst) as u64;
    let first = block_first(bb);
    let fl = c_false();
    let t1: i32 = vals[dst].ty;
    let t2: i32 = vals[src].ty;
    // IRBuilder<> Builder(InsertBlock, InsertBlock->begin()): head bit, in front of the block's first records
    let ci = if_intrinsic_call_at(IID_memcpy, [t1, t2, T_I64], [dst, src, size, fl], "", first, bb, true);
    var sets: i32[>..<] = [0, 0, if_align_set(dal), if_align_set(src_align)];
    insts[inst_of(ci)].attrs = alist_get(sets);
    let sp = func_subprogram(inst_func(ci));
    if inst_get_md(ci, 0) < 0 && sp >= 0 {
        let csp = func_subprogram(callee);
        if csp >= 0 { inst_set_md(ci, 0, if_dil(0, 0, csp, -1, false, false)); }
    }
}
// AddAlignmentAssumptions
fn add_alignment_assumptions(cb: i32, callee: i32) {
    if !flag_bool("preserve-alignment-assumptions-during-inlining", false) { return; }
    let caller = inst_func(cb);
    var dt_done = false;
    for k in func_nargs(callee) {
        let a = func_arg(callee, k);
        if ty_kind(vals[a].ty) != TK_PTR || ml_arg_has(a, AK_ByVal) || ml_arg_has(a, AK_InAlloca) || ml_arg_has(a, AK_Preallocated) || first_use(a) < 0 { continue; }
        let al = ml_arg_int(a, AK_Alignment);
        if al == 0 { continue; }
        if !dt_done { dt_invalidate(caller, DT_DOM); dt_get(caller, DT_DOM); dt_done = true; }
        let av = cb_arg(cb, k);
        if (ic::lsa_get_or_enforce_known_alignment(av, 0, cb) as u64) >= al { continue; }
        let asm = create_alignment_assumption(av, al, cb);
        ia_register_assumption(caller, asm);
    }
    if dt_done { dt_invalidate(caller, DT_DOM); }
}

// isUsedByLifetimeMarker / hasLifetimeMarkers
fn has_lifetime_markers(ai: i32) -> bool {
    var u = first_use(ai);
    while u >= 0 {
        let us = uses[u].user;
        let id = inst_iid(us);
        if id == IID_lifetime_start || id == IID_lifetime_end { return true; }
        u = use_next(u);
    }
    return false;
}

// changeToInvokeAndSplitBasicBlock(CI, UnwindEdge) -> the split block
fn change_to_invoke_and_split(ci: i32, unwind: i32) -> i32 {
    let bb = inst_parent(ci);
    var nm: u8[>..] = [];
    nm.append(val_name(ci));
    nm.append(".noexc");
    let split = split_block(bb, ci, nm);
    inst_erase_from_parent(block_last(bb));
    let n = nops(ci);
    var opsv: i32[>..<] = [];
    for k in n - 1 { opsv.push(op(ci, k)); }
    opsv.push(split);
    opsv.push(unwind);
    opsv.push(op(ci, n - 1));
    let ii = create_inst(OP_INVOKE, vals[ci].ty, opsv);
    let x = inst_of(ii);
    let src = insts[inst_of(ci)];
    insts[x].cc = src.cc;
    insts[x].attrs = src.attrs;
    insts[x].ty2 = src.ty2;
    insts[x].fmf = src.fmf;
    let nb = cb_nbundles(ci);
    if nb > 0 {
        var pairs: i32[>..<] = [];
        for k in nb { pairs.push(cb_bundle_tag(ci, k)); pairs.push(cb_bundle_count(ci, k) as i32); }
        cb_set_bundles(ii, cb_bundle_begin(ci, 0), pairs, 0);
    }
    block_append_inst(bb, ii);
    let dl = inst_get_md(ci, 0);
    if dl >= 0 { inst_set_md(ii, 0, dl); }
    let pr = inst_get_md(ci, MDK_PROF);
    if pr >= 0 { inst_set_md(ii, MDK_PROF, pr); }
    if vals[ci].name >= 0 { var cn: u8[>..] = []; cn.append(val_name(ci)); set_name(ii, cn); }
    rauw(ci, ii);
    inst_erase_from_parent(ci);
    return split;
}

// ---------------------------------------------------------------------------------------------
// Landing-pad EH (LandingPadInliningInfo)

var lp_outer_dest: i32 = -1;
var lp_inner_dest: i32 = -1;
var lp_caller_lpad: i32 = -1;
var lp_inner_eh_phi: i32 = -1;
var lp_phi_vals: i32[>..<];

fn lp_init(ii: i32) {
    lp_outer_dest = invoke_unwind_dest(ii);
    lp_inner_dest = -1;
    lp_inner_eh_phi = -1;
    lp_phi_vals.resize(0);
    let ib = inst_parent(ii);
    var i = block_first(lp_outer_dest);
    while iop(i) == OP_PHI {
        lp_phi_vals.push(phi_value(i, phi_block_index(i, ib)));
        i = inst_next(i);
    }
    lp_caller_lpad = i;
}
fn lp_add_incoming_into(src: i32, dest: i32) {
    var i = block_first(dest);
    for v in lp_phi_vals { phi_add_incoming(i, v, src); i = inst_next(i); }
}
fn lp_inner_resume_dest() -> i32 {
    if lp_inner_dest >= 0 { return lp_inner_dest; }
    var nm: u8[>..] = [];
    nm.append(val_name(lp_outer_dest));
    nm.append(".body");
    lp_inner_dest = split_block(lp_outer_dest, inst_next(lp_caller_lpad), nm);
    var ins = block_first(lp_inner_dest);
    var i = block_first(lp_outer_dest);
    for k in lp_phi_vals.len {
        let outer = i;
        i = inst_next(i);
        let inner = create_inst(OP_PHI, vals[outer].ty, []);
        if_phi_reserve(inner, 2);
        inst_insert_at(inner, lp_inner_dest, ins, false);
        var nm2: u8[>..] = [];
        nm2.append(val_name(outer));
        nm2.append(".lpad-body");
        set_name(inner, nm2);
        rauw(outer, inner);
        phi_add_incoming(inner, outer, lp_outer_dest);
    }
    let eh = create_inst(OP_PHI, vals[lp_caller_lpad].ty, []);
    if_phi_reserve(eh, 2);
    inst_insert_at(eh, lp_inner_dest, ins, false);
    set_name(eh, "eh.lpad-body");
    rauw(lp_caller_lpad, eh);
    phi_add_incoming(eh, lp_caller_lpad, lp_outer_dest);
    lp_inner_eh_phi = eh;
    return lp_inner_dest;
}
fn if_phi_reserve(p: i32, n: i64) { if (vals[p].cap as i64) < n { grow_ops(p, n); } }
fn lp_forward_resume(ri: i32) {
    let dest = lp_inner_resume_dest();
    let src = inst_parent(ri);
    let br = create_inst(OP_BR, T_VOID, [dest]);
    block_append_inst(src, br);
    let dl = inst_get_md(ri, 0);
    if dl >= 0 { inst_set_md(br, 0, dl); }
    lp_add_incoming_into(src, dest);
    phi_add_incoming(lp_inner_eh_phi, op(ri, 0), src);
    inst_erase_from_parent(ri);
}
// HandleCallsInBlockInlinedThroughInvoke
fn handle_calls_through_invoke(bb: i32, unwind: i32, funclet_map: bool) -> i32 {
    var i = block_first(bb);
    while i >= 0 {
        let ci = i;
        i = inst_next(i);
        if iop(ci) != OP_CALL || call_has_fn_attr(ci, AK_NoUnwind) { continue; }
        let f = called_function(ci);
        if f >= 0 {
            let id = func_iid(f);
            if id == IID_experimental_deoptimize || id == IID_experimental_guard { continue; }
        }
        if funclet_map {
            // A call nested inside a funclet that has an unwind destination within the inlinee stays a call.
            var skip = false;
            for k in cb_nbundles(ci) {
                if sbytes(cb_bundle_tag(ci, k)) == "funclet" {
                    let t = get_unwind_dest_token(op(ci, cb_bundle_begin(ci, k)));
                    skip = t >= 0 && !is_token_none(t);
                    break;
                }
            }
            if skip { continue; }
        } else {
            for k in cb_nbundles(ci) { if sbytes(cb_bundle_tag(ci, k)) == "funclet" { fatal("internal: a funclet call inlined through a landingpad invoke"); } }
        }
        let was_indirect = cci_indirect_remove(ci);
        change_to_invoke_and_split(ci, unwind);
        if was_indirect { cci_orig_indirect.push(block_terminator(bb)); }
        return bb;
    }
    return -1;
}
// HandleInlinedLandingPad
fn handle_inlined_landing_pad(ii: i32, first: i32) {
    let invoke_dest = invoke_unwind_dest(ii);
    lp_init(ii);
    var lpads: i32[>..<] = [];
    var b = first;
    while b >= 0 {
        let t = block_terminator(b);
        if iop(t) == OP_INVOKE {
            let lp = first_non_phi(invoke_unwind_dest(t));
            var seen = false;
            for x in lpads { if x == lp { seen = true; } }
            if !seen { lpads.push(lp); }
        }
        b = block_next(b);
    }
    let outer = lp_caller_lpad;
    for lp in lpads {
        let n = nops(outer);
        for k in n { if_lpad_add_clause(lp, op(outer, k)); }
        if (insts[inst_of(outer)].bits & 1) != 0 { insts[inst_of(lp)].bits |= 1; }
    }
    b = first;
    while b >= 0 {
        if cci_contains_calls {
            let nb = handle_calls_through_invoke(b, lp_outer_dest, false);
            if nb >= 0 { lp_add_incoming_into(nb, lp_outer_dest); }
        }
        let t = block_terminator(b);
        if iop(t) == OP_RESUME { lp_forward_resume(t); }
        b = block_next(b);
    }
    block_remove_predecessor(invoke_dest, inst_parent(ii), false);
}
// HandleInlinedEHPad: the inlined code's "unwind to caller" edges go to the invoke's EH ehp destination
fn eh_update_phis(ud: i32, pvals: const i32[:], src: i32) {
    var i = block_first(ud);
    for v in pvals { phi_add_incoming(i, v, src); i = inst_next(i); }
}
fn handle_inlined_eh_pad(ii: i32, first: i32) {
    let ud = invoke_unwind_dest(ii);
    let caller = block_func(first);
    let invoke_bb = inst_parent(ii);
    var pvals: i32[>..<] = [];
    var i = block_first(ud);
    while i >= 0 && iop(i) == OP_PHI { pvals.push(phi_value_for_block(i, invoke_bb)); i = inst_next(i); }
    uw_memo_reset();
    var b = first;
    while b >= 0 {
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_CLEANUPRET && cleanupret_unwinds_to_caller(t) {
            let ehp = op(t, 0);
            let ncr = create_inst(OP_CLEANUPRET, T_VOID, [ehp, ud]);
            inst_insert_before(ncr, t);
            inst_erase_from_parent(t);
            eh_update_phis(ud, pvals, b);
            uw_memo_set(ehp, token_none());
        }
        let fi = first_non_phi(b);
        if fi < 0 || !inst_is_eh_pad(fi) { b = block_next(b); continue; }
        var repl: i32 = -1;
        if iop(fi) == OP_CATCHSWITCH {
            if catchswitch_unwinds_to_caller(fi) {
                var tok: i32 = -1;
                var skip = false;
                let pp = eh_parent_pad(fi);
                if is_inst(pp) {
                    tok = get_unwind_dest_token(pp);
                    skip = tok >= 0 && !is_token_none(tok);
                } else { tok = token_none(); }
                if !skip {
                    let first_h = catchswitch_first_handler(fi);
                    let nh = nops(fi) - first_h;
                    let ncs = new_inst(OP_CATCHSWITCH, T_TOKEN, nh + 2);
                    set_op(ncs, 0, pp);
                    set_op(ncs, 1, ud);
                    insts[inst_of(ncs)].bits = 1;
                    for k in nh { set_op(ncs, 2 + k, op(fi, first_h + k)); }
                    inst_insert_before(ncs, fi);
                    if vals[fi].name >= 0 { set_name_from(ncs, fi); }   // CatchSwitchInst::Create(..., getName(), ...)
                    uw_memo_set(ncs, tok);
                    repl = ncs;
                }
            }
        } else if iop(fi) == OP_LANDINGPAD { fatal("internal: unexpected EHPad"); }
        if repl >= 0 {
            cu_take_name(repl, fi);
            rauw(fi, repl);
            inst_erase_from_parent(fi);
            eh_update_phis(ud, pvals, b);
        }
        b = block_next(b);
    }
    if cci_contains_calls {
        b = first;
        while b >= 0 {
            let nb = handle_calls_through_invoke(b, ud, true);
            if nb >= 0 { eh_update_phis(ud, pvals, nb); }
            b = block_next(b);
        }
    }
    block_remove_predecessor(ud, invoke_bb, false);
}

// PropagateOperandBundles: inlined call sites get the call site's "funclet" bundle
fn propagate_funclet_bundles(bb: i32, ehp: i32) {
    var i = block_first(bb);
    while i >= 0 {
        let c = i;
        i = inst_next(i);
        if !is_callbase(c) { continue; }
        var has = false;
        for k in cb_nbundles(c) { if sbytes(cb_bundle_tag(c, k)) == "funclet" { has = true; } }
        if has { continue; }
        let cf = fa_strip_pointer_casts(cb_callee(c));
        if is_func(cf) && if_is_intrinsic(cf) && call_has_fn_attr(c, AK_NoUnwind) && !if_may_lower_to_function_call(func_iid(cf)) { continue; }
        var pairs: i32[>..<] = [];
        var bops: i32[>..<] = [];
        for k in cb_nbundles(c) {
            let bb0 = cb_bundle_begin(c, k);
            for j in cb_bundle_count(c, k) { bops.push(op(c, bb0 + j)); }
            pairs.push(cb_bundle_tag(c, k));
            pairs.push(cb_bundle_count(c, k) as i32);
        }
        pairs.push(intern("funclet"));
        pairs.push(1);
        bops.push(ehp);
        let ni = if_recreate_with_bundles(c, pairs, bops);
        cu_take_name(ni, c);
        rauw(c, ni);
        inst_erase_from_parent(c);
    }
}
// IntrinsicInst::mayLowerToFunctionCall
fn if_may_lower_to_function_call(id: i64) -> bool {
    return id == IID_objc_autorelease || id == IID_objc_autoreleasePoolPop || id == IID_objc_autoreleasePoolPush ||
        id == IID_objc_autoreleaseReturnValue || id == IID_objc_claimAutoreleasedReturnValue || id == IID_objc_copyWeak ||
        id == IID_objc_destroyWeak || id == IID_objc_initWeak || id == IID_objc_loadWeak || id == IID_objc_loadWeakRetained ||
        id == IID_objc_moveWeak || id == IID_objc_release || id == IID_objc_retain || id == IID_objc_retainAutorelease ||
        id == IID_objc_retainAutoreleaseReturnValue || id == IID_objc_retainAutoreleasedReturnValue ||
        id == IID_objc_retainBlock || id == IID_objc_storeStrong || id == IID_objc_storeWeak ||
        id == IID_objc_unsafeClaimAutoreleasedReturnValue || id == IID_objc_retainedObject ||
        id == IID_objc_unretainedObject || id == IID_objc_unretainedPointer || id == IID_objc_retain_autorelease ||
        id == IID_objc_sync_enter || id == IID_objc_sync_exit;
}

// ---------------------------------------------------------------------------------------------
// ObjC ARC: inlineRetainOrClaimRVCalls (llvm/Analysis/ObjCARCUtil.h, ObjCARCAnalysisUtils.h, ObjCARCInstKind.cpp)

// objcarc::IsForwarding(GetBasicARCInstKind(V)): a direct call of a forwarding ARC runtime intrinsic
fn arc_is_forwarding_call(v: i32) -> bool {
    if !is_inst(v) || iop(v) != OP_CALL { return false; }
    let f = called_function(v);
    if f < 0 { return false; }
    let id = func_iid(f);
    return id == IID_objc_retain || id == IID_objc_retainAutoreleasedReturnValue ||
        id == IID_objc_unsafeClaimAutoreleasedReturnValue || id == IID_objc_autorelease ||
        id == IID_objc_autoreleaseReturnValue || id == IID_objc_retainedObject || id == IID_objc_unretainedObject ||
        id == IID_objc_unretainedPointer;
}
// objcarc::GetRCIdentityRoot
fn arc_rc_identity_root(v0: i32) -> i32 {
    var v = v0;
    loop {
        v = fa_strip_pointer_casts(v);
        if !arc_is_forwarding_call(v) { break; }
        v = cb_arg(v, 0);
    }
    return v;
}
// objcarc::getAttachedARCFunction: the "clang.arc.attachedcall" operand (-1 without the bundle)
fn arc_attached_function(c: i32) -> i32 {
    for k in cb_nbundles(c) {
        if sbytes(cb_bundle_tag(c, k)) == "clang.arc.attachedcall" {
            if cb_bundle_count(c, k) == 0 { return -1; }
            return op(c, cb_bundle_begin(c, k));
        }
    }
    return -1;
}
// Instruction::copyMetadata(SrcInst): !dbg, then every other attachment
fn if_copy_all_metadata(dst: i32, src: i32) {
    let dl = inst_get_md(src, 0);
    if dl >= 0 { inst_set_md(dst, 0, dl); }
    let si = inst_of(src);
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    for k in insts[si].nmd { kinds.push(md_att[insts[si].md + 2 * k]); nodes.push(md_att[insts[si].md + 2 * k + 1]); }
    for k in kinds.len { if kinds[k] != 0 { inst_set_md(dst, kinds[k], nodes[k]); } }
}
fn arc_has_attached_bundle(c: i32) -> bool {
    for k in cb_nbundles(c) { if sbytes(cb_bundle_tag(c, k)) == "clang.arc.attachedcall" { return true; } }
    return false;
}
fn inline_retain_or_claim_rv_calls(cb: i32, is_retain_rv: bool, returns: const i32[:]) {
    for ri in returns {
        let ret_opnd = arc_rc_identity_root(op(ri, 0));
        var insert_retain = is_retain_rv;
        var i = inst_prev(ri);
        while i >= 0 {
            let cur = i;
            i = inst_prev(i);
            if is_cast_op(iop(cur)) { continue; }
            let id = inst_iid(cur);
            if id != 0 {
                if id != IID_objc_autoreleaseReturnValue || has_uses(cur) || arc_rc_identity_root(cb_arg(cur, 0)) != ret_opnd { break; }
                if !is_retain_rv { if_intrinsic_call(IID_objc_release, [], [ret_opnd], "", cur, -1); }
                inst_erase_from_parent(cur);
                insert_retain = false;
                break;
            }
            if iop(cur) != OP_CALL { break; }
            if arc_rc_identity_root(cur) != ret_opnd || arc_has_attached_bundle(cur) { break; }
            // An unannotated call that defines RetOpnd gets a "clang.arc.attachedcall" bundle
            // (CallBase::addOperandBundle: CallBase::Create keeps the name, uniqued while the old call lives).
            var pairs: i32[>..<] = [];
            var bops: i32[>..<] = [];
            for k in cb_nbundles(cur) {
                let b0 = cb_bundle_begin(cur, k);
                for j in cb_bundle_count(cur, k) { bops.push(op(cur, b0 + j)); }
                pairs.push(cb_bundle_tag(cur, k));
                pairs.push(cb_bundle_count(cur, k) as i32);
            }
            pairs.push(intern("clang.arc.attachedcall"));
            pairs.push(1);
            bops.push(arc_attached_function(cb));
            let nc = if_recreate_with_bundles(cur, pairs, bops);
            if_copy_all_metadata(nc, cur);
            rauw(cur, nc);
            inst_erase_from_parent(cur);
            insert_retain = false;
            break;
        }
        if insert_retain { if_intrinsic_call(IID_objc_retain, [], [ret_opnd], "", ri, -1); }
    }
}

// LandingPadInst::addClause (growOperands: capacity (n + 1) * 2 when full, like the parser)
fn if_lpad_add_clause(lp: i32, c: i32) {
    let e = nops(lp);
    if vals[lp].cap as i64 < e + 1 { grow_ops(lp, max(e, 1) * 2); }
    vals[lp].nops = (e + 1) as i32;
    set_op(lp, e, c);
}

// ---------------------------------------------------------------------------------------------
// mergeAttributesForInlining

fn fn_str_attr(f: i32, key: const u8[:]) -> i32 { aset_find_str(alist_fn(func_attrs(f)), key) }
fn fn_str_is_true(f: i32, key: const u8[:]) -> bool { let a = fn_str_attr(f, key); a >= 0 && attrs[a].sval >= 0 && sbytes(attrs[a].sval) == "true" }
fn fn_set_str(f: i32, a: i32) {
    let s = fn_aset(f, 0);
    var xs: i32[>..<] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind == 0 && attrs[x].skey == attrs[a].skey { continue; } xs.push(x); }
    xs.push(a);
    fn_set_aset(f, 0, aset_get(xs));
}
fn fn_remove_str(f: i32, key: const u8[:]) {
    let s = fn_aset(f, 0);
    var xs: i32[>..<] = [];
    var changed = false;
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind == 0 && sbytes(attrs[x].skey) == key { changed = true; continue; } xs.push(x); }
    if changed { fn_set_aset(f, 0, aset_get(xs)); }
}
fn fn_set_strbool(f: i32, key: const u8[:], v: bool) { fn_set_str(f, attr_str(key, if v { "true" } else { "false" }, true)); }
fn fn_set_enum(f: i32, kind: i64, v: bool) {
    if v { if !fn_has(f, 0, kind) { fn_add_attr(f, 0, attr_enum(kind)); } }
    else { let s = fn_aset(f, 0); if aset_has(s, kind) { fn_set_aset(f, 0, aset_without(s, [kind])); } }
}
fn parse_u64_attr(a: i32) -> u64 {
    // StringRef::getAsInteger(0, ...): decimal / 0x hex / 0 octal; an invalid value leaves 0
    let s = sbytes(attrs[a].sval);
    var v: u64 = 0;
    var base: u64 = 10;
    var k: i64 = 0;
    if s.len > 1 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') { base = 16; k = 2; }
    else if s.len > 1 && s[0] == '0' { base = 8; k = 1; }
    while k < s.len {
        let c = s[k];
        var d: u64 = 99;
        if c >= '0' && c <= '9' { d = (c - '0') as u64; }
        else if c >= 'a' && c <= 'f' { d = (c - 'a') as u64 + 10; }
        else if c >= 'A' && c <= 'F' { d = (c - 'A') as u64 + 10; }
        if d >= base { return 0; }
        v = v * base + d;
        k++;
    }
    return v;
}
fn merge_attributes_for_inlining(caller: i32, callee: i32) {
    // setAND<LessPreciseFPMAD>, setAND<NoSignedZerosFPMath>
    for key in ["less-precise-fpmad", "no-signed-zeros-fp-math"] {
        if fn_str_is_true(caller, key) && !fn_str_is_true(callee, key) { fn_set_strbool(caller, key, false); }
    }
    // setOR<NoImplicitFloat>, setOR<NoJumpTables>, setOR<ProfileSampleAccurate>, setOR<SpeculativeLoadHardening>
    if !fn_has(caller, 0, AK_NoImplicitFloat) && fn_has(callee, 0, AK_NoImplicitFloat) { fn_set_enum(caller, AK_NoImplicitFloat, true); }
    for key in ["no-jump-tables", "profile-sample-accurate"] {
        if !fn_str_is_true(caller, key) && fn_str_is_true(callee, key) { fn_set_strbool(caller, key, true); }
    }
    if !fn_has(caller, 0, AK_SpeculativeLoadHardening) && fn_has(callee, 0, AK_SpeculativeLoadHardening) { fn_set_enum(caller, AK_SpeculativeLoadHardening, true); }
    // adjustCallerSSPLevel
    if fn_has(caller, 0, AK_StackProtect) || fn_has(caller, 0, AK_StackProtectStrong) || fn_has(caller, 0, AK_StackProtectReq) {
        if fn_has(callee, 0, AK_StackProtectReq) {
            fn_set_enum(caller, AK_StackProtect, false); fn_set_enum(caller, AK_StackProtectStrong, false);
            fn_set_enum(caller, AK_StackProtectReq, true);
        } else if fn_has(callee, 0, AK_StackProtectStrong) && !fn_has(caller, 0, AK_StackProtectReq) {
            fn_set_enum(caller, AK_StackProtect, false); fn_set_enum(caller, AK_StackProtectReq, false);
            fn_set_enum(caller, AK_StackProtectStrong, true);
        } else if fn_has(callee, 0, AK_StackProtect) && !fn_has(caller, 0, AK_StackProtectReq) && !fn_has(caller, 0, AK_StackProtectStrong) {
            fn_set_enum(caller, AK_StackProtect, true);
        }
    }
    // adjustCallerStackProbes
    let ps = fn_str_attr(callee, "probe-stack");
    if fn_str_attr(caller, "probe-stack") < 0 && ps >= 0 { fn_set_str(caller, ps); }
    // adjustCallerStackProbeSize
    let ce = fn_str_attr(callee, "stack-probe-size");
    if ce >= 0 {
        let cr = fn_str_attr(caller, "stack-probe-size");
        if cr >= 0 { if parse_u64_attr(cr) > parse_u64_attr(ce) { fn_set_str(caller, ce); } }
        else { fn_set_str(caller, ce); }
    }
    // adjustMinLegalVectorWidth
    let cw = fn_str_attr(caller, "min-legal-vector-width");
    if cw >= 0 {
        let ew = fn_str_attr(callee, "min-legal-vector-width");
        if ew >= 0 { if parse_u64_attr(cw) < parse_u64_attr(ew) { fn_set_str(caller, ew); } }
        else { fn_remove_str(caller, "min-legal-vector-width"); }
    }
    // adjustNullPointerValidAttr
    if fn_has(callee, 0, AK_NullPointerIsValid) && !fn_has(caller, 0, AK_NullPointerIsValid) { fn_set_enum(caller, AK_NullPointerIsValid, true); }
    // setAND<MustProgress>
    if fn_has(caller, 0, AK_MustProgress) && !fn_has(callee, 0, AK_MustProgress) { fn_set_enum(caller, AK_MustProgress, false); }
}

// ---------------------------------------------------------------------------------------------
// InlineFunction

// Instruction::getTerminatingMustTailCall / getTerminatingDeoptimizeCall of a block ending in `ret`
fn if_is_intrinsic(f: i32) -> bool { func_iid(f) != 0 || starts_with(val_name(f), "llvm.") }

// BasicBlock::getTerminatingDeoptimizeCall
fn block_terminating_deoptimize_call(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_RET || block_first(bb) == t { return -1; }
    let p = inst_prev(t);
    if p >= 0 && iop(p) == OP_CALL {
        let f = called_function(p);
        if f >= 0 && func_iid(f) == IID_experimental_deoptimize { return p; }
    }
    return -1;
}

// CallBase::Create(CB, Bundles, InsertPt): a copy of call/invoke `c` with the bundles (tag, operands) given as
// pairs (tag, count) and their operands, inserted before c. Other metadata is not copied.
fn if_recreate_with_bundles(c: i32, pairs: const i32[:], bops: const i32[:]) -> i32 {
    let na = cb_nargs(c);
    var opsv: i32[>..<] = [];
    for k in na { opsv.push(cb_arg(c, k)); }
    for v in bops { opsv.push(v); }
    if iop(c) == OP_INVOKE { opsv.push(invoke_normal_dest(c)); opsv.push(invoke_unwind_dest(c)); }
    else if iop(c) != OP_CALL { if_not_ported("re-creating a callbr with new operand bundles"); }
    opsv.push(cb_callee(c));
    let nc = create_inst(iop(c), vals[c].ty, opsv);
    let ni = inst_of(nc);
    let oi = inst_of(c);
    insts[ni].ty2 = insts[oi].ty2;
    insts[ni].pred = insts[oi].pred;
    insts[ni].cc = insts[oi].cc;
    insts[ni].fmf = insts[oi].fmf;
    insts[ni].flags = insts[oi].flags;
    insts[ni].attrs = insts[oi].attrs;
    cb_set_bundles(nc, na, pairs, 0);
    inst_insert_before(nc, c);
    if vals[c].name >= 0 { var nm: u8[>..] = []; nm.append(val_name(c)); set_name(nc, nm); }
    let dl = inst_get_md(c, 0);
    if dl >= 0 { inst_set_md(nc, 0, dl); }
    return nc;
}

// The parent's "deopt" continuation is prepended to the inlined calls' deopt bundles
fn merge_parent_deopt_bundles(cb: i32) {
    var pk: i64 = -1;
    for k in cb_nbundles(cb) { if sbytes(cb_bundle_tag(cb, k)) == "deopt" { pk = k; break; } }
    if pk < 0 { return; }
    for h in cci_bundle_sites {
        let ics = wvh_get(h);
        if ics < 0 || is_dead(ics) || !is_inst(ics) || !is_callbase(ics) { continue; }
        var pairs: i32[>..<] = [];
        var bops: i32[>..<] = [];
        for k in cb_nbundles(ics) {
            let t = cb_bundle_tag(ics, k);
            var n: i64 = 0;
            if sbytes(t) == "deopt" {
                let pb = cb_bundle_begin(cb, pk);
                for j in cb_bundle_count(cb, pk) { bops.push(op(cb, pb + j)); n++; }
            }
            let b = cb_bundle_begin(ics, k);
            for j in cb_bundle_count(ics, k) { bops.push(op(ics, b + j)); n++; }
            pairs.push(t);
            pairs.push(n as i32);
        }
        let ni = if_recreate_with_bundles(ics, pairs, bops);
        rauw(ics, ni);
        wvh_set(h, -1);
        inst_erase_from_parent(ics);
    }
}

// InlinedDeoptimizeCalls: the deoptimizing returns leave the Return set; with a different caller return type the
// deoptimize calls are re-created with the caller's return type.
fn rewrite_deoptimize_returns(cb: i32, caller: i32, returns: i32[>..<]&) {
    let crt = ty_fn_ret(globs[glob_of(caller)].vty);
    var normal: i32[>..<] = [];
    if crt == vals[cb].ty {
        for ri in returns { if block_terminating_deoptimize_call(inst_parent(ri)) < 0 { normal.push(ri); } }
    } else {
        let nd = au_get_declaration(IID_experimental_deoptimize, [crt]);
        for ri in returns {
            let dc = block_terminating_deoptimize_call(inst_parent(ri));
            if dc < 0 { normal.push(ri); continue; }
            let ccv = globs[glob_of(called_function(dc))].cc;
            globs[glob_of(nd)].cc = ccv;
            let cur = inst_parent(ri);
            inst_erase_from_parent(ri);
            var opsv: i32[>..<] = [];
            for k in cb_nargs(dc) { opsv.push(cb_arg(dc, k)); }
            var pairs: i32[>..<] = [];
            for k in cb_nbundles(dc) {
                let b = cb_bundle_begin(dc, k);
                for j in cb_bundle_count(dc, k) { opsv.push(op(dc, b + j)); }
                pairs.push(cb_bundle_tag(dc, k));
                pairs.push(cb_bundle_count(dc, k) as i32);
            }
            let na = cb_nargs(dc);
            let dattrs = insts[inst_of(dc)].attrs;
            inst_erase_from_parent(dc);
            opsv.push(nd);
            let nc = create_inst(OP_CALL, crt, opsv);
            insts[inst_of(nc)].ty2 = globs[glob_of(nd)].vty;
            insts[inst_of(nc)].cc = ccv;
            insts[inst_of(nc)].attrs = dattrs;
            cb_set_bundles(nc, na, pairs, 0);
            block_append_inst(cur, nc);
            let r = if crt == T_VOID { create_inst(OP_RET, T_VOID, []) } else { create_inst(OP_RET, T_VOID, [nc]) };
            block_append_inst(cur, r);
            cb_set_ret_set(nc, ic::aset_remove_incompatible(crt, cb_ret_set(nc), 3));
        }
    }
    returns.resize(0);
    for r in normal { returns.push(r); }
}

fn block_terminating_musttail(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || iop(t) != OP_RET { return -1; }
    var p = inst_prev(t);
    if p >= 0 && iop(p) == OP_BITCAST { p = inst_prev(p); }
    if p >= 0 && iop(p) == OP_CALL && insts[inst_of(p)].pred == 2 { return p; }
    return -1;
}

fn inline_function(cb: i32, merge_attrs: bool, insert_lifetime: bool, track_history: bool, with_psi: bool, with_bfi: bool, aa_fn: i32) -> bool {
    ifi_inlined_call_sites.resize(0);
    ifi_static_allocas.resize(0);
    // InlineFunctionInfo(GetAssumptionCache, PSI, &FAM.getResult<BlockFrequencyAnalysis>(Caller), ...(Callee))
    if with_bfi { bfi_get(inst_func(cb)); let cf = called_function(cb); if cf >= 0 && !func_is_decl(cf) { bfi_get(cf); } }
    if !can_inline_call_site(cb) { return false; }
    let wmark = wvh_mark();
    let vmark = vmm_mark();
    inline_function_impl(cb, merge_attrs, insert_lifetime, track_history, with_psi, with_bfi, aa_fn);
    vmm_release(vmark);
    wvh_release(wmark);
    return true;
}

fn inline_function_impl(cb: i32, merge_attrs: bool, insert_lifetime: bool, track_history: bool, with_psi: bool, with_bfi: bool, aa_fn: i32) {
    let orig_bb = inst_parent(cb);
    let caller = block_func(orig_bb);
    let callee = called_function(cb);
    // Determine if we are dealing with a call in an EHPad which does not unwind to caller.
    var ehpad_unwinds_locally = false;
    if ifi_callsite_ehpad >= 0 && iop(cb) == OP_CALL {
        uw_memo_reset();
        let t = get_unwind_dest_token(ifi_callsite_ehpad);
        ehpad_unwinds_locally = t >= 0 && !is_token_none(t);
    }
    if tli_module_flag_int(globs[glob_of(caller)].module, "debug-info-assignment-tracking") > 0 { if_not_ported("assignment tracking"); }
    let last_block = func_last_block(caller);
    var returns: i32[>..<] = [];
    cci_contains_calls = false;
    cci_contains_memprof = false;
    cci_contains_dynamic_allocas = false;
    cci_bundle_sites.resize(0);
    cci_orig_indirect.resize(0);
    cci_orig_vmap = vmm_new();
    let cg = globs[glob_of(callee)].gc;
    if cg >= 0 && globs[glob_of(caller)].gc < 0 { globs[glob_of(caller)].gc = cg; }
    if globs[glob_of(callee)].has_personality != 0 {
        let cp = fa_strip_pointer_casts(op(callee, 0));
        if globs[glob_of(caller)].has_personality == 0 { if_set_personality(caller, cp); }
    }
    var first_new: i32 = -1;
    {
        let m = vmm_new_tracking();
        var bv_dst: i32[>..<] = [];
        var bv_src: i32[>..<] = [];
        var bv_align: u64[>..<] = [];
        var bv_ty: i32[>..<] = [];
        dc_collect(callee);
        let na = func_nargs(callee);
        for k in na {
            var actual = cb_arg(cb, k);
            if cb_is_byval_arg(cb, k) {
                let bty = cb_param_byval_type(cb, k);
                let nv = handle_byval_argument(bty, actual, cb, callee, aset_int_of(alist_param(func_attrs(callee), k), AK_Alignment));
                if nv != actual {
                    bv_dst.push(nv); bv_src.push(actual);
                    bv_align.push(aset_int_of(cb_param_set(cb, k), AK_Alignment) | (if cb_param_attr(cb, k, AK_Alignment) >= 0 { attrs[cb_param_attr(cb, k, AK_Alignment)].i1 } else { 0 }));
                    bv_ty.push(bty);
                }
                actual = nv;
            }
            vmm_set(m, func_arg(callee, k), actual);
        }
        add_alignment_assumptions(cb, callee);
        if flag_bool("enable-knowledge-retention", false) { salvage_knowledge(cb, true); }
        clone_and_prune_function_into(caller, callee, m, returns);
        first_new = block_next(last_block);
        // Insert retainRV/claimRV runtime calls.
        let arcf = arc_attached_function(cb);
        if arcf >= 0 { inline_retain_or_claim_rv_calls(cb, is_func(arcf) && func_iid(arcf) == IID_objc_retainAutoreleasedReturnValue, returns); }
        // IFI.UpdateProfile (always set here)
        if with_bfi { if_update_caller_bfi(orig_bb, m, callee); }
        if callee_has_entry_count(callee) { if_update_profile(cb, callee, m, orig_bb, with_psi, with_bfi); }
        for j in bv_dst.len { handle_byval_argument_init(bv_ty[j], bv_dst[j], bv_src[j], bv_align[j], first_new, callee); }
        merge_parent_deopt_bundles(cb);
        fixup_line_numbers(caller, first_new, cb, func_subprogram(callee) >= 0);
        dc_clone();
        dc_remap(first_new);
        add_alias_scope_metadata(cb, m, callee, aa_fn);
        add_return_attributes(cb, m, callee);
        add_param_and_fn_basic_attributes(cb, m, callee);
        propagate_memprof_metadata(callee, cb, m);
        propagate_call_site_metadata(cb, first_new);
        propagate_alloc_token_metadata(callee, cb, m);
        let irk = mdk("implicit.ref");
        if func_get_md(callee, irk) >= 0 {
            var irs: i32[>..<] = [];
            let cg = globs[glob_of(callee)];
            for k in cg.nmd { if md_att[cg.md + 2 * k] == irk { irs.push(md_att[cg.md + 2 * k + 1]); } }
            for x in irs { glob_add_md(caller, irk, x); }
        }
        propagate_inlined_from_metadata(cb, callee, caller, first_new);
        var b = first_new;
        while b >= 0 {
            var i = block_first(b);
            while i >= 0 { if inst_iid(i) == IID_assume { ia_register_assumption(caller, i); } i = inst_next(i); }
            b = block_next(b);
        }
    }
    if ifi_convergence_token >= 0 {
        let ic = if_convergence_entry(first_new);
        if ic >= 0 { rauw(ic, ifi_convergence_token); inst_erase_from_parent(ic); }
    }
    // static allocas to the caller's entry block
    {
        let entry = func_entry(caller);
        let insert_pt = block_first(entry);
        var i = block_first(first_new);
        while i >= 0 {
            let ai = i;
            i = inst_next(i);
            if iop(ai) != OP_ALLOCA { continue; }
            if first_use(ai) < 0 { inst_erase_from_parent(ai); continue; }
            if !if_alloca_static_in_entry(ai) { continue; }
            ifi_static_allocas.push(ai);
            var last = ai;
            while i >= 0 && iop(i) == OP_ALLOCA && first_use(i) >= 0 && if_alloca_static_in_entry(i) {
                ifi_static_allocas.push(i);
                last = i;
                i = inst_next(i);
            }
            // Caller->getEntryBlock().splice(InsertPoint, FirstNewBlock, AI, I) with I's tail bit set; InsertPoint
            // is Caller->begin()->begin(), with the head bit: the allocas go in front of the entry's first records
            block_splice(entry, insert_pt, true, first_new, ai, false, i, true);
        }
    }
    let mark_nounwind = call_has_fn_attr(cb, AK_NoUnwind);
    let callee_np = ty_fn_nparams(globs[glob_of(callee)].vty);
    var va_fwd: i32[>..<] = [];
    var va_attrs: i32[>..<] = [];
    for i in callee_np..cb_nargs(cb) { va_fwd.push(cb_arg(cb, i)); va_attrs.push(cb_param_set(cb, i)); }
    var inlined_musttail = false;
    var inlined_deopt = false;
    if cci_contains_calls {
        var site_tk: u8 = 0;
        if iop(cb) == OP_CALL { site_tk = insts[inst_of(cb)].pred; }
        if site_tk == 3 { site_tk = 0; }
        var b = first_new;
        while b >= 0 {
            var i = block_first(b);
            while i >= 0 {
                var ci = i;
                i = inst_next(i);
                if iop(ci) != OP_CALL { continue; }
                if va_fwd.len > 0 && insts[inst_of(ci)].pred == 2 {
                    // forward the call site's varargs (CallInst::Create without a tail kind or name)
                    let al = insts[inst_of(ci)].attrs;
                    let fty = insts[inst_of(ci)].ty2;
                    var sets: i32[>..<] = [alist_fn(al), alist_ret(al)];
                    for k in ty_fn_nparams(fty) { sets.push(alist_param(al, k)); }
                    for x in va_attrs { sets.push(x); }
                    var opsv: i32[>..<] = [];
                    for k in cb_nargs(ci) { opsv.push(cb_arg(ci, k)); }
                    for x in va_fwd { opsv.push(x); }
                    opsv.push(cb_callee(ci));
                    let nc = create_inst(OP_CALL, vals[ci].ty, opsv);
                    insts[inst_of(nc)].ty2 = fty;
                    insts[inst_of(nc)].cc = insts[inst_of(ci)].cc;
                    insts[inst_of(nc)].attrs = alist_get(sets);
                    inst_insert_before(nc, ci);
                    let dl = inst_get_md(ci, 0);
                    if dl >= 0 { inst_set_md(nc, 0, dl); }
                    rauw(ci, nc);
                    inst_erase_from_parent(ci);
                    ci = nc;
                }
                let f = called_function(ci);
                if f >= 0 && func_iid(f) == IID_experimental_deoptimize { inlined_deopt = true; }
                var child = insts[inst_of(ci)].pred;
                if child != 3 { child = if site_tk < child { site_tk } else { child }; }
                insts[inst_of(ci)].pred = child;
                if child == 2 { inlined_musttail = true; }
                if mark_nounwind && !call_has_fn_attr(ci, AK_NoUnwind) { cb_add_fn_attr_enum(ci, AK_NoUnwind); }
            }
            b = block_next(b);
        }
    }
    if insert_lifetime && ifi_static_allocas.len > 0 {
        let first = block_first(first_new);
        for ai in ifi_static_allocas {
            if (insts[inst_of(ai)].bits & 4) != 0 { continue; }   // swifterror
            if has_lifetime_markers(ai) { continue; }
            let sz, known, scal = ml_alloca_size(ai);
            if known && sz == 0 && !scal { continue; }
            if_intrinsic_call_at(IID_lifetime_start, [vals[ai].ty as i32], [ai], "", first, first_new, true);
            for ri in returns {
                if inlined_musttail && block_terminating_musttail(inst_parent(ri)) >= 0 { continue; }
                if inlined_deopt && block_terminating_deoptimize_call(inst_parent(ri)) >= 0 { continue; }
                if_intrinsic_call(IID_lifetime_end, [vals[ai].ty as i32], [ai], "", ri, -1);
            }
        }
    }
    if cci_contains_dynamic_allocas {
        let first = block_first(first_new);
        let pt = ty_ptr(dl_alloca_as());
        let saved = if_intrinsic_call_at(IID_stacksave, [pt], [], "savedstack", first, first_new, true);
        for ri in returns {
            if inlined_musttail && block_terminating_musttail(inst_parent(ri)) >= 0 { continue; }
            if inlined_deopt && block_terminating_deoptimize_call(inst_parent(ri)) >= 0 { continue; }
            if_intrinsic_call(IID_stackrestore, [pt], [saved], "", ri, -1);
        }
    }
    if iop(cb) == OP_INVOKE {
        let ud = invoke_unwind_dest(cb);
        let fnp = first_non_phi(ud);
        if fnp >= 0 && iop(fnp) == OP_LANDINGPAD { handle_inlined_landing_pad(cb, first_new); }
        else { handle_inlined_eh_pad(cb, first_new); }
    }
    // Update the lexical scopes of the new funclets and callsites: anything that had 'none' as its parent is now
    // nested inside the callsite's EHPad.
    if ifi_callsite_ehpad >= 0 {
        var b = first_new;
        while b >= 0 {
            let nb = block_next(b);
            propagate_funclet_bundles(b, ifi_callsite_ehpad);
            let t = block_terminator(b);
            if t >= 0 && iop(t) == OP_CLEANUPRET && cleanupret_unwinds_to_caller(t) && ehpad_unwinds_locally { change_to_unreachable(t, false); }
            let fi = first_non_phi(b);
            if fi >= 0 && inst_is_eh_pad(fi) && iop(fi) != OP_LANDINGPAD {
                if is_token_none(eh_parent_pad(fi)) { eh_set_parent_pad(fi, ifi_callsite_ehpad); }
            }
            b = nb;
        }
    }
    if inlined_deopt { rewrite_deoptimize_returns(cb, caller, returns); }
    if inlined_musttail {
        var normal: i32[>..<] = [];
        for ri in returns { if block_terminating_musttail(inst_parent(ri)) < 0 { normal.push(ri); } }
        returns.resize(0);
        for r in normal { returns.push(r); }
    }
    if cci_contains_calls {
        var b = first_new;
        while b >= 0 {
            var i = block_first(b);
            while i >= 0 {
                if is_callbase(i) {
                    let f = called_function(i);
                    if !(f >= 0 && if_is_intrinsic(f)) { ifi_inlined_call_sites.push(i); }   // Function::isIntrinsic: an llvm.* name
                }
                i = inst_next(i);
            }
            b = block_next(b);
        }
    }
    let ihk = mdk("inline_history");
    for icb in ifi_inlined_call_sites {
        if track_history || cci_indirect_has(icb) {
            var hist: i32[>..] = [];
            hist.push(md_value(callee));
            let h1 = inst_get_md(cb, ihk);
            if h1 >= 0 { for k in mds[h1].nops as i64 { let o = md_op(h1, k); if o >= 0 { hist.push(o); } } }
            let h2 = inst_get_md(icb, ihk);
            if h2 >= 0 { for k in mds[h2].nops as i64 { let o = md_op(h2, k); if o >= 0 { hist.push(o); } } }
            inst_set_md(icb, ihk, md_get(MK_TUPLE, -1, hist, false));
        }
    }
    // a single return block: splice it in place of the call
    if returns.len == 1 && block_next(first_new) < 0 {
        block_splice(orig_bb, cb, false, first_new, block_first(first_new), true, -1, false);
        block_erase(func_last_block(caller));
        if iop(cb) == OP_INVOKE {
            let br = create_inst(OP_BR, T_VOID, [invoke_normal_dest(cb)]);
            inst_insert_before(br, cb);
            let dl = inst_get_md(returns[0], 0);
            if dl >= 0 { inst_set_md(br, 0, dl); }
        }
        if first_use(cb) >= 0 {
            let r = returns[0];
            if cb == op(r, 0) { rauw(cb, c_poison(vals[cb].ty)); } else { rauw(cb, op(r, 0)); }
        }
        inst_erase_from_parent(cb);
        inst_erase_from_parent(returns[0]);
        if merge_attrs { merge_attributes_for_inlining(caller, callee); }
        return;
    }
    var after: i32 = -1;
    var created_br: i32 = -1;
    var nm: u8[>..] = [];
    nm.append(val_name(callee));
    nm.append(".exit");
    if iop(cb) == OP_INVOKE {
        created_br = create_inst(OP_BR, T_VOID, [invoke_normal_dest(cb)]);
        inst_insert_before(created_br, cb);
        after = split_block(orig_bb, created_br, nm);
    } else {
        after = split_block(orig_bb, cb, nm);
    }
    if with_bfi { ifq_set_after(after, orig_bb); }
    let br = block_terminator(orig_bb);
    term_set_succ(br, 0, first_new);
    // Caller->splice(AfterCallBB, Caller, FirstNewBlock, end)
    var b = first_new;
    while b >= 0 { let nb = block_next(b); block_move_before(b, after); b = nb; }
    let rty = ty_fn_ret(globs[glob_of(callee)].vty);
    var phi: i32 = -1;
    if returns.len > 1 {
        if first_use(cb) >= 0 {
            phi = create_inst(OP_PHI, rty, []);
            if_phi_reserve(phi, returns.len);
            inst_insert_at(phi, after, block_first(after), true);
            if vals[cb].name >= 0 { var pn: u8[>..] = []; pn.append(val_name(cb)); set_name(phi, pn); }
            rauw(cb, phi);
        }
        if phi >= 0 { for ri in returns { phi_add_incoming(phi, op(ri, 0), inst_parent(ri)); } }
        var loc: i32 = -1;
        for ri in returns {
            let bi = create_inst(OP_BR, T_VOID, [after]);
            inst_insert_before(bi, ri);
            loc = inst_get_md(ri, 0);
            if loc >= 0 { inst_set_md(bi, 0, loc); }
            inst_erase_from_parent(ri);
        }
        if created_br >= 0 { if loc >= 0 { inst_set_md(created_br, 0, loc); } else { inst_set_md(created_br, 0, -1); } }
    } else if returns.len == 1 {
        if first_use(cb) >= 0 {
            if cb == op(returns[0], 0) { rauw(cb, c_poison(vals[cb].ty)); } else { rauw(cb, op(returns[0], 0)); }
        }
        let rbb = inst_parent(returns[0]);
        cu_block_rauw(rbb, after);
        block_splice(after, block_first(after), true, rbb, block_first(rbb), true, -1, false);
        if created_br >= 0 { let dl = inst_get_md(returns[0], 0); inst_set_md(created_br, 0, dl); }
        inst_erase_from_parent(returns[0]);
        block_erase(rbb);
    } else if first_use(cb) >= 0 {
        if created_br >= 0 { inst_set_md(created_br, 0, -1); }
        rauw(cb, c_poison(vals[cb].ty));
    }
    inst_erase_from_parent(cb);
    if inlined_musttail && pred_count(after) == 0 { block_erase(after); }
    let callee_entry = term_succ(br, 0);
    cu_block_rauw(callee_entry, orig_bb);
    block_splice(orig_bb, br, false, callee_entry, block_first(callee_entry), true, -1, false);
    inst_erase_from_parent(br);
    block_erase(callee_entry);
    if phi >= 0 {
        let v = if_simplify_instruction_ac(phi);
        if v >= 0 {
            rauw(phi, v);
            inst_erase_from_parent(phi);
        }
    }
    if merge_attrs { merge_attributes_for_inlining(caller, callee); }
}
// simplifyInstruction(PHI, {DL, nullptr, nullptr, AC})
fn if_simplify_instruction_ac(i: i32) -> i32 {
    let sdt = sq_no_dt; let stli = sq_no_tli;
    sq_no_dt = true; sq_no_tli = true;
    kb_cxt = -1;
    let r = simplify_instruction(i);
    sq_no_dt = sdt; sq_no_tli = stli;
    return r;
}
fn if_alloca_static_in_entry(ai: i32) -> bool { is_constant(op(ai, 0)) && (insts[inst_of(ai)].bits & 2) == 0 }
fn cb_add_fn_attr_enum(c: i32, kind: i64) {
    let ii = inst_of(c);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 1) {
        var s: i32 = 0;
        if j < n { s = alist_runs[alists[l].at + j]; }
        if j == 0 { s = aset_put(s, attr_enum(kind)); }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}
fn dl_alloca_as() -> i64 { dl_alloca_addr_space }
// Function::setPersonalityFn: the hung-off operands [personality, prefix, prologue] are allocated on first use
fn if_set_personality(f: i32, p: i32) {
    if vals[f].nops < 3 { while vals[f].nops < 3 { add_op_slot(f); } }
    set_op(f, 0, p);
    globs[glob_of(f)].has_personality = 1;
}
fn callee_has_entry_count(f: i32) -> bool { let ok, c = fn_entry_count(f); return ok; }

// uniteAccessGroups (llvm/lib/Analysis/VectorUtils.cpp)
fn unite_access_groups(a: i32, b: i32) -> i32 {
    if a < 0 { return b; }
    if b < 0 { return a; }
    if a == b { return a; }
    var u: i32[>..<] = [];
    for g in [a, b] {
        if mds[g].nops == 0 { var seen = false; for x in u { if x == g { seen = true; } } if !seen { u.push(g); } continue; }
        for k in mds[g].nops as i64 {
            let it = md_op(g, k);
            var seen = false;
            for x in u { if x == it { seen = true; } }
            if !seen { u.push(it); }
        }
    }
    if u.len == 0 { return -1; }
    if u.len == 1 { return u[0]; }
    return md_get(MK_TUPLE, -1, u, false);
}

// PropagateCallSiteMetadata
fn propagate_call_site_metadata(cb: i32, first: i32) {
    var mpla = inst_get_md(cb, MDK_MEM_PARALLEL_LOOP_ACCESS);
    let ag = inst_get_md(cb, MDK_ACCESS_GROUP);
    let asc = inst_get_md(cb, MDK_ALIAS_SCOPE);
    let na = inst_get_md(cb, MDK_NOALIAS);
    if mpla < 0 && ag < 0 && asc < 0 && na < 0 { return; }
    var b = first;
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if inst_may_read_or_write_memory(i) {
                if mpla >= 0 {
                    mpla = md_concatenate(inst_get_md(i, MDK_MEM_PARALLEL_LOOP_ACCESS), mpla);
                    inst_set_md(i, MDK_MEM_PARALLEL_LOOP_ACCESS, mpla);
                }
                if ag >= 0 { inst_set_md(i, MDK_ACCESS_GROUP, unite_access_groups(inst_get_md(i, MDK_ACCESS_GROUP), ag)); }
                if asc >= 0 { inst_set_md(i, MDK_ALIAS_SCOPE, md_concatenate(inst_get_md(i, MDK_ALIAS_SCOPE), asc)); }
                if na >= 0 { inst_set_md(i, MDK_NOALIAS, md_concatenate(inst_get_md(i, MDK_NOALIAS), na)); }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
}

// propagateAllocTokenMetadata
fn propagate_alloc_token_metadata(callee: i32, cb: i32, m: i32) {
    let tk = mdk("alloc_token");
    let md = inst_get_md(cb, tk);
    if md < 0 { return; }
    var calls: i32[>..<] = [];
    var b = func_first_block(callee);
    while b >= 0 {
        let t = block_terminator(b);
        if iop(t) == OP_RET && nops(t) > 0 {
            var wl: i32[>..<] = [op(t, 0)];
            var seen = hm_new();
            while wl.len > 0 {
                let v = wl.pop();
                if ty_kind(vals[v].ty) != TK_PTR || hm_has(seen, (v as i64) as u64) { continue; }
                hm_put(seen, (v as i64) as u64, 1);
                if is_inst(v) && is_callbase(v) { calls.push(v); }
                else if is_inst_op(v, OP_BITCAST) || is_inst_op(v, OP_ADDRSPACECAST) { wl.push(op(v, 0)); }
                else if is_inst_op(v, OP_PHI) { for k in nops(v) { wl.push(op(v, k)); } }
                else if is_inst_op(v, OP_SELECT) { wl.push(op(v, 1)); wl.push(op(v, 2)); }
            }
        }
        b = block_next(b);
    }
    for oc in calls {
        let cc = vmm_get(m, oc);
        if cc < 0 || !is_inst(cc) || !is_callbase(cc) || cci_is_simplified(oc, cc) { continue; }
        if inst_get_md(cc, tk) >= 0 { continue; }
        inst_set_md(cc, tk, md);
    }
}

// PropagateInlinedFromMetadata
fn propagate_inlined_from_metadata(cb: i32, callee: i32, caller: i32, first: i32) {
    let sk = mdk("srcloc");
    var loc: u64 = 0;
    let sm = inst_get_md(cb, sk);
    if sm >= 0 && mds[sm].nops > 0 {
        let o = md_op(sm, 0);
        if o >= 0 && mds[o].kind == MK_VALUE && vals[mds[o].extra].kind == VK_CINT { loc = cint_lo(mds[o].extra); }
    }
    let ik = mdk("inlined.from");
    var b = first;
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if iop(i) == OP_CALL && inst_get_md(i, sk) >= 0 {
                let f = called_function(i);
                if f >= 0 && (aset_find_str(alist_fn(func_attrs(f)), "dontcall-error") >= 0 || aset_find_str(alist_fn(func_attrs(f)), "dontcall-warn") >= 0) {
                    var ops: i32[>..] = [];
                    let ex = inst_get_md(i, ik);
                    if ex >= 0 { for k in mds[ex].nops as i64 { ops.push(md_op(ex, k)); } }
                    else { ops.push(md_string(val_name(callee))); ops.push(md_value(c_int(T_I64, 0))); }
                    ops.push(md_string(val_name(caller)));
                    ops.push(md_value(c_int(T_I64, loc as! i64)));
                    inst_set_md(i, ik, md_get(MK_TUPLE, -1, ops, false));
                }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
}

// ---------------------------------------------------------------------------------------------
// Profile updates (updateCallerBFI / updateCallProfile)

// updateCallerBFI: each block cloned into the caller gets its callee frequency (the maximum when several callee
// blocks map to one clone), then they are scaled so the entry clone gets the call site block's frequency.
fn if_update_caller_bfi(call_bb: i32, m: i32, callee: i32) {
    var cl: i32[>..<] = [];
    var fr: u64[>..<] = [];
    bfi_get(callee);
    var e = vmm_first(m);
    while e >= 0 {
        let k = vmm_ent_key(e);
        let v = vmm_val(e);
        e = vmm_next(e);
        if k < 0 || vals[k].kind != VK_BLOCK || v < 0 || is_dead(v) { continue; }
        let f = bfi_freq(k);
        var found = false;
        for j in cl.len { if cl[j] == v { found = true; if f > fr[j] { fr[j] = f; } } }
        if !found { cl.push(v); fr.push(f); }
    }
    let entry_clone = vmm_get(m, func_entry(callee));
    bfi_get(block_func(call_bb));
    for j in cl.len { bfi_set_freq(cl[j], fr[j]); }
    // setBlockFreqAndScale(EntryClone, getBlockFreq(CallSiteBlock), ClonedBBs)
    let nf = ap_u64(bfi_freq(call_bb), 128);
    let of = ap_u64(bfi_freq(entry_clone), 128);
    if ap_is_zero(of) { if_not_ported("updateCallerBFI with a zero entry frequency"); }
    for b in cl {
        let bf = ap_udiv(ap_mul(ap_u64(bfi_freq(b), 128), nf), of);
        bfi_set_freq(b, ap_limited(bf, 0xFFFFFFFFFFFFFFFF));
    }
    bfi_set_freq(entry_clone, bfi_freq(call_bb));
}

// Copy original BB's block frequency to AfterCallBB (in the caller's cached BFI)
fn ifq_set_after(after: i32, orig: i32) {
    bfi_get(block_func(orig));
    bfi_set_freq(after, bfi_freq(orig));
}
// updateCallProfile
fn if_update_profile(cb: i32, callee: i32, m: i32, orig_bb: i32, with_psi: bool, with_bfi: bool) {
    let ok, cec = fn_entry_count(callee);
    if !ok || cec < 1 { return; }
    var cs: u64 = 0;
    if with_psi {
        if with_bfi { bfi_get(inst_func(cb)); }
        let pok, pc = psi_profile_count(cb, with_bfi);
        if pok { cs = pc; }
    }
    let cc = if cs < cec { cs } else { cec };
    update_profile_callee(callee, -(cc as! i64), m);
}

// llvm::updateProfileCallee(Callee, EntryDelta, VMap); m = -1: no VMap
fn update_profile_callee(callee: i32, delta: i64, m: i32) {
    let ok, cc = fn_entry_count(callee);
    if !ok { return; }
    let nec: u64 = if delta < 0 && ((-delta) as! u64) > cc { 0 } else { cc + (delta as! u64) };
    if m >= 0 {
        let clone_ec = cc - nec;
        var e = vmm_first(m);
        while e >= 0 {
            let k = vmm_ent_key(e);
            let v = vmm_val(e);
            e = vmm_next(e);
            if k < 0 || !is_inst(k) || v < 0 || is_dead(v) || !is_inst(v) { continue; }
            if (iop(k) == OP_CALL && iop(v) == OP_CALL) || (iop(k) == OP_INVOKE && iop(v) == OP_INVOKE) {
                if_update_prof_weight(v, clone_ec, cc);
                if_update_vtable_prof_weight(v, clone_ec, cc);
            }
        }
    }
    if delta != 0 {
        fn_set_entry_count(callee, nec);
        var b = func_first_block(callee);
        while b >= 0 {
            if m < 0 || vmm_find(m, b) >= 0 {
                var i = block_first(b);
                while i >= 0 {
                    if iop(i) == OP_CALL || iop(i) == OP_INVOKE {
                        if_update_prof_weight(i, nec, cc);
                        if_update_vtable_prof_weight(i, nec, cc);
                    }
                    i = inst_next(i);
                }
            }
            b = block_next(b);
        }
    }
}
// CallInst / InvokeInst::updateProfWeight(S, T)
fn if_update_prof_weight(i: i32, sv: u64, tv: u64) {
    if tv == 0 { return; }
    if_scale_prof_data(i, sv, tv);
}
fn if_update_vtable_prof_weight(cb: i32, sv: u64, tv: u64) {
    let vp = try_get_vtable_instruction(cb);
    if vp >= 0 { if_scale_prof_data(vp, sv, tv); }
}
// PGOIndirectCallVisitor::tryGetVTableInstruction
fn try_get_vtable_instruction(cb: i32) -> i32 {
    let callee = cb_callee(cb);
    if is_func(callee) || is_constant(callee) || vals[callee].kind == VK_INLINEASM { return -1; }
    if !is_inst_op(callee, OP_LOAD) { return -1; }
    let vt = if_strip_inbounds_constant_offsets(op(callee, 0));
    if vt >= 0 && is_inst(vt) { return vt; }
    return -1;
}
// Value::stripInBoundsConstantOffsets
fn if_strip_inbounds_constant_offsets(v0: i32) -> i32 {
    var v = v0;
    if ty_kind(vals[v].ty) != TK_PTR { return v; }
    var seen: i32[>..<] = [v];
    loop {
        let o = opcode_of(v);
        if o == OP_GEP {
            for k in 1..nops(v) { if vals[op(v, k)].kind != VK_CINT { return v; } }
            if (op_flags(v) & GEP_INBOUNDS) == 0 { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else if is_inst(v) && is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv < 0 { return v; }
            v = rv;
        } else {
            return v;
        }
        for x in seen { if x == v { return v; } }
        seen.push(v);
    }
}
// scaleProfData(I, S, T)
fn if_scale_prof_data(i: i32, sv: u64, tv: u64) {
    let pd = inst_get_md(i, MDK_PROF);
    if pd < 0 || mds[pd].nops < 1 { return; }
    let nm = md_op(pd, 0);
    let is_bw = pd_md_string_is(nm, "branch_weights");
    let is_vp = pd_md_string_is(nm, "VP");
    if !is_bw && !is_vp { return; }
    // hasCountTypeMD: value profiles, or a call's non-branch-weight (fewer than 3 operands) profile
    let count_type = (is_vp && mds[pd].nops >= 5) || (is_callbase(i) && !pd_is_branch_weight_md(pd));
    if !count_type { return; }
    var opsv: i32[>..<] = [nm];
    let aps = ap_u64(sv, 128);
    let apt = ap_u64(tv, 128);
    if is_bw && mds[pd].nops > 0 {
        let w = pd_md_weight(pd, pd_offset(pd));
        let q = ap_udiv(ap_mul(ap_u64(w, 128), aps), apt);
        opsv.push(md_value(c_int(T_I32, ap_limited(q, 0xFFFFFFFF) as! i64)));
    } else if is_vp {
        var k: i64 = 1;
        while k < (mds[pd].nops as i64) {
            opsv.push(md_op(pd, k));
            let cnt = pd_md_weight(pd, k + 1);
            if cnt == 0xFFFFFFFFFFFFFFFF { opsv.push(md_op(pd, k + 1)); k += 2; continue; }
            let q = ap_udiv(ap_mul(ap_u64(cnt, 128), aps), apt);
            opsv.push(md_value(c_int(T_I64, ap_limited(q, 0xFFFFFFFFFFFFFFFF) as! i64)));
            k += 2;
        }
    }
    inst_set_md(i, MDK_PROF, md_get(MK_TUPLE, -1, opsv, false));
}
// Function::setEntryCount(Count): keeps the import GUIDs of a function_entry_count
fn fn_set_entry_count(f: i32, n: u64) {
    var opsv: i32[>..<] = [md_string("function_entry_count"), md_value(c_int(T_I64, n as! i64))];
    let old = func_get_md(f, MDK_PROF);
    if old >= 0 && pd_md_string_is(md_op(old, 0), "function_entry_count") {
        var guids: u64[>..<] = [];
        for k in 2..(mds[old].nops as i64) { guids.push(pd_md_weight(old, k)); }
        // sorted, unique (a DenseSet)
        var a: i64 = 1;
        while a < guids.len { var b = a; while b > 0 && guids[b - 1] > guids[b] { let t = guids[b]; guids[b] = guids[b - 1]; guids[b - 1] = t; b--; } a++; }
        var last: u64 = 0;
        for g, j in guids { if j > 0 && g == last { continue; } opsv.push(md_value(c_int(T_I64, g as! i64))); last = g; }
    }
    glob_set_md(f, MDK_PROF, md_get(MK_TUPLE, -1, opsv, false));
}
// GlobalObject::addMetadata(Kind, MD): another attachment of the kind (getAllMetadata stable-sorts by kind)
fn glob_add_md(f: i32, kind: i32, node: i32) {
    let g = glob_of(f);
    let at = globs[g].md;
    let n = globs[g].nmd;
    let nat = md_att.len as i32;
    var placed = false;
    for k in n {
        let kk = md_att[at + 2 * k];
        if !placed && kk > kind { md_att.push(kind); md_att.push(node); placed = true; }
        md_att.push(kk);
        md_att.push(md_att[at + 2 * k + 1]);
    }
    if !placed { md_att.push(kind); md_att.push(node); }
    globs[g].md = nat;
    globs[g].nmd = n + 1;
}
fn glob_set_md(f: i32, kind: i32, node: i32) {
    let g = glob_of(f);
    let at = globs[g].md;
    let n = globs[g].nmd;
    for k in n { if md_att[at + 2 * k] == kind { md_att[at + 2 * k + 1] = node; return; } }
    let nat = md_att.len as i32;
    for k in n { md_att.push(md_att[at + 2 * k]); md_att.push(md_att[at + 2 * k + 1]); }
    md_att.push(kind);
    md_att.push(node);
    globs[g].md = nat;
    globs[g].nmd = n + 1;
}
