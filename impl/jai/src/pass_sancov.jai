// SanitizerCoverage: a port of llvm/lib/Transforms/Instrumentation/SanitizerCoverage.cpp (SanitizerCoveragePass
// "sancov-module": every cl::opt, trace-pc / trace-pc-guard / inline 8-bit counters / bool flags / pc tables /
// control-flow tables / stack depth / cmp, switch, div, gep, load and store tracing, gated callbacks), with
// PrepareToSplitEntryBlock (llvm/lib/Transforms/Utils/Instrumentation.cpp). No allow/block lists: the pass has no
// cl::opt for them (only the constructor arguments clang passes).

sancov_cl: struct {
    level: s64;
    trace_pc, trace_pc_entry_exit, trace_pc_guard, pc_table, inline_8bit_counters, drop_ctors, inline_bool_flag: bool;
    cmp_tracing, div_tracing, load_tracing, store_tracing, gep_tracing: bool;
    prune_blocks := true;
    stack_depth: bool;
    stack_depth_callback_min: s64;
    collect_cf: bool;
    gated_callbacks: bool;
};

sancov_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    pi :: (name: string, value: string) -> s64 {
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("opt: for the --% option: '%' value invalid for integer argument!", name, value);
        return v;
    }
    o := *sancov_cl;
    if name == {
        case "sanitizer-coverage-level"; o.level = pi(name, value);
        case "sanitizer-coverage-trace-pc"; o.trace_pc = pb(name, value, has_value);
        case "sanitizer-coverage-trace-pc-entry-exit"; o.trace_pc_entry_exit = pb(name, value, has_value);
        case "sanitizer-coverage-trace-pc-guard"; o.trace_pc_guard = pb(name, value, has_value);
        case "sanitizer-coverage-pc-table"; o.pc_table = pb(name, value, has_value);
        case "sanitizer-coverage-inline-8bit-counters"; o.inline_8bit_counters = pb(name, value, has_value);
        case "sanitizer-coverage-drop-ctors"; o.drop_ctors = pb(name, value, has_value);
        case "sanitizer-coverage-inline-bool-flag"; o.inline_bool_flag = pb(name, value, has_value);
        case "sanitizer-coverage-trace-compares"; o.cmp_tracing = pb(name, value, has_value);
        case "sanitizer-coverage-trace-divs"; o.div_tracing = pb(name, value, has_value);
        case "sanitizer-coverage-trace-loads"; o.load_tracing = pb(name, value, has_value);
        case "sanitizer-coverage-trace-stores"; o.store_tracing = pb(name, value, has_value);
        case "sanitizer-coverage-trace-geps"; o.gep_tracing = pb(name, value, has_value);
        case "sanitizer-coverage-prune-blocks"; o.prune_blocks = pb(name, value, has_value);
        case "sanitizer-coverage-stack-depth"; o.stack_depth = pb(name, value, has_value);
        case "sanitizer-coverage-stack-depth-callback-min"; o.stack_depth_callback_min = pi(name, value);
        case "sanitizer-coverage-control-flow"; o.collect_cf = pb(name, value, has_value);
        case "sanitizer-coverage-gated-trace-callbacks"; o.gated_callbacks = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

// SanitizerCoverageOptions (CoverageType: 0 none, 1 function, 2 bb, 3 edge)
Sancov_Options :: struct {
    coverage_type: s64;
    indirect_calls, trace_cmp, trace_div, trace_gep, trace_pc, trace_pc_entry_exit, trace_pc_guard: bool;
    inline_8bit_counters, inline_bool_flag, pc_table, no_prune, stack_depth, trace_loads, trace_stores: bool;
    collect_control_flow, gated_callbacks: bool;
    stack_depth_callback_min: s64;
}

// getOptions + OverrideFromCL, on the default-constructed options of SanitizerCoveragePass()
sancov_options :: () -> Sancov_Options {
    o: Sancov_Options;
    c := *sancov_cl;
    lt := 0; li := false;
    if c.level == 1 lt = 1;
    else if c.level == 2 lt = 2;
    else if c.level == 3 lt = 3;
    else if c.level == 4 { lt = 3; li = true; }
    o.coverage_type = max(o.coverage_type, lt);
    o.indirect_calls |= li;
    o.trace_cmp |= c.cmp_tracing;
    o.trace_div |= c.div_tracing;
    o.trace_gep |= c.gep_tracing;
    o.trace_pc |= c.trace_pc;
    o.trace_pc_entry_exit |= c.trace_pc_entry_exit;
    o.trace_pc_guard |= c.trace_pc_guard;
    o.inline_8bit_counters |= c.inline_8bit_counters;
    o.inline_bool_flag |= c.inline_bool_flag;
    o.pc_table |= c.pc_table;
    o.no_prune |= !c.prune_blocks;
    o.stack_depth |= c.stack_depth;
    o.stack_depth_callback_min = max(o.stack_depth_callback_min, cast(s64) cast,trunc(s32) c.stack_depth_callback_min);
    o.trace_loads |= c.load_tracing;
    o.trace_stores |= c.store_tracing;
    o.gated_callbacks |= c.gated_callbacks;
    if !o.trace_pc_guard && !o.trace_pc && !o.trace_pc_entry_exit && !o.inline_8bit_counters && !o.stack_depth &&
       !o.inline_bool_flag && !o.trace_loads && !o.trace_stores
        o.trace_pc_guard = true;   // TracePCGuard is default.
    o.collect_control_flow |= c.collect_cf;
    return o;
}

Sancov :: struct {
    o: Sancov_Options;
    intptr: Type_Id;
    trace_pc_indir, trace_pc, trace_pc_guard, trace_pc_entry, trace_pc_exit, stack_depth_callback: San_Callee;
    trace_cmp, trace_const_cmp: [4] San_Callee;
    load_fns, store_fns: [5] San_Callee;
    trace_div: [2] San_Callee;
    trace_gep, trace_switch: San_Callee;
    lowest_stack: Value_Id;
    callback_gate: Value_Id;
    guard_array, counter_array, bool_array, pcs_array, cfs_array: Value_Id;
    to_used, to_compiler_used: [..] Value_Id;
}

// getSectionName / getSectionStart / getSectionEnd
sancov_section_name :: (sec: string) -> string {
    if san_triple_is_coff() {
        if sec == "sancov_cntrs" return ".SCOV$CM";
        if sec == "sancov_bools" return ".SCOV$BM";
        if sec == "sancov_pcs" return ".SCOVP$M";
        return ".SCOV$GM";
    }
    if san_triple_is_macho() return tconcat("__DATA,__", sec);
    return tconcat("__", sec);
}
sancov_section_start :: (sec: string) -> string {
    if san_triple_is_macho() return tconcat("\x01section$start$__DATA$__", sec);
    return tconcat("__start___", sec);
}
sancov_section_end :: (sec: string) -> string {
    if san_triple_is_macho() return tconcat("\x01section$end$__DATA$__", sec);
    return tconcat("__stop___", sec);
}

// CreateSecStartEnd
sancov_sec_start_end :: (s: *Sancov, sec: string, ty: Type_Id) -> (Value_Id, Value_Id) {
    coff := san_triple_is_coff();
    lk := ifx coff then Linkage.EXTERNAL else .EXTERN_WEAK;
    st := gv_create(ty, false, lk, NONE, sancov_section_start(sec), NONE, 0, dl.globals_as);
    glob(st).visibility = 1;
    en := gv_create(ty, false, lk, NONE, sancov_section_end(sec), NONE, 0, dl.globals_as);
    glob(en).visibility = 1;
    if !coff return st, en;
    return ce_gep(ir.t_i8, st, .[const_int(s.intptr, 8)], 0), en;
}

// CreateInitCallsForSections
sancov_create_init_calls :: (s: *Sancov, ctor_name: string, init_name: string, ty: Type_Id, sec: string) -> Value_Id {
    if sancov_cl.drop_ctors return NONE;
    st, en := sancov_sec_start_end(s, sec, ty);
    p := type_ptr(0);
    ctor := create_sanitizer_ctor_and_init_functions(ctor_name, init_name, .[p, p], .[st, en], "");
    if triple_supports_comdat() {
        glob(ctor).comdat = get_comdat(ctor_name);
        append_to_global_ctors(ctor, 2, ctor);
    } else append_to_global_ctors(ctor, 2);
    if san_triple_is_coff() gv_set_linkage(ctor, .WEAK_ODR);
    return ctor;
}

// PrepareToSplitEntryBlock(BB, IP): static allocas and llvm.localescape stay ahead of the insertion point.
// The point is (instruction, head bit); moveBeforeInsertPoint either advances it (losing the head bit) or moves the
// instruction before it.
prepare_to_split_entry_block :: (bb: Value_Id, ip_in: Value_Id, head_in: bool) -> (Value_Id, bool) {
    ip := ip_in; head := head_in;
    i := ip_in;
    while i != NONE {
        nx := inst(i).next;
        keep := false;
        if inst_op(i) == .ALLOCA keep = is_static_alloca(i);
        else if inst_op(i) == .CALL && call_iid(i) == IID_LOCALESCAPE keep = true;
        if keep {
            if i == ip { ip = inst(ip).next; head = false; }
            else inst_move_before_at(i, ip, head);
        }
        i = nx;
    }
    return ip, head;
}
// Instruction::moveBefore(BasicBlock::iterator): with the head bit the instruction goes ahead of the position's
// debug records, without it it takes them over (inst_move_before_dbg)
inst_move_before_at :: (i: Value_Id, pos: Value_Id, head: bool) {
    if !head { inst_move_before_dbg(i, pos); return; }
    if inst(i).records && inst_next(i) != pos {
        nx := inst_next(i);
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
    inst_insert_before(i, pos);
}

// isa<IntrinsicInst>: a call of a function whose name starts with "llvm."
sancov_is_intrinsic_inst :: (i: Value_Id) -> bool {
    cf := call_called_function(i);
    return cf != NONE && glob(cf).intrinsic;
}

// CallBase::isIndirectCall
sancov_is_indirect_call :: (cb: Value_Id) -> bool {
    c := call_callee(cb);
    if is_constant_kind(vkind(c)) return false;
    return vkind(c) != .INLINE_ASM;
}

// isFullDominator / isFullPostDominator / shouldInstrumentBlock
sancov_should_instrument_block :: (s: *Sancov, f: Value_Id, bb: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) -> bool {
    fi := block_first_non_phi_or_dbg_or_lifetime(bb);
    if fi != NONE && inst_op(fi) == .UNREACHABLE return false;
    if block_first_insertion_pt(bb) == NONE return false;
    if s.o.no_prune || fn_entry(f) == bb return true;
    if s.o.coverage_type == 1 && fn_entry(f) != bb return false;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    full_dom := succs.count > 0;
    for succs if !dt_dominates(dt, bb, it) { full_dom = false; break; }
    if full_dom return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    full_pdom := preds.count > 0;
    for preds if !dt_dominates(pdt, bb, it) { full_pdom = false; break; }
    return !(full_pdom && block_single_predecessor(bb) == NONE);
}

// IsBackEdge / IsInterestingCmp
sancov_is_back_edge :: (from: Value_Id, to: Value_Id, dt: *Dom_Tree) -> bool {
    if dt_dominates(dt, to, from) return true;
    nx := block_unique_successor(to);
    if nx != NONE && dt_dominates(dt, nx, from) return true;
    return false;
}
sancov_is_interesting_cmp :: (s: *Sancov, cmp: Value_Id, dt: *Dom_Tree) -> bool {
    if !s.o.no_prune && has_one_use(cmp) {
        br := ir.u_user[ir.v_first_use[cmp]];
        if is_inst(br) && inst_op(br) == .CONDBR {
            for k: 0..num_successors(br) - 1 if sancov_is_back_edge(inst(br).parent, get_successor(br, k), dt) return false;
        }
    }
    return true;
}

// CreateFunctionLocalArrayInSection
sancov_local_array :: (s: *Sancov, n: u64, f: Value_Id, ty: Type_Id, sec: string) -> Value_Id {
    at := type_array(n, ty);
    a := gv_create(at, false, .PRIVATE, const_null_value(at), "__sancov_gen_", NONE, 0, dl.globals_as);
    if triple_supports_comdat() && (glob(f).comdat >= 0 || san_triple_is_elf() || !gv_is_interposable(f)) {
        c := get_or_create_function_comdat(f);
        if c >= 0 glob(a).comdat = c;
    }
    glob(a).section = sancov_section_name(sec);
    // Align(StoreSize): a release build keeps 1 << Log2(n) for a size that is not a power of two (40-bit pointers)
    sz := dl_type_store_size(ty);
    al: u64 = 1;
    while al * 2 <= sz al *= 2;
    glob(a).align = al;
    if glob(a).comdat >= 0 array_add(*s.to_compiler_used, a);
    else array_add(*s.to_used, a);
    return a;
}

// CreatePCArray
sancov_create_pc_array :: (s: *Sancov, f: Value_Id, blocks: [] Value_Id) -> Value_Id {
    p := type_ptr(0);
    pcs: [..] Value_Id; pcs.allocator = temp;
    for bb: blocks {
        if fn_entry(f) == bb {
            array_add(*pcs, san_ce_pointer_cast(f, p));
            array_add(*pcs, ce_cast(.INTTOPTR, const_int(s.intptr, 1), p));
        } else {
            array_add(*pcs, san_ce_pointer_cast(const_blockaddr(f, bb), p));
            array_add(*pcs, const_null_value(p));
        }
    }
    n := cast(u64) blocks.count * 2;
    a := sancov_local_array(s, n, f, p, "sancov_pcs");
    gv_set_initializer(a, const_aggregate(.C_ARRAY, type_array(n, p), pcs));
    glob(a).is_const = true;
    return a;
}

// createFunctionControlFlow
sancov_create_function_control_flow :: (s: *Sancov, f: Value_Id) {
    p := type_ptr(0);
    cfs: [..] Value_Id; cfs.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: fn_blocks(f) {
        if bb == fn_entry(f) array_add(*cfs, san_ce_pointer_cast(f, p));
        else array_add(*cfs, san_ce_pointer_cast(const_blockaddr(f, bb), p));
        succs.count = 0;
        block_successors(bb, *succs);
        for succs array_add(*cfs, san_ce_pointer_cast(const_blockaddr(f, it), p));
        array_add(*cfs, const_null_value(p));
        for i: block_insts(bb) {
            if !is_call_base(i) continue;
            if sancov_is_indirect_call(i) array_add(*cfs, ce_cast(.INTTOPTR, cf_all_ones(s.intptr), p));
            else {
                cf := call_called_function(i);
                if cf != NONE && !glob(cf).intrinsic array_add(*cfs, san_ce_pointer_cast(cf, p));
            }
        }
        array_add(*cfs, const_null_value(p));
    }
    n := cast(u64) cfs.count;
    s.cfs_array = sancov_local_array(s, n, f, p, "sancov_cfs");
    gv_set_initializer(s.cfs_array, const_aggregate(.C_ARRAY, type_array(n, p), cfs));
    glob(s.cfs_array).is_const = true;
}

// Instruction::setNoSanitizeMetadata
set_no_sanitize_metadata :: (i: Value_Id) { set_metadata(i, md_kind_id("nosanitize"), md_tuple(.[], false)); }

// CreateFunctionLocalGateCmp / CreateGateBranch
sancov_gate_branch :: (s: *Sancov, f: Value_Id, gate_cmp: *Value_Id, at: Value_Id) -> Value_Id {
    if gate_cmp.* == NONE {
        bb := fn_entry(f);
        ip, head := prepare_to_split_entry_block(bb, block_first_insertion_pt(bb), true);
        b: Irb; irb_set_before(*b, ip);
        l := irb_load(*b, ir.t_i64, s.callback_gate, dl_abi_align(ir.t_i64));
        set_no_sanitize_metadata(l);
        gate_cmp.* = irb_icmp(*b, ICMP_NE, l, const_int(ir.t_i64, 0), "sancov gate cmp");
    }
    w := md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1)), md_value(const_int(ir.t_i32, 100000))], false);
    return sbi_if_then(gate_cmp.*, at, false, w);
}

// InjectCoverageAtBlock
sancov_inject_coverage_at_block :: (s: *Sancov, f: Value_Id, bb: Value_Id, idx: u64, gate_cmp: *Value_Id, is_leaf: bool) {
    ip := block_first_insertion_pt(bb);
    head := true;
    is_entry := bb == fn_entry(f);
    entry_loc: Md_Id = NONE;
    if is_entry {
        sp := fn_subprogram(f);
        if sp != NONE entry_loc = di_location_get(ir.md_ints[ir.mds[sp].ints + 1], 0, sp, NONE);
        ip, head = prepare_to_split_entry_block(bb, ip, head);
    }
    b: Irb; irb_instr_before(*b, ip);
    if entry_loc != NONE b.dbg = entry_loc;
    if s.o.trace_pc || (is_entry && s.o.trace_pc_entry_exit) {
        c := ifx is_entry && s.o.trace_pc_entry_exit then s.trace_pc_entry else s.trace_pc;
        call_add_fn_attr(san_call(*b, c, .[]), .NoMerge);
    }
    i64 := ir.t_i64;
    if s.o.trace_pc_guard {
        gp := irb_gep(*b, glob(s.guard_array).value_type, s.guard_array, .[const_int(i64, 0), const_int(i64, idx)], "", F_INBOUNDS);
        if s.o.gated_callbacks {
            gb := sancov_gate_branch(s, f, gate_cmp, ip);
            g: Irb; irb_set_before(*g, gb);
            call_add_fn_attr(san_call(*g, s.trace_pc_guard, .[gp]), .NoMerge);
        } else call_add_fn_attr(san_call(*b, s.trace_pc_guard, .[gp]), .NoMerge);
    }
    if s.o.inline_8bit_counters {
        cp := irb_gep(*b, glob(s.counter_array).value_type, s.counter_array, .[const_int(s.intptr, 0), const_int(s.intptr, idx)]);
        l := irb_load(*b, ir.t_i8, cp, dl_abi_align(ir.t_i8));
        inc := irb_binop(*b, .ADD, l, const_int(ir.t_i8, 1));
        st := irb_store(*b, inc, cp, dl_abi_align(ir.t_i8));
        set_no_sanitize_metadata(l);
        set_no_sanitize_metadata(st);
    }
    if s.o.inline_bool_flag {
        fp := irb_gep(*b, glob(s.bool_array).value_type, s.bool_array, .[const_int(s.intptr, 0), const_int(s.intptr, idx)]);
        l := irb_load(*b, ir.t_i1, fp, dl_abi_align(ir.t_i1));
        t := sbi_if_then(irb_icmp(*b, ICMP_EQ, l, const_int(ir.t_i1, 0)), ip, false, create_unlikely_branch_weights());
        tb: Irb; irb_instr_before(*tb, t);
        st := irb_store(*tb, const_int(ir.t_i1, 1), fp, dl_abi_align(ir.t_i1));
        if entry_loc != NONE set_metadata(st, 0, entry_loc);
        set_no_sanitize_metadata(l);
        set_no_sanitize_metadata(st);
    }
    if s.o.stack_depth && is_entry && !is_leaf {
        if s.o.stack_depth_callback_min {
            est: s32 = 0;
            dynamic := false;
            insert_before: Value_Id = NONE;
            for i: block_insts(bb) {
                if inst_op(i) != .ALLOCA continue;
                insert_before = inst(i).next;
                ok, sz := alloca_allocation_size(i);
                if !ok || (sz != 0 && type_is_scalable(inst(i).ty2)) dynamic = true;
                else est = cast,trunc(s32)(cast(u64) est + sz);
            }
            if dynamic || est >= s.o.stack_depth_callback_min {
                if insert_before != NONE irb_set_before(*b, insert_before);
                c := san_call(*b, s.stack_depth_callback, .[]);
                if entry_loc != NONE set_metadata(c, 0, entry_loc);
                call_add_fn_attr(c, .NoMerge);
            }
        } else {
            fa := irb_intrinsic(*b, "llvm.frameaddress", .[type_ptr(dl.alloca_as)], .[const_int(ir.t_i32, 0)]);
            fai := irb_cast(*b, .PTRTOINT, fa, s.intptr);
            low := irb_load(*b, s.intptr, s.lowest_stack, dl_abi_align(s.intptr));
            lower := irb_icmp(*b, ICMP_ULT, fai, low);
            t := sbi_if_then(lower, ip, false, create_unlikely_branch_weights());
            tb: Irb; irb_instr_before(*tb, t);
            st := irb_store(*tb, fai, s.lowest_stack, dl_abi_align(s.intptr));
            if entry_loc != NONE set_metadata(st, 0, entry_loc);
            set_no_sanitize_metadata(low);
            set_no_sanitize_metadata(st);
        }
    }
}

// instrumentFunction
sancov_instrument_function :: (s: *Sancov, f: Value_Id) {
    if is_declaration(f) return;
    n := vname(f);
    if contains(n, ".module_ctor") return;
    if begins_with(n, "__sanitizer_") return;
    if glob(f).linkage == .AVAILABLE_EXTERNALLY return;
    if n == "__local_stdio_printf_options" || n == "__local_stdio_scanf_options" return;
    if inst_op(block_terminator(fn_entry(f))) == .UNREACHABLE return;
    if glob(f).has_personality && is_asynchronous_eh_personality(classify_eh_personality(fn_personality(f))) return;
    if fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .NoSanitizeCoverage) || fn_has_fn_attr(f, .DisableSanitizerInstrumentation) return;
    if s.o.coverage_type >= 3 {
        ceo: Crit_Edge_Options;
        ceo.ignore_unreachable_dests = true;
        if split_all_critical_edges(f, *ceo) > 0 fam_invalidate(f, PRESERVE_NONE);
    }
    indir, blocks, cmps, switches, divs, geps, loads, stores: [..] Value_Id;
    indir.allocator = temp; blocks.allocator = temp; cmps.allocator = temp; switches.allocator = temp;
    divs.allocator = temp; geps.allocator = temp; loads.allocator = temp; stores.allocator = temp;
    dt := get_domtree(f);
    pdt := get_postdomtree(f);
    is_leaf := true;
    for bb: fn_blocks(f) {
        if sancov_should_instrument_block(s, f, bb, dt, pdt) array_add(*blocks, bb);
        for i: block_insts(bb) {
            o := inst_op(i);
            if s.o.indirect_calls && is_call_base(i) && sancov_is_indirect_call(i) array_add(*indir, i);
            if s.o.trace_cmp {
                if o == .ICMP && sancov_is_interesting_cmp(s, i, dt) array_add(*cmps, i);
                if o == .SWITCH array_add(*switches, i);
            }
            if s.o.trace_div && (o == .SDIV || o == .UDIV) array_add(*divs, i);
            if s.o.trace_gep && o == .GEP array_add(*geps, i);
            if s.o.trace_loads && o == .LOAD array_add(*loads, i);
            if s.o.trace_stores && o == .STORE array_add(*stores, i);
            if s.o.stack_depth && (o == .INVOKE || (o == .CALL && !sancov_is_intrinsic_inst(i))) is_leaf = false;
        }
    }
    if s.o.collect_control_flow sancov_create_function_control_flow(s, f);
    gate_cmp: Value_Id = NONE;
    // InjectCoverage
    if blocks.count {
        nb := cast(u64) blocks.count;
        if s.o.trace_pc_guard s.guard_array = sancov_local_array(s, nb, f, ir.t_i32, "sancov_guards");
        if s.o.inline_8bit_counters s.counter_array = sancov_local_array(s, nb, f, ir.t_i8, "sancov_cntrs");
        if s.o.inline_bool_flag s.bool_array = sancov_local_array(s, nb, f, ir.t_i1, "sancov_bools");
        if s.o.pc_table s.pcs_array = sancov_create_pc_array(s, f, blocks);
        for bb: blocks sancov_inject_coverage_at_block(s, f, bb, cast(u64) it_index, *gate_cmp, is_leaf);
    }
    // InjectCoverageForIndirectCalls
    for i: indir {
        b: Irb; irb_instr_before(*b, i);
        c := call_callee(i);
        if vkind(c) == .INLINE_ASM continue;
        san_call(*b, s.trace_pc_indir, .[irb_pointer_cast(*b, c, s.intptr)]);
    }
    // InjectTraceForCmp
    for i: cmps {
        b: Irb; irb_instr_before(*b, i);
        a0 := op(i, 0); a1 := op(i, 1);
        if type_kind(vtype(a0)) != .INT continue;
        ts := dl_type_store_size(vtype(a0)) * 8;
        ci := ifx ts == 8 then 0 else ifx ts == 16 then 1 else ifx ts == 32 then 2 else ifx ts == 64 then 3 else -1;
        if ci < 0 continue;
        cb := s.trace_cmp[ci];
        c0 := vkind(a0) == .C_INT; c1 := vkind(a1) == .C_INT;
        if c0 && c1 continue;
        if c0 || c1 {
            cb = s.trace_const_cmp[ci];
            if c1 { t := a0; a0 = a1; a1 = t; }
        }
        ty := type_int(ts);
        if s.o.gated_callbacks {
            gb := sancov_gate_branch(s, f, *gate_cmp, i);
            g: Irb; irb_set_before(*g, gb);
            x := irb_int_cast(*g, a0, ty, true);
            y := irb_int_cast(*g, a1, ty, true);
            san_call(*g, cb, .[x, y]);
        } else {
            x := irb_int_cast(*b, a0, ty, true);
            y := irb_int_cast(*b, a1, ty, true);
            san_call(*b, cb, .[x, y]);
        }
    }
    // InjectTraceForSwitch
    for i: switches {
        b: Irb; irb_instr_before(*b, i);
        cond := op(i, 0);
        bits := type_bits(vtype(cond));
        if bits > 64 continue;
        inits: [..] Value_Id; inits.allocator = temp;
        nc := cast(s64) switch_num_cases(i);
        array_add(*inits, const_int(ir.t_i64, cast(u64) nc));
        array_add(*inits, const_int(ir.t_i64, bits));
        if bits < 64 cond = irb_int_cast(*b, cond, ir.t_i64, false);
        vals: [..] u64; vals.allocator = temp;
        for k: 0..nc - 1 array_add(*vals, const_int_zext(switch_case_value(i, cast(u32) k)));
        quick_sort(vals, (a: u64, b: u64) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
        for vals array_add(*inits, const_int(ir.t_i64, it));
        at := type_array(cast(u64) inits.count, ir.t_i64);
        gv := gv_create(at, false, .INTERNAL, const_aggregate(.C_ARRAY, at, inits), "__sancov_gen_cov_switch_values", NONE, 0, dl.globals_as);
        if s.o.gated_callbacks {
            gb := sancov_gate_branch(s, f, *gate_cmp, i);
            g: Irb; irb_set_before(*g, gb);
            san_call(*g, s.trace_switch, .[cond, gv]);
        } else san_call(*b, s.trace_switch, .[cond, gv]);
    }
    // InjectTraceForDiv
    for i: divs {
        a1 := op(i, 1);
        if vkind(a1) == .C_INT || type_kind(vtype(a1)) != .INT continue;
        ts := dl_type_store_size(vtype(a1)) * 8;
        ci := ifx ts == 32 then 0 else ifx ts == 64 then 1 else -1;
        if ci < 0 continue;
        b: Irb; irb_instr_before(*b, i);
        san_call(*b, s.trace_div[ci], .[irb_int_cast(*b, a1, type_int(ts), true)]);
    }
    // InjectTraceForGep
    for i: geps {
        b: Irb; irb_instr_before(*b, i);
        for k: 1..cast(s64) nops(i) - 1 {
            x := op(i, cast(u32) k);
            if vkind(x) != .C_INT && type_kind(vtype(x)) == .INT san_call(*b, s.trace_gep, .[irb_int_cast(*b, x, s.intptr, true)]);
        }
    }
    // InjectTraceForLoadsAndStores
    idx_of :: (t: Type_Id) -> s64 {
        ts := dl_type_store_size(t) * 8;
        return ifx ts == 8 then 0 else ifx ts == 16 then 1 else ifx ts == 32 then 2 else ifx ts == 64 then 3 else ifx ts == 128 then 4 else -1;
    }
    for i: loads {
        b: Irb; irb_instr_before(*b, i);
        k := idx_of(vtype(i));
        if k < 0 continue;
        san_call(*b, s.load_fns[k], .[op(i, 0)]);
    }
    for i: stores {
        b: Irb; irb_instr_before(*b, i);
        k := idx_of(vtype(op(i, 0)));
        if k < 0 continue;
        san_call(*b, s.store_fns[k], .[op(i, 1)]);
    }
    // InjectTraceForExits
    if s.o.trace_pc_entry_exit {
        ee := escape_enumerator(f, "sancov_exit", true);
        while true {
            pt := escape_enumerator_next(*ee);
            if pt == NONE break;
            b: Irb; irb_set_before(*b, pt);
            san_ensure_debug_info(*b, f);
            c := san_call(*b, s.trace_pc_exit, .[]);
            call_set_tail_kind(c, TCK_NOTAIL);
        }
    }
}

// SanitizerCoveragePass::run / ModuleSanitizerCoverage::instrumentModule
sancov_run :: () -> Preserved {
    s: Sancov;
    s.o = sancov_options();
    if s.o.coverage_type == 0 return PRESERVE_ALL;
    s.to_used.allocator = temp; s.to_compiler_used.allocator = temp;
    s.guard_array = NONE; s.counter_array = NONE; s.bool_array = NONE; s.pcs_array = NONE; s.cfs_array = NONE;
    s.intptr = type_int(dl_ptr_spec(0).bits);
    p := type_ptr(0); v := ir.t_void;
    i8 := ir.t_i8; i16 := type_int(16); i32 := ir.t_i32; i64 := ir.t_i64;
    s.trace_pc_indir = san_callee("__sanitizer_cov_trace_pc_indir", v, .[s.intptr]);
    zs: Attr; zs.kind = .ZExt; zs.ty = NONE;
    zset := attr_set_with(0, zs);
    zext_al := attr_list_with_param(attr_list_with_param(0, 0, zset), 1, zset);
    s.trace_cmp[0] = san_callee("__sanitizer_cov_trace_cmp1", v, .[i8, i8], zext_al);
    s.trace_cmp[1] = san_callee("__sanitizer_cov_trace_cmp2", v, .[i16, i16], zext_al);
    s.trace_cmp[2] = san_callee("__sanitizer_cov_trace_cmp4", v, .[i32, i32], zext_al);
    s.trace_cmp[3] = san_callee("__sanitizer_cov_trace_cmp8", v, .[i64, i64]);
    s.trace_const_cmp[0] = san_callee("__sanitizer_cov_trace_const_cmp1", v, .[i8, i8], zext_al);
    s.trace_const_cmp[1] = san_callee("__sanitizer_cov_trace_const_cmp2", v, .[i16, i16], zext_al);
    s.trace_const_cmp[2] = san_callee("__sanitizer_cov_trace_const_cmp4", v, .[i32, i32], zext_al);
    s.trace_const_cmp[3] = san_callee("__sanitizer_cov_trace_const_cmp8", v, .[i64, i64]);
    for n, k: string.["1", "2", "4", "8", "16"] s.load_fns[k] = san_callee(tconcat("__sanitizer_cov_load", n), v, .[p]);
    for n, k: string.["1", "2", "4", "8", "16"] s.store_fns[k] = san_callee(tconcat("__sanitizer_cov_store", n), v, .[p]);
    s.trace_div[0] = san_callee("__sanitizer_cov_trace_div4", v, .[i32], attr_list_with_param(0, 0, zset));
    s.trace_div[1] = san_callee("__sanitizer_cov_trace_div8", v, .[i64]);
    s.trace_gep = san_callee("__sanitizer_cov_trace_gep", v, .[s.intptr]);
    s.trace_switch = san_callee("__sanitizer_cov_trace_switch", v, .[i64, p]);
    s.lowest_stack = module_get_or_insert_global("__sancov_lowest_stack", s.intptr);
    if glob(s.lowest_stack).value_type != s.intptr fatal("error: '__sancov_lowest_stack' should not be declared by the user");
    glob(s.lowest_stack).tls = 3;   // InitialExecTLSModel
    if s.o.stack_depth && !is_declaration(s.lowest_stack) gv_set_initializer(s.lowest_stack, cf_all_ones(s.intptr));
    if s.o.gated_callbacks {
        if !s.o.trace_pc_guard && !s.o.trace_cmp
            fatal("error: 'sanitizer-coverage-gated-trace-callbacks' is only supported with trace-pc-guard or trace-cmp");
        s.callback_gate = module_get_or_insert_global("__sancov_should_track", i64);
        glob(s.callback_gate).section = sancov_section_name("sancov_gate");
        gv_set_initializer(s.callback_gate, const_int(i64, 0));
        gv_set_linkage(s.callback_gate, .LINKONCE_ANY);
        glob(s.callback_gate).visibility = 1;
        append_to_compiler_used(s.callback_gate);
    }
    s.trace_pc = san_callee("__sanitizer_cov_trace_pc", v, .[]);
    s.trace_pc_entry = san_callee("__sanitizer_cov_trace_pc_entry", v, .[]);
    s.trace_pc_exit = san_callee("__sanitizer_cov_trace_pc_exit", v, .[]);
    s.trace_pc_guard = san_callee("__sanitizer_cov_trace_pc_guard", v, .[p]);
    s.stack_depth_callback = san_callee("__sanitizer_cov_stack_depth", v, .[]);
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns sancov_instrument_function(*s, f);
    ctor: Value_Id = NONE;
    if s.guard_array != NONE ctor = sancov_create_init_calls(*s, "sancov.module_ctor_trace_pc_guard", "__sanitizer_cov_trace_pc_guard_init", i32, "sancov_guards");
    if s.counter_array != NONE ctor = sancov_create_init_calls(*s, "sancov.module_ctor_8bit_counters", "__sanitizer_cov_8bit_counters_init", i8, "sancov_cntrs");
    if s.bool_array != NONE ctor = sancov_create_init_calls(*s, "sancov.module_ctor_bool_flag", "__sanitizer_cov_bool_flag_init", ir.t_i1, "sancov_bools");
    if ctor != NONE && s.o.pc_table {
        st, en := sancov_sec_start_end(*s, "sancov_pcs", s.intptr);
        init := declare_sanitizer_init_function("__sanitizer_cov_pcs_init", .[p, p]);
        b: Irb; irb_set_before(*b, block_terminator(fn_entry(ctor)));
        irb_call(*b, init, .[st, en]);
    }
    if ctor != NONE && s.o.collect_control_flow {
        st, en := sancov_sec_start_end(*s, "sancov_cfs", s.intptr);
        init := declare_sanitizer_init_function("__sanitizer_cov_cfs_init", .[p, p]);
        b: Irb; irb_set_before(*b, block_terminator(fn_entry(ctor)));
        irb_call(*b, init, .[st, en]);
    }
    mu_append_to_used_list("llvm.used", s.to_used);
    mu_append_to_used_list("llvm.compiler.used", s.to_compiler_used);
    printer_note_ir_changed();
    pa := PRESERVE_NONE;
    pa.abandon_globals_aa = true;
    return pa;
}
