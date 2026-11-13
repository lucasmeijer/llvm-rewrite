// Small module passes of the -O2 pipeline.
// - ForceFunctionAttrsPass (llvm/lib/Transforms/IPO/ForceFunctionAttrs.cpp): -force-attribute /
//   -force-remove-attribute (-forceattrs-csv-path is rejected as unsupported).
// - MemProfRemoveInfo (llvm/lib/Transforms/IPO/MemProfContextDisambiguation.cpp): drops the "memprof" call-site
//   attribute and !memprof / !callsite metadata.
// - RecomputeGlobalsAAPass (llvm/lib/Analysis/GlobalsModRef.cpp): recomputes a cached GlobalsAA result.
// - LowerCommentStringPass (llvm/lib/Transforms/Utils/LowerCommentStringPass.cpp): AIX only.

// ForceFunctionAttrsPass (llvm/lib/Transforms/IPO/ForceFunctionAttrs.cpp): -force-attribute / -force-remove-attribute
// (-forceattrs-csv-path fails loudly)
forceattrs_opts: struct {
    add: [..] string;      // -force-attribute (cl::list)
    removes: [..] string;   // -force-remove-attribute
};
forceattrs_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "force-attribute" { if !has_value fatal("option -force-attribute needs a value"); array_add(*forceattrs_opts.add, copy_string(value)); return true; }
    if name == "force-remove-attribute" { if !has_value fatal("option -force-remove-attribute needs a value"); array_add(*forceattrs_opts.removes, copy_string(value)); return true; }
    if name == "forceattrs-csv-path" fatal("unsupported option '-forceattrs-csv-path'");
    return false;
}
forceattrs_run :: () -> Preserved {
    if forceattrs_opts.add.count == 0 && forceattrs_opts.removes.count == 0 return PRESERVE_ALL;
    has :: (f: Value_Id, k: Attr_Kind) -> bool { return fn_has_fn_attr(f, k); }
    conflicting :: (k: Attr_Kind, f: Value_Id) -> bool {
        if k == {
            case .AlwaysInline; return has(f, .NoInline) || has(f, .OptimizeNone);
            case .NoInline; return has(f, .AlwaysInline);
            case .OptimizeNone; return has(f, .AlwaysInline) || has(f, .MinSize) || has(f, .OptimizeForSize) || has(f, .OptimizeForDebugging);
            case .MinSize; return has(f, .OptimizeNone) || has(f, .OptimizeForDebugging);
            case .OptimizeForSize; return has(f, .OptimizeNone) || has(f, .OptimizeForDebugging);
            case .OptimizeForDebugging; return has(f, .OptimizeNone) || has(f, .MinSize) || has(f, .OptimizeForSize);
        }
        return false;
    }
    // ParseFunctionAndAttr
    parse :: (s: string, f: Value_Id) -> Attr_Kind {
        text := s;
        c := find_index_from_left(s, #char ":");
        if c >= 0 {
            if slice(s, 0, c) != vname(f) return .NONE_ATTR;
            text = slice(s, c + 1, s.count - c - 1);
        }
        k := attr_kind_from_name(text);
        if k != .NONE_ATTR && k > .LAST_ENUM fatal("forceattrs: forcing the attribute '%' (it takes an argument) is not supported", text);
        return k;
    }
    for f: ir.m_functions {
        for s: forceattrs_opts.add {
            k := parse(s, f);
            if k == .NONE_ATTR || has(f, k) || conflicting(k, f) continue;
            if k == .OptimizeNone && !has(f, .NoInline) fn_add_fn_attr_kind(f, .NoInline);
            fn_add_fn_attr_kind(f, k);
        }
        for s: forceattrs_opts.removes {
            k := parse(s, f);
            if k == .NONE_ATTR || !has(f, k) || (k == .NoInline && has(f, .OptimizeNone)) continue;
            l := glob(f).attrs;
            glob(f).attrs = attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), k));
        }
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

memprof_remove_info_run :: () -> Preserved {
    changed := false;
    memprof := md_fixed("memprof");
    callsite := md_fixed("callsite");
    for f: ir.m_functions {
        if is_declaration(f) continue;
        for i: fn_insts(f) {
            if !is_call_base(i) continue;
            has := false;
            for attr_set_items(call_fn_attrs(i)) if it.kind == .STRING_ATTR && it.key == "memprof" { has = true; break; }
            callee := call_called_operand_fn(i);
            if !has && callee != NONE for attr_set_items(attr_list_fn(glob(callee).attrs)) if it.kind == .STRING_ATTR && it.key == "memprof" { has = true; break; }
            if has {
                // CallBase::removeFnAttr("memprof"): the call-site attribute only
                r := inst(i);
                ps := NewArray(cast(s64) call_arg_count(i), u32,, allocator = temp);
                for *ps it.* = attr_list_param(r.attrs, cast(u32) it_index);
                r.attrs = attr_list_get(attr_set_remove_str(attr_list_fn(r.attrs), "memprof"), attr_list_ret(r.attrs), ps);
                changed = true;
            }
            if get_metadata(i, callsite) == NONE continue;
            set_metadata(i, memprof, NONE);
            set_metadata(i, callsite, NONE);
            changed = true;
        }
    }
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}

recompute_globalsaa_run :: () -> Preserved {
    if globals_aa globals_aa = globals_aa_compute();
    return PRESERVE_ALL;
}

lower_comment_string_cl: struct { disable := false; };   // -disable-lower-comment-string
lower_comment_string_run :: () -> Preserved {
    if lower_comment_string_cl.disable || !triple_is_os_aix() return PRESERVE_ALL;
    fatal("lower-comment-string: the AIX lowering is not implemented yet");
    return PRESERVE_NONE;
}
triple_is_os_aix :: () -> bool { return find_index_from_left(ir.triple, "-aix") >= 0; }

// AllocTokenPass (llvm/lib/Transforms/Instrumentation/AllocToken.cpp, AllocToken::instrumentFunction): a function
// is instrumented only with sanitize_alloc_token (and without disable_sanitizer_instrumentation), and
// llvm.alloc.token.id calls are always lowered; anything to do fails loudly (the instrumentation is not ported).
alloc_token_run :: () -> Preserved {
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if fn_has_fn_attr(f, .Naked) || glob(f).linkage == .AVAILABLE_EXTERNALLY continue;
        if fn_has_fn_attr(f, .SanitizeAllocToken) && !fn_has_fn_attr(f, .DisableSanitizerInstrumentation)
            fatal("alloc-token: sanitize_alloc_token instrumentation is not implemented yet");
        for i: fn_insts(f) if call_iid(i) == intrinsic_id_by_name("llvm.alloc.token.id")
            fatal("alloc-token: lowering llvm.alloc.token.id is not implemented yet");
    }
    return PRESERVE_ALL;
}
