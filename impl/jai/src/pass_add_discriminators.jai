// AddDiscriminators: assign DWARF base discriminators to instructions that share a file:line with instructions
// in other blocks (and to calls on the same line within one block).
// Ported from llvm/lib/Transforms/Utils/AddDiscriminators.cpp and DILocation::cloneWithBaseDiscriminator
// (llvm/lib/IR/DebugInfoMetadata.cpp). -enable-fs-discriminator (flow-sensitive) is not ported: it fails
// loudly in sample_profile_parse_cl_opt.

add_discriminators_cl: struct {
    no_discriminators := false;   // -no-discriminators
};

// DIScope::getFilename of a DILocation's scope
diloc_filename :: (l: Md_Id) -> string {
    s := diloc_scope(l);
    if s == NONE return "";
    file := discope_file(s);
    if file == NONE return "";
    return md_str_of(di_op(file, 0));
}

// DILocation::cloneWithBaseDiscriminator (EnableFSDiscriminator off): (ok, location)
diloc_clone_with_base_discriminator :: (l: Md_Id, d: u32) -> (bool, Md_Id) {
    if disc_is_pseudo_probe(diloc_discriminator(l)) return true, l;   // do not interfere with pseudo probes
    bd, df, ci := disc_decode(diloc_discriminator(l));
    if d == bd return true, l;
    ok, enc := disc_encode(d, df, ci);
    if ok return true, diloc_clone_with_discriminator(l, enc);
    return false, NONE;
}

// shouldHaveDiscriminator: !isa<IntrinsicInst>(I) || isa<MemIntrinsic>(I)
ad_should_have_discriminator :: (i: Value_Id) -> bool {
    if ad_is_intrinsic_inst(i) return is_mem_intrinsic_inst(i);
    return true;
}

// isa<IntrinsicInst>: a CallInst whose callee is an intrinsic function
ad_is_intrinsic_inst :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    cf := call_called_function(i);
    return cf != NONE && glob(cf).intrinsic;
}

add_discriminators_run :: (f: Value_Id) -> Preserved {
    if add_discriminators_cl.no_discriminators || fn_subprogram(f) == NONE return PRESERVE_ALL;
    changed := false;
    // Location = (filename, line), as a "line:filename" string
    loc_key :: (l: Md_Id) -> string { return tprint("%:%", diloc_line(l), diloc_filename(l)); }
    lbm_size: Table(string, s64);   lbm_size.allocator = temp;     // LBM[L].size()
    lbm_member: Table(string, bool); lbm_member.allocator = temp;  // (block, L) in LBM[L]
    ldm: Table(string, u32);        ldm.allocator = temp;         // LDM[L]
    for b: fn_blocks(f) for i: block_insts(b) {
        if !ad_should_have_discriminator(i) continue;
        dil := get_metadata(i, MDK_DBG);
        if dil == NONE continue;
        key := loc_key(dil);
        mkey := tprint("%|%", b, key);
        inserted := !table_contains(*lbm_member, mkey);
        if inserted {
            table_set(*lbm_member, mkey, true);
            p := table_find_pointer(*lbm_size, key);
            if p p.* += 1; else table_set(*lbm_size, key, 1);
        }
        _, size := table_find(*lbm_size, key);
        if size == 1 continue;
        disc: u32;
        p := table_find_pointer(*ldm, key);
        if !p { table_set(*ldm, key, 0); p = table_find_pointer(*ldm, key); }
        if inserted p.* += 1;
        disc = p.*;
        ok, nd := diloc_clone_with_base_discriminator(dil, disc);
        if ok set_metadata(i, MDK_DBG, nd);
        changed = true;
    }
    for b: fn_blocks(f) {
        call_locs: Table(string, bool); call_locs.allocator = temp;
        for i: block_insts(b) {
            o := inst_op(i);
            if o != .INVOKE && (o != .CALL || ad_is_intrinsic_inst(i)) continue;
            dil := get_metadata(i, MDK_DBG);
            if dil == NONE continue;
            key := loc_key(dil);
            if table_contains(*call_locs, key) {
                p := table_find_pointer(*ldm, key);
                if !p { table_set(*ldm, key, 0); p = table_find_pointer(*ldm, key); }
                p.* += 1;
                ok, nd := diloc_clone_with_base_discriminator(dil, p.*);
                if ok { set_metadata(i, MDK_DBG, nd); changed = true; }
            } else table_set(*call_locs, key, true);
        }
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
