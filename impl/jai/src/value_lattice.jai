// ValueLatticeElement: a port of llvm/include/llvm/Analysis/ValueLattice.h and llvm/lib/Analysis/ValueLattice.cpp.
// A value (plain struct), like LLVM's. The range's APInts live in temp unless copied with vle_heap_copy (caches
// that outlive a pass, e.g. LazyValueInfo's).

Vle_Tag :: enum u8 { UNKNOWN; UNDEF; CONSTANT; NOTCONSTANT; CONSTANTRANGE; CONSTANTRANGE_INCLUDING_UNDEF; OVERDEFINED; }

Vle :: struct {
    tag: Vle_Tag;
    num_range_extensions: u8;
    c: Value_Id = NONE;    // CONSTANT / NOTCONSTANT
    r: Const_Range;        // CONSTANTRANGE*
}

// MergeOptions
Vle_Merge_Options :: struct {
    may_include_undef: bool;
    check_widen: bool;
    max_widen_steps: u32 = 1;
}

vle_heap_copy :: (v: Vle) -> Vle {
    r := v;
    if v.tag == .CONSTANTRANGE || v.tag == .CONSTANTRANGE_INCLUDING_UNDEF {
        r.r.lo = ap_heap_copy(v.r.lo);
        r.r.hi = ap_heap_copy(v.r.hi);
    }
    return r;
}

vle_is_undef :: inline (v: Vle) -> bool { return v.tag == .UNDEF; }
vle_is_unknown :: inline (v: Vle) -> bool { return v.tag == .UNKNOWN; }
vle_is_unknown_or_undef :: inline (v: Vle) -> bool { return v.tag == .UNKNOWN || v.tag == .UNDEF; }
vle_is_constant :: inline (v: Vle) -> bool { return v.tag == .CONSTANT; }
vle_is_not_constant :: inline (v: Vle) -> bool { return v.tag == .NOTCONSTANT; }
vle_is_constant_range_including_undef :: inline (v: Vle) -> bool { return v.tag == .CONSTANTRANGE_INCLUDING_UNDEF; }
vle_is_constant_range :: (v: Vle, undef_allowed := true) -> bool {
    return v.tag == .CONSTANTRANGE || (v.tag == .CONSTANTRANGE_INCLUDING_UNDEF && (undef_allowed || cr_is_single_element(v.r)));
}
vle_is_overdefined :: inline (v: Vle) -> bool { return v.tag == .OVERDEFINED; }

// static get(C)
vle_get :: (c: Value_Id) -> Vle { r: Vle; vle_mark_constant(*r, c); return r; }
// static getNot(C)
vle_get_not :: (c: Value_Id) -> Vle { r: Vle; vle_mark_not_constant(*r, c); return r; }
// static getRange(CR, MayIncludeUndef)
vle_get_range :: (cr: Const_Range, may_include_undef := false) -> Vle {
    if cr_is_full_set(cr) return vle_get_overdefined();
    r: Vle;
    if cr_is_empty_set(cr) {
        if may_include_undef vle_mark_undef(*r);
        return r;
    }
    o: Vle_Merge_Options; o.may_include_undef = may_include_undef;
    vle_mark_constant_range(*r, cr, o);
    return r;
}
vle_get_overdefined :: () -> Vle { r: Vle; r.tag = .OVERDEFINED; return r; }

// asConstantInteger
vle_as_constant_integer :: (v: Vle) -> (bool, APInt) {
    if v.tag == .CONSTANT && vkind(v.c) == .C_INT return true, const_ap(v.c);
    if vle_is_constant_range(v) {
        ok, e := cr_single_element(v.r);
        if ok return true, e;
    }
    no: APInt;
    return false, no;
}
// asConstantRange(BW, UndefAllowed)
vle_as_constant_range_bits :: (v: Vle, bw: u32, undef_allowed := false) -> Const_Range {
    if vle_is_constant_range(v, undef_allowed) return v.r;
    if v.tag == .CONSTANT return constant_to_range(v.c);
    if v.tag == .UNKNOWN return cr_empty(bw);
    return cr_full(bw);
}
vle_as_constant_range :: (v: Vle, t: Type_Id, undef_allowed := false) -> Const_Range {
    return vle_as_constant_range_bits(v, type_bits(scalar_type(t)), undef_allowed);
}

vle_mark_overdefined :: (v: *Vle) -> bool {
    if v.tag == .OVERDEFINED return false;
    v.tag = .OVERDEFINED;
    return true;
}
vle_mark_undef :: (v: *Vle) -> bool {
    if v.tag == .UNDEF return false;
    assert(v.tag == .UNKNOWN);
    v.tag = .UNDEF;
    return true;
}
vle_mark_constant :: (v: *Vle, c: Value_Id, may_include_undef := false) -> bool {
    k := vkind(c);
    if k == .C_UNDEF || k == .C_POISON return vle_mark_undef(v);
    if v.tag == .CONSTANT {
        assert(v.c == c, "Marking constant with different value");
        return false;
    }
    if k == .C_INT {
        o: Vle_Merge_Options; o.may_include_undef = may_include_undef;
        return vle_mark_constant_range(v, cr_single(const_ap(c)), o);
    }
    assert(v.tag == .UNKNOWN || v.tag == .UNDEF);
    v.tag = .CONSTANT;
    v.c = c;
    return true;
}
vle_mark_not_constant :: (v: *Vle, c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT {
        a := const_ap(c);
        return vle_mark_constant_range(v, cr_new(ap_add_u64(a, 1), a), .{});
    }
    if k == .C_UNDEF || k == .C_POISON return false;
    if v.tag == .NOTCONSTANT {
        assert(v.c == c, "Marking !constant with different value");
        return false;
    }
    assert(v.tag == .UNKNOWN);
    v.tag = .NOTCONSTANT;
    v.c = c;
    return true;
}
vle_mark_constant_range :: (v: *Vle, nr: Const_Range, o: Vle_Merge_Options = .{}) -> bool {
    assert(!cr_is_empty_set(nr), "should only be called for non-empty sets");
    if cr_is_full_set(nr) return vle_mark_overdefined(v);
    old_tag := v.tag;
    new_tag := ifx (v.tag == .UNDEF || v.tag == .CONSTANTRANGE_INCLUDING_UNDEF || o.may_include_undef)
        then Vle_Tag.CONSTANTRANGE_INCLUDING_UNDEF else .CONSTANTRANGE;
    if vle_is_constant_range(v.*) {
        v.tag = new_tag;
        if cr_eq(v.r, nr) return v.tag != old_tag;
        if o.check_widen {
            v.num_range_extensions += 1;
            if v.num_range_extensions > o.max_widen_steps return vle_mark_overdefined(v);
        }
        v.r = nr;
        return true;
    }
    v.num_range_extensions = 0;
    v.tag = new_tag;
    v.r = nr;
    return true;
}

vle_merge_in :: (v: *Vle, rhs: Vle, o_in: Vle_Merge_Options = .{}) -> bool {
    o := o_in;
    if rhs.tag == .UNKNOWN || v.tag == .OVERDEFINED return false;
    if rhs.tag == .OVERDEFINED { vle_mark_overdefined(v); return true; }
    if v.tag == .UNDEF {
        if rhs.tag == .UNDEF return false;
        if rhs.tag == .CONSTANT return vle_mark_constant(v, rhs.c, true);
        if vle_is_constant_range(rhs) { o.may_include_undef = true; return vle_mark_constant_range(v, rhs.r, o); }
        return vle_mark_overdefined(v);
    }
    if v.tag == .UNKNOWN { v.* = rhs; return true; }
    if v.tag == .CONSTANT {
        if rhs.tag == .CONSTANT && v.c == rhs.c return false;
        if rhs.tag == .UNDEF return false;
        t := vtype(v.c);
        if is_vector_type(t) && is_int_type(scalar_type(t)) {
            l := constant_to_range(v.c);
            nr := cr_union(l, vle_as_constant_range_bits(rhs, cr_bits(l), true));
            o.may_include_undef = rhs.tag == .CONSTANTRANGE_INCLUDING_UNDEF;
            return vle_mark_constant_range(v, nr, o);
        }
        vle_mark_overdefined(v);
        return true;
    }
    if v.tag == .NOTCONSTANT {
        if rhs.tag == .NOTCONSTANT && v.c == rhs.c return false;
        vle_mark_overdefined(v);
        return true;
    }
    old_tag := v.tag;
    if rhs.tag == .UNDEF {
        v.tag = .CONSTANTRANGE_INCLUDING_UNDEF;
        return old_tag != v.tag;
    }
    l := v.r;
    nr := cr_union(l, vle_as_constant_range_bits(rhs, cr_bits(l), true));
    o.may_include_undef = rhs.tag == .CONSTANTRANGE_INCLUDING_UNDEF;
    return vle_mark_constant_range(v, nr, o);
}

// getCompare(Pred, Ty, Other, DL)
vle_get_compare :: (a: Vle, pred: u8, ty: Type_Id, b: Vle) -> Value_Id {
    if a.tag == .UNKNOWN || b.tag == .UNKNOWN return NONE;
    if a.tag == .UNDEF || b.tag == .UNDEF return NONE;
    if a.tag == .CONSTANT && b.tag == .CONSTANT return cfo_compare_inst_operands(pred, a.c, b.c);
    if icmp_is_equality(pred) {
        if (a.tag == .NOTCONSTANT && b.tag == .CONSTANT && a.c == b.c) || (a.tag == .CONSTANT && b.tag == .NOTCONSTANT && a.c == b.c)
            return ifx pred == ICMP_NE then const_int(ty, 1) else const_int(ty, 0);
    }
    if !vle_is_constant_range(a) || !vle_is_constant_range(b) return NONE;
    if cr_icmp(a.r, pred, b.r) return const_int(ty, 1);
    if cr_icmp(a.r, icmp_inverse(pred), b.r) return const_int(ty, 0);
    return NONE;
}

// hasSingleValue (ValueLattice.cpp and LazyValueInfo.cpp)
vle_has_single_value :: (v: Vle) -> bool {
    if vle_is_constant_range(v) && cr_is_single_element(v.r) return true;
    return v.tag == .CONSTANT;
}

// intersect(Other)
vle_intersect :: (a: Vle, b: Vle) -> Vle {
    if a.tag == .UNKNOWN return a;
    if b.tag == .UNKNOWN return b;
    if a.tag == .OVERDEFINED return b;
    if b.tag == .OVERDEFINED return a;
    if vle_has_single_value(a) return a;
    if vle_has_single_value(b) return b;
    if !vle_is_constant_range(a) || !vle_is_constant_range(b) return a;
    r := cr_intersect(a.r, b.r);
    return vle_get_range(r, a.tag == .CONSTANTRANGE_INCLUDING_UNDEF || b.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
}

// operator<<(raw_ostream &, const ValueLatticeElement &)
vle_to_string :: (v: Vle) -> string {
    if v.tag == {
        case .UNKNOWN; return "unknown";
        case .UNDEF; return "undef";
        case .OVERDEFINED; return "overdefined";
        case .NOTCONSTANT; return tprint("notconstant<%>", value_print_isolated(v.c));
        case .CONSTANTRANGE_INCLUDING_UNDEF;
            return tprint("constantrange incl. undef <%, %>", ap_to_string_signed(v.r.lo), ap_to_string_signed(v.r.hi));
        case .CONSTANTRANGE;
            return tprint("constantrange<%, %>", ap_to_string_signed(v.r.lo), ap_to_string_signed(v.r.hi));
    }
    return tprint("constant<%>", value_print_isolated(v.c));
}

// `OS << *V` (Value::print) with its own SlotTracker, also while another print is in progress (an annotation
// writer): global variables and functions print their definition, other constants as typed operands. The AsmWriter
// state is saved and restored around it.
value_print_isolated :: (v: Value_Id) -> string {
    k := vkind(v);
    if k != .GLOBAL_VAR && k != .FUNCTION {
        if is_inst(v) return printer_isolated_inst_to_string(v);
        return value_as_operand_typed(v);
    }
    saved_w := W; saved_ps := print_state; saved_cf := current_function;
    saved_ab := print_annot_block; saved_ai := print_annot_inst;
    print_annot_block = null; print_annot_inst = null;
    W = .{};
    print_state = .{};
    type_printing_init();
    process_module();
    print_state.module_ready = true;
    print_state.dirty = false;
    start := W.buf.count;
    if k == .GLOBAL_VAR print_global(v); else print_function(v);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W = saved_w; print_state = saved_ps; current_function = saved_cf;
    print_annot_block = saved_ab; print_annot_inst = saved_ai;
    return s;
}
// `OS << *I` with its own SlotTracker while another print is in progress
printer_isolated_inst_to_string :: (i: Value_Id) -> string {
    saved_w := W; saved_ps := print_state; saved_cf := current_function;
    W = .{};
    print_state = .{};
    s := inst_to_string(i);
    W = saved_w; print_state = saved_ps; current_function = saved_cf;
    return s;
}
