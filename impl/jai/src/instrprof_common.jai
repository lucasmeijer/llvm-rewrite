// InstrProf helpers shared by the IR PGO passes (instrprof lowering, pgo-instr-gen, pgo-icall-prom, memprof):
// section and variable names (llvm/include/llvm/ProfileData/InstrProfData.inc, InstrProf.h), PGO names, name
// variables, comdat rules, the name-string blob with its zlib compression, value-profile metadata.
// Ported from llvm/lib/ProfileData/InstrProf.cpp and setGlobalVariableLargeSection
// (llvm/lib/Transforms/Utils/Instrumentation.cpp).
//
// The name blob is compressed with the system zlib (compression::zlib::compress at BestSizeCompression); LLVM's
// opt links the same libz.so.1, so the bytes are identical (NOTES.md "The profile family").

libz :: #system_library "libz.so.1";
zlib_compress2 :: (dest: *u8, dest_len: *u64, source: *u8, source_len: u64, level: s32) -> s32 #foreign libz "compress2";
zlib_compress_bound :: (n: u64) -> u64 #foreign libz "compressBound";

instrprof_cl: struct {
    do_name_compression := true;         // -enable-name-compression (InstrProf.cpp)
    static_func_full_module_prefix := true;   // -static-func-full-module-prefix
    static_func_strip_dir_name_prefix: s64 = 0;   // -static-func-strip-dirname-prefix
    enable_vtable_value_profiling := false;   // -enable-vtable-value-profiling
};

// InstrProfSectKind (InstrProfData.inc order)
Ipsk :: enum u8 { DATA; CNTS; UCNTS; BITMAP; NAME; VNAME; VALS; VNODES; VTAB; COVMAP; COVFUN; COVDATA; COVNAME; COVINIT; }
IPSK_COMMON :: string.["__llvm_prf_data", "__llvm_prf_cnts", "__llvm_prf_ucnts", "__llvm_prf_bits", "__llvm_prf_names",
    "__llvm_prf_vns", "__llvm_prf_vals", "__llvm_prf_vnds", "__llvm_prf_vtab", "__llvm_covmap", "__llvm_covfun",
    "__llvm_covdata", "__llvm_covnames", "__llvm_covinit"];
IPSK_COFF :: string.[".lprfd$M", ".lprfc$M", ".lprfuc$M", ".lprfb$M", ".lprfn$M", ".lprfvn$M", ".lprfv$M", ".lprfnd$M",
    ".lprfvt$M", ".lcovmap$M", ".lcovfun$M", ".lcovd", ".lcovn", ".lcovd$M"];
IPSK_PREFIX :: string.["__DATA,", "__DATA,", "__DATA,", "__DATA,", "__DATA,", "__DATA,", "__DATA,", "__DATA,", "__DATA,",
    "__LLVM_COV,", "__LLVM_COV,", "__LLVM_COV,", "__LLVM_COV,", "__LLVM_COV,"];

// getInstrProfSectionName(IPSK, OF, AddSegmentInfo)
instrprof_section_name :: (k: Ipsk, obj: Triple_Object_Format, add_segment_info := true) -> string {
    s := "";
    if obj == .MachO && add_segment_info s = IPSK_PREFIX[k];
    if obj == .COFF s = tconcat(s, IPSK_COFF[k]); else s = tconcat(s, IPSK_COMMON[k]);
    if obj == .MachO && k == .DATA && add_segment_info s = tconcat(s, ",regular,live_support");
    return intern_str(s);   // kept as a global's section: not in temp
}

IPVK_INDIRECT_CALL_TARGET :: 0; IPVK_MEMOP_SIZE :: 1; IPVK_VTABLE_TARGET :: 2; IPVK_LAST :: 2;
INSTR_PROF_NAME_VAR_PREFIX :: "__profn_";
INSTR_PROF_RAW_VERSION_VAR :: "__llvm_profile_raw_version";
VARIANT_MASK_IR_PROF :: 1 << 56;

// GlobalValue::getGlobalIdentifier(Name, Linkage, FileName)
global_identifier_for :: (name_in: string, linkage: Linkage, file: string) -> string {
    name := name_in;
    if name.count && name[0] == 1 name = slice(name, 1, name.count - 1);
    if is_local_linkage(linkage) {
        f := file;
        if f.count == 0 f = "<unknown>";
        return tconcat(f, ";", name);
    }
    return name;
}

// getStrippedSourceFileName
instrprof_stripped_source_file_name :: () -> string {
    file := ir.source_filename;
    strip_level: u32 = ifx instrprof_cl.static_func_full_module_prefix then cast(u32) 0 else 0xFFFF_FFFF;
    if strip_level < cast(u32) instrprof_cl.static_func_strip_dir_name_prefix strip_level = cast(u32) instrprof_cl.static_func_strip_dir_name_prefix;
    if strip_level {
        count := strip_level; pos: u32 = 0; last: u32 = 0;
        for i: 0..file.count-1 {
            pos += 1;
            if file[i] == #char "/" { last = pos; count -= 1; }
            if count == 0 break;
        }
        file = slice(file, last, file.count - last);
    }
    return file;
}

// getIRPGOFuncName(F, InLTO = false) / getPGOName(GV)
irpgo_object_name :: (g: Value_Id, in_lto := false) -> string {
    if in_lto fatal("internal: getIRPGOFuncName in LTO mode is not ported");
    return global_identifier_for(vname(g), glob(g).linkage, instrprof_stripped_source_file_name());
}
// getPGOFuncName(F, InLTO = false): the older ':'-separated form
pgo_func_name_legacy :: (f: Value_Id) -> string {
    name := vname(f);
    if name.count && name[0] == 1 name = slice(name, 1, name.count - 1);
    if is_local_linkage(glob(f).linkage) {
        file := instrprof_stripped_source_file_name();
        if file.count == 0 return tconcat("<unknown>:", name);
        return tconcat(file, ":", name);
    }
    return name;
}

// getPGOFuncNameVarName(FuncName, Linkage)
pgo_func_name_var_name :: (func_name: string, linkage: Linkage) -> string {
    s := tconcat(INSTR_PROF_NAME_VAR_PREFIX, func_name);
    if !is_local_linkage(linkage) return s;
    b := cast([] u8) copy_string(s,, temp);
    for * b if it.* == #char "-" || it.* == #char ":" || it.* == #char ";" || it.* == #char "<" || it.* == #char ">" ||
               it.* == #char "/" || it.* == #char "\"" || it.* == #char "'" it.* = #char "_";
    return cast(string) b;
}

// ConstantDataArray::getString(Ctx, S, AddNull)
c_string_const :: (s: string, add_null: bool) -> Value_Id {
    n := s.count + (ifx add_null then 1 else 0);
    ty := type_array(cast(u64) n, ir.t_i8);
    elts := NewArray(n, u64,, allocator = temp);
    all_zero := true;
    for i: 0..s.count-1 { elts[i] = s[i]; if s[i] != 0 all_zero = false; }
    return ifx all_zero then const_zero(ty) else const_data(ty, elts);
}

// createPGOFuncNameVar(M, Linkage, PGOFuncName)
create_pgo_func_name_var :: (linkage_in: Linkage, pgo_func_name: string) -> Value_Id {
    linkage := linkage_in;
    if linkage == .EXTERN_WEAK linkage = .LINKONCE_ANY;
    else if linkage == .AVAILABLE_EXTERNALLY linkage = .LINKONCE_ODR;
    else if linkage == .INTERNAL || linkage == .EXTERNAL linkage = .PRIVATE;
    init := c_string_const(pgo_func_name, false);
    gv := gv_create(vtype(init), true, linkage, init, pgo_func_name_var_name(pgo_func_name, linkage), NONE, 0, dl.globals_as);
    // setPGOFuncVisibility
    if !is_local_linkage(glob(gv).linkage) gv_set_visibility(gv, 1);
    return gv;
}

// getPGOFuncNameVarInitializer(NameVar)
pgo_func_name_var_initializer :: (gv: Value_Id) -> string {
    init := gv_initializer(gv);
    if vkind(init) == .C_ZERO {
        // a ConstantDataArray of zeros is a ConstantAggregateZero: cast<ConstantDataArray> would fail in LLVM
        fatal("internal: PGO name variable % has a zeroinitializer", vname(gv));
    }
    if vkind(init) != .C_DATA fatal("internal: PGO name variable % is not a ConstantDataArray", vname(gv));
    n := cast(s64) const_data_count(init);
    sb: String_Builder; sb.allocator = temp;
    for i: 0..n-1 append(*sb, cast(u8) const_data_elt(init, cast(u64) i));
    s := builder_to_string(*sb,, allocator = temp);
    // isCString: the last element is 0 and no other one is
    if n > 0 && s[n - 1] == 0 {
        other_zero := false;
        for i: 0..n-2 if s[i] == 0 { other_zero = true; break; }
        if !other_zero s.count -= 1;
    }
    return s;
}

// needsComdatForCounter(GO, M)
needs_comdat_for_counter :: (g: Value_Id) -> bool {
    if glob(g).comdat >= 0 return true;
    if !triple_supports_comdat() return false;
    l := glob(g).linkage;
    return l == .EXTERN_WEAK || l == .AVAILABLE_EXTERNALLY;
}

// isIRPGOFlagSet(M)
is_irpgo_flag_set :: () -> bool {
    v := lookup_global(INSTR_PROF_RAW_VERSION_VAR);
    if v == NONE || vkind(v) != .GLOBAL_VAR || gv_has_local_linkage(v) return false;
    if is_declaration(v) return true;
    if !glob(v).has_init return false;
    init := gv_initializer(v);
    if vkind(init) != .C_INT return false;
    return (const_int_zext(init) & VARIANT_MASK_IR_PROF) != 0;
}

// canRenameComdatFunc(F, CheckAddressTaken)
can_rename_comdat_func :: (f: Value_Id, check_address_taken := false) -> bool {
    if vname(f).count == 0 return false;
    if !needs_comdat_for_counter(f) return false;
    if check_address_taken && fn_has_address_taken(f) return false;
    if !gv_is_discardable_if_unused(f) return false;
    return true;
}

// createProfileFileNameVar(M, InstrProfileOutput)
create_profile_file_name_var :: (output: string) {
    if output.count == 0 return;
    init := c_string_const(output, true);
    gv := gv_create(vtype(init), true, .WEAK_ANY, init, "__llvm_profile_filename", NONE, 0, dl.globals_as);
    gv_set_visibility(gv, 1);
    if triple_supports_comdat() {
        gv_set_linkage(gv, .EXTERNAL);
        glob(gv).comdat = get_comdat("__llvm_profile_filename");
    }
}

// setGlobalVariableLargeSection(TT, GV): x86-64 ELF with the medium / large code model
set_global_variable_large_section :: (gv: Value_Id) {
    t := triple_parse(ir.triple);
    if t.arch != .x86_64 || t.obj != .ELF return;
    ok, cm := mu_module_flag_int("Code Model");   // Module::getCodeModel: CodeModel::Model (Tiny 0 .. Large 4)
    if !ok || (cm != 3 && cm != 4) return;
    glob(gv).code_model = 5;   // large
}

encode_uleb128 :: (sb: *String_Builder, v_in: u64) {
    v := v_in;
    while true {
        b := cast(u8) (v & 0x7f);
        v >>= 7;
        if v != 0 b |= 0x80;
        append(sb, b);
        if v == 0 break;
    }
}

// collectGlobalObjectNameStrings(NameStrs, DoCompression, Result)
collect_global_object_name_strings :: (names: [] string, do_compression: bool) -> string {
    sb: String_Builder; sb.allocator = temp;
    for names { if it_index > 0 append(*sb, cast(u8) 1); append(*sb, it); }   // getInstrProfNameSeparator() = "\01"
    uncompressed := builder_to_string(*sb,, allocator = temp);
    out: String_Builder; out.allocator = temp;
    encode_uleb128(*out, cast(u64) uncompressed.count);
    if !do_compression {
        encode_uleb128(*out, 0);
        append(*out, uncompressed);
        return builder_to_string(*out,, allocator = temp);
    }
    bound := zlib_compress_bound(cast(u64) uncompressed.count);
    buf := NewArray(cast(s64) bound, u8,, allocator = temp);
    dlen: u64 = bound;
    r := zlib_compress2(buf.data, *dlen, uncompressed.data, cast(u64) uncompressed.count, 9);
    if r != 0 fatal("zlib compress2 failed (%)", r);
    encode_uleb128(*out, dlen);
    c: string; c.data = buf.data; c.count = cast(s64) dlen;
    append(*out, c);
    return builder_to_string(*out,, allocator = temp);
}
