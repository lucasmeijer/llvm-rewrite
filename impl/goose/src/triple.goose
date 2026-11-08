// Target triples: port of llvm/lib/TargetParser/Triple.cpp (Triple(Str) parsing: parseArch, parseVendor, parseOS,
// parseEnvironment, parseFormat, getDefaultFormat; Triple::normalize; getOSVersion, getEnvironmentVersion,
// isMacOSXVersionLT, isOSVersionLT, getArchPointerBitWidth, getDefaultWCharSize) and the predicates of
// llvm/include/llvm/TargetParser/Triple.h, plus VersionTuple::tryParse (lib/Support/VersionTuple.cpp) and the
// part of ARM::getCanonicalArchName / parseArchISA / parseArchEndian (ARMTargetParserCommon.cpp) parseARMArch needs.
// Tables (enums, names, parse orders) are generated: gen_triple.goose (tools/gen_triple.py).
//
// Not ported: SubArchType (only the x86/x86_64 arch matters here), parseARMArch's "v6m is thumb" rule
// (ARM::parseArchProfile/parseArchVersion need the ARM arch table), DXIL shader-model version normalization
// (fails loudly), iOS/watchOS version canonicalization (getiOSVersion).
import std;
import gen_triple;

struct VT { maj: i64, min: i64, mic: i64, bld: i64 }

struct Triple {
    arch: i32, vendor: i32, os: i32, env: i32, fmt: i32,
    osv: VT,          // getOSVersion()
    envv: VT,         // getEnvironmentVersion()
}

fn vt_lt(a: VT, b: VT) -> bool {
    if a.maj != b.maj { return a.maj < b.maj; }
    if a.min != b.min { return a.min < b.min; }
    if a.mic != b.mic { return a.mic < b.mic; }
    return a.bld < b.bld;
}

// VersionTuple::tryParse(Name) then withoutBuild(); a parse failure leaves the empty version
fn vt_parse(s: const u8[:]) -> VT {
    var parts: i64[4] = [0; 4];
    var n = 0;
    var i: i64 = 0;
    while true {
        if i >= s.len || s[i] < '0' || s[i] > '9' { return VT { 0, 0, 0, 0 }; }
        var v: i64 = 0;
        while i < s.len && s[i] >= '0' && s[i] <= '9' {
            v = v * 10 + (s[i] - '0');
            if v > 0xFFFFFFFF { return VT { 0, 0, 0, 0 }; }   // parseInt: getAsInteger(10, unsigned) fails
            i++;
        }
        parts[n] = v;
        n++;
        if i == s.len { break; }
        if s[i] != '.' || n == 4 { return VT { 0, 0, 0, 0 }; }
        i++;
    }
    if n == 4 && parts[3] >= 1024 * 1024 { return VT { 0, 0, 0, 0 }; }
    return VT { parts[0], parts[1], parts[2], 0 };
}

// The idx-th '-' separated component (StringRef::split chains); "" past the end
fn triple_component(t: const u8[:], idx: i64) -> const u8[:] {
    var f = 0;
    var start: i64 = 0;
    for i in 0..t.len + 1 {
        if i == t.len || t[i] == '-' {
            if f == idx { return t[start..i]; }
            f++;
            start = i + 1;
        }
    }
    return "";
}
// Everything after the idx-th '-' (getEnvironmentName for idx 3, getOSAndEnvironmentName for 2)
fn triple_rest(t: const u8[:], idx: i64) -> const u8[:] {
    var f = 0;
    for i in 0..t.len {
        if t[i] == '-' {
            f++;
            if f == idx { return t[i + 1..]; }
        }
    }
    return "";
}

fn tp_bpf(s: const u8[:]) -> i32 {
    if s == "bpf" { return TA_bpfel; }   // sys::IsLittleEndianHost (x86-64 host)
    if s == "bpf_be" || s == "bpfeb" { return TA_bpfeb; }
    if s == "bpf_le" || s == "bpfel" { return TA_bpfel; }
    return TA_UnknownArch;
}

// ARM::getCanonicalArchName: "" for an invalid name
fn arm_canonical_arch_name(arch: const u8[:]) -> const u8[:] {
    var offset: i64 = -1;
    var a = arch;
    if starts_with(a, "arm64_32") { offset = 8; }
    else if starts_with(a, "arm64e") { offset = 6; }
    else if starts_with(a, "arm64") { offset = 5; }
    else if starts_with(a, "aarch64_32") { offset = 10; }
    else if starts_with(a, "arm") { offset = 3; }
    else if starts_with(a, "thumb") { offset = 5; }
    else if starts_with(a, "aarch64") {
        offset = 7;
        if find(a, "eb") >= 0 { return ""; }
        if a.len >= offset + 3 && a[offset..offset + 3] == "_be" { offset += 3; }
    }
    if offset >= 0 && a.len >= offset + 2 && a[offset..offset + 2] == "eb" { offset += 2; }
    else if ends_with(a, "eb") { a = a[..a.len - 2]; }
    if offset >= 0 { a = if offset <= a.len { a[offset..] } else { a[a.len..] }; }
    if a.len == 0 { return arch; }
    if offset >= 0 {
        if a.len >= 2 && (a[0] != 'v' || a[1] < '0' || a[1] > '9') { return ""; }
        if find(a, "eb") >= 0 { return ""; }
    }
    return a;
}

// parseARMArch (without the v6-M rule, see the header)
fn tp_arm(s: const u8[:]) -> i32 {
    // parseArchISA: 1 AARCH64, 2 THUMB, 3 ARM
    let isa = if starts_with(s, "aarch64") || starts_with(s, "arm64") { 1 } else if starts_with(s, "thumb") { 2 }
              else if starts_with(s, "arm") { 3 } else { 0 };
    // parseArchEndian: 1 LITTLE, 2 BIG
    var endian = 0;
    if starts_with(s, "armeb") || starts_with(s, "thumbeb") || starts_with(s, "aarch64_be") { endian = 2; }
    else if starts_with(s, "arm") || starts_with(s, "thumb") { endian = if ends_with(s, "eb") { 2 } else { 1 }; }
    else if starts_with(s, "aarch64") { endian = 1; }
    var arch = TA_UnknownArch;
    if endian == 1 { arch = if isa == 3 { TA_arm } else if isa == 2 { TA_thumb } else if isa == 1 { TA_aarch64 } else { TA_UnknownArch }; }
    if endian == 2 { arch = if isa == 3 { TA_armeb } else if isa == 2 { TA_thumbeb } else if isa == 1 { TA_aarch64_be } else { TA_UnknownArch }; }
    let cn = arm_canonical_arch_name(s);
    if cn.len == 0 { return TA_UnknownArch; }
    if isa == 2 && (starts_with(cn, "v2") || starts_with(cn, "v3")) { return TA_UnknownArch; }
    return arch;
}

// Triple::parseArch
fn triple_parse_arch(s: const u8[:]) -> i32 {
    for nm, k in TRIPLE_ARCH_PARSE_NAMES {
        if (TRIPLE_ARCH_PARSE_PREFIX[k] != 0 && starts_with(s, nm)) || s == nm { return TRIPLE_ARCH_PARSE_IDS[k]; }
    }
    if starts_with(s, "arm") || starts_with(s, "thumb") || starts_with(s, "aarch64") { return tp_arm(s); }
    if starts_with(s, "bpf") { return tp_bpf(s); }
    return TA_UnknownArch;
}
fn triple_parse_vendor(s: const u8[:]) -> i32 {
    for nm, k in TRIPLE_VENDOR_PARSE_NAMES { if s == nm { return TRIPLE_VENDOR_PARSE_IDS[k]; } }
    return TV_UnknownVendor;
}
fn triple_parse_os(s: const u8[:]) -> i32 {
    for nm, k in TRIPLE_OS_PARSE_NAMES { if starts_with(s, nm) { return TRIPLE_OS_PARSE_IDS[k]; } }
    return TOS_UnknownOS;
}
fn triple_parse_env(s: const u8[:]) -> i32 {
    for nm, k in TRIPLE_ENV_PARSE_NAMES { if starts_with(s, nm) { return TRIPLE_ENV_PARSE_IDS[k]; } }
    return TENV_UnknownEnvironment;
}
fn triple_parse_format(s: const u8[:]) -> i32 {
    if ends_with(s, "xcoff") { return TOF_XCOFF; }
    if ends_with(s, "coff") { return TOF_COFF; }
    if ends_with(s, "elf") { return TOF_ELF; }
    if ends_with(s, "goff") { return TOF_GOFF; }
    if ends_with(s, "macho") { return TOF_MachO; }
    if ends_with(s, "wasm") { return TOF_Wasm; }
    if ends_with(s, "spirv") { return TOF_SPIRV; }
    return TOF_UnknownObjectFormat;
}

fn triple_is_os_darwin_k(os: i32, vendor: i32) -> bool {
    os == TOS_Darwin || os == TOS_MacOSX || os == TOS_IOS || os == TOS_TvOS || os == TOS_WatchOS ||
        os == TOS_DriverKit || os == TOS_XROS || os == TOS_BridgeOS || (vendor == TV_Apple && os == TOS_Firmware)
}

// getDefaultFormat
fn triple_default_format(arch: i32, vendor: i32, os: i32) -> i32 {
    if arch == TA_UnknownArch || arch == TA_aarch64 || arch == TA_aarch64_32 || arch == TA_arm || arch == TA_thumb ||
       arch == TA_x86 || arch == TA_x86_64 {
        if os == TOS_Win32 || os == TOS_UEFI { return TOF_COFF; }
        return if triple_is_os_darwin_k(os, vendor) { TOF_MachO } else { TOF_ELF };
    }
    if arch == TA_mipsel { return if os == TOS_Win32 { TOF_COFF } else { TOF_ELF }; }
    if arch == TA_ppc64 || arch == TA_ppc {
        if os == TOS_AIX { return TOF_XCOFF; }
        if triple_is_os_darwin_k(os, vendor) { return TOF_MachO; }
        return TOF_ELF;
    }
    if arch == TA_systemz { return if os == TOS_ZOS { TOF_GOFF } else { TOF_ELF }; }
    if arch == TA_wasm32 || arch == TA_wasm64 { return TOF_Wasm; }
    if arch == TA_spirv || arch == TA_spirv32 || arch == TA_spirv64 { return TOF_SPIRV; }
    if arch == TA_dxil { return TOF_DXContainer; }
    return TOF_ELF;
}

// Triple::Triple(Str)
fn triple_parse(t: const u8[:]) -> Triple {
    var r = Triple { TA_UnknownArch, TV_UnknownVendor, TOS_UnknownOS, TENV_UnknownEnvironment, TOF_UnknownObjectFormat,
                     VT { 0, 0, 0, 0 }, VT { 0, 0, 0, 0 } };
    var ncomp = 1;
    for c in t { if c == '-' { ncomp++; } }
    if ncomp > 4 { ncomp = 4; }   // split(Components, '-', MaxSplit 3)
    let c0 = triple_component(t, 0);
    r.arch = triple_parse_arch(c0);
    if ncomp > 1 {
        r.vendor = triple_parse_vendor(triple_component(t, 1));
        if ncomp > 2 {
            r.os = triple_parse_os(triple_component(t, 2));
            if ncomp > 3 {
                let e = triple_rest(t, 3);
                r.env = triple_parse_env(e);
                r.fmt = triple_parse_format(e);
            }
        }
    } else {
        if starts_with(c0, "mipsn32") { r.env = TENV_GNUABIN32; }
        else if starts_with(c0, "mips64") || starts_with(c0, "mipsisa64") { r.env = TENV_GNUABI64; }
        else if starts_with(c0, "mipsisa32") { r.env = TENV_GNU; }
        else if c0 == "mips" || c0 == "mipsel" || c0 == "mipsr6" || c0 == "mipsr6el" { r.env = TENV_GNU; }
    }
    if r.fmt == TOF_UnknownObjectFormat { r.fmt = triple_default_format(r.arch, r.vendor, r.os); }
    // getOSVersion
    var osn = triple_component(t, 2);
    let otn = TRIPLE_OS_NAMES[r.os];
    if starts_with(osn, otn) { osn = osn[otn.len..]; }
    else if r.os == TOS_MacOSX && starts_with(osn, "macos") { osn = osn[5..]; }
    else if starts_with(osn, "visionos") { osn = osn[8..]; }
    r.osv = vt_parse(osn);
    // getEnvironmentVersion (getEnvironmentVersionString)
    var en = triple_rest(t, 3);
    if en != "none" {
        let etn = TRIPLE_ENV_NAMES[r.env];
        if starts_with(en, etn) { en = en[etn.len..]; }
        if find(en, "-") >= 0 && r.fmt != TOF_UnknownObjectFormat {
            let fnm = TRIPLE_OF_NAMES[r.fmt];
            if en.len > fnm.len && en[en.len - fnm.len - 1] == '-' && ends_with(en, fnm) { en = en[..en.len - fnm.len - 1]; }
        }
        r.envv = vt_parse(en);
    }
    return r;
}

// ---------------------------------------------------------------------------------------------
// Triple.h predicates

fn tt_is_macosx(t: Triple) -> bool { t.os == TOS_Darwin || t.os == TOS_MacOSX }
fn tt_is_ios(t: Triple) -> bool { t.os == TOS_IOS || t.os == TOS_TvOS }
fn tt_is_watchos(t: Triple) -> bool { t.os == TOS_WatchOS }
fn tt_is_os_darwin(t: Triple) -> bool { triple_is_os_darwin_k(t.os, t.vendor) }
fn tt_is_linux(t: Triple) -> bool { t.os == TOS_Linux }
fn tt_is_freebsd(t: Triple) -> bool { t.os == TOS_FreeBSD }
fn tt_is_solaris(t: Triple) -> bool { t.os == TOS_Solaris }
fn tt_is_aix(t: Triple) -> bool { t.os == TOS_AIX }
fn tt_is_windows(t: Triple) -> bool { t.os == TOS_Win32 }
fn tt_is_uefi(t: Triple) -> bool { t.os == TOS_UEFI }
fn tt_is_windows_or_uefi(t: Triple) -> bool { tt_is_windows(t) || tt_is_uefi(t) }
fn tt_is_known_windows_msvc(t: Triple) -> bool { tt_is_windows(t) && t.env == TENV_MSVC }
fn tt_is_windows_msvc(t: Triple) -> bool { tt_is_known_windows_msvc(t) || (tt_is_windows(t) && t.env == TENV_UnknownEnvironment) }
fn tt_is_windows_cygwin(t: Triple) -> bool { tt_is_windows(t) && t.env == TENV_Cygnus }
fn tt_is_windows_gnu(t: Triple) -> bool { tt_is_windows(t) && t.env == TENV_GNU }
fn tt_is_windows_itanium(t: Triple) -> bool { tt_is_windows(t) && t.env == TENV_Itanium }
fn tt_is_cygming(t: Triple) -> bool { tt_is_windows_cygwin(t) || tt_is_windows_gnu(t) }
fn tt_is_msvcrt(t: Triple) -> bool { tt_is_windows_msvc(t) || tt_is_windows_gnu(t) || tt_is_windows_itanium(t) }
fn tt_is_gnu_env(t: Triple) -> bool {
    let e = t.env;
    e == TENV_GNU || e == TENV_GNUT64 || e == TENV_GNUABIN32 || e == TENV_GNUABI64 || e == TENV_GNUEABI ||
        e == TENV_GNUEABIT64 || e == TENV_GNUEABIHF || e == TENV_GNUEABIHFT64 || e == TENV_GNUF32 ||
        e == TENV_GNUF64 || e == TENV_GNUSF || e == TENV_GNUX32
}
fn tt_is_musl(t: Triple) -> bool {
    let e = t.env;
    e == TENV_Musl || e == TENV_MuslABIN32 || e == TENV_MuslABI64 || e == TENV_MuslEABI || e == TENV_MuslEABIHF ||
        e == TENV_MuslF32 || e == TENV_MuslSF || e == TENV_MuslX32 || e == TENV_MuslWALI || e == TENV_OpenHOS ||
        t.os == TOS_LiteOS
}
fn tt_is_android(t: Triple) -> bool { t.env == TENV_Android }
fn tt_is_ps(t: Triple) -> bool { t.arch == TA_x86_64 && t.vendor == TV_SCEI && (t.os == TOS_PS4 || t.os == TOS_PS5) }
fn tt_is_x86(t: Triple) -> bool { t.arch == TA_x86 || t.arch == TA_x86_64 }
fn tt_is_nvptx(t: Triple) -> bool { t.arch == TA_nvptx || t.arch == TA_nvptx64 }
fn tt_is_amdgpu(t: Triple) -> bool { t.arch == TA_amdgpu || t.arch == TA_r600 }
fn tt_is_dxil(t: Triple) -> bool { t.arch == TA_dxil }
fn tt_is_elf(t: Triple) -> bool { t.fmt == TOF_ELF }

// getArchPointerBitWidth
fn triple_arch_pointer_bits(a: i32) -> i64 {
    if a == TA_UnknownArch { return 0; }
    if a == TA_avr || a == TA_msp430 { return 16; }
    if a == TA_aarch64_32 || a == TA_amdil || a == TA_arc || a == TA_arm || a == TA_armeb || a == TA_csky ||
       a == TA_dxil || a == TA_hexagon || a == TA_hsail || a == TA_kalimba || a == TA_lanai || a == TA_loongarch32 ||
       a == TA_m68k || a == TA_mips || a == TA_mipsel || a == TA_nvptx || a == TA_ppc || a == TA_ppcle ||
       a == TA_r600 || a == TA_renderscript32 || a == TA_riscv32 || a == TA_riscv32be || a == TA_shave ||
       a == TA_sparc || a == TA_sparcel || a == TA_spir || a == TA_spirv32 || a == TA_tce || a == TA_tcele ||
       a == TA_thumb || a == TA_thumbeb || a == TA_wasm32 || a == TA_x86 || a == TA_xcore || a == TA_xtensa {
        return 32;
    }
    return 64;
}
fn tt_is_arch16(t: Triple) -> bool { triple_arch_pointer_bits(t.arch) == 16 }
fn tt_is_arch32(t: Triple) -> bool { triple_arch_pointer_bits(t.arch) == 32 }
fn tt_is_arch64(t: Triple) -> bool { triple_arch_pointer_bits(t.arch) == 64 }

// isOSVersionLT(Major, Minor, Micro)
fn tt_os_version_lt(t: Triple, maj: i64, min: i64, mic: i64) -> bool {
    if min == 0 { return vt_lt(t.osv, VT { maj, 0, 0, 0 }); }
    if mic == 0 { return vt_lt(t.osv, VT { maj, min, 0, 0 }); }
    return vt_lt(t.osv, VT { maj, min, mic, 0 });
}
// isMacOSXVersionLT
fn tt_macosx_version_lt(t: Triple, maj: i64, min: i64, mic: i64) -> bool {
    if t.os == TOS_MacOSX { return tt_os_version_lt(t, maj, min, mic); }
    if maj == 10 { return tt_os_version_lt(t, min + 4, mic, 0); }
    if maj < 25 { return tt_os_version_lt(t, maj - 11 + 20, min, mic); }
    return tt_os_version_lt(t, maj + 1, min, mic);
}
// isAndroidVersionLT
fn tt_android_version_lt(t: Triple, maj: i64) -> bool {
    if tt_is_arch64(t) && t.envv.maj < 21 { return 21 < maj; }
    return vt_lt(t.envv, VT { maj, 0, 0, 0 });
}
// getDefaultWCharSize
fn tt_default_wchar_size(t: Triple) -> i64 {
    if t.arch == TA_xcore { return 1; }
    if tt_is_windows_or_uefi(t) || tt_is_ps(t) { return 2; }
    if tt_is_aix(t) && tt_is_arch32(t) { return 2; }
    return 4;
}

// ---------------------------------------------------------------------------------------------
// Triple::normalize(Str, CanonicalForm::ANY)

// Components are (start, end) ranges of `buf`; new component texts are appended to buf.
fn triple_normalize(s: const u8[:], out: u8[>..]&) {
    var buf: u8[>..] = [];
    buf.append(s);
    var cs: i64[16] = [0; 16];
    var ce: i64[16] = [0; 16];
    var n: i64 = 0;
    var st: i64 = 0;
    for j in 0..s.len + 1 {
        if j < s.len && s[j] != '-' { continue; }
        if n == 16 { fatal("Triple::normalize: more than 16 components"); }
        cs[n] = st; ce[n] = j; n++;
        st = j + 1;
    }
    fn comp(k: i64) -> const u8[:] { buf[cs[k]..ce[k]] }
    fn set_text(k: i64, txt: const u8[:]) { cs[k] = buf.len; buf.append(txt); ce[k] = buf.len; }
    fn resize(m: i64) { while n < m { cs[n] = 0; ce[n] = 0; n++; } n = m; }
    var is_mingw = false;
    var is_cygwin = false;
    var arch = TA_UnknownArch;
    if n > 0 { arch = triple_parse_arch(comp(0)); }
    var vendor = TV_UnknownVendor;
    if n > 1 { vendor = triple_parse_vendor(comp(1)); }
    var os = TOS_UnknownOS;
    if n > 2 {
        os = triple_parse_os(comp(2));
        is_cygwin = starts_with(comp(2), "cygwin") || starts_with(comp(2), "msys");
        is_mingw = starts_with(comp(2), "mingw");
    }
    var env = TENV_UnknownEnvironment;
    if n > 3 { env = triple_parse_env(comp(3)); }
    var fmt = TOF_UnknownObjectFormat;
    if n > 4 { fmt = triple_parse_format(comp(4)); }
    var found: bool[4] = [arch != TA_UnknownArch, vendor != TV_UnknownVendor, os != TOS_UnknownOS,
                          env != TENV_UnknownEnvironment];
    for pos in 0..4 {
        if found[pos] { continue; }
        var idx: i64 = 0;
        while idx < n {
            if idx < 4 && found[idx] { idx++; continue; }
            var valid = false;
            let c = comp(idx);
            if pos == 0 { arch = triple_parse_arch(c); valid = arch != TA_UnknownArch; }
            else if pos == 1 { vendor = triple_parse_vendor(c); valid = vendor != TV_UnknownVendor; }
            else if pos == 2 {
                os = triple_parse_os(c);
                is_cygwin = starts_with(c, "cygwin") || starts_with(c, "msys");
                is_mingw = starts_with(c, "mingw");
                valid = os != TOS_UnknownOS || is_cygwin || is_mingw;
            } else {
                env = triple_parse_env(c);
                valid = env != TENV_UnknownEnvironment;
                if !valid { fmt = triple_parse_format(c); valid = fmt != TOF_UnknownObjectFormat; }
            }
            if !valid { idx++; continue; }
            if pos < idx {
                // insert left, pushing the existing components to the right
                var cur_s = cs[idx]; var cur_e = ce[idx];
                cs[idx] = 0; ce[idx] = 0;
                var i = pos;
                while cur_e > cur_s {
                    while i < 4 && found[i] { i++; }
                    if i >= n { fatal("Triple::normalize: component moved out of range"); }
                    let ts = cs[i]; let te = ce[i];
                    cs[i] = cur_s; ce[i] = cur_e;
                    cur_s = ts; cur_e = te;
                    i++;
                }
            } else if pos > idx {
                // push right by inserting empty components until the component reaches pos
                while true {
                    var cur_s: i64 = 0; var cur_e: i64 = 0;
                    var i = idx;
                    while i < n {
                        let ts = cs[i]; let te = ce[i];
                        cs[i] = cur_s; ce[i] = cur_e;
                        cur_s = ts; cur_e = te;
                        if cur_e == cur_s { break; }
                        i++;
                        while i < 4 && found[i] { i++; }
                    }
                    if cur_e > cur_s {
                        if n == 16 { fatal("Triple::normalize: more than 16 components"); }
                        cs[n] = cur_s; ce[n] = cur_e; n++;
                    }
                    idx++;
                    while idx < 4 && found[idx] { idx++; }
                    if idx >= pos { break; }
                }
            }
            found[pos] = true;
            break;
        }
    }
    if found[0] && !found[1] && !found[2] && found[3] && n > 2 && comp(1) == "none" && comp(2).len == 0 {
        let ts = cs[1]; let te = ce[1];
        cs[1] = cs[2]; ce[1] = ce[2];
        cs[2] = ts; ce[2] = te;
    }
    for k in 0..n { if ce[k] == cs[k] { set_text(k, "unknown"); } }
    if env == TENV_Android && n > 3 && starts_with(comp(3), "androideabi") {
        var v: u8[>..] = [];
        v.append("android");
        v.append(comp(3)[11..]);
        set_text(3, v);
    }
    if vendor == TV_SUSE && env == TENV_GNUEABI { set_text(3, "gnueabihf"); }
    if os == TOS_Win32 {
        resize(4);
        set_text(2, "windows");
        if env == TENV_UnknownEnvironment {
            if fmt == TOF_UnknownObjectFormat || fmt == TOF_COFF { set_text(3, "msvc"); }
            else { set_text(3, TRIPLE_OF_NAMES[fmt]); }
        }
    } else if is_mingw {
        resize(4);
        set_text(2, "windows");
        set_text(3, "gnu");
    } else if is_cygwin {
        resize(4);
        set_text(2, "windows");
        set_text(3, "cygnus");
    }
    if is_mingw || is_cygwin || (os == TOS_Win32 && env != TENV_UnknownEnvironment) {
        if fmt != TOF_UnknownObjectFormat && fmt != TOF_COFF {
            resize(5);
            set_text(4, TRIPLE_OF_NAMES[fmt]);
        }
    }
    if comp(0) == "dxil" { fatal("Triple::normalize: DXIL triples are not supported"); }
    if n > 2 && comp(2) == "firmware" && comp(1) != "apple" {
        fatal("the firmware target os is only supported for the apple vendor");
    }
    for k in 0..n {
        if k > 0 { out.push('-'); }
        out.append(comp(k));
    }
}
