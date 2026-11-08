// TargetLibraryInfo: a port of llvm/lib/Analysis/TargetLibraryInfo.cpp and include/llvm/Analysis/TargetLibraryInfo.h
// (TargetLibraryInfoImpl, TargetLibraryInfo, TargetLibraryAnalysis), with the parts of
// llvm/lib/TargetParser/Triple.cpp it needs (Triple parsing, OS / environment versions, the is*() predicates).
// Tables: gen_tli.jai (gen/gen_tli.py from TargetLibraryInfo.td), gen_triple.jai (gen/gen_triple.py from
// TripleName.def).
//
// API (LLVM name -> here):
//   TargetLibraryAnalysis result for F      tli_for(f) -> *Tli (never invalidated, like TargetLibraryInfo::invalidate)
//   getLibFunc(StringRef, F)                tli_lookup_name(name) -> (bool, Lib_Func)
//   getLibFunc(const Function &, F)         tli_lookup_fn(fdecl) -> (bool, Lib_Func)   (prototype checked)
//   getLibFunc(const CallBase &, F)         tli_lookup_call(call) -> (bool, Lib_Func)
//   has(F) / getName(F) / getState(F)       tli_func_has(t, lf) / tli_func_name(t, lf) / tli_state(t, lf)
//   isValidProtoForLibFunc                  tli_valid_proto_for(ft, lf)
//   getSizeTSize / getIntSize / getWCharSize  tli_size_t_bits() / tli_int_bits() / tli_wchar_size()
//   getExtAttrForI32Param / Return          tli_ext_attr_for_i32_param(signed) / tli_ext_attr_for_i32_return(signed)
//   isCallingConvCCompatible(CB / F)        tli_is_calling_conv_c_compatible_call(c) / _fn(f)
//   hasOptimizedCodeGen                     tli_has_optimized_code_gen(t, lf)
// Vector library mappings (VecFuncs.def, -vector-library) are not ported: opt's -vector-library is rejected as an
// unknown flag, so no mapping can be asked for.

// ---------------------------------------------------------------- Triple (TargetParser/Triple.cpp subset)

Triple_Arch :: enum u8 {
    UnknownArch :: 0;
    arm; armeb; aarch64; aarch64_be; aarch64_32; arc; avr; bpfel; bpfeb; csky; dxil; hexagon; loongarch32; loongarch64;
    m68k; mips; mipsel; mips64; mips64el; msp430; ppc; ppcle; ppc64; ppc64le; r600; amdgpu; riscv32; riscv64;
    riscv32be; riscv64be; sparc; sparcv9; sparcel; systemz; tce; tcele; tcele64; thumb; thumbeb; x86; x86_64; xcore;
    xtensa; nvptx; nvptx64; amdil; amdil64; hsail; hsail64; spir; spir64; spirv; spirv32; spirv64; kalimba; shave;
    lanai; wasm32; wasm64; renderscript32; renderscript64; ve;
}
// Triple::parseArch's StringSwitch (exact names; "amdgpu*" and "kalimba*" are prefixes)
TRIPLE_ARCH_PARSE :: struct { name: string; v: Triple_Arch; }.[
    .{"i386", .x86}, .{"i486", .x86}, .{"i586", .x86}, .{"i686", .x86}, .{"i786", .x86}, .{"i886", .x86}, .{"i986", .x86},
    .{"amd64", .x86_64}, .{"x86_64", .x86_64}, .{"x86_64h", .x86_64}, .{"x86_64_lfi", .x86_64},
    .{"powerpc", .ppc}, .{"powerpcspe", .ppc}, .{"ppc", .ppc}, .{"ppc32", .ppc},
    .{"powerpcle", .ppcle}, .{"ppcle", .ppcle}, .{"ppc32le", .ppcle},
    .{"powerpc64", .ppc64}, .{"ppu", .ppc64}, .{"ppc64", .ppc64}, .{"powerpc64le", .ppc64le}, .{"ppc64le", .ppc64le},
    .{"xscale", .arm}, .{"xscaleeb", .armeb}, .{"aarch64", .aarch64}, .{"aarch64_be", .aarch64_be},
    .{"aarch64_32", .aarch64_32}, .{"aarch64_lfi", .aarch64}, .{"arc", .arc}, .{"arm64", .aarch64},
    .{"arm64_32", .aarch64_32}, .{"arm64e", .aarch64}, .{"arm64e.x1", .aarch64}, .{"arm64ec", .aarch64},
    .{"arm", .arm}, .{"armeb", .armeb}, .{"thumb", .thumb}, .{"thumbeb", .thumbeb}, .{"avr", .avr}, .{"m68k", .m68k},
    .{"msp430", .msp430},
    .{"mips", .mips}, .{"mipseb", .mips}, .{"mipsallegrex", .mips}, .{"mipsisa32r6", .mips}, .{"mipsr6", .mips},
    .{"mipsel", .mipsel}, .{"mipsallegrexel", .mipsel}, .{"mipsisa32r6el", .mipsel}, .{"mipsr6el", .mipsel},
    .{"mips64", .mips64}, .{"mips64eb", .mips64}, .{"mipsn32", .mips64}, .{"mipsisa64r6", .mips64},
    .{"mips64r6", .mips64}, .{"mipsn32r6", .mips64},
    .{"mips64el", .mips64el}, .{"mipsn32el", .mips64el}, .{"mipsisa64r6el", .mips64el}, .{"mips64r6el", .mips64el},
    .{"mipsn32r6el", .mips64el},
    .{"amdgcn", .amdgpu}, .{"r600", .r600}, .{"riscv32", .riscv32}, .{"riscv64", .riscv64},
    .{"riscv32be", .riscv32be}, .{"riscv64be", .riscv64be}, .{"hexagon", .hexagon}, .{"s390x", .systemz},
    .{"systemz", .systemz}, .{"sparc", .sparc}, .{"sparcel", .sparcel}, .{"sparcv9", .sparcv9}, .{"sparc64", .sparcv9},
    .{"tce", .tce}, .{"tcele", .tcele}, .{"tcele64", .tcele64}, .{"xcore", .xcore}, .{"nvptx", .nvptx},
    .{"nvptx64", .nvptx64}, .{"amdil", .amdil}, .{"amdil64", .amdil64}, .{"hsail", .hsail}, .{"hsail64", .hsail64},
    .{"spir", .spir}, .{"spir64", .spir64}, .{"spirv", .spirv}, .{"spirv1.5", .spirv}, .{"spirv1.6", .spirv},
    .{"lanai", .lanai}, .{"renderscript32", .renderscript32}, .{"renderscript64", .renderscript64},
    .{"shave", .shave}, .{"ve", .ve}, .{"wasm32", .wasm32}, .{"wasm64", .wasm64}, .{"csky", .csky},
    .{"loongarch32", .loongarch32}, .{"loongarch64", .loongarch64}, .{"xtensa", .xtensa},
];

Triple_Object_Format :: enum u8 { UnknownObjectFormat :: 0; COFF; DXContainer; ELF; GOFF; MachO; SPIRV; Wasm; XCOFF; }

Version_Tuple :: struct { major: u32; minor: u32; micro: u32; build: u32; }
version_lt :: (a: Version_Tuple, b: Version_Tuple) -> bool {
    if a.major != b.major return a.major < b.major;
    if a.minor != b.minor return a.minor < b.minor;
    if a.micro != b.micro return a.micro < b.micro;
    return a.build < b.build;
}

Triple :: struct {
    data: string;
    arch: Triple_Arch;
    vendor: Triple_Vendor;
    os: Triple_OS;
    env: Triple_Env;
    obj: Triple_Object_Format;
}

// Triple::parseArch (the ARM / BPF special parsers are approximated by the arch family of the name)
triple_parse_arch :: (s: string) -> Triple_Arch {
    for TRIPLE_ARCH_PARSE if it.name == s return it.v;
    if begins_with(s, "amdgpu") return .amdgpu;
    if begins_with(s, "kalimba") return .kalimba;
    if begins_with(s, "spirv32") return .spirv32;
    if begins_with(s, "spirv64") return .spirv64;
    if begins_with(s, "dxil") return .dxil;
    // parseARMArch: aarch64* / arm64* -> aarch64(_be), arm* / thumb* by endianness
    if begins_with(s, "aarch64") || begins_with(s, "arm64") return ifx contains(s, "_be") then .aarch64_be else .aarch64;
    if begins_with(s, "arm") return ifx ends_with(s, "eb") then .armeb else .arm;
    if begins_with(s, "thumb") return ifx ends_with(s, "eb") then .thumbeb else .thumb;
    if begins_with(s, "bpf") return ifx s == "bpfeb" then .bpfeb else .bpfel;
    return .UnknownArch;
}
triple_parse_vendor :: (s: string) -> Triple_Vendor {
    for TRIPLE_VENDOR_PARSE if it.name == s return it.v;
    return .UnknownVendor;
}
triple_parse_os :: (s: string) -> Triple_OS {
    for TRIPLE_OS_PARSE if begins_with(s, it.name) return it.v;
    return .UnknownOS;
}
triple_parse_env :: (s: string) -> Triple_Env {
    for TRIPLE_ENV_PARSE if begins_with(s, it.name) return it.v;
    return .UnknownEnvironment;
}
triple_parse_format :: (s: string) -> Triple_Object_Format {
    if ends_with(s, "xcoff") return .XCOFF;
    if ends_with(s, "coff") return .COFF;
    if ends_with(s, "elf") return .ELF;
    if ends_with(s, "goff") return .GOFF;
    if ends_with(s, "macho") return .MachO;
    if ends_with(s, "wasm") return .Wasm;
    if ends_with(s, "spirv") return .SPIRV;
    return .UnknownObjectFormat;
}
// getDefaultFormat (only the cases TLI cares about: MachO for Darwin, COFF for Windows, ELF otherwise)
triple_default_format :: (t: *Triple) -> Triple_Object_Format {
    if triple_is_os_darwin(t) return .MachO;
    if t.os == .Win32 return .COFF;
    if t.arch == .dxil return .DXContainer;
    if t.arch == .UnknownArch return .ELF;
    return .ELF;
}

// Triple::Triple(std::string &&Str)
triple_parse :: (s: string) -> Triple {
    t: Triple;
    t.data = s;
    comps := split(s, "-",, allocator = temp);
    // split(Components, '-', MaxSplit = 3): the 4th component keeps the rest
    if comps.count > 4 {
        rest := s;
        for 0..2 { k := find_index_from_left(rest, #char "-"); rest = slice(rest, k + 1, rest.count - k - 1); }
        comps.count = 4; comps[3] = rest;
    }
    if comps.count > 0 {
        t.arch = triple_parse_arch(comps[0]);
        if comps.count > 1 {
            t.vendor = triple_parse_vendor(comps[1]);
            if comps.count > 2 {
                t.os = triple_parse_os(comps[2]);
                if comps.count > 3 {
                    t.env = triple_parse_env(comps[3]);
                    t.obj = triple_parse_format(comps[3]);
                }
            }
        } else {
            c := comps[0];
            if begins_with(c, "mipsn32") t.env = .GNUABIN32;
            else if begins_with(c, "mips64") || begins_with(c, "mipsisa64") t.env = .GNUABI64;
            else if begins_with(c, "mipsisa32") t.env = .GNU;
            else if c == "mips" || c == "mipsel" || c == "mipsr6" || c == "mipsr6el" t.env = .GNU;
        }
    }
    if t.obj == .UnknownObjectFormat t.obj = triple_default_format(*t);
    return t;
}

triple_component :: (t: *Triple, idx: s64) -> string {
    rest := t.data;
    for 0..idx-1 {
        k := find_index_from_left(rest, #char "-");
        if k < 0 return "";
        rest = slice(rest, k + 1, rest.count - k - 1);
    }
    if idx >= 3 return rest;   // getEnvironmentName: everything after the third '-'
    k := find_index_from_left(rest, #char "-");
    if k >= 0 rest = slice(rest, 0, k);
    return rest;
}

// VersionTuple::tryParse + withoutBuild (on a parse error the result stays 0)
version_parse :: (s_in: string) -> Version_Tuple {
    v: Version_Tuple;
    s := s_in;
    parse_int :: (s: *string) -> bool, u32 {
        if s.count == 0 || !c_isdigit(s.*[0]) return false, 0;
        r: u32 = 0;
        while s.count && c_isdigit(s.*[0]) { r = r * 10 + cast(u32)(s.*[0] - #char "0"); advance(s, 1); }
        return true, r;
    }
    ok, major := parse_int(*s);
    if !ok return v;
    if s.count == 0 { v.major = major; return v; }
    if s[0] != #char "." return v;
    advance(*s, 1);
    ok2, minor := parse_int(*s);
    if !ok2 return v;
    if s.count == 0 { v.major = major; v.minor = minor; return v; }
    if s[0] != #char "." return v;
    advance(*s, 1);
    ok3, micro := parse_int(*s);
    if !ok3 return v;
    if s.count == 0 { v.major = major; v.minor = minor; v.micro = micro; return v; }
    if s[0] != #char "." return v;
    advance(*s, 1);
    ok4, build := parse_int(*s);
    if !ok4 || s.count != 0 return v;
    v.major = major; v.minor = minor; v.micro = micro;   // withoutBuild
    return v;
}

// Triple::getOSVersion
triple_os_version :: (t: *Triple) -> Version_Tuple {
    name := triple_component(t, 2);
    tn := TRIPLE_OS_NAMES[cast(int) t.os];
    if begins_with(name, tn) name = slice(name, tn.count, name.count - tn.count);
    else if t.os == .MacOSX && begins_with(name, "macos") name = slice(name, 5, name.count - 5);
    else if begins_with(name, "visionos") name = slice(name, 8, name.count - 8);
    return version_parse(name);
}
// Triple::getEnvironmentVersion
triple_env_version :: (t: *Triple) -> Version_Tuple {
    name := triple_component(t, 3);
    if name == "none" return .{};
    en := TRIPLE_ENV_NAMES[cast(int) t.env];
    if begins_with(name, en) name = slice(name, en.count, name.count - en.count);
    if contains(name, "-") && t.obj != .UnknownObjectFormat {
        names :: string.["", "coff", "dxcontainer", "elf", "goff", "macho", "spirv", "wasm", "xcoff"];
        suf := tprint("-%", names[cast(int) t.obj]);
        if ends_with(name, suf) name = slice(name, 0, name.count - suf.count);
    }
    return version_parse(name);
}
triple_is_os_version_lt :: (t: *Triple, major: u32, minor: u32 = 0, micro: u32 = 0) -> bool {
    return version_lt(triple_os_version(t), .{major, minor, micro, 0});
}
// Triple::isMacOSXVersionLT
triple_is_macosx_version_lt :: (t: *Triple, major: u32, minor: u32 = 0, micro: u32 = 0) -> bool {
    if t.os == .MacOSX return triple_is_os_version_lt(t, major, minor, micro);
    if major == 10 return triple_is_os_version_lt(t, minor + 4, micro, 0);
    if major < 25 return triple_is_os_version_lt(t, major - 11 + 20, minor, micro);
    return triple_is_os_version_lt(t, major + 1, minor, micro);
}
triple_is_macosx :: (t: *Triple) -> bool { return t.os == .Darwin || t.os == .MacOSX; }
triple_is_ios :: (t: *Triple) -> bool { return t.os == .IOS || t.os == .TvOS; }
triple_is_watchos :: (t: *Triple) -> bool { return t.os == .WatchOS; }
triple_is_os_darwin :: (t: *Triple) -> bool {
    return triple_is_macosx(t) || triple_is_ios(t) || t.os == .WatchOS || t.os == .DriverKit || t.os == .XROS ||
           t.os == .BridgeOS || (t.vendor == .Apple && t.os == .Firmware);
}
triple_is_gnu_environment :: (t: *Triple) -> bool {
    e := t.env;
    return e == .GNU || e == .GNUT64 || e == .GNUABIN32 || e == .GNUABI64 || e == .GNUEABI || e == .GNUEABIT64 ||
           e == .GNUEABIHF || e == .GNUEABIHFT64 || e == .GNUF32 || e == .GNUF64 || e == .GNUSF || e == .GNUX32;
}
triple_is_musl :: (t: *Triple) -> bool {
    e := t.env;
    return e == .Musl || e == .MuslABIN32 || e == .MuslABI64 || e == .MuslEABI || e == .MuslEABIHF || e == .MuslF32 ||
           e == .MuslSF || e == .MuslX32 || e == .MuslWALI || e == .OpenHOS || t.os == .LiteOS;
}
triple_is_windows_msvc_environment :: (t: *Triple) -> bool {
    return t.os == .Win32 && (t.env == .MSVC || t.env == .UnknownEnvironment);
}
triple_is_os_cyg_ming :: (t: *Triple) -> bool { return t.os == .Win32 && (t.env == .Cygnus || t.env == .GNU); }
triple_is_os_msvcrt :: (t: *Triple) -> bool {
    return triple_is_windows_msvc_environment(t) || (t.os == .Win32 && (t.env == .GNU || t.env == .Itanium));
}
triple_is_ps :: (t: *Triple) -> bool { return t.arch == .x86_64 && t.vendor == .SCEI && (t.os == .PS4 || t.os == .PS5); }
triple_is_arch_64bit :: (t: *Triple) -> bool {
    a := t.arch;
    return a == .aarch64 || a == .aarch64_be || a == .amdgpu || a == .bpfel || a == .bpfeb || a == .loongarch64 ||
           a == .mips64 || a == .mips64el || a == .nvptx64 || a == .ppc64 || a == .ppc64le || a == .riscv64 ||
           a == .riscv64be || a == .sparcv9 || a == .systemz || a == .x86_64 || a == .amdil64 || a == .hsail64 ||
           a == .spir64 || a == .spirv64 || a == .wasm64 || a == .renderscript64 || a == .ve || a == .tcele64;
}
triple_is_arch_16bit :: (t: *Triple) -> bool { return t.arch == .avr || t.arch == .msp430; }
triple_is_arch_32bit :: (t: *Triple) -> bool {
    return !triple_is_arch_64bit(t) && !triple_is_arch_16bit(t) && t.arch != .UnknownArch;
}
triple_is_android_version_lt :: (t: *Triple, major: u32) -> bool {
    v := triple_env_version(t);
    if triple_is_arch_64bit(t) && v.major < 21 return version_lt(.{21, 0, 0, 0}, .{major, 0, 0, 0});
    return version_lt(v, .{major, 0, 0, 0});
}
// Triple::getDefaultWCharSize
triple_default_wchar_size :: (t: *Triple) -> u32 {
    if t.arch == .xcore return 1;
    if t.os == .Win32 || t.os == .UEFI || triple_is_ps(t) return 2;
    if t.os == .AIX && triple_is_arch_32bit(t) return 2;
    return 4;
}

// ---------------------------------------------------------------- TargetLibraryInfoImpl

TLI_UNAVAILABLE :: 0; TLI_CUSTOM_NAME :: 1; TLI_STANDARD_NAME :: 3;

Tli_Impl :: struct {
    state: [NUM_LIB_FUNCS] u8;          // AvailableArray (one entry per function instead of 2-bit packing)
    custom_names: [NUM_LIB_FUNCS] string;
    should_ext_i32_param: bool;
    should_ext_i32_return: bool;
    should_sign_ext_i32_param: bool;
    should_sign_ext_i32_return: bool;
    size_of_int: u32;
    triple: Triple;
}

// TargetLibraryInfo (the per-function result)
Tli :: struct {
    impl: *Tli_Impl;
    override_unavailable: [NUM_LIB_FUNCS] bool;
}

tli_baseline: *Tli_Impl;                  // TLII built by opt from the module triple
tli_results: Table(Value_Id, *Tli);
tli_name_index: Table(string, Lib_Func);

tli_set_state :: (impl: *Tli_Impl, f: Lib_Func, st: u8) { impl.state[cast(int) f] = st; }
tli_set_unavailable :: (impl: *Tli_Impl, f: Lib_Func) { tli_set_state(impl, f, TLI_UNAVAILABLE); }
tli_set_available :: (impl: *Tli_Impl, f: Lib_Func) { tli_set_state(impl, f, TLI_STANDARD_NAME); }
tli_set_available_with_name :: (impl: *Tli_Impl, f: Lib_Func, name: string) {
    if LIB_FUNC_NAMES[cast(int) f] != name {
        tli_set_state(impl, f, TLI_CUSTOM_NAME);
        impl.custom_names[cast(int) f] = name;
    } else tli_set_state(impl, f, TLI_STANDARD_NAME);
}
tli_disable_all_functions :: (impl: *Tli_Impl) { for 0..NUM_LIB_FUNCS-1 impl.state[it] = TLI_UNAVAILABLE; }

hasSinCosPiStret :: (t: *Triple) -> bool {
    if !triple_is_os_darwin(t) return false;
    if t.arch == .x86 return false;
    if triple_is_macosx(t) && triple_is_macosx_version_lt(t, 10, 9) return false;
    if triple_is_ios(t) && triple_is_os_version_lt(t, 7, 0) return false;
    return true;
}
hasBcmp :: (t: *Triple) -> bool {
    if t.os == .Linux return triple_is_gnu_environment(t) || triple_is_musl(t);
    return t.os == .FreeBSD || t.os == .Solaris;
}

// initializeBase + initializeLibCalls (TargetLibraryInfo.cpp), in LLVM's order
tli_initialize :: (tli: *Tli_Impl, T: *Triple) {
    U :: (f: Lib_Func) #expand { tli_set_unavailable(`tli, f); }
    A :: (f: Lib_Func) #expand { tli_set_available(`tli, f); }
    // initializeBase: TargetLibraryInfo::initExtensionsForTriple
    a := T.arch;
    is_ppc64 := a == .ppc64 || a == .ppc64le;
    is_loongarch := a == .loongarch32 || a == .loongarch64;
    is_mips := a == .mips || a == .mipsel || a == .mips64 || a == .mips64el;
    is_riscv64 := a == .riscv64 || a == .riscv64be;
    if is_ppc64 || a == .sparcv9 || a == .systemz { tli.should_ext_i32_param = true; tli.should_ext_i32_return = true; }
    if is_loongarch || is_mips || is_riscv64 tli.should_sign_ext_i32_param = true;
    if is_loongarch || is_riscv64 tli.should_sign_ext_i32_return = true;
    tli.size_of_int = ifx triple_is_arch_16bit(T) then cast(u32) 16 else 32;

    // initializeLibCalls
    U(.getc_unlocked); U(.getchar_unlocked); U(.putc_unlocked); U(.putchar_unlocked); U(.fputc_unlocked);
    U(.fgetc_unlocked); U(.fread_unlocked); U(.fwrite_unlocked); U(.fputs_unlocked); U(.fgets_unlocked);
    if a == .amdgpu || a == .r600 { tli_disable_all_functions(tli); return; }
    if a == .dxil { tli_disable_all_functions(tli); return; }
    if triple_is_macosx(T) {
        A(.getc_unlocked); A(.getchar_unlocked); A(.putc_unlocked); A(.putchar_unlocked);
        U(.memrchr);
        if triple_is_macosx_version_lt(T, 10, 5) { U(.memset_pattern4); U(.memset_pattern8); U(.memset_pattern16); }
    } else if triple_is_ios(T) {
        if triple_is_os_version_lt(T, 3, 0) { U(.memset_pattern4); U(.memset_pattern8); U(.memset_pattern16); }
    } else if !triple_is_watchos(T) {
        U(.memset_pattern4); U(.memset_pattern8); U(.memset_pattern16);
    }
    if !hasSinCosPiStret(T) {
        U(.sinpi); U(.sinpif); U(.cospi); U(.cospif); U(.sincospi_stret); U(.sincospif_stret);
    }
    if !hasBcmp(T) U(.bcmp);
    if triple_is_macosx(T) && a == .x86 && !triple_is_macosx_version_lt(T, 10, 7) {
        tli_set_available_with_name(tli, .fwrite, "fwrite$UNIX2003");
        tli_set_available_with_name(tli, .fputs, "fputs$UNIX2003");
    }
    if a != .xcore && a != .tce && T.os != .Emscripten { U(.iprintf); U(.siprintf); U(.fiprintf); }
    if T.os != .Emscripten { U(.small_printf); U(.small_sprintf); U(.small_fprintf); }

    if T.os == .Win32 && !triple_is_os_cyg_ming(T) {
        has_partial_c99 := true;
        if T.os == .Win32 && T.env == .MSVC {
            v := triple_env_version(T);
            has_partial_c99 = v.major == 0 || v.major >= 19;
        }
        is_arm := a == .aarch64 || a == .arm;
        has_partial_float := is_arm || a == .x86_64;
        if !has_partial_float {
            U(.acosf); U(.asinf); U(.atan2f); U(.atanf); U(.ceilf); U(.cosf); U(.coshf); U(.expf); U(.floorf);
            U(.fmodf); U(.hypotf); U(.log10f); U(.logf); U(.modff); U(.powf); U(.remainderf); U(.remquof);
            U(.fdimf); U(.sinf); U(.sinhf); U(.sqrtf); U(.tanf); U(.tanhf);
        }
        if !is_arm U(.fabsf);
        U(.frexpf); U(.ldexpf);
        U(.acosl); U(.asinl); U(.atan2l); U(.atanl); U(.ceill); U(.cosl); U(.coshl); U(.expl); U(.fabsl); U(.floorl);
        U(.fmodl); U(.frexpl); U(.hypotl); U(.ldexpl); U(.log10l); U(.logl); U(.modfl); U(.powl); U(.remainderl);
        U(.remquol); U(.fdiml); U(.sinl); U(.sinhl); U(.sqrtl); U(.tanl); U(.tanhl);
        if !has_partial_c99 {
            U(.acosh); U(.acoshf); U(.asinh); U(.asinhf); U(.atanh); U(.atanhf);
            tli_set_available_with_name(tli, .cabs, "_cabs");
            U(.cabsf); U(.cbrt); U(.cbrtf);
            tli_set_available_with_name(tli, .copysign, "_copysign");
            tli_set_available_with_name(tli, .copysignf, "_copysignf");
            U(.exp2); U(.exp2f); U(.expm1); U(.expm1f); U(.fmax); U(.fmaxf); U(.fmin); U(.fminf); U(.log1p);
            U(.log1pf); U(.log2); U(.log2f);
            tli_set_available_with_name(tli, .logb, "_logb");
            U(.ilogb); U(.ilogbf);
            if has_partial_float tli_set_available_with_name(tli, .logbf, "_logbf");
            else U(.logbf);
            U(.nextafter); U(.nextafterf); U(.nexttoward); U(.nexttowardf); U(.rint); U(.rintf); U(.round);
            U(.roundf); U(.scalbln); U(.scalblnf); U(.scalblnl); U(.scalbn); U(.scalbnf); U(.scalbnl); U(.trunc);
            U(.truncf);
        }
        U(.acoshl); U(.asinhl); U(.atanhl); U(.cabsl); U(.cbrtl); U(.copysignl); U(.exp2l); U(.expm1l); U(.fmaxl);
        U(.fminl); U(.log1pl); U(.log2l); U(.logbl); U(.ilogbl); U(.nearbyintl); U(.nextafterl); U(.nexttowardl);
        U(.rintl); U(.roundl); U(.scalblnl); U(.scalbnl); U(.truncl);
        U(.access); U(.chmod); U(.closedir); U(.fdopen); U(.fileno); U(.fseeko); U(.fstat); U(.ftello);
        U(.gettimeofday); U(.memccpy); U(.mkdir); U(.open); U(.opendir); U(.pclose); U(.popen); U(.read); U(.rmdir);
        U(.stat); U(.strcasecmp); U(.strncasecmp); U(.unlink); U(.utime); U(.write);
    }
    if T.os == .Win32 && T.env != .Cygnus {
        U(.bcmp); U(.bcopy); U(.bzero); U(.chown); U(.ctermid); U(.ffs); U(.flockfile); U(.fstatvfs);
        U(.ftrylockfile); U(.funlockfile); U(.getitimer); U(.getlogin_r); U(.getpwnam); U(.htonl); U(.htons);
        U(.lchown); U(.lstat); U(.memrchr); U(.ntohl); U(.ntohs); U(.pread); U(.pwrite); U(.readlink); U(.realpath);
        U(.setitimer); U(.statvfs); U(.stpcpy); U(.stpncpy); U(.times); U(.uname); U(.unsetenv); U(.utimes);
        U(.ldexpf);
    }
    if triple_is_os_msvcrt(T) {
        U(.ZdaPv); U(.ZdaPvRKSt9nothrow_t); U(.ZdaPvSt11align_val_t); U(.ZdaPvSt11align_val_tRKSt9nothrow_t);
        U(.ZdaPvj); U(.ZdaPvjSt11align_val_t); U(.ZdaPvm); U(.ZdaPvmSt11align_val_t); U(.ZdlPv);
        U(.ZdlPvRKSt9nothrow_t); U(.ZdlPvSt11align_val_t); U(.ZdlPvSt11align_val_tRKSt9nothrow_t); U(.ZdlPvj);
        U(.ZdlPvjSt11align_val_t); U(.ZdlPvm); U(.ZdlPvmSt11align_val_t); U(.Znaj); U(.ZnajRKSt9nothrow_t);
        U(.ZnajSt11align_val_t); U(.ZnajSt11align_val_tRKSt9nothrow_t); U(.Znam); U(.ZnamRKSt9nothrow_t);
        U(.ZnamRKSt9nothrow_t12__hot_cold_t); U(.ZnamSt11align_val_t); U(.ZnamSt11align_val_tRKSt9nothrow_t);
        U(.Znwj); U(.ZnwjRKSt9nothrow_t); U(.ZnwjSt11align_val_t); U(.ZnwjSt11align_val_tRKSt9nothrow_t); U(.Znwm);
        U(.ZnwmRKSt9nothrow_t); U(.ZnwmRKSt9nothrow_t12__hot_cold_t); U(.ZnwmSt11align_val_t);
        U(.ZnwmSt11align_val_tRKSt9nothrow_t); U(.Znwm12__hot_cold_t); U(.ZnwmSt11align_val_t12__hot_cold_t);
        U(.ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t); U(.Znam12__hot_cold_t);
        U(.ZnamSt11align_val_t12__hot_cold_t); U(.ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t);
        U(.size_returning_new); U(.size_returning_new_hot_cold); U(.size_returning_new_aligned);
        U(.size_returning_new_aligned_hot_cold);
    } else {
        U(.msvc_new_int); U(.msvc_new_int_nothrow); U(.msvc_new_longlong); U(.msvc_new_longlong_nothrow);
        U(.msvc_delete_ptr32); U(.msvc_delete_ptr32_nothrow); U(.msvc_delete_ptr32_int); U(.msvc_delete_ptr64);
        U(.msvc_delete_ptr64_nothrow); U(.msvc_delete_ptr64_longlong); U(.msvc_new_array_int);
        U(.msvc_new_array_int_nothrow); U(.msvc_new_array_longlong); U(.msvc_new_array_longlong_nothrow);
        U(.msvc_delete_array_ptr32); U(.msvc_delete_array_ptr32_nothrow); U(.msvc_delete_array_ptr32_int);
        U(.msvc_delete_array_ptr64); U(.msvc_delete_array_ptr64_nothrow); U(.msvc_delete_array_ptr64_longlong);
    }
    if T.os == .MacOSX {
        U(.exp10l);
        if triple_is_macosx_version_lt(T, 10, 9) { U(.exp10); U(.exp10f); }
        else { tli_set_available_with_name(tli, .exp10, "__exp10"); tli_set_available_with_name(tli, .exp10f, "__exp10f"); }
    } else if T.os == .IOS || T.os == .TvOS || T.os == .WatchOS || T.os == .XROS {
        U(.exp10l);
        is_x86 := a == .x86 || a == .x86_64;
        if !triple_is_watchos(T) && (triple_is_os_version_lt(T, 7, 0) || (triple_is_os_version_lt(T, 9, 0) && is_x86)) {
            U(.exp10); U(.exp10f);
        } else { tli_set_available_with_name(tli, .exp10, "__exp10"); tli_set_available_with_name(tli, .exp10f, "__exp10f"); }
    } else {
        U(.exp10); U(.exp10f); U(.exp10l);
    }
    os := T.os;
    ffs_os := os == .Darwin || os == .MacOSX || os == .IOS || os == .TvOS || os == .WatchOS || os == .XROS ||
              os == .FreeBSD || os == .Linux;
    if !ffs_os U(.ffsl);
    if !ffs_os U(.ffsll);
    if os != .FreeBSD { U(.fls); U(.flsl); U(.flsll); }
    if !(os == .Linux) || !triple_is_gnu_environment(T) {
        U(.dunder_strdup); U(.dunder_strtok_r); U(.dunder_isoc99_scanf); U(.dunder_isoc99_sscanf);
        U(.under_IO_getc); U(.under_IO_putc);
        if T.env != .Android && !triple_is_musl(T) U(.memalign);
        U(.fopen64); U(.fseeko64); U(.fstat64); U(.fstatvfs64); U(.ftello64); U(.lstat64); U(.open64); U(.stat64);
        U(.statvfs64); U(.tmpfile64);
        U(.acos_finite); U(.acosf_finite); U(.acosl_finite); U(.acosh_finite); U(.acoshf_finite); U(.acoshl_finite);
        U(.asin_finite); U(.asinf_finite); U(.asinl_finite); U(.atan2_finite); U(.atan2f_finite); U(.atan2l_finite);
        U(.atanh_finite); U(.atanhf_finite); U(.atanhl_finite); U(.cosh_finite); U(.coshf_finite); U(.coshl_finite);
        U(.exp10_finite); U(.exp10f_finite); U(.exp10l_finite); U(.exp2_finite); U(.exp2f_finite); U(.exp2l_finite);
        U(.exp_finite); U(.expf_finite); U(.expl_finite); U(.log10_finite); U(.log10f_finite); U(.log10l_finite);
        U(.log2_finite); U(.log2f_finite); U(.log2l_finite); U(.log_finite); U(.logf_finite); U(.logl_finite);
        U(.pow_finite); U(.powf_finite); U(.powl_finite); U(.sinh_finite); U(.sinhf_finite); U(.sinhl_finite);
        U(.sqrt_finite); U(.sqrtf_finite); U(.sqrtl_finite);
    }
    if (os == .Linux && triple_is_gnu_environment(T)) || (T.env == .Android && !triple_is_android_version_lt(T, 28)) {
        A(.getc_unlocked); A(.getchar_unlocked); A(.putc_unlocked); A(.putchar_unlocked); A(.fputc_unlocked);
        A(.fgetc_unlocked); A(.fread_unlocked); A(.fwrite_unlocked); A(.fputs_unlocked); A(.fgets_unlocked);
    }
    if triple_is_ps(T) {
        A(.memalign);
        U(.ZdaPvj); U(.ZdaPvjSt11align_val_t); U(.ZdlPvj); U(.ZdlPvjSt11align_val_t); U(.Znaj);
        U(.ZnajRKSt9nothrow_t); U(.ZnajSt11align_val_t); U(.ZnajSt11align_val_tRKSt9nothrow_t); U(.Znwj);
        U(.ZnwjRKSt9nothrow_t); U(.ZnwjSt11align_val_t); U(.ZnwjSt11align_val_tRKSt9nothrow_t);
        U(.memccpy_chk); U(.memcpy_chk); U(.memmove_chk); U(.mempcpy_chk); U(.memset_chk); U(.snprintf_chk);
        U(.sprintf_chk); U(.stpcpy_chk); U(.stpncpy_chk); U(.strcat_chk); U(.strcpy_chk); U(.strlcat_chk);
        U(.strlcpy_chk); U(.strlen_chk); U(.strncat_chk); U(.strncpy_chk); U(.vsnprintf_chk); U(.vsprintf_chk);
        U(.access); U(.chmod); U(.chown); U(.closedir); U(.ctermid); U(.execl); U(.execle); U(.execlp); U(.execv);
        U(.execvP); U(.execve); U(.execvp); U(.execvpe); U(.fork); U(.fstat); U(.fstatvfs); U(.getenv);
        U(.getitimer); U(.getlogin_r); U(.getpwnam); U(.gettimeofday); U(.lchown); U(.lstat); U(.mkdir); U(.open);
        U(.opendir); U(.pclose); U(.popen); U(.pread); U(.pvalloc); U(.pwrite); U(.read); U(.readlink);
        U(.realpath); U(.rename); U(.rmdir); U(.setitimer); U(.stat); U(.statvfs); U(.system); U(.times);
        U(.tmpfile); U(.unlink); U(.uname); U(.unsetenv); U(.utime); U(.utimes); U(.valloc); U(.write);
        U(.atomic_load); U(.atomic_store); U(.dunder_strndup); U(.bcmp); U(.bcopy); U(.bzero); U(.cabs);
        U(.cabsf); U(.cabsl); U(.ffs); U(.flockfile); U(.fseeko); U(.ftello); U(.ftrylockfile); U(.funlockfile);
        U(.htonl); U(.htons); U(.isascii); U(.memccpy); U(.mempcpy); U(.memrchr); U(.ntohl); U(.ntohs);
        U(.reallocarray); U(.reallocf); U(.roundeven); U(.roundevenf); U(.roundevenl); U(.stpcpy); U(.stpncpy);
        U(.strlcat); U(.strlcpy); U(.strndup); U(.strnlen); U(.toascii);
    }
    if os == .FreeBSD {
        A(.dunder_strtok_r); A(.memalign); A(.fputc_unlocked); A(.fputs_unlocked); A(.fread_unlocked);
        A(.fwrite_unlocked); A(.getc_unlocked); A(.getchar_unlocked); A(.putc_unlocked); A(.putchar_unlocked);
        U(.dunder_strndup); U(.memccpy_chk); U(.strlen_chk); U(.fmaximum_num); U(.fmaximum_numf);
        U(.fmaximum_numl); U(.fminimum_num); U(.fminimum_numf); U(.fminimum_numl); U(.roundeven); U(.roundevenf);
        U(.roundevenl);
    }
    if a == .nvptx || a == .nvptx64 {
        tli_disable_all_functions(tli);
        A(.nvvm_reflect); A(.malloc); A(.free);
    } else U(.nvvm_reflect);
    if os != .AIX { U(.vec_calloc); U(.vec_malloc); U(.vec_realloc); U(.vec_free); }
    if os == .AIX U(.memrchr);
    // addVectorizableFunctionsFromVecLib(VecLib = NoLibrary): nothing (see the header)
}

// opt: TargetLibraryInfoImpl TLII(ModuleTriple, VecLib); -disable-simplify-libcalls -> disableAllFunctions()
tli_get_baseline :: () -> *Tli_Impl {
    if tli_baseline return tli_baseline;
    impl := New(Tli_Impl);
    for 0..NUM_LIB_FUNCS-1 impl.state[it] = TLI_STANDARD_NAME;   // memset(AvailableArray, -1)
    impl.triple = triple_parse(copy_string(ir.triple));
    tli_initialize(impl, *impl.triple);
    if opts.disable_simplify_libcalls tli_disable_all_functions(impl);
    tli_baseline = impl;
    return impl;
}

// TargetLibraryAnalysis::run(F): TargetLibraryInfo(*BaselineInfoImpl, &F)
tli_for :: (f: Value_Id) -> *Tli {
    p := table_find_pointer(*tli_results, f);
    if p return p.*;
    t := New(Tli);
    t.impl = tli_get_baseline();
    if f != NONE {
        if fn_has_str_attr(f, "no-builtins") {
            for 0..NUM_LIB_FUNCS-1 t.override_unavailable[it] = true;
        } else {
            for attr_set_items(attr_list_fn(glob(f).attrs)) {
                if it.kind != .STRING_ATTR || !begins_with(it.key, "no-builtin-") continue;
                ok, lf := tli_lookup_name(slice(it.key, 11, it.key.count - 11));
                if ok t.override_unavailable[cast(int) lf] = true;
            }
        }
    }
    table_set(*tli_results, f, t);
    return t;
}
// A TargetLibraryInfo without a function (TargetLibraryInfo(Impl) with F = nullopt)
tli_module_only :: () -> *Tli { return tli_for(NONE); }

tli_state :: (t: *Tli, f: Lib_Func) -> u8 {
    if t.override_unavailable[cast(int) f] return TLI_UNAVAILABLE;
    return t.impl.state[cast(int) f];
}
tli_func_has :: (t: *Tli, f: Lib_Func) -> bool { return tli_state(t, f) != TLI_UNAVAILABLE; }
// TargetLibraryInfo::getName: "" when unavailable
tli_func_name :: (t: *Tli, f: Lib_Func) -> string {
    st := tli_state(t, f);
    if st == TLI_UNAVAILABLE return "";
    if st == TLI_STANDARD_NAME return LIB_FUNC_NAMES[cast(int) f];
    return t.impl.custom_names[cast(int) f];
}
tli_standard_name :: (f: Lib_Func) -> string { return LIB_FUNC_NAMES[cast(int) f]; }

// sanitizeFunctionName + getLibFunc(StringRef)
tli_lookup_name :: (name_in: string) -> (bool, Lib_Func) {
    name := name_in;
    if name.count == 0 return false, .NotLibFunc;
    for 0..name.count-1 if name[it] == 0 return false, .NotLibFunc;
    if name[0] == 1 name = slice(name, 1, name.count - 1);   // GlobalValue::dropLLVMManglingEscape
    if name.count == 0 return false, .NotLibFunc;
    if tli_name_index.count == 0 {
        for 1..NUM_LIB_FUNCS-1 table_set(*tli_name_index, LIB_FUNC_NAMES[it], cast(Lib_Func) it);
    }
    found, lf := table_find(*tli_name_index, name);
    if found return true, lf;
    return false, .NotLibFunc;
}

// getSizeTSize(M): the index size of address space 0
tli_size_t_bits :: () -> u32 { return dl_index_size_bits(0); }
tli_size_t_type :: () -> Type_Id { return type_int(tli_size_t_bits()); }
tli_as_size_t :: (v: u64) -> Value_Id { return const_int(tli_size_t_type(), v); }
tli_int_bits :: () -> u32 { return tli_get_baseline().size_of_int; }

// Module::getModuleFlag(Key): the value metadata of the flag, NONE if absent
module_get_flag :: (key: string) -> Md_Id {
    for * nm: ir.named_md {
        if nm.name != "llvm.module.flags" continue;
        for op: nm.ops {
            if op == NONE || ir.mds[op].kind != .TUPLE || ir.mds[op].nops != 3 continue;
            idm := md_op(op, 1);
            if idm != NONE && ir.mds[idm].kind == .STRING && ir.mds[idm].str == key return md_op(op, 2);
        }
    }
    return NONE;
}
// getWCharSize(M): the "wchar_size" module flag, else the triple's default
tli_wchar_size :: () -> u32 {
    m := module_get_flag("wchar_size");
    if m != NONE {
        ok, v := md_const_int_value(m);
        if ok return cast(u32) v;
    }
    return triple_default_wchar_size(*tli_get_baseline().triple);
}

// matchType
tli_match_type :: (at: Func_Arg_Type, ty: Type_Id, int_bits: u32, size_t_bits: u32) -> bool {
    k := type_kind(ty);
    if #complete at == {
        case .Void; return k == .VOID;
        case .Bool; return k == .INT && type_int_width(ty) == 8;
        case .Int16; return k == .INT && type_int_width(ty) == 16;
        case .Int32; return k == .INT && type_int_width(ty) == 32;
        case .Int; return k == .INT && type_int_width(ty) == int_bits;
        case .IntPlus; return k == .INT && type_int_width(ty) >= int_bits;
        case .IntX; return k == .INT;
        case .Long; return k == .INT && type_int_width(ty) >= int_bits;
        case .Int64; return k == .INT && type_int_width(ty) == 64;
        case .LLong; return k == .INT && type_int_width(ty) == 64;
        case .SizeT; #through;
        case .SSizeT; return k == .INT && type_int_width(ty) == size_t_bits;
        case .Flt; return k == .FLOAT;
        case .Dbl; return k == .DOUBLE;
        case .LDbl; return is_fp_type(ty);
        case .Floating; return is_fp_type(ty);
        case .Ptr; return k == .PTR;
        case .Struct; return k == .STRUCT;
        case .Ellip; #through;
        case .Same; #through;
        case .NoFuncArgType;
    }
    fatal("TargetLibraryInfo: invalid function argument type");
    return false;
}

// isValidProtoForSizeReturningNew
tli_valid_proto_size_returning_new :: (ft: Type_Id, f: Lib_Func, sbits: u32) -> bool {
    np := func_nparams(ft);
    is_int :: (t: Type_Id, w: u32) -> bool { return type_kind(t) == .INT && type_int_width(t) == w; }
    if f == {
        case .size_returning_new;
            if np != 1 || !is_int(func_param(ft, 0), sbits) return false;
        case .size_returning_new_hot_cold;
            if np != 2 || !is_int(func_param(ft, 0), sbits) || !is_int(func_param(ft, 1), 8) return false;
        case .size_returning_new_aligned;
            if np != 2 || !is_int(func_param(ft, 0), sbits) || !is_int(func_param(ft, 1), sbits) return false;
        case .size_returning_new_aligned_hot_cold;
            if np != 3 || !is_int(func_param(ft, 0), sbits) || !is_int(func_param(ft, 1), sbits) || !is_int(func_param(ft, 2), 8) return false;
        case; return false;
    }
    sized_ptr := type_literal_struct(.[type_ptr(0), type_int(sbits)], false);
    return func_ret(ft) == sized_ptr;
}

// TargetLibraryInfoImpl::isValidProtoForLibFunc
tli_valid_proto_for :: (ft: Type_Id, f: Lib_Func) -> bool {
    np := func_nparams(ft);
    if f == {
        case .cabs; #through;
        case .cabsf; #through;
        case .cabsl;
            ret := func_ret(ft);
            if !is_fp_type(ret) || np == 0 return false;
            pt := func_param(ft, 0);
            if np == 1 return type_kind(pt) == .ARRAY && type_count(pt) == 2 && type_elem(pt) == ret;
            else if np == 2 return pt == ret && func_param(ft, 1) == ret;
            return false;
        case .sincospi_stret; #through;
        case .sincospif_stret;
            if np != 1 return false;
            ret := func_ret(ft);
            pt := func_param(ft, 0);
            if type_kind(ret) == .STRUCT {
                if ir.types[ret].nsub != 2 return false;
                return type_sub(ret, 0) == pt && type_sub(ret, 1) == pt;
            }
            if type_kind(ret) == .VECTOR {
                if type_count(ret) != 2 return false;
                return type_elem(ret) == pt;
            }
            return false;
        case .size_returning_new; #through;
        case .size_returning_new_hot_cold; #through;
        case .size_returning_new_aligned; #through;
        case .size_returning_new_aligned_hot_cold;
            return tli_valid_proto_size_returning_new(ft, f, tli_size_t_bits());
    }
    int_bits := tli_int_bits();
    size_t_bits := tli_size_t_bits();
    idx: u32 = 0;
    ty := func_ret(ft);
    last_ty := ty;
    have_ty := true;
    off := cast(int) LIB_FUNC_SIG_OFFSET[cast(int) f];
    while true {
        tid := LIB_FUNC_SIG[off + cast(int) idx];
        if tid == .NoFuncArgType break;
        if tid == .Ellip return func_vararg(ft);
        if tid == .Same {
            if !have_ty || ty != last_ty return false;
        } else {
            if !have_ty || !tli_match_type(tid, ty, int_bits, size_t_bits) return false;
            last_ty = ty;
        }
        if idx == np {
            have_ty = false;
            idx += 1;
            continue;
        }
        ty = func_param(ft, idx);
        idx += 1;
    }
    return idx == np + 1 && !func_vararg(ft);
}

// TargetLibraryInfoImpl::getLibFunc(const Function &FDecl, LibFunc &F)
tli_lookup_fn :: (fdecl: Value_Id) -> (bool, Lib_Func) {
    if glob(fdecl).intrinsic return false, .NotLibFunc;
    ok, lf := tli_lookup_name(vname(fdecl));
    if !ok return false, .NotLibFunc;
    return tli_valid_proto_for(glob(fdecl).value_type, lf), lf;
}
// TargetLibraryInfo::getLibFunc(const CallBase &CB, LibFunc &F)
tli_lookup_call :: (call: Value_Id) -> (bool, Lib_Func) {
    if call_is_no_builtin(call) return false, .NotLibFunc;
    f := call_called_function(call);
    if f == NONE return false, .NotLibFunc;
    ok, lf := tli_lookup_fn(f);
    return ok, lf;
}
// getLibFunc(Opcode, Ty, F): frem of float / double
tli_lookup_opcode :: (opc: Opcode, ty: Type_Id) -> (bool, Lib_Func) {
    if opc != .FREM || (type_kind(ty) != .DOUBLE && type_kind(ty) != .FLOAT) return false, .NotLibFunc;
    return true, ifx type_kind(ty) == .DOUBLE then Lib_Func.fmod else .fmodf;
}

// getExtAttrForI32Param / getExtAttrForI32Return: .NONE_ATTR = no attribute
tli_ext_attr_for_i32_param :: (signed := true) -> Attr_Kind {
    b := tli_get_baseline();
    if b.should_ext_i32_param return ifx signed then Attr_Kind.SExt else .ZExt;
    if b.should_sign_ext_i32_param return .SExt;
    return .NONE_ATTR;
}
tli_ext_attr_for_i32_return :: (signed := true) -> Attr_Kind {
    b := tli_get_baseline();
    if b.should_ext_i32_return return ifx signed then Attr_Kind.SExt else .ZExt;
    if b.should_sign_ext_i32_return return .SExt;
    return .NONE_ATTR;
}

// isCallingConvCCompatible(CC, TT, FuncTy)
tli_is_calling_conv_c_compatible :: (cc: u32, fty: Type_Id) -> bool {
    CC_C_ :: 0; CC_ARM_APCS_ :: 66; CC_ARM_AAPCS_ :: 67; CC_ARM_AAPCS_VFP_ :: 68;
    if cc == CC_C_ return true;
    if cc == CC_ARM_APCS_ || cc == CC_ARM_AAPCS_ || cc == CC_ARM_AAPCS_VFP_ {
        if triple_is_ios(*tli_get_baseline().triple) return false;
        r := func_ret(fty);
        if !is_ptr_type(r) && !is_int_type(r) && type_kind(r) != .VOID return false;
        for k: 0..cast(s64) func_nparams(fty) - 1 { p := func_param(fty, cast(u32) k); if !is_ptr_type(p) && !is_int_type(p) return false; }
        return true;
    }
    return false;
}
tli_is_calling_conv_c_compatible_call :: (c: Value_Id) -> bool { return tli_is_calling_conv_c_compatible(inst(c).cc, inst(c).ty2); }
tli_is_calling_conv_c_compatible_fn :: (f: Value_Id) -> bool { return tli_is_calling_conv_c_compatible(glob(f).cc, glob(f).value_type); }

// TargetLibraryInfo::hasOptimizedCodeGen
tli_has_optimized_code_gen :: (t: *Tli, f: Lib_Func) -> bool {
    if tli_state(t, f) == TLI_UNAVAILABLE return false;
    if f == {
        case .acos; #through; case .acosf; #through; case .acosl; #through;
        case .asin; #through; case .asinf; #through; case .asinl; #through;
        case .atan2; #through; case .atan2f; #through; case .atan2l; #through;
        case .atan; #through; case .atanf; #through; case .atanl; #through;
        case .copysign; #through; case .copysignf; #through; case .copysignl; #through;
        case .cos; #through; case .cosf; #through; case .cosl; #through;
        case .cosh; #through; case .coshf; #through; case .coshl; #through;
        case .exp2; #through; case .exp2f; #through; case .exp2l; #through;
        case .exp10; #through; case .exp10f; #through; case .exp10l; #through;
        case .ldexp; #through; case .ldexpf; #through; case .ldexpl; #through;
        case .log2; #through; case .log2f; #through; case .log2l; #through;
        case .memcmp; #through; case .bcmp; #through; case .strcmp; #through;
        case .memcpy; #through; case .memset; #through; case .memmove; #through;
        case .sin; #through; case .sinf; #through; case .sinl; #through;
        case .sinh; #through; case .sinhf; #through; case .sinhl; #through;
        case .sqrt; #through; case .sqrtf; #through; case .sqrtl; #through;
        case .sqrt_finite; #through; case .sqrtf_finite; #through; case .sqrtl_finite; #through;
        case .strcpy; #through; case .stpcpy; #through; case .strlen; #through;
        case .strnlen; #through; case .strstr; #through; case .memchr; #through;
        case .memccpy; #through; case .mempcpy; #through; case .tan; #through;
        case .tanf; #through; case .tanl; #through; case .tanh; #through;
        case .tanhf; #through; case .tanhl;
            return true;
    }
    return false;
}
