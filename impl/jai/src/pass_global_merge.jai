// GlobalMerge (`global-merge`, `global-merge<...>`): port of llvm/lib/CodeGen/GlobalMerge.cpp (GlobalMergePass::run,
// GlobalMergeImpl::run, doMerge (both), setMustKeepGlobalVariables, collectUsedGlobalVariables) with
// GlobalObject::copyMetadata(Src, Offset) (llvm/lib/IR/Metadata.cpp), TargetMachine::shouldAssumeDSOLocal and
// TargetLoweringObjectFile::getKindForGlobal's BSS test (isSuitableForBSS).
//
// The new pass manager's GlobalMergePass takes its options from the pass parameters only (GlobalMergeOptions
// defaults: max-offset 0, so nothing merges without max-offset=N); doMerge still reads the cl::opts
// -global-merge-group-by-use and -global-merge-ignore-single-use directly, and run reads -enable-global-merge.

gm_cl: struct {
    enable := true;                // -enable-global-merge
    group_by_use := true;          // -global-merge-group-by-use
    ignore_single_use := true;     // -global-merge-ignore-single-use
}
// the other cl::opts only feed the legacy pass (GlobalMerge / createGlobalMergePass): accepted and unused
gm_parse_legacy_only :: (name: string) -> bool {
    return name == "global-merge-max-offset" || name == "global-merge-all-const" || name == "global-merge-on-const" ||
           name == "global-merge-on-external" || name == "global-merge-min-data-size";
}

Gm_Opts :: struct {
    max_offset: u64 = 0;
    min_size: u64 = 0;
    group_by_use := true;          // (unused by the implementation, like LLVM's)
    ignore_single_use := true;     // (unused by the implementation, like LLVM's)
    merge_external := true;
    merge_const := false;
    merge_const_aggressive := false;
    size_only := false;
}

// parseGlobalMergeOptions
gm_parse_options :: (name: string) -> Gm_Opts {
    o: Gm_Opts;
    if name == "global-merge" return o;
    params := slice(name, "global-merge<".count, name.count - "global-merge<".count - 1);
    while params.count {
        p := params;
        semi := find_index_from_left(params, #char ";");
        if semi >= 0 { p = slice(params, 0, semi); params = slice(params, semi + 1, params.count - semi - 1); }
        else params = "";
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "group-by-use" o.group_by_use = enable;
        else if p == "ignore-single-use" o.ignore_single_use = enable;
        else if p == "merge-const" o.merge_const = enable;
        else if p == "merge-const-aggressive" o.merge_const_aggressive = enable;
        else if p == "merge-external" o.merge_external = enable;
        else if begins_with(p, "max-offset=") {
            v := slice(p, 11, p.count - 11);
            n, ok := string_to_int(v, 10, u64);
            if !ok || v.count == 0 fatal(tprint("invalid GlobalMergePass parameter '%'", v));
            o.max_offset = n;
        } else fatal(tprint("invalid global-merge pass parameter '%'", params));
    }
    return o;
}

Gm :: struct {
    opt: Gm_Opts;
    st: *X86_Lowering;        // TM (null without a target triple)
    is_macho: bool;
    must_keep: [..] Value_Id;
}

gm_must_keep :: (g: *Gm, gv: Value_Id) -> bool { for g.must_keep if it == gv return true; return false; }
gm_keep :: (g: *Gm, gv: Value_Id) { if !gm_must_keep(g, gv) array_add(*g.must_keep, gv); }

// collectUsedGlobalVariables
gm_collect_used :: (g: *Gm, name: string) {
    gv := module_get_global_variable(name);
    if gv == NONE || !glob(gv).has_init return;
    init := gv_initializer(gv);
    if vkind(init) != .C_ARRAY fatal("global-merge: % initializer that is not a ConstantArray", name);
    for k: 0..cast(s64) nops(init) - 1 {
        e := strip_pointer_casts(op(init, cast(u32) k));
        if vkind(e) == .GLOBAL_VAR gm_keep(g, e);
    }
}

// setMustKeepGlobalVariables
gm_set_must_keep :: (g: *Gm) {
    gm_collect_used(g, "llvm.used");
    gm_collect_used(g, "llvm.compiler.used");
    for f: ir.m_functions for bb: fn_blocks(f) {
        pad := block_first_non_phi(bb);
        if pad == NONE continue;
        if !is_eh_pad(pad) && !(inst_op(pad) == .CALL && iid_name(call_iid(pad)) == "llvm.eh.typeid.for") continue;
        for k: 0..cast(s64) nops(pad) - 1 {
            u := strip_pointer_casts(op(pad, cast(u32) k));
            if u == NONE continue;
            if vkind(u) == .GLOBAL_VAR gm_keep(g, u);
            else if vkind(u) == .C_ARRAY {
                for e: 0..cast(s64) nops(u) - 1 {
                    x := strip_pointer_casts(op(u, cast(u32) e));
                    if vkind(x) == .GLOBAL_VAR gm_keep(g, x);
                }
            }
        }
    }
}

gm_is_special_macho_section :: (s: string) -> bool {
    return begins_with(s, "__DATA,__cfstring") || begins_with(s, "__DATA,__objc_classrefs") || begins_with(s, "__DATA,__objc_selrefs");
}

// GlobalVariable::hasImplicitSection
gm_has_implicit_section :: (gv: Value_Id) -> bool {
    for attr_set_items(glob(gv).attrs) if it.kind == .STRING_ATTR &&
        (it.key == "bss-section" || it.key == "data-section" || it.key == "relro-section" || it.key == "rodata-section") return true;
    return false;
}

// isSuitableForBSS (getKindForGlobal(GV, TM).isBSS() for a non-TLS, non-common global; NoZerosInBSS is off)
gm_is_bss :: (gv: Value_Id) -> bool {
    gr := glob(gv);
    if gr.linkage == .COMMON return false;
    init := gv_initializer(gv);
    k := vkind(init);
    if !(is_null_value(init) || k == .C_UNDEF || k == .C_POISON) return false;
    if gr.is_const return false;
    if gr.section.count return false;
    return true;
}

// GlobalObject::copyMetadata(Other, Offset)
gm_copy_metadata :: (dst: Value_Id, src: Value_Id, offset: u64) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(src, *all);
    type_kind_id := md_kind_id("type");
    for all {
        if offset != 0 && it.kind == type_kind_id {
            oc := ir.mds[md_op(it.md, 0)].value;
            nc := const_int_ap(vtype(oc), ap_add(const_ap(oc), ap_from_u64(type_bits(vtype(oc)), offset)));
            ops: [2] Md_Id;
            ops[0] = md_value(nc); ops[1] = md_op(it.md, 1);
            add_metadata(dst, type_kind_id, md_tuple(ops, false));
            continue;
        }
        att := it.md;
        if offset != 0 && it.kind == MDK_DBG {
            var := att; expr: Md_Id = NONE;
            if di_kind(att) == .GLOBAL_VARIABLE_EXPRESSION { var = md_op(att, 0); expr = md_op(att, 1); }
            elts: [..] u64; elts.allocator = temp;
            array_add(*elts, DW_OP_PLUS_UCONST); array_add(*elts, offset);
            if expr != NONE for diexpr_elts(expr) array_add(*elts, it);
            att = di_gve_get(var, diexpr_get(elts));
        }
        add_metadata(dst, it.kind, att);
    }
}

gm_merge_all :: (g: *Gm, globals: [] Value_Id, set: [] bool, is_const: bool, as: u32) -> bool {
    assert(globals.count > 1);
    find_next :: (set: [] bool, from: s64) -> s64 { k := from; while k < set.count { if set[k] return k; k += 1; } return -1; }
    changed := false;
    i := find_next(set, 0);
    while i != -1 {
        j := i;
        merged_size: u64 = 0;
        tys: [..] Type_Id; tys.allocator = temp;
        inits: [..] Value_Id; inits.allocator = temp;
        struct_idxs: [..] u32; struct_idxs.allocator = temp;
        has_external := false;
        first_external_name: string;
        max_align: u64 = 1;
        cur_idx: u32 = 0;
        while j != -1 {
            gv := globals[j];
            ty := glob(gv).value_type;
            alignment := dl_preferred_align_gv(gv);
            padding := ((merged_size + alignment - 1) / alignment) * alignment - merged_size;
            merged_size += padding;
            merged_size += dl_type_alloc_size(ty);
            if merged_size > g.opt.max_offset break;
            if padding {
                pt := type_array(padding, ir.t_i8);
                array_add(*tys, pt);
                array_add(*inits, const_zero(pt));
                cur_idx += 1;
            }
            array_add(*tys, ty);
            array_add(*inits, gv_initializer(gv));
            array_add(*struct_idxs, cur_idx);
            cur_idx += 1;
            max_align = max(max_align, alignment);
            if glob(gv).linkage == .EXTERNAL && !has_external { has_external = true; first_external_name = vname(gv); }
            j = find_next(set, j + 1);
        }
        if tys.count < 2 { i = j; continue; }

        linkage := ifx has_external then Linkage.EXTERNAL else .INTERNAL;
        merged_ty := type_literal_struct(tys, true);
        merged_init := const_aggregate(.C_STRUCT, merged_ty, inits);
        name := ifx g.is_macho && has_external then tconcat("_MergedGlobals_", first_external_name) else "_MergedGlobals";
        merged_linkage := ifx g.is_macho then linkage else .PRIVATE;
        mgv := gv_create(merged_ty, is_const, merged_linkage, merged_init, name, NONE, 0, as);
        glob(mgv).align = max_align;
        glob(mgv).section = glob(globals[i]).section;
        glob(mgv).comdat = glob(globals[i]).comdat;

        k := i;
        idx := 0;
        while k != j {
            gv := globals[k];
            lk := glob(gv).linkage;
            gname := copy_string(vname(gv),, allocator = temp);
            vis := glob(gv).visibility;
            dll := glob(gv).dll;
            gm_copy_metadata(mgv, gv, dl_struct_offset(merged_ty, struct_idxs[idx]));
            idxs: [2] Value_Id;
            idxs[0] = const_int(ir.t_i32, 0);
            idxs[1] = const_int(ir.t_i32, cast(u64) struct_idxs[idx]);
            gep := ce_gep(merged_ty, mgv, idxs, F_INBOUNDS);
            ipo_rauw(gv, gep);
            gv_erase_from_parent(gv);
            if !g.is_macho || lk == .EXTERNAL {
                ga := new_global(.ALIAS, tys[struct_idxs[idx]], as, 1);
                set_op(ga, 0, gep);
                gv_set_linkage(ga, lk);
                array_add(*ir.m_aliases, ga);
                if gname.count set_name(ga, gname);
                gv_set_visibility(ga, vis);
                glob(ga).dll = dll;
            }
            k = find_next(set, k + 1);
            idx += 1;
        }
        // AssignGUIDPass::assignGUIDForMergedGV
        set_metadata(mgv, MDK_UNIQUE_ID, NONE);
        gv_assign_guid(mgv);
        changed = true;
        i = j;
    }
    return changed;
}

// doMerge(Globals, M, isConst, AddrSpace)
gm_do_merge :: (g: *Gm, globals_in: [] Value_Id, is_const: bool, as: u32) -> bool {
    // stable_sort by allocation size
    globals := array_copy(globals_in,, allocator = temp);
    for a: 1..globals.count - 1 {
        b := a;
        while b > 0 && dl_type_alloc_size(glob(globals[b]).value_type) < dl_type_alloc_size(glob(globals[b - 1]).value_type) {
            t := globals[b]; globals[b] = globals[b - 1]; globals[b - 1] = t;
            b -= 1;
        }
    }
    n := globals.count;
    if !gm_cl.group_by_use || (g.opt.merge_const_aggressive && is_const) {
        all := NewArray(n, bool,, allocator = temp);
        for * all it.* = true;
        return gm_merge_all(g, globals, all, is_const, as);
    }
    Ugs :: struct { set: [] bool; count: u32; usage: s64; }
    sets: [..] Ugs; sets.allocator = temp;
    new_set :: (sets: *[..] Ugs, n: s64) -> s64 {
        u: Ugs; u.set = NewArray(n, bool,, allocator = temp); u.usage = 1;
        array_add(sets, u);
        return sets.count - 1;
    }
    sets[new_set(*sets, n)].usage = 0;
    by_fn: Table(Value_Id, s64); by_fn.allocator = temp;   // GlobalUsesByFunction (lookups only)
    encountered: [..] s64; encountered.allocator = temp;
    set_bit :: (u: *Ugs, k: s64) { if !u.set[k] { u.set[k] = true; u.count += 1; } }
    for gi: 0..n - 1 {
        gv := globals[gi];
        encountered.count = 0;
        for 1..sets.count array_add(*encountered, 0);
        cur_only: s64 = 0;
        use := ir.v_first_use[gv];
        while use != NONE {
            defer use = ir.u_next[use];
            user := ir.u_user[use];
            ui: Use_Id; ue: Use_Id;
            if vkind(user) == .C_EXPR {
                if ir.v_first_use[user] == NONE continue;
                ui = ir.v_first_use[user]; ue = NONE;
            } else if is_inst(user) {
                ui = use; ue = ir.u_next[use];
            } else continue;
            while ui != ue {
                defer ui = ir.u_next[ui];
                ii := ir.u_user[ui];
                if !is_inst(ii) continue;
                pf := inst_fn(ii);
                if g.opt.size_only && !fn_has_min_size(pf) continue;
                _, ugs := table_find(*by_fn, pf);
                if !ugs {
                    if !cur_only {
                        cur_only = new_set(*sets, n);
                        set_bit(*sets[cur_only], gi);
                    } else sets[cur_only].usage += 1;
                    table_set(*by_fn, pf, cur_only);
                    continue;
                }
                if sets[ugs].set[gi] { sets[ugs].usage += 1; continue; }
                sets[ugs].usage -= 1;
                expanded := encountered[ugs];
                if expanded {
                    sets[expanded].usage += 1;
                    table_set(*by_fn, pf, expanded);
                    continue;
                }
                ni := new_set(*sets, n);
                table_set(*by_fn, pf, ni);
                encountered[ugs] = ni;
                for k: 0..n - 1 if sets[ugs].set[k] || k == gi set_bit(*sets[ni], k);
            }
        }
    }
    if gm_cl.ignore_single_use {
        all := NewArray(n, bool,, allocator = temp);
        for u: sets {
            if u.usage == 0 continue;
            if u.count > 1 for k: 0..n - 1 if u.set[k] all[k] = true;
        }
        return gm_merge_all(g, globals, all, is_const, as);
    }
    // stable_sort by count * usage
    order := NewArray(sets.count, s64,, allocator = temp);
    for * order it.* = it_index;
    for a: 1..order.count - 1 {
        b := a;
        key :: (u: Ugs) -> s64 { return cast(s64) u.count * u.usage; }
        while b > 0 && key(sets[order[b]]) < key(sets[order[b - 1]]) {
            t := order[b]; order[b] = order[b - 1]; order[b - 1] = t;
            b -= 1;
        }
    }
    picked := NewArray(n, bool,, allocator = temp);
    changed := false;
    r := order.count - 1;
    while r >= 0 {
        defer r -= 1;
        u := sets[order[r]];
        if u.usage == 0 continue;
        common := false;
        for k: 0..n - 1 if picked[k] && u.set[k] { common = true; break; }
        if common continue;
        for k: 0..n - 1 if u.set[k] picked[k] = true;
        if u.count < 2 continue;
        changed |= gm_merge_all(g, globals, u.set, is_const, as);
    }
    return changed;
}

global_merge_run :: (name: string) -> Preserved {
    g: Gm;
    g.opt = gm_parse_options(name);
    g.must_keep.allocator = temp;
    if !gm_cl.enable return PRESERVE_ALL;
    if tti_triple().count {
        t := tti_get_uncached(0);
        if t.kind == .X86 g.st = *t.xl;
    }
    g.is_macho = triple_parse(ir.triple).obj == .MachO;
    gm_set_must_keep(*g);
    Key :: struct { as: u32; section: string; comdat: s32; }
    Group :: struct { key: Key; gvs: [..] Value_Id; }
    add :: (groups: *[..] Group, k: Key, gv: Value_Id) {
        for * groups.* if it.key.as == k.as && it.key.section == k.section && it.key.comdat == k.comdat { array_add(*it.gvs, gv); return; }
        n: Group; n.key = k; n.gvs.allocator = temp;
        array_add(*n.gvs, gv);
        array_add(groups, n);
    }
    globals: [..] Group; globals.allocator = temp;
    consts: [..] Group; consts.allocator = temp;
    bss: [..] Group; bss.allocator = temp;
    list := array_copy(ir.m_globals,, allocator = temp);
    for gv: list {
        gr := glob(gv);
        if is_declaration(gv) || gr.tls != 0 || gm_has_implicit_section(gv) continue;
        if g.st && !x86_should_assume_dso_local(g.st, gv) continue;
        if !(g.opt.merge_external && gr.linkage == .EXTERNAL) && !gv_has_local_linkage(gv) continue;
        as := gr.addrspace;
        section := gr.section;
        if g.is_macho && gm_is_special_macho_section(section) continue;
        nm := vname(gv);
        if begins_with(nm, "llvm.") || begins_with(nm, ".llvm.") || section == "llvm.metadata" continue;
        if gm_must_keep(*g, gv) continue;
        if (gr.sanitizer & 4) != 0 continue;   // isTagged
        if gv_has_metadata_other_than_dbg_and_guid(gv) continue;
        size := dl_type_alloc_size(gr.value_type);
        if !(size < g.opt.max_offset && size >= g.opt.min_size) continue;
        k := Key.{as, section, gr.comdat};
        if g.st && gm_is_bss(gv) add(*bss, k, gv);
        else if gr.is_const add(*consts, k, gv);
        else add(*globals, k, gv);
    }
    changed := false;
    for globals if it.gvs.count > 1 changed |= gm_do_merge(*g, it.gvs, false, it.key.as);
    for bss if it.gvs.count > 1 changed |= gm_do_merge(*g, it.gvs, false, it.key.as);
    if g.opt.merge_const for consts if it.gvs.count > 1 changed |= gm_do_merge(*g, it.gvs, true, it.key.as);
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return preserved_cfg();
}
