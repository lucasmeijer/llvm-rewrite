// Parts of the sample profile loader that are not ported yet: each fails loudly when reached.

sp_raw_binary_has_format :: (data: string) -> bool { return sp_binary_magic(data) == sp_magic(0xff); }
sp_ext_binary_has_format :: (data: string) -> bool { return sp_binary_magic(data) == sp_magic(0x4); }
// SPMagic(Format)
sp_magic :: (format: u64) -> u64 {
    return ((cast(u64) #char "S") << 56) | ((cast(u64) #char "P") << 48) | ((cast(u64) #char "R") << 40) | ((cast(u64) #char "O") << 32) |
           ((cast(u64) #char "F") << 24) | ((cast(u64) #char "4") << 16) | ((cast(u64) #char "2") << 8) | format;
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

sp_remapper_create :: (file: string) { fatal("sample-profile: -sample-profile-remapping-file (SampleProfileReaderItaniumRemapper) is not implemented yet"); }
sp_remapper_apply :: () {}
sp_remapper_lookup :: (name: string) -> (bool, string) { return false, ""; }

// SampleContextTracker: sample_context_tracker.jai




