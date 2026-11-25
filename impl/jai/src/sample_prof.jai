// Sample profile data and readers.
// Ported from llvm/include/llvm/ProfileData/SampleProf.h + llvm/lib/ProfileData/SampleProf.cpp (FunctionSamples,
// SampleRecord, SampleContext, LineLocation), llvm/include/llvm/ProfileData/FunctionId.h (FunctionId),
// llvm/lib/ProfileData/SampleProfReader.cpp + SampleProfReader.h (the text reader; binary, ext-binary and gcc
// readers in sample_prof_binary.jai) and SampleProfileSummaryBuilder / ProfileSummaryBuilder::computeDetailedSummary
// (llvm/lib/ProfileData/ProfileSummaryBuilder.cpp), ProfileSummary::getMD (llvm/lib/IR/ProfileSummary.cpp).
//
// FunctionSamples are heap rows (`*Fs`) that never move, like the nodes of LLVM's std::maps; the maps themselves
// (BodySampleMap, CallsiteSampleMap, FunctionSamplesMap) are arrays kept sorted by their keys.

// ---------------------------------------------------------------- FunctionId

// FunctionId: a name, or (MD5 profiles) only the MD5 hash of the name. h == 0 and no name = the empty id.
Fid :: struct { s: string; h: u64; md5: bool; }
fid_of :: (s: string) -> Fid { f: Fid; f.s = s; return f; }
fid_of_hash :: (h: u64) -> Fid { f: Fid; f.h = h; f.md5 = true; return f; }
fid_len :: inline (f: Fid) -> u64 { return ifx f.md5 then f.h else cast(u64) f.s.count; }
fid_empty :: (f: Fid) -> bool { return fid_len(f) == 0; }
// FunctionId::getHashCode
fid_hash :: (f: Fid) -> u64 { if f.md5 return f.h; return md5_hash_u64(f.s); }
fid_eq :: (a: Fid, b: Fid) -> bool {
    if fid_len(a) != fid_len(b) return false;
    if a.md5 != b.md5 return fid_len(a) == 0 && false;
    if a.md5 return true;
    return a.s == b.s;
}
// FunctionId::compare (compareMemory treats a missing name as smaller)
fid_cmp :: (a: Fid, b: Fid) -> s64 {
    n := min(fid_len(a), fid_len(b));
    r: s64 = 0;
    if a.md5 && b.md5 r = 0;
    else if a.md5 r = -1;
    else if b.md5 r = 1;
    else {
        for i: 0..cast(s64) n - 1 {
            ca := a.s[i]; cb := b.s[i];
            if ca != cb { r = ifx ca < cb then -1 else 1; break; }
        }
    }
    if r != 0 return r;
    la := fid_len(a); lb := fid_len(b);
    if la == lb return 0;
    return ifx la < lb then -1 else 1;
}
// FunctionId::str
fid_str :: (f: Fid) -> string {
    if !f.md5 return f.s;
    if f.h != 0 return tprint("%", f.h);
    return "";
}
// getRepInFormat
fid_rep_in_format :: (name: string) -> Fid {
    if name.count == 0 || !sp_flags.use_md5 return fid_of(name);
    return fid_of_hash(md5_hash_u64(name));
}

// ---------------------------------------------------------------- LineLocation, SampleRecord

Line_Loc :: struct { line: u32; disc: u32; }
loc_cmp :: (a: Line_Loc, b: Line_Loc) -> s64 {
    if a.line != b.line return ifx a.line < b.line then -1 else 1;
    if a.disc != b.disc return ifx a.disc < b.disc then -1 else 1;
    return 0;
}
loc_eq :: (a: Line_Loc, b: Line_Loc) -> bool { return a.line == b.line && a.disc == b.disc; }
loc_hash :: (l: Line_Loc) -> u64 { return ((cast(u64) l.disc) << 32) | l.line; }

Call_Target :: struct { f: Fid; count: u64; }
Sample_Record :: struct {
    samples: u64;
    targets: [..] Call_Target;   // CallTargetMap (a DenseMap; every use is order independent or sorts)
}

sp_sat_mul_add :: (x: u64, y: u64, a: u64) -> (u64, bool) { r, o := saturating_multiply_add(x, y, a); return r, o; }

sr_add_samples :: (r: *Sample_Record, s: u64, w: u64 = 1) -> bool {
    v, o := sp_sat_mul_add(s, w, r.samples);
    r.samples = v;
    return o;
}
sr_remove_samples :: (r: *Sample_Record, s_in: u64) -> u64 {
    s := s_in;
    if s > r.samples s = r.samples;
    r.samples -= s;
    return s;
}
sr_target_index :: (r: *Sample_Record, f: Fid) -> s64 {
    for r.targets if fid_eq(it.f, f) return it_index;
    return -1;
}
sr_add_called_target :: (r: *Sample_Record, f: Fid, s: u64, w: u64 = 1) -> bool {
    k := sr_target_index(r, f);
    if k < 0 { array_add(*r.targets, .{f, 0}); k = r.targets.count - 1; }
    v, o := sp_sat_mul_add(s, w, r.targets[k].count);
    r.targets[k].count = v;
    return o;
}
sr_remove_called_target :: (r: *Sample_Record, f: Fid) -> u64 {
    k := sr_target_index(r, f);
    if k < 0 return 0;
    c := r.targets[k].count;
    array_ordered_remove_by_index(*r.targets, k);
    return c;
}
sr_call_target_sum :: (r: *Sample_Record) -> u64 { s: u64 = 0; for r.targets s += it.count; return s; }
sr_merge :: (r: *Sample_Record, o: *Sample_Record, w: u64 = 1) -> bool {
    ov := sr_add_samples(r, o.samples, w);
    for o.targets if sr_add_called_target(r, it.f, it.count, w) ov = true;
    return ov;
}
// SampleRecord::sortCallTargets: count descending, then name ascending (temp)
sp_sort_call_targets :: (t: [] Call_Target) -> [] Call_Target {
    out := NewArray(t.count, Call_Target,, allocator = temp);
    for t out[it_index] = it;
    for a: 1..out.count - 1 {
        x := out[a]; b := a - 1;
        while b >= 0 && sp_call_target_less(x, out[b]) { out[b + 1] = out[b]; b -= 1; }
        out[b + 1] = x;
    }
    return out;
}
sp_call_target_less :: (l: Call_Target, r: Call_Target) -> bool {
    if l.count != r.count return l.count > r.count;
    return fid_cmp(l.f, r.f) < 0;
}

// ---------------------------------------------------------------- SampleContext

// ContextStateMask
CTX_UNKNOWN :: 0x0; CTX_RAW :: 0x1; CTX_SYNTHETIC :: 0x2; CTX_INLINED :: 0x4; CTX_MERGED :: 0x8;
// ContextAttributeMask
CTX_ATTR_NONE :: 0x0; CTX_WAS_INLINED :: 0x1; CTX_SHOULD_BE_INLINED :: 0x2; CTX_DUPLICATED_INTO_BASE :: 0x4;

Ctx_Frame :: struct { func: Fid; loc: Line_Loc; }
Sample_Context :: struct {
    func: Fid;
    frames: [] Ctx_Frame;   // full context (CS profiles); empty otherwise
    state: u32;
    attrs: u32;
}
ctx_has_context :: (c: *Sample_Context) -> bool { return c.state != CTX_UNKNOWN; }
ctx_set_function :: (c: *Sample_Context, f: Fid) { c.func = f; c.frames.count = 0; c.frames.data = null; c.state = CTX_UNKNOWN; }
ctx_set_context :: (c: *Sample_Context, frames: [] Ctx_Frame, state: u32 = CTX_RAW) {
    c.frames = frames;
    c.func = frames[frames.count - 1].func;
    c.state = state;
}
ctx_frames_eq :: (a: [] Ctx_Frame, b: [] Ctx_Frame) -> bool {
    if a.count != b.count return false;
    for a if !loc_eq(it.loc, b[it_index].loc) || !fid_eq(it.func, b[it_index].func) return false;
    return true;
}
ctx_eq :: (a: *Sample_Context, b: *Sample_Context) -> bool {
    return a.state == b.state && fid_eq(a.func, b.func) && ctx_frames_eq(a.frames, b.frames);
}
// SampleContextFrame::toString
ctx_frame_str :: (f: Ctx_Frame, with_loc: bool) -> string {
    if !with_loc return fid_str(f.func);
    if f.loc.disc return tprint("%:%.%", fid_str(f.func), f.loc.line, f.loc.disc);
    return tprint("%:%", fid_str(f.func), f.loc.line);
}
// SampleContext::getContextString
ctx_context_string :: (frames: [] Ctx_Frame, include_leaf_loc := false) -> string {
    sb: String_Builder; sb.allocator = temp;
    for frames {
        if it_index > 0 append(*sb, " @ ");
        append(*sb, ctx_frame_str(it, it_index != frames.count - 1 || include_leaf_loc));
    }
    return builder_to_string(*sb,, allocator = temp);
}
ctx_to_string :: (c: *Sample_Context) -> string {
    if !ctx_has_context(c) return fid_str(c.func);
    return ctx_context_string(c.frames);
}
// the key of the context in SampleProfileMap (LLVM hashes the frames; equality is what matters here)
ctx_key :: (c: *Sample_Context) -> string { return ctx_context_string(c.frames, true); }

// SampleContext::decodeContextString
ctx_decode_frame :: (s: string) -> Ctx_Frame {
    fr: Ctx_Frame;
    colon := sr_find(s, #char ":");
    fr.func = fid_of(sr_substr(s, 0, colon));
    if colon != SR_NPOS {
        rest := sr_substr(s, colon + 1);
        if rest.count {
            dot := sr_find(rest, #char ".");
            ok, v := sr_as_s64(sr_substr(rest, 0, dot));
            if ok fr.loc.line = cast,no_check(u32) v;
            if dot != SR_NPOS {
                d := sr_substr(rest, dot + 1);
                if d.count { ok2, dv := sr_as_u64(d); if ok2 && dv <= 0xFFFF_FFFF fr.loc.disc = cast(u32) dv; }
            }
        }
    }
    return fr;
}
// SampleContext::createCtxVectorFromStr ("[main:3 @ _Z5funcAi:1 @ _Z8funcLeafi]")
ctx_frames_from_str :: (s_in: string) -> [] Ctx_Frame {
    s := sr_substr(s_in, 1, cast(u64) s_in.count - 2);
    out: [..] Ctx_Frame;
    while s.count {
        k := sr_find_str(s, " @ ");
        part := sr_substr(s, 0, k);
        s = ifx k == SR_NPOS then "" else sr_substr(s, k + 3);
        array_add(*out, ctx_decode_frame(part));
    }
    return out;
}

// ---------------------------------------------------------------- FunctionSamples

Body_Sample :: struct { loc: Line_Loc; rec: Sample_Record; }
Callee_Samples :: struct { f: Fid; fs: *Fs; }
Callsite_Samples :: struct { loc: Line_Loc; callees: [..] Callee_Samples; }   // callees sorted by FunctionId

Fs :: struct {
    function_hash: u64;
    ctx: Sample_Context;
    total: u64;
    head: u64;
    body: [..] Body_Sample;              // BodySampleMap (sorted by location)
    callsites: [..] Callsite_Samples;    // CallsiteSampleMap (sorted by location)
    loc_map: *Table(u64, Line_Loc);      // IRToProfileLocationMap (stale profile matching)
    has_guid_map: bool;                  // GUIDToFuncNameMap is set
}

// FunctionSamples statics
sp_flags: struct {
    probe_based: bool;   // ProfileIsProbeBased
    cs: bool;            // ProfileIsCS
    preinlined: bool;    // ProfileIsPreInlined
    use_md5: bool;       // UseMD5
    has_uniq_suffix := true;   // HasUniqSuffix (true unless an ext-binary name table says otherwise)
    fs: bool;            // ProfileIsFS
};

fs_new :: () -> *Fs { return New(Fs); }
fs_set_function :: (fs: *Fs, f: Fid) { ctx_set_function(*fs.ctx, f); }
fs_func :: inline (fs: *Fs) -> Fid { return fs.ctx.func; }
fs_guid :: (fs: *Fs) -> u64 { return fid_hash(fs.ctx.func); }
fs_empty :: (fs: *Fs) -> bool { return fs.total == 0; }

fs_add_total :: (fs: *Fs, n: u64, w: u64 = 1) -> bool { v, o := sp_sat_mul_add(n, w, fs.total); fs.total = v; return o; }
fs_remove_total :: (fs: *Fs, n: u64) { if fs.total < n fs.total = 0; else fs.total -= n; }
fs_add_head :: (fs: *Fs, n: u64, w: u64 = 1) -> bool { v, o := sp_sat_mul_add(n, w, fs.head); fs.head = v; return o; }

// lower_bound in the sorted body map
fs_body_lower :: (fs: *Fs, l: Line_Loc) -> s64 {
    lo := 0; hi := fs.body.count;
    while lo < hi { m := (lo + hi) / 2; if loc_cmp(fs.body[m].loc, l) < 0 lo = m + 1; else hi = m; }
    return lo;
}
fs_body_find :: (fs: *Fs, l: Line_Loc) -> *Sample_Record {
    k := fs_body_lower(fs, l);
    if k < fs.body.count && loc_eq(fs.body[k].loc, l) return *fs.body[k].rec;
    return null;
}
// BodySamples[Loc]
fs_body_at :: (fs: *Fs, l: Line_Loc) -> *Sample_Record {
    k := fs_body_lower(fs, l);
    if k < fs.body.count && loc_eq(fs.body[k].loc, l) return *fs.body[k].rec;
    e: Body_Sample; e.loc = l;
    array_insert_at(*fs.body, e, k);
    return *fs.body[k].rec;
}
fs_body_erase :: (fs: *Fs, l: Line_Loc) {
    k := fs_body_lower(fs, l);
    if k < fs.body.count && loc_eq(fs.body[k].loc, l) array_ordered_remove_by_index(*fs.body, k);
}
fs_cs_lower :: (fs: *Fs, l: Line_Loc) -> s64 {
    lo := 0; hi := fs.callsites.count;
    while lo < hi { m := (lo + hi) / 2; if loc_cmp(fs.callsites[m].loc, l) < 0 lo = m + 1; else hi = m; }
    return lo;
}
fs_cs_find :: (fs: *Fs, l: Line_Loc) -> *Callsite_Samples {
    k := fs_cs_lower(fs, l);
    if k < fs.callsites.count && loc_eq(fs.callsites[k].loc, l) return *fs.callsites[k];
    return null;
}
fs_cs_at :: (fs: *Fs, l: Line_Loc) -> *Callsite_Samples {
    k := fs_cs_lower(fs, l);
    if k < fs.callsites.count && loc_eq(fs.callsites[k].loc, l) return *fs.callsites[k];
    e: Callsite_Samples; e.loc = l;
    array_insert_at(*fs.callsites, e, k);
    return *fs.callsites[k];
}
cs_find :: (cs: *Callsite_Samples, f: Fid) -> *Fs {
    for cs.callees if fid_eq(it.f, f) return it.fs;
    return null;
}
// FunctionSamplesMap[F] (a default-constructed FunctionSamples when new)
cs_at :: (cs: *Callsite_Samples, f: Fid) -> *Fs {
    k := 0;
    while k < cs.callees.count {
        c := fid_cmp(cs.callees[k].f, f);
        if c == 0 return cs.callees[k].fs;
        if c > 0 break;
        k += 1;
    }
    e: Callee_Samples; e.f = f; e.fs = fs_new();
    array_insert_at(*cs.callees, e, k);
    return e.fs;
}
cs_erase :: (cs: *Callsite_Samples, f: Fid) {
    for cs.callees if fid_eq(it.f, f) { array_ordered_remove_by_index(*cs.callees, it_index); return; }
}

// mapIRLocToProfileLoc
fs_map_ir_loc :: (fs: *Fs, l: Line_Loc) -> Line_Loc {
    if !fs.loc_map return l;
    found, v := table_find(fs.loc_map, loc_hash(l));
    if found return v;
    return l;
}
fs_add_body_samples :: (fs: *Fs, line: u32, disc: u32, n: u64, w: u64 = 1) -> bool {
    return sr_add_samples(fs_body_at(fs, .{line, disc}), n, w);
}
fs_add_called_target_samples :: (fs: *Fs, line: u32, disc: u32, f: Fid, n: u64, w: u64 = 1) -> bool {
    return sr_add_called_target(fs_body_at(fs, .{line, disc}), f, n, w);
}
fs_remove_called_target_and_body_sample :: (fs: *Fs, line: u32, disc: u32, f: Fid) -> u64 {
    r := fs_body_find(fs, .{line, disc});
    if !r return 0;
    c := sr_remove_called_target(r, f);
    c = sr_remove_samples(r, c);
    if !r.samples fs_body_erase(fs, .{line, disc});
    return c;
}
// findSamplesAt: (found, samples)
fs_find_samples_at :: (fs: *Fs, line: u32, disc: u32) -> (bool, u64) {
    r := fs_body_find(fs, fs_map_ir_loc(fs, .{line, disc}));
    if !r return false, 0;
    return true, r.samples;
}
// findCallTargetMapAt (null = not found)
fs_find_call_target_map_at :: (fs: *Fs, l: Line_Loc) -> *Sample_Record {
    return fs_body_find(fs, fs_map_ir_loc(fs, l));
}
fs_find_function_samples_map_at :: (fs: *Fs, l: Line_Loc) -> *Callsite_Samples {
    return fs_cs_find(fs, fs_map_ir_loc(fs, l));
}
// functionSamplesAt
fs_function_samples_at :: (fs: *Fs, l: Line_Loc) -> *Callsite_Samples { return fs_cs_at(fs, fs_map_ir_loc(fs, l)); }

// getHeadSamplesEstimate
fs_head_samples_estimate :: (fs: *Fs) -> u64 {
    if sp_flags.cs && fs.head return fs.head;
    count: u64 = 0;
    if fs.body.count && (!fs.callsites.count || loc_cmp(fs.body[0].loc, fs.callsites[0].loc) < 0)
        count = fs.body[0].rec.samples;
    else if fs.callsites.count {
        for fs.callsites[0].callees count += fs_head_samples_estimate(it.fs);
    }
    if count return count;
    return ifx fs.total > 0 then cast(u64) 1 else 0;
}
// getMaxCountInside
fs_max_count_inside :: (fs: *Fs, skip_callsite := false) -> u64 {
    m: u64 = 0;
    for fs.body if it.rec.samples > m m = it.rec.samples;
    if skip_callsite return m;
    for cs: fs.callsites for cs.callees { c := fs_max_count_inside(it.fs); if c > m m = c; }
    return m;
}
fs_update_callsite_samples :: (fs: *Fs) {
    for * fs.body {
        t := sr_call_target_sum(*it.rec);
        if t > it.rec.samples sr_add_samples(*it.rec, t - it.rec.samples);
    }
}
fs_update_total_samples :: (fs: *Fs) {
    fs.total = 0;
    for fs.body fs_add_total(fs, it.rec.samples);
    for cs: fs.callsites for cs.callees { fs_update_total_samples(it.fs); fs_add_total(fs, it.fs.total); }
}
fs_set_context_synthetic :: (fs: *Fs) {
    fs.ctx.state |= CTX_SYNTHETIC;
    for cs: fs.callsites for cs.callees fs_set_context_synthetic(it.fs);
}
fs_set_context_attribute :: (fs: *Fs, a: u32) {
    fs.ctx.attrs |= a;
    for cs: fs.callsites for cs.callees fs_set_context_attribute(it.fs, a);
}

// FunctionSamples::merge: (overflow, hash mismatch)
fs_merge :: (fs: *Fs, o: *Fs, w: u64 = 1) -> bool {
    if !fs.has_guid_map fs.has_guid_map = o.has_guid_map;
    if fid_empty(fs.ctx.func) fs.ctx = o.ctx;
    if fs.function_hash == 0 fs.function_hash = o.function_hash;
    else if fs.function_hash != o.function_hash return false;   // hash_mismatch: nothing is merged
    fs_add_total(fs, o.total, w);
    fs_add_head(fs, o.head, w);
    for * o.body sr_merge(fs_body_at(fs, it.loc), *it.rec, w);
    for * ocs: o.callsites {
        cs := fs_function_samples_at(fs, ocs.loc);
        for ocs.callees fs_merge(cs_at(cs, it.f), it.fs, w);
    }
    return true;
}

// a deep copy (FunctionSamples' copy constructor)
fs_clone :: (o: *Fs) -> *Fs {
    fs := fs_new();
    fs.function_hash = o.function_hash;
    fs.ctx = o.ctx;
    fs.total = o.total;
    fs.head = o.head;
    fs.has_guid_map = o.has_guid_map;
    fs.loc_map = o.loc_map;
    for o.body {
        e: Body_Sample; e.loc = it.loc; e.rec.samples = it.rec.samples;
        for t: it.rec.targets array_add(*e.rec.targets, t);
        array_add(*fs.body, e);
    }
    for o.callsites {
        e: Callsite_Samples; e.loc = it.loc;
        for c: it.callees array_add(*e.callees, .{c.f, fs_clone(c.fs)});
        array_add(*fs.callsites, e);
    }
    return fs;
}

// getCanonicalFnName(FnName, Attr)
SUFFIX_LLVM :: ".llvm."; SUFFIX_PART :: ".part."; SUFFIX_UNIQ :: ".__uniq.";
sp_canonical_fn_name_with :: (name: string, suffixes: [] string, attr: string = "selected") -> string {
    if attr == "" || attr == "all" { k := sr_find(name, #char "."); return sr_substr(name, 0, k); }
    if attr == "selected" {
        cand := name;
        for suf: suffixes {
            if suf == SUFFIX_UNIQ && sp_flags.has_uniq_suffix continue;
            it_pos := sr_rfind_str(cand, suf);
            if it_pos == SR_NPOS continue;
            dit := sr_rfind(cand, #char ".");
            if dit == it_pos || dit == it_pos + cast(u64) suf.count - 1 cand = sr_substr(cand, 0, it_pos);
        }
        return cand;
    }
    if attr == "none" return name;
    fatal("sample-profile: unknown suffix elision policy '%'", attr);
    return name;
}
sp_canonical_fn_name :: (name: string, attr: string = "selected") -> string {
    return sp_canonical_fn_name_with(name, .[SUFFIX_LLVM, SUFFIX_PART, SUFFIX_UNIQ], attr);
}
// getCanonicalFnName(const Function &)
sp_canonical_fn_name_of :: (f: Value_Id) -> string {
    attr := sp_fn_str_attr(f, "sample-profile-suffix-elision-policy");
    return sp_canonical_fn_name(vname(f), attr);
}

// FunctionSamples::getOffset
sp_offset :: (dil: Md_Id) -> u32 {
    sp := diloc_subprogram(dil);
    return cast(u32) ((diloc_line(dil) - di_int(sp, 0)) & 0xffff);
}
// DILocation::getBaseDiscriminator (EnableFSDiscriminator is off)
diloc_base_discriminator :: (dil: Md_Id) -> u32 {
    d := diloc_discriminator(dil);
    if disc_is_pseudo_probe(d) {
        ok, b := probe_extract_dwarf_base_discriminator(d);
        if ok return b;
        return probe_extract_index(d);
    }
    return disc_unsigned_from_prefix_encoding(d);
}
// PseudoProbeDwarfDiscriminator (llvm/include/llvm/IR/PseudoProbe.h)
probe_dwarf_base_encoded :: (v: u32) -> bool { return (v & 0x10000000) != 0; }
probe_extract_index :: (v: u32) -> u32 { if probe_dwarf_base_encoded(v) return (v >> 3) & 0x1FFF; return (v >> 3) & 0xFFFF; }
probe_extract_type :: (v: u32) -> u32 { return (v >> 26) & 0x3; }
probe_extract_attributes :: (v: u32) -> u32 { return (v >> 29) & 0x7; }
probe_extract_factor :: (v: u32) -> u32 { return (v >> 19) & 0x7F; }
probe_extract_dwarf_base_discriminator :: (v: u32) -> (bool, u32) {
    if probe_dwarf_base_encoded(v) return true, (v >> 16) & 0x7;
    return false, 0;
}
// packProbeData
probe_pack :: (index: u32, type: u32, flags: u32, factor: u32, has_base: bool, base: u32) -> u32 {
    v := (index << 3) | (factor << 19) | (type << 26) | 0x7;
    if index <= 0x1FFF && has_base && base <= 0x7 v |= (1 << 28) | (base << 16);
    return v;
}
// FunctionSamples::getCallSiteIdentifier
sp_callsite_id :: (dil: Md_Id, is_fs := false) -> Line_Loc {
    if sp_flags.probe_based return .{probe_extract_index(diloc_discriminator(dil)), 0};
    d := ifx is_fs then diloc_discriminator(dil) else diloc_base_discriminator(dil);
    return .{sp_offset(dil), d};
}
// the C++ linkage name of the scope's subprogram, or its name
sp_scope_fn_name :: (dil: Md_Id) -> string {
    sp := diloc_subprogram(dil);
    n := md_str_of(di_op(sp, 3));
    if n.count == 0 n = md_str_of(di_op(sp, 2));
    return n;
}

// FunctionSamples::findFunctionSamplesAt
fs_find_function_samples_at :: (fs: *Fs, l: Line_Loc, callee_in: string, use_remapper: bool, name_map: *Table(string, string)) -> *Fs {
    callee := sp_canonical_fn_name(callee_in);
    cs := fs_cs_find(fs, fs_map_ir_loc(fs, l));
    if !cs return null;
    r := cs_find(cs, fid_rep_in_format(callee));
    if r return r;
    if name_map && name_map.count {
        found, prof := table_find(name_map, callee);
        if found {
            callee = prof;
            r = cs_find(cs, fid_rep_in_format(callee));
            if r return r;
        }
    }
    if use_remapper && sp_reader.remapper_present {
        ok, n := sp_remapper_lookup(callee);
        if ok { r = cs_find(cs, fid_rep_in_format(n)); if r return r; }
    }
    if callee.count return null;
    mx: u64 = 0;
    best: *Fs = null;
    for cs.callees if it.fs.total >= mx { mx = it.fs.total; best = it.fs; }
    return best;
}
// FunctionSamples::findFunctionSamples(DIL)
fs_find_function_samples :: (fs: *Fs, dil_in: Md_Id, use_remapper: bool, name_map: *Table(string, string)) -> *Fs {
    S :: struct { l: Line_Loc; n: string; }
    s: [..] S; s.allocator = temp;
    prev := dil_in;
    dil := diloc_inlined_at(dil_in);
    while dil != NONE {
        array_add(*s, .{sp_callsite_id(dil, sp_flags.fs), sp_scope_fn_name(prev)});
        prev = dil;
        dil = diloc_inlined_at(dil);
    }
    if s.count == 0 return fs;
    r := fs;
    i := s.count - 1;
    while i >= 0 && r != null {
        r = fs_find_function_samples_at(r, s[i].l, s[i].n, use_remapper, name_map);
        i -= 1;
    }
    return r;
}
// findAllNames (into a list without duplicates)
fs_find_all_names :: (fs: *Fs, out: *[..] Fid) {
    add :: (out: *[..] Fid, f: Fid) { for out.* if fid_eq(it, f) return; array_add(out, f); }
    add(out, fs.ctx.func);
    for fs.body for t: it.rec.targets add(out, t.f);
    for cs: fs.callsites for cs.callees { add(out, it.f); fs_find_all_names(it.fs, out); }
}

// ---------------------------------------------------------------- StringRef helpers

SR_NPOS :: 0xFFFF_FFFF_FFFF_FFFF;
sr_substr :: (s: string, start: u64, n: u64 = SR_NPOS) -> string {
    st := min(start, cast(u64) s.count);
    len := min(n, cast(u64) s.count - st);
    r: string; r.data = s.data + st; r.count = cast(s64) len;
    return r;
}
sr_find :: (s: string, c: u8, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if s[i] == c return i; i += 1; }
    return SR_NPOS;
}
sr_find_str :: (s: string, t: string, from: u64 = 0) -> u64 {
    if t.count > s.count return SR_NPOS;
    i := from;
    while i + cast(u64) t.count <= cast(u64) s.count {
        if sr_substr(s, i, cast(u64) t.count) == t return i;
        i += 1;
    }
    return SR_NPOS;
}
// StringRef::rfind(C, From): the last C in [0, From)
sr_rfind :: (s: string, c: u8, from: u64 = SR_NPOS) -> u64 {
    i := min(from, cast(u64) s.count);
    while i != 0 { i -= 1; if s[i] == c return i; }
    return SR_NPOS;
}
sr_rfind_str :: (s: string, t: string) -> u64 {
    n := cast(u64) t.count;
    if n > cast(u64) s.count return SR_NPOS;
    i := cast(u64) s.count - n + 1;
    while i != 0 { i -= 1; if sr_substr(s, i, n) == t return i; }
    return SR_NPOS;
}
sr_find_first_not_of :: (s: string, c: u8, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if s[i] != c return i; i += 1; }
    return SR_NPOS;
}
sr_find_first_of :: (s: string, c: u8, from: u64 = 0) -> u64 { return sr_find(s, c, from); }
sr_trim :: (s: string) -> string {
    a := 0; b := s.count;
    while a < b && (s[a] == #char " " || s[a] == #char "\t" || s[a] == #char "\n" || s[a] == 11 || s[a] == 12 || s[a] == #char "\r") a += 1;
    while b > a && (s[b-1] == #char " " || s[b-1] == #char "\t" || s[b-1] == #char "\n" || s[b-1] == 11 || s[b-1] == 12 || s[b-1] == #char "\r") b -= 1;
    return sr_substr(s, cast(u64) a, cast(u64) (b - a));
}
// StringRef::getAsInteger(10, unsigned): (ok, value)
sr_as_u64 :: (s: string) -> (bool, u64) {
    if s.count == 0 return false, 0;
    v: u64 = 0;
    for i: 0..s.count - 1 {
        c := s[i];
        if c < #char "0" || c > #char "9" return false, 0;
        d := cast(u64) (c - #char "0");
        if v > (0xFFFF_FFFF_FFFF_FFFF - d) / 10 return false, 0;
        v = v * 10 + d;
    }
    return true, v;
}
sr_as_u32 :: (s: string) -> (bool, u32) {
    ok, v := sr_as_u64(s);
    if !ok || v > 0xFFFF_FFFF return false, 0;
    return true, cast(u32) v;
}
// getAsInteger(10, int)
sr_as_s64 :: (s: string) -> (bool, s64) {
    if s.count && s[0] == #char "-" {
        ok, v := sr_as_u64(sr_substr(s, 1));
        if !ok || v > 0x8000_0000_0000_0000 return false, 0;
        return true, -cast,no_check(s64) v;
    }
    ok, v := sr_as_u64(s);
    if !ok || v > 0x7FFF_FFFF_FFFF_FFFF return false, 0;
    return true, cast(s64) v;
}

// ---------------------------------------------------------------- the reader

Sp_Format :: enum u8 { NONE; TEXT; RAW_BINARY; EXT_BINARY; GCC; }

Sp_Summary :: struct {
    total_count: u64;
    max_count: u64;
    max_internal_count: u64;
    max_function_count: u64;
    num_counts: u64;
    num_functions: u64;
    partial: bool;
    partial_ratio: float64;
    detailed: [..] Psi_Entry;
}

Sp_Reader :: struct {
    format: Sp_Format;
    file: string;
    buffer: string;
    profiles: [..] *Fs;            // SampleProfileMap, in insertion order
    by_hash: Table(u64, *Fs);      // keyed by the MD5 of the name (non-CS)
    by_ctx: Table(string, *Fs);    // keyed by the full context (CS)
    is_cs: bool;
    is_probe_based: bool;
    is_preinlined: bool;
    is_fs: bool;
    use_md5: bool;
    skip_flat_prof: bool;
    summary: Sp_Summary;
    has_psl: bool;                 // a ProfileSymbolList was read
    psl: Table(string, bool);
    psl_md5: Table(u64, bool);     // ProfileSymbolList of an MD5 profile
    name_table: [..] Fid;
    remapper_present: bool;
    remap_name_map: Table(string, string);   // remapping key -> name in the profile
    func_name_to_prof_name: *Table(string, string);
}
sp_reader: Sp_Reader;

sp_profile_key_hash :: (c: *Sample_Context) -> u64 { return fid_hash(c.func); }

// SampleProfileMap::create(Ctx)
sp_profiles_create :: (r: *Sp_Reader, c: Sample_Context) -> *Fs {
    cc := c;
    if ctx_has_context(*cc) {
        key := ctx_key(*cc);
        found, fs := table_find(*r.by_ctx, key);
        if found return fs;
        fs = fs_new();
        fs.ctx = cc;
        table_add(*r.by_ctx, copy_string(key), fs);
        array_add(*r.profiles, fs);
        return fs;
    }
    h := sp_profile_key_hash(*cc);
    found, fs := table_find(*r.by_hash, h);
    if found return fs;
    fs = fs_new();
    fs.ctx = cc;
    table_add(*r.by_hash, h, fs);
    array_add(*r.profiles, fs);
    return fs;
}
sp_profiles_erase :: (r: *Sp_Reader, fs: *Fs) {
    if ctx_has_context(*fs.ctx) table_remove(*r.by_ctx, ctx_key(*fs.ctx));
    else table_remove(*r.by_hash, sp_profile_key_hash(*fs.ctx));
    for r.profiles if it == fs { array_ordered_remove_by_index(*r.profiles, it_index); break; }
}
// Profiles.find(FunctionId(Name))
sp_profiles_find_name :: (r: *Sp_Reader, name: string) -> *Fs {
    found, fs := table_find(*r.by_hash, md5_hash_u64(name));
    if found return fs;
    return null;
}
sp_profiles_find_ctx :: (r: *Sp_Reader, c: *Sample_Context) -> *Fs {
    if ctx_has_context(c) {
        found, fs := table_find(*r.by_ctx, ctx_key(c));
        if found return fs;
        return null;
    }
    found, fs := table_find(*r.by_hash, sp_profile_key_hash(c));
    if found return fs;
    return null;
}

// SampleProfileReader::getSamplesFor(StringRef)
sp_get_samples_for_name :: (name_in: string) -> *Fs {
    r := *sp_reader;
    name := name_in;
    fs := sp_profiles_find_name(r, name);
    if fs return fs;
    if r.func_name_to_prof_name && r.func_name_to_prof_name.count {
        found, p := table_find(r.func_name_to_prof_name, name);
        if found {
            name = p;
            fs = sp_profiles_find_name(r, name);
            if fs return fs;
        }
    }
    if r.remapper_present {
        ok, n := sp_remapper_lookup(name);
        if ok { fs = sp_profiles_find_name(r, n); if fs return fs; }
    }
    return null;
}
sp_get_samples_for :: (f: Value_Id) -> *Fs { return sp_get_samples_for_name(sp_canonical_fn_name_of(f)); }

sp_report_error :: (line: s64, msg: string) {
    fatal("%:%: %", sp_reader.file, line, msg);
}

// SampleProfileReader::create + read
sp_reader_open :: (file: string, remap_file: string) {
    r := *sp_reader;
    r.file = file;
    data, ok := read_entire_file(file);
    if !ok fatal("%: Could not open profile: No such file or directory", file);
    r.buffer = data;
    if sp_raw_binary_has_format(data) r.format = .RAW_BINARY;
    else if sp_ext_binary_has_format(data) r.format = .EXT_BINARY;
    else if sp_gcc_has_format(data) r.format = .GCC;
    else if sp_text_has_format(data) r.format = .TEXT;
    else fatal("%: Could not open profile: Unrecognized sample profile encoding format", file);
    if remap_file.count sp_remapper_create(remap_file);
}
sp_reader_read :: () {
    r := *sp_reader;
    if r.format == {
        case .TEXT; sp_text_read();
        case .RAW_BINARY; sp_raw_binary_read();
        case .EXT_BINARY; sp_ext_binary_read();
        case .GCC; sp_gcc_read();
    }
    if r.remapper_present sp_remapper_apply();
    sp_flags.use_md5 = r.use_md5;
}

// ---------------------------------------------------------------- the text format

Sp_Line_Iter :: struct { s: string; pos: s64; line_number: s64; cur: string; eof: bool; }
// line_iterator(Buffer, SkipBlanks = true, CommentMarker = '#')
sp_line_next :: (it: *Sp_Line_Iter) {
    s := it.s;
    while true {
        if it.pos >= s.count { it.eof = true; return; }
        // skip blank lines and comment lines
        if s[it.pos] == #char "\n" { it.pos += 1; it.line_number += 1; continue; }
        if s[it.pos] == #char "\r" && it.pos + 1 < s.count && s[it.pos + 1] == #char "\n" { it.pos += 2; it.line_number += 1; continue; }
        if s[it.pos] == #char "#" {
            while it.pos < s.count && s[it.pos] != #char "\n" it.pos += 1;
            continue;
        }
        break;
    }
    start := it.pos;
    while it.pos < s.count && s[it.pos] != #char "\n" && !(s[it.pos] == #char "\r" && it.pos + 1 < s.count && s[it.pos + 1] == #char "\n") it.pos += 1;
    it.cur = sr_substr(s, cast(u64) start, cast(u64) (it.pos - start));
    it.line_number += 1;
    if it.pos < s.count { if s[it.pos] == #char "\r" it.pos += 2; else it.pos += 1; }
}
sp_line_iter :: (s: string) -> Sp_Line_Iter {
    it: Sp_Line_Iter; it.s = s;
    sp_line_next(*it);
    return it;
}

// ParseHead
sp_parse_head :: (input: string) -> (bool, string, u64, u64) {
    if input.count == 0 || input[0] == #char " " return false, "", 0, 0;
    n2 := sr_rfind(input, #char ":");
    n1 := sr_rfind(input, #char ":", n2 - 1);
    fname := sr_substr(input, 0, n1);
    ok1, ns := sr_as_u64(sr_substr(input, n1 + 1, n2 - n1 - 1));
    if !ok1 return false, "", 0, 0;
    ok2, nh := sr_as_u64(sr_substr(input, n2 + 1));
    if !ok2 return false, "", 0, 0;
    return true, fname, ns, nh;
}

Sp_Line_Type :: enum u8 { CALLSITE; BODY; METADATA; VTABLE; }
Sp_Parsed_Line :: struct {
    type: Sp_Line_Type;
    depth: u32;
    num_samples: u64;
    line_offset: u32;
    disc: u32;
    callee: string;
    targets: [..] struct { name: string; count: u64; };
    function_hash: u64;
    attributes: u32;
    is_flat: bool;
}

// ParseLine
sp_parse_line :: (input: string, p: *Sp_Parsed_Line) -> bool {
    p.type = .BODY;
    d: u64 = 0;
    while d < cast(u64) input.count && input[d] == #char " " d += 1;
    p.depth = cast(u32) d;
    if d == 0 return false;
    if d < cast(u64) input.count && input[d] == #char "!" {
        p.type = .METADATA;
        if input == " !Flat" { p.is_flat = true; return true; }
        m := sr_substr(input, d);
        if begins_with(m, "!CFGChecksum:") {
            ok, v := sr_as_u64(sr_trim(sr_substr(m, 13)));
            p.function_hash = v;
            return ok;
        }
        if begins_with(m, "!Attributes:") {
            ok, v := sr_as_u32(sr_trim(sr_substr(m, 12)));
            p.attributes = v;
            return ok;
        }
        return false;
    }
    n1 := sr_find(input, #char ":");
    loc := sr_substr(input, d, n1 - d);
    n2 := sr_find(loc, #char ".");
    if n2 == SR_NPOS {
        ok, v := sr_as_u32(loc);
        if !ok || (v & 0xffff) != v return false;
        p.line_offset = v;
        p.disc = 0;
    } else {
        ok, v := sr_as_u32(sr_substr(loc, 0, n2));
        if !ok return false;
        p.line_offset = v;
        ok2, dv := sr_as_u32(sr_substr(loc, n2 + 1));
        if !ok2 return false;
        p.disc = dv;
    }
    rest := sr_substr(input, n1 + 2);
    if rest.count && rest[0] >= #char "0" && rest[0] <= #char "9" {
        p.type = .BODY;
        n3 := sr_find(rest, #char " ");
        if n3 == SR_NPOS {
            ok, v := sr_as_u64(rest);
            if !ok return false;
            p.num_samples = v;
        } else {
            ok, v := sr_as_u64(sr_substr(rest, 0, n3));
            if !ok return false;
            p.num_samples = v;
        }
        while n3 != SR_NPOS {
            n3 += sr_find_first_not_of(sr_substr(rest, n3), #char " ");
            rest = sr_substr(rest, n3);
            n3 = sr_find_first_of(rest, #char ":");
            if n3 == SR_NPOS || n3 == 0 return false;
            target: string;
            count: u64;
            n4: u64;
            while true {
                after := sr_substr(rest, n3 + 1);
                target = sr_substr(rest, 0, n3);
                n4 = sr_find_first_of(after, #char " ");
                n4 = ifx n4 != SR_NPOS then n3 + n4 + 1 else cast(u64) rest.count;
                word := sr_substr(rest, n3 + 1, n4 - n3 - 1);
                ok, c := sr_as_u64(word);
                if ok { count = c; break; }
                n5 := sr_find_first_of(after, #char ":");
                if n5 == SR_NPOS return false;
                n3 += n5 + 1;
            }
            found := false;
            for * p.targets if it.name == target { it.count = count; found = true; }
            if !found array_add(*p.targets, .{target, count});
            if n4 == cast(u64) rest.count break;
            n3 = n4;
        }
    } else if begins_with(rest, "vtables ") {
        p.type = .VTABLE;
        fatal("sample-profile: vtable type profiles in the text sample profile are not supported");
    } else {
        p.type = .CALLSITE;
        n3 := sr_rfind(rest, #char ":");
        p.callee = sr_substr(rest, 0, n3);
        ok, v := sr_as_u64(sr_substr(rest, n3 + 1));
        if !ok return false;
        p.num_samples = v;
    }
    return true;
}

sp_text_has_format :: (data: string) -> bool {
    it := sp_line_iter(data);
    if it.eof return false;
    if it.cur.count && it.cur[0] != #char " " {
        ok := sp_parse_head(it.cur);
        return ok;
    }
    return false;
}

// SampleProfileReaderText::readImpl
sp_text_read :: () {
    r := *sp_reader;
    it := sp_line_iter(r.buffer);
    inline_stack: [..] *Fs; inline_stack.allocator = temp;
    top_level_probe_count: u32 = 0;
    depth_metadata: u32 = 0;
    flat_samples: [..] *Fs; flat_samples.allocator = temp;
    cs_profile_count := 0;
    r.is_fs = sp_opts.profile_isfs;
    sp_flags.fs = r.is_fs;
    while !it.eof {
        defer sp_line_next(*it);
        line := it.cur;
        pos := sr_find_first_not_of(line, #char " ");
        if pos == SR_NPOS || line[pos] == #char "#" continue;
        if line[0] != #char " " {
            ok, fname, ns, nh := sp_parse_head(line);
            if !ok sp_report_error(it.line_number, tprint("Expected 'mangled_name:NUM:NUM', found %", line));
            depth_metadata = 0;
            c: Sample_Context;
            if begins_with(fname, "[") {
                ctx_set_context(*c, ctx_frames_from_str(fname));
                cs_profile_count += 1;
            } else c.func = fid_of(fname);
            fs := sp_profiles_create(r, c);
            fs_add_total(fs, ns);
            fs_add_head(fs, nh);
            inline_stack.count = 0;
            array_add(*inline_stack, fs);
        } else {
            p: Sp_Parsed_Line;
            p.targets.allocator = temp;
            if !sp_parse_line(line, *p) {
                if p.type == .METADATA sp_report_error(it.line_number, tprint("Cannot parse metadata: %", line));
                sp_report_error(it.line_number, tprint("Expected 'NUM[.NUM]: NUM[ mangled_name:NUM]*', found %", line));
            }
            if p.type != .METADATA && p.depth == depth_metadata
                sp_report_error(it.line_number, tprint("Found non-metadata after metadata: %", line));
            p.disc &= sp_discriminator_mask();
            while inline_stack.count > cast(s64) p.depth inline_stack.count -= 1;
            if p.type == {
              case .CALLSITE;
                cs := fs_function_samples_at(inline_stack[inline_stack.count - 1], .{p.line_offset, p.disc});
                f := cs_at(cs, fid_of(p.callee));
                fs_set_function(f, fid_of(p.callee));
                fs_add_total(f, p.num_samples);
                array_add(*inline_stack, f);
                depth_metadata = 0;
              case .BODY;
                fs := inline_stack[inline_stack.count - 1];
                for p.targets fs_add_called_target_samples(fs, p.line_offset, p.disc, fid_of(it.name), it.count);
                fs_add_body_samples(fs, p.line_offset, p.disc, p.num_samples);
              case .METADATA;
                fs := inline_stack[inline_stack.count - 1];
                if p.function_hash {
                    fs.function_hash = p.function_hash;
                    if p.depth == 1 top_level_probe_count += 1;
                }
                fs.ctx.attrs = p.attributes;
                if p.attributes & CTX_SHOULD_BE_INLINED r.is_preinlined = true;
                depth_metadata = p.depth;
                if p.is_flat && p.depth == 1 array_add(*flat_samples, fs);
              case; fatal("sample-profile: vtable type profiles are not supported");
            }
        }
    }
    if r.skip_flat_prof for flat_samples sp_profiles_erase(r, it);
    r.is_cs = cs_profile_count > 0;
    r.is_probe_based = top_level_probe_count > 0;
    sp_flags.probe_based = r.is_probe_based;
    sp_flags.cs = r.is_cs;
    sp_flags.preinlined = r.is_preinlined;
    sp_compute_summary();
}

// getDiscriminatorMask (FSDiscriminatorPass::Base)
sp_discriminator_mask :: () -> u32 {
    if !sp_reader.is_fs return 0xFFFF_FFFF;
    return 0xFF;
}

// ---------------------------------------------------------------- the summary

SP_DEFAULT_CUTOFFS :: u32.[10000, 100000, 200000, 300000, 400000, 500000, 600000, 700000, 800000, 900000, 950000,
                           990000, 999000, 999900, 999990, 999999];

Sp_Summary_Builder :: struct {
    s: Sp_Summary;
    counts: Table(u64, u32);   // CountFrequencies (iterated in descending count order)
}
sp_sb_add_count :: (b: *Sp_Summary_Builder, c: u64) {
    b.s.total_count += c;
    if c > b.s.max_count b.s.max_count = c;
    b.s.num_counts += 1;
    p := table_find_pointer(*b.counts, c);
    if p p.* += 1; else table_add(*b.counts, c, 1);
}
// SampleProfileSummaryBuilder::addRecord
sp_sb_add_record :: (b: *Sp_Summary_Builder, fs: *Fs, is_callsite := false) {
    if !is_callsite {
        b.s.num_functions += 1;
        if fs.head > b.s.max_function_count b.s.max_function_count = fs.head;
    } else if fs.ctx.attrs & CTX_DUPLICATED_INTO_BASE return;
    for fs.body sp_sb_add_count(b, it.rec.samples);
    for cs: fs.callsites for cs.callees sp_sb_add_record(b, it.fs, true);
}
// ProfileSummaryBuilder::computeDetailedSummary
sp_sb_compute_detailed :: (b: *Sp_Summary_Builder) {
    K :: struct { c: u64; f: u32; }
    freqs: [..] K; freqs.allocator = temp;
    for b.counts array_add(*freqs, .{it_index, it});
    quick_sort(freqs, (x: K, y: K) -> s64 { if x.c > y.c return -1; if x.c < y.c return 1; return 0; });
    k := 0;
    counts_seen: u32 = 0;
    curr_sum: u64 = 0; count: u64 = 0;
    for cutoff: SP_DEFAULT_CUTOFFS {
        // APInt(128) TotalCount * Cutoff / 1000000
        hi, lo := mul_u64_full(b.s.total_count, cast(u64) cutoff);
        desired := u128_div_u64(hi, lo, 1000000);
        while curr_sum < desired && k < freqs.count {
            count = freqs[k].c;
            curr_sum += count * freqs[k].f;
            counts_seen += freqs[k].f;
            k += 1;
        }
        array_add(*b.s.detailed, .{cast(u64) cutoff, count, cast(u64) counts_seen});
    }
}
u128_div_u64 :: (hi: u64, lo: u64, d: u64) -> u64 {
    // long division bit by bit (the quotient fits in 64 bits here)
    q: u64 = 0; r: u64 = 0;
    for < i: 0..127 {
        bit := ifx i >= 64 then (hi >> cast(u64) (i - 64)) & 1 else (lo >> cast(u64) i) & 1;
        carry := (r >> 63) & 1;
        r = (r << 1) | bit;
        if carry || r >= d { r -= d; if i < 64 q |= (cast(u64) 1) << cast(u64) i; }
    }
    return q;
}
// SampleProfileReader::computeSummary
sp_compute_summary :: () {
    r := *sp_reader;
    b: Sp_Summary_Builder;
    b.counts.allocator = temp;
    if sp_opts.contextless_summary || (sp_flags.cs && !sp_opts.contextless_summary_given) {
        flat := sp_flatten_profiles_copy(r.profiles, true);
        for flat sp_sb_add_record(*b, it);
    } else {
        for r.profiles sp_sb_add_record(*b, it);
    }
    sp_sb_compute_detailed(*b);
    r.summary = b.s;
}

// ProfileSummary::getMD (AddPartialField = AddPartialProfileRatioField = true)
sp_summary_md :: (s: *Sp_Summary) -> Md_Id {
    kv :: (k: string, v: u64) -> Md_Id { return md_tuple(.[md_string(k), md_value(const_int(ir.t_i64, v))], false); }
    comps: [..] Md_Id; comps.allocator = temp;
    array_add(*comps, md_tuple(.[md_string("ProfileFormat"), md_string("SampleProfile")], false));
    array_add(*comps, kv("TotalCount", s.total_count));
    array_add(*comps, kv("MaxCount", s.max_count));
    array_add(*comps, kv("MaxInternalCount", s.max_internal_count));
    array_add(*comps, kv("MaxFunctionCount", s.max_function_count));
    array_add(*comps, kv("NumCounts", s.num_counts));
    array_add(*comps, kv("NumFunctions", s.num_functions));
    array_add(*comps, kv("IsPartialProfile", ifx s.partial then cast(u64) 1 else 0));
    ratio := s.partial_ratio;
    bits := (cast(*u64) *ratio).*;
    array_add(*comps, md_tuple(.[md_string("PartialProfileRatio"), md_value(const_fp_words(type_simple(.DOUBLE), .[bits]))], false));
    entries: [..] Md_Id; entries.allocator = temp;
    for s.detailed {
        array_add(*entries, md_tuple(.[md_value(const_int(ir.t_i32, it.cutoff)), md_value(const_int(ir.t_i64, it.min_count)),
                                       md_value(const_int(ir.t_i32, it.num_counts))], false));
    }
    array_add(*comps, md_tuple(.[md_string("DetailedSummary"), md_tuple(entries, false)], false));
    return md_tuple(comps, false);
}

// Module::setModuleFlag(Behavior, Key, Val)
module_set_flag :: (behavior: u64, key: string, val: Md_Id) {
    k := named_md_get_or_insert("llvm.module.flags");
    flag := md_tuple(.[md_value(const_int(ir.t_i32, behavior)), md_string(key), val], false);
    for * ir.named_md[k].ops {
        m := it.*;
        if ir.mds[m].nops < 3 continue;
        kk := md_op(m, 1);
        if kk != NONE && ir.mds[kk].kind == .STRING && ir.mds[kk].str == key { it.* = flag; return; }
    }
    array_add(*ir.named_md[k].ops, flag);
}
