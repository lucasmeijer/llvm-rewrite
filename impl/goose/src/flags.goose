// Command-line options of passes (LLVM's cl::opt), the analysis printers' output stream, and the
// value-as-operand text helper the printers use.
import std;
import ir;
import printer;

// ---------------------------------------------------------------------------------------------
// cl::opt flags. opt.goose records every "-name[=value]" it doesn't handle itself; flag_known() decides which
// are accepted (unknown ones fail loudly, as `opt` does with "Unknown command line argument").

struct Flag { name: i32, value: i32 }
var cl_flags: Flag[>..];

// Options passes read. Options that would change output in ways we don't implement are not listed, so they
// fail loudly. Options listed as no-ops change nothing we print (e.g. extra verification).
let KNOWN_FLAGS: const u8[:][] = [
    "adce-remove-loops", "adce-remove-control-flow",
    "verify-dom-info",                                   // no-op: extra verification only
    "simplifycfg-require-and-preserve-domtree",          // read by simplifycfg
    "sroa-skip-mem2reg",                                 // read by sroa
];

fn flag_known(name: const u8[:]) -> bool {
    for k in KNOWN_FLAGS { if k == name { return true; } }
    return false;
}

fn flag_set(name: const u8[:], value: const u8[:]) {
    cl_flags.push(Flag { name: intern(name), value: intern(value) });
}

// cl::opt<bool>: absent -> dflt; "-x" -> true; "-x=true/1/false/0".
fn flag_bool(name: const u8[:], dflt: bool) -> bool {
    var r = dflt;
    for f in cl_flags {
        if sbytes(f.name) != name { continue; }
        let v = sbytes(f.value);
        if v == "" || v == "true" || v == "1" || v == "TRUE" || v == "True" { r = true; }
        else if v == "false" || v == "0" || v == "FALSE" || v == "False" { r = false; }
        else { fatal(str("opt: for the --", name, " option: '", v, "' is invalid value for boolean argument!")); }
    }
    return r;
}

fn flag_int(name: const u8[:], dflt: i64) -> i64 {
    var r = dflt;
    for f in cl_flags {
        if sbytes(f.name) != name { continue; }
        let v, ok = parse_int(sbytes(f.value));
        if !ok { fatal(str("opt: for the --", name, " option: '", sbytes(f.value), "' value invalid for integer argument!")); }
        r = v;
    }
    return r;
}

// ---------------------------------------------------------------------------------------------
// errs(): analysis printers write here; opt flushes it to stderr at exit.

var errbuf: u8[>..];

fn errs(s: const u8[:]) { errbuf.append(s); }
fn errs_int(v: i64) { format(errbuf, v); }
fn errs_u64(v: u64) { format_u64_dec(errbuf, v); }
fn errs_hex(v: u64) {
    if v == 0 { errbuf.push('0'); return; }
    var buf: u8[16] = [0; 16];
    var n = 0;
    var x = v;
    while x > 0 { buf[n] = "0123456789abcdef"[(x & 15) as i64]; x = x >> 4; n++; }
    while n > 0 { n--; errbuf.push(buf[n]); }
}

// ---------------------------------------------------------------------------------------------
// Value::printAsOperand / Instruction::print into errbuf. LLVM builds a ModuleSlotTracker for the function;
// we number the module and the function with the printer's SlotTracker and undo the metadata/attribute-group
// slots the function added, so a later print_module numbers them as if this never happened.

var slots_fn: i32 = -1;
var slots_md_mark: i64 = 0;
var slots_as_mark: i64 = 0;
var slots_module_done: bool = false;

fn slots_begin(fv: i32) {
    if slots_fn == fv { return; }
    if slots_fn >= 0 { slots_end(); }
    ensure_slot_arrays();
    if !slots_module_done {
        mnext = 0;
        process_module(globs[glob_of(fv)].module);
        slots_module_done = true;
    }
    slots_md_mark = md_order.len;
    slots_as_mark = as_order.len;
    process_function(fv);
    slots_fn = fv;
}

fn slots_end() {
    if slots_fn < 0 { return; }
    purge_function();
    while md_order.len > slots_md_mark { mdslot[md_order[md_order.len - 1]] = -1; md_order.resize(md_order.len - 1); }
    while as_order.len > slots_as_mark { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
    slots_fn = -1;
}

// The IR changed: slot numbers must be recomputed before the next printout.
fn slots_invalidate() { slots_end(); }

fn errs_operand(v: i32, fv: i32, with_type: bool) {
    slots_begin(fv);
    let mark = out.len;
    put_operand(v, with_type);
    errbuf.append(out[mark..]);
    out.resize(mark);
}

// Instruction::print (`OS << *I`): the instruction line as the module printer prints it, without the newline.
fn errs_inst(iv: i32, fv: i32) {
    slots_begin(fv);
    let mark = out.len;
    print_inst(iv);
    var end = out.len;
    if end > mark && out[end - 1] == '\n' { end--; }
    errbuf.append(out[mark..end]);
    out.resize(mark);
}
