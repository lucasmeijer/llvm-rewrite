// AssignGUID: give every defined global a !guid attachment.
// Ported from llvm/lib/Transforms/Utils/AssignGUID.cpp and GlobalValue::assignGUID / getGlobalIdentifier
// (llvm/lib/IR/Globals.cpp).

// GlobalValue::getGlobalIdentifier
gv_global_identifier :: (g: Value_Id) -> string {
    name := vname(g);
    if name.count && name[0] == 1 name = slice(name, 1, name.count - 1);
    if gv_has_local_linkage(g) {
        file := ir.source_filename;
        if file.count == 0 file = "<unknown>";
        return tconcat(file, ";", name);
    }
    return name;
}

// GlobalValue::assignGUID
gv_assign_guid :: (g: Value_Id) {
    if get_metadata(g, MDK_UNIQUE_ID) != NONE return;
    guid := md5_hash_u64(gv_global_identifier(g));
    ops: [1] Md_Id;
    ops[0] = md_value(const_int(type_int(64), guid));
    set_metadata(g, MDK_UNIQUE_ID, md_tuple(ops, false));
}

assign_guid_run :: () -> Preserved {
    for ir.m_globals if !is_declaration(it) gv_assign_guid(it);
    for ir.m_functions if !is_declaration(it) gv_assign_guid(it);
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
