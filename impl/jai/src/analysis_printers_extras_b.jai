// Analysis printers of L1.extra.analysis-misc:
//   print<hash-recognize>   HashRecognizePrinterPass / HashRecognize::print / CRCTable::print
//                           (llvm/lib/Analysis/HashRecognize.cpp; the analysis is hash_recognize.jai's), with
//                           Loop::getLocStr (llvm/lib/Analysis/LoopInfo.cpp) and DebugLoc::print (llvm/lib/IR/DebugLoc.cpp)
//   print<structural-hash>[<detailed>|<call-target-ignored>]
//                           llvm/lib/Analysis/StructuralHash.cpp, llvm/lib/IR/StructuralHash.cpp
//   print-profile-summary   ProfileSummaryPrinterPass (llvm/lib/Analysis/ProfileSummaryInfo.cpp)
//   print<stack-safety-local>, print-stack-safety
//                           the printers of llvm/lib/Analysis/StackSafetyAnalysis.cpp
//   print<stack-lifetime><may|must>
//                           StackLifetimePrinterPass (llvm/lib/Analysis/StackLifetime.cpp)
//   print<func-properties>  llvm/lib/Analysis/FunctionPropertiesAnalysis.cpp (FunctionPropertiesInfo,
//                           FunctionPropertiesPrinterPass; not FunctionPropertiesUpdater, used by the ML inliner)

// DebugLoc::print
debug_loc_print :: (sb: *String_Builder, l: Md_Id) {
    if l == NONE return;
    append(sb, diloc_filename(l));
    print_to_builder(sb, ":%", diloc_line(l));
    if diloc_col(l) != 0 print_to_builder(sb, ":%", diloc_col(l));
    ia := diloc_inlined_at(l);
    if ia != NONE {
        append(sb, " @[ ");
        debug_loc_print(sb, ia);
        append(sb, " ]");
    }
}
// Loop::getLocStr
li_loc_str :: (li: *Loop_Info, l: Loop_Id) -> string {
    sb: String_Builder; sb.allocator = temp;
    loc := li_start_loc(li, l);
    if loc != NONE debug_loc_print(*sb, loc);
    else append(*sb, ir.module_id);
    return builder_to_string(*sb,, allocator = temp);
}

// HashRecognizePrinterPass::run (a loop pass)
print_hash_recognize_run :: (l: Loop_Id, lar: *Loop_Std_Results) -> Preserved {
    li := lar.li;
    if li_subloops(li, l).count != 0 return PRESERVE_ALL;   // !L.isInnermost()
    sb: String_Builder; sb.allocator = temp;
    f := block_fn(li_header(li, l));
    print_to_builder(*sb, "HashRecognize: Checking a loop in '%' from %\n", vname(f), li_loc_str(li, l));
    ok, info, reason := hash_recognize_crc(li, l);
    if !ok {
        append(*sb, "Did not find a hash algorithm\n");
        if reason.count print_to_builder(*sb, "Reason: %\n", reason);
    } else {
        print_to_builder(*sb, "Found%CRC-% loop with trip count %\n", ifx info.is_big_endian then " big-endian " else " little-endian ",
                         info.rhs.bits, info.trip_count);
        print_to_builder(*sb, "  Initial CRC: %\n", value_print_to_string(info.lhs, f));
        print_to_builder(*sb, "  Generating polynomial: %\n", ap_to_string_unsigned(info.rhs));
        print_to_builder(*sb, "  Computed CRC: %\n", value_print_to_string(info.computed_value, f));
        if info.lhs_aux != NONE print_to_builder(*sb, "  Auxiliary data: %\n", value_print_to_string(info.lhs_aux, f));
        append(*sb, "  Computed CRC lookup table:\n");
        table := hr_gen_sarwate_table(info.rhs, info.is_big_endian);
        for i: 0..255 {
            append(*sb, ap_to_string_unsigned(table[i]));
            append(*sb, ifx i % 16 == 15 then "\n" else " ");
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print<structural-hash>
// StructuralHashPrinterPass (llvm/lib/Analysis/StructuralHash.cpp) and StructuralHashImpl
// (llvm/lib/IR/StructuralHash.cpp); xxh3 / stable_hash_combine are pass_merge_functions.jai's.

Sh :: struct {
    hash: u64 = 4;
    detailed: bool;
    ignore_call_constants: bool;   // the call-target-ignored IgnoreOp
    value_to_id: Table(Value_Id, u64);
    md_rep: Table(u32, Value_Id);    // metadata node -> the MetadataAsValue standing for it
    inst_count: u64;               // IndexInstruction->size()
    ignored: [..] Sh_Ignored;      // IndexOperandHashMap, in insertion order (printed in DenseMap bucket order)
}
Sh_Ignored :: struct { inst: u64; opnd: u64; hash: u64; }

sh_combine :: (hs: [] u64) -> u64 { return stable_hash_combine(hs); }
// stable_hash_name (get_stable_name)
sh_hash_name :: (name: string) -> u64 {
    rsplit :: (s: string, sep: string) -> string, string {
        i := s.count - sep.count;
        while i >= 0 {
            if slice(s, i, sep.count) == sep return slice(s, 0, i), slice(s, i + sep.count, s.count - i - sep.count);
            i -= 1;
        }
        return s, "";
    }
    _, s0 := rsplit(name, ".content.");
    n := name;
    if s0.count n = s0;
    else {
        p1 := rsplit(name, ".llvm.");
        n = rsplit(p1, ".__uniq.");
    }
    return xxh3_64bits(cast([] u8) n);
}
sh_hash_type :: (t: Type_Id) -> u64 {
    hs: [2] u64;
    hs[0] = fc_type_id(type_kind(t));
    if type_kind(t) == .INT { hs[1] = type_int_width(t); return sh_combine(hs); }
    return sh_combine(array_view(hs, 0, 1));
}
sh_hash_ap_words :: (bits: u64, words: [] u64) -> u64 {
    hs: [..] u64; hs.allocator = temp;
    array_add(*hs, bits);
    for words array_add(*hs, it);
    return sh_combine(hs);
}
// APFloat::bitcastToAPInt of the parsed bits: x86_fp80 unnormals are NaNs (exported with exponent 0x7fff) and
// pseudo-denormals are normals (exported with exponent 1); other formats round-trip
sh_fp_bitcast :: (k: Type_Kind, w: [] u64) -> [] u64 {
    if k != .X86_FP80 return w;
    e := w[1] & 0x7FFF;
    int_bit := (w[0] >> 63) != 0;
    if (e != 0 && e != 0x7FFF && !int_bit) || (e == 0 && int_bit) {
        r := NewArray(2, u64,, allocator = temp);
        r[0] = w[0];
        r[1] = (w[1] & ~cast(u64) 0x7FFF) | (ifx e == 0 then cast(u64) 1 else 0x7FFF);
        return r;
    }
    return w;
}
sh_hash_global_value :: (g: Value_Id) -> u64 {
    if vname(g).count == 0 return 0;
    return sh_hash_name(vname(g));
}
sh_is_string :: (c: Value_Id) -> bool {
    return vkind(c) == .C_DATA && type_kind(vtype(c)) == .ARRAY && type_kind(type_elem(vtype(c))) == .INT && type_int_width(type_elem(vtype(c))) == 8;
}
sh_string_of :: (c: Value_Id) -> string { return fc_raw_data(c); }
sh_hash_global_variable :: (g: Value_Id) -> u64 {
    if !glob(g).has_init return sh_hash_global_value(g);
    if begins_with(vname(g), ".str") {
        c := op(g, 0);
        if sh_is_string(c) return sh_hash_name(sh_string_of(c));
    }
    sec := glob(g).section;
    if sec.count {
        for string.["__cfstring", "__cstring", "__objc_classrefs", "__objc_methname", "__objc_selrefs"]
            if contains(sec, it) return sh_hash_constant(op(g, 0));
    }
    return sh_hash_global_value(g);
}
sh_hash_constant :: (c: Value_Id) -> u64 {
    hs: [..] u64; hs.allocator = temp;
    array_add(*hs, sh_hash_type(vtype(c)));
    k := vkind(c);
    if is_null_value(c) { array_add(*hs, cast(u64) #char "N"); return sh_combine(hs); }
    if k == .GLOBAL_VAR { array_add(*hs, sh_hash_global_variable(c)); return sh_combine(hs); }
    if is_global_value(k) { array_add(*hs, sh_hash_global_value(c)); return sh_combine(hs); }
    if sh_is_string(c) { array_add(*hs, sh_hash_name(sh_string_of(c))); return sh_combine(hs); }
    if k == {
        case .C_INT;
            t := vtype(c);
            st := scalar_type(t);
            if type_kind(st) == .BYTE {
                // a ConstantByte (vector splats too): not in hashConstant's switch, only the type is hashed
            } else if type_kind(t) == .SVECTOR && !opts.use_constant_int_for_scalable_splat {
                // ConstantVector::getSplat of a scalable vector (no ConstantInt splats by default): the ConstantExpr
                // shufflevector(insertelement(poison, V, i64 0), poison, zeroinitializer). (A fixed-length C_INT
                // vector only exists with -use-constant-int-for-fixed-length-splat, and is a ConstantInt then.)
                elt: [2] u64;
                elt[0] = sh_hash_type(st);
                elt[1] = sh_hash_ap_words(type_int_width(st), const_int_value(c));
                eh := sh_combine(elt);
                poison: [1] u64; poison[0] = sh_hash_type(t);
                ph := sh_combine(poison);
                zero: [2] u64; zero[0] = sh_hash_type(type_int(64)); zero[1] = cast(u64) #char "N";   // i64 0 is a null value
                ins: [4] u64; ins[0] = sh_hash_type(t); ins[1] = ph; ins[2] = eh; ins[3] = sh_combine(zero);
                array_add(*hs, sh_combine(ins));
                array_add(*hs, ph);
            } else array_add(*hs, sh_hash_ap_words(type_int_width(st), const_int_value(c)));
        case .C_FP;
            // ConstantFP (vector splats included): hashAPInt(bitcastToAPInt())
            array_add(*hs, sh_hash_ap_words(type_bits(scalar_type(vtype(c))), sh_fp_bitcast(type_kind(scalar_type(vtype(c))), const_fp_value(c))));
        case .C_ARRAY; #through;
        case .C_STRUCT; #through;
        case .C_VECTOR; #through;
        case .C_EXPR;
            for x: 0..cast(s64) nops(c) - 1 array_add(*hs, sh_hash_constant(op(c, cast(u32) x)));
        case .C_BLOCKADDR;
            array_add(*hs, sh_hash_global_value(op(c, 0)));
        case .C_DSO_EQUIV;
            array_add(*hs, sh_hash_global_value(op(c, 0)));
    }
    return sh_combine(hs);
}
sh_hash_value :: (s: *Sh, v: Value_Id) -> u64 {
    if is_constant_kind(vkind(v)) return sh_hash_constant(v);
    hs: [2] u64; n := 0;
    if vkind(v) == .ARGUMENT { hs[n] = arg_no(v); n += 1; }
    // MetadataAsValue is uniqued per Metadata in LLVM; impl/jai may hold two values for one node (a forward
    // reference and the definition), so metadata operands are keyed by their node
    key := v;
    if vkind(v) == .MD_VALUE {
        found_m, rep := table_find(*s.md_rep, ir.v_aux[v]);
        if found_m key = rep; else table_set(*s.md_rep, ir.v_aux[v], v);
    }
    found, id := table_find(*s.value_to_id, key);
    if !found { id = cast(u64) s.value_to_id.count; table_set(*s.value_to_id, key, id); }
    hs[n] = id; n += 1;
    return sh_combine(array_view(hs, 0, n));
}
sh_hash_operand :: (s: *Sh, v: Value_Id) -> u64 {
    hs: [2] u64;
    hs[0] = sh_hash_type(vtype(v));
    hs[1] = sh_hash_value(s, v);
    return sh_combine(hs);
}
// Instruction::operands() in LLVM's order
sh_operands :: (i: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    // (LLVM 23's SwitchInst keeps its case values out of the operand list, like impl/jai's)
    for k: 0..cast(s64) nops(i) - 1 array_add(out, op(i, cast(u32) k));
}
sh_hash_instruction :: (s: *Sh, i: Value_Id) -> u64 {
    hs: [..] u64; hs.allocator = temp;
    array_add(*hs, cast(u64) inst_op(i));
    if !s.detailed return sh_combine(hs);
    array_add(*hs, sh_hash_type(vtype(i)));
    if inst_op(i) == .ICMP || inst_op(i) == .FCMP array_add(*hs, cast(u64) inst(i).pred);
    idx: u64 = 0;
    if s.ignore_call_constants { idx = s.inst_count; s.inst_count += 1; }
    ops: [..] Value_Id; ops.allocator = temp;
    sh_operands(i, *ops);
    for o, k: ops {
        h := sh_hash_operand(s, o);
        if s.ignore_call_constants && inst_op(i) == .CALL && is_constant_kind(vkind(o)) array_add(*s.ignored, .{idx, cast(u64) k, h});
        else array_add(*hs, h);
    }
    return sh_combine(hs);
}
sh_update_function :: (s: *Sh, f: Value_Id) {
    if is_declaration(f) return;
    hs: [..] u64; hs.allocator = temp;
    array_add(*hs, s.hash);
    array_add(*hs, 0x62642d6b6b2d6b72);
    array_add(*hs, ifx func_vararg(glob(f).value_type) then cast(u64) 1 else 0);
    array_add(*hs, glob(f).nargs);
    stack: [..] Value_Id; stack.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    e := fn_entry(f);
    array_add(*stack, e);
    table_set(*visited, e, true);
    succs: [..] Value_Id; succs.allocator = temp;
    while stack.count {
        b := pop(*stack);
        array_add(*hs, 45798);
        for i: block_insts(b) array_add(*hs, sh_hash_instruction(s, i));
        block_successors(b, *succs);
        for x: succs if !table_contains(*visited, x) { table_set(*visited, x, true); array_add(*stack, x); }
    }
    s.hash = sh_combine(hs);
}
sh_new :: (detailed: bool, ignore := false) -> Sh {
    s: Sh;
    s.detailed = detailed; s.ignore_call_constants = ignore;
    s.value_to_id.allocator = temp; s.md_rep.allocator = temp; s.ignored.allocator = temp;
    return s;
}

print_structural_hash_run :: (name: string) -> Preserved {
    detailed := name == "print<structural-hash><detailed>";
    call_target_ignored := name == "print<structural-hash><call-target-ignored>";
    sb: String_Builder; sb.allocator = temp;
    m := sh_new(detailed || call_target_ignored);
    for gv: ir.m_globals {
        if is_declaration(gv) || begins_with(vname(gv), "llvm.") continue;
        hs: [3] u64;
        hs[0] = m.hash; hs[1] = 23456; hs[2] = fc_type_id(type_kind(glob(gv).value_type));
        m.hash = sh_combine(hs);
    }
    for f: ir.m_functions sh_update_function(*m, f);
    hex16 :: (x: u64) -> string { return tprint("%", formatInt(x, base = 16, minimum_digits = 16)); }
    print_to_builder(*sb, "Module Hash: %\n", hex16(m.hash));
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if call_target_ignored {
            s := sh_new(true, true);
            sh_update_function(*s, f);
            print_to_builder(*sb, "Function % Hash: %\n", vname(f), hex16(s.hash));
            // IndexOperandHashMap is a DenseMap<std::pair<unsigned, unsigned>, stable_hash>: printed in bucket order
            // (DenseMapInfo<pair> = combineHashValue of the two `x * 37` hashes; no erasures)
            buckets: [..] s32; buckets.allocator = temp;
            place :: (buckets: *[..] s32, ign: [] Sh_Ignored, e: s32) {
                mask := cast(u32) (buckets.count - 1);
                k := dm_combine_hash(dm_hash_s64(cast(s64) ign[e].inst), dm_hash_s64(cast(s64) ign[e].opnd)) & mask;
                while buckets.*[k] >= 0 k = (k + 1) & mask;
                buckets.*[k] = e;
            }
            for e: 0..s.ignored.count - 1 {
                if (e + 1) * 4 >= buckets.count * 3 {
                    nn := max(64, buckets.count * 2);
                    old: [..] s32; old.allocator = temp;
                    for buckets array_add(*old, it);
                    array_resize(*buckets, nn);
                    for * buckets it.* = -1;
                    for old if it >= 0 place(*buckets, s.ignored, it);
                }
                place(*buckets, s.ignored, cast(s32) e);
            }
            ordered: [..] Sh_Ignored; ordered.allocator = temp;
            for buckets if it >= 0 array_add(*ordered, s.ignored[it]);
            s.ignored = ordered;
            for s.ignored print_to_builder(*sb, "\tIgnored Operand Hash: % at (%,%)\n", hex16(it.hash), it.inst, it.opnd);
        } else {
            s := sh_new(detailed);
            sh_update_function(*s, f);
            print_to_builder(*sb, "Function % Hash: %\n", vname(f), hex16(s.hash));
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print-profile-summary
// ProfileSummaryPrinterPass (llvm/lib/Analysis/ProfileSummaryInfo.cpp; the analysis is psi.jai's)
print_profile_summary_run :: () -> Preserved {
    p := psi_require();
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Functions in % with hot/cold annotations: \n", ir.module_id);
    for f: ir.m_functions {
        append(*sb, vname(f));
        if psi_is_function_entry_hot(p, f) append(*sb, " :hot entry ");
        else if psi_is_function_entry_cold(p, f) append(*sb, " :cold entry ");
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print<stack-safety-local>, print-stack-safety
// StackSafetyPrinterPass, StackSafetyGlobalPrinterPass, FunctionInfo::print, operator<<(UseInfo)
// (llvm/lib/Analysis/StackSafetyAnalysis.cpp; the analysis is stack_safety.jai's). Calls are a std::map ordered by
// (ParamNo, Callee pointer): two callees for one parameter number print in address order: fails loudly.
ss_guess_address_order := false;   // -stack-safety-guess-address-order (ours): callees in creation (value id) order
ss_print_use :: (sb: *String_Builder, u: *Ss_Use) {
    cr_print_to(sb, u.range);
    for c, k: u.calls {
        if k > 0 && u.calls[k - 1].param == c.param && u.calls[k - 1].callee != c.callee && !ss_guess_address_order
            fatal("print<stack-safety>: the calls of one use are a std::map ordered by callee pointer (two callees for argument %; use -stack-safety-guess-address-order to guess)", c.param);
        print_to_builder(sb, ", @%(arg%, ", vname(c.callee), c.param);
        cr_print_to(sb, c.range);
        append(sb, ")");
    }
}
ss_print_fn :: (sb: *String_Builder, info: *Ss_Fn) {
    f := info.f;
    g := glob(f);
    print_to_builder(sb, "  @%%%\n", vname(f), ifx g.dso_local then "" else " dso_preemptable", ifx gv_is_interposable(f) then " interposable" else "");
    append(sb, "    args uses:\n");
    // std::map<uint32_t, UseInfo>: by argument number
    order := NewArray(info.params.count, s64,, allocator = temp);
    for * order it.* = it_index;
    for i: 1..order.count - 1 { x := order[i]; j := i - 1; while j >= 0 && info.params[order[j]] > info.params[x] { order[j + 1] = order[j]; j -= 1; } order[j + 1] = x; }
    for k: order {
        print_to_builder(sb, "      %[]: ", vname(fn_arg(f, info.params[k])));
        ss_print_use(sb, *info.param_uses[k]);
        append(sb, "\n");
    }
    append(sb, "    allocas uses:\n");
    for ai, k: info.allocas {
        print_to_builder(sb, "      %[%]: ", vname(ai), ap_to_string_signed(ss_static_alloca_size_range(ai).hi));
        ss_print_use(sb, *info.alloca_uses[k]);
        append(sb, "\n");
    }
}

print_stack_safety_local_run :: (f: Value_Id) -> Preserved {
    // the header goes out before the analysis runs (it may print subtarget feature warnings, via TTI)
    write_string(tprint("'Stack Safety Local Analysis' for function '%'\n", vname(f)), to_standard_error = true);
    sb: String_Builder; sb.allocator = temp;
    info := ss_local_run(f);
    ss_print_fn(*sb, *info);
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

print_stack_safety_global_run :: () -> Preserved {
    write_string(tprint("'Stack Safety Analysis' for module '%'\n", ir.module_id), to_standard_error = true);
    sb: String_Builder; sb.allocator = temp;
    g: Stack_Safety_Global;
    stack_safety_global_init(*g);
    ss_get_info(*g);
    for f: ir.m_functions {
        if is_declaration(f) continue;
        info: *Ss_Fn = null;
        for * g.print_fns if it.f == f { info = it; break; }
        if !info break;
        ss_print_fn(*sb, info);
        append(*sb, "    safe accesses:\n");
        for i: fn_insts(f) {
            o := inst_op(i);
            is_call := o == .CALL;
            if !(o == .STORE || o == .LOAD || (is_call && is_mem_intrinsic(i)) || o == .CMPXCHG || o == .ATOMICRMW || (is_call && call_has_byval_argument(i))) continue;
            if !stack_safety_access_is_safe(*g, i) continue;
            print_to_builder(*sb, "     %\n", inst_to_string(i));
        }
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
// CallBase::hasByValArgument
call_has_byval_argument :: (c: Value_Id) -> bool {
    n := call_arg_count(c);
    for k: 0..cast(s64) n - 1 if attr_set_find(attr_list_param(inst(c).attrs, cast(u32) k), .ByVal) return true;
    return false;
}

// ---------------------------------------------------------------- print<stack-lifetime><may|must>
// StackLifetimePrinterPass / StackLifetime::LifetimeAnnotationWriter (llvm/lib/Analysis/StackLifetime.cpp; the
// analysis is stack_lifetime.jai's). The alive allocas' names are sorted, so AllocaNumbering's order doesn't show.
sl_print_ctx: struct { sl: *Stack_Lifetime; allocas: [] Value_Id; };

sl_alive_names :: (inst_no: s64, after: Value_Id) {
    names: [..] string; names.allocator = temp;
    for ai, k: sl_print_ctx.allocas {
        alive := ifx after != NONE then stack_lifetime_is_alive_after(sl_print_ctx.sl, ai, after) else sl_print_ctx.sl.ranges[k][inst_no];
        if alive array_add(*names, vname(ai));
    }
    for i: 1..names.count - 1 { x := names[i]; j := i - 1; while j >= 0 && compare(names[j], x) > 0 { names[j + 1] = names[j]; j -= 1; } names[j + 1] = x; }
    out("<");
    for names { if it_index > 0 out(" "); out(it); }
    out(">\n");
}
sl_annot_block :: (b: Value_Id) {
    found, bi := table_find(*sl_print_ctx.sl.block_index, b);
    if !found return;
    out("  ; Alive: ");
    sl_alive_names(sl_print_ctx.sl.inst_start[bi], NONE);
}
sl_annot_info :: (i: Value_Id) {
    if !stack_lifetime_is_reachable(sl_print_ctx.sl, i) return;
    out("\n  ; Alive: ");
    sl_alive_names(0, i);
}

print_stack_lifetime_run :: (f: Value_Id, must: bool) -> Preserved {
    allocas: [..] Value_Id; allocas.allocator = temp;
    for i: fn_insts(f) if inst_op(i) == .ALLOCA array_add(*allocas, i);
    sl := stack_lifetime_run(f, allocas, !must);
    // AllocaNumbering: allocas[k] is number k (stack_lifetime_run numbers them in order)
    for ai, k: allocas { found, no := table_find(*sl.numbering, ai); assert(found && no == k); }
    sl_print_ctx.sl = *sl;
    sl_print_ctx.allocas = allocas;
    printer_begin_function(f);
    start := W.buf.count;
    print_annot_block = sl_annot_block;
    print_annot_info = sl_annot_info;
    print_function(f);
    print_annot_block = null;
    print_annot_info = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    write_string(s, to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print<func-properties>
// FunctionPropertiesInfo (getFunctionPropertiesInfo, updateForBB, updateAggregateStats, print) and
// FunctionPropertiesPrinterPass (llvm/lib/Analysis/FunctionPropertiesAnalysis.cpp; the property list is
// llvm/include/llvm/IR/FunctionProperties.def). The IR2Vec function embedding is only computed when an
// IR2VecVocabAnalysis result is cached, which the printer never has.
fpi_detailed := false;               // -enable-detailed-function-properties
fpi_big_bb_threshold := 500;         // -big-basic-block-instruction-threshold
fpi_medium_bb_threshold := 15;       // -medium-basic-block-instruction-threshold
fpi_many_args_threshold := 4;        // -call-with-many-arguments-threshold

FPI_NAMES :: string.[
    "BasicBlockCount", "BlocksReachedFromConditionalInstruction", "Uses", "DirectCallsToDefinedFunctions",
    "LoadInstCount", "StoreInstCount", "MaxLoopDepth", "TopLevelLoopCount", "TotalInstructionCount",
    // detailed
    "BasicBlocksWithSingleSuccessor", "BasicBlocksWithTwoSuccessors", "BasicBlocksWithMoreThanTwoSuccessors",
    "BasicBlocksWithSinglePredecessor", "BasicBlocksWithTwoPredecessors", "BasicBlocksWithMoreThanTwoPredecessors",
    "BigBasicBlocks", "MediumBasicBlocks", "SmallBasicBlocks", "CastInstructionCount", "FloatingPointInstructionCount",
    "IntegerInstructionCount", "ConstantIntOperandCount", "ConstantFPOperandCount", "ConstantOperandCount",
    "InstructionOperandCount", "BasicBlockOperandCount", "GlobalValueOperandCount", "InlineAsmOperandCount",
    "ArgumentOperandCount", "UnknownOperandCount", "CriticalEdgeCount", "ControlFlowEdgeCount",
    "UnconditionalBranchCount", "ConditionalBranchCount", "BranchInstructionCount", "BranchSuccessorCount",
    "SwitchInstructionCount", "SwitchSuccessorCount", "IntrinsicCount", "NoReturnCallCount", "DirectCallCount",
    "IndirectCallCount", "CallReturnsIntegerCount", "CallReturnsFloatCount", "CallReturnsPointerCount",
    "CallReturnsVectorIntCount", "CallReturnsVectorFloatCount", "CallReturnsVectorPointerCount",
    "CallWithManyArgumentsCount", "CallWithPointerArgumentCount"];
FPI_N_BASIC :: 9;

Fpi :: enum {
    BasicBlockCount; BlocksReachedFromConditionalInstruction; Uses; DirectCallsToDefinedFunctions;
    LoadInstCount; StoreInstCount; MaxLoopDepth; TopLevelLoopCount; TotalInstructionCount;
    BasicBlocksWithSingleSuccessor; BasicBlocksWithTwoSuccessors; BasicBlocksWithMoreThanTwoSuccessors;
    BasicBlocksWithSinglePredecessor; BasicBlocksWithTwoPredecessors; BasicBlocksWithMoreThanTwoPredecessors;
    BigBasicBlocks; MediumBasicBlocks; SmallBasicBlocks; CastInstructionCount; FloatingPointInstructionCount;
    IntegerInstructionCount; ConstantIntOperandCount; ConstantFPOperandCount; ConstantOperandCount;
    InstructionOperandCount; BasicBlockOperandCount; GlobalValueOperandCount; InlineAsmOperandCount;
    ArgumentOperandCount; UnknownOperandCount; CriticalEdgeCount; ControlFlowEdgeCount;
    UnconditionalBranchCount; ConditionalBranchCount; BranchInstructionCount; BranchSuccessorCount;
    SwitchInstructionCount; SwitchSuccessorCount; IntrinsicCount; NoReturnCallCount; DirectCallCount;
    IndirectCallCount; CallReturnsIntegerCount; CallReturnsFloatCount; CallReturnsPointerCount;
    CallReturnsVectorIntCount; CallReturnsVectorFloatCount; CallReturnsVectorPointerCount;
    CallWithManyArgumentsCount; CallWithPointerArgumentCount;
}

fpi_count_operand :: (p: *[FPI_NAMES.count] s64, o: Value_Id) {
    k := vkind(o);
    t := vtype(o);
    if k == .FUNCTION || k == .GLOBAL_VAR || k == .ALIAS || k == .IFUNC p.*[cast(s64) Fpi.GlobalValueOperandCount] += 1;
    // a C_INT vector is a ConstantInt in LLVM only with -use-constant-int-for-fixed-length-splat (fixed; impl/jai has
    // none without it) or -use-constant-int-for-scalable-splat; a default scalable splat is a ConstantExpr
    else if k == .C_INT && type_kind(scalar_type(t)) == .INT && !(type_kind(t) == .SVECTOR && !opts.use_constant_int_for_scalable_splat)
        p.*[cast(s64) Fpi.ConstantIntOperandCount] += 1;
    else if k == .C_FP p.*[cast(s64) Fpi.ConstantFPOperandCount] += 1;   // vector splats are ConstantFPs too
    else if is_const(o) p.*[cast(s64) Fpi.ConstantOperandCount] += 1;
    else if k == .INST p.*[cast(s64) Fpi.InstructionOperandCount] += 1;
    else if k == .BLOCK p.*[cast(s64) Fpi.BasicBlockOperandCount] += 1;
    else if k == .INLINE_ASM p.*[cast(s64) Fpi.InlineAsmOperandCount] += 1;
    else if k == .ARGUMENT p.*[cast(s64) Fpi.ArgumentOperandCount] += 1;
    else p.*[cast(s64) Fpi.UnknownOperandCount] += 1;
}

// updateForBB(BB, +1)
fpi_include_bb :: (p: *[FPI_NAMES.count] s64, bb: Value_Id) {
    p.*[cast(s64) Fpi.BasicBlockCount] += 1;
    term := block_terminator(bb);
    if inst_op(term) == .CONDBR p.*[cast(s64) Fpi.BlocksReachedFromConditionalInstruction] += 2;
    else if inst_op(term) == .SWITCH p.*[cast(s64) Fpi.BlocksReachedFromConditionalInstruction] += switch_num_cases(term) + 1;
    size := 0;
    for i: block_insts(bb) {
        size += 1;
        o := inst_op(i);
        if o == .CALL || o == .INVOKE || o == .CALLBR {
            callee := call_called_function(i);
            if callee != NONE && !glob(callee).intrinsic && !is_declaration(callee) p.*[cast(s64) Fpi.DirectCallsToDefinedFunctions] += 1;
        }
        if o == .LOAD p.*[cast(s64) Fpi.LoadInstCount] += 1;
        else if o == .STORE p.*[cast(s64) Fpi.StoreInstCount] += 1;
    }
    p.*[cast(s64) Fpi.TotalInstructionCount] += size;
    if !fpi_detailed return;
    nsucc := num_successors(term);
    if nsucc == 1 p.*[cast(s64) Fpi.BasicBlocksWithSingleSuccessor] += 1;
    else if nsucc == 2 p.*[cast(s64) Fpi.BasicBlocksWithTwoSuccessors] += 1;
    else if nsucc > 2 p.*[cast(s64) Fpi.BasicBlocksWithMoreThanTwoSuccessors] += 1;
    np := block_num_preds(bb);
    if np == 1 p.*[cast(s64) Fpi.BasicBlocksWithSinglePredecessor] += 1;
    else if np == 2 p.*[cast(s64) Fpi.BasicBlocksWithTwoPredecessors] += 1;
    else if np >= 3 p.*[cast(s64) Fpi.BasicBlocksWithMoreThanTwoPredecessors] += 1;
    // the function's running TotalInstructionCount, as in LLVM
    if p.*[cast(s64) Fpi.TotalInstructionCount] > fpi_big_bb_threshold p.*[cast(s64) Fpi.BigBasicBlocks] += 1;
    else if p.*[cast(s64) Fpi.TotalInstructionCount] > fpi_medium_bb_threshold p.*[cast(s64) Fpi.MediumBasicBlocks] += 1;
    else p.*[cast(s64) Fpi.SmallBasicBlocks] += 1;
    if nsucc > 1 {
        for k: 0..cast(s64) nsucc - 1 if block_num_preds(get_successor(term, cast(u32) k)) >= 2 p.*[cast(s64) Fpi.CriticalEdgeCount] += 1;
    }
    p.*[cast(s64) Fpi.ControlFlowEdgeCount] += nsucc;
    to := inst_op(term);
    if to == .BR {
        p.*[cast(s64) Fpi.BranchInstructionCount] += 1; p.*[cast(s64) Fpi.BranchSuccessorCount] += 1; p.*[cast(s64) Fpi.UnconditionalBranchCount] += 1;
    } else if to == .CONDBR {
        p.*[cast(s64) Fpi.BranchInstructionCount] += 1; p.*[cast(s64) Fpi.BranchSuccessorCount] += 2; p.*[cast(s64) Fpi.ConditionalBranchCount] += 1;
    } else if to == .SWITCH {
        p.*[cast(s64) Fpi.SwitchInstructionCount] += 1; p.*[cast(s64) Fpi.SwitchSuccessorCount] += nsucc;
    }
    for i: block_insts(bb) {
        o := inst_op(i);
        t := vtype(i);
        if is_cast_op(o) p.*[cast(s64) Fpi.CastInstructionCount] += 1;
        if type_kind(t) == .FLOAT p.*[cast(s64) Fpi.FloatingPointInstructionCount] += 1;
        else if type_kind(t) == .INT p.*[cast(s64) Fpi.IntegerInstructionCount] += 1;
        if o == .CALL {
            callee := call_called_function(i);
            if callee != NONE && glob(callee).intrinsic p.*[cast(s64) Fpi.IntrinsicCount] += 1;
            if call_has_fn_attr(i, .NoReturn) p.*[cast(s64) Fpi.NoReturnCallCount] += 1;
            co := call_callee(i);
            // CallBase::isIndirectCall
            if vkind(co) != .FUNCTION && !is_const(co) && vkind(co) != .INLINE_ASM p.*[cast(s64) Fpi.IndirectCallCount] += 1;
            else p.*[cast(s64) Fpi.DirectCallCount] += 1;
            tk := type_kind(t);
            if tk == .INT p.*[cast(s64) Fpi.CallReturnsIntegerCount] += 1;
            else if is_fp_type(t) p.*[cast(s64) Fpi.CallReturnsFloatCount] += 1;
            else if tk == .PTR p.*[cast(s64) Fpi.CallReturnsPointerCount] += 1;
            else if tk == .VECTOR || tk == .SVECTOR {
                st := scalar_type(t);
                if type_kind(st) == .INT p.*[cast(s64) Fpi.CallReturnsVectorIntCount] += 1;
                else if is_fp_type(st) p.*[cast(s64) Fpi.CallReturnsVectorFloatCount] += 1;
                else if type_kind(st) == .PTR p.*[cast(s64) Fpi.CallReturnsVectorPointerCount] += 1;
            }
            na := call_num_args(i);
            if na > cast(u32) fpi_many_args_threshold p.*[cast(s64) Fpi.CallWithManyArgumentsCount] += 1;
            for a: 0..cast(s64) na - 1 if is_ptr_type(vtype(call_arg(i, cast(u32) a))) { p.*[cast(s64) Fpi.CallWithPointerArgumentCount] += 1; break; }
        }
        for k: 0..cast(s64) nops(i) - 1 fpi_count_operand(p, op(i, cast(u32) k));
        // (LLVM 23's SwitchInst keeps its case values out of the operand list: they are not counted)
    }
}

print_func_properties_run :: (f: Value_Id) -> Preserved {
    p: [FPI_NAMES.count] s64;
    dt := get_domtree(f);
    li := get_loop_info(f);
    for bb: fn_blocks(f) if dt_is_reachable_from_entry(dt, bb) fpi_include_bb(*p, bb);
    // updateAggregateStats
    // getNumUses: LLVM 23's BlockAddress has only the block as operand, so blockaddress(@f, ...) is not a use of @f
    n_uses := 0;
    u := ir.v_first_use[f];
    while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR n_uses += 1; u = ir.u_next[u]; }
    p[cast(s64) Fpi.Uses] = (ifx is_local_linkage(glob(f).linkage) then 0 else 1) + n_uses;
    p[cast(s64) Fpi.TopLevelLoopCount] = li.top_level.count;
    for * l: li.loops if !l.dead { d := cast(s64) li_depth(li, cast(Loop_Id) it_index); if d > p[cast(s64) Fpi.MaxLoopDepth] p[cast(s64) Fpi.MaxLoopDepth] = d; }
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis results of CFA for function '%':\n", vname(f));
    for FPI_NAMES {
        if it_index >= FPI_N_BASIC && !fpi_detailed break;
        print_to_builder(*sb, "%: %\n", it, p[it_index]);
    }
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
