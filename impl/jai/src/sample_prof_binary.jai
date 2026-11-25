// The binary sample profile readers: SampleProfileReaderRawBinary and SampleProfileReaderExtBinary.
// Ported from llvm/lib/ProfileData/SampleProfReader.cpp (SampleProfileReaderBinary: readNumber, readString,
// readUnencodedNumber, readStringFromTable, readContextFromTable, readSampleContextFromTable, readProfile,
// readFuncProfile, readImpl, readNameTable, readMagicIdent, readHeader, readSummary; SampleProfileReaderExtBinaryBase:
// readOneSection, useFuncOffsetList, collectFuncsFromModule, readFuncOffsetTable, readFuncProfiles,
// readProfileSymbolList, decompressSection, readImpl, readNameTableSec, readCSNameTableSec, readFuncMetadata,
// readSecHdrTable, readHeader) and ProfileSymbolList::read (llvm/lib/ProfileData/SampleProf.cpp).
// Not ported (loud): vtable type profiles (SecFlagHasVTableTypeProf).

SP_SEC_PROF_SUMMARY :: 1; SP_SEC_NAME_TABLE :: 2; SP_SEC_PROFILE_SYMBOL_LIST :: 3; SP_SEC_FUNC_OFFSET_TABLE :: 4;
SP_SEC_FUNC_METADATA :: 5; SP_SEC_CS_NAME_TABLE :: 6; SP_SEC_LBR_PROFILE :: 32;
SP_FORMAT_VERSION :: 103;   // SPVersion()

Sp_Sec_Hdr :: struct { type: u64; flags: u64; offset: u64; size: u64; }

Spb :: struct {
    data: string;                 // the bytes being read (the file, or a decompressed section)
    pos: s64;
    end: s64;
    md5_ctx_table: [..] u64;      // MD5SampleContextTable (0 = not computed yet)
    cs_name_table: [..] [] Ctx_Frame;
    sec_hdrs: [..] Sp_Sec_Hdr;
    func_offset_list: [..] struct { ctx: Sample_Context; offset: u64; };
    func_offset_table: Table(u64, u64);
    has_func_offset_table: bool;
    profile_has_attribute: bool;
    read_vtable_prof: bool;
    profile_sec_start: s64;       // ProfileSecRange (in `data` of the section)
}
spb: Spb;

spb_error :: (msg: string) {
    // reportError(0, EC.message()) / "profile reading failed: <message>"
    fatal("%: profile reading failed: %", sp_reader.file, msg);
}

// readNumber<T>
spb_read_number :: (max: u64 = 0xFFFF_FFFF_FFFF_FFFF) -> u64 {
    b := *spb;
    v: u64 = 0; shift: u64 = 0;
    p := b.pos;
    while true {
        if p >= b.end spb_error("Truncated profile data");
        c := cast(u64) b.data[p];
        p += 1;
        if shift < 64 v |= (c & 0x7f) << shift;
        else if (c & 0x7f) != 0 spb_error("Malformed sample profile data");
        shift += 7;
        if (c & 0x80) == 0 break;
    }
    if v > max spb_error("Malformed sample profile data");
    b.pos = p;
    return v;
}
spb_read_u32 :: () -> u32 { return cast(u32) spb_read_number(0xFFFF_FFFF); }
// readString
spb_read_string :: () -> string {
    b := *spb;
    p := b.pos;
    while p < b.end && b.data[p] != 0 p += 1;
    if p >= b.end spb_error("Truncated profile data");
    s := slice(b.data, b.pos, p - b.pos);
    b.pos = p + 1;
    return s;
}
// readUnencodedNumber<uint64_t> (little endian)
spb_read_u64_le :: () -> u64 {
    b := *spb;
    if b.pos + 8 > b.end spb_error("Truncated profile data");
    v: u64 = 0;
    for k: 0..7 v |= (cast(u64) b.data[b.pos + k]) << (cast(u64) k * 8);
    b.pos += 8;
    return v;
}
spb_is_offset_legal :: (l: u64) -> bool { return (l & 0xFFFF) == l; }

// readStringFromTable
spb_read_string_from_table :: () -> (Fid, s64) {
    idx := spb_read_number();
    if idx >= cast(u64) sp_reader.name_table.count spb_error("Function name table is truncated");
    return sp_reader.name_table[idx], cast(s64) idx;
}
// readSampleContextFromTable
spb_read_sample_context_from_table :: () -> (Sample_Context, u64) {
    c: Sample_Context;
    idx: s64;
    if sp_reader.is_cs {
        k := spb_read_number();
        if k >= cast(u64) spb.cs_name_table.count spb_error("Function name table is truncated");
        idx = cast(s64) k;
        ctx_set_context(*c, spb.cs_name_table[idx]);
    } else {
        f: Fid;
        f, idx = spb_read_string_from_table();
        c.func = f;
    }
    h := spb.md5_ctx_table[idx];
    if h == 0 {
        h = sp_ctx_hash_code(*c);
        spb.md5_ctx_table[idx] = h;
    }
    return c, h;
}
// SampleContext::getHashCode
sp_ctx_hash_code :: (c: *Sample_Context) -> u64 {
    if ctx_has_context(c) fatal("sample-profile: hashing a full (CS) context is not implemented yet");
    return fid_hash(c.func);
}

// readProfile
spb_read_profile :: (fs: *Fs) {
    fs_add_total(fs, spb_read_number());
    num_records := spb_read_u32();
    for 1..num_records {
        line := spb_read_number();
        if !spb_is_offset_legal(line) spb_error("Illegal line offset in sample profile data");
        disc := spb_read_number();
        n := spb_read_number();
        num_calls := spb_read_u32();
        d := cast(u32) disc & sp_discriminator_mask();
        for 1..num_calls {
            callee := spb_read_string_from_table();
            c := spb_read_number();
            fs_add_called_target_samples(fs, cast(u32) line, d, callee, c);
        }
        fs_add_body_samples(fs, cast(u32) line, d, n);
    }
    num_callsites := spb_read_u32();
    for 1..num_callsites {
        line := spb_read_number();
        disc := spb_read_number();
        fname := spb_read_string_from_table();
        d := cast(u32) disc & sp_discriminator_mask();
        callee := cs_at(fs_function_samples_at(fs, .{cast(u32) line, d}), fname);
        fs_set_function(callee, fname);
        spb_read_profile(callee);
    }
    if spb.read_vtable_prof fatal("sample-profile: vtable type profiles are not supported");
}
// readFuncProfile
spb_read_func_profile :: (start: s64) {
    spb.pos = start;
    head := spb_read_number();
    c, h := spb_read_sample_context_from_table();
    fs := sp_profiles_create(*sp_reader, c);
    fs.ctx = c;
    fs_add_head(fs, head);
    spb_read_profile(fs);
}

// readNameTable (also the ext-binary name table without MD5)
spb_read_name_table :: () {
    r := *sp_reader;
    size := spb_read_number();
    r.name_table.count = 0;
    if !r.is_cs { spb.md5_ctx_table.count = 0; }
    for 1..size {
        name := spb_read_string();
        if r.use_md5 {
            // FunctionId(StringRef) of an MD5 profile: the name is the decimal MD5 (readNameTable with useMD5())
            fid := fid_of(name);
            if !r.is_cs array_add(*spb.md5_ctx_table, fid_hash(fid));
            array_add(*r.name_table, fid);
        } else {
            array_add(*r.name_table, fid_of(name));
            if !r.is_cs array_add(*spb.md5_ctx_table, 0);
        }
    }
}
// readNameTableSec
spb_read_name_table_sec :: (is_md5: bool, fixed_length_md5: bool) {
    r := *sp_reader;
    if fixed_length_md5 {
        if !is_md5 print_to_stderr("If FixedLengthMD5 is true, UseMD5 has to be true");
        size := spb_read_number();
        if spb.pos + cast(s64) size * 8 > spb.end spb_error("Truncated profile data");
        r.name_table.count = 0;
        if !r.is_cs spb.md5_ctx_table.count = 0;
        for 1..size {
            h := spb_read_u64_le();
            array_add(*r.name_table, fid_of_hash(h));
            if !r.is_cs array_add(*spb.md5_ctx_table, h);
        }
        return;
    }
    if is_md5 {
        size := spb_read_number();
        r.name_table.count = 0;
        if !r.is_cs spb.md5_ctx_table.count = 0;
        for 1..size {
            h := spb_read_number();
            if !r.is_cs array_add(*spb.md5_ctx_table, h);
            array_add(*r.name_table, fid_of_hash(h));
        }
        return;
    }
    spb_read_name_table();
}
// readCSNameTableSec
spb_read_cs_name_table_sec :: () {
    size := spb_read_number();
    spb.cs_name_table.count = 0;
    if sp_reader.is_cs { spb.md5_ctx_table.count = 0; for 1..size array_add(*spb.md5_ctx_table, 0); }
    for 1..size {
        n := spb_read_u32();
        frames := NewArray(n, Ctx_Frame);
        for k: 0..cast(s64) n - 1 {
            fname := spb_read_string_from_table();
            line := spb_read_number();
            if !spb_is_offset_legal(line) spb_error("Illegal line offset in sample profile data");
            disc := spb_read_number();
            frames[k] = .{fname, .{cast(u32) line, cast(u32) disc}};
        }
        array_add(*spb.cs_name_table, frames);
    }
}

// readSummary
spb_read_summary :: () {
    s := *sp_reader.summary;
    s.total_count = spb_read_number();
    s.max_count = spb_read_number();
    s.max_function_count = spb_read_number();
    s.num_counts = spb_read_number();
    s.num_functions = spb_read_number();
    s.max_internal_count = 0;
    n := spb_read_number();
    s.detailed.count = 0;
    for 1..n {
        e: Psi_Entry;
        e.cutoff = spb_read_number();
        e.min_count = spb_read_number();
        e.num_counts = spb_read_number();
        array_add(*s.detailed, e);
    }
}

// readMagicIdent
spb_read_magic_ident :: (expected: u64) {
    m := spb_read_number();
    if m != expected spb_error("Invalid sample profile data (bad magic)");
    v := spb_read_number();
    if v != SP_FORMAT_VERSION fatal("%: Could not open profile: Unsupported sample profile format version", sp_reader.file);
}

// SampleProfileReaderRawBinary: readHeader + readImpl
sp_raw_binary_read :: () {
    r := *sp_reader;
    spb.data = r.buffer; spb.pos = 0; spb.end = r.buffer.count;
    spb_read_magic_ident(sp_magic(0xff));
    spb_read_summary();
    spb_read_name_table();
    r.is_fs = sp_opts.profile_isfs;   // ProfileIsFSDisciminator
    sp_flags.fs = r.is_fs;
    while spb.pos < spb.end spb_read_func_profile(spb.pos);
}

spb_has_flag :: (e: Sp_Sec_Hdr, flag: u64, common := false) -> bool {
    return (e.flags & (ifx common then flag else flag << 32)) != 0;
}

// useFuncOffsetList
spb_use_func_offset_list :: () -> bool {
    r := *sp_reader;
    if r.is_cs return true;
    if r.use_md5 return false;
    if r.remapper_present return true;
    return false;
}
// readFuncOffsetTable
spb_read_func_offset_table :: () {
    spb.func_offset_list.count = 0;
    table_reset(*spb.func_offset_table);
    size := spb_read_number();
    use_list := spb_use_func_offset_list();
    spb.has_func_offset_table = !use_list;
    for 1..size {
        c, h := spb_read_sample_context_from_table();
        off := spb_read_number();
        if use_list array_add(*spb.func_offset_list, .{c, off});
        else table_set(*spb.func_offset_table, h, off);   // DenseMap insert: the first offset of a hash stays
    }
}
// readFuncProfiles(FuncsToUse, Profiles): the module's canonical function names
spb_read_func_profiles_for_module :: () {
    r := *sp_reader;
    start := spb.pos;
    if r.remapper_present fatal("sample-profile: an ext-binary profile with -sample-profile-remapping-file is not implemented yet");
    if r.is_cs fatal("sample-profile: context-sensitive ext-binary profiles are not implemented yet");
    if !spb.has_func_offset_table fatal("sample-profile: an ext-binary profile without a function offset table is not supported");
    // FuncsToUse is a DenseSet<StringRef>: the profiles are read in hash order, but each profile is keyed by its
    // own hash and the order of the profile map is not observable here (no observable effect of the order)
    seen: Table(string, bool); seen.allocator = temp;
    for f: ir.m_functions {
        name := sp_canonical_fn_name_of(f);
        if table_contains(*seen, name) continue;
        table_set(*seen, name, true);
        found, off := table_find(*spb.func_offset_table, md5_hash_u64(name));
        if found spb_read_func_profile(start + cast(s64) off);
    }
}
// readFuncMetadata(ProfileHasAttribute, FProfile)
spb_read_func_metadata_one :: (fs: *Fs) {
    r := *sp_reader;
    if spb.pos >= spb.end return;
    if r.is_probe_based {
        h := spb_read_number();
        if fs fs.function_hash = h;
    }
    if spb.profile_has_attribute {
        a := spb_read_u32();
        if fs fs.ctx.attrs = a;
    }
    if !r.is_cs {
        n := spb_read_u32();
        for 1..n {
            line := spb_read_number();
            disc := spb_read_number();
            c, _ := spb_read_sample_context_from_table();
            callee: *Fs = null;
            if fs callee = cs_at(fs_function_samples_at(fs, .{cast(u32) line, cast(u32) disc}), c.func);
            spb_read_func_metadata_one(callee);
        }
    }
}
// readFuncMetadata(ProfileHasAttribute)
spb_read_func_metadata :: () {
    r := *sp_reader;
    while spb.pos < spb.end {
        c, _ := spb_read_sample_context_from_table();
        fs := sp_profiles_find_ctx(r, *c);
        spb_read_func_metadata_one(fs);
    }
}
// ProfileSymbolList::read
spb_read_profile_symbol_list :: () {
    r := *sp_reader;
    r.has_psl = true;
    while spb.pos < spb.end {
        s := spb_read_string();
        table_set(*r.psl, s, true);
    }
}

// readOneSection
spb_read_one_section :: (e: Sp_Sec_Hdr) {
    r := *sp_reader;
    if e.type == {
      case SP_SEC_PROF_SUMMARY;
        spb_read_summary();
        if spb_has_flag(e, 1 << 0) r.summary.partial = true;
        if spb_has_flag(e, 1 << 1) { r.is_cs = true; sp_flags.cs = true; }
        if spb_has_flag(e, 1 << 4) { r.is_preinlined = true; sp_flags.preinlined = true; }
        if spb_has_flag(e, 1 << 2) { r.is_fs = true; sp_flags.fs = true; }
        if spb_has_flag(e, 1 << 5) spb.read_vtable_prof = true;
      case SP_SEC_NAME_TABLE;
        fixed := spb_has_flag(e, 1 << 1);
        md5 := spb_has_flag(e, 1 << 0);
        r.use_md5 = r.use_md5 || md5;
        sp_flags.has_uniq_suffix = spb_has_flag(e, 1 << 2);
        spb_read_name_table_sec(md5, fixed);
      case SP_SEC_CS_NAME_TABLE;
        spb_read_cs_name_table_sec();
      case SP_SEC_LBR_PROFILE;
        spb.profile_sec_start = spb.pos;
        // readFuncProfiles(): the module is set, so only the functions it uses are read
        spb_read_func_profiles_for_module();
        spb.pos = spb.end;
      case SP_SEC_FUNC_OFFSET_TABLE;
        spb_read_func_offset_table();
      case SP_SEC_FUNC_METADATA;
        r.is_probe_based = spb_has_flag(e, 1 << 0);
        sp_flags.probe_based = r.is_probe_based;
        spb.profile_has_attribute = spb_has_flag(e, 1 << 1);
        spb_read_func_metadata();
      case SP_SEC_PROFILE_SYMBOL_LIST;
        spb_read_profile_symbol_list();
      case;
        spb.pos = spb.end;   // readCustomSection: skipped
    }
}

zlib_uncompress :: (dest: *u8, dest_len: *u64, source: *u8, source_len: u64) -> s32 #foreign libz "uncompress";

// SampleProfileReaderExtBinaryBase: readHeader + readImpl
sp_ext_binary_read :: () {
    r := *sp_reader;
    spb.data = r.buffer; spb.pos = 0; spb.end = r.buffer.count;
    spb_read_magic_ident(sp_magic(0x4));
    n := spb_read_u64_le();
    for 1..n {
        e: Sp_Sec_Hdr;
        e.type = spb_read_u64_le(); e.flags = spb_read_u64_le(); e.offset = spb_read_u64_le(); e.size = spb_read_u64_le();
        array_add(*spb.sec_hdrs, e);
    }
    for e: spb.sec_hdrs {
        if e.size == 0 continue;
        if r.skip_flat_prof && spb_has_flag(e, 1 << 1, common = true) continue;
        sec_start := cast(s64) e.offset;
        sec_size := cast(s64) e.size;
        spb.data = r.buffer;
        if spb_has_flag(e, 1 << 0, common = true) {
            // decompressSection
            spb.pos = sec_start; spb.end = sec_start + sec_size;
            dsize := spb_read_number();
            csize := spb_read_number();
            buf := cast(*u8) alloc(cast(s64) dsize);
            uc := dsize;
            if zlib_uncompress(buf, *uc, spb.data.data + spb.pos, csize) != 0 || uc != dsize
                spb_error("Uncompress failure");
            dec: string; dec.data = buf; dec.count = cast(s64) dsize;
            spb.data = dec;
            sec_start = 0;
            sec_size = cast(s64) dsize;
        }
        spb.pos = sec_start; spb.end = sec_start + sec_size;
        spb_read_one_section(e);
        if spb.pos != sec_start + sec_size spb_error("Malformed sample profile data");
    }
    spb.data = r.buffer;
}
