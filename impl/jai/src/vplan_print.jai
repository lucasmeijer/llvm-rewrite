// Debug-only VPlan dump (an approximation of VPlan::print; LLVM's release opt cannot print plans, so the format only
// serves to read our own plans). Enabled with the environment variable JAI_VPLAN_DEBUG=1; written to stderr.

vp_getenv :: (name: *u8) -> *u8 #foreign libc_for_errno "getenv";
vp_debug_enabled :: () -> bool {
    p := vp_getenv("JAI_VPLAN_DEBUG");
    return p != null && p[0] != 0 && p[0] != #char "0";
}

vp_value_str :: (v: Vp_Val) -> string {
    if v == NONE return "<null>";
    row := vv(v);
    if row.kind == .IR {
        x := row.uv;
        if vkind(x) == .C_INT return tprint("ir<%>", const_int_sext(x));
        n := ir.v_name[x];
        if n.count return tprint("ir<%%>", "%", n);
        if is_const(x) return tprint("ir<const#%>", x);
        return tprint("ir<#%>", x);
    }
    if v == vpl.vf return "vp<VF>";
    if v == vpl.uf return "vp<UF>";
    if v == vpl.vfxuf return "vp<VFxUF>";
    if v == vpl.vector_trip_count return ifx row.uv != NONE then tprint("vp<vtc=%>", vp_value_str_ir(row.uv)) else "vp<vector-trip-count>";
    if v == vpl.btc return "vp<BTC>";
    if row.kind == .REGION { if v == vb(row.region).can_iv return "vp<can-iv>"; return "vp<header-mask>"; }
    if row.uv != NONE && ir.v_name[row.uv].count return tprint("ir<%%>[%]", "%", ir.v_name[row.uv], v);
    return tprint("vp<%%>", "%", v);
}
vp_value_str_ir :: (x: Value_Id) -> string {
    if vkind(x) == .C_INT return tprint("%", const_int_sext(x));
    return tprint("%%", "%", ir.v_name[x]);
}
vp_opcode_name :: (o: u16) -> string {
    if vp_is_ir_opcode(o) return tprint("%", vp_ir_opcode(o));
    if o == {
        case VPI_FIRST_ORDER_RECURRENCE_SPLICE; return "first-order splice";
        case VPI_NOT; return "not";
        case VPI_ACTIVE_LANE_MASK; return "active lane mask";
        case VPI_CANONICAL_IV_INCREMENT_FOR_PART; return "VF * Part +";
        case VPI_BRANCH_ON_COUNT; return "branch-on-count";
        case VPI_BRANCH_ON_COND; return "branch-on-cond";
        case VPI_BRANCH_ON_TWO_CONDS; return "branch-on-two-conds";
        case VPI_BROADCAST; return "broadcast";
        case VPI_BUILD_VECTOR; return "buildvector";
        case VPI_BUILD_STRUCT_VECTOR; return "buildstructvector";
        case VPI_UNPACK; return "unpack";
        case VPI_COMPUTE_REDUCTION_RESULT; return "compute-reduction-result";
        case VPI_EXTRACT_LAST_PART; return "extract-last-part";
        case VPI_EXTRACT_LAST_LANE; return "extract-last-lane";
        case VPI_EXTRACT_PENULTIMATE_ELEMENT; return "extract-penultimate-element";
        case VPI_LOGICAL_AND; return "logical-and";
        case VPI_LOGICAL_OR; return "logical-or";
        case VPI_PTR_ADD; return "ptradd";
        case VPI_WIDE_PTR_ADD; return "wide-ptradd";
        case VPI_ANY_OF; return "any-of";
        case VPI_EXTRACT_LANE; return "extract-lane";
        case VPI_EXITING_IV_VALUE; return "exiting-iv-value";
        case VPI_WIDE_IV_STEP; return "wide-iv-step";
        case VPI_STEP_VECTOR; return "step-vector";
        case VPI_REVERSE; return "reverse";
        case VPI_REDUCTION_START_VECTOR; return "reduction-start-vector";
        case VPI_INTRINSIC; return "intrinsic";
    }
    return tprint("vpi#%", o);
}

vp_print_plan :: (title: string) {
    if !vp_debug_enabled() return;
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "VPlan '%' (%) {\n", vpl.name, title);
    print_to_builder(*sb, "  VFs:"); for vpl.vfs print_to_builder(*sb, " %", it.n); print_to_builder(*sb, " UFs:"); for vpl.ufs print_to_builder(*sb, " %", it);
    print_to_builder(*sb, "\n  trip count = %\n", vp_value_str(vpl.trip_count));
    vp_print_blocks(*sb, vpl.entry, "  ");
    print_to_builder(*sb, "}\n");
    write_string(builder_to_string(*sb,, temp), to_standard_error = true);
}
vp_print_blocks :: (sb: *String_Builder, start: Vp_Blk, indent: string) {
    for b: vp_depth_first_shallow(start) {
        if vp_is_region(b) {
            print_to_builder(sb, "%<% region '%'> {\n", indent, ifx vp_is_replicator(b) then "replicate" else "loop", vb(b).name);
            vp_print_blocks(sb, vb(b).entry, tconcat(indent, "  "));
            print_to_builder(sb, "%}\n", indent);
        } else {
            print_to_builder(sb, "%%:\n", indent, vb(b).name);
            r := vb(b).first;
            while r != NONE { print_to_builder(sb, "%  %\n", indent, vp_recipe_str(r)); r = vr(r).next; }
        }
        print_to_builder(sb, "%Successor(s):", indent);
        for s: vb(b).succs print_to_builder(sb, " %", vb(s).name);
        print_to_builder(sb, "\n");
    }
}
vp_recipe_str :: (r: Vp_Rec) -> string {
    row := vr(r);
    sb: String_Builder; sb.allocator = temp;
    if row.def != NONE print_to_builder(*sb, "% = ", vp_value_str(row.def));
    for row.defs print_to_builder(*sb, "% ", vp_value_str(it));
    print_to_builder(*sb, "%", row.kind);
    if row.kind == .INSTRUCTION || row.kind == .WIDEN || row.kind == .WIDEN_CAST print_to_builder(*sb, " %", vp_opcode_name(row.opcode));
    if row.kind == .IR_INSTRUCTION print_to_builder(*sb, " #%", row.ir_inst);
    if row.kind == .REPLICATE { print_to_builder(*sb, " %%", inst_op(vp_underlying_instr(r)), ifx row.single_scalar then " (single)" else ""); }
    if row.flags.optype == .OVERFLOWING_BINOP { if row.flags.nuw print_to_builder(*sb, " nuw"); if row.flags.nsw print_to_builder(*sb, " nsw"); }
    for row.ops print_to_builder(*sb, "% %", ifx it_index then "," else "", vp_value_str(it));
    if row.name.count print_to_builder(*sb, "  ; name=%", row.name);
    return builder_to_string(*sb,, temp);
}
