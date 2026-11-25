// Run-time checks and hardening passes: a port of
//   llvm/lib/Transforms/Instrumentation/KCFI.cpp              kcfi
//   llvm/lib/Transforms/Instrumentation/LowerAllowCheckPass.cpp  lower-allow-check
//   llvm/lib/Transforms/Instrumentation/BoundsChecking.cpp    bounds-checking (with memory_builtins.jai's
//                                                              ObjectSizeOffsetEvaluator)
//   llvm/lib/Transforms/Instrumentation/AllocToken.cpp        alloc-token
//   llvm/lib/Support/AllocToken.cpp                           getAllocToken, the mode names
//   llvm/lib/Support/SipHash.cpp                              getStableSipHash (SipHash-2-4, the reference algorithm)
//   llvm/lib/Support/RandomNumberGenerator.cpp                RandomNumberGenerator (std::mt19937_64 seeded through
//                                                              std::seed_seq; libstdc++'s bernoulli_distribution)
// (Module::createRNG, llvm/lib/IR/Module.cpp, salts with the module identifier's file name.)
// StackProtector and SafeStack are in pass_stack_protector.jai and pass_safe_stack.jai.

// ---------------------------------------------------------------- RandomNumberGenerator

rng_cl: struct { seed: u64 = 0; };   // -rng-seed

Mt64 :: struct { mt: [312] u64; idx: s64; }
MT_N :: 312; MT_M :: 156;
mt64_seed_seq :: (g: *Mt64, data: [] u32) {
    // std::seed_seq::generate into 624 32-bit words (C++ [rand.util.seedseq])
    n :: 624;
    b: [624] u32;
    for * b it.* = 0x8b8b8b8b;
    s := data.count;
    t: s64 = ifx n >= 623 then 11 else ifx n >= 68 then 7 else ifx n >= 39 then 5 else ifx n >= 7 then 3 else (n - 1) / 2;
    p := (n - t) / 2;
    q := p + t;
    m := max(s + 1, n);
    T :: (x: u32) -> u32 { return x ^ (x >> 27); }
    for k: 0..m-1 {
        r1: u32 = 1664525 * T(b[k % n] ^ b[(k + p) % n] ^ b[(k + n - 1) % n]);
        r2: u32;
        if k == 0 r2 = r1 + cast(u32) s;
        else if k <= s r2 = r1 + cast(u32)(k % n) + data[k - 1];
        else r2 = r1 + cast(u32)(k % n);
        b[(k + p) % n] += r1;
        b[(k + q) % n] += r2;
        b[k % n] = r2;
    }
    for k: m..m+n-1 {
        r3: u32 = 1566083941 * T(b[k % n] + b[(k + p) % n] + b[(k + n - 1) % n]);
        r4: u32 = r3 - cast(u32)(k % n);
        b[(k + p) % n] ^= r3;
        b[(k + q) % n] ^= r4;
        b[k % n] = r4;
    }
    // mersenne_twister_engine::seed(Sseq&): k = 2 words per state element
    for i: 0..MT_N-1 g.mt[i] = (cast(u64) b[2 * i]) | ((cast(u64) b[2 * i + 1]) << 32);
    // if the top w-r = 33 bits of x[0] and all other words are zero, x[0] = 2^63
    zero := (g.mt[0] & (~(cast(u64) 0) << 31)) == 0;
    if zero for i: 1..MT_N-1 if g.mt[i] != 0 { zero = false; break; }
    if zero g.mt[0] = (cast(u64) 1) << 63;
    g.idx = MT_N;
}
mt64_next :: (g: *Mt64) -> u64 {
    UPPER :: 0xFFFF_FFFF_8000_0000;
    LOWER :: 0x0000_0000_7FFF_FFFF;
    MATRIX_A :: 0xB502_6F5A_A966_19E9;
    if g.idx >= MT_N {
        for i: 0..MT_N-1 {
            y := (g.mt[i] & UPPER) | (g.mt[(i + 1) % MT_N] & LOWER);
            v := g.mt[(i + MT_M) % MT_N] ^ (y >> 1);
            if y & 1 v ^= MATRIX_A;
            g.mt[i] = v;
        }
        g.idx = 0;
    }
    z := g.mt[g.idx];
    g.idx += 1;
    z ^= (z >> 29) & 0x5555_5555_5555_5555;
    z ^= (z << 17) & 0x71D6_7FFF_EDA6_0000;
    z ^= (z << 37) & 0xFFF7_EEE0_0000_0000;
    z ^= z >> 43;
    return z;
}
// Module::createRNG(Name): salt = Name + sys::path::filename(ModuleIdentifier)
create_rng :: (name: string) -> Mt64 {
    salt := tconcat(name, sp_filename(ir.module_id, false));
    data := NewArray(2 + salt.count, u32,, allocator = temp);
    data[0] = cast(u32)(rng_cl.seed & 0xFFFF_FFFF);
    data[1] = cast(u32)(rng_cl.seed >> 32);
    for i: 0..salt.count-1 data[2 + i] = cast(u32) salt[i];   // std::copy of a StringRef: char (signed) -> u32
    for i: 0..salt.count-1 if salt[i] >= 0x80 data[2 + i] = cast(u32) cast(s32) cast(s8) salt[i];
    g: Mt64;
    mt64_seed_seq(*g, data);
    return g;
}
// std::bernoulli_distribution(p)(urng) with libstdc++: generate_canonical<double, 53>(urng) < p
rng_bernoulli :: (g: *Mt64, p: float64) -> bool {
    x := mt64_next(g);
    c := cast(float64) x / 18446744073709551616.0;
    if c >= 1.0 c = 0.99999999999999989;   // nextafter(1, 0)
    return c < p;
}

// ---------------------------------------------------------------- SipHash-2-4

sip_hash_2_4_64 :: (data: string, key: [16] u8) -> u64 {
    rotl :: (x: u64, b: u64) -> u64 { return (x << b) | (x >> (64 - b)); }
    le64 :: (p: *u8) -> u64 { r: u64; for i: 0..7 r |= (cast(u64) p[i]) << (8 * cast(u64) i); return r; }
    kk := key;
    k0 := le64(kk.data); k1 := le64(kk.data + 8);
    v0: u64 = 0x736f6d6570736575 ^ k0;
    v1: u64 = 0x646f72616e646f6d ^ k1;
    v2: u64 = 0x6c7967656e657261 ^ k0;
    v3: u64 = 0x7465646279746573 ^ k1;
    round :: () #expand {
        v0 += v1; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32);
        v2 += v3; v3 = rotl(v3, 16); v3 ^= v2;
        v0 += v3; v3 = rotl(v3, 21); v3 ^= v0;
        v2 += v1; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32);
    }
    n := data.count;
    full := n - n % 8;
    i := 0;
    while i < full {
        m := le64(data.data + i);
        v3 ^= m; round(); round(); v0 ^= m;
        i += 8;
    }
    b: u64 = (cast(u64) n) << 56;
    left := n & 7;
    for j: 0..left-1 b |= (cast(u64) data[full + j]) << (8 * cast(u64) j);
    v3 ^= b; round(); round(); v0 ^= b;
    v2 ^= 0xff;
    round(); round(); round(); round();
    return v0 ^ v1 ^ v2 ^ v3;
}
// getStableSipHash
get_stable_sip_hash :: (s: string) -> u64 {
    K :: u8.[0xb5, 0xd4, 0xc9, 0xeb, 0x79, 0x10, 0x4a, 0x79, 0x6f, 0xec, 0x8b, 0x1b, 0x42, 0x87, 0x81, 0xd4];
    k: [16] u8;
    for K k[it_index] = it;
    return sip_hash_2_4_64(s, k);
}

// ---------------------------------------------------------------- KCFI

kcfi_run :: (f: Value_Id) -> Preserved {
    if module_flag("kcfi") == NONE return PRESERVE_ALL;
    calls: [..] Value_Id; calls.allocator = temp;
    for i: fn_insts(f) if inst_op(i) == .CALL && call_bundle_index(i, "kcfi") >= 0 array_add(*calls, i);
    if calls.count == 0 return PRESERVE_ALL;
    if attr_set_has_str(attr_list_fn(glob(f).attrs), "patchable-function-prefix")
        fatal("-fpatchable-function-entry=N,M, where M>0 is not compatible with -fsanitize=kcfi on this target");
    weights := create_unlikely_branch_weights();
    t := triple_parse(ir.triple);
    is_arm := t.arch == .arm || t.arch == .armeb || t.arch == .thumb || t.arch == .thumbeb;
    for ci: calls {
        k := call_bundle_index(ci, "kcfi");
        s, e := call_bundle_range(ci, cast(u32) k);
        expected := cast(u32) const_int_zext(op(ci, s));
        call := ic_call_remove_bundle_at(ci, cast(u32) k);
        insert_at_position(call, inst_block(ci), ci, false);
        if vname(ci).count set_name(call, vname(ci));
        rauw_with_metadata(ci, call);
        erase_inst_with_metadata(ci);
        if !call_is_indirect(call) continue;
        b: Irb; irb_set_before(*b, call); b.dbg = get_metadata(call, 0);
        fp := call_callee(call);
        if is_arm {
            pi := irb_cast(*b, .PTRTOINT, fp, ir.t_i32);
            a := irb_binop(*b, .AND, pi, const_int(ir.t_i32, 0xFFFF_FFFE));
            fp = irb_cast(*b, .INTTOPTR, a, vtype(fp));
        }
        hp := irb_gep(*b, ir.t_i32, fp, .[const_int(ir.t_i32, 0xFFFF_FFFF)], "", F_INBOUNDS);
        ld := irb_load(*b, ir.t_i32, hp, dl_abi_align(ir.t_i32));
        test := irb_icmp(*b, ICMP_NE, ld, const_int(ir.t_i32, expected));
        then_term := sbi_if_then(test, call, false, weights);
        b2: Irb; irb_set_before(*b2, then_term); b2.dbg = get_metadata(then_term, 0);
        irb_call(*b2, get_or_insert_intrinsic_declaration(IID_DEBUGTRAP), .[]);
    }
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- LowerAllowCheck

lac_cl: struct {
    has_hot_cutoff: bool; hot_cutoff: s64;    // -lower-allow-check-percentile-cutoff-hot
    has_random_rate: bool; random_rate: float64;   // -lower-allow-check-random-rate
};
hardening_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "lower-allow-check-percentile-cutoff-hot"; lac_cl.has_hot_cutoff = true; lac_cl.hot_cutoff = smisc_int(name, value, has_value);
        case "lower-allow-check-random-rate";
            if !has_value fatal(tprint("opt: option -% needs a value", name));
            v, ok := string_to_float64(value);
            if !ok fatal(tprint("opt: invalid floating-point value '%' for -%", value, name));
            lac_cl.has_random_rate = true; lac_cl.random_rate = v;
        case "rng-seed"; rng_cl.seed = cast(u64) smisc_int(name, value, has_value);
        case "bounds-checking-single-trap"; bc_cl.single_trap_bb = smisc_bool(name, value, has_value);
        case "alloc-token-prefix"; if !has_value fatal("opt: option -alloc-token-prefix needs a value"); at_cl.prefix = copy_string(value);
        case "alloc-token-max"; at_cl.has_max = true; at_cl.max = cast(u64) smisc_int(name, value, has_value);
        case "alloc-token-fast-abi"; at_cl.has_fast_abi = true; at_cl.fast_abi = smisc_bool(name, value, has_value);
        case "alloc-token-extended"; at_cl.has_extended = true; at_cl.extended = smisc_bool(name, value, has_value);
        case "alloc-token-cover-replaceable-new"; at_cl.cover_replaceable_new = smisc_bool(name, value, has_value);
        case "alloc-token-fallback"; at_cl.fallback = cast(u64) smisc_int(name, value, has_value);
        case; return false;
    }
    return true;
}

Lac_Options :: struct { cutoffs: [..] s64; runtime_check: s64; }
// parseLowerAllowCheckPassOptions
lac_parse_options :: (name: string) -> Lac_Options {
    o: Lac_Options; o.cutoffs.allocator = temp;
    if !begins_with(name, "lower-allow-check<") return o;
    params := slice(name, 18, name.count - 19);
    while params.count {
        p := params;
        c := find_index_from_left(params, #char ";");
        if c >= 0 { p = slice(params, 0, c); params = slice(params, c + 1, params.count - c - 1); } else params = "";
        if begins_with(p, "cutoffs[") {
            sep := find_index_from_left(p, "]=");
            idxs, cut: string;
            if sep >= 0 { idxs = slice(p, 0, sep); cut = slice(p, sep + 2, p.count - sep - 2); } else { idxs = p; cut = ""; }
            cv, ok := parse_int_auto(cut);
            if !ok pipeline_error("invalid LowerAllowCheck pass cutoffs parameter '%' (%)", cut, params);
            if !begins_with(idxs, "cutoffs[") || idxs.count == 8 pipeline_error("invalid LowerAllowCheck pass index parameter '%' (%)", idxs, cut);
            idxs = slice(idxs, 8, idxs.count - 8);
            while idxs.count {
                f := idxs;
                bar := find_index_from_left(idxs, #char "|");
                if bar >= 0 { f = slice(idxs, 0, bar); idxs = slice(idxs, bar + 1, idxs.count - bar - 1); } else idxs = "";
                iv, ok2 := parse_int_auto(f);
                if !ok2 || iv < 0 pipeline_error("invalid LowerAllowCheck pass index parameter '%' (%) ", f, idxs);
                while o.cutoffs.count <= iv array_add(*o.cutoffs, 0);
                o.cutoffs[iv] = cv;
            }
        } else if begins_with(p, "runtime_check") {
            eq := find_index_from_left(p, #char "=");
            vs := ifx eq >= 0 then slice(p, eq + 1, p.count - eq - 1) else "";
            rv, ok := parse_int_auto(vs);
            if !ok pipeline_error("invalid LowerAllowCheck pass runtime_check parameter '%' (%)", vs, params);
            o.runtime_check = rv;
        } else pipeline_error("invalid LowerAllowCheck pass parameter '%'", p);
    }
    return o;
}
// StringRef::getAsInteger(0, ...): radix autodetection (0x, 0b, 0o / leading 0)
parse_int_auto :: (s_in: string) -> (s64, bool) {
    s := s_in;
    neg := false;
    if s.count && s[0] == #char "-" { neg = true; s = slice(s, 1, s.count - 1); }
    radix: u64 = 10;
    if begins_with(s, "0x") || begins_with(s, "0X") { radix = 16; s = slice(s, 2, s.count - 2); }
    else if begins_with(s, "0b") || begins_with(s, "0B") { radix = 2; s = slice(s, 2, s.count - 2); }
    else if begins_with(s, "0o") { radix = 8; s = slice(s, 2, s.count - 2); }
    else if s.count > 1 && s[0] == #char "0" { radix = 8; s = slice(s, 1, s.count - 1); }
    if s.count == 0 return 0, false;
    v: u64 = 0;
    for c: cast([] u8) s {
        d: u64;
        if c >= #char "0" && c <= #char "9" d = cast(u64)(c - #char "0");
        else if c >= #char "a" && c <= #char "z" d = cast(u64)(c - #char "a") + 10;
        else if c >= #char "A" && c <= #char "Z" d = cast(u64)(c - #char "A") + 10;
        else return 0, false;
        if d >= radix return 0, false;
        v = v * radix + d;
    }
    r := cast,no_check(s64) v;
    if neg r = -r;
    return r, true;
}

lower_allow_check_run :: (f: Value_Id, name: string) -> Preserved {
    if is_declaration(f) return PRESERVE_ALL;
    opts := lac_parse_options(name);
    Repl :: struct { i: Value_Id; v: bool; }
    repl: [..] Repl; repl.allocator = temp;
    rng: Mt64; has_rng := false;
    bfi: *Bfi = null;
    psi_done := false; psi: *Psi = null;
    get_cutoff :: (i: Value_Id, opts: *Lac_Options) -> s64 {
        if lac_cl.has_hot_cutoff return lac_cl.hot_cutoff;
        id := call_iid(i);
        if id == IID_ALLOW_UBSAN_CHECK {
            k := const_int_zext(call_arg(i, 0));
            if k < cast(u64) opts.cutoffs.count return opts.cutoffs[k];
        } else if id == IID_ALLOW_RUNTIME_CHECK return opts.runtime_check;
        return 0;
    }
    for i: fn_insts(f) {
        id := call_iid(i);
        if id == IID_ALLOW_UBSAN_CHECK || id == IID_ALLOW_RUNTIME_CHECK {
            cutoff := get_cutoff(i, *opts);
            to_remove := false;
            // ShouldRemoveRandom() || ShouldRemoveHot(BB, cutoff)
            if lac_cl.has_random_rate {
                if !has_rng { rng = create_rng(vname(f)); has_rng = true; }
                to_remove = !rng_bernoulli(*rng, lac_cl.random_rate);
            }
            if !to_remove {
                if cutoff == 1000000 to_remove = true;
                else {
                    if !psi_done { psi = psi_cached_or_null(); psi_done = true; }
                    if psi {
                        if !bfi bfi = get_bfi(f);
                        okc, cnt := bfi_profile_count_from_freq(bfi, f, bfi_get_block_freq(bfi, inst_block(i)));
                        if !okc cnt = 0;
                        to_remove = psi_is_hot_count_nth_percentile(psi, cutoff, cnt);
                    }
                }
            }
            array_add(*repl, .{i, !to_remove});
        } else if id == intrinsic_id_by_name("llvm.allow.sanitize.address") array_add(*repl, .{i, fn_has_fn_attr(f, .SanitizeAddress)});
        else if id == intrinsic_id_by_name("llvm.allow.sanitize.thread") array_add(*repl, .{i, fn_has_fn_attr(f, .SanitizeThread)});
        else if id == intrinsic_id_by_name("llvm.allow.sanitize.memory") array_add(*repl, .{i, fn_has_fn_attr(f, .SanitizeMemory)});
        else if id == intrinsic_id_by_name("llvm.allow.sanitize.hwaddress") array_add(*repl, .{i, fn_has_fn_attr(f, .SanitizeHWAddress)});
    }
    for repl {
        rauw_with_metadata(it.i, const_int(vtype(it.i), ifx it.v then cast(u64) 1 else 0));
        erase_inst_with_metadata(it.i);
    }
    if repl.count == 0 return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- BoundsChecking

bc_cl: struct { single_trap_bb := false; };   // -bounds-checking-single-trap

Bc_Options :: struct {
    has_rt: bool; min_runtime: bool; may_return: bool; preserve_all_regs: bool;
    merge: bool;
    has_guard: bool; guard: s8;
}
// parseBoundsCheckingOptions
bc_parse_options :: (name: string) -> Bc_Options {
    o: Bc_Options;
    if !begins_with(name, "bounds-checking<") return o;
    params := slice(name, 16, name.count - 17);
    while params.count {
        p := params;
        c := find_index_from_left(params, #char ";");
        if c >= 0 { p = slice(params, 0, c); params = slice(params, c + 1, params.count - c - 1); } else params = "";
        if p == "trap" o.has_rt = false;
        else if p == "rt" { o.has_rt = true; o.min_runtime = false; o.may_return = true; o.preserve_all_regs = false; }
        else if p == "rt-abort" { o.has_rt = true; o.min_runtime = false; o.may_return = false; o.preserve_all_regs = false; }
        else if p == "min-rt" { o.has_rt = true; o.min_runtime = true; o.may_return = true; o.preserve_all_regs = false; }
        else if p == "min-rt-abort" { o.has_rt = true; o.min_runtime = true; o.may_return = false; o.preserve_all_regs = false; }
        else if p == "merge" o.merge = true;
        else if p == "handler-preserve-all-regs" { if o.has_rt o.preserve_all_regs = true; }
        else {
            eq := find_index_from_left(p, #char "=");
            pe := ifx eq >= 0 then slice(p, 0, eq) else p;
            val := ifx eq >= 0 then slice(p, eq + 1, p.count - eq - 1) else "";
            v, ok := parse_int_auto(val);
            if pe == "guard" && ok && v >= -128 && v <= 127 { o.has_guard = true; o.guard = cast(s8) v; }
            else pipeline_error("invalid BoundsChecking pass parameter '%'", p);
        }
    }
    return o;
}

// IRBuilder<TargetFolder, NoSanitizeInserter>: every inserted instruction gets !nosanitize !{}
bc_ns :: (v: Value_Id, mark: Value_Id) -> Value_Id {
    if is_inst(v) && v >= mark set_metadata(v, md_fixed("nosanitize"), md_tuple(.[], false));
    return v;
}
bc_mark :: () -> Value_Id { return cast(Value_Id) ir.v_kind.count; }
bc_ns_since :: (mark: Value_Id) {
    for v: cast(s64) mark..ir.v_kind.count-1 {
        x := cast(Value_Id) v;
        if vkind(x) == .INST && inst(x).parent != NONE set_metadata(x, md_fixed("nosanitize"), md_tuple(.[], false));
    }
}

// getBoundsCheckCond
bc_get_bounds_check_cond :: (ptr: Value_Id, inst_val: Value_Id, ev: *Os_Evaluator, b: *Irb) -> Value_Id {
    needed := dl_type_store_size(vtype(inst_val));
    scalable := type_is_scalable(vtype(inst_val));
    ok, size, offset := ose_compute(ev, ptr);
    if !ok return NONE;
    it := dl_index_type(vtype(ptr));
    // LLVM asserts (APInt bit widths) when an address space cast changes the index width between the size, the
    // offset and the index type; its release build compares and folds values of mismatched widths
    if vtype(size) != it || vtype(offset) != it fatal("bounds-checking: object size and offset of another index width (an assertion in LLVM)");
    m := bc_mark();
    needed_v := irb_type_size(b, it, needed, scalable);   // CreateTypeSize
    bc_ns_since(m);
    size_r := sc_unsigned_range(sc_get_scev(size));
    off_r := sc_unsigned_range(sc_get_scev(offset));
    need_r := sc_unsigned_range(sc_get_scev(needed_v));
    m = bc_mark(); obj_size := bc_ns(irb_binop(b, .SUB, size, offset), m);
    cmp2: Value_Id;
    if ap_uge(cr_umin(size_r), cr_umax(off_r)) cmp2 = const_int(ir.t_i1, 0);
    else { m = bc_mark(); cmp2 = bc_ns(irb_icmp(b, ICMP_ULT, size, offset), m); }
    cmp3: Value_Id;
    if ap_uge(cr_umin(cr_sub(size_r, off_r)), cr_umax(need_r)) cmp3 = const_int(ir.t_i1, 0);
    else { m = bc_mark(); cmp3 = bc_ns(irb_icmp(b, ICMP_ULT, obj_size, needed_v), m); }
    m = bc_mark(); or := bc_ns(irb_binop(b, .OR, cmp2, cmp3), m);
    size_ci := is_scalar_const_int(size);
    if (!size_ci || ap_slt(const_ap(size), ap_zero(const_ap(size).bits))) && !ap_is_non_negative(cr_smin(sc_signed_range(sc_get_scev(size)))) {
        m = bc_mark(); cmp1 := bc_ns(irb_icmp(b, ICMP_SLT, offset, const_int(it, 0)), m);
        m = bc_mark(); or = bc_ns(irb_binop(b, .OR, cmp1, or), m);
    }
    return or;
}

bounds_checking_run :: (f: Value_Id, name: string) -> Preserved {
    o := bc_parse_options(name);
    if fn_has_fn_attr(f, .NoSanitizeBounds) return PRESERVE_ALL;
    get_scev(f);
    ev: Os_Evaluator;
    ev.opts.round_to_align = true;
    ev.opts.mode = .EXACT_UNDERLYING_SIZE_AND_OFFSET;
    ev.cache.allocator = temp; ev.seen.allocator = temp;
    Trap_Info :: struct { i: Value_Id; or: Value_Id; }
    infos: [..] Trap_Info; infos.allocator = temp;
    for i: fn_insts(f) {
        or: Value_Id = NONE;
        b: Irb; irb_set_before(*b, i); b.dbg = get_metadata(i, 0);
        op_ := inst_op(i);
        volatile := (inst(i).flags & F_VOLATILE) != 0;
        if op_ == .LOAD { if !volatile or = bc_get_bounds_check_cond(op(i, 0), i, *ev, *b); }
        else if op_ == .STORE { if !volatile or = bc_get_bounds_check_cond(op(i, 1), op(i, 0), *ev, *b); }
        else if op_ == .CMPXCHG { if !volatile or = bc_get_bounds_check_cond(op(i, 0), op(i, 1), *ev, *b); }
        else if op_ == .ATOMICRMW { if !volatile or = bc_get_bounds_check_cond(op(i, 0), op(i, 1), *ev, *b); }
        if or != NONE {
            if o.has_guard {
                m := bc_mark();
                allow := bc_ns(irb_call(*b, get_or_insert_intrinsic_declaration(IID_ALLOW_UBSAN_CHECK), .[const_int(ir.t_i8, (cast,no_check(u64) cast(s64) o.guard) & 0xFF)]), m);
                m = bc_mark(); or = bc_ns(irb_binop(*b, .AND, or, allow), m);
            }
            array_add(*infos, .{i, or});
        }
    }
    rt_name: string;
    if o.has_rt {
        rt_name = "__ubsan_handle_local_out_of_bounds";
        if o.min_runtime rt_name = tconcat(rt_name, "_minimal");
        if !o.may_return rt_name = tconcat(rt_name, "_abort");
        else if o.preserve_all_regs rt_name = tconcat(rt_name, "_preserve");
    }
    reuse_trap_bb: Value_Id = NONE;
    get_trap_bb :: (f: Value_Id, cont: Value_Id, dbg: Md_Id, o: *Bc_Options, rt_name: string, reuse: *Value_Id) -> Value_Id {
        if reuse.* != NONE return reuse.*;
        trap_bb := create_block(f, "trap");
        b: Irb; irb_set_end(*b, trap_bb); b.dbg = dbg;
        debug_trap_bb := !o.merge;
        m := bc_mark();
        tc: Value_Id;
        if o.has_rt {
            fa: [..] Attr; fa.allocator = temp;
            a: Attr; a.kind = .NoUnwind; a.ty = NONE; array_add(*fa, a);
            if !o.may_return { a2: Attr; a2.kind = .NoReturn; a2.ty = NONE; array_add(*fa, a2); }
            callee := get_or_insert_function_attrs(rt_name, type_func(ir.t_void, .[], false), attr_list_get(attr_set_get(fa), 0, .[]));
            tc = irb_call(*b, callee, .[]);
        } else if !debug_trap_bb {
            tc = irb_call(*b, get_or_insert_intrinsic_declaration(IID_TRAP), .[]);
        } else {
            imm: u64 = ifx o.has_guard then cast,no_check(u64) cast(s64) o.guard else cast(u64) fn_num_blocks(f);
            if imm > 255 imm = 255;
            tc = irb_call(*b, get_or_insert_intrinsic_declaration(IID_UBSANTRAP), .[const_int(ir.t_i8, imm)]);
        }
        bc_ns(tc, m);
        if debug_trap_bb call_add_fn_attr(tc, .NoMerge);
        call_set_does_not_throw(tc);
        set_metadata(tc, 0, dbg);
        may_return := o.has_rt && o.may_return;
        m = bc_mark();
        if may_return {
            br := new_inst(.BR, ir.t_void, 1); set_op(br, 0, cont);
            bc_ns(irb_insert(*b, br), m);
        } else {
            call_add_fn_attr(tc, .NoReturn);
            u := new_inst(.UNREACHABLE, ir.t_void, 0);
            bc_ns(irb_insert(*b, u), m);
        }
        if o.has_rt && o.preserve_all_regs && may_return inst(tc).cc = CC_PRESERVE_ALL;
        if !may_return && bc_cl.single_trap_bb && !debug_trap_bb reuse.* = trap_bb;
        return trap_bb;
    }
    for infos {
        i := it.i;
        or := it.or;
        is_c := vkind(or) == .C_INT;
        if is_c && const_int_zext(or) == 0 continue;
        dbg := get_metadata(i, 0);
        old_bb := inst_block(i);
        cont := split_basic_block(old_bb, i, "");
        erase_inst(block_terminator(old_bb));
        trap_bb := get_trap_bb(f, cont, dbg, *o, rt_name, *reuse_trap_bb);
        if is_c {
            br := new_inst(.BR, ir.t_void, 1); set_op(br, 0, trap_bb);
            block_append_inst(old_bb, br);
            continue;
        }
        cbr := new_inst(.CONDBR, ir.t_void, 3);
        set_op(cbr, 0, or); set_op(cbr, 1, trap_bb); set_op(cbr, 2, cont);
        block_append_inst(old_bb, cbr);
    }
    if infos.count == 0 return PRESERVE_ALL;
    return PRESERVE_NONE;
}
CC_PRESERVE_ALL :: 15;

// Module::getOrInsertFunction(Name, AttributeList, RetTy): the attributes only apply to a new declaration
get_or_insert_function_attrs :: (name: string, ft: Type_Id, attrs: u32) -> Value_Id {
    f := lookup_global(name);
    if f != NONE return f;
    f = get_or_insert_function(name, ft);
    glob(f).attrs = attrs;
    return f;
}

// ---------------------------------------------------------------- AllocToken

at_cl: struct {
    prefix := "__alloc_token_";              // -alloc-token-prefix
    has_max: bool; max: u64;                 // -alloc-token-max
    has_fast_abi: bool; fast_abi: bool;      // -alloc-token-fast-abi
    has_extended: bool; extended: bool;      // -alloc-token-extended
    cover_replaceable_new := true;           // -alloc-token-cover-replaceable-new
    fallback: u64;                           // -alloc-token-fallback
};
At_Mode :: enum u8 { Increment; Random; TypeHash; TypeHashPointerSplit; }
at_mode_from_string :: (s: string) -> (bool, At_Mode) {
    if s == "increment" return true, .Increment;
    if s == "random" return true, .Random;
    if s == "typehash" return true, .TypeHash;
    if s == "typehashpointersplit" return true, .TypeHashPointerSplit;
    if s == "default" return true, .TypeHashPointerSplit;
    return false, .Increment;
}
At_State :: struct {
    mode: At_Mode;
    max_tokens: u64;
    fast_abi: bool;
    extended: bool;
    counter: u64;
    rng: Mt64;
    int_ptr_ty: Type_Id;
    fn_keys: [..] u64;      // TokenAllocFunctions: (LibFunc << 48) | token (FastABI) -> callee
    fn_vals: [..] Value_Id;
}
// getAllocTokenMetadata
at_get_metadata :: (cb: Value_Id) -> Md_Id {
    r: Md_Id;
    if call_iid(cb) == IID_ALLOC_TOKEN_ID {
        a := call_arg(cb, 0);
        if vkind(a) != .MD_VALUE fatal("alloc-token: llvm.alloc.token.id operand is not metadata");
        r = cast(Md_Id) ir.v_aux[a];
        if md_nops(r) == 0 return NONE;
    } else {
        r = get_metadata(cb, md_fixed("alloc_token"));
        if r == NONE return NONE;
    }
    if md_nops(r) != 2 || !md_is_string(md_op(r, 0)) fatal("alloc-token: bad !alloc_token");
    return r;
}
IID_ALLOC_TOKEN_ID :: #run iid_by_name("llvm.alloc.token.id");
at_get_token :: (s: *At_State, cb: Value_Id) -> u64 {
    if s.mode == {
        case .Increment; t := s.counter % s.max_tokens; s.counter += 1; return t;
        case .Random; return mt64_next(*s.rng) % s.max_tokens;
        case .TypeHash; #through;
        case .TypeHashPointerSplit;
            n := at_get_metadata(cb);
            if n != NONE {
                name := ir.mds[md_op(n, 0)].str;
                cp := md_value_of(md_op(n, 1));
                contains_ptr := cp != NONE && vkind(cp) == .C_INT && !ap_is_zero(const_ap(cp));
                if s.mode == .TypeHash return get_stable_sip_hash(name) % s.max_tokens;
                if s.max_tokens == 1 return 0;
                half := s.max_tokens / 2;
                h := get_stable_sip_hash(name) % half;
                if contains_ptr h += half;
                return h;
            }
            return at_cl.fallback;
    }
    return 0;
}
at_is_instrumentable_lib_func :: (lf: Lib_Func, cb: Value_Id) -> bool {
    if lf == .strdup || lf == .dunder_strdup || lf == .strndup || lf == .dunder_strndup return false;
    if is_allocation_fn(cb) return true;
    if lf == {
        case .posix_memalign; #through; case .size_returning_new; #through; case .size_returning_new_hot_cold; #through;
        case .size_returning_new_aligned; #through; case .size_returning_new_aligned_hot_cold; return true;
        case .Znwj; #through; case .ZnwjRKSt9nothrow_t; #through; case .ZnwjSt11align_val_t; #through;
        case .ZnwjSt11align_val_tRKSt9nothrow_t; #through; case .Znwm; #through; case .Znwm12__hot_cold_t; #through;
        case .ZnwmRKSt9nothrow_t; #through; case .ZnwmRKSt9nothrow_t12__hot_cold_t; #through; case .ZnwmSt11align_val_t; #through;
        case .ZnwmSt11align_val_t12__hot_cold_t; #through; case .ZnwmSt11align_val_tRKSt9nothrow_t; #through;
        case .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t; #through; case .Znaj; #through; case .ZnajRKSt9nothrow_t; #through;
        case .ZnajSt11align_val_t; #through; case .ZnajSt11align_val_tRKSt9nothrow_t; #through; case .Znam; #through;
        case .Znam12__hot_cold_t; #through; case .ZnamRKSt9nothrow_t; #through; case .ZnamRKSt9nothrow_t12__hot_cold_t; #through;
        case .ZnamSt11align_val_t; #through; case .ZnamSt11align_val_t12__hot_cold_t; #through;
        case .ZnamSt11align_val_tRKSt9nothrow_t; #through; case .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t;
            return at_cl.cover_replaceable_new;
    }
    return false;
}
// getTokenAllocFunction
at_get_token_alloc_function :: (s: *At_State, cb: Value_Id, token: u64, lf: Lib_Func) -> Value_Id {
    key: u64; has_key := lf != .NotLibFunc;
    if has_key {
        key = ((cast(u64) lf) << 48) | (ifx s.fast_abi then token else 0);
        for s.fn_keys if it == key return s.fn_vals[it_index];
    }
    callee := call_called_function(cb);
    if callee == NONE return NONE;
    old := glob(callee).value_type;
    if func_vararg(old) return NONE;
    params: [..] Type_Id; params.allocator = temp;
    np := func_nparams(old);
    for k: 0..cast(s64) np - 1 array_add(*params, type_sub(old, cast(u32) k + 1));
    name := at_cl.prefix;
    if s.fast_abi name = tprint("%1%2_", name, token);
    else array_add(*params, s.int_ptr_ty);
    name = tconcat(name, vname(callee));
    nft := type_func(func_ret(old), params, false);
    f := lookup_global(name);
    if f == NONE { f = get_or_insert_function(name, nft); glob(f).attrs = glob(callee).attrs; }
    else if vkind(f) != .FUNCTION || glob(f).value_type != nft fatal("alloc-token: an existing token allocation function has another type");
    if has_key { array_add(*s.fn_keys, key); array_add(*s.fn_vals, f); }
    return f;
}
// replaceAllocationCall
at_replace_allocation_call :: (s: *At_State, cb: Value_Id, lf: Lib_Func) -> bool {
    token := at_get_token(s, cb);
    ta := at_get_token_alloc_function(s, cb, token, lf);
    if ta == NONE return false;
    if s.fast_abi { call_set_called_function(cb, ta); return true; }
    args: [..] Value_Id; args.allocator = temp;
    na := call_num_args(cb);
    for k: 0..cast(s64) na - 1 array_add(*args, call_arg(cb, cast(u32) k));
    array_add(*args, const_int(s.int_ptr_ty, token));
    b: Irb; irb_set_before(*b, cb); b.dbg = get_metadata(cb, 0);
    nc: Value_Id;
    if inst_op(cb) == .INVOKE {
        nc = rs_new_invoke(ta, args, .[], get_successor(cb, 0), get_successor(cb, 1));
        irb_insert(*b, nc);
    } else {
        nc = irb_call(*b, ta, args);
        call_set_tail_kind(nc, ifx arc_is_tail_call(cb) then cast(u32) TCK_TAIL else TCK_NONE);
    }
    inst(nc).cc = inst(cb).cc;
    copy_metadata(nc, cb);
    inst(nc).attrs = inst(cb).attrs;
    rauw_with_metadata(cb, nc);
    erase_inst_with_metadata(cb);
    return true;
}

alloc_token_run_impl :: (name: string) -> Preserved {
    s: At_State;
    s.mode = .TypeHashPointerSplit;
    if begins_with(name, "alloc-token<") {
        params := slice(name, 12, name.count - 13);
        while params.count {
            p := params;
            c := find_index_from_left(params, #char ";");
            if c >= 0 { p = slice(params, 0, c); params = slice(params, c + 1, params.count - c - 1); } else params = "";
            if begins_with(p, "mode=") {
                ok, m := at_mode_from_string(slice(p, 5, p.count - 5));
                if !ok pipeline_error("invalid argument to AllocToken pass mode parameter: '%'", slice(p, 5, p.count - 5));
                s.mode = m;
            } else pipeline_error("invalid AllocToken pass parameter '%'", p);
        }
    }
    // resolveOptions
    mf := module_flag("alloc-token-mode");
    if mf != NONE && md_is_string(mf) { ok, m := at_mode_from_string(ir.mds[mf].str); if ok s.mode = m; }
    int_flag :: (key: string) -> (bool, u64) {
        m := module_flag(key);
        if m == NONE return false, 0;
        v := md_value_of(m);
        if v == NONE || vkind(v) != .C_INT return false, 0;
        return true, const_int_zext(v);
    }
    max_tokens: u64 = 0;
    h, v := int_flag("alloc-token-max"); if h max_tokens = v;
    h, v = int_flag("alloc-token-fast-abi"); if h s.fast_abi |= v == 1;
    h, v = int_flag("alloc-token-extended"); if h s.extended |= v == 1;
    if at_cl.has_max max_tokens = at_cl.max;
    if at_cl.has_fast_abi s.fast_abi = at_cl.fast_abi;
    if at_cl.has_extended s.extended = at_cl.extended;
    s.int_ptr_ty = type_int(dl_ptr_spec(0).bits);
    mask: u64 = ifx dl_ptr_spec(0).bits >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << dl_ptr_spec(0).bits) - 1;
    s.max_tokens = ifx max_tokens then max_tokens else mask;
    if s.mode == .Random s.rng = create_rng("alloc-token");
    s.fn_keys.allocator = temp; s.fn_vals.allocator = temp;
    modified := false;
    x := 0;
    while x < ir.m_functions.count {
        f := ir.m_functions[x];
        x += 1;
        if glob(f).first_block == NONE continue;
        if fn_has_fn_attr(f, .Naked) || glob(f).linkage == .AVAILABLE_EXTERNALLY continue;
        Alloc :: struct { cb: Value_Id; lf: Lib_Func; }
        allocs: [..] Alloc; allocs.allocator = temp;
        intrinsics: [..] Value_Id; intrinsics.allocator = temp;
        instrument := fn_has_fn_attr(f, .SanitizeAllocToken) && !fn_has_fn_attr(f, .DisableSanitizerInstrumentation);
        for i: fn_insts(f) {
            if call_iid(i) == IID_ALLOC_TOKEN_ID { array_add(*intrinsics, i); continue; }
            if !instrument || !is_call_base(i) continue;
            callee := call_called_function(i);
            if callee == NONE continue;
            ok, lf := tli_lookup_fn(callee);
            if ok { if at_is_instrumentable_lib_func(lf, i) array_add(*allocs, .{i, lf}); }
            else if s.extended && get_metadata(i, md_fixed("alloc_token")) != NONE array_add(*allocs, .{i, .NotLibFunc});
        }
        if allocs.count == 0 && intrinsics.count == 0 continue;
        for allocs modified |= at_replace_allocation_call(*s, it.cb, it.lf);
        for ii: intrinsics {
            t := at_get_token(*s, ii);
            rauw_with_metadata(ii, const_int(s.int_ptr_ty, t));
            erase_inst_with_metadata(ii);
            modified = true;
        }
    }
    if !modified return PRESERVE_ALL;
    return preserved_cfg();
}
