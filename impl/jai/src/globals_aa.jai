// GlobalsAA (GlobalsModRef): a port of llvm/lib/Analysis/GlobalsModRef.cpp (AnalyzeGlobals, AnalyzeUsesOfPointer,
// AnalyzeIndirectGlobalMemory, AnalyzeCallGraph, alias, getModRefInfo(Call, Loc), getMemoryEffects(F)) and of the
// parts of llvm/lib/Analysis/CallGraph.cpp and llvm/include/llvm/ADT/SCCIterator.h it needs (the CallGraph built
// for the module, Tarjan's SCCs from the external calling node).
//
// A module analysis: `require<globals-aa>` computes `globals_aa` (heap); the function-level AAManager consults it
// only when it is cached, exactly like AAManager::getModuleAAResultImpl. GlobalsAA is stateless for the pass
// manager (PreservedAnalyses::preservedWhenStateless), so nothing invalidates it here. LLVM's deletion callbacks
// aren't needed: erased values keep their ids (never reused), so stale entries are never looked up again.
// Callback calls (!callback metadata: AbstractCallSite, forEachCallbackFunction) fail loudly.

// CallGraph: node 0 = ExternalCallingNode (function NONE), node 1 = CallsExternalNode (function NONE)
Cg_Node :: struct {
    f: Value_Id = NONE;
    callees: [..] s32;     // CalledFunctions, in insertion order
}
Call_Graph :: struct {
    nodes: [..] Cg_Node;
    of_fn: Table(Value_Id, s32);
}
CG_EXTERNAL_CALLING :: 0;
CG_CALLS_EXTERNAL :: 1;

cg_get_or_insert :: (cg: *Call_Graph, f: Value_Id) -> s32 {
    found, n := table_find(*cg.of_fn, f);
    if found return n;
    node: Cg_Node; node.f = f; node.callees.allocator = temp;
    array_add(*cg.nodes, node);
    n = cast(s32)(cg.nodes.count - 1);
    table_set(*cg.of_fn, f, n);
    return n;
}

fn_has_callback_md :: (f: Value_Id) -> bool { return get_metadata(f, md_kind_id("callback")) != NONE; }

// Function::hasAddressTaken(nullptr, IgnoreCallbackUses = true, IgnoreAssumeLikeCalls = true, IgnoreLLVMUsed = false)
fn_has_address_taken_for_cg :: (f: Value_Id) -> bool {
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        is_call := is_inst(usr) && is_call_base(usr);
        if is_call && opno_of(u) != nops(usr) - 1 {
            c := call_callee(usr);
            if vkind(c) == .FUNCTION && fn_has_callback_md(c) fatal("GlobalsAA: callback calls (!callback) are not supported yet");
        }
        if !is_call {
            o := opr_code(usr);
            if o == .BITCAST || o == .ADDRSPACECAST {
                all_assume_like := true;
                x := ir.v_first_use[usr];
                while x != NONE {
                    uu := ir.u_user[x];
                    if !(is_inst(uu) && is_assume_like_intrinsic(uu)) { all_assume_like = false; break; }
                    x = ir.u_next[x];
                }
                if all_assume_like continue;
            }
            return true;
        }
        if is_assume_like_intrinsic(usr) continue;
        if opno_of(u) != nops(usr) - 1 || inst(usr).ty2 != glob(f).value_type return true;
    }
    return false;
}
opno_of :: inline (u: Use_Id) -> u32 { return u - ir.v_ops[ir.u_user[u]]; }

// CallGraph::CallGraph(Module &)
cg_build :: () -> Call_Graph {
    cg: Call_Graph;
    cg.nodes.allocator = temp;
    cg.of_fn.allocator = temp;
    ext: Cg_Node; ext.callees.allocator = temp;
    array_add(*cg.nodes, ext);   // ExternalCallingNode (getOrInsertFunction(nullptr))
    table_set(*cg.of_fn, NONE, CG_EXTERNAL_CALLING);
    calls_ext: Cg_Node; calls_ext.callees.allocator = temp;
    array_add(*cg.nodes, calls_ext);
    for f: ir.m_functions {
        n := cg_get_or_insert(*cg, f);
        if !is_local_linkage(glob(f).linkage) || fn_has_address_taken_for_cg(f) array_add(*cg.nodes[CG_EXTERNAL_CALLING].callees, n);
        // populateCallGraphNode
        if is_declaration(f) && !fn_has_fn_attr(f, .NoCallback) array_add(*cg.nodes[n].callees, CG_CALLS_EXTERNAL);
        if !is_declaration(f) for i: fn_insts(f) {
            if !is_call_base(i) continue;
            callee := call_called_function(i);
            if callee == NONE array_add(*cg.nodes[n].callees, CG_CALLS_EXTERNAL);
            else {
                cn := cg_get_or_insert(*cg, callee);
                array_add(*cg.nodes[n].callees, cn);
            }
            c := call_callee(i);
            if vkind(c) == .FUNCTION && fn_has_callback_md(c) fatal("GlobalsAA: callback calls (!callback) are not supported yet");
        }
    }
    return cg;
}

// scc_iterator<CallGraph *>: SCCs (bottom-up) of the nodes reachable from the external calling node
cg_sccs :: (cg: *Call_Graph) -> [..] [..] s32 {
    result: [..] [..] s32; result.allocator = temp;
    Frame :: struct { node: s32; next_child: s64; min_visited: u32; }
    visit_num: u32 = 0;
    numbers: Table(s32, u32); numbers.allocator = temp;
    scc_stack: [..] s32; scc_stack.allocator = temp;
    visit_stack: [..] Frame; visit_stack.allocator = temp;
    visit_one :: (n: s32, visit_num: *u32, numbers: *Table(s32, u32), scc_stack: *[..] s32, visit_stack: *[..] Frame) {
        visit_num.* += 1;
        table_set(numbers, n, visit_num.*);
        array_add(scc_stack, n);
        array_add(visit_stack, .{n, 0, visit_num.*});
    }
    visit_one(CG_EXTERNAL_CALLING, *visit_num, *numbers, *scc_stack, *visit_stack);
    while visit_stack.count {
        // DFSVisitChildren
        while true {
            top := *visit_stack[visit_stack.count - 1];
            callees := cg.nodes[top.node].callees;
            if top.next_child >= callees.count break;
            child := callees[top.next_child];
            top.next_child += 1;
            found, num := table_find(*numbers, child);
            if !found { visit_one(child, *visit_num, *numbers, *scc_stack, *visit_stack); continue; }
            if top.min_visited > num top.min_visited = num;
        }
        visiting := visit_stack[visit_stack.count - 1].node;
        min_num := visit_stack[visit_stack.count - 1].min_visited;
        pop(*visit_stack);
        if visit_stack.count && visit_stack[visit_stack.count - 1].min_visited > min_num visit_stack[visit_stack.count - 1].min_visited = min_num;
        _, vn := table_find(*numbers, visiting);
        if min_num != vn continue;
        scc: [..] s32; scc.allocator = temp;
        while true {
            x := pop(*scc_stack);
            array_add(*scc, x);
            table_set(*numbers, x, 0xFFFF_FFFF);
            if x == visiting break;
        }
        array_add(*result, scc);
    }
    return result;
}

// GlobalsAAResult::FunctionInfo
G_MAY_READ_ANY_GLOBAL :: 4;
Gaa_Function_Info :: struct {
    info: u8;                         // ModRefInfo | MayReadAnyGlobal
    globals: [..] Gaa_Global_Mr;      // per-global ModRefInfo (map; order irrelevant)
}
Gaa_Global_Mr :: struct { gv: Value_Id; mr: u8; }

Globals_AA :: struct {
    non_address_taken: Table(Value_Id, bool);
    unknown_functions_with_local_linkage: bool;
    indirect_globals: Table(Value_Id, bool);
    allocs_for_indirect_globals: Table(Value_Id, Value_Id);
    function_infos: Table(Value_Id, Gaa_Function_Info);
}
globals_aa: *Globals_AA;   // the cached module analysis result (null = not computed)

gfi_add_mr_for_global :: (fi: *Gaa_Function_Info, gv: Value_Id, mr: u8) {
    for * fi.globals if it.gv == gv { it.mr |= mr; return; }
    array_add(*fi.globals, .{gv, mr});
}
gfi_mr_for_global :: (fi: *Gaa_Function_Info, gv: Value_Id) -> u8 {
    r := ifx (fi.info & G_MAY_READ_ANY_GLOBAL) != 0 then MR_REF else MR_NO;
    for fi.globals if it.gv == gv { r |= it.mr; break; }
    return r;
}
gfi_add_function_info :: (fi: *Gaa_Function_Info, other: *Gaa_Function_Info) {
    fi.info |= other.info & MR_MODREF;
    if other.info & G_MAY_READ_ANY_GLOBAL fi.info |= G_MAY_READ_ANY_GLOBAL;
    for other.globals gfi_add_mr_for_global(fi, it.gv, it.mr);
}
gaa_function_info :: (g: *Globals_AA, f: Value_Id) -> *Gaa_Function_Info { return table_find_pointer(*g.function_infos, f); }
gaa_function_info_or_create :: (g: *Globals_AA, f: Value_Id) -> *Gaa_Function_Info {
    p := table_find_pointer(*g.function_infos, f);
    if p return p;
    blank: Gaa_Function_Info;
    table_set(*g.function_infos, f, blank);
    return table_find_pointer(*g.function_infos, f);
}
gaa_erase_function_info :: (g: *Globals_AA, f: Value_Id) {
    p := table_find_pointer(*g.function_infos, f);
    if p { array_free(p.globals); table_remove(*g.function_infos, f); }
}

// Constant::isConstantUsed
is_constant_used :: (c: Value_Id) -> bool {
    u := ir.v_first_use[c];
    while u != NONE {
        usr := ir.u_user[u];
        if !is_const(usr) || is_global(usr) return true;
        if is_constant_used(usr) return true;
        u = ir.u_next[u];
    }
    return false;
}
add_fn :: (set: *[..] Value_Id, f: Value_Id) { for set.* if it == f return; array_add(set, f); }

// AnalyzeUsesOfPointer: true if the pointer escapes
gaa_analyze_uses_of_pointer :: (v: Value_Id, readers: *[..] Value_Id, writers: *[..] Value_Id, okay_store_dest: Value_Id = NONE) -> bool {
    if !is_ptr_type(vtype(v)) return true;
    u := ir.v_first_use[v];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        o := opr_code(usr);
        if is_inst(usr) && o == .LOAD {
            if readers add_fn(readers, inst_fn(usr));
        } else if is_inst(usr) && o == .STORE {
            if opno_of(u) == 1 { if writers add_fn(writers, inst_fn(usr)); }
            else if op(usr, 1) != okay_store_dest return true;
        } else if o == .GEP {
            if gaa_analyze_uses_of_pointer(usr, readers, writers) return true;
        } else if o == .BITCAST || o == .ADDRSPACECAST {
            if gaa_analyze_uses_of_pointer(usr, readers, writers, okay_store_dest) return true;
        } else if is_inst(usr) && is_call_base(usr) {
            if call_iid(usr) == IID_THREADLOCAL_ADDRESS && v == call_arg(usr, 0) {
                if gaa_analyze_uses_of_pointer(usr, readers, writers) return true;
                continue;
            }
            k := opno_of(u);
            if k < nops(usr) - call_non_data_operands(usr) {   // isDataOperand
                if k < call_num_args(usr) && get_freed_operand(usr) == v && call_arg(usr, k) == v {
                    if writers add_fn(writers, inst_fn(usr));
                } else {
                    f := call_called_function(usr);
                    if f == NONE || !is_declaration(f) return true;
                    if !call_has_fn_attr(usr, .NoCallback) || k >= call_num_args(usr) || !call_does_not_capture(usr, k) return true;
                    if readers add_fn(readers, inst_fn(usr));
                    if writers add_fn(writers, inst_fn(usr));
                }
            }
        } else if is_inst(usr) && o == .ICMP {
            if vkind(op(usr, 1)) != .C_NULL return true;
        } else if is_const(usr) {
            if is_global(usr) || is_constant_used(usr) return true;
        } else return true;
    }
    return false;
}
// CallBase::doesNotCapture(OpNo): capturesNothing(getCaptureInfo(OpNo))
call_does_not_capture :: (c: Value_Id, k: u32) -> bool {
    oth, ret := call_capture_info(c, k);
    return (oth | ret) == CC_NONE;
}

// AnalyzeIndirectGlobalMemory
gaa_analyze_indirect_global_memory :: (g: *Globals_AA, gv: Value_Id) -> bool {
    alloc_related: [..] Value_Id; alloc_related.allocator = temp;
    if glob(gv).has_init && vkind(op(gv, 0)) != .C_NULL return false;
    u := ir.v_first_use[gv];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if is_inst(usr) && inst_op(usr) == .LOAD {
            if gaa_analyze_uses_of_pointer(usr, null, null) return false;
        } else if is_inst(usr) && inst_op(usr) == .STORE {
            if op(usr, 0) == gv return false;
            if vkind(op(usr, 0)) == .C_NULL continue;
            p := get_underlying_object(op(usr, 0));
            if !aa_is_no_alias_call(p) return false;
            if gaa_analyze_uses_of_pointer(p, null, null, gv) return false;
            array_add(*alloc_related, p);
        } else return false;
    }
    while alloc_related.count table_set(*g.allocs_for_indirect_globals, pop(*alloc_related), gv);
    table_set(*g.indirect_globals, gv, true);
    return true;
}

// AnalyzeGlobals
gaa_analyze_globals :: (g: *Globals_AA) {
    tracked: [..] Value_Id; tracked.allocator = temp;   // (only membership; LLVM keeps handles)
    for f: ir.m_functions {
        if !is_local_linkage(glob(f).linkage) continue;
        if !gaa_analyze_uses_of_pointer(f, null, null) {
            table_set(*g.non_address_taken, f, true);
            add_fn(*tracked, f);
        } else g.unknown_functions_with_local_linkage = true;
    }
    readers: [..] Value_Id; readers.allocator = temp;
    writers: [..] Value_Id; writers.allocator = temp;
    for gv: ir.m_globals {
        if !is_local_linkage(glob(gv).linkage) continue;
        readers.count = 0; writers.count = 0;
        is_c := glob(gv).is_const;
        if !gaa_analyze_uses_of_pointer(gv, *readers, ifx is_c then null else *writers) {
            table_set(*g.non_address_taken, gv, true);
            for r: readers gfi_add_mr_for_global(gaa_function_info_or_create(g, r), gv, MR_REF);
            if !is_c for w: writers gfi_add_mr_for_global(gaa_function_info_or_create(g, w), gv, MR_MOD);
            if is_ptr_type(glob(gv).value_type) gaa_analyze_indirect_global_memory(g, gv);
        }
    }
}

// GlobalValue::isDefinitionExact (!mayBeDerefined)
gv_is_definition_exact :: (f: Value_Id) -> bool {
    l := glob(f).linkage;
    if l == .WEAK_ODR || l == .LINKONCE_ODR || l == .AVAILABLE_EXTERNALLY return false;
    nobuiltin_def := vkind(f) == .FUNCTION && !is_declaration(f) && fn_has_fn_attr(f, .NoBuiltin);   // isNobuiltinFnDef
    return !(gv_is_interposable(f) || nobuiltin_def);
}
fn_memory :: (f: Value_Id) -> u64 { return attr_set_memory(attr_list_fn(glob(f).attrs)); }

// AnalyzeCallGraph
gaa_analyze_call_graph :: (g: *Globals_AA, cg: *Call_Graph) {
    sccs := cg_sccs(cg);
    for scc: sccs {
        f := cg.nodes[scc[0]].f;
        if f == NONE || !gv_is_definition_exact(f) {
            for scc gaa_erase_function_info(g, cg.nodes[it].f);
            continue;
        }
        fi := gaa_function_info_or_create(g, f);
        know_nothing := false;
        may_sync_or_call_into_module :: (f: Value_Id) -> bool {
            return !is_declaration(f) || !fn_has_fn_attr(f, .NoSync) || !fn_has_fn_attr(f, .NoCallback);
        }
        for i: 0..scc.count-1 {
            if know_nothing break;
            if is_declaration(f) || fn_has_fn_attr(f, .OptimizeNone) {
                me := fn_memory(f);
                if me == 0 {
                } else if mem_only_reads(me) {
                    fi.info |= MR_REF;
                    if !me_only_accesses_arg_pointees(me) && may_sync_or_call_into_module(f) fi.info |= G_MAY_READ_ANY_GLOBAL;
                } else {
                    fi.info |= MR_MODREF;
                    if !me_only_accesses_arg_pointees(me) fi.info |= G_MAY_READ_ANY_GLOBAL;
                    if may_sync_or_call_into_module(f) { know_nothing = true; break; }
                }
                continue;
            }
            for cn: cg.nodes[scc[i]].callees {
                if know_nothing break;
                callee := cg.nodes[cn].f;
                if callee != NONE {
                    cfi := gaa_function_info(g, callee);
                    if cfi {
                        tmp := cfi.*;   // the callee may be f itself
                        fi = gaa_function_info_or_create(g, f);
                        gfi_add_function_info(fi, *tmp);
                    } else {
                        _, node := table_find(*cg.of_fn, callee);
                        in_scc := false;
                        for scc if it == node { in_scc = true; break; }
                        if !in_scc know_nothing = true;
                    }
                } else know_nothing = true;
            }
        }
        if know_nothing {
            for scc gaa_erase_function_info(g, cg.nodes[it].f);
            continue;
        }
        fi = gaa_function_info_or_create(g, f);
        for n: scc {
            if (fi.info & MR_MODREF) == MR_MODREF break;
            nf := cg.nodes[n].f;
            if fn_has_fn_attr(nf, .OptimizeNone) continue;
            for i: fn_insts(nf) {
                if (fi.info & MR_MODREF) == MR_MODREF break;
                if is_call_base(i) continue;
                if may_read_from_memory(i) fi.info |= MR_REF;
                if may_write_to_memory(i) fi.info |= MR_MOD;
            }
        }
        cached := fi.*;
        for k: 1..scc.count-1 {
            dst := gaa_function_info_or_create(g, cg.nodes[scc[k]].f);
            dst.info = cached.info;
            dst.globals.count = 0;
            for cached.globals array_add(*dst.globals, it);
        }
    }
}

// GlobalsAA::run / GlobalsAAResult::analyzeModule
globals_aa_compute :: () -> *Globals_AA {
    g := New(Globals_AA);
    cg := cg_build();
    gaa_analyze_globals(g);
    gaa_analyze_call_graph(g, *cg);
    // GlobalsAAResult's move constructor doesn't move UnknownFunctionsWithLocalLinkage, and the new pass manager
    // stores the result by moving it (AnalysisResultModel), so in opt the flag is always false.
    g.unknown_functions_with_local_linkage = false;
    return g;
}

// isNonEscapingGlobalNoAliasWithLoad
gaa_non_escaping_with_load :: (gv: Value_Id, v: Value_Id, depth: *s32) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    inputs: [..] Value_Id; inputs.allocator = temp;
    array_add(*visited, v); array_add(*inputs, v);
    ins :: (visited: *[..] Value_Id, x: Value_Id) -> bool { for visited.* if it == x return false; array_add(visited, x); return true; }
    while inputs.count {
        input := pop(*inputs);
        if is_global(input) || vkind(input) == .ARGUMENT || (is_inst(input) && (inst_op(input) == .CALL || inst_op(input) == .INVOKE)) continue;
        depth.* += 1;
        if depth.* > 4 return false;
        if is_inst(input) && inst_op(input) == .LOAD { array_add(*inputs, get_underlying_object(op(input, 0))); continue; }
        if is_inst(input) && inst_op(input) == .SELECT {
            l := get_underlying_object(op(input, 1)); r := get_underlying_object(op(input, 2));
            if ins(*visited, l) array_add(*inputs, l);
            if ins(*visited, r) array_add(*inputs, r);
            continue;
        }
        if is_phi(input) {
            for k: 0..nops(input)-1 { o := get_underlying_object(phi_value(input, k)); if ins(*visited, o) array_add(*inputs, o); }
            continue;
        }
        return false;
    }
    return true;
}

// isNonEscapingGlobalNoAlias
gaa_non_escaping_global_no_alias :: (gv: Value_Id, v: Value_Id, ctx: Value_Id) -> bool {
    if !is_ptr_type(vtype(v)) return true;
    visited: [..] Value_Id; visited.allocator = temp;
    inputs: [..] Value_Id; inputs.allocator = temp;
    array_add(*visited, v); array_add(*inputs, v);
    ins :: (visited: *[..] Value_Id, x: Value_Id) -> bool { for visited.* if it == x return false; array_add(visited, x); return true; }
    depth: s32 = 0;
    while inputs.count {
        input := pop(*inputs);
        if is_global(input) {
            if input == gv return false;
            if vkind(gv) == .GLOBAL_VAR && vkind(input) == .GLOBAL_VAR && !is_declaration(gv) && !is_declaration(input) &&
               !gv_is_interposable(gv) && !gv_is_interposable(input) {
                t1 := vtype(op(gv, 0)); t2 := vtype(op(input, 0));
                if type_is_sized(t1) && type_is_sized(t2) && dl_type_alloc_size(t1) > 0 && dl_type_alloc_size(t2) > 0 continue;
            }
            return false;
        }
        if vkind(input) == .ARGUMENT || (is_inst(input) && (inst_op(input) == .CALL || inst_op(input) == .INVOKE)) continue;
        if ctx != NONE && vkind(input) == .C_NULL && !null_pointer_is_defined(inst_fn(ctx), ir.types[vtype(input)].a) continue;
        depth += 1;
        if depth > 4 return false;
        if is_inst(input) && inst_op(input) == .LOAD {
            p := get_underlying_object(op(input, 0));
            if gaa_non_escaping_with_load(gv, p, *depth) continue;
            return false;
        }
        if is_inst(input) && inst_op(input) == .SELECT {
            l := get_underlying_object(op(input, 1)); r := get_underlying_object(op(input, 2));
            if ins(*visited, l) array_add(*inputs, l);
            if ins(*visited, r) array_add(*inputs, r);
            continue;
        }
        if is_phi(input) {
            for k: 0..nops(input)-1 { o := get_underlying_object(phi_value(input, k)); if ins(*visited, o) array_add(*inputs, o); }
            continue;
        }
        return false;
    }
    return true;
}

// GlobalsAAResult::alias
globals_aa_alias :: (q: *Aa_Query, a: Mem_Loc, b: Mem_Loc, ctx: Value_Id) -> Alias_Result {
    g := globals_aa;
    uv1 := get_underlying_object(strip_pointer_casts_for_alias_analysis(a.ptr));
    uv2 := get_underlying_object(strip_pointer_casts_for_alias_analysis(b.ptr));
    gv1: Value_Id = ifx is_global(uv1) then uv1 else NONE;
    gv2: Value_Id = ifx is_global(uv2) then uv2 else NONE;
    if gv1 != NONE || gv2 != NONE {
        if gv1 != NONE && !table_contains(*g.non_address_taken, gv1) gv1 = NONE;
        if gv2 != NONE && !table_contains(*g.non_address_taken, gv2) gv2 = NONE;
        if gv1 != NONE && gv2 != NONE && gv1 != gv2 return ar(AR_NO);
        if (gv1 != NONE || gv2 != NONE) && gv1 != gv2 {
            gv := ifx gv1 != NONE then gv1 else gv2;
            uv := ifx gv1 != NONE then uv2 else uv1;
            if gaa_non_escaping_global_no_alias(gv, uv, ctx) return ar(AR_NO);
        }
    }
    gv1 = NONE; gv2 = NONE;
    if is_inst(uv1) && inst_op(uv1) == .LOAD && vkind(op(uv1, 0)) == .GLOBAL_VAR && table_contains(*g.indirect_globals, op(uv1, 0)) gv1 = op(uv1, 0);
    if is_inst(uv2) && inst_op(uv2) == .LOAD && vkind(op(uv2, 0)) == .GLOBAL_VAR && table_contains(*g.indirect_globals, op(uv2, 0)) gv2 = op(uv2, 0);
    if gv1 == NONE { found, x := table_find(*g.allocs_for_indirect_globals, uv1); if found gv1 = x; }
    if gv2 == NONE { found, x := table_find(*g.allocs_for_indirect_globals, uv2); if found gv2 = x; }
    if gv1 != NONE && gv2 != NONE && gv1 != gv2 return ar(AR_NO);
    return ar(AR_MAY);
}

// getModRefInfoForArgument
gaa_mod_ref_for_argument :: (q: *Aa_Query, call: Value_Id, gv: Value_Id) -> u8 {
    me := call_memory_effects(call);
    if me == 0 return MR_NO;
    conservative := ifx mem_only_reads(me) then MR_REF else MR_MODREF;
    n := call_num_args(call);
    objects: [..] Value_Id; objects.allocator = temp;
    if n > 0 for k: 0..n-1 {
        objects.count = 0;
        get_underlying_objects(call_arg(call, k), *objects);
        all_identified := true;
        for objects if !is_identified_object(it) { all_identified = false; break; }
        if !all_identified {
            all_no := true;
            for objects if globals_aa_alias(q, mloc_before_or_after(it), mloc_before_or_after(gv), call).kind != AR_NO { all_no = false; break; }
            if !all_no return conservative;
        }
        for objects if it == gv return conservative;
    }
    return MR_NO;
}

// GlobalsAAResult::getModRefInfo(Call, Loc)
globals_aa_mod_ref_call_loc :: (q: *Aa_Query, call: Value_Id, loc: Mem_Loc) -> u8 {
    g := globals_aa;
    known := MR_MODREF;
    gv := get_underlying_object(loc.ptr);
    if is_global(gv) && is_local_linkage(glob(gv).linkage) && !g.unknown_functions_with_local_linkage {
        f := call_called_function(call);
        if f != NONE && table_contains(*g.non_address_taken, gv) {
            fi := gaa_function_info(g, f);
            if fi known = gfi_mr_for_global(fi, gv) | gaa_mod_ref_for_argument(q, call, gv);
        }
    }
    return known;
}

// GlobalsAAResult::getMemoryEffects(F)
globals_aa_memory_effects_fn :: (f: Value_Id) -> u64 {
    fi := gaa_function_info(globals_aa, f);
    if fi return mem_all(fi.info & MR_MODREF);
    return MEM_UNKNOWN;
}
