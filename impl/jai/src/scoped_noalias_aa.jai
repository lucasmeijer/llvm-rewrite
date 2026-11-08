// ScopedNoAliasAA: a port of llvm/lib/Analysis/ScopedNoAliasAA.cpp (mayAliasInScopes over !alias.scope / !noalias
// lists, grouped by domain via AliasScopeNode::getDomain).

scoped_noalias_opts: struct { enable := true; };   // -enable-scoped-noalias

// AliasScopeNode::getDomain
alias_scope_domain :: (scope: Md_Id) -> Md_Id {
    if md_nops(scope) < 2 return NONE;
    return md_node_op(scope, 1);
}

// ScopedNoAliasAAResult::mayAliasInScopes
may_alias_in_scopes :: (scopes: Md_Id, noalias: Md_Id) -> bool {
    if scopes == NONE || noalias == NONE return true;
    // collectScopedDomains (a SmallPtrSet: the iteration order doesn't matter, the result is a conjunction)
    domains: [..] Md_Id; domains.allocator = temp;
    n := md_nops(noalias);
    if n > 0 for i: 0..n-1 {
        na := md_node_op(noalias, i);
        if na == NONE continue;
        d := alias_scope_domain(na);
        if d == NONE continue;
        seen := false;
        for domains if it == d { seen = true; break; }
        if !seen array_add(*domains, d);
    }
    collect :: (list: Md_Id, domain: Md_Id, out: *[..] Md_Id) {
        n := md_nops(list);
        if n > 0 for i: 0..n-1 {
            m := md_node_op(list, i);
            if m == NONE || alias_scope_domain(m) != domain continue;
            seen := false;
            for out.* if it == m { seen = true; break; }
            if !seen array_add(out, m);
        }
    }
    scope_nodes: [..] Md_Id; scope_nodes.allocator = temp;
    na_nodes: [..] Md_Id; na_nodes.allocator = temp;
    for d: domains {
        scope_nodes.count = 0;
        collect(scopes, d, *scope_nodes);
        if scope_nodes.count == 0 continue;
        na_nodes.count = 0;
        collect(noalias, d, *na_nodes);
        subset := true;
        for s: scope_nodes {
            found := false;
            for na_nodes if it == s { found = true; break; }
            if !found { subset = false; break; }
        }
        if subset return false;
    }
    return true;
}

// ScopedNoAliasAAResult::alias
scoped_noalias_alias :: (a: Mem_Loc, b: Mem_Loc) -> Alias_Result {
    if !scoped_noalias_opts.enable return ar(AR_MAY);
    if !may_alias_in_scopes(a.tags.scope, b.tags.noalias) return ar(AR_NO);
    if !may_alias_in_scopes(b.tags.scope, a.tags.noalias) return ar(AR_NO);
    return ar(AR_MAY);
}
// ScopedNoAliasAAResult::getModRefInfo(Call, Loc) and (Fence, Loc)
scoped_noalias_mod_ref_inst_loc :: (i: Value_Id, loc: Mem_Loc) -> u8 {
    if !scoped_noalias_opts.enable return MR_MODREF;
    if !may_alias_in_scopes(loc.tags.scope, get_metadata(i, md_kind_id("noalias"))) return MR_NO;
    if !may_alias_in_scopes(get_metadata(i, md_kind_id("alias.scope")), loc.tags.noalias) return MR_NO;
    return MR_MODREF;
}
// ScopedNoAliasAAResult::getModRefInfo(Call1, Call2)
scoped_noalias_mod_ref_call_call :: (c1: Value_Id, c2: Value_Id) -> u8 {
    if !scoped_noalias_opts.enable return MR_MODREF;
    sk := md_kind_id("alias.scope"); nk := md_kind_id("noalias");
    if !may_alias_in_scopes(get_metadata(c1, sk), get_metadata(c2, nk)) return MR_NO;
    if !may_alias_in_scopes(get_metadata(c2, sk), get_metadata(c1, nk)) return MR_NO;
    return MR_MODREF;
}
