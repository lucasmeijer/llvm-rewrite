// Port of the parts of llvm/lib/IR/DataLayout.cpp the IR core needs: spec parsing, type sizes and
// ABI/preferred alignment, struct layout.

Prim_Spec :: struct { bits: u32; abi: u64; pref: u64; }
Ptr_Spec  :: struct { as: u32; bits: u32; abi: u64; pref: u64; idx_bits: u32; }

Data_Layout :: struct {
    big_endian: bool;
    int_specs:   [..] Prim_Spec;
    float_specs: [..] Prim_Spec;
    vec_specs:   [..] Prim_Spec;
    ptr_specs:   [..] Ptr_Spec;
    struct_abi:  u64 = 1;
    struct_pref: u64 = 8;
    alloca_as:   u32;
    program_as:  u32;
    globals_as:  u32;
    stack_natural: u64;
}

dl: Data_Layout;

dl_set_prim :: (list: *[..] Prim_Spec, bits: u32, abi: u64, pref: u64) {
    for * list.* if it.bits == bits { it.abi = abi; it.pref = pref; return; }
    // keep sorted by bit width
    i := 0;
    while i < list.count && list.*[i].bits < bits i += 1;
    array_insert_at(list, .{bits, abi, pref}, i);
}
dl_set_ptr :: (as: u32, bits: u32, abi: u64, pref: u64, idx: u32) {
    for * dl.ptr_specs if it.as == as { it.bits = bits; it.abi = abi; it.pref = pref; it.idx_bits = idx; return; }
    i := 0;
    while i < dl.ptr_specs.count && dl.ptr_specs[i].as < as i += 1;
    array_insert_at(*dl.ptr_specs, .{as, bits, abi, pref, idx}, i);
}

dl_init :: (s: string) {
    dl = .{};
    dl_set_prim(*dl.int_specs, 8, 1, 1);
    dl_set_prim(*dl.int_specs, 16, 2, 2);
    dl_set_prim(*dl.int_specs, 32, 4, 4);
    dl_set_prim(*dl.int_specs, 64, 4, 8);
    dl_set_prim(*dl.float_specs, 16, 2, 2);
    dl_set_prim(*dl.float_specs, 32, 4, 4);
    dl_set_prim(*dl.float_specs, 64, 8, 8);
    dl_set_prim(*dl.float_specs, 128, 16, 16);
    dl_set_ptr(0, 64, 8, 8, 64);
    if s.count == 0 return;
    parts := split(s, "-",, allocator = temp);
    for part: parts {
        if part.count == 0 continue;
        c := part[0];
        rest := slice(part, 1, part.count - 1);
        nums := split(rest, ":",, allocator = temp);
        num :: (x: string) -> u64 { v, ok := string_to_int(x, 10, u64); return v; }
        if c == {
            case #char "e"; dl.big_endian = false;
            case #char "E"; dl.big_endian = true;
            case #char "i"; #through;
            case #char "f"; #through;
            case #char "v";
                bits := cast(u32) num(nums[0]);
                abi := ifx nums.count > 1 then num(nums[1]) / 8 else 0;
                pref := ifx nums.count > 2 then num(nums[2]) / 8 else abi;
                list := ifx c == #char "i" then *dl.int_specs else ifx c == #char "f" then *dl.float_specs else *dl.vec_specs;
                dl_set_prim(list, bits, abi, pref);
            case #char "p";
                as: u32 = 0;
                if nums[0].count as = cast(u32) num(nums[0]);
                bits := cast(u32) num(nums[1]);
                abi := num(nums[2]) / 8;
                pref := ifx nums.count > 3 then num(nums[3]) / 8 else abi;
                idx := ifx nums.count > 4 then cast(u32) num(nums[4]) else bits;
                dl_set_ptr(as, bits, abi, pref, idx);
            case #char "a";
                if nums.count > 1 { dl.struct_abi = max(num(nums[1]) / 8, 1); }
                if nums.count > 2 dl.struct_pref = num(nums[2]) / 8;
            case #char "A"; dl.alloca_as = cast(u32) num(rest);
            case #char "P"; dl.program_as = cast(u32) num(rest);
            case #char "G"; dl.globals_as = cast(u32) num(rest);
            case #char "S"; dl.stack_natural = num(rest) / 8;
        }
    }
}

dl_ptr_spec :: (as: u32) -> Ptr_Spec {
    for dl.ptr_specs if it.as == as return it;
    return dl.ptr_specs[0];
}

power_of_2_ceil :: (x: u64) -> u64 { r: u64 = 1; while r < x r <<= 1; return r; }
align_to :: inline (x: u64, a: u64) -> u64 { return (x + a - 1) / a * a; }

dl_int_align :: (bits: u32, abi: bool) -> u64 {
    i := 0;
    while i < dl.int_specs.count && dl.int_specs[i].bits < bits i += 1;
    if i == dl.int_specs.count i -= 1;
    return ifx abi then dl.int_specs[i].abi else dl.int_specs[i].pref;
}

dl_type_size_bits :: (t: Type_Id) -> u64 {
    r := ir.types[t];
    if r.kind == {
        case .LABEL; return dl_ptr_spec(0).bits;
        case .PTR; return dl_ptr_spec(cast(u32) r.a).bits;
        case .ARRAY; return r.a * dl_type_alloc_size(type_elem(t)) * 8;
        case .STRUCT; sz, al := dl_struct_layout(t); return sz * 8;
        case .INT; return r.a;
        case .BYTE; return r.a;
        case .HALF; return 16; case .BFLOAT; return 16; case .FLOAT; return 32; case .DOUBLE; return 64;
        case .PPC_FP128; return 128; case .FP128; return 128; case .X86_AMX; return 8192; case .X86_FP80; return 80;
        case .VECTOR; #through;
        case .SVECTOR; return r.a * dl_type_size_bits(type_elem(t));
    }
    return 0;
}
dl_type_store_size :: (t: Type_Id) -> u64 { return (dl_type_size_bits(t) + 7) / 8; }
dl_type_alloc_size :: (t: Type_Id) -> u64 { return align_to(dl_type_store_size(t), dl_abi_align(t)); }

dl_alignment :: (t: Type_Id, abi: bool) -> u64 {
    r := ir.types[t];
    if r.kind == {
        case .LABEL; s := dl_ptr_spec(0); return ifx abi then s.abi else s.pref;
        case .PTR; s := dl_ptr_spec(cast(u32) r.a); return ifx abi then s.abi else s.pref;
        case .ARRAY; return dl_alignment(type_elem(t), abi);
        case .STRUCT;
            if (r.flags & TYF_PACKED) && abi return 1;
            sz, al := dl_struct_layout(t);
            return max(ifx abi then dl.struct_abi else dl.struct_pref, al);
        case .BYTE; #through;
        case .INT; return dl_int_align(cast(u32) r.a, abi);
        case .HALF; #through;
        case .BFLOAT; #through;
        case .FLOAT; #through;
        case .DOUBLE; #through;
        case .PPC_FP128; #through;
        case .FP128; #through;
        case .X86_FP80;
            bits := cast(u32) dl_type_size_bits(t);
            for dl.float_specs if it.bits == bits return ifx abi then it.abi else it.pref;
            return power_of_2_ceil(bits / 8);
        case .VECTOR; #through;
        case .SVECTOR;
            bits := cast(u32) dl_type_size_bits(t);
            for dl.vec_specs if it.bits == bits return ifx abi then it.abi else it.pref;
            return power_of_2_ceil(dl_type_store_size(t));
        case .X86_AMX; return 64;
    }
    return 1;
}
dl_abi_align  :: (t: Type_Id) -> u64 { return dl_alignment(t, true); }
dl_pref_align :: (t: Type_Id) -> u64 {
    // DataLayout::getPrefTypeAlign
    return dl_alignment(t, false);
}

// StructLayout: returns (size in bytes, alignment).
dl_struct_layout :: (t: Type_Id) -> (u64, u64) {
    r := ir.types[t];
    size: u64 = 0;
    al: u64 = 1;
    if r.nsub > 0 for i: 0..r.nsub-1 {
        et := ir.type_list[r.sub + i];
        ta := ifx (r.flags & TYF_PACKED) then cast(u64) 1 else dl_abi_align(et);
        if size % ta != 0 size = align_to(size, ta);
        al = max(al, ta);
        size += dl_type_alloc_size(et);
    }
    if size % al != 0 size = align_to(size, al);
    return size, al;
}
dl_struct_offset :: (t: Type_Id, idx: u32) -> u64 {
    r := ir.types[t];
    size: u64 = 0;
    if r.nsub > 0 for i: 0..r.nsub-1 {
        et := ir.type_list[r.sub + i];
        ta := ifx (r.flags & TYF_PACKED) then cast(u64) 1 else dl_abi_align(et);
        if size % ta != 0 size = align_to(size, ta);
        if i == idx return size;
        size += dl_type_alloc_size(et);
    }
    return size;
}
