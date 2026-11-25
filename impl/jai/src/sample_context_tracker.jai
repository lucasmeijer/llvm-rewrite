// SampleContextTracker and ContextTrieNode: the trie of context-sensitive (CS) sample profiles used by the sample
// profile loader. Ported from llvm/lib/Transforms/IPO/SampleContextTracker.cpp (all but the debug dumps and
// createContextLessProfileMap), SampleContextFrame::getHashCode (llvm/include/llvm/ProfileData/SampleProf.h, with
// libstdc++'s std::hash<std::string> = _Hash_bytes) and the CS constructor of ProfiledCallGraph
// (llvm/include/llvm/Transforms/IPO/ProfiledCallGraph.h), plus findExternalInlineCandidate's CS walk
// (llvm/lib/Transforms/IPO/SampleProfile.cpp).
//
// Nodes are rows; a node's children are kept sorted by the context frame hash, like the std::map of LLVM. A moved
// subtree (moveContextSamples, which copies the std::map subtree) reuses the same rows with new parent links.

Ctn :: struct {
    parent: s32 = -1;
    func: Fid;
    fs: *Fs;
    loc: Line_Loc;
    children: [..] Ctn_Child;   // sorted by hash
}
Ctn_Child :: struct { hash: u64; node: s32; }

sp_ctx: struct {
    nodes: [..] Ctn;
    root: s32;
    profile_to_node: Table(*Fs, s32);
    func_to_profiles: Table(string, [..] *Fs);   // FuncToCtxtProfiles, keyed by fid_key
}

fid_key :: (f: Fid) -> string { if f.md5 return tprint("#%", f.h); return f.s; }

// libstdc++ std::_Hash_bytes(ptr, len, seed = 0xc70f6907) for a 64-bit size_t
std_hash_string :: (s: string) -> u64 {
    MUL : u64 : 0xc6a4a793_5bd1e995;
    shift_mix :: (v: u64) -> u64 { return v ^ (v >> 47); }
    len := cast(u64) s.count;
    aligned := len & ~cast(u64) 7;
    hash: u64 = 0xc70f6907 ^ (len * MUL);
    p: u64 = 0;
    while p < aligned {
        d: u64 = 0;
        for k: 0..7 d |= (cast(u64) s[p + cast(u64) k]) << (8 * cast(u64) k);
        data := shift_mix(d * MUL) * MUL;
        hash ^= data;
        hash *= MUL;
        p += 8;
    }
    rest := len & 7;
    if rest {
        // load_bytes(end, n): big-endian accumulation from the last byte down
        d: u64 = 0;
        n := cast(s64) rest - 1;
        while n >= 0 { d = (d << 8) + cast(u64) s[aligned + cast(u64) n]; n -= 1; }
        hash ^= d;
        hash *= MUL;
    }
    hash = shift_mix(hash) * MUL;
    hash = shift_mix(hash);
    return hash;
}
// FunctionSamples::getCallSiteHash(Callee, Callsite) = SampleContextFrame::getHashCode
sp_call_site_hash :: (callee: Fid, loc: Line_Loc) -> u64 {
    name_hash := ifx callee.md5 then callee.h else std_hash_string(callee.s);
    loc_id := ((cast(u64) loc.disc) << 32) | cast(u64) loc.line;
    return name_hash + (loc_id << 5) + loc_id;
}

ctn :: inline (n: s32) -> *Ctn { return *sp_ctx.nodes[n]; }
ctn_new :: (parent: s32, func: Fid, fs: *Fs, loc: Line_Loc) -> s32 {
    c: Ctn; c.parent = parent; c.func = func; c.fs = fs; c.loc = loc;
    array_add(*sp_ctx.nodes, c);
    return cast(s32) sp_ctx.nodes.count - 1;
}
ctn_find_child :: (n: s32, hash: u64) -> s32 {
    ch := ctn(n).children;
    lo := 0; hi := ch.count;
    while lo < hi { m := (lo + hi) / 2; if ch[m].hash < hash lo = m + 1; else hi = m; }
    if lo < ch.count && ch[lo].hash == hash return ch[lo].node;
    return -1;
}
ctn_insert_child :: (n: s32, hash: u64, child: s32) {
    ch := *ctn(n).children;
    lo := 0; hi := ch.count;
    while lo < hi { m := (lo + hi) / 2; if ch.*[m].hash < hash lo = m + 1; else hi = m; }
    array_insert_at(ch, .{hash, child}, lo);
}
// ContextTrieNode::removeChildContext
ctn_remove_child :: (n: s32, loc: Line_Loc, callee: Fid) {
    h := sp_call_site_hash(callee, loc);
    ch := *ctn(n).children;
    for ch.* if it.hash == h { array_ordered_remove_by_index(ch, it_index); return; }
}
// ContextTrieNode::getChildContext
ctn_get_child_context :: (n: s32, loc: Line_Loc, callee: Fid) -> s32 {
    if fid_empty(callee) return ctn_get_hottest_child_context(n, loc);
    return ctn_find_child(n, sp_call_site_hash(callee, loc));
}
// getHottestChildContext
ctn_get_hottest_child_context :: (n: s32, loc: Line_Loc) -> s32 {
    ret: s32 = -1;
    max: u64 = 0;
    for c: ctn(n).children {
        cn := ctn(c.node);
        if !loc_eq(cn.loc, loc) continue;
        if !cn.fs continue;
        if cn.fs.total > max { ret = c.node; max = cn.fs.total; }
    }
    return ret;
}
// getOrCreateChildContext
ctn_get_or_create_child_context :: (n: s32, loc: Line_Loc, callee: Fid, allow_create := true) -> s32 {
    h := sp_call_site_hash(callee, loc);
    c := ctn_find_child(n, h);
    if c >= 0 {
        if !fid_eq(ctn(c).func, callee) fatal("sample-profile: hash collision of two child context nodes (LLVM asserts)");
        return c;
    }
    if !allow_create return -1;
    nc := ctn_new(n, callee, null, loc);
    ctn_insert_child(n, h, nc);
    return nc;
}

sp_ctx_set_context_node :: (fs: *Fs, n: s32) { table_set(*sp_ctx.profile_to_node, fs, n); }
sp_ctx_node_for_profile :: (fs: *Fs) -> s32 {
    found, n := table_find(*sp_ctx.profile_to_node, fs);
    return ifx found then n else -1;
}

// the trie in breadth-first order (SampleContextTracker::Iterator)
sp_ctx_bfs :: () -> [..] s32 {
    out: [..] s32; out.allocator = temp;
    array_add(*out, sp_ctx.root);
    k := 0;
    while k < out.count {
        for ctn(out[k]).children array_add(*out, it.node);
        k += 1;
    }
    return out;
}

// SampleContextTracker::SampleContextTracker(Profiles, GUIDToFuncNameMap)
sp_context_tracker_init :: () {
    sp_ctx.nodes.count = 0;
    sp_ctx.profile_to_node = .{};
    sp_ctx.func_to_profiles = .{};
    sp_ctx.root = ctn_new(-1, .{}, null, .{});
    for fs: sp_reader.profiles {
        n := sp_ctx_get_or_create_context_path(fs.ctx.frames, true);
        if ctn(n).fs fatal("sample-profile: two CS profiles of one context (LLVM asserts)");
        ctn(n).fs = fs;
    }
    // populateFuncToCtxtMap
    for n: sp_ctx_bfs() {
        fs := ctn(n).fs;
        if !fs continue;
        fs.ctx.state |= CTX_RAW;
        sp_ctx_set_context_node(fs, n);
        p := sp_ctx_profiles_for(ctn(n).func);
        array_add(p, fs);
    }
}
sp_ctx_profiles_for :: (f: Fid) -> *[..] *Fs {
    k := fid_key(f);
    p := table_find_pointer(*sp_ctx.func_to_profiles, k);
    if p return p;
    e: [..] *Fs;
    table_set(*sp_ctx.func_to_profiles, copy_string(k), e);
    return table_find_pointer(*sp_ctx.func_to_profiles, k);
}

// getOrCreateContextPath(Context, AllowCreate)
sp_ctx_get_or_create_context_path :: (frames: [] Ctx_Frame, allow_create: bool) -> s32 {
    n := sp_ctx.root;
    loc: Line_Loc;
    for fr: frames {
        if allow_create n = ctn_get_or_create_child_context(n, loc, fr.func);
        else n = ctn_get_child_context(n, loc, fr.func);
        if n < 0 return -1;
        loc = fr.loc;
    }
    return n;
}

// getContextFor(const DILocation *DIL)
sp_ctx_get_context_for :: (dil_in: Md_Id) -> s32 {
    Pair :: struct { loc: Line_Loc; f: Fid; }
    s: [..] Pair; s.allocator = temp;
    prev := dil_in;
    d := diloc_inlined_at(dil_in);
    while d != NONE {
        array_add(*s, .{sp_callsite_id(d), fid_rep_in_format(sp_scope_fn_name(prev))});
        prev = d;
        d = diloc_inlined_at(d);
    }
    array_add(*s, .{.{}, fid_rep_in_format(sp_scope_fn_name(prev))});
    n := sp_ctx.root;
    i := s.count - 1;
    while i >= 0 && n >= 0 {
        n = ctn_get_child_context(n, s[i].loc, s[i].f);
        i -= 1;
    }
    if i < 0 return n;
    return -1;
}
// getCalleeContextFor
sp_ctx_get_callee_context_for :: (dil: Md_Id, callee: Fid) -> s32 {
    c := sp_ctx_get_context_for(dil);
    if c < 0 return -1;
    return ctn_get_child_context(c, sp_callsite_id(dil), callee);
}

// getCalleeContextSamplesFor(Inst, CalleeName)
sp_ctx_get_callee_context_samples_for :: (i: Value_Id, callee_in: string) -> *Fs {
    dil := get_metadata(i, 0);
    if dil == NONE return null;
    callee := sp_canonical_fn_name(callee_in);
    c := sp_ctx_get_callee_context_for(dil, fid_rep_in_format(callee));
    if c >= 0 return ctn(c).fs;
    return null;
}
// getIndirectCalleeContextSamplesFor
sp_ctx_get_indirect_callee_context_samples_for :: (dil: Md_Id) -> [..] *Fs {
    r: [..] *Fs; r.allocator = temp;
    if dil == NONE return r;
    caller := sp_ctx_get_context_for(dil);
    if caller < 0 fatal("sample-profile: no context node for an indirect call's caller (LLVM dereferences null)");
    cs := sp_callsite_id(dil);
    for c: ctn(caller).children {
        cn := ctn(c.node);
        if !loc_eq(cn.loc, cs) continue;
        if cn.fs array_add(*r, cn.fs);
    }
    return r;
}
// getContextSamplesFor(const DILocation *DIL)
sp_ctx_get_context_samples_for :: (dil: Md_Id) -> *Fs {
    n := sp_ctx_get_context_for(dil);
    if n < 0 return null;
    fs := ctn(n).fs;
    if fs && ctn(n).parent != sp_ctx.root fs.ctx.state |= CTX_INLINED;
    return fs;
}

// getBaseSamplesFor(const Function &Func, MergeContext = true)
sp_ctx_get_base_samples_for :: (f: Value_Id) -> *Fs {
    return sp_ctx_get_base_samples_for_name(fid_rep_in_format(sp_canonical_fn_name_of(f)), true);
}
sp_ctx_get_base_samples_for_name :: (name: Fid, merge_context: bool) -> *Fs {
    node := ctn_get_child_context(sp_ctx.root, .{}, name);   // getTopLevelContextNode
    if merge_context {
        profiles := sp_ctx_profiles_for(name).*;
        for cs: profiles {
            st := cs.ctx.state;
            if (st & CTX_INLINED) || (st & CTX_MERGED) continue;
            from := sp_ctx_node_for_profile(cs);
            if from == node continue;
            to := sp_ctx_promote_merge_context_samples_tree_root(from);
            node = to;
        }
    }
    if node < 0 return null;
    return ctn(node).fs;
}

// markContextSamplesInlined
sp_ctx_mark_context_samples_inlined :: (fs: *Fs) { fs.ctx.state |= CTX_INLINED; }

// promoteMergeContextSamplesTree(const Instruction &Inst, FunctionId CalleeName)
sp_ctx_promote_merge_context_samples_tree_inst :: (i: Value_Id, callee: Fid) {
    dil := get_metadata(i, 0);
    caller := sp_ctx_get_context_for(dil);
    if caller < 0 return;
    cs := sp_callsite_id(dil);
    if fid_empty(callee) {
        // the children are walked as they were; a promoted child leaves this list (std::map erase while iterating)
        kids: [..] Ctn_Child; kids.allocator = temp;
        for ctn(caller).children array_add(*kids, it);
        for c: kids {
            if ctn_find_child(caller, c.hash) != c.node continue;
            if !loc_eq(cs, ctn(c.node).loc) continue;
            from := ctn(c.node).fs;
            if from && (from.ctx.state & CTX_INLINED) continue;
            sp_ctx_promote_merge_context_samples_tree_root(c.node);
        }
        return;
    }
    n := ctn_get_child_context(caller, cs, callee);
    if n < 0 return;
    sp_ctx_promote_merge_context_samples_tree_root(n);
}
// promoteMergeContextSamplesTree(ContextTrieNode &NodeToPromo)
sp_ctx_promote_merge_context_samples_tree_root :: (n: s32) -> s32 {
    return sp_ctx_promote_merge_context_samples_tree(n, sp_ctx.root);
}

// mergeContextNode
sp_ctx_merge_context_node :: (from: s32, to: s32) {
    fs := ctn(from).fs; ts := ctn(to).fs;
    if fs && ts {
        fs_merge(ts, fs, 1);
        ts.ctx.state |= CTX_SYNTHETIC;
        fs.ctx.state |= CTX_MERGED;
        if fs.ctx.attrs & CTX_SHOULD_BE_INLINED ts.ctx.attrs |= CTX_SHOULD_BE_INLINED;
    } else if fs {
        ctn(to).fs = fs;
        sp_ctx_set_context_node(fs, to);
        fs.ctx.state |= CTX_SYNTHETIC;
    }
}

// moveContextSamples(ToNodeParent, CallSite, NodeToMove): the subtree moves (keeps its rows)
sp_ctx_move_context_samples :: (to_parent: s32, loc: Line_Loc, node: s32) -> s32 {
    h := sp_call_site_hash(ctn(node).func, loc);
    if ctn_find_child(to_parent, h) >= 0 fatal("sample-profile: moving a context node onto an existing one (LLVM asserts)");
    ctn_insert_child(to_parent, h, node);
    ctn(node).loc = loc;
    ctn(node).parent = to_parent;
    queue: [..] s32; queue.allocator = temp;
    array_add(*queue, node);
    k := 0;
    while k < queue.count {
        x := queue[k]; k += 1;
        fs := ctn(x).fs;
        if fs {
            sp_ctx_set_context_node(fs, x);
            fs.ctx.state |= CTX_SYNTHETIC;
        }
        for c: ctn(x).children {
            ctn(c.node).parent = x;
            array_add(*queue, c.node);
        }
    }
    return node;
}

// promoteMergeContextSamplesTree(FromNode, ToNodeParent)
sp_ctx_promote_merge_context_samples_tree :: (from: s32, to_parent: s32) -> s32 {
    new_loc: Line_Loc;
    old_loc := ctn(from).loc;
    from_parent := ctn(from).parent;
    move_to_root := to_parent == sp_ctx.root;
    if !move_to_root new_loc = old_loc;
    func := ctn(from).func;
    to := ctn_get_child_context(to_parent, new_loc, func);
    if to < 0 {
        // the old parent keeps its entry for now (only the root case removes it below)
        old_hash := sp_call_site_hash(func, old_loc);
        to = sp_ctx_move_context_samples(to_parent, new_loc, from);
        if !move_to_root {
            // the copy of LLVM leaves the old row behind, the caller clears the old parent's children
            _ = old_hash;
        }
    } else {
        sp_ctx_merge_context_node(from, to);
        kids: [..] Ctn_Child; kids.allocator = temp;
        for ctn(from).children array_add(*kids, it);
        for c: kids sp_ctx_promote_merge_context_samples_tree(c.node, to);
        ctn(from).children.count = 0;
    }
    if move_to_root ctn_remove_child(from_parent, old_loc, ctn(to).func);
    return to;
}

// findExternalInlineCandidate, the CS part: BFS over the trie from the caller's node
sp_ctx_find_external_inline_candidate :: (samples: *Fs, s: *[..] u64, threshold: u64) {
    caller := sp_ctx_node_for_profile(samples);
    if caller < 0 fatal("sample-profile: a CS profile without a context node (LLVM dereferences null)");
    queue: [..] s32; queue.allocator = temp;
    array_add(*queue, caller);
    k := 0;
    is_decl :: (f: Value_Id) -> bool { return f == NONE || is_declaration(f); }
    while k < queue.count {
        n := queue[k]; k += 1;
        cs := ctn(n).fs;
        if !cs continue;
        pre_inline := sp_opts.use_preinliner && (cs.ctx.attrs & CTX_SHOULD_BE_INLINED) != 0;
        if !pre_inline && fs_head_samples_estimate(cs) < threshold continue;
        if is_decl(spl_symbol_lookup(cs.ctx.func)) sp_guid_set_add(s, fs_guid(cs));
        for cs.body for t: it.rec.targets {
            if t.count > threshold && is_decl(spl_symbol_lookup(t.f)) sp_guid_set_add(s, fid_hash(t.f));
        }
        for ctn(n).children array_add(*queue, it.node);
    }
}

// ProfiledCallGraph(SampleContextTracker &, IgnoreColdCallThreshold = 0)
sp_ctx_add_profiled_calls :: (g: *Pcg) {
    queue: [..] s32; queue.allocator = temp;
    for ctn(sp_ctx.root).children {
        pcg_add_function(g, ctn(it.node).func);
        array_add(*queue, it.node);
    }
    k := 0;
    while k < queue.count {
        caller := queue[k]; k += 1;
        caller_samples := ctn(caller).fs;
        for c: ctn(caller).children {
            callee := c.node;
            pcg_add_function(g, ctn(callee).func);
            array_add(*queue, callee);
            w: u64 = 0;
            callee_samples := ctn(callee).fs;
            if callee_samples && caller_samples {
                entry := fs_head_samples_estimate(callee_samples);
                count: u64 = 0;
                t := fs_find_call_target_map_at(caller_samples, ctn(callee).loc);
                if t for t.targets if fid_eq(it.f, callee_samples.ctx.func) { count = it.count; break; }
                w = max(count, entry);
            }
            pcg_add_call(g, ctn(caller).func, ctn(callee).func, w);
        }
    }
}
