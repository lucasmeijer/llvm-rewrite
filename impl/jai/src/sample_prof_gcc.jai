// The GCC (gcov / AutoFDO) sample profile reader: SampleProfileReaderGCC.
// Ported from llvm/lib/ProfileData/SampleProfReader.cpp (readHeader, readSectionTag, readNameTable,
// readFunctionProfiles, readOneFunctionProfile, readImpl, hasFormat) and GCOVBuffer (llvm/include/llvm/ProfileData/
// GCOV.h: readGCDAFormat, readGCOVVersion, readInt, readInt64, readString for versions before 12).

SP_GCOV_TAG_AFDO_FILE_NAMES :: 0xaa000000;
SP_GCOV_TAG_AFDO_FUNCTION :: 0xac000000;
SP_HIST_TYPE_INDIR_CALL_TOPN :: 7;

Spg :: struct {
    data: string;    // after the 4-byte magic
    pos: s64;
    little: bool;
    names: [..] string;
}
spg: Spg;

sp_gcc_has_format :: (data: string) -> bool {
    // StringRef Magic(Buffer.getBufferStart()): the buffer as a C string
    n := 0;
    while n < data.count && data[n] != 0 n += 1;
    return slice(data, 0, n) == "adcg*704";
}

spg_truncated :: () { fatal("%: profile reading failed: Truncated profile data", sp_reader.file); }
spg_malformed :: () { fatal("%: profile reading failed: Malformed sample profile data", sp_reader.file); }

// GCOVBuffer::readInt
spg_read_int :: () -> u32 {
    if spg.pos + 4 > spg.data.count {
        print_to_stderr("unexpected end of memory buffer: %\n", spg.pos);
        spg_truncated();
    }
    b0 := cast(u32) spg.data[spg.pos]; b1 := cast(u32) spg.data[spg.pos + 1];
    b2 := cast(u32) spg.data[spg.pos + 2]; b3 := cast(u32) spg.data[spg.pos + 3];
    spg.pos += 4;
    if spg.little return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    return b3 | (b2 << 8) | (b1 << 16) | (b0 << 24);
}
spg_read_int64 :: () -> u64 { lo := spg_read_int(); hi := spg_read_int(); return ((cast(u64) hi) << 32) | lo; }
// GCOVBuffer::readString (version < V1200: len words, up to the first NUL)
spg_read_string :: () -> string {
    len := spg_read_int();
    if len == 0 spg_truncated();
    n := cast(s64) len * 4;
    if spg.pos + n > spg.data.count spg_truncated();
    s := slice(spg.data, spg.pos, n);
    spg.pos += n;
    k := 0;
    while k < s.count && s[k] != 0 k += 1;
    return slice(s, 0, k);
}
// readSectionTag
spg_read_section_tag :: (expected: u32) {
    tag := spg_read_int();
    if tag != expected spg_malformed();
    spg_read_int();   // skipNextWord
}

// readOneFunctionProfile
spg_read_one_function_profile :: (stack: [] *Fs, update_in: bool, offset: u32) {
    update := update_in;
    head: u64 = 0;
    if stack.count == 0 head = spg_read_int64();
    name_idx := spg_read_int();
    if name_idx >= cast(u32) spg.names.count spg_malformed();
    name := spg.names[name_idx];
    num_pos_counts := spg_read_int();
    num_callsites := spg_read_int();
    fs: *Fs;
    if stack.count == 0 {
        c: Sample_Context; c.func = fid_of(name);
        fs = sp_profiles_create(*sp_reader, c);
        fs_add_head(fs, head);
        if fs.total > 0 update = false;
    } else {
        caller := stack[0];
        fs = cs_at(fs_function_samples_at(caller, .{offset >> 16, offset & 0xFFFF}), fid_of(name));
    }
    fs_set_function(fs, fid_of(name));
    new_stack := NewArray(stack.count + 1, *Fs,, allocator = temp);
    new_stack[0] = fs;
    for stack new_stack[it_index + 1] = it;
    for 1..num_pos_counts {
        off := spg_read_int();
        num_targets := spg_read_int();
        count := spg_read_int64();
        line := off >> 16; disc := off & 0xFFFF;
        if update {
            for new_stack fs_add_total(it, count);
            fs_add_body_samples(fs, line, disc, count);
        }
        for 1..num_targets {
            hist := spg_read_int();
            if hist != SP_HIST_TYPE_INDIR_CALL_TOPN spg_malformed();
            target_idx := spg_read_int64();
            if target_idx >= cast(u64) spg.names.count spg_malformed();
            target_count := spg_read_int64();
            if update fs_add_called_target_samples(fs, line, disc, fid_of(spg.names[target_idx]), target_count);
        }
    }
    for 1..num_callsites {
        off := spg_read_int();
        spg_read_one_function_profile(new_stack, update, off);
    }
}

// SampleProfileReaderGCC: readHeader + readImpl
sp_gcc_read :: () {
    r := *sp_reader;
    buf := r.buffer;
    magic := slice(buf, 0, 4);
    if magic == "gcda" spg.little = false;
    else if magic == "adcg" spg.little = true;
    else fatal("%: Could not open profile: Unrecognized sample profile encoding format", r.file);
    spg.data = slice(buf, 4, buf.count - 4);
    spg.pos = 0;
    // readGCOVVersion
    if spg.data.count < 4 fatal("%: Could not open profile: Unrecognized sample profile encoding format", r.file);
    v: [4] u8;
    for k: 0..3 v[k] = spg.data[k];
    if spg.little { t := v[0]; v[0] = v[3]; v[3] = t; t = v[1]; v[1] = v[2]; v[2] = t; }
    spg.pos = 4;
    ver: s64;
    if v[0] >= #char "A" ver = (cast(s64) v[0] - #char "A") * 100 + (cast(s64) v[1] - #char "0") * 10 + cast(s64) v[2] - #char "0";
    else ver = (cast(s64) v[0] - #char "0") * 10 + cast(s64) v[2] - #char "0";
    if ver < 47 || ver >= 48 fatal("%: Could not open profile: Unsupported sample profile format version", r.file);   // only GCOV::V407
    spg_read_int();   // skipNextWord
    // readNameTable
    spg_read_section_tag(SP_GCOV_TAG_AFDO_FILE_NAMES);
    n := spg_read_int();
    for 1..n array_add(*spg.names, copy_string(spg_read_string()));
    // readFunctionProfiles
    spg_read_section_tag(SP_GCOV_TAG_AFDO_FUNCTION);
    nf := spg_read_int();
    for 1..nf spg_read_one_function_profile(.[], true, 0);
    sp_compute_summary();
}
