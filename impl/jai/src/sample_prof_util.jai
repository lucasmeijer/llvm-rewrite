// Sample profile helpers: ProfileConverter::flattenProfile (llvm/include/llvm/ProfileData/SampleProf.h),
// ProfileSymbolList::contains, extractProbe / setProbeDistributionFactor (llvm/lib/IR/PseudoProbe.cpp).

// flattenNestedProfile
sp_flatten_nested :: (out: *Sp_Reader, fs: *Fs) {
    profile := sp_profiles_find_ctx(out, *fs.ctx);
    if !profile {
        profile = sp_profiles_create(out, fs.ctx);
        p := profile;
        c := fs_clone(fs);
        p.* = c.*;
        p.callsites.count = 0;   // removeAllCallsiteSamples
        p.total = 0;
    } else {
        for * fs.body sr_merge(fs_body_at(profile, it.loc), *it.rec, 1);   // addSampleRecord
    }
    total := fs.total;
    for cs: fs.callsites for cs.callees {
        callee := it.fs;
        h := fs_head_samples_estimate(callee);
        fs_add_body_samples(profile, cs.loc.line, cs.loc.disc, h);
        fs_add_called_target_samples(profile, cs.loc.line, cs.loc.disc, fs_func(callee), h);
        total = ifx total >= callee.total then total - callee.total else 0;
        total += h;
        sp_flatten_nested(out, callee);
    }
    fs_add_total(profile, total);
    profile.head = fs_head_samples_estimate(profile);
}

// ProfileConverter::flattenProfile(InputProfiles, OutputProfiles, ProfileIsCS) into a fresh map
sp_flatten_to :: (input: [] *Fs, is_cs: bool) -> *Sp_Reader {
    out := New(Sp_Reader);
    if is_cs {
        for input {
            c: Sample_Context; c.func = fs_func(it);
            fs := sp_profiles_create(out, c);
            fs_merge(fs, it, 1);
        }
    } else {
        for input sp_flatten_nested(out, it);
    }
    return out;
}
// the flattened copy of the profiles (computeSummaryForProfiles)
sp_flatten_profiles_copy :: (input: [] *Fs, is_cs: bool) -> [] *Fs {
    out := sp_flatten_to(input, is_cs);
    return out.profiles;
}
// ProfileConverter::flattenProfile(Reader->getProfiles(), Reader->profileIsCS())
sp_flatten_profiles_in_place :: () {
    r := *sp_reader;
    out := sp_flatten_to(r.profiles, r.is_cs);
    r.profiles = out.profiles;
    r.by_hash = out.by_hash;
    r.by_ctx = out.by_ctx;
}

// ProfileSymbolList::contains
sp_psl_contains :: (name: string) -> bool {
    r := *sp_reader;
    if !r.has_psl return false;
    return table_contains(*r.psl, name);
}

// ---------------------------------------------------------------- pseudo probes

Sp_Probe :: struct { id: u32; type: u32; attr: u32; disc: u32; factor: float32; }
PSEUDO_PROBE_FULL_DISTRIBUTION_FACTOR : u64 : 0xFFFF_FFFF_FFFF_FFFF;

// extractProbe
sp_extract_probe :: (i: Value_Id) -> (bool, Sp_Probe) {
    p: Sp_Probe;
    if call_iid(i) == IID_PSEUDOPROBE {
        p.id = cast(u32) const_int_zext(call_arg(i, 1));
        p.type = 0;
        p.attr = cast(u32) const_int_zext(call_arg(i, 2));
        p.factor = u64_to_f32(const_int_zext(call_arg(i, 3))) / u64_to_f32(PSEUDO_PROBE_FULL_DISTRIBUTION_FACTOR);
        p.disc = 0;
        dil := get_metadata(i, 0);
        if dil != NONE p.disc = diloc_discriminator(dil);
        return true, p;
    }
    if is_call_base(i) && !sp_is_intrinsic_inst(i) {
        dil := get_metadata(i, 0);
        if dil == NONE return false, p;
        d := diloc_discriminator(dil);
        if !disc_is_pseudo_probe(d) return false, p;
        p.id = probe_extract_index(d);
        p.type = probe_extract_type(d);
        p.attr = probe_extract_attributes(d);
        p.factor = cast(float32) probe_extract_factor(d) / cast(float32) 100;
        p.disc = 0;
        return true, p;
    }
    return false, p;
}

// setProbeDistributionFactor
sp_set_probe_distribution_factor :: (i: Value_Id, factor: float32) {
    if call_iid(i) == IID_PSEUDOPROBE {
        int_factor := PSEUDO_PROBE_FULL_DISTRIBUTION_FACTOR;
        if factor < 1 int_factor = f32_to_u64(u64_to_f32(int_factor) * factor);   // IntFactor *= Factor (in float)
        orig := const_int_zext(call_arg(i, 3));
        if int_factor != orig set_op(i, 3, const_int(ir.t_i64, int_factor));
        return;
    }
    if is_call_base(i) && !sp_is_intrinsic_inst(i) {
        dil := get_metadata(i, 0);
        if dil == NONE return;
        d := diloc_discriminator(dil);
        if !disc_is_pseudo_probe(d) return;
        index := probe_extract_index(d);
        type := probe_extract_type(d);
        attr := probe_extract_attributes(d);
        has_base, base := probe_extract_dwarf_base_discriminator(d);
        int_factor: u32 = 100;
        if factor < 1 int_factor = cast(u32) (cast(float32) int_factor * factor);
        v := probe_pack(index, type, attr, int_factor, has_base, base);
        set_metadata(i, 0, diloc_clone_with_discriminator(dil, v));
    }
}

// a float -> uint64_t conversion (also for values >= 2^63)
f32_to_u64 :: (v: float32) -> u64 {
    if v >= 9223372036854775808.0 return (cast(u64) (cast(float64) v - 9223372036854775808.0)) + 0x8000_0000_0000_0000;
    if v <= 0 return 0;
    return cast(u64) v;
}
// (float) of a uint64_t (round to nearest)
u64_to_f32 :: (v: u64) -> float32 {
    if v < 0x8000_0000_0000_0000 return cast(float32) cast(s64) v;
    h := (v >> 1) | (v & 1);
    return cast(float32) cast(s64) h * 2;
}
