// CGProfile: port of llvm/lib/Transforms/Instrumentation/CGProfile.cpp (addModuleFlags, runCGProfilePass).
// Indirect calls with value-profile data fail loudly (InstrProfSymtab is not ported).

cg_profile_run :: () -> Preserved {
    keys_a: [..] Value_Id; keys_a.allocator = temp;   // MapVector<pair<Function*, Function*>, uint64_t>
    keys_b: [..] Value_Id; keys_b.allocator = temp;
    counts: [..] u64; counts.allocator = temp;
    update :: (f: Value_Id, called: Value_Id, n: u64) #expand {
        if n == 0 return;
        if called == NONE || !tti_is_lowered_to_call(called) || glob(called).dll == 1 return;
        for k: 0..keys_a.count - 1 {
            if keys_a[k] == f && keys_b[k] == called {
                s := counts[k] + n; if s < n s = 0xFFFF_FFFF_FFFF_FFFF;   // SaturatingAdd
                counts[k] = s;
                return;
            }
        }
        array_add(*keys_a, f); array_add(*keys_b, called); array_add(*counts, n);
    }
    for f: ir.m_functions {
        if is_declaration(f) continue;
        has, _ := function_entry_count(f);
        if !has continue;
        bfi := get_bfi(f);
        if bfi.entry_freq == 0 continue;
        for bb: fn_blocks(f) {
            okc, bb_count := bfi_profile_count_from_freq(bfi, f, bfi_get_block_freq(bfi, bb));
            if !okc continue;
            for i: block_insts(bb) {
                if !is_call_base(i) continue;
                if call_is_indirect(i) {
                    prof := get_metadata(i, md_kind_id("prof"));
                    if prof != NONE && md_nops(prof) > 0 && md_str_of(md_op(prof, 0)) == "VP"
                        fatal("cg-profile: value-profile data of indirect calls is not supported yet");
                    continue;
                }
                update(f, call_called_function(i), bb_count);
            }
        }
    }
    if keys_a.count == 0 return PRESERVE_ALL;
    nodes: [..] Md_Id; nodes.allocator = temp;
    for k: 0..keys_a.count - 1 {
        vals: [3] Md_Id;
        vals[0] = md_value(keys_a[k]); vals[1] = md_value(keys_b[k]); vals[2] = md_value(const_int(type_int(64), counts[k]));
        array_add(*nodes, md_tuple(vals, false));
    }
    // M.addModuleFlag(Module::Append, "CG Profile", MDTuple::getDistinct(Context, Nodes))
    flag: [3] Md_Id;
    flag[0] = md_value(const_int(ir.t_i32, 5));
    flag[1] = md_string("CG Profile");
    flag[2] = md_tuple(nodes, true);
    k := named_md_get_or_insert("llvm.module.flags");
    array_add(*ir.named_md[k].ops, md_tuple(flag, false));
    return PRESERVE_ALL;
}
