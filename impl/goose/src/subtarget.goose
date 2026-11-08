// The diagnostics opt prints when it creates the X86 subtarget of a function, i.e. whenever an analysis asks for
// TargetIRAnalysis (TTI) and through it for X86TargetMachine::getSubtargetImpl(F). Ports
// llvm/lib/Target/X86/X86TargetMachine.cpp (getSubtargetImpl: the SubtargetMap key) and
// llvm/lib/MC/MCSubtargetInfo.cpp (InitMCProcessorInfo / getFeatures / ApplyFeatureFlag: "'+x' is not a
// recognized feature for this target (ignoring feature)"), llvm/lib/TargetParser/SubtargetFeature.cpp (Split,
// AddFeature: lower-case, '+' added when there is no flag).
//
// When: AssumptionAnalysis requests TTI, so every pass or printer that needs an AssumptionCache (BasicAA,
// ScalarEvolution, DemandedBits, MemorySSA, SROA, ...) creates the subtarget before it prints anything. The
// subtarget is cached by key in the TargetMachine, so each distinct key warns once per process. A new subtarget
// runs InitMCProcessorInfo twice (the X86GenSubtargetInfo constructor and initializeSubtargetDependencies), so
// every unknown feature is reported twice. The TargetMachine's own subtarget (from -mcpu/-mattr) is created
// once, when opt creates the TargetMachine after parsing the module.
//
// Not ported (fail loudly): unknown processor names (LLVM warns per InitMCProcessorInfo and may then abort with
// "64-bit code requested on a subtarget that doesn't support it"), "+help"/"+cpuhelp".
import std;
import ir;
import flags;
import instinfo;
import gen_x86st;

var st_keys: u8[>..];       // "\n"-separated keys of the subtargets created so far
var st_active = false;      // the module has an x86 target machine

fn st_is_x86_triple(s: const u8[:]) -> bool {
    starts_with(s, "x86_64") || starts_with(s, "i386") || starts_with(s, "i486") || starts_with(s, "i586") ||
        starts_with(s, "i686") || starts_with(s, "x86")
}

fn st_name_in(blob: const u8[:], name: const u8[:]) -> bool {
    if name.len == 0 { return false; }
    var i = 0;
    while i < blob.len {
        // blob is "\nname\nname\n...\n": compare the entry starting at i + 1
        let s = i + 1;
        var e = s;
        while e < blob.len && blob[e] != '\n' { e++; }
        if e - s == name.len && blob[s..e] == name { return true; }
        i = e;
    }
    return false;
}

fn st_check_cpu(cpu: const u8[:]) {
    if cpu.len == 0 { return; }
    if !st_name_in(X86_CPU_NAMES, cpu) {
        fatal(str("X86 subtarget: unrecognized processor '", cpu, "' (LLVM's warnings and abort for it are not ported)"));
    }
}

// MCSubtargetInfo::getFeatures over one feature string: the warnings for unknown features
fn st_warn_features(fs: const u8[:]) {
    var i = 0;
    while i <= fs.len {
        var e = i;
        while e < fs.len && fs[e] != ',' { e++; }
        if e > i {
            var f: u8[>..<] = [];
            let raw = fs[i..e];
            let has_flag = raw[0] == '+' || raw[0] == '-';
            if !has_flag { f.push('+'); }
            for c in raw { if c >= 'A' && c <= 'Z' { f.push(c + 32); } else { f.push(c); } }
            if f[..] == "+help" || f[..] == "+cpuhelp" { fatal("X86 subtarget: +help/+cpuhelp features are not supported"); }
            if !st_name_in(X86_FEATURE_NAMES, f[1..]) {
                errs("'");
                errs(f[..]);
                errs("' is not a recognized feature for this target (ignoring feature)\n");
            }
        }
        i = e + 1;
    }
}

// opt's TargetMachine creation (codegen::createTargetMachineForTriple) for the module's triple
fn st_init_target_machine(m: i32) {
    st_keys.clear();
    let t = modules[m].triple;
    st_active = t >= 0 && st_is_x86_triple(sbytes(t));
    if !st_active { return; }
    st_check_cpu(cl_mcpu[..]);
    st_warn_features(cl_mattr[..]);
}

fn st_fn_str(fv: i32, key: const u8[:]) -> i32 {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return -1; }
    return attrs[a].sval;
}

fn st_is_uint(s: const u8[:]) -> bool {
    // StringRef::getAsInteger(0, unsigned): decimal, 0x hex, 0 octal, 0b binary; whole string
    if s.len == 0 { return false; }
    for c in s { if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == 'x' || c == 'X') { return false; } }
    return true;
}

// X86TargetMachine::getSubtargetImpl(F): creates (and warns about) the subtarget the first time its key is seen
fn st_touch(fv: i32) {
    if !st_active { return; }
    let cpu_a = st_fn_str(fv, "target-cpu");
    let tune_a = st_fn_str(fv, "tune-cpu");
    let fs_a = st_fn_str(fv, "target-features");
    let cpu: const u8[:] = if cpu_a >= 0 { sbytes(cpu_a) } else { cl_mcpu[..] };
    let tune: const u8[:] = if tune_a >= 0 { sbytes(tune_a) } else if cpu == "x86-64" { "generic" } else { cpu };
    let fs: const u8[:] = if fs_a >= 0 { sbytes(fs_a) } else { cl_mattr[..] };
    var key: u8[>..<] = [];
    let pv = st_fn_str(fv, "prefer-vector-width");
    if pv >= 0 && st_is_uint(sbytes(pv)) { key.push('p'); key.append(sbytes(pv)); }
    let mv = st_fn_str(fv, "min-legal-vector-width");
    if mv >= 0 && st_is_uint(sbytes(mv)) { key.push('m'); key.append(sbytes(mv)); }
    key.append(cpu);
    key.push('\x01');
    key.append(tune);
    key.push('\x01');
    let sf = st_fn_str(fv, "use-soft-float");
    if sf >= 0 && sbytes(sf) == "true" { key.append(if fs.len == 0 { "+soft-float" } else { "+soft-float," }); }
    key.append(fs);
    // seen?
    var i = 0;
    while i < st_keys.len {
        var e = i;
        while e < st_keys.len && st_keys[e] != '\n' { e++; }
        if st_keys[i..e] == key[..] { return; }
        i = e + 1;
    }
    st_keys.append(key[..]);
    st_keys.push('\n');
    st_check_cpu(cpu);
    st_check_cpu(tune);
    st_warn_features(fs);
    st_warn_features(fs);
}
