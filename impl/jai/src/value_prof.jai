// Value profile metadata (!prof !{!"VP", i32 kind, i64 total, (i64 value, i64 count)...}).
// Ported from llvm/lib/ProfileData/InstrProf.cpp: annotateValueSite, mayHaveValueProfileOfKind,
// getValueProfDataFromInst.

// IPVK_* are in instrprof_common.jai
NOMORE_ICP_MAGICNUM : u64 : 0xFFFF_FFFF_FFFF_FFFF;

Vp_Data :: struct { value: u64; count: u64; }

// mayHaveValueProfileOfKind
vp_md_of_kind :: (i: Value_Id, kind: u32) -> Md_Id {
    m := get_metadata(i, md_fixed("prof"));
    if m == NONE || md_nops(m) < 5 return NONE;
    t := md_op(m, 0);
    if t == NONE || ir.mds[t].kind != .STRING || ir.mds[t].str != "VP" return NONE;
    k := md_const_int_op(m, 1);
    if k == NONE return NONE;
    if const_int_zext(k) != kind return NONE;
    return m;
}

// getValueProfDataFromInst: the data and the total count (TotalC is only written when the metadata is found)
vp_get_value_prof_data :: (i: Value_Id, kind: u32, max_num: u32, get_no_icp_value: bool) -> ([..] Vp_Data, bool, u64) {
    out: [..] Vp_Data; out.allocator = temp;
    m := vp_md_of_kind(i, kind);
    if m == NONE return out, false, 0;
    n := md_nops(m);
    tc := md_const_int_op(m, 2);
    if tc == NONE return out, false, 0;
    total := const_int_zext(tc);
    k: u32 = 3;
    while k < n {
        if out.count >= cast(s64) max_num break;
        v := md_const_int_op(m, k);
        c := md_const_int_op(m, k + 1);
        if v == NONE || c == NONE { out.count = 0; return out, true, total; }
        cnt := const_int_zext(c);
        k += 2;
        if !get_no_icp_value && cnt == NOMORE_ICP_MAGICNUM continue;
        array_add(*out, .{const_int_zext(v), cnt});
    }
    return out, true, total;
}

// annotateValueSite(M, Inst, VDs, Sum, ValueKind, MaxMDCount)
vp_annotate_value_site :: (i: Value_Id, vds: [] Vp_Data, sum: u64, kind: u32, max_md_count: u32) {
    if vds.count == 0 return;
    vals: [..] Md_Id; vals.allocator = temp;
    array_add(*vals, md_string("VP"));
    array_add(*vals, md_value(const_int(ir.t_i32, kind)));
    array_add(*vals, md_value(const_int(ir.t_i64, sum)));
    md_count := max_md_count;
    zero_count: u64 = 0;
    visited: [..] u64; visited.allocator = temp;
    for vd: vds {
        inserted := true;
        for visited if it == vd.value { inserted = false; break; }
        if inserted array_add(*visited, vd.value);
        if vd.value != 0 && !inserted continue;
        if vd.value == 0 zero_count += vd.count;
        else {
            array_add(*vals, md_value(const_int(ir.t_i64, vd.value)));
            array_add(*vals, md_value(const_int(ir.t_i64, vd.count)));
        }
        md_count -= 1;
        if md_count == 0 break;
    }
    if zero_count != 0 {
        array_add(*vals, md_value(const_int(ir.t_i64, 0)));
        array_add(*vals, md_value(const_int(ir.t_i64, zero_count)));
    }
    if vals.count >= 5 set_metadata(i, md_fixed("prof"), md_tuple(vals, false));
}
