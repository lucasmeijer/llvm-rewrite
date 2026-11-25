// Parts of the sample profile loader that are not ported yet: each fails loudly when reached.

sp_raw_binary_has_format :: (data: string) -> bool { return sp_binary_magic(data) == sp_magic(0xff); }
sp_ext_binary_has_format :: (data: string) -> bool { return sp_binary_magic(data) == sp_magic(0x4); }
sp_gcc_has_format :: (data: string) -> bool { return data.count >= 8 && sr_substr(data, 0, 8) == "adcg*704"; }
// SPMagic(Format)
sp_magic :: (format: u64) -> u64 {
    return (cast(u64) #char "S") << 56 | (cast(u64) #char "P") << 48 | (cast(u64) #char "R") << 40 | (cast(u64) #char "O") << 32 |
           (cast(u64) #char "F") << 24 | (cast(u64) #char "4") << 16 | (cast(u64) #char "2") << 8 | format;
}
// the ULEB128 magic number at the start of a binary profile
sp_binary_magic :: (data: string) -> u64 {
    v: u64 = 0; shift: u64 = 0;
    for i: 0..data.count - 1 {
        b := cast(u64) data[i];
        if shift < 64 v |= (b & 0x7f) << shift;
        shift += 7;
        if (b & 0x80) == 0 return v;
        if i >= 10 return 0;
    }
    return 0;
}
sp_raw_binary_read :: () { fatal("sample-profile: the binary sample profile format is not implemented yet"); }
sp_ext_binary_read :: () { fatal("sample-profile: the extensible binary sample profile format is not implemented yet"); }
sp_gcc_read :: () { fatal("sample-profile: the GCC (gcov) sample profile format is not implemented yet"); }

sp_remapper_create :: (file: string) { fatal("sample-profile: -sample-profile-remapping-file (SampleProfileReaderItaniumRemapper) is not implemented yet"); }
sp_remapper_apply :: () {}
sp_remapper_lookup :: (name: string) -> (bool, string) { return false, ""; }

sp_context_tracker_init :: () { fatal("sample-profile: context-sensitive profiles (SampleContextTracker) are not implemented yet"); }
sp_ctx_get_base_samples_for :: (f: Value_Id) -> *Fs { return null; }
sp_ctx_get_context_samples_for :: (dil: Md_Id) -> *Fs { return null; }
sp_ctx_get_callee_context_samples_for :: (i: Value_Id, callee: string) -> *Fs { return null; }
sp_ctx_get_indirect_callee_context_samples_for :: (dil: Md_Id) -> [..] *Fs { r: [..] *Fs; return r; }
sp_ctx_mark_context_samples_inlined :: (fs: *Fs) {}
sp_ctx_find_external_inline_candidate :: (fs: *Fs, s: *[..] u64, threshold: u64) {}
sp_ctx_add_profiled_calls :: (g: *Pcg) {}

sp_matcher_init :: () { fatal("sample-profile: stale profile matching (SampleProfileMatcher) is not implemented yet"); }
sp_matcher_run_on_module :: () {}

sp_apply_profi :: (f: Value_Id, sample_weights: *Table(Value_Id, u64)) { fatal("sample-profile: profile inference (-sample-profile-use-profi, SampleProfileInference) is not implemented yet"); }

