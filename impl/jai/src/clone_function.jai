// Cloning basic blocks and loops.
// Port of llvm/lib/Transforms/Utils/CloneFunction.cpp (CloneBasicBlock, mapAtomInstance, remapInstructionsInBlocks,
// cloneNoAliasScopes, adaptNoAliasScopes, cloneAndAdaptNoAliasScopes, identifyNoAliasScopesToClone) and
// cloneLoop from llvm/lib/Transforms/Utils/LoopUtils.cpp.
//
// Reusable API:
//   clone_basic_block(bb, *vm, suffix, f = NONE) -> Value_Id    CloneBasicBlock(BB, VMap, NameSuffix, F)
//       f == NONE gives a block without a parent (its names are not in any symbol table yet); insert it with
//       fn_insert_detached_block_before / _after, which links it and then (re)inserts the instruction names and the
//       block name like SymbolTableListTraits (instructions first, then the block).
//   remap_instructions_in_blocks(blocks, *vm)                   remapInstructionsInBlocks
//   identify_no_alias_scopes_to_clone(blocks, *out)             identifyNoAliasScopesToClone(BBs, ...)
//   clone_and_adapt_no_alias_scopes(scopes, new_blocks, ext)    cloneAndAdaptNoAliasScopes(..., NewBlocks, ...)
//   clone_loop(li, l, parent, *vm) -> Loop_Id                   cloneLoop (no LPPassManager)
//   fn_splice_blocks(f, before, first)                          F->splice(Before, F, First, F->end())

// CloneBasicBlock(BB, VMap, NameSuffix, F, CodeInfo = nullptr, MapAtoms = true)
clone_basic_block :: (bb: Value_Id, vm: *Value_Map, suffix: string, f: Value_Id = NONE) -> Value_Id {
    nb: Value_Id;
    if f != NONE nb = create_block(f, "");
    else nb = new_block(NONE);
    if vname(bb).count set_name(nb, tprint("%0%", vname(bb), suffix));
    recs: [..] u32; recs.allocator = temp;
    for i: block_insts(bb) {
        c := inst_clone(i);
        if vname(i).count ir.v_name[c] = intern_str(tprint("%0%", vname(i), suffix));   // setName on an unlinked value
        block_append_inst(nb, c);
        if f != NONE ic_reinsert_name(c);
        if inst(i).records clone_debug_info_from(c, i, inst(i).records, *recs);
        table_set(*vm.map, i, c);
        map_atom_instance(c);
    }
    return nb;
}

// mapAtomInstance: key-instruction atom groups are not ported
map_atom_instance :: (i: Value_Id) {
    dl := get_metadata(i, 0);
    if dl != NONE && di_int(dl, 3) != 0 fatal("cloning: key-instruction atom groups (mapAtomInstance) are not implemented yet");
}

// Function::insert(Before, BB) for a block made by clone_basic_block(..., f = NONE): link it into f, then
// SymbolTableListTraits gives the instructions (in order) and then the block their (uniqued) names
fn_insert_detached_block_before :: (f: Value_Id, before: Value_Id, b: Value_Id) {
    fn_insert_block_before(f, before, b);
    fn_attach_detached_block(f, b);
}
fn_insert_detached_block_after :: (f: Value_Id, after: Value_Id, b: Value_Id) {
    fn_insert_block_after(f, after, b);
    fn_attach_detached_block(f, b);
}
fn_attach_detached_block :: (f: Value_Id, b: Value_Id) {
    block(b).parent = f;
    note_block_created(f, b);
    for i: block_insts(b) ic_reinsert_name(i);
    n := vname(b);
    if n.count { ir.v_name[b] = ""; set_name(b, n); }
}

// F->splice(Before, F, First, F->end()): move the blocks from `first` to the end of f in front of `before`
fn_splice_blocks :: (f: Value_Id, before: Value_Id, first: Value_Id) {
    if first == before return;
    moved: [..] Value_Id; moved.allocator = temp;
    b := first;
    while b != NONE { array_add(*moved, b); b = block(b).next; }
    for moved {
        if it == before return;   // `before` inside the range: nothing moves past it
    }
    for moved fn_unlink_block(f, it);
    for moved fn_insert_block_before(f, before, it);
}

// remapInstructionsInBlocks(Blocks, VMap)
remap_instructions_in_blocks :: (blocks: [] Value_Id, vm: *Value_Map) {
    for bb: blocks {
        for i: block_insts(bb) {
            remap_dbg_record_range(vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
            remap_instruction(vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        }
    }
}

// identifyNoAliasScopesToClone(BBs, NoAliasDeclScopes)
identify_no_alias_scopes_to_clone :: (blocks: [] Value_Id, out: *[..] Md_Id) {
    for bb: blocks for i: block_insts(bb)
        if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL array_add(out, cast(Md_Id) ir.v_aux[call_arg(i, 0)]);
}

// cloneNoAliasScopes(NoAliasDeclScopes, ClonedScopes, Ext, Context): DenseMap from each scope to a fresh anonymous
// scope in the same domain
No_Alias_Scope_Map :: struct { from: [..] Md_Id; to: [..] Md_Id; }
clone_no_alias_scopes :: (scopes: [] Md_Id, ext: string) -> No_Alias_Scope_Map {
    m: No_Alias_Scope_Map; m.from.allocator = temp; m.to.allocator = temp;
    for scope_list: scopes {
        n := md_nops(scope_list);
        if n > 0 for k: 0..n-1 {
            md := md_op(scope_list, k);
            if !md_is_node(md) continue;
            // AliasScopeNode: getName = operand 2 (MDString), getDomain = operand 1
            name := ext;
            if md_nops(md) > 2 {
                nm := md_op(md, 2);
                if nm != NONE && ir.mds[nm].kind == .STRING && ir.mds[nm].str.count name = tprint("%:%", ir.mds[nm].str, ext);
            }
            domain := ifx md_nops(md) > 1 then md_op(md, 1) else NONE;
            // MDBuilder::createAnonymousAliasScope(Domain, Name) = createAnonymousAARoot(Name, Domain)
            ops: [..] Md_Id; ops.allocator = temp;
            array_add(*ops, NONE);
            if domain != NONE array_add(*ops, domain);
            if name.count array_add(*ops, md_string(name));
            root := md_tuple(ops, true);
            ir.md_ops[ir.mds[root].ops] = root;
            // ClonedScopes.insert: the first insertion wins
            found := false;
            for m.from if it == md { found = true; break; }
            if !found { array_add(*m.from, md); array_add(*m.to, root); }
        }
    }
    return m;
}
// adaptNoAliasScopes(I, ClonedScopes, Context)
adapt_no_alias_scopes :: (i: Value_Id, m: *No_Alias_Scope_Map) {
    clone_scope_list :: (sl: Md_Id, m: *No_Alias_Scope_Map) -> Md_Id {
        needs := false;
        ops: [..] Md_Id; ops.allocator = temp;
        n := md_nops(sl);
        if n > 0 for k: 0..n-1 {
            md := md_op(sl, k);
            if !md_is_node(md) continue;
            rep: Md_Id = NONE;
            for m.from if it == md { rep = m.to[it_index]; break; }
            if rep != NONE { array_add(*ops, rep); needs = true; continue; }
            array_add(*ops, md);
        }
        if needs return md_tuple(ops, false);
        return NONE;
    }
    if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL {
        nsl := clone_scope_list(cast(Md_Id) ir.v_aux[call_arg(i, 0)], m);
        if nsl != NONE set_op(i, 0, md_as_value(nsl));
    }
    for kind: string.["noalias", "alias.scope"] {
        id := md_kind_id(kind);
        cs := get_metadata(i, id);
        if cs != NONE {
            nsl := clone_scope_list(cs, m);
            if nsl != NONE set_metadata(i, id, nsl);
        }
    }
}
// cloneAndAdaptNoAliasScopes(NoAliasDeclScopes, NewBlocks, Context, Ext)
clone_and_adapt_no_alias_scopes :: (scopes: [] Md_Id, new_blocks: [] Value_Id, ext: string) {
    if scopes.count == 0 return;
    m := clone_no_alias_scopes(scopes, ext);
    for bb: new_blocks for i: block_insts(bb) adapt_no_alias_scopes(i, *m);
}

// cloneLoop(L, PL, VM, LI, LPM = nullptr) (LoopUtils.cpp)
clone_loop :: (li: *Loop_Info, l: Loop_Id, parent: Loop_Id, vm: *Value_Map) -> Loop_Id {
    nl := li_alloc_loop(li);
    if parent != NONE li_add_child_loop(li, parent, nl);
    else li_add_top_level_loop(li, nl);
    for bb: li_blocks(li, l) if li_loop_for(li, bb) == l li_add_basic_block_to_loop(li, nl, vmap_get(vm, bb));
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(li, l) array_add(*subs, it);
    for subs clone_loop(li, it, nl, vm);
    return nl;
}
