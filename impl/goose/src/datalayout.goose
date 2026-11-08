// DataLayout: type sizes and alignments. Port of the parts of llvm/lib/IR/DataLayout.cpp we need.
import std;
import ir;

struct PrimSpec { bits: i64, abi: i64, pref: i64 }
struct PtrSpec { as_: i64, bits: i64, abi: i64, pref: i64, idx: i64 }

var dl_ints: PrimSpec[>..<];
var dl_floats: PrimSpec[>..<];
var dl_vecs: PrimSpec[>..<];
var dl_ptrs: PtrSpec[>..<];
var dl_struct_abi: i64 = 1;
var dl_struct_pref: i64 = 8;
var dl_stack_align: i64 = 0;
var dl_vec_elem_aligned: bool = false;
var dl_prog_as: i64 = 0;      // P<n>: program address space (functions, calls)
var dl_native: i64[>..<];          // "n" legal integer widths
var dl_nonintegral: i64[>..<];     // "ni" address spaces
var dl_big_endian: bool = false;

fn dl_set_spec(xs: PrimSpec[>..<]&, bits: i64, abi: i64, pref: i64) {
    for &s in xs { if s.bits == bits { s.abi = abi; s.pref = pref; return; } }
    xs.push(PrimSpec { bits: bits, abi: abi, pref: pref });
    // keep sorted by bits
    var i = xs.len - 1;
    while i > 0 && xs[i - 1].bits > xs[i].bits {
        let t = xs[i - 1];
        xs[i - 1] = xs[i];
        xs[i] = t;
        i--;
    }
}

fn dl_reset() {
    dl_ints.clear();
    dl_floats.clear();
    dl_vecs.clear();
    dl_ptrs.clear();
    dl_native.clear();
    dl_nonintegral.clear();
    dl_big_endian = false;
    dl_set_spec(dl_ints, 8, 1, 1);
    dl_set_spec(dl_ints, 16, 2, 2);
    dl_set_spec(dl_ints, 32, 4, 4);
    dl_set_spec(dl_ints, 64, 4, 8);
    dl_set_spec(dl_floats, 16, 2, 2);
    dl_set_spec(dl_floats, 32, 4, 4);
    dl_set_spec(dl_floats, 64, 8, 8);
    dl_set_spec(dl_floats, 128, 16, 16);
    dl_ptrs.push(PtrSpec { as_: 0, bits: 64, abi: 8, pref: 8, idx: 64 });
    dl_struct_abi = 1;
    dl_struct_pref = 8;
    dl_prog_as = 0;
}

fn parse_num(s: const u8[:]) -> i64 {
    var v = 0;
    for c in s { if c >= '0' && c <= '9' { v = v * 10 + (c - '0') as i64; } }
    return v;
}

// i-th ':'-separated field of part (after its first character), as a number
fn dl_field(part: const u8[:], idx: i64) -> i64, bool {
    var f = 0;
    var start = 1;
    for i in 1..part.len + 1 {
        if i == part.len || part[i] == ':' {
            if f == idx { return parse_num(part[start..i]), true; }
            f++;
            start = i + 1;
        }
    }
    return 0, false;
}

fn dl_parse(s: const u8[:]) {
    dl_reset();
    var start = 0;
    for i in 0..s.len + 1 {
        if i < s.len && s[i] != '-' { continue; }
        let part = s[start..i];
        start = i + 1;
        if part.len == 0 { continue; }
        let c = part[0];
        let f0, h0 = dl_field(part, 0);
        let f1, h1 = dl_field(part, 1);
        let f2, h2 = dl_field(part, 2);
        let f3, h3 = dl_field(part, 3);
        let f4, h4 = dl_field(part, 4);
        if c == 'i' || c == 'f' || c == 'v' {
            let abi = f1 / 8;
            let pref = if h2 { f2 / 8 } else { abi };
            if c == 'i' { dl_set_spec(dl_ints, f0, abi, pref); }
            else if c == 'f' { dl_set_spec(dl_floats, f0, abi, pref); }
            else { dl_set_spec(dl_vecs, f0, abi, pref); }
        } else if c == 'a' {
            let abi = f1 / 8;
            dl_struct_abi = if abi == 0 { 1 } else { abi };
            dl_struct_pref = if h2 { f2 / 8 } else { dl_struct_abi };
        } else if c == 'p' {
            let as_ = f0;
            let bits = f1;
            let abi = f2 / 8;
            let pref = if h3 { f3 / 8 } else { abi };
            let idx = if h4 { f4 } else { bits };
            var found = false;
            for &p in dl_ptrs { if p.as_ == as_ { p.bits = bits; p.abi = abi; p.pref = pref; p.idx = idx; found = true; } }
            if !found { dl_ptrs.push(PtrSpec { as_: as_, bits: bits, abi: abi, pref: pref, idx: idx }); }
        } else if c == 'P' {
            dl_prog_as = parse_num(part[1..]);
        } else if c == 'n' && part.len > 1 && part[1] == 'i' {
            // ni:AS:AS...
            var st = 3;
            for j in 3..part.len + 1 {
                if j == part.len || part[j] == ':' { if j > st { dl_nonintegral.push(parse_num(part[st..j])); } st = j + 1; }
            }
        } else if c == 'n' {
            var st = 1;
            for j in 1..part.len + 1 {
                if j == part.len || part[j] == ':' { if j > st { dl_native.push(parse_num(part[st..j])); } st = j + 1; }
            }
        } else if c == 'E' {
            dl_big_endian = true;
        } else if c == 'e' {
            dl_big_endian = false;
        } else if c == 'S' {
            dl_stack_align = parse_num(part[1..]) / 8;
        }
    }
}

// DataLayout::isLegalInteger / isNonIntegralAddressSpace
fn dl_is_legal_integer(bits: i64) -> bool { for w in dl_native { if w == bits { return true; } } return false; }
fn dl_is_nonintegral_as(as_: i64) -> bool { for a in dl_nonintegral { if a == as_ { return true; } } return false; }

fn dl_ptr(as_: i64) -> PtrSpec {
    for p in dl_ptrs { if p.as_ == as_ { return p; } }
    return dl_ptrs[0];
}

fn pow2_ceil(x: i64) -> i64 { var p = 1; while p < x { p *= 2; } return p; }
fn align_to(x: i64, a: i64) -> i64 { if a <= 1 { x } else { (x + a - 1) / a * a } }

fn dl_int_align(bits: i64, abi: bool) -> i64 {
    for s in dl_ints { if s.bits >= bits { return if abi { s.abi } else { s.pref }; } }
    let s = dl_ints[dl_ints.len - 1];
    return if abi { s.abi } else { s.pref };
}

// Type.cpp getTargetTypeInfo: the layout type of a target extension type
fn target_layout_type(t: i32) -> i32 {
    let nm = sbytes(types[t].name);
    if nm == "spirv.Image" || nm == "spirv.SignedImage" { return T_PTR; }
    if nm == "spirv.Type" {
        let size = ty_target_int(t, 1);
        let al = ty_target_int(t, 2);
        if size > 0 && al > 0 { return ty_array(ty_int(al), size * 8 / al); }
        return T_I32;
    }
    if nm == "spirv.Padding" || nm == "dx.Padding" { return ty_array(T_I8, ty_target_int(t, 0)); }
    if starts_with(nm, "spirv.") || starts_with(nm, "dx.") || nm == "wasm.funcref" || nm == "wasm.externref" { return T_PTR; }
    if nm == "aarch64.svcount" { return ty_vector(T_I1, 16, true); }
    if nm == "amdgcn.named.barrier" { return ty_vector(T_I32, 4, false); }
    if nm == "llvm.test.vectorelement" { return T_I32; }
    fatal(str("layout of target extension type \"", nm, "\" is not supported"));
    return -1;
}

recursive fn dl_size_bits(t: i32) -> i64 {
    let k = types[t].kind;
    if k == TK_TARGETEXT { return dl_size_bits(target_layout_type(t)); }
    if k == TK_INT { return types[t].n as i64; }
    if k == TK_PTR { return dl_ptr(types[t].n).bits; }
    if k == TK_LABEL { return dl_ptr(0).bits; }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    if k == TK_X86_AMX { return 8192; }
    if k == TK_ARRAY { return types[t].cnt * dl_alloc_size(types[t].a) * 8; }
    if k == TK_FVEC || k == TK_SVEC { return types[t].cnt * dl_size_bits(types[t].a); }
    if k == TK_STRUCT { return dl_struct_size(t) * 8; }
    fatal("size of unsized type requested");
    return 0;
}

recursive fn dl_align(t: i32, abi: bool) -> i64 {
    let k = types[t].kind;
    if k == TK_TARGETEXT { return dl_align(target_layout_type(t), abi); }
    if k == TK_PTR { let p = dl_ptr(types[t].n); return if abi { p.abi } else { p.pref }; }
    if k == TK_LABEL { let p = dl_ptr(0); return if abi { p.abi } else { p.pref }; }
    if k == TK_ARRAY { return dl_align(types[t].a, abi); }
    if k == TK_STRUCT {
        if (types[t].flags & TF_PACKED) != 0 && abi { return 1; }
        let sa = dl_struct_align(t);
        let base = if abi { dl_struct_abi } else { dl_struct_pref };
        return max(base, sa);
    }
    if k == TK_INT { return dl_int_align(types[t].n, abi); }
    if k >= TK_HALF && k <= TK_PPC_FP128 {
        let bits = dl_size_bits(t);
        for s in dl_floats { if s.bits == bits { return if abi { s.abi } else { s.pref }; } }
        return pow2_ceil(bits / 8);
    }
    if k == TK_FVEC || k == TK_SVEC {
        let bits = dl_size_bits(t);
        for s in dl_vecs { if s.bits == bits { return if abi { s.abi } else { s.pref }; } }
        if dl_vec_elem_aligned { return dl_align(types[t].a, abi); }
        return pow2_ceil((bits + 7) / 8);
    }
    if k == TK_X86_AMX { return 64; }
    fatal("alignment of unsized type requested");
    return 1;
}

fn dl_store_size(t: i32) -> i64 { (dl_size_bits(t) + 7) / 8 }
recursive fn dl_alloc_size(t: i32) -> i64 {
    // DataLayout::getTypeAllocSize: arrays in bytes (no overflow through bits)
    if types[t].kind == TK_ARRAY { return types[t].cnt * dl_alloc_size(types[t].a); }
    return align_to(dl_store_size(t), dl_align(t, true));
}

// StructLayout: (size, alignment)
recursive fn dl_struct_layout(t: i32) -> i64, i64 {
    var size = 0;
    var al = 1;
    let packed = (types[t].flags & TF_PACKED) != 0;
    for k in types[t].cnt {
        let et = ints[types[t].a + k];
        let a = if packed { 1 } else { dl_align(et, true) };
        size = align_to(size, a);
        al = max(al, a);
        size += dl_alloc_size(et);
    }
    size = align_to(size, al);
    return size, al;
}
recursive fn dl_struct_size(t: i32) -> i64 { let s, a = dl_struct_layout(t); return s; }
recursive fn dl_struct_align(t: i32) -> i64 { let s, a = dl_struct_layout(t); return a; }
recursive fn dl_struct_offset(t: i32, idx: i64) -> i64 {
    var size = 0;
    let packed = (types[t].flags & TF_PACKED) != 0;
    for k in idx + 1 {
        let et = ints[types[t].a + k];
        let a = if packed { 1 } else { dl_align(et, true) };
        size = align_to(size, a);
        if k == idx { return size; }
        size += dl_alloc_size(et);
    }
    return size;
}

fn log2_exact(a: i64) -> i64 { var k = 0; while (1 << k) < a { k++; } return k; }

// Triple::computeDataLayout for x86 (llvm/lib/TargetParser/TargetDataLayout.cpp: computeX86DataLayout,
// getManglingComponent). Returns "" for other architectures (callers must fail loudly).
fn triple_part(t: const u8[:], idx: i64) -> const u8[:] {
    var f = 0;
    var start = 0;
    for i in 0..t.len + 1 {
        if i == t.len || t[i] == '-' {
            if f == idx { return t[start..i]; }
            f++;
            start = i + 1;
        }
    }
    return "";
}

fn compute_x86_datalayout(t: const u8[:], out: u8[>..]&) -> bool {
    let arch = triple_part(t, 0);
    let is64 = arch == "x86_64" || arch == "amd64";
    let is32 = arch == "i386" || arch == "i486" || arch == "i586" || arch == "i686" || arch == "i786" || arch == "i886" || arch == "i986" || arch == "x86";
    if !is64 && !is32 { return false; }
    // OS / environment are the remaining components (normalization is approximate)
    let os = triple_part(t, 2);
    let env = triple_part(t, 3);
    let darwin = starts_with(os, "darwin") || starts_with(os, "macos") || starts_with(os, "ios") || starts_with(os, "tvos") || starts_with(os, "watchos");
    let windows = starts_with(os, "windows") || starts_with(os, "win32") || starts_with(os, "mingw") || starts_with(os, "cygwin") || starts_with(os, "uefi");
    let iamcu = starts_with(os, "elfiamcu");
    let x32 = starts_with(env, "gnux32");
    let env_elf = ends_with(env, "elf");
    let env_macho = ends_with(env, "macho");
    let msvc = windows && (env.len == 0 || starts_with(env, "msvc")) && !env_elf && !env_macho;
    let macho = darwin || env_macho;
    let coff = windows && !env_elf && !env_macho;
    out.push('e');
    if macho { out.append("-m:o"); }
    else if coff { out.append(if is32 { "-m:x" } else { "-m:w" }); }
    else { out.append("-m:e"); }
    if !is64 || x32 { out.append("-p:32:32"); }
    out.append("-p270:32:32-p271:32:32-p272:64:64");
    if is64 || windows { out.append("-i64:64-i128:128"); }
    else if iamcu { out.append("-i64:32-f64:32"); }
    else { out.append("-i128:128-f64:32:64"); }
    if iamcu { }
    else if is64 || darwin || msvc { out.append("-f80:128"); }
    else { out.append("-f80:32"); }
    if iamcu { out.append("-f128:32"); }
    out.append(if is64 { "-n8:16:32:64" } else { "-n8:16:32" });
    if (!is64 && windows) || iamcu { out.append("-a:0:32-S32"); } else { out.append("-S128"); }
    return true;
}
