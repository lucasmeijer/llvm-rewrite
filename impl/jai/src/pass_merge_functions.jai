// MergeFunctions: merge functions that are equivalent (thunks, aliases, or direct replacement).
// Ported from llvm/lib/Transforms/IPO/MergeFunctions.cpp (MergeFunctions::run/insert/remove/removeUsers,
// mergeTwoFunctions, writeThunk, writeAlias, replaceDirectCallers), llvm/lib/Transforms/Utils/FunctionComparator.cpp
// (FunctionComparator, GlobalNumberState), llvm/lib/IR/StructuralHash.cpp (StructuralHash(F), non-detailed) and
// llvm/lib/Support/xxhash.cpp (xxh3_64bits).
//
// The FnTree (a std::set ordered by (hash, FunctionComparator)) is a list of nodes searched for an equal element:
// insertion only needs equality (compare() == 0, which does not depend on GlobalNumberState's numbering), and a set
// holds at most one element equal to a key, so the result is the same as the tree's. Deferred entries are
// WeakTrackingVHs: they follow replaceAllUsesWith of a function (mf.fwd) and become null when it is erased.
// -mergefunc-preserve-debug-info (MergeFunctionsPDI) fails loudly.

// ---------------------------------------------------------------- xxh3_64bits

XXH_SECRET :: u8.[
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
];
XXH_PRIME32_1 : u64 : 0x9E3779B1;
XXH_PRIME32_2 : u64 : 0x85EBCA77;
XXH_PRIME32_3 : u64 : 0xC2B2AE3D;
XXH_PRIME64_1 : u64 : 11400714785074694791;
XXH_PRIME64_2 : u64 : 14029467366897019727;
XXH_PRIME64_3 : u64 : 1609587929392839161;
XXH_PRIME64_4 : u64 : 9650029242287828579;
XXH_PRIME64_5 : u64 : 2870177450012600261;
XXH_PRIME_MX1 : u64 : 0x165667919E3779F9;
XXH_PRIME_MX2 : u64 : 0x9FB21C651E98DF25;

xxh_r64 :: inline (p: *u8) -> u64 { return (cast(*u64) p).*; }
xxh_r32 :: inline (p: *u8) -> u64 { return cast(u64) (cast(*u32) p).*; }
xxh_rotl :: inline (x: u64, r: u64) -> u64 { return (x << r) | (x >> (64 - r)); }
xxh_bswap64 :: (x: u64) -> u64 {
    r: u64 = 0;
    for 0..7 r |= ((x >> cast(u64) (8 * it)) & 0xff) << cast(u64) (56 - 8 * it);
    return r;
}
xxh_bswap32 :: (x: u64) -> u64 {
    return ((x & 0xff) << 24) | ((x & 0xff00) << 8) | ((x >> 8) & 0xff00) | ((x >> 24) & 0xff);
}
xxh_mul128_fold64 :: (lhs: u64, rhs: u64) -> u64 {
    lo_lo := (lhs & 0xFFFFFFFF) * (rhs & 0xFFFFFFFF);
    hi_lo := (lhs >> 32) * (rhs & 0xFFFFFFFF);
    lo_hi := (lhs & 0xFFFFFFFF) * (rhs >> 32);
    hi_hi := (lhs >> 32) * (rhs >> 32);
    cross := (lo_lo >> 32) + (hi_lo & 0xFFFFFFFF) + lo_hi;
    upper := (hi_lo >> 32) + (cross >> 32) + hi_hi;
    lower := (cross << 32) | (lo_lo & 0xFFFFFFFF);
    return upper ^ lower;
}
xxh64_avalanche :: (h_in: u64) -> u64 {
    h := h_in;
    h ^= h >> 33; h *= XXH_PRIME64_2; h ^= h >> 29; h *= XXH_PRIME64_3; h ^= h >> 32;
    return h;
}
xxh3_avalanche :: (h_in: u64) -> u64 {
    h := h_in;
    h ^= h >> 37; h *= XXH_PRIME_MX1; h ^= h >> 32;
    return h;
}
xxh3_mix16b :: (input: *u8, secret: *u8) -> u64 {
    lhs := xxh_r64(secret) ^ xxh_r64(input);
    rhs := xxh_r64(secret + 8) ^ xxh_r64(input + 8);
    return xxh_mul128_fold64(lhs, rhs);
}
xxh3_accumulate_512 :: (acc: *[8] u64, input: *u8, secret: *u8) {
    for i: 0..7 {
        data_val := xxh_r64(input + 8 * i);
        data_key := data_val ^ xxh_r64(secret + 8 * i);
        acc.*[i ^ 1] += data_val;
        acc.*[i] += (data_key & 0xFFFFFFFF) * (data_key >> 32);
    }
}
xxh3_scramble_acc :: (acc: *[8] u64, secret: *u8) {
    for i: 0..7 {
        acc.*[i] ^= acc.*[i] >> 47;
        acc.*[i] ^= xxh_r64(secret + 8 * i);
        acc.*[i] *= XXH_PRIME32_1;
    }
}
// llvm::xxh3_64bits (seed 0, the default secret)
xxh3_64bits :: (data: [] u8) -> u64 {
    secret := XXH_SECRET.data;
    input := data.data;
    len := cast(u64) data.count;
    if len <= 16 {
        if len > 8 {
            input_lo := xxh_r64(secret + 24) ^ xxh_r64(secret + 32);
            input_hi := xxh_r64(secret + 40) ^ xxh_r64(secret + 48);
            input_lo ^= xxh_r64(input);
            input_hi ^= xxh_r64(input + len - 8);
            acc := len + xxh_bswap64(input_lo) + input_hi + xxh_mul128_fold64(input_lo, input_hi);
            return xxh3_avalanche(acc);
        }
        if len >= 4 {
            input1 := xxh_r32(input);
            input2 := xxh_r32(input + len - 4);
            acc := xxh_r64(secret + 8) ^ xxh_r64(secret + 16);
            acc ^= input2 | (input1 << 32);
            acc ^= xxh_rotl(acc, 49) ^ xxh_rotl(acc, 24);
            acc *= XXH_PRIME_MX2;
            acc ^= (acc >> 35) + len;
            acc *= XXH_PRIME_MX2;
            return acc ^ (acc >> 28);
        }
        if len != 0 {
            c1 := cast(u64) input[0]; c2 := cast(u64) input[len >> 1]; c3 := cast(u64) input[len - 1];
            combined := (c1 << 16) | (c2 << 24) | c3 | (len << 8);
            bitflip := (xxh_r32(secret) ^ xxh_r32(secret + 4));
            return xxh64_avalanche(combined ^ bitflip);
        }
        return xxh64_avalanche(xxh_r64(secret + 56) ^ xxh_r64(secret + 64));
    }
    if len <= 128 {
        acc := len * XXH_PRIME64_1;
        acc += xxh3_mix16b(input, secret);
        acc_end := xxh3_mix16b(input + len - 16, secret + 16);
        if len > 32 {
            acc += xxh3_mix16b(input + 16, secret + 32);
            acc_end += xxh3_mix16b(input + len - 32, secret + 48);
            if len > 64 {
                acc += xxh3_mix16b(input + 32, secret + 64);
                acc_end += xxh3_mix16b(input + len - 48, secret + 80);
                if len > 96 {
                    acc += xxh3_mix16b(input + 48, secret + 96);
                    acc_end += xxh3_mix16b(input + len - 64, secret + 112);
                }
            }
        }
        return xxh3_avalanche(acc + acc_end);
    }
    if len <= 240 {
        acc := len * XXH_PRIME64_1;
        nb_rounds := len / 16;
        for i: 0..7 acc += xxh3_mix16b(input + 16 * i, secret + 16 * i);
        acc = xxh3_avalanche(acc);
        i: u64 = 8;
        while i < nb_rounds { acc += xxh3_mix16b(input + 16 * i, secret + 16 * (i - 8) + 3); i += 1; }
        acc += xxh3_mix16b(input + len - 16, secret + 136 - 17);
        return xxh3_avalanche(acc);
    }
    // XXH3_hashLong_64b
    secret_size: u64 = 192;
    stripes_per_block := (secret_size - 64) / 8;
    block_len := 64 * stripes_per_block;
    nb_blocks := (len - 1) / block_len;
    acc: [8] u64 = .[XXH_PRIME32_3, XXH_PRIME64_1, XXH_PRIME64_2, XXH_PRIME64_3, XXH_PRIME64_4, XXH_PRIME32_2, XXH_PRIME64_5, XXH_PRIME32_1];
    n: u64 = 0;
    while n < nb_blocks {
        for s: 0..stripes_per_block - 1 xxh3_accumulate_512(*acc, input + n * block_len + s * 64, secret + s * 8);
        xxh3_scramble_acc(*acc, secret + secret_size - 64);
        n += 1;
    }
    nb_stripes := (len - 1 - block_len * nb_blocks) / 64;
    s: u64 = 0;
    while s < nb_stripes { xxh3_accumulate_512(*acc, input + nb_blocks * block_len + s * 64, secret + s * 8); s += 1; }
    xxh3_accumulate_512(*acc, input + len - 64, secret + secret_size - 64 - 7);
    result := len * XXH_PRIME64_1;
    key := secret + 11;
    for k: 0..3 result += xxh_mul128_fold64(acc[2 * k] ^ xxh_r64(key + 16 * k), acc[2 * k + 1] ^ xxh_r64(key + 16 * k + 8));
    return xxh3_avalanche(result);
}
// stable_hash_combine(ArrayRef<stable_hash>)
stable_hash_combine :: (hs: [] u64) -> u64 {
    d: [] u8; d.data = cast(*u8) hs.data; d.count = hs.count * 8;
    return xxh3_64bits(d);
}

// StructuralHash(F, DetailedHash = false)
mf_structural_hash :: (f: Value_Id) -> u64 {
    if is_declaration(f) return 4;
    hs: [..] u64; hs.allocator = temp;
    array_add(*hs, 4);
    array_add(*hs, 0x62642d6b6b2d6b72);   // FunctionHeaderHash
    array_add(*hs, ifx func_vararg(glob(f).value_type) then cast(u64) 1 else 0);
    array_add(*hs, glob(f).nargs);
    stack: [..] Value_Id; stack.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    entry := glob(f).first_block;
    array_add(*stack, entry);
    table_set(*visited, entry, true);
    while stack.count {
        b := pop(*stack);
        array_add(*hs, 45798);   // BlockHeaderHash
        for i: block_insts(b) {
            opc: [1] u64;
            opc[0] = cast(u64) inst_op(i);
            array_add(*hs, stable_hash_combine(opc));
        }
        t := block_terminator(b);
        if t != NONE {
            ns := num_successors(t);
            if ns > 0 for k: 0..ns - 1 {
                s := get_successor(t, k);
                if table_contains(*visited, s) continue;
                table_set(*visited, s, true);
                array_add(*stack, s);
            }
        }
    }
    return stable_hash_combine(hs);
}

// ---------------------------------------------------------------- FunctionComparator

Fn_Cmp :: struct {
    fl, fr: Value_Id;
    sn_l: Table(Value_Id, u32);
    sn_r: Table(Value_Id, u32);
}
mf_global_numbers: Table(Value_Id, u64);   // GlobalNumberState
mf_next_number: u64;

fc_num :: inline (l: u64, r: u64) -> s32 { if l < r return -1; if l > r return 1; return 0; }
fc_snum :: inline (l: s64, r: s64) -> s32 { if l < r return -1; if l > r return 1; return 0; }

fc_ap :: (l: Value_Id, r: Value_Id) -> s32 {
    // cmpAPInts on two ConstantInt / ConstantFP bit patterns of the same width
    wl := const_int_value(l); wr := const_int_value(r);
    if wl.count != wr.count return fc_num(cast(u64) wl.count, cast(u64) wr.count);
    k := wl.count - 1;
    while k >= 0 { if wl[k] != wr[k] return fc_num(wl[k], wr[k]); k -= 1; }
    return 0;
}

// DL.getIntPtrType for pointers in address space 0 (cmpTypes compares those as integers)
fc_norm_type :: (t: Type_Id) -> Type_Id {
    if type_kind(t) == .PTR && ir.types[t].a == 0 return type_int(dl_ptr_size_bits_as(0));
    return t;
}
// Type::getTypeID order
fc_type_id :: (k: Type_Kind) -> u64 {
    if k == {
        case .HALF; return 0; case .BFLOAT; return 1; case .FLOAT; return 2; case .DOUBLE; return 3;
        case .X86_FP80; return 4; case .FP128; return 5; case .PPC_FP128; return 6; case .VOID; return 7;
        case .LABEL; return 8; case .METADATA; return 9; case .X86_AMX; return 10; case .TOKEN; return 11;
        case .INT; return 12; case .BYTE; return 13; case .FUNC; return 14; case .PTR; return 15;
        case .STRUCT; return 16; case .ARRAY; return 17; case .VECTOR; return 18; case .SVECTOR; return 19;
        case .TARGET_EXT; return 21;
    }
    return 99;
}
fc_types :: (c: *Fn_Cmp, tl_in: Type_Id, tr_in: Type_Id) -> s32 {
    tl := fc_norm_type(tl_in); tr := fc_norm_type(tr_in);
    if tl == tr return 0;
    kl := type_kind(tl); kr := type_kind(tr);
    res := fc_num(fc_type_id(kl), fc_type_id(kr));
    if res return res;
    if kl == {
        case .INT; return fc_num(ir.types[tl].a, ir.types[tr].a);
        case .PTR; return fc_num(ir.types[tl].a, ir.types[tr].a);
        case .STRUCT;
            nl := type_nsub(tl); nr := type_nsub(tr);
            if nl != nr return fc_num(nl, nr);
            pl := (ir.types[tl].flags & TYF_PACKED) != 0; pr := (ir.types[tr].flags & TYF_PACKED) != 0;
            if pl != pr return fc_num(cast(u64) pl, cast(u64) pr);
            if nl > 0 for i: 0..nl - 1 { r := fc_types(c, type_sub(tl, i), type_sub(tr, i)); if r return r; }
            return 0;
        case .FUNC;
            nl := func_nparams(tl); nr := func_nparams(tr);
            if nl != nr return fc_num(nl, nr);
            vl := func_vararg(tl); vr := func_vararg(tr);
            if vl != vr return fc_num(cast(u64) vl, cast(u64) vr);
            r := fc_types(c, func_ret(tl), func_ret(tr)); if r return r;
            if nl > 0 for i: 0..nl - 1 { r2 := fc_types(c, func_param(tl, i), func_param(tr, i)); if r2 return r2; }
            return 0;
        case .ARRAY; #through;
        case .VECTOR; #through;
        case .SVECTOR;
            if type_count(tl) != type_count(tr) return fc_num(type_count(tl), type_count(tr));
            return fc_types(c, type_elem(tl), type_elem(tr));
        case .TARGET_EXT;
            fatal("mergefunc: comparing target extension types is not supported yet");
    }
    return 0;   // void, fp, label, metadata, token
}

fc_mem :: (l: string, r: string) -> s32 {
    res := fc_num(cast(u64) l.count, cast(u64) r.count);
    if res return res;
    c := compare(l, r);
    if c < 0 return -1;
    if c > 0 return 1;
    return 0;
}

fc_global_values :: (l: Value_Id, r: Value_Id) -> s32 {
    get :: (g: Value_Id) -> u64 {
        found, n := table_find(*mf_global_numbers, g);
        if found return n;
        n = mf_next_number; mf_next_number += 1;
        table_set(*mf_global_numbers, g, n);
        return n;
    }
    return fc_num(get(l), get(r));
}

// LLVM's Value::getValueID order for the constant kinds (only equality matters for merging)
fc_value_id :: (v: Value_Id) -> u64 {
    k := vkind(v);
    if k == .C_DATA return ifx is_vector_type(vtype(v)) then cast(u64) 101 else 100;
    return cast(u64) k;
}
// ConstantDataSequential::getRawDataValues
fc_raw_data :: (v: Value_Id) -> string {
    et := type_elem(vtype(v));
    bytes := cast(s64) (type_bits(et) / 8);
    n := cast(s64) const_data_count(v);
    s: string; s.data = alloc(n * bytes,, temp); s.count = n * bytes;
    for i: 0..n - 1 {
        w := const_data_elt(v, cast(u64) i);
        for b: 0..bytes - 1 s.data[i * bytes + b] = cast,trunc(u8) (w >> cast(u64) (8 * b));
    }
    return s;
}

fc_constants :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> s32 {
    tl := vtype(l); tr := vtype(r);
    types_res := fc_types(c, tl, tr);
    if types_res != 0 {
        if !is_first_class(tl) { if is_first_class(tr) return -1; return types_res; }
        if !is_first_class(tr) { if is_first_class(tl) return 1; return types_res; }
        wl: u64 = 0; wr: u64 = 0;
        if is_vector_type(tl) wl = type_count(tl) * type_bits_any(type_elem(tl));
        if is_vector_type(tr) wr = type_count(tr) * type_bits_any(type_elem(tr));
        if wl != wr return fc_num(wl, wr);
        if wl == 0 {
            pl := type_kind(tl) == .PTR; pr := type_kind(tr) == .PTR;
            if pl && pr { res := fc_num(ir.types[tl].a, ir.types[tr].a); if res return res; }
            if pl return 1;
            if pr return -1;
            return types_res;
        }
    }
    nl := is_null_value(l); nr := is_null_value(r);
    if nl && nr return types_res;
    if nl && !nr return 1;
    if !nl && nr return -1;
    if is_global_value(vkind(l)) && is_global_value(vkind(r)) return fc_global_values(l, r);
    res := fc_num(fc_value_id(l), fc_value_id(r));
    if res return res;
    k := vkind(l);
    if k == {
        case .C_DATA; return fc_mem(fc_raw_data(l), fc_raw_data(r));
        case .C_UNDEF; #through;
        case .C_POISON; #through;
        case .C_TOKEN_NONE; return types_res;
        case .C_INT; return fc_ap(l, r);
        case .C_FP;
            // cmpAPFloats: the semantics (precision, exponents, size), then the bits
            sl := type_kind(scalar_type(tl)); sr := type_kind(scalar_type(tr));
            pl, xl, ml, bl := fp_semantics(sl); pr, xr, mr, br := fp_semantics(sr);
            r1 := fc_snum(pl, pr); if r1 return r1;
            r2 := fc_snum(xl, xr); if r2 return r2;
            r3 := fc_snum(ml, mr); if r3 return r3;
            r4 := fc_snum(bl, br); if r4 return r4;
            return fc_ap(l, r);
        case .C_ARRAY; #through;
        case .C_STRUCT; #through;
        case .C_VECTOR;
            a := nops(l); b := nops(r);
            if a != b return fc_num(a, b);
            if a > 0 for i: 0..a - 1 { x := fc_constants(c, op(l, i), op(r, i)); if x return x; }
            return 0;
        case .C_EXPR;
            el := cexpr(l); er := cexpr(r);
            r0 := fc_num(cast(u64) el.op, cast(u64) er.op); if r0 return r0;
            a := nops(l); b := nops(r);
            if a != b return fc_num(a, b);
            if a > 0 for i: 0..a - 1 { x := fc_constants(c, op(l, i), op(r, i)); if x return x; }
            if el.op == .GEP {
                rt := fc_types(c, el.ty2, er.ty2); if rt return rt;
                GEP_NW :: F_INBOUNDS | F_NUSW | F_GEP_NUW;
                rf := fc_num(el.flags & GEP_NW, er.flags & GEP_NW); if rf return rf;
                // getInRange: the (lo, hi) pair in the expression's index words; compared as signed APInts of
                // the index width (only equality matters here)
                il := (el.flags & F_INRANGE) != 0; irr := (er.flags & F_INRANGE) != 0;
                if il {
                    if !irr return 1;
                    for k: 0..3 { x := fc_num(ir.u32_pool[el.idx + cast(u32) k], ir.u32_pool[er.idx + cast(u32) k]); if x return x; }
                } else if irr return -1;
            }
            if el.op == .ADD || el.op == .SUB || el.op == .MUL || el.op == .SHL {
                ru := fc_num(cast(u64) ((el.flags & F_NUW) != 0), cast(u64) ((er.flags & F_NUW) != 0)); if ru return ru;
                rs := fc_num(cast(u64) ((el.flags & F_NSW) != 0), cast(u64) ((er.flags & F_NSW) != 0)); if rs return rs;
            }
            return 0;
        case .C_BLOCKADDR;
            rv := fc_values(c, op(l, 0), op(r, 0)); if rv return rv;
            if op(l, 0) == op(r, 0) {
                lb := op(l, 1); rb := op(r, 1);
                if lb == rb return 0;
                for bb: fn_blocks(op(l, 0)) { if bb == lb return -1; if bb == rb return 1; }
                return -1;
            }
            return fc_values(c, op(l, 1), op(r, 1));
        case .C_DSO_EQUIV; return fc_global_values(op(l, 0), op(r, 0));
        case .C_PTRAUTH;
            for i: 0..3 { x := fc_constants(c, op(l, cast(u32) i), op(r, cast(u32) i)); if x return x; }
            return 0;
    }
    fatal("mergefunc: comparing constants of kind % is not supported", k);
    return -1;
}
type_bits_any :: (t: Type_Id) -> u64 {
    if type_kind(t) == .PTR return dl_ptr_size_bits_as(cast(u32) ir.types[t].a);
    return type_bits(t);
}

// cmpMetadata: MDStrings by content, ConstantAsMetadata by constant, anything else is equal
fc_metadata :: (c: *Fn_Cmp, l: Md_Id, r: Md_Id) -> s32 {
    sl := l != NONE && ir.mds[l].kind == .STRING;
    sr := r != NONE && ir.mds[r].kind == .STRING;
    if sl && sr {
        if l == r return 0;
        x := compare(ir.mds[l].str, ir.mds[r].str);
        return ifx x < 0 then cast(s32) -1 else ifx x > 0 then cast(s32) 1 else 0;
    }
    if sr return -1;
    if sl return 1;
    cl: Value_Id = NONE; cr: Value_Id = NONE;
    if l != NONE && ir.mds[l].kind == .VALUE && is_constant_kind(vkind(ir.mds[l].value)) cl = ir.mds[l].value;
    if r != NONE && ir.mds[r].kind == .VALUE && is_constant_kind(vkind(ir.mds[r].value)) cr = ir.mds[r].value;
    if cl == NONE && cr == NONE return 0;
    if cl == NONE return -1;
    if cr == NONE return 1;
    if cl == cr return 0;
    return fc_constants(c, cl, cr);
}
fc_md_node :: (c: *Fn_Cmp, l: Md_Id, r: Md_Id) -> s32 {
    if l == r return 0;
    if l == NONE return -1;
    if r == NONE return 1;
    res := fc_num(ir.mds[l].nops, ir.mds[r].nops);
    if res return res;
    n := ir.mds[l].nops;
    if n > 0 for i: 0..n - 1 { x := fc_metadata(c, md_op(l, i), md_op(r, i)); if x return x; }
    return 0;
}
fc_inst_metadata :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> s32 {
    ml: [..] Kind_Md; ml.allocator = temp; mr: [..] Kind_Md; mr.allocator = temp;
    get_all_metadata(l, *ml); get_all_metadata(r, *mr);
    strip :: (a: *[..] Kind_Md) { k := 0; for a.* if it.kind != MDK_DBG { a.*[k] = it; k += 1; } a.count = k; }
    strip(*ml); strip(*mr);
    if ml.count > mr.count return 1;
    if ml.count < mr.count return -1;
    for ml {
        x := fc_num(it.kind, mr[it_index].kind); if x return x;
        y := fc_md_node(c, it.md, mr[it_index].md); if y return y;
    }
    return 0;
}

// AttributeList::getNumAttrSets
fc_num_attr_sets :: (l: u32) -> u64 {
    if l == 0 return 0;
    row := ir.attr_lists[l];
    if row.params.count return cast(u64) (2 + row.params.count);
    if row.ret return 2;
    if row.fn return 1;
    return 0;
}
fc_attr_set :: (c: *Fn_Cmp, sl: u32, sr: u32) -> s32 {
    al := attr_set_items(sl); ar := attr_set_items(sr);
    n := min(al.count, ar.count);
    for i: 0..n - 1 {
        a := *al[i]; b := *ar[i];
        if is_type_attr(a.kind) && is_type_attr(b.kind) {
            if a.kind != b.kind return fc_num(cast(u64) a.kind, cast(u64) b.kind);
            if a.ty != NONE && b.ty != NONE { x := fc_types(c, a.ty, b.ty); if x return x; continue; }
            x := fc_num(cast(u64) (a.ty != NONE), cast(u64) (b.ty != NONE)); if x return x;
            continue;
        }
        if (a.kind == .Range || a.kind == .Initializes) && a.kind == b.kind {
            // cmpConstantRanges / the ConstantRangeList: bit width, then the bounds
            x := fc_num(a.ival, b.ival); if x return x;
            y := fc_num(cast(u64) a.lo.count, cast(u64) b.lo.count); if y return y;
            for a.lo { z := fc_num(it, b.lo[it_index]); if z return z; }
            for a.hi { z := fc_num(it, b.hi[it_index]); if z return z; }
            continue;
        }
        if attr_less(a, b) return -1;
        if attr_less(b, a) return 1;
    }
    if al.count > ar.count return 1;
    if ar.count > al.count return -1;
    return 0;
}
fc_attrs :: (c: *Fn_Cmp, l: u32, r: u32) -> s32 {
    res := fc_num(fc_num_attr_sets(l), fc_num_attr_sets(r));
    if res return res;
    x := fc_attr_set(c, attr_list_fn(l), attr_list_fn(r)); if x return x;
    y := fc_attr_set(c, attr_list_ret(l), attr_list_ret(r)); if y return y;
    np := fc_num_attr_sets(l);
    if np > 2 for k: 0..np - 3 { z := fc_attr_set(c, attr_list_param(l, cast(u32) k), attr_list_param(r, cast(u32) k)); if z return z; }
    return 0;
}

fc_inline_asm :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> s32 {
    if l == r return 0;
    a := inline_asms[ir.v_aux[l]]; b := inline_asms[ir.v_aux[r]];
    x := fc_types(c, a.fty, b.fty); if x return x;
    y := fc_mem(a.asm_str, b.asm_str); if y return y;
    z := fc_mem(a.constraints, b.constraints); if z return z;
    return fc_num(a.flags, b.flags);   // side effects, align stack, dialect, can throw
}

fc_values :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> s32 {
    if l == c.fl { if r == c.fr return 0; return -1; }
    if r == c.fr { if l == c.fl return 0; return 1; }
    kl := vkind(l); kr := vkind(r);
    cl := is_constant_kind(kl); cr := is_constant_kind(kr);
    if cl && cr { if l == r return 0; return fc_constants(c, l, r); }
    if cl return 1;
    if cr return -1;
    ml := kl == .MD_VALUE; mr := kr == .MD_VALUE;
    if ml && mr { if l == r return 0; return fc_metadata(c, cast(Md_Id) ir.v_aux[l], cast(Md_Id) ir.v_aux[r]); }
    if ml return 1;
    if mr return -1;
    il := kl == .INLINE_ASM; irr := kr == .INLINE_ASM;
    if il && irr return fc_inline_asm(c, l, r);
    if il return 1;
    if irr return -1;
    found_l, nl := table_find(*c.sn_l, l);
    if !found_l { nl = cast(u32) c.sn_l.count; table_set(*c.sn_l, l, nl); }
    found_r, nr := table_find(*c.sn_r, r);
    if !found_r { nr = cast(u32) c.sn_r.count; table_set(*c.sn_r, r, nr); }
    return fc_num(nl, nr);
}

// getRawSubclassOptionalData: the wrap / exact / disjoint / nneg / samesign / GEP no-wrap / fast-math flags
FC_OPTIONAL_DATA :: F_NUW | F_NSW | F_EXACT | F_INBOUNDS | F_NUSW | F_GEP_NUW | (FMF_ALL << FMF_SHIFT);

fc_geps :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> s32 {
    asl := ir.types[scalar_type(vtype(op(l, 0)))].a; asr := ir.types[scalar_type(vtype(op(r, 0)))].a;
    res := fc_num(asl, asr);
    if res return res;
    bw := dl_index_size_bits(cast(u32) asl);
    okl, offl := gep_accumulate_constant_offset(l, ap_zero(bw));
    if okl {
        okr, offr := gep_accumulate_constant_offset(r, ap_zero(bw));
        if okr {
            if ap_ugt(offl, offr) return 1;
            if ap_ugt(offr, offl) return -1;
            return 0;
        }
    }
    x := fc_types(c, inst(l).ty2, inst(r).ty2); if x return x;
    y := fc_num(nops(l), nops(r)); if y return y;
    n := nops(l);
    for i: 0..n - 1 { z := fc_values(c, op(l, i), op(r, i)); if z return z; }
    return 0;
}

// cmpOperations; need_operands is false for GEPs (compared here completely)
fc_operations :: (c: *Fn_Cmp, l: Value_Id, r: Value_Id) -> (s32, bool) {
    res := fc_values(c, l, r);
    if res return res, true;
    ol := inst_op(l); orr := inst_op(r);
    res = fc_num(cast(u64) ol, cast(u64) orr);
    if res return res, true;
    if ol == .GEP {
        x := fc_values(c, op(l, 0), op(r, 0)); if x return x, false;
        return fc_geps(c, l, r), false;
    }
    res = fc_num(nops(l), nops(r)); if res return res, true;
    res = fc_types(c, vtype(l), vtype(r)); if res return res, true;
    res = fc_num(inst(l).flags & FC_OPTIONAL_DATA, inst(r).flags & FC_OPTIONAL_DATA); if res return res, true;
    n := nops(l);
    if n > 0 for i: 0..n - 1 { x := fc_types(c, vtype(op(l, i)), vtype(op(r, i))); if x return x, true; }
    a := inst(l); b := inst(r);
    vol :: (i: *Inst_Row) -> u64 { return cast(u64) ((i.flags & F_VOLATILE) != 0); }
    if ol == {
        case .ALLOCA;
            x := fc_types(c, a.ty2, b.ty2); if x return x, true;
            return fc_num(a.align, b.align), true;
        case .LOAD;
            x := fc_num(vol(a), vol(b)); if x return x, true;
            x = fc_num(a.align, b.align); if x return x, true;
            x = fc_num(a.ord1, b.ord1); if x return x, true;
            x = fc_num(a.sync, b.sync); if x return x, true;
            return fc_inst_metadata(c, l, r), true;
        case .STORE;
            x := fc_num(vol(a), vol(b)); if x return x, true;
            x = fc_num(a.align, b.align); if x return x, true;
            x = fc_num(a.ord1, b.ord1); if x return x, true;
            return fc_num(a.sync, b.sync), true;
        case .ICMP; #through;
        case .FCMP; return fc_num(a.pred, b.pred), true;
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR;
            x := fc_num(a.cc, b.cc); if x return x, true;
            x = fc_attrs(c, a.attrs, b.attrs); if x return x, true;
            // cmpOperandBundlesSchema
            x = fc_num(call_num_bundles(l), call_num_bundles(r)); if x return x, true;
            nb := call_num_bundles(l);
            if nb > 0 for k: 0..nb - 1 {
                t := compare(call_bundle_tag(l, k), call_bundle_tag(r, k));
                if t return ifx t < 0 then cast(s32) -1 else 1, true;
                b1, e1 := call_bundle_range(l, k); b2, e2 := call_bundle_range(r, k);
                y := fc_num(e1 - b1, e2 - b2); if y return y, true;
            }
            if ol == .CALL { x = fc_num((a.flags >> TAIL_SHIFT) & 3, (b.flags >> TAIL_SHIFT) & 3); if x return x, true; }
            rk := md_kind_id("range");
            return fc_md_node(c, get_metadata(l, rk), get_metadata(r, rk)), true;
        case .SWITCH;
            nc := min(switch_num_cases(l), switch_num_cases(r));
            if nc > 0 for k: 0..nc - 1 { x := fc_constants(c, switch_case_value_at(l, k), switch_case_value_at(r, k)); if x return x, true; }
            return 0, true;
        case .INSERTVALUE; #through;
        case .EXTRACTVALUE; #through;
        case .SHUFFLEVECTOR;
            il := inst_indices(l); ir_ := inst_indices(r);
            x := fc_num(cast(u64) il.count, cast(u64) ir_.count); if x return x, true;
            for il { y := fc_num(it, ir_[it_index]); if y return y, true; }
            if ol == .INSERTVALUE return 0, true;
        case .FENCE;
            x := fc_num(a.ord1, b.ord1); if x return x, true;
            return fc_num(a.sync, b.sync), true;
        case .CMPXCHG;
            x := fc_num(vol(a), vol(b)); if x return x, true;
            x = fc_num(cast(u64) ((a.flags & F_WEAK) != 0), cast(u64) ((b.flags & F_WEAK) != 0)); if x return x, true;
            x = fc_num(a.ord1, b.ord1); if x return x, true;
            x = fc_num(a.ord2, b.ord2); if x return x, true;
            return fc_num(a.sync, b.sync), true;
        case .ATOMICRMW;
            x := fc_num(a.ord2, b.ord2); if x return x, true;
            x = fc_num(vol(a), vol(b)); if x return x, true;
            x = fc_num(a.ord1, b.ord1); if x return x, true;
            return fc_num(a.sync, b.sync), true;
        case .PHI;
            for k: 0..n - 1 { x := fc_values(c, phi_block(l, k), phi_block(r, k)); if x return x, true; }
    }
    return 0, true;
}

fc_basic_blocks :: (c: *Fn_Cmp, bl: Value_Id, br: Value_Id) -> s32 {
    il := block(bl).first; ir_ := block(br).first;
    while true {
        res, need := fc_operations(c, il, ir_);
        if res return res;
        if need {
            n := nops(il);
            if n > 0 for i: 0..n - 1 { x := fc_values(c, op(il, i), op(ir_, i)); if x return x; }
        }
        il = inst(il).next; ir_ = inst(ir_).next;
        if il == NONE || ir_ == NONE break;
    }
    if il != NONE && ir_ == NONE return 1;
    if il == NONE && ir_ != NONE return -1;
    return 0;
}

fc_compare_signature :: (c: *Fn_Cmp) -> s32 {
    l := glob(c.fl); r := glob(c.fr);
    x := fc_attrs(c, l.attrs, r.attrs); if x return x;
    x = fc_num(cast(u64) (l.gc.count != 0), cast(u64) (r.gc.count != 0)); if x return x;
    if l.gc.count { x = fc_mem(l.gc, r.gc); if x return x; }
    x = fc_num(cast(u64) (l.section.count != 0), cast(u64) (r.section.count != 0)); if x return x;
    if l.section.count { x = fc_mem(l.section, r.section); if x return x; }
    x = fc_num(cast(u64) func_vararg(l.value_type), cast(u64) func_vararg(r.value_type)); if x return x;
    x = fc_num(l.cc, r.cc); if x return x;
    x = fc_types(c, l.value_type, r.value_type); if x return x;
    if l.nargs > 0 for k: 0..l.nargs - 1 fc_values(c, fn_arg(c.fl, k), fn_arg(c.fr, k));
    return 0;
}

// FunctionComparator::compare
fc_compare :: (fl: Value_Id, fr: Value_Id) -> s32 {
    c: Fn_Cmp;
    c.fl = fl; c.fr = fr;
    c.sn_l.allocator = temp; c.sn_r.allocator = temp;
    x := fc_compare_signature(*c);
    if x return x;
    sl: [..] Value_Id; sl.allocator = temp; sr: [..] Value_Id; sr.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*sl, glob(fl).first_block); array_add(*sr, glob(fr).first_block);
    table_set(*visited, sl[0], true);
    while sl.count {
        bl := pop(*sl); br := pop(*sr);
        r1 := fc_values(*c, bl, br); if r1 return r1;
        r2 := fc_basic_blocks(*c, bl, br); if r2 return r2;
        tl := block_terminator(bl); tr := block_terminator(br);
        ns := num_successors(tl);
        if ns > 0 for k: 0..ns - 1 {
            s := get_successor(tl, k);
            if table_contains(*visited, s) continue;
            table_set(*visited, s, true);
            array_add(*sl, s);
            array_add(*sr, get_successor(tr, k));
        }
    }
    return 0;
}

// ---------------------------------------------------------------- MergeFunctions

Mf_Node :: struct { f: Value_Id; hash: u64; alive: bool; }
mf: struct {
    tree: [..] Mf_Node;
    in_tree: Table(Value_Id, s64);    // FNodesInTree
    deferred: [..] Value_Id;
    used: Table(Value_Id, bool);
    fwd: Table(Value_Id, Value_Id);   // WeakTrackingVH: followed through replaceAllUsesWith
    use_aliases: bool;                // -mergefunc-use-aliases
    preserve_debug_info: bool;        // -mergefunc-preserve-debug-info
};

merge_functions_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    b :: (value: string, has_value: bool) -> bool { return !has_value || value == "true" || value == "1"; }
    if name == "mergefunc-use-aliases" { mf.use_aliases = b(value, has_value); return true; }
    if name == "mergefunc-preserve-debug-info" { mf.preserve_debug_info = b(value, has_value); return true; }
    if name == "mergefunc-verify" fatal("unsupported option '-mergefunc-verify'");
    return false;
}

mf_resolve :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    while true {
        found, n := table_find(*mf.fwd, v);
        if !found break;
        v = n;
    }
    if vkind(v) == .DEAD return NONE;
    return v;
}
mf_rauw :: (old: Value_Id, new: Value_Id) {
    ipo_rauw(old, new);
    table_set(*mf.fwd, old, new);
}

mf_is_odr :: (f: Value_Id) -> bool { l := glob(f).linkage; return l == .WEAK_ODR || l == .LINKONCE_ODR; }
mf_discardable_if_unused :: (f: Value_Id) -> bool {
    l := glob(f).linkage;
    return l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .INTERNAL || l == .PRIVATE || l == .AVAILABLE_EXTERNALLY;
}

mf_has_distinct_metadata_intrinsic :: (f: Value_Id) -> bool {
    for i: fn_insts(f) {
        if inst_op(i) != .CALL continue;
        callee := call_called_function(i);
        if callee == NONE || !glob(callee).intrinsic continue;
        n := nops(i);
        for k: 0..n - 1 {
            o := op(i, k);
            if o == NONE || vkind(o) != .MD_VALUE continue;
            m := cast(Md_Id) ir.v_aux[o];
            if is_md_node(m) && ir.mds[m].distinct return true;
        }
    }
    return false;
}
mf_eligible :: (f: Value_Id) -> bool {
    return !is_declaration(f) && glob(f).linkage != .AVAILABLE_EXTERNALLY && !fn_has_fn_attr(f, .NoIPA) &&
           !mf_has_distinct_metadata_intrinsic(f);
}

// MergeFunctions::remove
mf_remove :: (f: Value_Id) {
    found, idx := table_find(*mf.in_tree, f);
    if !found return;
    mf.tree[idx].alive = false;
    table_remove(*mf.in_tree, f);
    array_add(*mf.deferred, f);
}
// MergeFunctions::removeUsers
mf_remove_users :: (v: Value_Id) {
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for users if vkind(it) == .INST mf_remove(value_function(it));
}
// MergeFunctions::replaceDirectCallers
mf_replace_direct_callers :: (old: Value_Id, new: Value_Id) {
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[old];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for u: uses {
        cb := ir.u_user[u];
        if vkind(cb) != .INST || !is_call_base(cb) continue;
        if u != op_use(cb, nops(cb) - 1) continue;   // CB->isCallee(&U)
        mf_remove(value_function(cb));
        use_set(u, new);
    }
}

// Function::Create(Ty, Linkage, AddrSpace, "", M): appended to the module
mf_new_function :: (like: Value_Id) -> Value_Id {
    g := glob(like);
    nf := new_function(g.value_type, "", g.addrspace);
    gv_set_linkage(nf, g.linkage);
    array_add(*ir.m_functions, nf);
    return nf;
}
mf_copy_metadata_if_present :: (from: Value_Id, to: Value_Id, kind: string) {
    k := md_kind_id(kind);
    a := ir.v_md[from];
    while a != NONE { if ir.attaches[a].kind == k add_metadata(to, k, ir.attaches[a].md); a = ir.attaches[a].next; }
}
mf_set_align :: (f: Value_Id, a: u64, b: u64) {
    if a || b glob(f).align = max(max(a, 1), max(b, 1)); else glob(f).align = 0;
}

// canCreateThunkFor
mf_can_create_thunk_for :: (f: Value_Id) -> bool {
    if func_vararg(glob(f).value_type) return false;
    if cc_is_kernel(glob(f).cc) return false;
    if fn_num_blocks(f) == 1 && block_size(glob(f).first_block) < 2 return false;
    return true;
}
cc_is_kernel :: (cc: u32) -> bool {
    // CallingConv::AMDGPU_KERNEL (91), PTX_Kernel (71), SPIR_KERNEL (76)
    return cc == 91 || cc == 71 || cc == 76;
}
mf_can_create_alias_for :: (f: Value_Id) -> bool {
    return mf.use_aliases && glob(f).unnamed_addr == 2;
}

// IRBuilder::CreateAggregateCast
mf_aggregate_cast :: (b: *Irb, v: Value_Id, dt: Type_Id) -> Value_Id {
    st := vtype(v);
    if st == dt return v;
    sk := type_kind(st);
    if sk == .STRUCT || sk == .ARRAY {
        n := ifx sk == .STRUCT then cast(u64) type_nsub(st) else type_count(st);
        result := const_poison(dt);
        for k: 0..cast(s64) n - 1 {
            et := ifx sk == .STRUCT then type_sub(dt, cast(u32) k) else type_elem(dt);
            idx := u32.[cast(u32) k];
            e := mf_aggregate_cast(b, irb_extract_value(b, v, idx), et);
            result = irb_insert_value(b, result, e, idx);
        }
        return result;
    }
    // CreateBitOrPointerCast
    if type_kind(scalar_type(st)) == .PTR && type_kind(scalar_type(dt)) == .INT return irb_cast(b, .PTRTOINT, v, dt);
    if type_kind(scalar_type(st)) == .INT && type_kind(scalar_type(dt)) == .PTR return irb_cast(b, .INTTOPTR, v, dt);
    return irb_cast(b, .BITCAST, v, dt);
}

// MergeFunctions::filterInstsUnrelatedToPDI: the entry block's instructions and debug records that do not
// describe parameters (in order of appearance)
mf_filter_insts_unrelated_to_pdi :: (entry: Value_Id, insts: *[..] Value_Id, recs: *[..] u32) {
    rel_i: Table(Value_Id, bool); rel_i.allocator = temp;
    rel_r: Table(u32, bool); rel_r.allocator = temp;
    is_param :: (var: Md_Id) -> bool { return var != NONE && di_int(var, 1) != 0; }   // DILocalVariable::isParameter
    for i: block_insts(entry) {
        x := inst(i).records;
        while x != 0 {
            r := dbgr(x);
            if r.kind == .VALUE || r.kind == .ASSIGN {
                if is_param(r.var) table_set(*rel_r, x, true);
            } else if r.kind == .DECLARE {
                if is_param(r.var) && r.loc != NONE && ir.mds[r.loc].kind == .VALUE {
                    ai := ir.mds[r.loc].value;
                    if vkind(ai) == .INST && inst_op(ai) == .ALLOCA {
                        u := ir.v_first_use[ai];
                        while u != NONE {
                            si := ir.u_user[u];
                            if vkind(si) == .INST && inst_op(si) == .STORE {
                                v := op(si, 0);
                                if v != NONE && vkind(v) == .ARGUMENT {
                                    table_set(*rel_i, ai, true);
                                    table_set(*rel_i, si, true);
                                    table_set(*rel_r, x, true);
                                }
                            }
                            u = ir.u_next[u];
                        }
                    }
                }
            }
            x = r.next;
        }
        if is_terminator(inst_op(i)) && i == block_terminator(entry) table_set(*rel_i, i, true);
    }
    for i: block_insts(entry) {
        x := inst(i).records;
        while x != 0 {
            if dbgr(x).kind != .LABEL && !table_contains(*rel_r, x) array_add(recs, x);
            x = dbgr(x).next;
        }
        if !table_contains(*rel_i, i) array_add(insts, i);
    }
}

// MergeFunctions::eraseTail
mf_erase_tail :: (g: Value_Id) {
    bbs: [..] Value_Id; bbs.allocator = temp;
    first := true;
    for b: fn_blocks(g) {
        if first { first = false; continue; }
        for i: block_insts(b) drop_all_references(i);
        array_add(*bbs, b);
    }
    while bbs.count block_erase_from_parent(pop(*bbs));
}

// MergeFunctions::writeThunk
mf_write_thunk :: (f: Value_Id, g: Value_Id) {
    has_gec, gec := function_entry_count(g);
    pdi := mf.preserve_debug_info;
    pdi_insts: [..] Value_Id; pdi_insts.allocator = temp;
    pdi_recs: [..] u32; pdi_recs.allocator = temp;
    if pdi {
        entry := glob(g).first_block;
        mf_filter_insts_unrelated_to_pdi(entry, *pdi_insts, *pdi_recs);
        // the terminator's debug records become the block's trailing records, which the next instruction
        // inserted at the end adopts
        term := block_terminator(entry);
        trailing := inst(term).records;
        inst(term).records = 0;
        prev_last := inst(term).prev;
        erase_inst(term);
        b: Irb;
        irb_set_end(*b, entry);
        args: [..] Value_Id; args.allocator = temp;
        ffty := glob(f).value_type;
        for k: 0..cast(s64) glob(g).nargs - 1 array_add(*args, mf_aggregate_cast(*b, fn_arg(g, cast(u32) k), func_param(ffty, cast(u32) k)));
        ci := irb_call(*b, f, args);
        swift_tail := glob(f).cc == 20 && glob(g).cc == 20;
        inst(ci).flags = (inst(ci).flags & ~(cast(u32) 3 << TAIL_SHIFT)) | ((ifx swift_tail then cast(u32) 2 else 1) << TAIL_SHIFT);
        inst(ci).cc = glob(f).cc;
        inst(ci).attrs = glob(f).attrs;
        hret := func_ret(glob(g).value_type);
        ret: Value_Id;
        if type_kind(hret) == .VOID ret = new_inst(.RET, ir.t_void, 0);
        else { rv := mf_aggregate_cast(*b, ci, hret); ret = new_inst(.RET, ir.t_void, 1); set_op(ret, 0, rv); }
        irb_insert(*b, ret);
        if trailing attach_records_before(ifx prev_last == NONE then block(entry).first else inst(prev_last).next, trailing);
        sp := get_metadata(g, MDK_DBG);
        if sp != NONE {
            set_metadata(ci, MDK_DBG, di_location_get(di_int(sp, 1), 0, sp, NONE));
            set_metadata(ret, MDK_DBG, di_location_get(di_int(sp, 1), 0, sp, NONE));
        }
        mf_erase_tail(g);
        while pdi_insts.count erase_inst_with_metadata(pop(*pdi_insts));
        while pdi_recs.count dbgr_erase(pop(*pdi_recs));
        return;
    }
    ng := mf_new_function(g);
    glob(ng).comdat = glob(g).comdat;
    bb := new_block(ng);
    fn_append_block(ng, bb);
    note_block_created(ng, bb);
    b: Irb;
    irb_set_end(*b, bb);
    args: [..] Value_Id; args.allocator = temp;
    ffty := glob(f).value_type;
    for k: 0..cast(s64) glob(ng).nargs - 1 array_add(*args, mf_aggregate_cast(*b, fn_arg(ng, cast(u32) k), func_param(ffty, cast(u32) k)));
    ci := irb_call(*b, f, args);
    swift_tail := glob(f).cc == 20 && glob(g).cc == 20;
    inst(ci).flags = (inst(ci).flags & ~(cast(u32) 3 << TAIL_SHIFT)) | ((ifx swift_tail then cast(u32) 2 else 1) << TAIL_SHIFT);
    inst(ci).cc = glob(f).cc;
    inst(ci).attrs = glob(f).attrs;
    hret := func_ret(glob(ng).value_type);
    ret: Value_Id;
    if type_kind(hret) == .VOID ret = new_inst(.RET, ir.t_void, 0);
    else {
        rv := mf_aggregate_cast(*b, ci, hret);
        ret = new_inst(.RET, ir.t_void, 1);
        set_op(ret, 0, rv);
    }
    irb_insert(*b, ret);
    ipo_fn_copy_attributes_from(ng, g);
    if has_gec fn_set_entry_count(ng, gec);
    gv_take_name(ng, g);
    mf_copy_metadata_if_present(g, ng, "type");
    mf_copy_metadata_if_present(g, ng, "kcfi_type");
    mf_copy_metadata_if_present(g, ng, "callgraph");
    mf_remove_users(g);
    mf_rauw(g, ng);
    gv_erase_from_parent(g);
}

// MergeFunctions::writeAlias
mf_write_alias :: (f: Value_Id, g: Value_Id) {
    gg := glob(g);
    ga := new_global(.ALIAS, gg.value_type, gg.addrspace, 1);
    gv_set_linkage(ga, gg.linkage);
    set_op(ga, 0, f);
    array_add(*ir.m_aliases, ga);
    mf_set_align(f, glob(f).align, gg.align);
    gv_take_name(ga, g);
    gv_set_visibility(ga, glob(g).visibility);
    glob(ga).unnamed_addr = 2;
    mf_remove_users(g);
    mf_rauw(g, ga);
    gv_erase_from_parent(g);
}

// writeThunkOrAliasIfNeeded
mf_write_thunk_or_alias_if_needed :: (f: Value_Id, g: Value_Id) -> bool {
    if mf_discardable_if_unused(g) && !has_uses(g) && !mf.preserve_debug_info { gv_erase_from_parent(g); return true; }
    if mf_can_create_alias_for(g) { mf_write_alias(f, g); return true; }
    if mf_can_create_thunk_for(f) { mf_write_thunk(f, g); return true; }
    return false;
}

// mergeEntryCountsInto
mf_merge_entry_counts_into :: (f: Value_Id, has_fc: bool, fc: u64, has_gc: bool, gc: u64) {
    if !has_fc && !has_gc return;
    a := ifx has_fc then fc else 0;
    b := ifx has_gc then gc else 0;
    s := a + b;
    if s < a s = 0xFFFF_FFFF_FFFF_FFFF;   // SaturatingAdd
    fn_set_entry_count(f, s);
}

// MergeFunctions::mergeTwoFunctions
mf_merge_two_functions :: (f: Value_Id, g: Value_Id) {
    has_fec, fec := function_entry_count(f);
    has_gec, gec := function_entry_count(g);
    if gv_is_interposable(f) || (mf_is_odr(f) && mf_is_odr(g)) {
        if !mf_can_create_thunk_for(f) && (!mf_can_create_alias_for(f) || !mf_can_create_alias_for(g)) return;
        nf := mf_new_function(f);
        ipo_fn_copy_attributes_from(nf, f);
        gv_take_name(nf, f);
        glob(nf).comdat = glob(f).comdat;
        glob(f).comdat = -1;
        mf_copy_metadata_if_present(f, nf, "type");
        mf_copy_metadata_if_present(f, nf, "kcfi_type");
        mf_copy_metadata_if_present(f, nf, "callgraph");
        mf_remove_users(f);
        mf_rauw(f, nf);
        // (the WeakTrackingVHs of F now refer to NewF; F itself stays the merged body)
        if mf_is_odr(g) mf_replace_direct_callers(g, f);
        if mf_is_odr(f) mf_replace_direct_callers(nf, f);
        nf_align := glob(nf).align;
        g_align := glob(g).align;
        mf_write_thunk_or_alias_if_needed(f, g);
        if has_fec fn_set_entry_count(nf, fec);
        mf_write_thunk_or_alias_if_needed(f, nf);
        mf_set_align(f, nf_align, g_align);
        gv_set_linkage(f, .PRIVATE);
        mf_merge_entry_counts_into(f, has_fec, fec, has_gec, gec);
        return;
    }
    if !gv_is_interposable(g) && !mf.preserve_debug_info {
        if glob(g).unnamed_addr == 2 && !table_contains(*mf.used, g) {
            table_remove(*mf_global_numbers, g);
            mf_remove_users(g);
            mf_rauw(g, f);
        } else mf_replace_direct_callers(g, f);
    }
    if mf_discardable_if_unused(g) && !has_uses(g) && !mf.preserve_debug_info {
        mf_merge_entry_counts_into(f, has_fec, fec, has_gec, gec);
        gv_erase_from_parent(g);
        return;
    }
    if mf_write_thunk_or_alias_if_needed(f, g) mf_merge_entry_counts_into(f, has_fec, fec, has_gec, gec);
}

// isFuncOrderCorrect
mf_is_func_order_correct :: (f: Value_Id, g: Value_Id) -> bool {
    if mf_is_odr(f) != mf_is_odr(g) return mf_is_odr(g);
    if gv_is_interposable(f) != gv_is_interposable(g) return !gv_is_interposable(f);
    if gv_has_local_linkage(f) != gv_has_local_linkage(g) return !gv_has_local_linkage(f);
    return compare(vname(f), vname(g)) <= 0;
}

// MergeFunctions::insert
mf_insert :: (nf_in: Value_Id) -> bool {
    nf := nf_in;
    h := mf_structural_hash(nf);
    found := -1;
    for * mf.tree {
        if !it.alive || it.hash != h continue;
        if fc_compare(it.f, nf) == 0 { found = it_index; break; }
    }
    if found < 0 {
        array_add(*mf.tree, .{nf, h, true});
        table_set(*mf.in_tree, nf, mf.tree.count - 1);
        return false;
    }
    old := mf.tree[found].f;
    if !mf_is_func_order_correct(old, nf) {
        // replaceFunctionInTree(OldF, NewFunction)
        table_remove(*mf.in_tree, old);
        table_set(*mf.in_tree, nf, found);
        mf.tree[found].f = nf;
        tmp := old; old = nf; nf = tmp;
    }
    mf_merge_two_functions(old, nf);
    return true;
}

merge_functions_run :: () -> Preserved {
    mf.tree.count = 0;
    table_reset(*mf.in_tree);
    mf.deferred.count = 0;
    table_reset(*mf.used);
    table_reset(*mf.fwd);
    table_reset(*mf_global_numbers);
    mf_next_number = 0;
    used: [..] Value_Id; used.allocator = temp;
    collect_used_global_variables(*used, false);
    collect_used_global_variables(*used, true);
    for used table_set(*mf.used, it, true);

    Hashed :: struct { h: u64; f: Value_Id; }
    hashed: [..] Hashed; hashed.allocator = temp;
    for f: ir.m_functions if mf_eligible(f) array_add(*hashed, .{mf_structural_hash(f), f});
    // llvm::stable_sort(HashedFuncs, less_first())
    for i: 1..hashed.count - 1 {
        x := hashed[i];
        j := i - 1;
        while j >= 0 && hashed[j].h > x.h { hashed[j + 1] = hashed[j]; j -= 1; }
        hashed[j + 1] = x;
    }
    for hashed {
        if (it_index > 0 && hashed[it_index - 1].h == it.h) || (it_index + 1 < hashed.count && hashed[it_index + 1].h == it.h)
            array_add(*mf.deferred, it.f);
    }
    changed := false;
    while mf.deferred.count {
        worklist: [..] Value_Id; worklist.allocator = temp;
        for mf.deferred array_add(*worklist, it);
        mf.deferred.count = 0;
        for w: worklist {
            f := mf_resolve(w);
            if f == NONE continue;
            if vkind(f) != .FUNCTION fatal("mergefunc: a deferred function was replaced by an alias (not supported)");
            if !is_declaration(f) && glob(f).linkage != .AVAILABLE_EXTERNALLY && !fn_has_fn_attr(f, .NoIPA)
                if mf_insert(f) changed = true;
        }
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
