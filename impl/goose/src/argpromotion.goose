// ArgumentPromotion: port of llvm/lib/Transforms/IPO/ArgumentPromotion.cpp (the CGSCC pass, MaxElements = 2 as
// `-passes=argpromotion` creates it), with AAResults::canInstructionRangeModRef / canBasicBlockModify
// (llvm/lib/Analysis/AliasAnalysis.cpp) and AttributeFuncs::updateMinLegalVectorWidthAttr (Attributes.cpp).
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
import pm;
import vt;
import apint;
import memloc;
import aa;
import speculate;
import inline_cost;
import mem2reg;
import tti;
import dinfo;
import scev;
import lcg;
import cgscc;
import ipoutil;
import ipo_globals;
import ipo_args;
import instsimplify;
import passmgr;
import inline_function;
import build_libcalls;
import autoupgrade;
import inliner;
import ic;

fn ap_fail(what: const u8[:]) { fatal(str("ArgumentPromotion: ", what, " is not ported yet")); }

let AP_MAX_ELEMENTS: i64 = 2;

// ArgPart: (offset, type, alignment, guaranteed-executed instruction or -1) per part, for the argument being
// analysed; the parts of every promoted argument are kept in ap_parts_* runs (ap_arg_at / ap_arg_n per argument)
var ap_off: i64[>..<];
var ap_ty: i32[>..<];
var ap_al: i64[>..<];
var ap_mx: i32[>..<];
var ap_need_align: i64 = 1;
var ap_need_bytes: i64 = 0;

fn ap_inst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) }; }
fn ap_is_simple(i: i32) -> bool { !inst_is_volatile(i) && insts[inst_of(i)].ord == 0 }

// HandleEndUser(I, Ty, GuaranteedToExecute): 0 = false, 1 = true, -1 = std::nullopt
fn ap_handle_end_user(arg: i32, i: i32, ty: i32, guaranteed: bool, is_recursive: bool) -> i64 {
    if !ap_is_simple(i) { return 0; }
    let ptr0 = if iop(i) == OP_LOAD { op(i, 0) } else { op(i, 1) };
    let p = strip_and_accumulate_offsets(ptr0, true, false, false);
    let off = vt_off;
    if p != arg { return -1; }
    if off == (-9223372036854775807 - 1) { return 0; }
    if ty_contains_scalable(ty) { return 0; }
    let size = dl_store_size(ty);
    if is_recursive && ty_kind(ty) == TK_PTR { return 0; }
    var idx: i64 = -1;
    for k in ap_off.len { if ap_off[k] == off { idx = k; } }
    var not_seen = false;
    if idx < 0 {
        idx = ap_off.len;
        ap_off.push(off); ap_ty.push(ty); ap_al.push(ap_inst_align(i)); ap_mx.push(if guaranteed { i } else { -1 });
        not_seen = true;
    }
    if AP_MAX_ELEMENTS > 0 && ap_off.len > AP_MAX_ELEMENTS { return 0; }
    if ap_ty[idx] != ty { return 0; }
    let ia = ap_inst_align(i);
    if !guaranteed && (not_seen || ap_al[idx] < ia) {
        if off < 0 { return 0; }
        if off % ia != 0 { return 0; }
        if off + size > ap_need_bytes { ap_need_bytes = off + size; }
        if ia > ap_need_align { ap_need_align = ia; }
    }
    if ia > ap_al[idx] { ap_al[idx] = ia; }
    return 1;
}

// isDereferenceableAndAlignedPointer(V, Alignment, APInt(64, Bytes), SimplifyQuery(DL, CtxI))
fn ap_deref_aligned(v: i32, align: i64, bytes: i64, cxt: i32) -> bool {
    let sdt = spec_use_dt; let stli = spec_use_tli; let sac = spec_use_ac; let scx = spec_cxt;
    spec_use_dt = false; spec_use_tli = false; spec_use_ac = false; spec_cxt = cxt;
    spec_visited.clear();
    let r = spec_deref_aligned(v, align, ap_u64(bytes as u64, 64), 16);
    spec_use_dt = sdt; spec_use_tli = stli; spec_use_ac = sac; spec_cxt = scx;
    return r;
}
// allCallersPassValidPointerForArgument(Arg, RecursiveCalls, NeededAlign, NeededDerefBytes)
fn ap_all_callers_pass_valid_pointer(arg: i32, recursive_calls: i32[>..<]&, align: i64, bytes: i64) -> bool {
    let callee = args_parent[vals[arg].sub];
    let k = args_no[vals[arg].sub] as i64;
    if ap_deref_aligned(arg, align, bytes, block_first(func_entry(callee))) { return true; }
    var u = first_use(callee);
    while u >= 0 {
        let cb = uses[u].user;
        u = use_next(u);
        if vals[cb].kind == VK_BLOCKADDR { continue; }
        if position(recursive_calls, cb) >= 0 { continue; }
        if !ap_deref_aligned(cb_arg(cb, k), align, bytes, cb) { return false; }
    }
    return true;
}
// isArgUnmodifiedByAllCalls(Arg, FAM)
fn ap_arg_unmodified_by_all_calls(arg: i32) -> bool {
    let f = args_parent[vals[arg].sub];
    let k = args_no[vals[arg].sub] as i64;
    var u = first_use(f);
    while u >= 0 {
        let call = uses[u].user;
        u = use_next(u);
        if vals[call].kind == VK_BLOCKADDR { continue; }
        let loc = ml_for_argument(call, k, false);
        aa_begin(inst_func(call));
        let q = aq_push(CA_SIMPLE);
        let mr = aa_call_loc_mr(call, loc, q);
        aq_pop(q);
        if (mr & MR_MOD) != 0 { return false; }
    }
    return true;
}
// AAResults::canInstructionRangeModRef(I1, I2, Loc, Mod)
fn ap_can_range_mod(i1: i32, i2: i32, loc: ML) -> bool {
    var i = i1;
    loop {
        if (aa_inst_loc_mr_simple(i, loc) & MR_MOD) != 0 { return true; }
        if i == i2 { break; }
        i = inst_next(i);
    }
    return false;
}

// findArgParts(Arg, DL, AAR, MaxElements, IsRecursive, ArgPartsVec): the parts are left sorted in ap_*
fn ap_find_arg_parts(arg: i32, is_recursive: bool) -> bool {
    ap_off.clear(); ap_ty.clear(); ap_al.clear(); ap_mx.clear();
    if first_use(arg) < 0 { return true; }
    let f = args_parent[vals[arg].sub];
    let argno = args_no[vals[arg].sub] as i64;
    ap_need_align = 1;
    ap_need_bytes = 0;
    let pset = alist_param(globs[glob_of(f)].attrs, argno);
    let stores_allowed = aset_find(pset, AK_ByVal) >= 0 && aset_find(pset, AK_Alignment) >= 0;
    var i = block_first(func_entry(f));
    while i >= 0 {
        var res: i64 = -1;
        if iop(i) == OP_LOAD { res = ap_handle_end_user(arg, i, vals[i].ty, true, is_recursive); }
        else if iop(i) == OP_STORE { res = ap_handle_end_user(arg, i, vals[op(i, 0)].ty, true, is_recursive); }
        if res == 0 { return false; }
        if !guaranteed_to_transfer(i) { break; }
        i = inst_next(i);
    }
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var loads: i32[>..<] = [];
    var recursive_calls: i32[>..<] = [];
    ap_append_uses(arg, wl, visited);
    while wl.len > 0 {
        let u = wl.pop();
        let v = uses[u].user;
        if is_inst(v) && iop(v) == OP_GEP {
            for k in 1..nops(v) { if vals[op(v, k)].kind != VK_CINT { return false; } }
            ap_append_uses(v, wl, visited);
            continue;
        }
        if is_inst(v) && iop(v) == OP_LOAD {
            let r = ap_handle_end_user(arg, v, vals[v].ty, false, is_recursive);
            if r < 0 { ap_fail("a load whose pointer is not based on the argument"); }
            if r == 0 { return false; }
            loads.push(v);
            continue;
        }
        if stores_allowed && is_inst(v) && iop(v) == OP_STORE && (u - vals[v].ops) == 1 {
            let r = ap_handle_end_user(arg, v, vals[op(v, 0)].ty, false, is_recursive);
            if r < 0 { ap_fail("a store whose pointer is not based on the argument"); }
            if r == 0 { return false; }
            continue;
        }
        if is_inst(v) && is_callbase(v) && called_function(v) == inst_func(v) {
            if uses[u].val != arg { return false; }
            if (u - vals[v].ops) as i64 != argno { return false; }
            if AP_MAX_ELEMENTS > 0 && ap_off.len > AP_MAX_ELEMENTS { return false; }
            if position(recursive_calls, v) < 0 { recursive_calls.push(v); }
            continue;
        }
        return false;
    }
    if ap_need_bytes != 0 || ap_need_align > 1 {
        if !ap_all_callers_pass_valid_pointer(arg, recursive_calls, ap_need_align, ap_need_bytes) { return false; }
    }
    if ap_off.len == 0 { return true; }
    // sort by offset
    var i2: i64 = 1;
    while i2 < ap_off.len {
        var j = i2;
        while j > 0 && ap_off[j - 1] > ap_off[j] {
            let to = ap_off[j]; ap_off[j] = ap_off[j - 1]; ap_off[j - 1] = to;
            let tt = ap_ty[j]; ap_ty[j] = ap_ty[j - 1]; ap_ty[j - 1] = tt;
            let ta = ap_al[j]; ap_al[j] = ap_al[j - 1]; ap_al[j - 1] = ta;
            let tm = ap_mx[j]; ap_mx[j] = ap_mx[j - 1]; ap_mx[j - 1] = tm;
            j--;
        }
        i2++;
    }
    var offset = ap_off[0];
    for k in ap_off.len {
        if ap_off[k] < offset { return false; }
        offset = ap_off[k] + dl_store_size(ap_ty[k]);
    }
    if stores_allowed { return true; }
    if ap_arg_unmodified_by_all_calls(arg) { return true; }
    aa_begin(f);
    for ld in loads {
        let bb = inst_parent(ld);
        let loc = ml_get(ld);
        if ap_can_range_mod(block_first(bb), ld, loc) { return false; }
        // every path from the entry to the load: inverse_depth_first from each predecessor
        var preds: i32[>..<] = [];
        each_pred(bb) { p => preds.push(p); }
        for p in preds {
            var seen = hm_new();
            var st: i32[>..<] = [];
            st.push(p);
            hm_put(seen, p as u64, 1);
            while st.len > 0 {
                let t = st.pop();
                if ap_can_range_mod(block_first(t), block_last(t), loc) { return false; }
                var ps: i32[>..<] = [];
                each_pred(t) { x => ps.push(x); }
                var k = ps.len - 1;
                while k >= 0 {
                    let x = ps[k];
                    if !hm_has(seen, x as u64) { hm_put(seen, x as u64, 1); st.push(x); }
                    k--;
                }
            }
        }
    }
    return true;
}
fn ap_append_uses(v: i32, wl: i32[>..<]&, visited: HMap&) {
    var u = first_use(v);
    while u >= 0 {
        if !hm_has(visited, u as u64) { hm_put(visited, u as u64, 1); wl.push(u); }
        u = use_next(u);
    }
}

// areTypesABICompatible(Types, F, TTI)
fn ap_types_abi_compatible(tys: i32[>..<]&, f: i32) -> bool {
    let m = globs[glob_of(f)].module;
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        u = use_next(u);
        if vals[cb].kind == VK_BLOCKADDR { continue; }
        if !is_inst(cb) || !is_callbase(cb) { return false; }
        let caller = inst_func(cb);
        let callee = called_function(cb);
        tti_init_function(callee, m);
        if tti_kind != TTI_X86 {
            if !ic_fn_str_eq(caller, callee, "target-cpu") || !ic_fn_str_eq(caller, callee, "target-features") { return false; }
        } else if !x86_are_types_abi_compatible(caller, callee, tys, m) { return false; }
    }
    return true;
}

// AttributeFuncs::updateMinLegalVectorWidthAttr(Fn, Width)
fn ap_update_min_legal_vector_width(f: i32, width: u64) {
    let a = fn_str_attr(f, "min-legal-vector-width");
    if a < 0 { return; }
    let s = sbytes(attrs[a].sval);
    var old: u64 = 0;
    var ok = s.len > 0;
    for c in s { if c < '0' || c > '9' { ok = false; } else { old = old * 10 + ((c - '0') as u64); } }
    if !ok { ap_fail("a non-decimal min-legal-vector-width"); }
    if width > old {
        var buf: u8[>..] = [];
        format_u64_dec(buf, width);
        fn_add_attr(f, 0, attr_str("min-legal-vector-width", buf, true));
    }
}

// The promoted arguments: ap_pa_arg (argument index), parts in ap_pp_* from ap_pa_at for ap_pa_n parts
var ap_pa_arg: i64[>..<];
var ap_pa_at: i64[>..<];
var ap_pa_n: i64[>..<];
var ap_pp_off: i64[>..<];
var ap_pp_ty: i32[>..<];
var ap_pp_al: i64[>..<];
var ap_pp_mx: i32[>..<];
fn ap_promoted(k: i64) -> i64 { for x, i in ap_pa_arg { if x == k { return i; } } return -1; }

// doPromotion(F, FAM, ArgsToPromote)
fn ap_do_promotion(f: i32) -> i32 {
    let g = glob_of(f);
    let fty = globs[g].vty;
    let pal = globs[g].attrs;
    var params: i32[>..<] = [];
    var arg_attrs: i32[>..<] = [];
    var new_idx: i64[>..<] = [];
    var nan: i64 = 0;
    let nargs = func_nargs(f);
    for k in nargs {
        let p = ap_promoted(k);
        let a = func_arg(f, k);
        if p < 0 {
            params.push(vals[a].ty);
            arg_attrs.push(alist_param(pal, k));
            new_idx.push(nan);
            nan++;
        } else if first_use(a) < 0 {
            new_idx.push(-1);
        } else {
            for j in ap_pa_n[p] { params.push(ap_pp_ty[ap_pa_at[p] + j]); arg_attrs.push(0); }
            new_idx.push(-1);
            nan += ap_pa_n[p];
        }
    }
    let ret_ty = ty_fn_ret(fty);
    let nfty = ty_func_of(ret_ty, params, ty_fn_vararg(fty));
    let m = globs[g].module;
    let nf = ig_new_function(m, nfty, gv_linkage(f), ptr_as(vals[f].ty));
    let fname = vals[f].name;
    ig_fn_copy_attributes_from(nf, f);
    // NF->copyMetadata(F, 0)
    let fg = globs[g];
    for k in fg.nmd {
        let kind = md_att[fg.md + 2 * k];
        if kind == md_kind_id("type") { ap_fail("copyMetadata of !type attachments"); }
        glob_add_md(nf, kind, md_att[fg.md + 2 * k + 1]);
    }
    // F->setSubprogram(nullptr)
    ap_erase_glob_md(f, 0);
    var largest: u64 = 0;
    for t in params {
        let k = ty_kind(t);
        if k == TK_FVEC || k == TK_SVEC {
            let w = (ty_count(t) * ic::ty_prim_bits_any(ty_elem(t))) as u64;
            if w > largest { largest = w; }
        }
    }
    var sets: i32[>..<] = [];
    sets.push(alist_fn(pal));
    sets.push(alist_ret(pal));
    for s in arg_attrs { sets.push(s); }
    globs[glob_of(nf)].attrs = alist_get(sets);
    let asz = aset_find(alist_fn(globs[glob_of(nf)].attrs), AK_AllocSize);
    if asz >= 0 {
        let raw = attrs[asz].i1;
        let e = (raw >> 32) as! i64;
        let n = (raw & 0xFFFFFFFF) as! i64;
        let a1 = new_idx[e];
        var a2: u64 = 0xFFFFFFFF;
        if n != 0xFFFFFFFF { a2 = new_idx[n] as! u64; }
        fn_add_attr(nf, 0, attr_int(AK_AllocSize, ((a1 as! u64) << 32) | a2));
    }
    ap_update_min_legal_vector_width(nf, largest);
    // getFunctionList().insert(F, NF) with NF named like F: the module symbol table makes the name unique first
    ig_insert_global_before(nf, f);
    if fname >= 0 { symtab_set_name(modules[m].symtab, nf, sbytes(fname), true); }
    ig_take_name(nf, f);
    var args: i32[>..<] = [];
    var cattrs: i32[>..<] = [];
    var dead_args: i32[>..<] = [];
    loop {
        var u = first_use(f);
        while u >= 0 && vals[uses[u].user].kind == VK_BLOCKADDR { u = use_next(u); }
        if u < 0 { break; }
        let cb = uses[u].user;
        let cpal = insts[inst_of(cb)].attrs;
        args.clear();
        cattrs.clear();
        for k in nargs {
            let p = ap_promoted(k);
            let av = cb_arg(cb, k);
            if p < 0 {
                args.push(av);
                cattrs.push(alist_param(cpal, k));
            } else if first_use(func_arg(f, k)) >= 0 {
                for j in ap_pa_n[p] {
                    let x = ap_pa_at[p] + j;
                    let ty = ap_pp_ty[x];
                    var ptr = av;
                    if ap_pp_off[x] != 0 {
                        ptr = create_inst(OP_GEP, vals[av].ty, [av, c_int(ty_int(dl_ptr(ptr_as(vals[av].ty)).idx), ap_pp_off[x])]);
                        insts[inst_of(ptr)].ty2 = ty_int(8);
                        ap_builder_insert(ptr, "", cb);
                    }
                    let li = create_inst(OP_LOAD, ty, [ptr]);
                    insts[inst_of(li)].align = ap_log2a(ap_pp_al[x]);
                    var nm: u8[>..] = [];
                    nm.append(val_name(av));
                    nm.append(".val");
                    ap_builder_insert(li, nm, cb);
                    let mx = ap_pp_mx[x];
                    if mx >= 0 {
                        let aa_kinds: const u8[:][] = ["tbaa", "tbaa.struct", "alias.scope", "noalias", "noalias.addrspace"];
                        for kn in aa_kinds { let kid = md_kind_id(kn); inst_set_md(li, kid, inst_get_md(mx, kid)); }
                        let cp_kinds: const u8[:][] = ["dereferenceable", "dereferenceable_or_null", "noundef", "nontemporal"];
                        for kn in cp_kinds { let kid = md_kind_id(kn); let md = inst_get_md(mx, kid); if md >= 0 { inst_set_md(li, kid, md); } }
                        if inst_get_md(li, md_kind_id("noundef")) >= 0 {
                            let pg_kinds: const u8[:][] = ["range", "nonnull", "align", "nofpclass"];
                            for kn in pg_kinds { let kid = md_kind_id(kn); let md = inst_get_md(mx, kid); if md >= 0 { inst_set_md(li, kid, md); } }
                        }
                    }
                    args.push(li);
                    cattrs.push(0);
                }
            } else {
                dead_args.push(av);
            }
        }
        let na = cb_nargs(cb);
        var pi = nargs;
        while pi < na { args.push(cb_arg(cb, pi)); cattrs.push(alist_param(cpal, pi)); pi++; }
        var ncb: i32 = -1;
        if iop(cb) == OP_INVOKE { ncb = ig_create_call_like(cb, nfty, nf, args, cb, -1); }
        else {
            ncb = ig_create_call_like(cb, nfty, nf, args, cb, -1);
            insts[inst_of(ncb)].pred = insts[inst_of(cb)].pred;
        }
        insts[inst_of(ncb)].cc = insts[inst_of(cb)].cc;
        var csets: i32[>..<] = [];
        csets.push(alist_fn(cpal));
        csets.push(alist_ret(cpal));
        for s in cattrs { csets.push(s); }
        insts[inst_of(ncb)].attrs = alist_get(csets);
        ig_copy_prof_dbg(ncb, cb);
        ap_update_min_legal_vector_width(inst_func(cb), largest);
        if first_use(cb) >= 0 {
            rauw(cb, ncb);
            ig_take_name(ncb, cb);
        }
        inst_erase_from_parent(cb);
    }
    ap_rdtdi_permissive(dead_args);
    ig_splice_body(nf, f);
    var allocas: i32[>..<] = [];
    var i2: i64 = 0;
    for k in nargs {
        let a = func_arg(f, k);
        let p = ap_promoted(k);
        if p < 0 {
            let a2 = func_arg(nf, i2);
            rauw(a, a2);
            ig_take_name(a2, a);
            i2++;
            continue;
        }
        if first_use(a) < 0 { rauw(a, c_poison(vals[a].ty)); continue; }
        // IRBuilder<NoFolder> IRB(&NF->begin()->front())
        let front = block_first(func_entry(nf));
        var off_alloca_off: i64[>..<] = [];
        var off_alloca_ai: i32[>..<] = [];
        for j in ap_pa_n[p] {
            let x = ap_pa_at[p] + j;
            let off = ap_pp_off[x];
            let na2 = func_arg(nf, i2);
            i2++;
            var nm: u8[>..] = [];
            nm.append(val_name(a));
            nm.push('.');
            format(nm, off);
            nm.append(".val");
            set_name(na2, nm);
            let ai = create_inst(OP_ALLOCA, ty_ptr(dl_alloca_addr_space), [c_int(T_I32, 1)]);
            insts[inst_of(ai)].ty2 = ap_pp_ty[x];
            insts[inst_of(ai)].align = ap_log2a(ap_pp_al[x]);
            var an: u8[>..] = [];
            an.append(val_name(a));
            an.push('.');
            format(an, off);
            an.append(".allc");
            ap_builder_insert(ai, an, front);
            let si = create_inst(OP_STORE, T_VOID, [na2, ai]);
            insts[inst_of(si)].align = ap_log2a(ap_pp_al[x]);
            ap_builder_insert(si, "", front);
            off_alloca_off.push(off);
            off_alloca_ai.push(ai);
        }
        var wl: i32[>..<] = [];
        var u = first_use(a);
        while u >= 0 { wl.push(uses[u].user); u = use_next(u); }
        var dead: i32[>..<] = [];
        while wl.len > 0 {
            let v = wl.pop();
            if is_inst(v) && iop(v) == OP_GEP {
                dead.push(v);
                var w = first_use(v);
                while w >= 0 { wl.push(uses[w].user); w = use_next(w); }
                continue;
            }
            if is_inst(v) && (iop(v) == OP_LOAD || iop(v) == OP_STORE) {
                let pk: i64 = if iop(v) == OP_LOAD { 0 } else { 1 };
                strip_and_accumulate_offsets(op(v, pk), true, false, false);
                let off = vt_off;
                var ai: i32 = -1;
                for q in off_alloca_off.len { if off_alloca_off[q] == off { ai = off_alloca_ai[q]; } }
                set_op(v, pk, ai);
                continue;
            }
            fatal("internal: argpromotion: unexpected user of a promoted argument");
        }
        for d in dead {
            rauw(d, c_poison(vals[d].ty));
            inst_erase_from_parent(d);
        }
        // the allocas in SmallDenseMap<int64_t, AllocaInst *> order (4 inline buckets, hash Val * 37)
        ap_dense_map_order(off_alloca_off, off_alloca_ai, allocas);
        rauw(a, c_poison(vals[a].ty));
    }
    if allocas.len > 0 {
        dt_get_for(nf);
        promote_mem_to_reg(nf, allocas);
    }
    if dinfo_func_subprogram(nf) >= 0 { ig_mark_subprogram_nocall(nf); }
    return nf;
}
fn dt_get_for(f: i32) { aa_begin(f); }
fn ap_log2a(a: i64) -> u8 { var k: u8 = 0; while (1 << k) < a { k++; } return k + 1; }
// an IRBuilder<NoFolder> insertion before `pos` (the builder takes pos's debug location)
fn ap_builder_insert(i: i32, name: const u8[:], pos: i32) {
    inst_insert_before(i, pos);
    if name.len > 0 { set_name(i, name); }
    let d = inst_get_md(pos, 0);
    if d >= 0 { inst_set_md(i, 0, d); }
}
fn ap_erase_glob_md(f: i32, kind: i32) {
    let g = glob_of(f);
    let at = globs[g].md;
    var w: i32 = 0;
    for k in globs[g].nmd {
        if md_att[at + 2 * k] == kind { continue; }
        md_att[at + 2 * w] = md_att[at + 2 * k];
        md_att[at + 2 * w + 1] = md_att[at + 2 * k + 1];
        w++;
    }
    globs[g].nmd = w;
}
// RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadArgs)
fn ap_rdtdi_permissive(list: i32[>..<]&) {
    var keep: i32[>..<] = [];
    for d in list { if !is_dead(d) && is_inst(d) && is_instruction_trivially_dead(d) { keep.push(d); } }
    if keep.len == 0 { return; }
    recursively_delete_trivially_dead(keep);
}
// iteration order of a SmallDenseMap<int64_t, V, 4> holding at most 4 entries (DenseMapInfo<int64_t>: hash
// Val * 37, quadratic probing over 4 buckets)
fn ap_dense_map_order(keys: i64[>..<]&, vs: i32[>..<]&, out: i32[>..<]&) {
    if keys.len > 4 { ap_fail("more than 4 promoted parts of one argument"); }
    var bucket: i64[4] = [-1, -1, -1, -1];
    for k in keys.len {
        var b = (((keys[k] as! u64) * 37) & 3) as! i64;
        var probe: i64 = 1;
        while bucket[b] >= 0 { b = (b + probe) & 3; probe++; }
        bucket[b] = k;
    }
    for b in 4 { if bucket[b] >= 0 { out.push(vs[bucket[b]]); } }
}

// promoteArguments(F, FAM, MaxElements, IsRecursive)
fn ap_promote_arguments(f: i32, is_rec0: bool) -> i32 {
    var is_recursive = is_rec0;
    if fn_has(f, 0, AK_Naked) { return -1; }
    if !gv_has_local_linkage(f) { return -1; }
    if gv_may_be_derefined(f) { return -1; }
    let fty = globs[glob_of(f)].vty;
    if ty_fn_vararg(fty) { return -1; }
    if dae_has_attr_somewhere(f, AK_InAlloca) { return -1; }
    var ptr_args: i32[>..<] = [];
    for k in func_nargs(f) { let a = func_arg(f, k); if ty_kind(vals[a].ty) == TK_PTR { ptr_args.push(a); } }
    if ptr_args.len == 0 { return -1; }
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        let nu = use_next(u);
        if vals[cb].kind == VK_BLOCKADDR { u = nu; continue; }
        if !is_inst(cb) || !is_callbase(cb) || (u - vals[cb].ops) as i64 != nops(cb) - 1 || insts[inst_of(cb)].ty2 != fty { return -1; }
        if dae_is_musttail(cb) { return -1; }
        if inst_func(cb) == f { is_recursive = true; }
        u = nu;
    }
    var b = func_first_block(f);
    while b >= 0 { if dae_terminating_musttail(b) >= 0 { return -1; } b = block_next(b); }
    aa_begin(f);
    let m = globs[glob_of(f)].module;
    ap_pa_arg.clear(); ap_pa_at.clear(); ap_pa_n.clear();
    ap_pp_off.clear(); ap_pp_ty.clear(); ap_pp_al.clear(); ap_pp_mx.clear();
    var num_after = ty_fn_nparams(fty);
    for pa in ptr_args {
        let argno = args_no[vals[pa].sub] as i64;
        if aset_has(alist_param(globs[glob_of(f)].attrs, argno), AK_StructRet) {
            fn_set_aset(f, 2 + argno, aset_without(fn_aset(f, 2 + argno), [AK_StructRet]));
            fn_add_attr(f, 2 + argno, attr_enum(AK_NoAlias));
            var w = first_use(f);
            while w >= 0 {
                let cb = uses[w].user;
                w = use_next(w);
                if vals[cb].kind == VK_BLOCKADDR { continue; }
                let s = aset_without(cb_param_set(cb, argno), [AK_StructRet]);
                cb_set_param_set(cb, argno, aset_add_enum_ap(s, AK_NoAlias));
            }
        }
        if ap_find_arg_parts(pa, is_recursive) {
            var tys: i32[>..<] = [];
            for t in ap_ty { tys.push(t); }
            if ap_types_abi_compatible(tys, f) {
                num_after += ap_off.len - 1;
                ap_pa_arg.push(argno);
                ap_pa_at.push(ap_pp_off.len);
                ap_pa_n.push(ap_off.len);
                for k in ap_off.len { ap_pp_off.push(ap_off[k]); ap_pp_ty.push(ap_ty[k]); ap_pp_al.push(ap_al[k]); ap_pp_mx.push(ap_mx[k]); }
            }
            aa_begin(f);
        } else {
            aa_begin(f);
        }
    }
    if ap_pa_arg.len == 0 { return -1; }
    let _ = m;
    let _ = num_after;   // TTI::getMaxNumArgs() is UINT_MAX on X86 and without a target
    return ap_do_promotion(f);
}
fn aset_add_enum_ap(s: i32, kind: i64) -> i32 {
    if aset_has(s, kind) { return s; }
    var xs: i32[>..<] = [];
    for k in aset_n(s) { xs.push(aset_attr(s, k)); }
    xs.push(attr_enum(kind));
    return aset_get(xs);
}

// ArgumentPromotionPass::run(C, AM, CG, UR)
fn argpromotion_run_cgscc(c: i32) -> u32 {
    var changed = false;
    loop {
        var local = false;
        let is_recursive = lcg_scc_size(c) > 1;
        for k in lcg_scc_size(c) {
            let n = lcg_scc_node(c, k);
            let oldf = lcg_fn(n);
            let nf = ap_promote_arguments(oldf, is_recursive);
            if nf < 0 { continue; }
            local = true;
            lcg_replace_node_function(n, nf);
            invalidate_function(oldf, PA_NONE);
            ig_erase_global(oldf, false);
            var u = first_use(nf);
            while u >= 0 {
                let cb = uses[u].user;
                u = use_next(u);
                if vals[cb].kind == VK_BLOCKADDR { continue; }
                invalidate_function(inst_func(cb), PA_CFG);
            }
        }
        if local { changed = true; } else { break; }
    }
    if !changed { return PA_ALL; }
    return PA_FN | ((1 as u32) << A_FAMPROXY);
}
