// Intrinsic lookup and attributes (llvm/lib/IR/Intrinsics.cpp: lookupIntrinsicID, getAttributes;
// llvm/lib/IR/AutoUpgrade.cpp: UpgradeIntrinsicFunction sets Intrinsic::getAttributes on declarations).
// The tables are generated (gen_intrinsics.jai, see impl/jai/gen/gen_intrinsics.py).

// Intrinsic::lookupIntrinsicID: the longest intrinsic name that equals `name` or prefixes it before a '.'.
// Non-overloaded intrinsics only match exactly.
intrinsic_lookup :: (name: string) -> string {
    for INTRINSIC_NAMES if name == it return it;
    best := "";
    for INTRINSIC_OVERLOADED {
        if it.count <= best.count continue;
        if name.count > it.count && begins_with(name, it) && name[it.count] == #char "." best = it;
    }
    return best;
}

parse_attr_text :: (text: string, is_fn: bool) -> u32 {
    if text.count == 0 return 0;
    saved_lx := P.lx; saved_tok := P.tok;
    P.lx = .{};
    P.lx.src = ifx is_fn then tprint("% }", text) else text;
    P.lx.file = "<intrinsic attribute table>";
    next();
    attrs: [..] Attr; attrs.allocator = temp;
    if is_fn {
        groups: [..] u32; groups.allocator = temp;
        parse_fn_attribute_value_pairs(*attrs, *groups, true);
    } else {
        parse_optional_param_or_return_attrs(*attrs, true);
    }
    if P.tok.kind != .RBRACE && P.tok.kind != .EOF fatal("bad intrinsic attribute text '%'", text);
    P.lx = saved_lx; P.tok = saved_tok;
    return attr_set_get(attrs);
}

upgrade_intrinsic_function :: (f: Value_Id) {
    base := intrinsic_lookup(vname(f));
    if base.count == 0 return;   // unknown intrinsic: keeps its attributes (printed with "; Unknown intrinsic")
    for INTRINSIC_ATTRS {
        if it.name != base continue;
        fnset := parse_attr_text(it.fn, true);
        rtext := it.ret;
        if contains(rtext, "@") {
            rt := scalar_type(func_ret(glob(f).value_type));
            rtext = replace(rtext, "@", tprint("%", type_bits(rt)),, allocator = temp);
        }
        retset := parse_attr_text(rtext, false);
        ps: [..] u32; ps.allocator = temp;
        np := func_nparams(glob(f).value_type);
        if np > 0 for i: 0..np-1 array_add(*ps, ifx i < it.params.count then parse_attr_text(it.params[i], false) else 0);
        glob(f).attrs = attr_list_get(fnset, retset, ps);
        return;
    }
    fatal("intrinsic '%' has no entry in the generated attribute table (impl/jai/gen/gen_intrinsics.py: add a test that declares it)", vname(f));
}

is_unknown_intrinsic :: (f: Value_Id) -> bool {
    return glob(f).intrinsic && intrinsic_lookup(vname(f)).count == 0;
}

intrinsic_has_pretty_args :: (name: string) -> bool {
    return intrinsic_lookup(name) == "llvm.is.fpclass";
}

// Intrinsic::printImmArg for llvm.is.fpclass (ImmArgPrinter<"printFPClassMask"> on argument 1)
print_imm_arg_comment :: (f: Value_Id, argno: u32, v: Value_Id) {
    if argno != 1 || vkind(v) != .C_INT return;
    out("/* ");
    write_fpclass(const_int_zext(v));
    out(" */ ");
}
