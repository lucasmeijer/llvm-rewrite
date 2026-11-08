// Port of the parts of llvm/lib/IR/DataLayout.cpp the IR core needs: spec parsing, type sizes and
// ABI/preferred alignment, struct layout.

Prim_Spec :: struct { bits: u32; abi: u64; pref: u64; }
Ptr_Spec  :: struct { as: u32; bits: u32; abi: u64; pref: u64; idx_bits: u32; unstable: bool; external: bool = false; null_all_ones: bool = false; }

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
    legal_ints:  [..] u32;   // "n" (DataLayout::LegalIntWidths)
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
    array_insert_at(*dl.ptr_specs, .{as, bits, abi, pref, idx, false, false, false}, i);
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
    non_integral: [..] u32; non_integral.allocator = temp;
    defer for as: non_integral {
        // "ni:<as>...": the address space gets its own spec (a copy of AS0's if it has none), marked unstable
        ps := dl_ptr_spec(as);
        dl_set_ptr(as, ps.bits, ps.abi, ps.pref, ps.idx_bits);
        for * dl.ptr_specs if it.as == as it.unstable = true;
    }
    for part: parts {
        if part.count == 0 continue;
        if begins_with(part, "ni:") {
            for x: split(slice(part, 3, part.count - 3), ":",, allocator = temp) { v, ok := string_to_int(x, 10, u32); array_add(*non_integral, v); }
            continue;
        }
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
                // DataLayout::parsePointerSpec flags: e (external state), u (unstable), z / o (null value)
                flags := nums[0];
                ext := false; uns := false; ones := false;
                while flags.count && (flags[0] == #char "e" || flags[0] == #char "u" || flags[0] == #char "z" || flags[0] == #char "o") {
                    if flags[0] == #char "e" ext = true;
                    else if flags[0] == #char "u" uns = true;
                    else if flags[0] == #char "o" ones = true;
                    flags = slice(flags, 1, flags.count - 1);
                }
                if flags.count && !(flags[0] >= #char "0" && flags[0] <= #char "9") fatal("datalayout: unsupported pointer specification '%'", part);
                if flags.count as = cast(u32) num(flags);
                bits := cast(u32) num(nums[1]);
                abi := num(nums[2]) / 8;
                pref := ifx nums.count > 3 then num(nums[3]) / 8 else abi;
                idx := ifx nums.count > 4 then cast(u32) num(nums[4]) else bits;
                dl_set_ptr(as, bits, abi, pref, idx);
                for * dl.ptr_specs if it.as == as { it.external = ext; if uns it.unstable = true; it.null_all_ones = ones; }
            case #char "a";
                if nums.count > 1 { dl.struct_abi = max(num(nums[1]) / 8, 1); }
                if nums.count > 2 dl.struct_pref = num(nums[2]) / 8;
            case #char "n";
                for nums array_add(*dl.legal_ints, cast(u32) num(it));
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

// DataLayout::isLegalInteger
dl_is_legal_integer :: (bits: u64) -> bool { for dl.legal_ints if it == bits return true; return false; }
// DataLayout::isNonIntegralAddressSpace
dl_ni_as :: (as: u32) -> bool { ps := dl_ptr_spec(as); return ps.bits != ps.idx_bits || ps.unstable || ps.external; }
dl_ni_ptr_type :: (t: Type_Id) -> bool { return type_kind(t) == .PTR && dl_ni_as(cast(u32) ir.types[t].a); }
// DataLayout::getIndexSizeInBits / getIndexTypeSizeInBits
dl_index_size_bits :: (as: u32) -> u32 { return dl_ptr_spec(as).idx_bits; }
dl_index_type_size_bits :: (t: Type_Id) -> u32 { return dl_index_size_bits(cast(u32) ir.types[scalar_type(t)].a); }
// DataLayout::typeSizeEqualsStoreSize
dl_size_eq_store_size :: (t: Type_Id) -> bool { return dl_type_size_bits(t) == dl_type_store_size(t) * 8; }

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
        case .TARGET_EXT; l := target_ext_layout_type(t); if type_kind(l) == .VOID return 0; return dl_type_size_bits(l);
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
        case .TARGET_EXT; l := target_ext_layout_type(t); if type_kind(l) == .VOID return 1; return dl_alignment(l, abi);
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

// Triple::computeDataLayout for x86 (llvm/lib/TargetParser/TargetDataLayout.cpp computeX86DataLayout).
// opt fills in this default when the module has a triple but no datalayout (llvm/tools/opt/optdriver.cpp).
compute_default_datalayout :: (triple: string) -> string, bool {
    parts := split(triple, "-",, allocator = temp);
    arch := parts[0];
    os := ifx parts.count > 2 then parts[2] else "";
    env := ifx parts.count > 3 then parts[3] else "";
    is64 := arch == "x86_64" || arch == "amd64" || arch == "x86_64h";
    is32 := arch == "i386" || arch == "i486" || arch == "i586" || arch == "i686" || arch == "i786" || arch == "i886" || arch == "i986" || arch == "x86";
    if !is64 && !is32 return "", false;
    darwin := begins_with(os, "darwin") || begins_with(os, "macos") || begins_with(os, "ios") || begins_with(os, "tvos") ||
              begins_with(os, "watchos") || begins_with(os, "driverkit") || begins_with(os, "xros");
    windows := begins_with(os, "windows") || begins_with(os, "win32");
    uefi := begins_with(os, "uefi");
    iamcu := begins_with(os, "elfiamcu");
    coff := (windows || uefi) && !contains(env, "elf") && !contains(env, "macho");
    msvc := windows && (begins_with(env, "msvc") || env.count == 0);
    x32 := begins_with(env, "gnux32") || begins_with(env, "muslx32");
    sb: String_Builder;
    append(*sb, "e");
    if darwin append(*sb, "-m:o");
    else if coff append(*sb, ifx is32 then "-m:x" else "-m:w");
    else append(*sb, "-m:e");
    if !is64 || x32 append(*sb, "-p:32:32");
    append(*sb, "-p270:32:32-p271:32:32-p272:64:64");
    if is64 || windows append(*sb, "-i64:64-i128:128");
    else if iamcu append(*sb, "-i64:32-f64:32");
    else append(*sb, "-i128:128-f64:32:64");
    if iamcu {}
    else if is64 || darwin || msvc append(*sb, "-f80:128");
    else append(*sb, "-f80:32");
    if iamcu append(*sb, "-f128:32");
    if is64 append(*sb, "-n8:16:32:64"); else append(*sb, "-n8:16:32");
    if (!is64 && windows) || iamcu append(*sb, "-a:0:32-S32"); else append(*sb, "-S128");
    return builder_to_string(*sb), true;
}

// TargetExtType::getLayoutType (llvm/lib/IR/Type.cpp getTargetTypeInfo)
target_ext_layout_type :: (t: Type_Id) -> Type_Id {
    r := ir.types[t];
    name := r.name;
    ip :: (r: Type_Row, i: u32) -> u64 { return ir.type_list[r.ints + i]; }
    if name == "spirv.Image" || name == "spirv.SignedImage" return type_ptr(0);
    if name == "spirv.Type" {
        size := ip(r, 1); al := ip(r, 2);
        if size > 0 && al > 0 return type_array(size * 8 / al, type_int(al));
        return ir.t_i32;
    }
    if name == "spirv.IntegralConstant" || name == "spirv.Literal" return ir.t_void;
    if name == "spirv.Padding" return type_array(ip(r, 0), ir.t_i8);
    if begins_with(name, "spirv.") return type_ptr(0);
    if name == "aarch64.svcount" return type_vector(16, ir.t_i1, true);
    if name == "riscv.vector.tuple" {
        n := max(type_count(type_sub(t, 0)), 8) * ip(r, 0);
        return type_vector(n, ir.t_i8, true);
    }
    if name == "dx.Padding" return type_array(ip(r, 0), ir.t_i8);
    if begins_with(name, "dx.") return type_ptr(0);
    if name == "amdgcn.named.barrier" return type_vector(4, ir.t_i32, false);
    if name == "llvm.test.vectorelement" return ir.t_i32;
    if name == "wasm.funcref" || name == "wasm.externref" return type_ptr(0);
    return ir.t_void;
}
