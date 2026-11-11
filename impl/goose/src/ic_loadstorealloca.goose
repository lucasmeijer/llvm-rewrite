// Port of llvm/lib/Transforms/InstCombine/InstCombineLoadStoreAlloca.cpp, whole, in file order:
// isOnlyCopiedFromConstantMemory, isDereferenceableForAllocaSize, simplifyAllocaArraySize, PointerReplacer,
// visitAllocaInst, combineLoadToNewType, combineStoreToNewValue, combineLoadToOperationType,
// unpackLoadToAggregate, isObjectSizeLessThanOrEq, canReplaceGEPIdxWithZero, replaceGEPIdxWithZero,
// canSimplifyNullStoreOrGEP, canSimplifyNullLoadOrGEP, simplifyNonNullOperand, visitLoadInst,
// likeBitCastFromVector, combineStoreToValueType, unpackStoreToAggregate, equivalentAddressValues,
// visitStoreInst, mergeStoreIntoSuccessor. Also copyMetadataForLoad / copyNonnullMetadata / copyRangeMetadata
// and getOrEnforceKnownAlignment / tryEnforceAlignment (llvm/lib/Transforms/Utils/Local.cpp).
namespace ic;
import std;
import triple;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import apint;
import pm;
import vt;
import local;
import knownbits;
import memloc;
import aa;
import loads;
import speculate;
import cfold;
import constfold;
import constrange;
import instsimplify;
import instident;
import cfgutil;
import simplifycfg;
import mem2reg;
import domtree;
import domcond;
import flags;
import ic;
import ic_builder;
import ic_common;
import ic_combining;
import ic_visit_misc;

// ---------------------------------------------------------------------------------------------
// Small accessors

// AM.getResult<AAManager>(F) for the function being combined (once per InstCombinePass run)
var ic_aa_fn: i32 = -1;
fn ic_aa_ensure() { if ic_aa_fn != ic_fn { aa_begin(ic_fn); ic_aa_fn = ic_fn; } }

fn lsa_align(i: i32) -> i64 { icb_inst_align(i) }
fn lsa_set_align(i: i32, al: i64) { insts[inst_of(i)].align = icb_align_code(al); }
fn lsa_is_array_allocation(ai: i32) -> bool {
    let n = op(ai, 0);
    return !(vals[n].kind == VK_CINT && ap_is_one(ci_ap(n)));
}
fn lsa_alloca_ty(ai: i32) -> i32 { insts[inst_of(ai)].ty2 }
fn lsa_alloca_as(ai: i32) -> i64 { ptr_as(vals[ai].ty) }
// Value::isSwiftError
fn lsa_is_swift_error(v: i32) -> bool {
    if is_arg(v) { return ml_arg_has(v, AK_SwiftError); }
    if is_inst_op(v, OP_ALLOCA) { return (insts[inst_of(v)].bits & 2) != 0; }
    return false;
}
fn lsa_is_mem_transfer(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove;
}
// MemIntrinsic::isVolatile: the i1 operand 3
fn lsa_memintr_volatile(i: i32) -> bool { let v = cb_arg(i, 3); return vals[v].kind == VK_CINT && !ap_is_zero(ci_ap(v)); }
// the call-site `align` of an argument (MemIntrinsic::getDestAlign / getSourceAlign); 0 = none
fn lsa_param_align(ci: i32, k: i64) -> i64 {
    let a = aset_find(alist_param(insts[inst_of(ci)].attrs, k), AK_Alignment);
    return if a < 0 { 0 } else { attrs[a].i1 as! i64 };
}
// StructLayout::hasPadding
fn lsa_struct_has_padding(t: i32) -> bool {
    if (types[t].flags & TF_PACKED) != 0 { return false; }
    var off: i64 = 0;
    var al: i64 = 1;
    for k in types[t].cnt {
        let et = ty_field(t, k);
        let a = dl_align(et, true);
        if off % a != 0 { return true; }
        al = max(al, a);
        off += dl_alloc_size(et);
    }
    return off % al != 0;
}
fn lsa_common_alignment(a: i64, off: i64) -> i64 {
    // commonAlignment(A, Offset) = MinAlign(A, Offset)
    if off == 0 { return a; }
    let x = (a as! u64) | (off as! u64);
    return (x & (~x + 1)) as! i64;
}

// ---------------------------------------------------------------------------------------------
// Local.cpp: getOrEnforceKnownAlignment(V, PrefAlign, DL, CxtI, AC, DT)

fn lsa_get_or_enforce_known_alignment(v: i32, pref: i64, cx: i32) -> i64 {
    let sv = dc_active;
    dc_active = false;
    kb_cxt = cx;
    let known = kb_compute_all(v, 0);
    dc_active = sv;
    var tz = kb_min_tz(known);
    if tz > 32 { tz = 32; }
    let bw = kb_bw(known);
    let e = if bw - 1 < tz { bw - 1 } else { tz };
    var al: i64 = 1 << e;
    if pref > al { al = max(al, lsa_try_enforce_alignment(v, pref)); }
    return al;
}
// tryEnforceAlignment(V, PrefAlign, DL)
fn lsa_try_enforce_alignment(v0: i32, pref0: i64) -> i64 {
    var pref = pref0;
    let v = strip_ptr_casts(v0);
    if is_inst_op(v, OP_ALLOCA) {
        let cur = lsa_align(v);
        if pref <= cur { return cur; }
        if dl_stack_align != 0 && pref > dl_stack_align { return cur; }
        lsa_set_align(v, pref);
        return pref;
    }
    if vals[v].kind == VK_GVAR {
        let cur = pointer_alignment(v);
        if pref <= cur { return cur; }
        if !lsa_can_increase_alignment(v) { return cur; }
        if globs[glob_of(v)].tls != 0 { ic_not_ported("tryEnforceAlignment of a thread-local global (MaxTLSAlign)"); }
        globs[glob_of(v)].align = icb_align_code(pref);
        return pref;
    }
    return 1;
}
// GlobalObject::canIncreaseAlignment (x86 ELF/COFF/MachO triples: not XCOFF)
fn lsa_can_increase_alignment(v: i32) -> bool {
    if !gv_is_strong_definition(v) { return false; }
    let g = globs[glob_of(v)];
    if g.section >= 0 && g.align != 0 { return false; }
    if lsa_triple_is_elf(g.module) && g.dso_local == 0 { return false; }
    return true;
}
// Triple::isOSBinFormatELF
fn lsa_triple_is_elf(m: i32) -> bool {
    let t = modules[m].triple;
    return tt_is_elf(triple_parse(if t < 0 { "" } else { sbytes(t) }));
}
fn contains(s: const u8[:], sub: const u8[:]) -> bool {
    if sub.len > s.len { return false; }
    for i in 0..s.len - sub.len + 1 { if s[i..i + sub.len] == sub { return true; } }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Local.cpp: copyMetadataForLoad(Dest, Source)

fn lsa_copy_metadata_for_load(dst: i32, src: i32) {
    let si = inst_of(src);
    let nt = vals[dst].ty;
    let direct: const u8[:][] = ["dbg", "tbaa", "prof", "fpmath", "tbaa.struct", "invariant.load", "alias.scope", "noalias",
        "nontemporal", "mem.cache_hint", "llvm.mem.parallel_loop_access", "llvm.access.group", "noundef",
        "noalias.addrspace", "invariant.group"];
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    for k in insts[si].nmd { kinds.push(md_att[insts[si].md + 2 * k]); nodes.push(md_att[insts[si].md + 2 * k + 1]); }
    for x in kinds.len {
        let kind = kinds[x];
        let node = nodes[x];
        let nm = sbytes(md_kind_names[kind]);
        var is_direct = false;
        for d in direct { if d == nm { is_direct = true; } }
        if is_direct { inst_set_md(dst, kind, node); continue; }
        if nm == "nonnull" {
            // copyNonnullMetadata
            if ty_kind(nt) == TK_PTR { inst_set_md(dst, kind, node); continue; }
            if !ty_is_int(nt) { continue; }
            let pty = vals[op(src, 0)].ty;
            let null_int = tf_fold(ce_cast(OP_PTRTOINT, c_null(pty), nt));
            let nonnull_int = tf_fold(ce_binop(OP_ADD, null_int, c_int_ty(nt, 1), 0));
            inst_set_md(dst, md_kind_id("range"), md_get(MK_TUPLE, -1, [md_value(nonnull_int), md_value(null_int)], false));
            continue;
        }
        if nm == "align" || nm == "dereferenceable" || nm == "dereferenceable_or_null" {
            if ty_kind(nt) == TK_PTR { inst_set_md(dst, kind, node); }
            continue;
        }
        if nm == "range" {
            // copyRangeMetadata
            if nt == vals[src].ty { inst_set_md(dst, kind, node); continue; }
            if ty_kind(nt) != TK_PTR { continue; }
            let bw = dl_ptr(types[nt].n).bits;
            if bw == ty_scalar_bits(vals[src].ty) && !lsa_range_md_contains(node, ap_zero(bw)) {
                inst_set_md(dst, md_kind_id("nonnull"), md_get(MK_TUPLE, -1, [], false));
            }
            continue;
        }
        if nm == "nofpclass" {
            if ty_scalar(nt) == ty_scalar(vals[src].ty) { inst_set_md(dst, kind, node); }
            continue;
        }
    }
}
// getConstantRangeFromMetadata(N).contains(X): the union of the [lo, hi) pairs
fn lsa_range_md_contains(m: i32, x: AP) -> bool {
    var k: i64 = 0;
    while k + 1 < mds[m].nops as i64 {
        let lo = ci_ap(mds[md_op(m, k)].extra);
        let hi = ci_ap(mds[md_op(m, k + 1)].extra);
        if rg_contains_ap(rg_nonempty(lo, hi), x) { return true; }
        k += 2;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// isOnlyCopiedFromConstantMemory

var lsa_to_delete: i32[>..<];
// returns the copy (MemTransferInst) or -1; lsa_to_delete gets the lifetime markers
fn lsa_is_only_copied_from_constant_memory(ai: i32) -> i32 {
    lsa_to_delete.clear();
    let max_users = flag_int("instcombine-max-copied-from-constant-users", 300);
    var wl_v: i32[>..<] = [];
    var wl_off: bool[>..<] = [];
    var vis_v: i32[>..<] = [];
    var vis_off: bool[>..<] = [];
    var the_copy: i32 = -1;
    wl_v.push(ai);
    wl_off.push(false);
    while wl_v.len > 0 {
        let v = wl_v.pop();
        let is_off = wl_off.pop();
        var seen = false;
        for k in vis_v.len { if vis_v[k] == v && vis_off[k] == is_off { seen = true; } }
        if seen { continue; }
        vis_v.push(v);
        vis_off.push(is_off);
        if vis_v.len > max_users { return -1; }
        var u = first_use(v);
        while u >= 0 {
            let i = use_user(u);
            let uidx = (u - vals[i].ops) as i64;
            u = use_next(u);
            let o = iop(i);
            if o == OP_LOAD {
                if !ld_is_simple(i) { return -1; }
                continue;
            }
            if o == OP_PHI || o == OP_SELECT { wl_v.push(i); wl_off.push(true); continue; }
            if o == OP_BITCAST || o == OP_ADDRSPACECAST { wl_v.push(i); wl_off.push(is_off); continue; }
            if o == OP_GEP { wl_v.push(i); wl_off.push(is_off || !gep_all_zero(i)); continue; }
            if is_callbase(i) {
                if uidx == nops(i) - 1 { continue; }   // isCallee
                let nargs = cb_nargs(i);
                let is_arg_op = uidx < nargs;
                if is_arg_op && cb_param_has_attr(i, uidx, AK_InAlloca) { return -1; }
                let no_capture = cc_nothing(ci_other(cb_capture_info(i, uidx))) && cc_nothing(ci_ret(cb_capture_info(i, uidx)));
                if no_capture && (call_only_reads_memory(i) || cb_arg_only_reads(i, uidx)) { continue; }
            }
            if inst_is_lifetime_start_or_end(i) { lsa_to_delete.push(i); continue; }
            if !lsa_is_mem_transfer(i) { return -1; }
            if lsa_memintr_volatile(i) { return -1; }
            if uidx == 1 { continue; }
            if the_copy >= 0 { return -1; }
            if is_off { return -1; }
            if uidx != 0 { return -1; }
            // isModSet(AA->getModRefInfoMask(MI->getSource()))
            let src = strip_ptr_casts(cb_arg(i, 1));
            ic_aa_ensure();
            if mr_is_mod(aa_mod_ref_mask_simple(ml_before_or_after(src), false)) { return -1; }
            the_copy = i;
        }
    }
    return the_copy;
}

// isDereferenceableForAllocaSize(V, AI, DL)
fn lsa_is_deref_for_alloca_size(v: i32, ai: i32) -> bool {
    let sz, ok, sc = ml_alloca_size(ai);
    if !ok || sc { return false; }
    let save_cxt = spec_cxt;
    let save_ac = spec_use_ac;
    spec_cxt = -1;
    spec_use_ac = false;
    spec_visited.clear();
    let r = spec_deref_aligned(v, lsa_align(ai), ap_u64(sz, 64), 16);
    spec_cxt = save_cxt;
    spec_use_ac = save_ac;
    return r;
}

// simplifyAllocaArraySize(IC, AI, DT)
fn lsa_simplify_alloca_array_size(ai: i32) -> i32 {
    let sz = op(ai, 0);
    if !lsa_is_array_allocation(ai) {
        if vals[sz].ty == T_I32 { return -1; }
        return ic_replace_operand(ai, 0, c_int(T_I32, 1));
    }
    if vals[sz].kind == VK_CINT && !ty_is_vector(vals[sz].ty) {
        let c = ci_ap(sz);
        if ap_active_bits(c) <= 64 {
            let nt = ty_array(lsa_alloca_ty(ai), ap_zext64(c) as i64);
            var nm: u8[>..] = [];
            nm.append(val_name(ai));
            let nw = icb_alloca(nt, lsa_alloca_as(ai), nm);
            lsa_set_align(nw, lsa_align(ai));
            insts[inst_of(nw)].bits = (insts[inst_of(nw)].bits & ~(1 as u8)) | (insts[inst_of(ai)].bits & 1);
            // replaceAllDbgUsesWith(AI, *New, *New, DT): the debug records of AI are rewritten by the RAUW
            return ic_replace_inst_uses_with(ai, nw);
        }
    }
    if is_undef_or_poison(sz) { return ic_replace_inst_uses_with(ai, c_poison(vals[ai].ty)); }
    let pit = dl_index_type(vals[ai].ty);
    if vals[sz].ty != pit {
        let v = icb_int_cast_c(sz, pit, false, "");
        return ic_replace_operand(ai, 0, v);
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// PointerReplacer

var pr_root: i32 = -1;
var pr_from_as: i64 = 0;
var pr_users: i32[>..<];          // UsersToReplace (SmallSetVector)
var pr_map_k: i32[>..<];          // WorkMap (MapVector)
var pr_map_v: i32[>..<];

fn pr_has_user(i: i32) -> bool { position(pr_users, i) >= 0 }
fn pr_add_user(i: i32) { if !pr_has_user(i) { pr_users.push(i); } }
fn pr_is_available(i: i32) -> bool { i == pr_root || pr_has_user(i) }
fn pr_get(v: i32) -> i32 { let k = position(pr_map_k, v); return if k < 0 { -1 } else { pr_map_v[k] }; }
fn pr_set(k: i32, v: i32) {
    let x = position(pr_map_k, k);
    if x >= 0 { pr_map_v[x] = v; } else { pr_map_k.push(k); pr_map_v.push(v); }
}
fn pr_is_equal_or_valid_asc(i: i32, from_as: i64) -> bool {
    if !is_inst_op(i, OP_ADDRSPACECAST) { return false; }
    let to_as = ptr_as(vals[i].ty);
    // InstCombiner::isValidAddrSpaceCast: TTI (X86: the base implementation returns false)
    return from_as == to_as;
}

fn pr_collect_users() -> bool {
    var wl: i32[>..<] = [];
    var revisit: i32[>..<] = [];   // ValuesToRevisit (SmallSetVector)
    fn push_users(inst: i32) {
        var u = first_use(inst);
        while u >= 0 {
            let i = use_user(u);
            u = use_next(u);
            if !pr_is_available(i) && position(revisit, i) < 0 { wl.push(i); }
        }
    }
    fn try_push_inst_operand(x: i32) -> bool {
        if !pr_has_user(x) {
            if position(revisit, x) >= 0 { return false; }
            revisit.push(x);
            wl.push(x);
        }
        return true;
    }
    push_users(pr_root);
    while wl.len > 0 {
        let inst = wl.pop();
        let o = iop(inst);
        if o == OP_LOAD {
            if ld_is_volatile(inst) { return false; }
            pr_add_user(inst);
        } else if o == OP_PHI {
            var replaceable = true;
            for k in nops(inst) { if !is_inst(op(inst, k)) { replaceable = false; } }
            var all_avail = replaceable;
            if replaceable { for k in nops(inst) { if !pr_is_available(op(inst, k)) { all_avail = false; } } }
            if all_avail {
                pr_add_user(inst);
                push_users(inst);
                continue;
            }
            if !replaceable { return false; }
            if position(revisit, inst) >= 0 { return false; }
            revisit.push(inst);
            wl.push(inst);
            for k in nops(inst) { if !try_push_inst_operand(op(inst, k)) { return false; } }
        } else if o == OP_SELECT {
            let t = op(inst, 1);
            let f = op(inst, 2);
            if !is_inst(t) || !is_inst(f) { return false; }
            if pr_is_available(t) && pr_is_available(f) {
                pr_add_user(inst);
                push_users(inst);
                continue;
            }
            wl.push(inst);
            if !try_push_inst_operand(t) || !try_push_inst_operand(f) { return false; }
        } else if o == OP_GEP {
            let p = op(inst, 0);
            if !is_inst(p) { return false; }
            if pr_is_available(p) {
                pr_add_user(inst);
                push_users(inst);
                continue;
            }
            wl.push(inst);
            if !try_push_inst_operand(p) { return false; }
        } else if lsa_is_mem_transfer(inst) {
            if lsa_memintr_volatile(inst) { return false; }
            pr_add_user(inst);
        } else if pr_is_equal_or_valid_asc(inst, pr_from_as) {
            pr_add_user(inst);
            push_users(inst);
        } else if inst_is_lifetime_start_or_end(inst) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

fn pr_replace_pointer(v: i32) {
    pr_set(pr_root, v);
    var wl: i32[>..<] = [];
    var post: i32[>..<] = [];     // PostOrderWorklist (SetVector)
    var visited: i32[>..<] = [];
    wl.push(pr_root);
    while wl.len > 0 {
        let i = wl[wl.len - 1];
        if position(visited, i) < 0 {
            visited.push(i);
            var u = first_use(i);
            while u >= 0 {
                let ui = use_user(u);
                u = use_next(u);
                if pr_has_user(ui) && position(visited, ui) < 0 { wl.push(ui); }
            }
        } else {
            if position(post, i) < 0 { post.push(i); }
            wl.pop();
        }
    }
    var k = post.len;
    while k > 0 { k--; pr_replace(post[k]); }
}

fn pr_replace(i: i32) {
    if pr_get(i) >= 0 { return; }
    let o = iop(i);
    if o == OP_LOAD {
        let v = pr_get(op(i, 0));
        let ni = ic_new_load_like(vals[i].ty, v, i);
        ic_take_name(ni, i);
        inst_copy_all_md(ni, i);
        ic_insert_new_with(ni, i);
        ic_replace_inst_uses_with(i, ni);
        pr_set(ni, ni);
    } else if o == OP_PHI {
        let v0 = pr_get(op(i, 0));
        vals[i].ty = if v0 >= 0 { vals[v0].ty } else { vals[op(i, 0)].ty };
        for k in nops(i) {
            let v = pr_get(op(i, k));
            set_op(i, k, if v >= 0 { v } else { op(i, k) });
        }
        pr_set(i, i);
    } else if o == OP_GEP {
        let v = pr_get(op(i, 0));
        var idx: i32[>..<] = [];
        idx.push(v);
        for k in 1..nops(i) { idx.push(op(i, k)); }
        let ni = create_inst(OP_GEP, gep_ret_type(v, idx[1..]), idx);
        insts[inst_of(ni)].ty2 = insts[inst_of(i)].ty2;
        ic_insert_new_with(ni, i);
        ic_take_name(ni, i);
        insts[inst_of(ni)].flags = insts[inst_of(i)].flags;
        pr_set(i, ni);
    } else if o == OP_SELECT {
        var t = op(i, 1);
        var f = op(i, 2);
        let rt = pr_get(t);
        if rt >= 0 { t = rt; }
        let rf = pr_get(f);
        if rf >= 0 { f = rf; }
        let ns = ic_new_select_md(op(i, 0), t, f, i);
        ic_insert_new_with(ns, i);
        ic_take_name(ns, i);
        pr_set(i, ns);
    } else if lsa_is_mem_transfer(i) {
        var d = cb_arg(i, 0);
        var s = cb_arg(i, 1);
        let rd = pr_get(d);
        if rd >= 0 { d = rd; }
        let rs = pr_get(s);
        if rs >= 0 { s = rs; }
        icb_set_insert_point(i);
        let ni = icb_mem_transfer(inst_iid(i) as i64, d, lsa_param_align(i, 0), s, lsa_param_align(i, 1), cb_arg(i, 2), lsa_memintr_volatile(i));
        lsa_copy_aa_metadata(ni, i);
        ic_erase(i);
        pr_set(i, ni);
    } else if o == OP_ADDRSPACECAST {
        let v = pr_get(op(i, 0));
        if ptr_as(vals[v].ty) != ptr_as(vals[i].ty) {
            let ni = ic_new_cast(OP_ADDRSPACECAST, v, vals[i].ty);
            ic_take_name(ni, i);
            ic_insert_new_with(ni, i);
            pr_set(i, ni);
        } else {
            pr_set(i, v);
        }
    } else {
        fatal("internal: PointerReplacer::replace: should never reach here");
    }
}

// Instruction::copyMetadata(SrcInst) (all attachments, !dbg included)
fn inst_copy_all_md(dst: i32, src: i32) {
    let si = inst_of(src);
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    for k in insts[si].nmd { kinds.push(md_att[insts[si].md + 2 * k]); nodes.push(md_att[insts[si].md + 2 * k + 1]); }
    for k in kinds.len { inst_set_md(dst, kinds[k], nodes[k]); }
}
// copyMetadata(Src, Kinds)
fn inst_copy_md_kind(dst: i32, src: i32, kind: i32) {
    let n = inst_get_md(src, kind);
    if n >= 0 { inst_set_md(dst, kind, n); } else { inst_erase_md(dst, kind); }
}
// setAAMetadata(Src->getAAMetadata()): tbaa, tbaa.struct, alias.scope, noalias, noalias.addrspace
fn lsa_copy_aa_metadata(dst: i32, src: i32) {
    for nm in ["tbaa", "tbaa.struct", "alias.scope", "noalias", "noalias.addrspace"] {
        inst_copy_md_kind(dst, src, md_kind_id(nm));
    }
}
// Metadata::PoisonGeneratingIDs: range, nonnull, align, nofpclass
fn lsa_copy_poison_generating_md(dst: i32, src: i32) {
    for nm in ["range", "nonnull", "align", "nofpclass"] {
        let n = inst_get_md(src, md_kind_id(nm));
        if n >= 0 { inst_set_md(dst, md_kind_id(nm), n); }
    }
}

// IRBuilder::CreateMemTransferInst(IntrID, Dst, DstAlign, Src, SrcAlign, Size, isVolatile)
fn icb_mem_transfer(id: i64, d: i32, dal: i64, s: i32, sal: i64, size: i32, vol: bool) -> i32 {
    let vb = c_bool_ty(T_I1, vol);
    let dt = vals[d].ty;
    let stt = vals[s].ty;
    let szt = vals[size].ty;
    let c = ic_new_intrinsic(id, [dt as i32, stt as i32, szt as i32], [d, s, size, vb]);
    if dal > 0 { ic_call_add_param_attr(c, 0, attr_int(AK_Alignment, dal as u64)); }
    if sal > 0 { ic_call_add_param_attr(c, 1, attr_int(AK_Alignment, sal as u64)); }
    return icb_insert(c, "");
}
// IRBuilder::CreateMemSet(Ptr, Val, Size, Align, isVolatile = false)
fn icb_memset(p: i32, v: i32, size: i32, al: i64) -> i32 {
    let f = c_false();
    let pt = vals[p].ty;
    let st = vals[size].ty;
    let c = ic_new_intrinsic(IID_memset, [pt as i32, st as i32], [p, v, size, f]);
    if al > 0 { ic_call_add_param_attr(c, 0, attr_int(AK_Alignment, al as u64)); }
    return icb_insert(c, "");
}

// ---------------------------------------------------------------------------------------------
// visitAllocaInst

fn visit_alloca(ai: i32) -> i32 {
    let r = lsa_simplify_alloca_array_size(ai);
    if r >= 0 { return r; }
    let sz, ok, sc = ml_alloca_size(ai);
    if ok && sz == 0 {
        if lsa_is_array_allocation(ai) { return ic_replace_operand(ai, 0, c_int_ty(vals[op(ai, 0)].ty, 1)); }
        let entry = func_entry(inst_func(ai));
        let first = lsa_first_non_phi_or_dbg(entry);
        if first != ai {
            var e_ok = false;
            var e_sz: u64 = 1;
            if is_inst_op(first, OP_ALLOCA) {
                let s2, ok2, sc2 = ml_alloca_size(first);
                e_ok = ok2;
                e_sz = s2;
            }
            if !e_ok || e_sz != 0 {
                inst_move_before(ai, first);
                return ai;
            }
            let ma = max(lsa_align(first), lsa_align(ai));
            lsa_set_align(first, ma);
            return ic_replace_inst_uses_with(ai, first);
        }
    }
    let copy = lsa_is_only_copied_from_constant_memory(ai);
    if copy >= 0 {
        let src = strip_ptr_casts(cb_arg(copy, 1));
        let aal = lsa_align(ai);
        let sal = lsa_get_or_enforce_known_alignment(src, aal, ai);
        if aal <= sal && lsa_is_deref_for_alloca_size(src, ai) && !is_inst(src) {
            let src_as = ptr_as(vals[src].ty);
            var dels: i32[>..<] = [];
            for d in lsa_to_delete { dels.push(d); }
            if lsa_alloca_as(ai) == src_as {
                for d in dels { ic_erase(d); }
                let ni = ic_replace_inst_uses_with(ai, src);
                ic_erase(copy);
                return ni;
            }
            pr_root = ai;
            pr_from_as = src_as;
            pr_users.clear();
            pr_map_k.clear();
            pr_map_v.clear();
            if pr_collect_users() {
                for d in dels { ic_erase(d); }
                pr_replace_pointer(src);
            }
        }
    }
    return visit_alloc_site(ai);
}

// BasicBlock::getFirstNonPHIOrDbg
fn lsa_first_non_phi_or_dbg(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || ld_is_debug_or_pseudo(i)) { i = inst_next(i); }
    return i;
}

// ---------------------------------------------------------------------------------------------
// Loads

// isSupportedAtomicType
fn lsa_is_supported_atomic_type(t: i32) -> bool { ty_is_int(t) || ty_kind(t) == TK_PTR || ty_is_fp(t) }

// combineLoadToNewType(LI, NewTy, Suffix)
fn combine_load_to_new_type(li: i32, nt: i32, suffix: const u8[:]) -> i32 {
    var nm: u8[>..] = [];
    nm.append(val_name(li));
    nm.append(suffix);
    let nl = icb_load_like(nt, op(li, 0), li, nm);
    lsa_copy_metadata_for_load(nl, li);
    return nl;
}

// combineStoreToNewValue(IC, SI, V)
fn combine_store_to_new_value(si: i32, v: i32) -> i32 {
    let ns = icb_store_like(v, op(si, 1), si);
    let ii = inst_of(si);
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    for k in insts[ii].nmd { kinds.push(md_att[insts[ii].md + 2 * k]); nodes.push(md_att[insts[ii].md + 2 * k + 1]); }
    let keep: const u8[:][] = ["dbg", "DIAssignID", "tbaa", "prof", "fpmath", "tbaa.struct", "alias.scope", "noalias",
        "nontemporal", "llvm.mem.parallel_loop_access", "llvm.access.group"];
    for x in kinds.len {
        let nm = sbytes(md_kind_names[kinds[x]]);
        for kk in keep { if kk == nm { inst_set_md(ns, kinds[x], nodes[x]); } }
    }
    return ns;
}

// CastInst::isNoopCast(DL)
fn lsa_is_noop_cast(c: i32) -> bool {
    let o = iop(c);
    let st = vals[op(c, 0)].ty;
    let dt = vals[c].ty;
    if o == OP_BITCAST { return true; }
    if o == OP_PTRTOINT || o == OP_PTRTOADDR { return ty_scalar_bits_dl(dt) == dl_ptr(ptr_as(st)).bits; }
    if o == OP_INTTOPTR { return ty_scalar_bits_dl(st) == dl_ptr(ptr_as(dt)).bits; }
    return false;
}
fn ty_scalar_bits_dl(t: i32) -> i64 { ty_bits(ty_scalar(t)) }
fn lsa_is_ptr_or_ptr_vec(t: i32) -> bool { ty_kind(ty_scalar(t)) == TK_PTR }

// combineLoadToOperationType(IC, Load)
fn combine_load_to_operation_type(li: i32) -> i32 {
    if !ld_is_unordered(li) { return -1; }
    if use_empty(li) { return -1; }
    if lsa_is_swift_error(op(li, 0)) { return -1; }
    if has_one_use(li) {
        let lt = vals[li].ty;
        let ub = use_user(first_use(li));
        if is_inst_op(ub, OP_BITCAST) && ty_kind(vals[ub].ty) == TK_X86_AMX { return -1; }
        if is_cast_inst(ub) {
            let dt = vals[ub].ty;
            if lsa_is_noop_cast(ub) && lsa_is_ptr_or_ptr_vec(lt) == lsa_is_ptr_or_ptr_vec(dt) &&
               (!ld_is_atomic(li) || lsa_is_supported_atomic_type(dt)) {
                let nl = combine_load_to_new_type(li, dt, "");
                ic_rauw(ub, nl);
                ic_erase(ub);
                return li;
            }
        }
    }
    return -1;
}

// unpackLoadToAggregate(IC, LI)
fn unpack_load_to_aggregate(li: i32) -> i32 {
    if !ld_is_simple(li) { return -1; }
    let t = vals[li].ty;
    if !ty_is_aggregate(t) { return -1; }
    var name: u8[>..] = [];
    name.append(val_name(li));
    if ty_is_struct(t) {
        let n = ty_count(t);
        if n == 1 {
            let nl = combine_load_to_new_type(li, ty_field(t, 0), ".unpack");
            lsa_copy_aa_metadata(nl, li);
            inst_copy_md_kind(nl, li, md_kind_id("invariant.load"));
            return ic_replace_inst_uses_with(li, icb_insert_value(c_poison(t), nl, [0], name));
        }
        if lsa_struct_has_padding(t) { return -1; }
        let al = lsa_align(li);
        let addr = op(li, 0);
        let it = dl_index_type(vals[addr].ty);
        var v = c_poison(t);
        for i in n {
            let off = dl_struct_offset(t, i);
            var en: u8[>..] = [];
            en.append(name); en.append(".elt");
            let p = icb_ptr_add(addr, icb_type_size(it, off as u64, ty_size_scalable(t)), en, GEP_INBOUNDS | GEP_NUSW);
            var un: u8[>..] = [];
            un.append(name); un.append(".unpack");
            let l = icb_aligned_load(ty_field(t, i), p, lsa_common_alignment(al, off), un);
            lsa_copy_aa_metadata(l, li);
            inst_copy_md_kind(l, li, md_kind_id("invariant.load"));
            v = icb_insert_value(v, l, [i as i32], "");
        }
        ic_set_name_v(v, name);
        return ic_replace_inst_uses_with(li, v);
    }
    // array
    let et = ty_elem(t);
    let n = ty_count(t);
    if n == 1 {
        let nl = combine_load_to_new_type(li, et, ".unpack");
        lsa_copy_aa_metadata(nl, li);
        return ic_replace_inst_uses_with(li, icb_insert_value(c_poison(t), nl, [0], name));
    }
    if n > flag_int("instcombine-maxarray-size", 1024) { return -1; }
    let esz = dl_alloc_size(et);
    let al = lsa_align(li);
    let addr = op(li, 0);
    let zero = c_int(T_I64, 0);
    var v = c_poison(t);
    var off: i64 = 0;
    for i in n {
        var en: u8[>..] = [];
        en.append(name); en.append(".elt");
        let p = icb_gep(t, addr, [zero, c_int(T_I64, i)], en, GEP_INBOUNDS | GEP_NUSW);
        var un: u8[>..] = [];
        un.append(name); un.append(".unpack");
        let l = icb_aligned_load(et, p, lsa_common_alignment(al, off), un);
        lsa_copy_aa_metadata(l, li);
        v = icb_insert_value(v, l, [i as i32], "");
        off += esz;
    }
    ic_set_name_v(v, name);
    return ic_replace_inst_uses_with(li, v);
}
// V->setName(Name) on a value that may be a constant (Constants can't be named)
fn ic_set_name_v(v: i32, name: const u8[:]) {
    if is_constant(v) { return; }
    var buf: u8[>..] = [];
    buf.append(name);
    set_name(v, buf);
}

// isObjectSizeLessThanOrEq(V, MaxSize, DL)
fn lsa_is_object_size_le(v: i32, max_size: u64) -> bool {
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    wl.push(v);
    loop {
        let p = strip_ptr_casts(wl.pop());
        if position(visited, p) >= 0 { if wl.len == 0 { break; } continue; }
        visited.push(p);
        if is_inst_op(p, OP_SELECT) { wl.push(op(p, 1)); wl.push(op(p, 2)); continue; }
        if is_inst_op(p, OP_PHI) { for k in nops(p) { wl.push(op(p, k)); } continue; }
        if vals[p].kind == VK_ALIAS {
            if glob_is_interposable(p) { return false; }
            wl.push(op(p, 0));
            continue;
        }
        if is_inst_op(p, OP_ALLOCA) {
            let s, ok, sc = ml_alloca_size(p);
            if !ok || sc || s > max_size { return false; }
            if wl.len == 0 { break; }
            continue;
        }
        if vals[p].kind == VK_GVAR {
            let g = globs[glob_of(p)];
            // hasDefinitiveInitializer: an initializer, not interposable, not externally initialized
            if nops(p) == 0 || glob_is_interposable(p) || g.ext_init != 0 || g.is_const == 0 { return false; }
            if (dl_alloc_size(g.vty) as u64) > max_size { return false; }
            if wl.len == 0 { break; }
            continue;
        }
        return false;
    }
    return true;
}
// GlobalValue::isInterposable
fn glob_is_interposable(v: i32) -> bool {
    let l = globs[glob_of(v)].linkage as i64;
    if l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return true; }
    // isExternalLinkage && semantic interposition (module flag "SemanticInterposition"): not supported
    return false;
}

// canReplaceGEPIdxWithZero(IC, GEPI, MemI, Idx) -> (ok, Idx)
fn lsa_can_replace_gep_idx_with_zero(g: i32, mem: i32) -> bool, i64 {
    if nops(g) < 2 { return false, 0; }
    var idx: i64 = 1;
    while idx < nops(g) {
        let v = op(g, idx);
        if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) && ap_is_zero(ci_ap(v)) { idx++; continue; }
        break;
    }
    if idx == nops(g) { return false, 0; }
    if is_constant(op(g, idx)) { return false, 0; }
    let st = insts[inst_of(g)].ty2;
    if ty_contains_scalable(st) || ty_kind(st) == TK_TARGETEXT { return false, 0; }
    let mark = is_ops.len;
    for k in 1..idx { is_ops.push(op(g, k)); }
    let at = gep_indexed_type(st, mark, idx - 1);
    is_ops.resize(mark);
    if at < 0 || !cf_ty_is_sized(at) { return false, 0; }
    let tsz = dl_alloc_size(at) as u64;
    if idx + 1 != nops(g) && (insts[inst_of(g)].flags & GEP_INBOUNDS) == 0 { return false, idx; }
    if !lsa_is_object_size_le(op(g, 0), tsz) { return false, idx; }
    for i in idx + 1..nops(g) {
        kb_cxt = mem;
        let k = kb_compute_all(op(g, i), 0);
        if !kb_is_nonneg(k) { return false, idx; }
    }
    return true, idx;
}

// replaceGEPIdxWithZero(IC, Ptr, MemI)
fn lsa_replace_gep_idx_with_zero(p: i32, mem: i32) -> i32 {
    if !is_inst_op(p, OP_GEP) { return -1; }
    let ok, idx = lsa_can_replace_gep_idx_with_zero(p, mem);
    if !ok { return -1; }
    let ng = inst_clone(p);
    set_op(ng, idx, c_null(vals[op(p, idx)].ty));
    ic_insert_new_before(ng, p);
    if inst_parent(p) == inst_parent(mem) && lsa_guaranteed_transfer_range(p, mem) {
        ic_replace_inst_uses_with(p, ng);
        ic_erase(p);
    }
    return ng;
}
// isGuaranteedToTransferExecutionToSuccessor(Begin, End): every instruction in [from, to) transfers (limit 32)
fn lsa_guaranteed_transfer_range(from: i32, to: i32) -> bool {
    var i = from;
    var budget: i64 = 32;
    while i >= 0 && i != to {
        budget--;
        if budget == 0 { return false; }
        if !guaranteed_to_transfer(i) { return false; }
        i = inst_next(i);
    }
    return true;
}

// canSimplifyNullStoreOrGEP(SI)
fn lsa_can_simplify_null_store_or_gep(si: i32) -> bool {
    let f = inst_func(si);
    let as_ = ptr_as(vals[op(si, 1)].ty);
    if null_pointer_is_defined(f, as_) { return false; }
    var p = op(si, 1);
    if is_inst_op(p, OP_GEP) { p = op(p, 0); }
    return vals[p].kind == VK_CNULL && !null_pointer_is_defined(f, as_);
}
// canSimplifyNullLoadOrGEP(LI, Op)
fn lsa_can_simplify_null_load_or_gep(li: i32, p: i32) -> bool {
    let f = inst_func(li);
    if is_inst_op(p, OP_GEP) {
        let g0 = op(p, 0);
        if vals[g0].kind == VK_CNULL && !null_pointer_is_defined(f, ptr_as(vals[p].ty)) { return true; }
    }
    if is_undef_or_poison(p) || (vals[p].kind == VK_CNULL && !null_pointer_is_defined(f, ptr_as(vals[p].ty))) { return true; }
    return false;
}

// simplifyNonNullOperand(V, HasDereferenceable, Depth)
recursive fn ic_simplify_non_null_operand(v: i32, deref: bool, depth: i64) -> i32 {
    if is_select_inst(v) {
        if vals[op(v, 1)].kind == VK_CNULL { return op(v, 2); }
        if vals[op(v, 2)].kind == VK_CNULL { return op(v, 1); }
    }
    if !has_one_use(v) || is_constant_data(v) { return -1; }
    if depth == 3 { return -1; }
    if is_inst_op(v, OP_GEP) {
        if deref || (insts[inst_of(v)].flags & GEP_INBOUNDS) != 0 {
            let res = ic_simplify_non_null_operand(op(v, 0), deref, depth + 1);
            if res >= 0 {
                ic_replace_operand(v, 0, res);
                icw_push(v);
                return -1;
            }
        }
    }
    if is_phi_inst(v) {
        var changed = false;
        for k in nops(v) {
            let res = ic_simplify_non_null_operand(op(v, k), deref, 3);
            if res >= 0 {
                ic_replace_use(vals[v].ops + k as i32, res);
                changed = true;
            }
        }
        if changed { icw_push(v); }
        return -1;
    }
    return -1;
}

// visitLoadInst(LI)
fn visit_load(li: i32) -> i32 {
    let p = op(li, 0);
    let res0 = simplify_load(li, p, sq_at(li));
    if res0 >= 0 { return ic_replace_inst_uses_with(li, res0); }
    let r1 = combine_load_to_operation_type(li);
    if r1 >= 0 { return r1; }
    let ng = lsa_replace_gep_idx_with_zero(p, li);
    if ng >= 0 { return ic_replace_operand(li, 0, ng); }
    let r2 = unpack_load_to_aggregate(li);
    if r2 >= 0 { return r2; }
    ic_aa_ensure();
    let q = aq_push(CA_SIMPLE);
    let avail = ld_find_available_loaded_value(li, q, ld_max_insts_to_scan());
    aq_pop(q);
    if avail >= 0 {
        if ld_is_load_cse { combine_metadata_for_cse(avail, li, false); }
        var nm: u8[>..] = [];
        nm.append(val_name(li));
        nm.append(".cast");
        return ic_replace_inst_uses_with(li, icb_bit_or_pointer_cast(avail, vals[li].ty, nm));
    }
    if !ld_is_unordered(li) { return -1; }
    if lsa_can_simplify_null_load_or_gep(li, p) {
        ic_create_non_terminator_unreachable(li);
        return ic_replace_inst_uses_with(li, c_poison(vals[li].ty));
    }
    if has_one_use(p) && !is_constant_data(p) {
        let asc = if is_inst_op(p, OP_ADDRSPACECAST) { p } else { -1 };
        var sel_op = p;
        if asc >= 0 && has_one_use(op(asc, 0)) && !is_constant_data(op(asc, 0)) { sel_op = op(asc, 0); }
        if is_select_inst(sel_op) {
            let al = lsa_align(li);
            let si = sel_op;
            if ld_safe_to_load_unconditionally_ty(op(si, 1), vals[li].ty, al, si) &&
               ld_safe_to_load_unconditionally_ty(op(si, 2), vals[li].ty, al, si) {
                let lo1 = lsa_maybe_cast_load_operand(op(si, 1), asc);
                var n1: u8[>..] = [];
                n1.append(val_name(lo1)); n1.append(".val");
                let v1 = icb_load_like(vals[li].ty, lo1, li, n1);
                let lo2 = lsa_maybe_cast_load_operand(op(si, 2), asc);
                var n2: u8[>..] = [];
                n2.append(val_name(lo2)); n2.append(".val");
                let v2 = icb_load_like(vals[li].ty, lo2, li, n2);
                lsa_copy_poison_generating_md(v1, li);
                lsa_copy_poison_generating_md(v2, li);
                let profcheck = flag_bool("profcheck-disable-metadata-fixes", false);
                return ic_new_select_md(op(si, 0), v1, v2, if profcheck { -1 } else { si });
            }
        }
    }
    if !null_pointer_is_defined(inst_func(li), ptr_as(vals[p].ty)) {
        let v = ic_simplify_non_null_operand(p, true, 0);
        if v >= 0 { return ic_replace_operand(li, 0, v); }
    }
    if ty_kind(vals[li].ty) == TK_PTR && inst_iid(p) == IID_protected_field_ptr {
        ic_not_ported("load of llvm.protected.field.ptr (ptrauth)");
    }
    return -1;
}
fn lsa_maybe_cast_load_operand(v: i32, asc: i32) -> i32 {
    if asc < 0 { return v; }
    var nm: u8[>..] = [];
    nm.append(val_name(v)); nm.append(".cast");
    return icb_addrspacecast(v, vals[asc].ty, nm);
}

// ---------------------------------------------------------------------------------------------
// Stores

// likeBitCastFromVector(IC, V)
fn lsa_like_bitcast_from_vector(v0: i32) -> i32 {
    var v = v0;
    var u: i32 = -1;
    while is_inst_op(v, OP_INSERTVALUE) {
        let e = op(v, 1);
        if !is_inst_op(e, OP_EXTRACTELEMENT) { return -1; }
        let w = op(e, 0);
        if u < 0 { u = w; } else if u != w { return -1; }
        let ci = op(e, 1);
        if vals[ci].kind != VK_CINT || ty_is_vector(vals[ci].ty) { return -1; }
        if insts[inst_of(v)].naux != 1 { return -1; }
        // getZExtValue (asserts below 64 bits)
        if !ap_eq_u64(ci_ap(ci), ints[insts[inst_of(v)].aux] as u64) { return -1; }
        v = op(v, 0);
    }
    if !m_undef(v) || u < 0 { return -1; }
    let ut = vals[u].ty;
    let vt = vals[v].ty;
    if dl_store_size(ut) * 8 != dl_store_size(vt) * 8 { return -1; }
    if ty_kind(ut) == TK_SVEC { return -1; }
    if ty_is_array(vt) {
        if ty_count(vt) != ty_count(ut) { return -1; }
    } else {
        if ty_count(vt) != ty_count(ut) { return -1; }
        for k in ty_count(vt) { if ty_field(vt, k) != ty_elem(ut) { return -1; } }
    }
    return u;
}

// combineStoreToValueType(IC, SI)
fn combine_store_to_value_type(si: i32) -> bool {
    if !ld_is_unordered(si) { return false; }
    if lsa_is_swift_error(op(si, 1)) { return false; }
    var v = op(si, 0);
    if is_inst_op(v, OP_BITCAST) {
        v = op(v, 0);
        if ty_kind(vals[v].ty) == TK_X86_AMX { return false; }
        if !ld_is_atomic(si) || lsa_is_supported_atomic_type(vals[v].ty) {
            combine_store_to_new_value(si, v);
            return true;
        }
    }
    let u = lsa_like_bitcast_from_vector(v);
    if u >= 0 {
        if !ld_is_atomic(si) || lsa_is_supported_atomic_type(vals[u].ty) {
            combine_store_to_new_value(si, u);
            return true;
        }
    }
    return false;
}

// unpackStoreToAggregate(IC, SI)
fn unpack_store_to_aggregate(si: i32) -> bool {
    if !ld_is_simple(si) { return false; }
    var v = op(si, 0);
    let t = vals[v].ty;
    if !ty_is_aggregate(t) { return false; }
    if ty_is_struct(t) {
        let n = ty_count(t);
        if n == 1 {
            v = icb_extract_value(v, [0], "");
            combine_store_to_new_value(si, v);
            return true;
        }
        if lsa_struct_has_padding(t) { return false; }
        let al = lsa_align(si);
        var en: u8[>..] = [];
        en.append(val_name(v)); en.append(".elt");
        let addr = op(si, 1);
        var an: u8[>..] = [];
        an.append(val_name(addr)); an.append(".repack");
        let it = dl_index_type(vals[addr].ty);
        for i in n {
            let off = dl_struct_offset(t, i);
            let p = icb_ptr_add(addr, icb_type_size(it, off as u64, ty_size_scalable(t)), an, GEP_INBOUNDS | GEP_NUSW);
            let val = icb_extract_value(v, [i as i32], en);
            let ns = icb_aligned_store(val, p, lsa_common_alignment(al, off));
            lsa_copy_aa_metadata(ns, si);
        }
        return true;
    }
    let n = ty_count(t);
    if n == 1 {
        v = icb_extract_value(v, [0], "");
        combine_store_to_new_value(si, v);
        return true;
    }
    if n > flag_int("instcombine-maxarray-size", 1024) { return false; }
    let esz = dl_alloc_size(ty_elem(t));
    let al = lsa_align(si);
    var en: u8[>..] = [];
    en.append(val_name(v)); en.append(".elt");
    let addr = op(si, 1);
    var an: u8[>..] = [];
    an.append(val_name(addr)); an.append(".repack");
    let zero = c_int(T_I64, 0);
    var off: i64 = 0;
    for i in n {
        let p = icb_gep(t, addr, [zero, c_int(T_I64, i)], an, GEP_INBOUNDS | GEP_NUSW);
        let val = icb_extract_value(v, [i as i32], en);
        let ns = icb_aligned_store(val, p, lsa_common_alignment(al, off));
        lsa_copy_aa_metadata(ns, si);
        off += esz;
    }
    return true;
}

// equivalentAddressValues(A, B)
fn lsa_equivalent_address_values(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if is_inst(a) {
        let o = iop(a);
        if is_binary_op(o) || is_cast_op(o) || o == OP_PHI || o == OP_GEP {
            if is_inst(b) && ii_is_identical_when_defined(a, b, false) { return true; }
        }
    }
    return false;
}

// visitStoreInst(SI)
fn visit_store(si: i32) -> i32 {
    let val = op(si, 0);
    let p = op(si, 1);
    if combine_store_to_value_type(si) { return ic_erase(si); }
    if unpack_store_to_aggregate(si) { return ic_erase(si); }
    let ng = lsa_replace_gep_idx_with_zero(p, si);
    if ng >= 0 { return ic_replace_operand(si, 1, ng); }
    if !ld_is_unordered(si) { return -1; }
    if has_one_use(p) && !is_constant_data(p) {
        if is_inst_op(p, OP_ALLOCA) { return ic_erase(si); }
        if is_inst_op(p, OP_GEP) && is_inst_op(op(p, 0), OP_ALLOCA) {
            if has_one_use(op(p, 0)) { return ic_erase(si); }
        }
    }
    ic_aa_ensure();
    if !mr_is_mod(aa_mod_ref_mask_simple(ml_before_or_after(p), false)) { return ic_erase(si); }
    // really simple DSE
    var bbi = si;
    var scan: i64 = 6;
    let bb_first = block_first(inst_parent(si));
    while bbi != bb_first && scan > 0 {
        bbi = inst_prev(bbi);
        scan--;
        if is_debug_or_pseudo_inst(bbi) { scan++; continue; }
        if iop(bbi) == OP_STORE {
            if ld_is_unordered(bbi) && lsa_equivalent_address_values(op(bbi, 1), op(si, 1)) &&
               vals[op(bbi, 0)].ty == vals[op(si, 0)].ty {
                icw_push(si);
                ic_erase(bbi);
                return -1;
            }
            break;
        }
        if iop(bbi) == OP_LOAD {
            if bbi == val && lsa_equivalent_address_values(op(bbi, 0), p) { return ic_erase(si); }
            break;
        }
        if inst_may_write_memory(bbi) || inst_may_read_memory(bbi) || inst_may_throw(bbi) { break; }
    }
    if lsa_can_simplify_null_store_or_gep(si) {
        if !is_poison(val) { return ic_replace_operand(si, 0, c_poison(vals[val].ty)); }
        return -1;
    }
    if is_undef_or_poison(p) {
        ic_remove_insts_before_unreachable(si);
        var wl: i32[>..<] = [];
        ic_handle_unreachable_from(inst_next(si), wl);
        ic_handle_potentially_dead_blocks(wl);
        return -1;
    }
    if is_undef_or_poison(val) { return ic_erase(si); }
    if ty_kind(ty_scalar(vals[val].ty)) == TK_BYTE && m_imm_constant(val) {
        let it = lsa_int_from_byte_type(vals[val].ty);
        return ic_replace_operand(si, 0, tf_fold(ce_cast(OP_BITCAST, val, it)));
    }
    if !null_pointer_is_defined(inst_func(si), ptr_as(vals[p].ty)) {
        let v = ic_simplify_non_null_operand(p, true, 0);
        if v >= 0 { return ic_replace_operand(si, 1, v); }
    }
    if ty_kind(vals[val].ty) == TK_PTR && inst_iid(p) == IID_protected_field_ptr {
        ic_not_ported("store to llvm.protected.field.ptr (ptrauth)");
    }
    return -1;
}
// Type::getIntFromByteType
fn lsa_int_from_byte_type(t: i32) -> i32 {
    let it = ty_int(ty_bits(ty_scalar(t)));
    if ty_is_vector(t) { return ty_vector(it, ty_count(t), ty_kind(t) == TK_SVEC); }
    return it;
}

// mergeStoreIntoSuccessor(SI)
fn ic_merge_store_into_successor(si: i32) -> bool {
    if !ld_is_unordered(si) { return false; }
    let store_bb = inst_parent(si);
    let dest_bb = term_succ(block_terminator(store_bb), 0);
    if pred_count(dest_bb) != 2 { return false; }
    var other_bb: i32 = -1;
    var first = true;
    var p0: i32 = -1;
    var p1: i32 = -1;
    each_pred(dest_bb) { p =>
        if first { p0 = p; first = false; } else if p1 < 0 { p1 = p; }
    };
    other_bb = if p0 == store_bb { p1 } else { p0 };
    if store_bb == dest_bb || other_bb == dest_bb { return false; }
    var bbi = block_terminator(other_bb);
    if bbi == block_first(other_bb) { return false; }
    fn mergeable(os: i32) -> bool {
        if os < 0 || iop(os) != OP_STORE || op(os, 1) != op(si, 1) { return false; }
        let a = vals[op(si, 0)].ty;
        let b = vals[op(os, 0)].ty;
        return ld_is_bit_or_noop_ptr_castable(b, a) && ii_has_same_special_state(si, os, false, false);
    }
    var other_store: i32 = -1;
    if iop(bbi) == OP_BR {
        bbi = inst_prev(bbi);
        while is_debug_or_pseudo_inst(bbi) {
            if bbi == block_first(other_bb) { return false; }
            bbi = inst_prev(bbi);
        }
        other_store = bbi;
        if !mergeable(other_store) { return false; }
    } else if iop(bbi) == OP_CONDBR {
        if term_succ(bbi, 0) != store_bb && term_succ(bbi, 1) != store_bb { return false; }
        loop {
            if iop(bbi) == OP_STORE && mergeable(bbi) { other_store = bbi; break; }
            if inst_may_read_memory(bbi) || inst_may_throw(bbi) || inst_may_write_memory(bbi) || bbi == block_first(other_bb) { return false; }
            bbi = inst_prev(bbi);
        }
        var i = block_first(store_bb);
        while i != si {
            if inst_may_read_memory(i) || inst_may_throw(i) || inst_may_write_memory(i) { return false; }
            i = inst_next(i);
        }
    } else {
        return false;
    }
    var merged = op(other_store, 0);
    let merged_loc = merged_location(inst_get_md(si, 0), inst_get_md(other_store, 0));
    if merged != op(si, 0) {
        let pn = create_inst(OP_PHI, vals[op(si, 0)].ty, []);
        set_name(pn, "storemerge");
        phi_add_incoming(pn, op(si, 0), inst_parent(si));
        icb_set_insert_point(other_store);
        phi_add_incoming(pn, icb_bit_or_pointer_cast(merged, vals[pn].ty, ""), other_bb);
        merged = ic_insert_new_before_head(pn, block_first(dest_bb));   // DestBB->begin()
        if merged_loc >= 0 { inst_set_md(pn, 0, merged_loc); } else { inst_erase_md(pn, 0); }
    }
    let pos = first_insertion_pt(dest_bb);
    let nsi = ic_new_store_like(merged, op(si, 1), si);
    ic_insert_new_before_head(nsi, pos);
    if merged_loc >= 0 { inst_set_md(nsi, 0, merged_loc); } else { inst_erase_md(nsi, 0); }
    let dia = md_kind_id("DIAssignID");
    if inst_get_md(si, dia) >= 0 || inst_get_md(other_store, dia) >= 0 { ic_not_ported("mergeDIAssignID in mergeStoreIntoSuccessor"); }
    lsa_merge_aa_metadata(nsi, si, other_store);
    ic_erase(si);
    ic_erase(other_store);
    return true;
}

// NewSI->setAAMetadata(SI.getAAMetadata().merge(Other.getAAMetadata())) when SI has AA tags
fn lsa_merge_aa_metadata(dst: i32, a: i32, b: i32) {
    let k_tbaa = md_kind_id("tbaa");
    let k_tbs = md_kind_id("tbaa.struct");
    let k_scope = md_kind_id("alias.scope");
    let k_noalias = md_kind_id("noalias");
    let k_nas = md_kind_id("noalias.addrspace");
    // AAMDNodes::operator bool: any of TBAA, TBAAStruct, Scope, NoAlias (NoAliasAddrSpace is not tested)
    if inst_get_md(a, k_tbaa) < 0 && inst_get_md(a, k_tbs) < 0 && inst_get_md(a, k_scope) < 0 && inst_get_md(a, k_noalias) < 0 { return; }
    let ta = inst_get_md(a, k_tbaa);
    let tb = inst_get_md(b, k_tbaa);
    var t: i32 = -1;
    if ta >= 0 && tb >= 0 {
        if ta == tb { t = ta; } else { ic_not_ported("MDNode::getMostGenericTBAA of different tags (AAMDNodes::merge)"); }
    }
    cu_set_md(dst, k_tbaa, t);
    cu_set_md(dst, k_tbs, -1);
    cu_set_md(dst, k_scope, cu_most_generic_alias_scope(inst_get_md(a, k_scope), inst_get_md(b, k_scope)));
    cu_set_md(dst, k_noalias, cu_md_intersect(inst_get_md(a, k_noalias), inst_get_md(b, k_noalias)));
    cu_set_md(dst, k_nas, cu_most_generic_noalias_addrspace(inst_get_md(a, k_nas), inst_get_md(b, k_nas)));
}
