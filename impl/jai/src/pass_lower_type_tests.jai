// LowerTypeTestsPass, DropTypeTestsPass, SimplifyTypeTestsPass: lowering of type metadata and llvm.type.test /
// llvm.icall.branch.funnel (bit sets, byte arrays, jump tables, cross-DSO CFI exports, ThinLTO summary import and
// export with the YAML summaries of -lowertypetests-read-summary).
// Ported from llvm/lib/Transforms/IPO/LowerTypeTests.cpp (BitSetBuilder, GlobalLayoutBuilder, ByteArrayBuilder,
// LowerTypeTestsModule, ScopedSaveAliaseesAndUsed, dropTypeTests, SimplifyTypeTestsPass) and
// llvm/include/llvm/Transforms/IPO/LowerTypeTests.h. The module summary is module_summary.jai.
// Not ported: writing summaries (-lowertypetests-write-summary fails loudly); the jump table encodings of other
// targets (arm / thumb / aarch64 / riscv / loongarch / hexagon) and WebAssembly's indirect function indices fail
// loudly (only x86 / x86-64 targets are supported by opt here).

// ---------------------------------------------------------------- command line (runForTesting)

Pass_Summary_Action :: enum u8 { None; Import; Export; }
ltt_cl: struct {
    avoid_reuse := true;
    summary_action: Pass_Summary_Action;
    read_summary: string;
    write_summary: string;
    jump_table_debug_info := true;
};

ltt_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == "lowertypetests-avoid-reuse" { ltt_cl.avoid_reuse = parse_bool(name, value, has_value); return true; }
    if name == "lowertypetests-jump-table-debug-info" { ltt_cl.jump_table_debug_info = parse_bool(name, value, has_value); return true; }
    if name == "lowertypetests-summary-action" {
        if value == {
            case "none"; ltt_cl.summary_action = .None;
            case "import"; ltt_cl.summary_action = .Import;
            case "export"; ltt_cl.summary_action = .Export;
            case; fatal("invalid value '%' for option -lowertypetests-summary-action", value);
        }
        return true;
    }
    if name == "lowertypetests-read-summary" { ltt_cl.read_summary = copy_string(value); return true; }
    if name == "lowertypetests-write-summary" { ltt_cl.write_summary = copy_string(value); return true; }
    return false;
}

// ---------------------------------------------------------------- BitSetBuilder / GlobalLayoutBuilder / ByteArrayBuilder

Ltt_Bsi :: struct {        // BitSetInfo
    bits: [..] u64;        // std::set<uint64_t>: sorted, unique
    byte_offset: u64;
    bit_size: u64;
    align_log2: u64;
}
bsi_is_all_ones :: (b: *Ltt_Bsi) -> bool { return cast(u64) b.bits.count == b.bit_size; }

u64_set_insert :: (s: *[..] u64, v: u64) {
    lo := 0; hi := s.count;
    while lo < hi { mid := (lo + hi) / 2; if s.*[mid] < v lo = mid + 1; else hi = mid; }
    if lo < s.count && s.*[lo] == v return;
    array_insert_at(s, v, lo);
}

// BitSetBuilder(Offsets).build()
ltt_build_bit_set :: (offsets_in: [] u64) -> Ltt_Bsi {
    min: u64 = 0xFFFF_FFFF_FFFF_FFFF; max: u64 = 0;
    for offsets_in { if it < min min = it; if it > max max = it; }
    if min > max min = 0;
    offsets := array_copy(offsets_in,, allocator = temp);
    mask: u64 = 0;
    for * offsets { it.* -= min; mask |= it.*; }
    bsi: Ltt_Bsi;
    bsi.bits.allocator = temp;
    bsi.byte_offset = min;
    bsi.align_log2 = 0;
    if mask != 0 bsi.align_log2 = cast(u64) ctz64(mask);
    bsi.bit_size = ((max - min) >> bsi.align_log2) + 1;
    for offsets u64_set_insert(*bsi.bits, bsi.bit_size - 1 - (it >> bsi.align_log2));
    return bsi;
}

// GlobalLayoutBuilder::addFragment; Fragments[0] is the unused fragment the constructor creates
Ltt_Glb :: struct {
    fragments: [..] [..] u64;
    fragment_map: [..] u64;
}
glb_init :: (g: *Ltt_Glb, n: s64) {
    g.fragments.allocator = temp; g.fragment_map.allocator = temp;
    e: [..] u64; e.allocator = temp;
    array_add(*g.fragments, e);
    for 0..n-1 array_add(*g.fragment_map, 0);
}
glb_add_fragment :: (g: *Ltt_Glb, f: [] u64) {
    e: [..] u64; e.allocator = temp;
    array_add(*g.fragments, e);
    fi := cast(u64) g.fragments.count - 1;
    for obj: f {
        old := g.fragment_map[obj];
        if old == 0 {
            array_add(*g.fragments[fi], obj);
        } else {
            for g.fragments[old] array_add(*g.fragments[fi], it);
            g.fragments[old].count = 0;
        }
    }
    for g.fragments[fi] g.fragment_map[it] = fi;
}

// ByteArrayBuilder
Ltt_Bab :: struct {
    bytes: [..] u8;
    bit_allocs: [8] u64;
}
bab_allocate :: (b: *Ltt_Bab, bits: [] u64, bit_size: u64) -> (offset: u64, mask: u8) {
    bit := 0;
    for i: 1..7 if b.bit_allocs[i] < b.bit_allocs[bit] bit = i;
    off := b.bit_allocs[bit];
    req := cast(u32) (off + bit_size);   // unsigned ReqSize
    b.bit_allocs[bit] = req;
    while cast(u64) b.bytes.count < req array_add(*b.bytes, 0);
    m := cast(u8) (1 << bit);
    for bits b.bytes[off + it] |= m;
    return off, m;
}

// ---------------------------------------------------------------- the module state

Ltt_Gtm :: struct {        // GlobalTypeMember
    go: Value_Id;
    types: [..] Md_Id;
    jt_canonical: bool;
    exported: bool;
}
Ltt_Funnel :: struct {     // ICallBranchFunnel
    ci: Value_Id;
    targets: [..] s32;     // GTM indices
    unique_id: u32;
}
Ltt_Til :: struct {        // TypeIdLowering
    kind: Tt_Kind = .Unsat;
    offseted_global: Value_Id = NONE;
    align_log2: Value_Id = NONE;
    size_m1: Value_Id = NONE;
    byte_array: Value_Id = NONE;
    bit_mask: Value_Id = NONE;
    inline_bits: Value_Id = NONE;
}
Ltt_Bai :: struct {        // ByteArrayInfo
    bits: [..] u64;
    bit_size: u64;
    byte_array: Value_Id;
    mask_global: Value_Id;
    mask_tid: s64 = -1;    // MaskPtr: the exported TypeIdSummary whose TTRes.BitMask receives the mask
}
Ltt_Tid_User :: struct { call_sites: [..] Value_Id; exported: bool; }
Ltt_Tid_Info :: struct { unique_id: u32; ref_globals: [..] s32; }

// EquivalenceClasses<PointerUnion<GlobalTypeMember *, Metadata *, ICallBranchFunnel *>>: members in insertion
// order, each class a list starting at its leader (unionSets appends the second list to the first)
Ltt_Ec_Kind :: enum u8 { GTM; TYPE_ID; FUNNEL; }
Ltt_Ec_Node :: struct { kind: Ltt_Ec_Kind; id: u32; leader: s32; next: s32 = -1; last: s32; }
Ltt_Ec :: struct {
    nodes: [..] Ltt_Ec_Node;
    map: Table(u64, s32);
}
ec_key :: (k: Ltt_Ec_Kind, id: u32) -> u64 { return ((cast(u64) k) << 32) | cast(u64) id; }
ec_insert :: (ec: *Ltt_Ec, k: Ltt_Ec_Kind, id: u32) -> s32 {
    found, n := table_find(*ec.map, ec_key(k, id));
    if found return n;
    x := cast(s32) ec.nodes.count;
    array_add(*ec.nodes, .{k, id, x, -1, x});
    table_add(*ec.map, ec_key(k, id), x);
    return x;
}
ec_find_leader :: (ec: *Ltt_Ec, n: s32) -> s32 { return ec.nodes[n].leader; }
ec_union :: (ec: *Ltt_Ec, l1: s32, l2: s32) -> s32 {
    if l1 == l2 return l1;
    ec.nodes[ec.nodes[l1].last].next = l2;
    ec.nodes[l1].last = ec.nodes[l2].last;
    x := l2;
    while x >= 0 { ec.nodes[x].leader = l1; x = ec.nodes[x].next; }
    return l1;
}

Ltt :: struct {
    export_summary: *Summary_Index;
    import_summary: *Summary_Index;
    arch: Triple_Arch;
    os: Triple_OS;
    obj: Triple_Object_Format;
    int_ptr_ty: Type_Id;
    tid_users: Table(Md_Id, s64);
    users: [..] Ltt_Tid_User;
    bais: [..] Ltt_Bai;
    weak_init_fn: Value_Id = NONE;
    global_annotation: Value_Id = NONE;
    fn_annotations: [..] Value_Id;
    cross_dso: bool;
    gtms: [..] Ltt_Gtm;
    funnels: [..] Ltt_Funnel;
}

ltt_new :: (export_summary: *Summary_Index, import_summary: *Summary_Index) -> *Ltt {
    l := New(Ltt,, allocator = temp);
    l.tid_users.allocator = temp; l.users.allocator = temp; l.bais.allocator = temp; l.fn_annotations.allocator = temp;
    l.gtms.allocator = temp; l.funnels.allocator = temp;
    l.export_summary = export_summary;
    l.import_summary = import_summary;
    t := triple_parse(ir.triple);
    l.arch = t.arch; l.os = t.os; l.obj = t.obj;
    l.int_ptr_ty = type_int(dl_ptr_spec(0).bits);
    l.cross_dso = module_flag("Cross-DSO CFI") != NONE;
    if l.arch == .arm || l.arch == .thumb fatal("lowertypetests: ARM / Thumb jump tables are not supported");
    ga := module_get_global_variable("llvm.global.annotations", true);
    if ga != NONE {
        l.global_annotation = ga;
        if glob(ga).has_init {
            ca := gv_initializer(ga);
            if vkind(ca) != .C_ARRAY fatal("lowertypetests: llvm.global.annotations initializer is not a ConstantArray");
            for k: 0..nops(ca)-1 if !array_find(l.fn_annotations, op(ca, k)) array_add(*l.fn_annotations, op(ca, k));
        }
    }
    return l;
}

ltt_users_of :: (l: *Ltt, tid: Md_Id) -> *Ltt_Tid_User {
    found, k := table_find(*l.tid_users, tid);
    if !found {
        u: Ltt_Tid_User; u.call_sites.allocator = temp;
        array_add(*l.users, u);
        k = l.users.count - 1;
        table_add(*l.tid_users, tid, k);
    }
    return *l.users[k];
}

ltt_is_x86 :: (l: *Ltt) -> bool { return l.arch == .x86 || l.arch == .x86_64; }

// GlobalObject::getMetadata(MD_type, Types)
ltt_type_mds :: (go: Value_Id, out: *[..] Md_Id) {
    out.count = 0;
    kt := md_fixed("type");
    a := ir.v_md[go];
    while a != NONE { if ir.attaches[a].kind == kt array_add(out, ir.attaches[a].md); a = ir.attaches[a].next; }
}
// cast<ConstantInt>(cast<ConstantAsMetadata>(Type->getOperand(0))->getValue())->getZExtValue()
ltt_type_offset :: (t: Md_Id) -> u64 {
    m := md_op(t, 0);
    return const_int_zext(ir.mds[m].value);
}

// GlobalAlias::create(Ty, AddressSpace = 0, Linkage, Name, Aliasee, &M)
ltt_alias_create :: (ty: Type_Id, linkage: Linkage, name: string, aliasee: Value_Id) -> Value_Id {
    ga := new_global(.ALIAS, ty, 0, 1);
    set_op(ga, 0, aliasee);
    gv_set_linkage(ga, linkage);
    array_add(*ir.m_aliases, ga);
    if name.count set_name(ga, name);
    return ga;
}
// Function::Create(Ty, Linkage, AddrSpace, Name, &M)
ltt_fn_create :: (ft: Type_Id, linkage: Linkage, as: u32, name: string) -> Value_Id {
    f := new_function(ft, "", as);
    gv_set_linkage(f, linkage);
    array_add(*ir.m_functions, f);
    if name.count set_name(f, name);
    return f;
}
// InlineAsm::get(FTy, AsmString, Constraints, hasSideEffects): uniqued like the parser's inline asm values
inline_asm_get :: (fty: Type_Id, s: string, c: string, flags: u32) -> Value_Id {
    ty := type_ptr(0);
    k := const_key_begin(.INLINE_ASM, ty);
    key_str(k, s); key_str(k, c); key_u32(k, flags); key_u32(k, fty);
    found, v := table_find(*ir.const_map, key_view(k));
    if found return v;
    aux := cast(u32) inline_asms.count;
    array_add(*inline_asms, .{intern_str(s), intern_str(c), flags, fty});
    return const_lookup_or_create(k, .INLINE_ASM, ty, .[], aux);
}

// ---------------------------------------------------------------- isKnownTypeIdMember / lowering one type test

ltt_is_known_type_id_member :: (type_id: Md_Id, v: Value_Id, coffset_in: u64) -> bool {
    coffset := coffset_in;
    k := vkind(v);
    if k == .GLOBAL_VAR || k == .FUNCTION {
        types: [..] Md_Id; types.allocator = temp;
        ltt_type_mds(v, *types);
        for t: types {
            if md_op(t, 1) != type_id continue;
            if coffset == ltt_type_offset(t) return true;
        }
        return false;
    }
    o := opr_code(v);
    if o == .GEP {
        ok, ap := gep_accumulate_constant_offset(v, ap_zero(dl_index_size_bits(0)));
        if !ok return false;
        coffset += ap_zext_value(ap);
        return ltt_is_known_type_id_member(type_id, op(v, 0), coffset);
    }
    if o == .BITCAST return ltt_is_known_type_id_member(type_id, op(v, 0), coffset);
    if o == .SELECT
        return ltt_is_known_type_id_member(type_id, op(v, 1), coffset) && ltt_is_known_type_id_member(type_id, op(v, 2), coffset);
    return false;
}

// createMaskedBitTest
ltt_create_masked_bit_test :: (b: *Irb, bits: Value_Id, bit_offset_in: Value_Id) -> Value_Id {
    bty := vtype(bits);
    w := type_int_width(bty);
    bit_offset := irb_zext_or_trunc(b, bit_offset_in, bty);
    bit_index := irb_binop(b, .AND, bit_offset, const_int(bty, cast(u64) w - 1));
    bit_mask := irb_binop(b, .SHL, const_int(bty, 1), bit_index);
    masked := irb_binop(b, .AND, bits, bit_mask);
    return irb_icmp(b, ICMP_NE, masked, const_int(bty, 0));
}

// createBitSetTest
ltt_create_bit_set_test :: (l: *Ltt, b: *Irb, til: *Ltt_Til, bit_offset: Value_Id) -> Value_Id {
    if til.kind == .Inline return ltt_create_masked_bit_test(b, til.inline_bits, bit_offset);
    byte_array := til.byte_array;
    if ltt_cl.avoid_reuse && l.import_summary == null
        byte_array = ltt_alias_create(ir.t_i8, .PRIVATE, "bits_use", byte_array);
    byte_addr := irb_gep(b, ir.t_i8, byte_array, .[bit_offset]);
    byte := irb_load(b, ir.t_i8, byte_addr, 1);
    and := irb_binop(b, .AND, byte, ce_cast(.PTRTOINT, til.bit_mask, ir.t_i8));
    return irb_icmp(b, ICMP_NE, and, const_int(ir.t_i8, 0));
}

// lowerTypeTestCall: the value to replace the call with (NONE = keep the call)
ltt_lower_type_test_call :: (l: *Ltt, type_id: Md_Id, ci: Value_Id, til: *Ltt_Til) -> Value_Id {
    if til.kind == .Unknown return NONE;
    if til.kind == .Unsat return const_int(ir.t_i1, 0);
    ptr := op(ci, 0);
    if ltt_is_known_type_id_member(type_id, ptr, 0) return const_int(ir.t_i1, 1);
    initial_bb := inst_block(ci);
    b: Irb;
    irb_set_before(*b, ci);
    ptr_as_int := irb_cast(*b, .PTRTOINT, ptr, l.int_ptr_ty);
    og_as_int := ce_cast(.PTRTOINT, til.offseted_global, l.int_ptr_ty);
    if til.kind == .Single return irb_icmp(*b, ICMP_EQ, ptr_as_int, og_as_int);
    ptr_offset := irb_binop(*b, .SUB, og_as_int, ptr_as_int);
    bit_offset := irb_intrinsic(*b, "llvm.fshr", .[l.int_ptr_ty], .[ptr_offset, ptr_offset, til.align_log2]);
    in_range := irb_icmp(*b, ICMP_ULE, bit_offset, til.size_m1);
    if til.kind == .AllOnes return in_range;

    // br(llvm.type.test(...), thenbb, elsebb) with nothing in between: split at the call
    u := ir.v_first_use[ci];
    if u != NONE && ir.u_next[u] == NONE {
        br := ir.u_user[u];
        if is_inst(br) && inst_op(br) == .CONDBR && inst_next(ci) == br {
            then_bb := split_basic_block(initial_bb, ci, "");
            els := get_successor(br, 1);
            nbr := create_cond_br(in_range, then_bb, els);
            prof := get_metadata(br, MDK_PROF);
            if prof != NONE set_metadata(nbr, MDK_PROF, prof);
            replace_inst_with_inst(block_terminator(initial_bb), nbr);
            p := block_first(els);
            while p != NONE && inst_op(p) == .PHI {
                k := phi_block_index(p, then_bb);
                phi_add_incoming(p, phi_value(p, cast(u32) k), initial_bb);
                p = inst_next(p);
            }
            tb: Irb;
            irb_set_before(*tb, ci);
            return ltt_create_bit_set_test(l, *tb, til, bit_offset);
        }
    }
    // MDBuilder::createLikelyBranchWeights: (1 << 20) - 1, 1
    likely := md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1048575)), md_value(const_int(ir.t_i32, 1))], false);
    term := sbi_if_then(in_range, ci, false, likely);
    tb: Irb;
    irb_set_before(*tb, term);
    bit := ltt_create_bit_set_test(l, *tb, til, bit_offset);
    irb_set_before(*b, ci);
    p := irb_phi(*b, ir.t_i1, 2);
    phi_add_incoming(p, const_int(ir.t_i1, 0), initial_bb);
    phi_add_incoming(p, bit, tb.bb);
    return p;
}

// createByteArray
ltt_create_byte_array :: (l: *Ltt, bsi: *Ltt_Bsi) -> s64 {
    ba := gv_create(ir.t_i8, true, .PRIVATE, NONE, "", NONE, 0, dl.globals_as);
    mg := gv_create(ir.t_i8, true, .PRIVATE, NONE, "", NONE, 0, dl.globals_as);
    bai: Ltt_Bai;
    bai.bits.allocator = temp;
    for bsi.bits array_add(*bai.bits, it);
    bai.bit_size = bsi.bit_size;
    bai.byte_array = ba;
    bai.mask_global = mg;
    array_add(*l.bais, bai);
    return l.bais.count - 1;
}

// allocateByteArrays
ltt_allocate_byte_arrays :: (l: *Ltt) {
    // llvm::stable_sort by BitSize, largest first
    for i: 1..l.bais.count-1 {
        x := l.bais[i];
        j := i - 1;
        while j >= 0 && l.bais[j].bit_size < x.bit_size { l.bais[j + 1] = l.bais[j]; j -= 1; }
        l.bais[j + 1] = x;
    }
    offsets := NewArray(l.bais.count, u64,, allocator = temp);
    bab: Ltt_Bab;
    bab.bytes.allocator = temp;
    for * bai, i: l.bais {
        off, mask := bab_allocate(*bab, bai.bits, bai.bit_size);
        offsets[i] = off;
        ipo_rauw(bai.mask_global, ce_cast(.INTTOPTR, const_int(ir.t_i8, mask), type_ptr(0)));
        gv_erase_from_parent(bai.mask_global);
        if bai.mask_tid >= 0 l.export_summary.type_ids[bai.mask_tid].tt.bit_mask = mask;
    }
    // ConstantDataArray::get(Ctx, Bytes): a ConstantAggregateZero when every byte is zero
    aty := type_array(cast(u64) bab.bytes.count, ir.t_i8);
    elts := NewArray(bab.bytes.count, u64,, allocator = temp);
    all_zero := true;
    for bab.bytes { elts[it_index] = it; if it != 0 all_zero = false; }
    init := ifx all_zero then const_zero(aty) else const_data(aty, elts);
    byte_array := gv_create(aty, true, .PRIVATE, init, "", NONE, 0, dl.globals_as);
    for * bai, i: l.bais {
        gep := ce_gep(ir.t_i8, byte_array, .[const_int(l.int_ptr_ty, offsets[i])], F_INBOUNDS);
        alias := ltt_alias_create(ir.t_i8, .PRIVATE, "bits", gep);
        ipo_rauw(bai.byte_array, alias);
        gv_erase_from_parent(bai.byte_array);
    }
}

// ---------------------------------------------------------------- bit sets for a disjoint set

// buildBitSets
ltt_build_bit_sets :: (l: *Ltt, type_ids: [] Md_Id, layout_gtm: [] s32, layout_off: [] u64) -> [..] Ltt_Bsi {
    offsets: [..] [..] u64; offsets.allocator = temp;
    for type_ids { e: [..] u64; e.allocator = temp; array_add(*offsets, e); }
    for g, gi: layout_gtm {
        for t: l.gtms[g].types {
            tid := md_op(t, 1);
            for type_ids if it == tid { array_add(*offsets[it_index], layout_off[gi] + ltt_type_offset(t)); break; }
        }
    }
    out: [..] Ltt_Bsi; out.allocator = temp;
    for type_ids array_add(*out, ltt_build_bit_set(offsets[it_index]));
    return out;
}

// lowerTypeTestCalls
ltt_lower_type_test_calls :: (l: *Ltt, type_ids: [] Md_Id, combined: Value_Id, layout_gtm: [] s32, layout_off: [] u64) {
    bit_sets := ltt_build_bit_sets(l, type_ids, layout_gtm, layout_off);
    for type_id, ti: type_ids {
        bsi := *bit_sets[ti];
        bai := -1;
        til: Ltt_Til;
        global_offset := bsi.byte_offset + ((bsi.bit_size - 1) << bsi.align_log2);
        til.offseted_global = ce_gep(ir.t_i8, combined, .[const_int(l.int_ptr_ty, global_offset)], 0);
        til.align_log2 = const_int(l.int_ptr_ty, bsi.align_log2);
        til.size_m1 = const_int(l.int_ptr_ty, bsi.bit_size - 1);
        if bsi_is_all_ones(bsi) {
            til.kind = ifx bsi.bit_size == 1 then Tt_Kind.Single else .AllOnes;
        } else if bsi.bit_size <= cast(u64) type_int_width(l.int_ptr_ty) {
            til.kind = .Inline;
            inline_bits: u64 = 0;
            for bsi.bits inline_bits |= (cast(u64) 1) << it;
            if inline_bits == 0 til.kind = .Unsat;
            else til.inline_bits = const_int(ifx bsi.bit_size <= 32 then ir.t_i32 else ir.t_i64, inline_bits);
        } else {
            til.kind = .ByteArray;
            bai = ltt_create_byte_array(l, bsi);
            til.byte_array = l.bais[bai].byte_array;
            til.bit_mask = l.bais[bai].mask_global;
        }
        tiui := ltt_users_of(l, type_id);
        if tiui.exported {
            if ir.mds[type_id].kind != .STRING fatal("lowertypetests: exporting a type identifier that is not a string");
            mask_tid := ltt_export_type_id(l, ir.mds[type_id].str, *til);
            if bai >= 0 l.bais[bai].mask_tid = mask_tid;
        }
        calls := array_copy(tiui.call_sites,, allocator = temp);
        for ci: calls {
            lowered := ltt_lower_type_test_call(l, type_id, ci, *til);
            if lowered != NONE {
                ipo_rauw(ci, lowered);
                erase_inst(ci);
            }
        }
    }
}

// verifyTypeMDNode
ltt_verify_type_md_node :: (go: Value_Id, t: Md_Id) {
    if ir.mds[t].kind != .TUPLE || ir.mds[t].nops != 2 fatal("All operands of type metadata must have 2 elements");
    if gv_is_thread_local(go) fatal("Bit set element may not be thread-local");
    if vkind(go) == .GLOBAL_VAR && glob(go).section.count fatal("A member of a type identifier may not have an explicit section");
    m := md_op(t, 0);
    if m == NONE || ir.mds[m].kind != .VALUE || !is_constant_kind(vkind(ir.mds[m].value))
        fatal("Type offset must be a constant");
    if vkind(ir.mds[m].value) != .C_INT fatal("Type offset must be an integer constant");
}

// buildBitSetsFromGlobalVariables
ltt_build_bit_sets_from_global_variables :: (l: *Ltt, type_ids: [] Md_Id, globals: [] s32) {
    inits: [..] Value_Id; inits.allocator = temp;
    layout_off: [..] u64; layout_off.allocator = temp;
    max_align: u64 = 1;
    cur_offset: u64 = 0;
    desired_padding: u64 = 0;
    align_to :: (v: u64, a: u64) -> u64 { return (v + a - 1) / a * a; }
    next_power_of_2 :: (a_in: u64) -> u64 {
        a := a_in;
        a |= a >> 1; a |= a >> 2; a |= a >> 4; a |= a >> 8; a |= a >> 16; a |= a >> 32;
        return a + 1;
    }
    for g: globals {
        gv := l.gtms[g].go;
        vt := glob(gv).value_type;
        alignment := glob(gv).align;
        if alignment == 0 alignment = dl_alignment(vt, true);
        if alignment > max_align max_align = alignment;
        gv_offset := align_to(cur_offset + desired_padding, alignment);
        array_add(*layout_off, gv_offset);
        if gv_offset != 0 {
            padding := gv_offset - cur_offset;
            array_add(*inits, const_zero(type_array(padding, ir.t_i8)));
        }
        if !glob(gv).has_init fatal("lowertypetests: a member global variable has no initializer");
        array_add(*inits, gv_initializer(gv));
        init_size := dl_type_alloc_size(vt);
        cur_offset = gv_offset + init_size;
        desired_padding = next_power_of_2(init_size - 1) - init_size;
        if desired_padding > 32 desired_padding = align_to(init_size, 32) - init_size;
    }
    // ConstantStruct::getAnon(Ctx, GlobalInits)
    etys: [..] Type_Id; etys.allocator = temp;
    for inits array_add(*etys, vtype(it));
    sty := type_literal_struct(etys, false);
    new_init := const_aggregate(.C_STRUCT, sty, inits);
    combined := gv_create(sty, true, .PRIVATE, new_init, "", NONE, 0, dl.globals_as);
    glob(combined).align = max_align;

    ltt_lower_type_test_calls(l, type_ids, combined, globals, layout_off);

    for g, i: globals {
        gv := l.gtms[g].go;
        idxs: [2] Value_Id;
        idxs[0] = const_int(ir.t_i32, 0);
        idxs[1] = const_int(ir.t_i32, cast(u64) i * 2);
        elem_ptr := ce_gep(sty, combined, idxs, F_INBOUNDS);
        alias := ltt_alias_create(etys[i * 2], glob(gv).linkage, "", elem_ptr);
        gv_set_visibility(alias, glob(gv).visibility);
        gv_take_name(alias, gv);
        ipo_rauw(gv, alias);
        gv_erase_from_parent(gv);
    }
}

ltt_should_export_constants_as_absolute_symbols :: (l: *Ltt) -> bool {
    return ltt_is_x86(l) && l.obj == .ELF;
}

// exportTypeId: the TypeIdSummary index whose bit mask is to be filled in (MaskPtr), -1 if none
ltt_export_type_id :: (l: *Ltt, type_id: string, til: *Ltt_Til) -> s64 {
    si := l.export_summary;
    tk := si_get_or_insert_type_id_summary(si, type_id);
    si.type_ids[tk].tt.kind = til.kind;
    export_global :: (type_id: string, name: string, c: Value_Id) {
        ga := ltt_alias_create(ir.t_i8, .EXTERNAL, tconcat("__typeid_", type_id, "_", name), c);
        gv_set_visibility(ga, 1);
    }
    absolute := ltt_should_export_constants_as_absolute_symbols(l);
    if til.kind != .Unsat export_global(type_id, "global_addr", til.offseted_global);
    if til.kind == .ByteArray || til.kind == .Inline || til.kind == .AllOnes {
        if absolute export_global(type_id, "align", ce_cast(.INTTOPTR, til.align_log2, type_ptr(0)));
        else si.type_ids[tk].tt.align_log2 = const_int_zext(til.align_log2);
        if absolute export_global(type_id, "size_m1", ce_cast(.INTTOPTR, til.size_m1, type_ptr(0)));
        else si.type_ids[tk].tt.size_m1 = const_int_zext(til.size_m1);
        bit_size := const_int_zext(til.size_m1) + 1;
        if til.kind == .Inline si.type_ids[tk].tt.size_m1_bit_width = ifx bit_size <= 32 then cast(u32) 5 else 6;
        else si.type_ids[tk].tt.size_m1_bit_width = ifx bit_size <= 128 then cast(u32) 7 else 32;
    }
    if til.kind == .ByteArray {
        export_global(type_id, "byte_array", til.byte_array);
        if absolute export_global(type_id, "bit_mask", til.bit_mask);
        else return tk;
    }
    if til.kind == .Inline {
        if absolute export_global(type_id, "inline_bits", ce_cast(.INTTOPTR, til.inline_bits, type_ptr(0)));
        else si.type_ids[tk].tt.inline_bits = const_int_zext(til.inline_bits);
    }
    return -1;
}

// importTypeId
ltt_import_type_id :: (l: *Ltt, type_id: string) -> Ltt_Til {
    til: Ltt_Til;
    si := l.import_summary;
    tk := si_type_id_summary(si, type_id);
    if tk < 0 return til;   // Unsat: no globals match this type id
    tt := si.type_ids[tk].tt;
    til.kind = tt.kind;
    import_global :: (type_id: string, name: string) -> Value_Id {
        gv := module_get_or_insert_global(tconcat("__typeid_", type_id, "_", name), type_array(0, ir.t_i8));
        gv_set_visibility(gv, 1);
        return gv;
    }
    import_constant :: (l: *Ltt, type_id: string, name: string, cnst: u64, abs_width: u32, ty: Type_Id) -> Value_Id {
        if !ltt_should_export_constants_as_absolute_symbols(l) {
            c := const_int(ifx is_int_type(ty) then ty else ir.t_i64, cnst);
            if !is_int_type(ty) c = ce_cast(.INTTOPTR, c, ty);
            return c;
        }
        c := import_global(type_id, name);
        gv := strip_pointer_casts(c);
        if vkind(gv) != .GLOBAL_VAR fatal("lowertypetests: '__typeid_%_%' is not a global variable", type_id, name);
        if is_int_type(ty) c = ce_cast(.PTRTOINT, c, ty);
        if get_metadata(gv, md_fixed("absolute_symbol")) != NONE return c;
        set_abs_range :: (l: *Ltt, gv: Value_Id, mn: u64, mx: u64) {
            ops: [2] Md_Id;
            ops[0] = md_value(const_int(l.int_ptr_ty, mn));
            ops[1] = md_value(const_int(l.int_ptr_ty, mx));
            set_metadata(gv, md_fixed("absolute_symbol"), md_tuple(ops, false));
        }
        w := type_int_width(l.int_ptr_ty);
        if abs_width == w {
            all_ones: u64 = ifx w >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << w) - 1;
            set_abs_range(l, gv, all_ones, all_ones);
        } else {
            set_abs_range(l, gv, 0, (cast(u64) 1) << abs_width);
        }
        return c;
    }
    if til.kind != .Unsat {
        gv := import_global(type_id, "global_addr");
        glob(gv).code_model = 2;   // CodeModel::Small
        til.offseted_global = gv;
    }
    if til.kind == .ByteArray || til.kind == .Inline || til.kind == .AllOnes {
        til.align_log2 = import_constant(l, type_id, "align", tt.align_log2, 8, l.int_ptr_ty);
        til.size_m1 = import_constant(l, type_id, "size_m1", tt.size_m1, tt.size_m1_bit_width, l.int_ptr_ty);
    }
    if til.kind == .ByteArray {
        til.byte_array = import_global(type_id, "byte_array");
        til.bit_mask = import_constant(l, type_id, "bit_mask", tt.bit_mask, 8, type_ptr(0));
    }
    if til.kind == .Inline
        til.inline_bits = import_constant(l, type_id, "inline_bits", tt.inline_bits, (cast(u32) 1) << tt.size_m1_bit_width,
                                          ifx tt.size_m1_bit_width <= 5 then ir.t_i32 else ir.t_i64);
    return til;
}

// importTypeTest
ltt_import_type_test :: (l: *Ltt, ci: Value_Id) {
    a := op(ci, 1);
    if vkind(a) != .MD_VALUE fatal("Second argument of llvm.type.test must be metadata");
    tid := ir.v_aux[a];
    // a local unpromoted type (no MDString): Unknown, lowering is delayed
    if ir.mds[tid].kind != .STRING return;
    til := ltt_import_type_id(l, ir.mds[tid].str);
    lowered := ltt_lower_type_test_call(l, tid, ci, *til);
    if lowered != NONE {
        ipo_rauw(ci, lowered);
        erase_inst(ci);
    }
}

// maybeReplaceComdat
ltt_maybe_replace_comdat :: (l: *Ltt, f: Value_Id, original_name: string) {
    c := glob(f).comdat;
    if c < 0 || l.obj != .COFF || ir.comdats[c].name != original_name return;
    nc := get_comdat(vname(f));
    for ir.m_functions if glob(it).comdat == c glob(it).comdat = nc;
    for ir.m_globals if glob(it).comdat == c glob(it).comdat = nc;
}

// importFunction (ThinLTO backend: F has a jump table entry)
ltt_import_function :: (l: *Ltt, f: Value_Id, is_jt_canonical: bool) {
    visibility := glob(f).visibility;
    name := copy_string(vname(f),, allocator = temp);
    ft := glob(f).value_type;
    as := glob(f).addrspace;
    if gv_is_declaration_for_linker(f) && is_jt_canonical {
        // non-dso_local functions may be overridden at run time: don't short circuit them
        if glob(f).dso_local {
            real_f := ltt_fn_create(ft, .EXTERNAL, as, tconcat(name, ".cfi"));
            gv_set_visibility(real_f, 1);
            ltt_replace_direct_calls(f, real_f);
        }
        return;
    }
    fdecl: Value_Id;
    if !is_jt_canonical {
        fdecl = ltt_fn_create(ft, .EXTERNAL, as, tconcat(name, ".cfi_jt"));
        gv_set_visibility(fdecl, 1);
    } else {
        set_name(f, tconcat(name, ".cfi"));
        ltt_maybe_replace_comdat(l, f, name);
        fdecl = ltt_fn_create(ft, .EXTERNAL, as, name);
        gv_set_visibility(fdecl, visibility);
        visibility = 1;
        // aliases of F get the ".cfi" suffix; their users go to a declaration with the alias's name
        aliases: [..] Value_Id; aliases.allocator = temp;
        u := ir.v_first_use[f];
        while u != NONE { usr := ir.u_user[u]; if vkind(usr) == .ALIAS array_add(*aliases, usr); u = ir.u_next[u]; }
        for a: aliases {
            alias_name := tconcat(vname(a), ".cfi");
            decl := ltt_fn_create(ft, .EXTERNAL, as, "");
            gv_take_name(decl, a);
            ipo_rauw(a, decl);
            set_name(a, alias_name);
        }
    }
    if glob(f).linkage == .EXTERN_WEAK ltt_replace_weak_declaration_with_jump_table_ptr(l, f, fdecl, is_jt_canonical);
    else ltt_replace_cfi_uses(l, f, fdecl, is_jt_canonical);
    gv_set_visibility(f, visibility);
}

// ---------------------------------------------------------------- functions: jump tables

X86_JT_ENTRY_SIZE :: 8;
X86_IBT_JT_ENTRY_SIZE :: 16;

ltt_cf_protection_branch :: () -> bool {
    ok, v := mu_module_flag_int("cf-protection-branch");
    return ok && v != 0;
}

// getJumpTableEntrySize
ltt_jump_table_entry_size :: (l: *Ltt) -> u64 {
    if !ltt_is_x86(l) fatal("lowertypetests: jump tables for this target are not supported");
    if ltt_cf_protection_branch() return X86_IBT_JT_ENTRY_SIZE;
    return X86_JT_ENTRY_SIZE;
}

// createJumpTableEntryAsm
ltt_create_jump_table_entry_asm :: (l: *Ltt) -> Value_Id {
    if !ltt_is_x86(l) fatal("lowertypetests: jump tables for this target are not supported");
    endbr := ltt_cf_protection_branch();
    s := "";
    if endbr s = ifx l.arch == .x86 then "endbr32\n" else "endbr64\n";
    s = tconcat(s, "jmp ${0:c}@plt\n");
    if endbr s = tconcat(s, ".balign 16, 0xcc\n");
    else s = tconcat(s, "int3\nint3\nint3\n");
    return inline_asm_get(type_func(ir.t_void, .[type_ptr(0)], false), s, "s", 1);
}

// moveInitializerToModuleConstructor
ltt_move_initializer_to_module_constructor :: (l: *Ltt, gv: Value_Id) {
    if l.weak_init_fn == NONE {
        f := ltt_fn_create(type_func(ir.t_void, .[], false), .INTERNAL, dl.program_as, "__cfi_global_var_init");
        bb := create_block(f, "entry");
        block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
        glob(f).section = ifx l.obj == .MachO then "__TEXT,__StaticInit,regular,pure_instructions" else ".text.startup";
        append_to_global_ctors(f, 0);
        l.weak_init_fn = f;
    }
    b: Irb;
    irb_set_before(*b, block_terminator(fn_entry(l.weak_init_fn)));
    glob(gv).is_const = false;
    vt := glob(gv).value_type;
    align := glob(gv).align;
    if align == 0 align = dl_alignment(vt, true);
    irb_store(*b, gv_initializer(gv), gv, align);
    gv_set_initializer(gv, const_null_value(vt));
}

// findGlobalVariableUsersOf (SmallSetVector)
ltt_find_global_variable_users_of :: (c: Value_Id, out: *[..] Value_Id) {
    u := ir.v_first_use[c];
    while u != NONE {
        usr := ir.u_user[u];
        if vkind(usr) == .GLOBAL_VAR { if !array_find(out.*, usr) array_add(out, usr); }
        else if is_constant_kind(vkind(usr)) ltt_find_global_variable_users_of(usr, out);
        u = ir.u_next[u];
    }
}

// replaceWeakDeclarationWithJumpTablePtr: every use of F becomes (F ? JT : 0)
ltt_replace_weak_declaration_with_jump_table_ptr :: (l: *Ltt, f: Value_Id, jt: Value_Id, is_jt_canonical: bool) {
    gv_users: [..] Value_Id; gv_users.allocator = temp;
    ltt_find_global_variable_users_of(f, *gv_users);
    for gv: gv_users {
        if gv == l.global_annotation continue;
        ltt_move_initializer_to_module_constructor(l, gv);
    }
    placeholder := ltt_fn_create(glob(f).value_type, .EXTERN_WEAK, glob(f).addrspace, "");
    ltt_replace_cfi_uses(l, f, placeholder, is_jt_canonical);
    convert_users_of_constants_to_instructions(.[placeholder]);
    fty := vtype(f);
    while ir.v_first_use[placeholder] != NONE {
        u := ir.v_first_use[placeholder];
        insert_pt := ir.u_user[u];
        if vkind(insert_pt) != .INST fatal("lowertypetests: non-instruction users should have been eliminated");
        pn: Value_Id = NONE;
        if inst_op(insert_pt) == .PHI {
            pn = insert_pt;
            insert_pt = block_terminator(phi_block(pn, opno_of(u)));
        }
        b: Irb;
        irb_set_before(*b, insert_pt);
        icmp := irb_icmp(*b, ICMP_NE, f, const_null_value(fty));
        sel := irb_select(*b, icmp, jt, const_null_value(fty));
        if is_inst(sel) && inst_op(sel) == .SELECT set_explicitly_unknown_branch_weights_if_profiled(sel, "lowertypetests");
        if pn != NONE {
            // PN->setIncomingValueForBlock(InsertPt->getParent(), Select): every entry for that block
            blk := inst_block(insert_pt);
            for k: 0..phi_num_incoming(pn)-1 if phi_block(pn, k) == blk phi_set_value(pn, k, sel);
        } else {
            use_set(u, sel);
        }
    }
    gv_erase_from_parent(placeholder);
}

// createJumpTableDebugInfo
ltt_create_jump_table_debug_info :: (l: *Ltt, f: Value_Id, functions: [] s32) -> [..] Md_Id {
    cu: Md_Id = NONE;
    k := named_md_find("llvm.dbg.cu");
    if k >= 0 && ir.named_md[k].ops.count cu = ir.named_md[k].ops[0];
    file := di_get(.FILE, false, .[md_str_or_null("ubsan_interface.h"), md_str_or_null("sanitizer"), NONE, NONE], .[0]);
    if cu == NONE {
        // createCompileUnit(DW_LANG_C, File, "llvm", isOptimized = true, "", 0, "", LineTablesOnly)
        DW_LANG_C :: 2;
        cu = di_get(.COMPILE_UNIT, true,
            .[file, md_str_or_null("llvm"), NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
            .[DW_LANG_C, 0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0]);
        cuk := named_md_get_or_insert("llvm.dbg.cu");
        array_add(*ir.named_md[cuk].ops, cu);
    }
    fn_ty := di_get(.SUBROUTINE_TYPE, false, .[NONE, NONE, NONE, NONE, NONE, NONE], .[0, 0]);
    FLAG_ARTIFICIAL :: 64;
    create_function :: (cu: Md_Id, name: string, file: Md_Id, fn_ty: Md_Id) -> Md_Id {
        return di_get(.SUBPROGRAM, true,
            .[file, NONE, md_str_or_null(name), NONE, fn_ty, cu, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
            .[0, 0, 0, 0, FLAG_ARTIFICIAL, SPFLAG_DEFINITION, 0]);
    }
    ubsan_sp := create_function(cu, "__ubsan_check_cfi_icall_jt", file, fn_ty);
    set_metadata(f, 0, ubsan_sp);
    ubsan_loc := di_location_get(0, 0, ubsan_sp, NONE);
    locs: [..] Md_Id; locs.allocator = temp;
    for g: functions {
        name := vname(l.gtms[g].go);
        if ends_with(name, ".cfi") name = slice(name, 0, name.count - 4);
        jump_sp := create_function(cu, tconcat(name, ".cfi_jt"), file, fn_ty);
        array_add(*locs, di_location_get(0, 0, jump_sp, ubsan_loc));
    }
    return locs;
}

// createJumpTable
ltt_create_jump_table :: (l: *Ltt, f: Value_Id, functions: [] s32) {
    entry_size := ltt_jump_table_entry_size(l);
    if !l.cross_dso {
        SHT_LLVM_CFI_JUMP_TABLE :: 0x6fff4c0e;
        ops: [2] Md_Id;
        ops[0] = md_value(const_int(ir.t_i64, SHT_LLVM_CFI_JUMP_TABLE));
        ops[1] = md_value(const_int(ir.t_i64, entry_size));
        set_metadata(f, md_fixed("elf_section_properties"), md_tuple(ops, false));
    }
    bb := create_block(f, "entry");
    b: Irb;
    irb_set_end(*b, bb);
    locs: [..] Md_Id; locs.allocator = temp;
    ok, dwarf := mu_module_flag_int("Dwarf Version");
    if ok && dwarf != 0 && ltt_cl.jump_table_debug_info locs = ltt_create_jump_table_debug_info(l, f, functions);
    asm := ltt_create_jump_table_entry_asm(l);
    all_nounwind := true;
    for g, i: functions {
        if i < locs.count b.dbg = locs[i];
        target := l.gtms[g].go;
        if !fn_has_fn_attr(target, .NoUnwind) all_nounwind = false;
        // IRB.CreateCall(JumpTableAsm, F)
        ci := new_inst(.CALL, ir.t_void, 2);
        inst(ci).ty2 = inline_asms[ir.v_aux[asm]].fty;
        set_op(ci, 0, target);
        set_op(ci, 1, asm);
        irb_insert(*b, ci);
    }
    irb_insert(*b, new_inst(.UNREACHABLE, ir.t_void, 0));
    glob(f).pref_align = entry_size;
    fn_add_fn_attr_kind(f, .Naked);
    if ltt_is_x86(l) fn_add_fn_attr_kind(f, .NoCfCheck);
    if all_nounwind fn_add_fn_attr_kind(f, .NoUnwind);
    fn_add_fn_attr_kind(f, .NoInline);
}

// buildBitSetsFromFunctionsNative
ltt_build_bit_sets_from_functions_native :: (l: *Ltt, type_ids: [] Md_Id, functions: [] s32) {
    assert(functions.count > 0);
    entry_size := ltt_jump_table_entry_size(l);
    layout_off: [..] u64; layout_off.allocator = temp;
    for functions array_add(*layout_off, cast(u64) it_index * entry_size);
    jt_fn := ltt_fn_create(type_func(ir.t_void, .[], false), .PRIVATE, dl.program_as, ".cfi.jumptable");
    entry_ty := type_array(entry_size, ir.t_i8);
    jt_ty := type_array(cast(u64) functions.count, entry_ty);
    jump_table := jt_fn;   // ConstantExpr::getPointerCast(JumpTableFn, ptr): the same type

    ltt_lower_type_test_calls(l, type_ids, jump_table, functions, layout_off);

    for g, i: functions {
        f := l.gtms[g].go;
        is_canonical := l.gtms[g].jt_canonical;
        idxs: [2] Value_Id;
        idxs[0] = const_int(l.int_ptr_ty, 0);
        idxs[1] = const_int(l.int_ptr_ty, cast(u64) i);
        elem_ptr := ce_gep(jt_ty, jump_table, idxs, F_INBOUNDS);
        is_exported := l.gtms[g].exported;
        if !is_canonical {
            lt: Linkage = ifx is_exported then Linkage.EXTERNAL else .INTERNAL;
            jt_alias := ltt_alias_create(entry_ty, lt, tconcat(vname(f), ".cfi_jt"), elem_ptr);
            if is_exported gv_set_visibility(jt_alias, 1);
            else append_to_used(jt_alias);
        }
        if is_exported {
            // ExportSummary->cfiFunctionDefs() / cfiFunctionDecls().addSymbolWithThinLTOGUID(F->getName(), GUID)
            nm := copy_string(vname(f));
            if is_canonical { if !si_cfi_contains(l.export_summary.cfi_defs, nm) array_add(*l.export_summary.cfi_defs, nm); }
            else { if !si_cfi_contains(l.export_summary.cfi_decls, nm) array_add(*l.export_summary.cfi_decls, nm); }
        }
        if !is_canonical {
            if glob(f).linkage == .EXTERN_WEAK ltt_replace_weak_declaration_with_jump_table_ptr(l, f, elem_ptr, is_canonical);
            else ltt_replace_cfi_uses(l, f, elem_ptr, is_canonical);
        } else {
            falias := ltt_alias_create(entry_ty, glob(f).linkage, "", elem_ptr);
            gv_set_visibility(falias, glob(f).visibility);
            gv_take_name(falias, f);
            if vname(falias).count {
                set_name(f, tconcat(vname(falias), ".cfi"));
                ltt_maybe_replace_comdat(l, f, vname(falias));
            }
            ltt_replace_cfi_uses(l, f, falias, is_canonical);
            if !gv_has_local_linkage(f) gv_set_visibility(f, 1);
        }
    }
    ltt_create_jump_table(l, jt_fn, functions);
}

// buildBitSetsFromFunctions
ltt_build_bit_sets_from_functions :: (l: *Ltt, type_ids: [] Md_Id, functions: [] s32) {
    if ltt_is_x86(l) { ltt_build_bit_sets_from_functions_native(l, type_ids, functions); return; }
    if l.arch == .wasm32 || l.arch == .wasm64 fatal("lowertypetests: WebAssembly indirect function indices are not supported");
    fatal("Unsupported architecture for jump tables");
}

// buildBitSetsFromDisjointSet
ltt_build_bit_sets_from_disjoint_set :: (l: *Ltt, type_ids: [] Md_Id, globals: [] s32, funnels: [] s32) {
    // TypeMembers: one std::set of global indices per type id, then one per branch funnel
    members: [..] [..] u64; members.allocator = temp;
    for type_ids { e: [..] u64; e.allocator = temp; array_add(*members, e); }
    for g, gi: globals {
        for t: l.gtms[g].types {
            tid := md_op(t, 1);
            for type_ids if it == tid { u64_set_insert(*members[it_index], cast(u64) gi); break; }
        }
    }
    for fi: funnels {
        e: [..] u64; e.allocator = temp;
        for t: l.funnels[fi].targets {
            gi := -1;
            for globals if it == t { gi = it_index; break; }
            if gi < 0 { gi = 0; }   // GlobalIndices[T] (operator[]): a default 0 for a target outside the set
            u64_set_insert(*e, cast(u64) gi);
        }
        array_add(*members, e);
    }
    // stable_sort by set size
    for i: 1..members.count-1 {
        x := members[i];
        j := i - 1;
        while j >= 0 && members[j].count > x.count { members[j + 1] = members[j]; j -= 1; }
        members[j + 1] = x;
    }
    glb: Ltt_Glb;
    glb_init(*glb, globals.count);
    for members glb_add_fragment(*glb, it);
    is_global_set := globals.count == 0 || vkind(l.gtms[globals[0]].go) == .GLOBAL_VAR;
    ordered: [..] s32; ordered.allocator = temp;
    for f: glb.fragments for off: f {
        if is_global_set != (vkind(l.gtms[globals[off]].go) == .GLOBAL_VAR)
            fatal("Type identifier may not contain both global variables and functions");
        array_add(*ordered, globals[off]);
    }
    if ordered.count != globals.count fatal("lowertypetests: internal: global layout lost a member");
    if is_global_set ltt_build_bit_sets_from_global_variables(l, type_ids, ordered);
    else ltt_build_bit_sets_from_functions(l, type_ids, ordered);
}

// ---------------------------------------------------------------- replacing uses

ltt_is_direct_call :: (u: Use_Id) -> bool {
    usr := ir.u_user[u];
    return is_inst(usr) && inst_op(usr) == .CALL && opno_of(u) == nops(usr) - 1;
}

// replaceCfiUses: RAUW except no_cfi values, direct calls (to dso_local or non-canonical functions) and function
// annotations
ltt_replace_cfi_uses :: (l: *Ltt, old: Value_Id, new: Value_Id, is_jt_canonical: bool) {
    constants: [..] Value_Id; constants.allocator = temp;
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[old];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for u: uses {
        usr := ir.u_user[u];
        if vkind(usr) == .C_NO_CFI continue;
        if vkind(usr) == .C_BLOCKADDR continue;   // a blockaddress has no operands in LLVM 23: not a use of its function
        if ltt_is_direct_call(u) && (glob(old).dso_local || !is_jt_canonical) continue;
        if array_find(l.fn_annotations, usr) continue;
        if is_constant_kind(vkind(usr)) && !is_global_value(vkind(usr)) {
            if !array_find(constants, usr) array_add(*constants, usr);
            continue;
        }
        use_set(u, new);
    }
    for c: constants {
        if vkind(c) == .DEAD continue;
        constant_handle_operand_change(c, old, new);
    }
}

// replaceDirectCalls: Old->replaceUsesWithIf(New, isDirectCall)
ltt_replace_direct_calls :: (old: Value_Id, new: Value_Id) {
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[old];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for uses if ltt_is_direct_call(it) use_set(it, new);
}

// ScopedSaveAliaseesAndUsed
Ltt_Saved :: struct {
    used: [..] Value_Id;
    compiler_used: [..] Value_Id;
    fn_aliases: [..] [2] Value_Id;
    resolver_ifuncs: [..] [2] Value_Id;
}
ltt_save_aliasees_and_used :: () -> Ltt_Saved {
    s: Ltt_Saved;
    s.used.allocator = temp; s.compiler_used.allocator = temp; s.fn_aliases.allocator = temp; s.resolver_ifuncs.allocator = temp;
    collect_and_erase_used_functions :: (vec: *[..] Value_Id, compiler_used: bool) {
        gv := collect_used_global_variables(vec, compiler_used);
        if gv == NONE return;
        gv_erase_from_parent(gv);
        // std::stable_partition: functions first
        fns: [..] Value_Id; fns.allocator = temp;
        others: [..] Value_Id; others.allocator = temp;
        for vec.* { if vkind(it) == .FUNCTION array_add(*fns, it); else array_add(*others, it); }
        mu_append_to_used_list(ifx compiler_used then "llvm.compiler.used" else "llvm.used", others);
        vec.count = 0;
        for fns array_add(vec, it);
    }
    collect_and_erase_used_functions(*s.used, false);
    collect_and_erase_used_functions(*s.compiler_used, true);
    for ga: ir.m_aliases {
        f := strip_pointer_casts(op(ga, 0));
        if vkind(f) == .FUNCTION array_add(*s.fn_aliases, .[ga, f]);
    }
    for gi: ir.m_ifuncs {
        f := strip_pointer_casts(op(gi, 0));
        if vkind(f) == .FUNCTION array_add(*s.resolver_ifuncs, .[gi, f]);
    }
    return s;
}
ltt_restore_aliasees_and_used :: (s: *Ltt_Saved) {
    mu_append_to_used_list("llvm.used", s.used);
    mu_append_to_used_list("llvm.compiler.used", s.compiler_used);
    for s.fn_aliases set_op(it[0], 0, it[1]);
    for s.resolver_ifuncs set_op(it[0], 0, it[1]);
}

// ---------------------------------------------------------------- lower()

CFL_Definition :: 0;
CFL_Declaration :: 1;
CFL_WeakDeclaration :: 2;

// lowertypetests::isJumpTableCanonical
ltt_is_jump_table_canonical :: (f: Value_Id) -> bool {
    if gv_is_declaration_for_linker(f) return false;
    m := module_flag("CFI Canonical Jump Tables");
    if m == NONE || ir.mds[m].kind != .VALUE || vkind(ir.mds[m].value) != .C_INT || const_int_zext(ir.mds[m].value) != 0 return true;
    return fn_has_str_attr(f, "cfi-canonical-jump-table");
}

ltt_lower :: (l: *Ltt) -> bool {
    tt_fn := lookup_global("llvm.type.test");
    if tt_fn != NONE && vkind(tt_fn) != .FUNCTION tt_fn = NONE;
    if (l.export_summary && l.export_summary.partially_split) || (l.import_summary && l.import_summary.partially_split) return false;
    bf_fn := lookup_global("llvm.icall.branch.funnel");
    if bf_fn != NONE && vkind(bf_fn) != .FUNCTION bf_fn = NONE;
    if (tt_fn == NONE || !has_uses(tt_fn)) && (bf_fn == NONE || !has_uses(bf_fn)) && !l.export_summary && !l.import_summary
        return false;

    if l.import_summary {
        if tt_fn != NONE {
            calls: [..] Value_Id; calls.allocator = temp;
            u := ir.v_first_use[tt_fn];
            while u != NONE { array_add(*calls, ir.u_user[u]); u = ir.u_next[u]; }
            for calls ltt_import_type_test(l, it);
        }
        if bf_fn != NONE && has_uses(bf_fn) fatal("unexpected call to llvm.icall.branch.funnel during import phase");
        defs: [..] Value_Id; defs.allocator = temp;
        decls: [..] Value_Id; decls.allocator = temp;
        for f: ir.m_functions {
            if gv_has_local_linkage(f) continue;
            if si_cfi_contains(l.import_summary.cfi_defs, vname(f)) array_add(*defs, f);
            else if si_cfi_contains(l.import_summary.cfi_decls, vname(f)) array_add(*decls, f);
        }
        s := ltt_save_aliasees_and_used();
        for defs ltt_import_function(l, it, true);
        for decls ltt_import_function(l, it, false);
        ltt_restore_aliasees_and_used(*s);
        return true;
    }

    ec: Ltt_Ec;
    ec.nodes.allocator = temp; ec.map.allocator = temp;
    tid_info: Table(Md_Id, s64); tid_info.allocator = temp;
    infos: [..] Ltt_Tid_Info; infos.allocator = temp;
    info_of :: (tid_info: *Table(Md_Id, s64), infos: *[..] Ltt_Tid_Info, tid: Md_Id) -> *Ltt_Tid_Info {
        found, k := table_find(tid_info, tid);
        if !found {
            e: Ltt_Tid_Info; e.ref_globals.allocator = temp;
            array_add(infos, e);
            k = infos.count - 1;
            table_add(tid_info, tid, k);
        }
        return *infos.*[k];
    }
    cur_unique_id: u32 = 0;

    // ExportedFunctions: MapVector<StringRef, {Linkage, FuncMD}>
    Exported_Fn :: struct { name: string; linkage: u64; md: Md_Id; erased: bool; }
    exported: [..] Exported_Fn; exported.allocator = temp;
    exported_find :: (exported: [] Exported_Fn, name: string) -> s64 {
        for exported if !it.erased && it.name == name return it_index;
        return -1;
    }
    si := l.export_summary;
    if si {
        cfk := named_md_find("cfi.functions");
        if cfk >= 0 {
            // functions address taken by a live global object
            address_taken: Table(u64, bool); address_taken.allocator = temp;
            for * gi: si.gvs for * gvs: gi.sums {
                if !gvs.live continue;
                for r: gvs.refs {
                    table_set(*address_taken, r, true);
                    rk := si_gv_index(si, r);
                    if rk >= 0 for * rs: si.gvs[rk].sums if rs.is_alias table_set(*address_taken, rs.aliasee_guid, true);
                }
            }
            is_address_taken :: (si: *Summary_Index, at: *Table(u64, bool), guid: u64) -> bool {
                if table_contains(at, guid) return true;
                k := si_gv_index(si, guid);
                if k < 0 return false;
                for * si.gvs[k].sums if it.is_alias && table_contains(at, it.aliasee_guid) return true;
                return false;
            }
            for func_md: ir.named_md[cfk].ops {
                if ir.mds[func_md].nops < 3 fatal("lowertypetests: malformed cfi.functions entry");
                fname := ir.mds[md_op(func_md, 0)].str;
                linkage := const_int_zext(ir.mds[md_op(func_md, 1)].value);
                guid := const_int_zext(ir.mds[md_op(func_md, 2)].value);
                if !si_guid_live(si, guid) continue;
                if !is_address_taken(si, *address_taken, guid) {
                    if !l.cross_dso || linkage != CFL_Definition continue;
                    is_exp := false;
                    k := si_gv_index(si, guid);
                    if k >= 0 for * si.gvs[k].sums if it.live && !(it.linkage == .INTERNAL || it.linkage == .PRIVATE) is_exp = true;
                    if !is_exp continue;
                }
                x := exported_find(exported, fname);
                if x < 0 array_add(*exported, .{fname, linkage, func_md, false});
                else if exported[x].linkage != CFL_Definition { exported[x].linkage = linkage; exported[x].md = func_md; }
            }
            for * p: exported {
                f := module_get_function(p.name);
                if f != NONE && gv_has_local_linkage(f) {
                    set_name(f, tconcat(vname(f), ".1"));
                    f = NONE;
                }
                if f == NONE {
                    f = ltt_fn_create(type_func(ir.t_void, .[], false), .EXTERNAL, dl.program_as, p.name);
                    set_metadata(f, MDK_UNIQUE_ID, md_tuple(.[md_op(p.md, 2)], false));
                }
                if glob(f).linkage == .AVAILABLE_EXTERNALLY {
                    orig_guid := get_metadata(f, MDK_UNIQUE_ID);
                    gv_set_linkage(f, .EXTERNAL);
                    fn_delete_body(f);
                    glob(f).comdat = -1;
                    ir.v_md[f] = NONE;
                    if orig_guid != NONE set_metadata(f, MDK_UNIQUE_ID, orig_guid);
                }
                if p.linkage == CFL_Definition && glob(f).linkage == .EXTERN_WEAK gv_set_linkage(f, .EXTERNAL);
                if is_declaration(f) {
                    if p.linkage == CFL_WeakDeclaration gv_set_linkage(f, .EXTERN_WEAK);
                    set_metadata(f, md_fixed("type"), NONE);
                    for i: 3..cast(s64) ir.mds[p.md].nops - 1 add_metadata(f, md_fixed("type"), md_op(p.md, cast(u32) i));
                }
            }
        }
    }

    Alias_To_Create :: struct { alias: Value_Id; target: string; }
    aliases_to_create: [..] Alias_To_Create; aliases_to_create.allocator = temp;
    if si {
        ak := named_md_find("aliases");
        if ak >= 0 {
            for alias_md: ir.named_md[ak].ops {
                als: [..] Value_Id; als.allocator = temp;
                for i: 0..cast(s64) ir.mds[alias_md].nops - 1 {
                    m := md_op(alias_md, cast(u32) i);
                    if m == NONE || ir.mds[m].kind != .STRING continue;
                    if exported_find(exported, ir.mds[m].str) < 0 continue;
                    af := module_get_function(ir.mds[m].str);
                    if af != NONE array_add(*als, af);
                }
                if als.count == 0 continue;
                for i: 1..als.count-1 {
                    x := exported_find(exported, vname(als[i]));
                    if x >= 0 exported[x].erased = true;
                    array_add(*aliases_to_create, .{als[i], copy_string(vname(als[0]),, allocator = temp)});
                }
            }
        }
    }

    // the GlobalTypeMembers: functions first, then global variables (Module::global_objects)
    gtm_of: Table(Value_Id, s32); gtm_of.allocator = temp;
    types: [..] Md_Id; types.allocator = temp;
    objects: [..] Value_Id; objects.allocator = temp;
    for ir.m_functions array_add(*objects, it);
    for ir.m_globals array_add(*objects, it);
    for go: objects {
        if vkind(go) == .GLOBAL_VAR && gv_is_declaration_for_linker(go) continue;
        ltt_type_mds(go, *types);
        is_canonical := false;
        is_exported := false;
        if vkind(go) == .FUNCTION {
            is_canonical = ltt_is_jump_table_canonical(go);
            x := exported_find(exported, vname(go));
            if x >= 0 {
                is_canonical |= exported[x].linkage == CFL_Definition;
                is_exported = true;
            } else if !fn_has_address_taken(go) {
                if !l.cross_dso || !is_canonical || gv_has_local_linkage(go) continue;
            }
        }
        g: Ltt_Gtm;
        g.go = go; g.jt_canonical = is_canonical; g.exported = is_exported;
        g.types.allocator = temp;
        for types array_add(*g.types, it);
        array_add(*l.gtms, g);
        gi := cast(s32) l.gtms.count - 1;
        table_set(*gtm_of, go, gi);
        for t: types {
            ltt_verify_type_md_node(go, t);
            info := info_of(*tid_info, *infos, md_op(t, 1));
            cur_unique_id += 1;
            info.unique_id = cur_unique_id;
            array_add(*info.ref_globals, gi);
        }
    }

    add_type_id_use :: (l: *Ltt, ec: *Ltt_Ec, tid_info: *Table(Md_Id, s64), infos: *[..] Ltt_Tid_Info, tid: Md_Id) -> *Ltt_Tid_User {
        found := table_contains(*l.tid_users, tid);
        r := ltt_users_of(l, tid);
        if !found {
            cur := ec_find_leader(ec, ec_insert(ec, .TYPE_ID, tid));
            info := info_of(tid_info, infos, tid);
            for g: info.ref_globals cur = ec_union(ec, cur, ec_find_leader(ec, ec_insert(ec, .GTM, cast(u32) g)));
        }
        return r;
    }

    if tt_fn != NONE {
        u := ir.v_first_use[tt_fn];
        while u != NONE {
            defer u = ir.u_next[u];
            ci := ir.u_user[u];
            // only used by llvm.assume: kept for whole program devirtualization
            only_assume := has_uses(ci);
            x := ir.v_first_use[ci];
            while x != NONE {
                usr := ir.u_user[x];
                if !(is_inst(usr) && inst_op(usr) == .CALL && call_called_function(usr) != NONE && vname(call_called_function(usr)) == "llvm.assume") {
                    only_assume = false;
                    break;
                }
                x = ir.u_next[x];
            }
            if only_assume continue;
            a := op(ci, 1);
            if vkind(a) != .MD_VALUE fatal("Second argument of llvm.type.test must be metadata");
            r := add_type_id_use(l, *ec, *tid_info, *infos, ir.v_aux[a]);
            array_add(*r.call_sites, ci);
        }
    }

    if bf_fn != NONE {
        u := ir.v_first_use[bf_fn];
        while u != NONE {
            defer u = ir.u_next[u];
            if l.arch != .x86_64 fatal("llvm.icall.branch.funnel not supported on this target");
            ci := ir.u_user[u];
            nargs := call_num_args(ci);
            if nargs % 2 != 1 fatal("number of arguments should be odd");
            fun: Ltt_Funnel;
            fun.ci = ci;
            fun.targets.allocator = temp;
            cur: s32 = -1;
            i: u32 = 1;
            while i != nargs {
                base, off := get_pointer_base_with_constant_offset(op(ci, i));
                if base == NONE || !(vkind(base) == .FUNCTION || vkind(base) == .GLOBAL_VAR)
                    fatal("Expected branch funnel operand to be global value");
                found, gi := table_find(*gtm_of, base);
                if !found fatal("lowertypetests: branch funnel target @% has no type member", vname(base));
                array_add(*fun.targets, gi);
                ns := ec_find_leader(*ec, ec_insert(*ec, .GTM, cast(u32) gi));
                if i == 1 cur = ns;
                else cur = ec_union(*ec, cur, ns);
                i += 2;
            }
            cur_unique_id += 1;
            fun.unique_id = cur_unique_id;
            array_add(*l.funnels, fun);
            ec_union(*ec, cur, ec_find_leader(*ec, ec_insert(*ec, .FUNNEL, cast(u32) l.funnels.count - 1)));
        }
    }

    if si {
        // MetadataByGUID over the MDString type ids
        for * gi: si.gvs {
            for * s: gi.sums {
                if !si_gv_live(si, s) continue;
                base := s;
                if s.is_alias {
                    k := si_gv_index(si, s.aliasee_guid);
                    if k < 0 || si.gvs[k].sums.count == 0 fatal("lowertypetests: alias summary without an aliasee summary");
                    base = *si.gvs[k].sums[0];
                    if base.is_alias continue;
                }
                for g: base.type_tests {
                    for * info, tid: tid_info {
                        if ir.mds[tid].kind != .STRING || guid_of_name(ir.mds[tid].str) != g continue;
                        r := add_type_id_use(l, *ec, *tid_info, *infos, tid);
                        r.exported = true;
                    }
                }
            }
        }
    }

    if ec.nodes.count == 0 return false;

    {
        saved := ltt_save_aliasees_and_used();
        for node, ni: ec.nodes {
            if node.leader != ni continue;
            type_ids: [..] Md_Id; type_ids.allocator = temp;
            globals: [..] s32; globals.allocator = temp;
            funnels: [..] s32; funnels.allocator = temp;
            x := cast(s32) ni;
            while x >= 0 {
                n := ec.nodes[x];
                if n.kind == .TYPE_ID array_add(*type_ids, n.id);
                else if n.kind == .GTM array_add(*globals, cast(s32) n.id);
                else array_add(*funnels, cast(s32) n.id);
                x = n.next;
            }
            // llvm::sort by UniqueId (TypeIdInfo[M]: 0 for a type id no global has); std::sort is an insertion sort
            // (stable) up to 16 elements
            uid :: (tid_info: *Table(Md_Id, s64), infos: [] Ltt_Tid_Info, t: Md_Id) -> u32 {
                found, k := table_find(tid_info, t);
                if !found return 0;
                return infos[k].unique_id;
            }
            for i: 1..type_ids.count-1 {
                t := type_ids[i];
                j := i - 1;
                while j >= 0 && uid(*tid_info, infos, type_ids[j]) > uid(*tid_info, infos, t) { type_ids[j + 1] = type_ids[j]; j -= 1; }
                type_ids[j + 1] = t;
            }
            if type_ids.count > 16 {
                for i: 1..type_ids.count-1 if uid(*tid_info, infos, type_ids[i]) == uid(*tid_info, infos, type_ids[i - 1])
                    fatal("lowertypetests: more than 16 type identifiers in a disjoint set with equal unique ids (std::sort order)");
            }
            for i: 1..funnels.count-1 {
                t := funnels[i];
                j := i - 1;
                while j >= 0 && l.funnels[funnels[j]].unique_id > l.funnels[t].unique_id { funnels[j + 1] = funnels[j]; j -= 1; }
                funnels[j + 1] = t;
            }
            ltt_build_bit_sets_from_disjoint_set(l, type_ids, globals, funnels);
        }
        ltt_restore_aliasees_and_used(*saved);
    }

    ltt_allocate_byte_arrays(l);

    for a: aliases_to_create {
        target := lookup_global(a.target);
        if target == NONE || vkind(target) != .ALIAS continue;
        // GlobalAlias::create("", Target): the aliasee's value type and address space, the aliasee's linkage
        ga := ltt_alias_create(glob(target).value_type, glob(target).linkage, "", target);
        gv_set_visibility(ga, glob(a.alias).visibility);
        gv_set_linkage(ga, glob(a.alias).linkage);
        gv_take_name(ga, a.alias);
        ipo_rauw(a.alias, ga);
        gv_erase_from_parent(a.alias);
    }

    if si {
        sk := named_md_find("symvers");
        if sk >= 0 {
            for sv: ir.named_md[sk].ops {
                sym := ir.mds[md_op(sv, 0)].str;
                als := ir.mds[md_op(sv, 1)].str;
                if exported_find(exported, sym) < 0 continue;
                append_module_asm(tconcat(".symver ", sym, ", ", als), "", "");
            }
        }
    }
    return true;
}

// LowerTypeTestsPass::run (use_cl: the pass was named on the command line, runForTesting)
lower_type_tests_run :: (use_cl := true) -> Preserved {
    changed: bool;
    if use_cl {
        summary: Summary_Index;
        summary.gv_map.allocator = temp;
        if ltt_cl.read_summary.count read_summary_yaml(ltt_cl.read_summary, *summary, "-lowertypetests-read-summary");
        if ltt_cl.write_summary.count fatal("-lowertypetests-write-summary is not supported (writing YAML summaries is not ported)");
        l := ltt_new(ifx ltt_cl.summary_action == .Export then *summary else null, ifx ltt_cl.summary_action == .Import then *summary else null);
        changed = ltt_lower(l);
    } else {
        l := ltt_new(null, null);
        changed = ltt_lower(l);
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
