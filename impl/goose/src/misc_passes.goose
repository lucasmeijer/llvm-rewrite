// Registration and dispatch of the small passes of L1.scalar-misc / L1.o2-gaps and the other small passes of
// default<O2> (pass ids 400..599). passmgr.goose calls mp_parse_* while parsing a pipeline and mp_run_* for
// these ids, so the pass table there doesn't need a row per pass.
import std;
import ir;
import irutil;
import analyses;
import flags;
import os;
import lower_expect;
import lower_constant_intrinsics;
import sink;
import speculative_execution;
import div_rem_pairs;
import float2int;
import infer_alignment;
import mldst_motion;
import tailcallelim;
import callsite_splitting;
import subtarget;

let MP_LOWER_EXPECT = 400;
let MP_LOWER_CONSTANT_INTRINSICS = 401;
let MP_SINK = 402;
let MP_SPECULATIVE_EXECUTION = 403;    // arg: 1 = only-if-divergent-target
let MP_DIV_REM_PAIRS = 404;
let MP_FLOAT2INT = 405;
let MP_INFER_ALIGNMENT = 406;
let MP_MLDST_MOTION = 407;             // arg: 1 = split-footer-bb
let MP_TAILCALLELIM = 408;
let MP_CALLSITE_SPLITTING = 409;
let MP_NOOP_REQUIRE = 499;             // require<memdep> / invalidate<memdep>: nothing observable to compute

// A pass parameter list `name<a;b>` -> the parameters; `ok` false if the name has no parameter list
fn mp_params(name: const u8[:], base: const u8[:]) -> const u8[:] {
    if name.len <= base.len { return ""; }
    return name[base.len + 1..name.len - 1];
}
fn mp_param_name_is(name: const u8[:], base: const u8[:]) -> bool {
    if !starts_with(name, base) { return false; }
    let rest = name[base.len..];
    if rest.len == 0 { return true; }
    return rest[0] == '<' && rest[rest.len - 1] == '>';
}
fn mp_perr(msg: const u8[:]) {
    write_stderr(str("LLVM ERROR: ", msg, "\n"));
    exit(1);
}

// A function pass name -> (pass id, arg, required); pass id -1 if not ours.
fn mp_parse_function(name: const u8[:]) -> i32, i32, bool {
    if name == "lower-expect" { return MP_LOWER_EXPECT as i32, 0, false; }
    if name == "require<memdep>" || name == "invalidate<memdep>" { return MP_NOOP_REQUIRE as i32, 0, true; }
    if name == "lower-constant-intrinsics" { return MP_LOWER_CONSTANT_INTRINSICS as i32, 0, false; }
    if name == "sink" { return MP_SINK as i32, 0, false; }
    if mp_param_name_is(name, "speculative-execution") {
        let ps = mp_params(name, "speculative-execution");
        var a: i32 = 0;
        if ps == "only-if-divergent-target" { a = 1; }
        else if ps.len > 0 { mp_perr(str("invalid SpeculativeExecutionPass parameter '", ps, "'")); }
        return MP_SPECULATIVE_EXECUTION as i32, a, false;
    }
    if name == "div-rem-pairs" { return MP_DIV_REM_PAIRS as i32, 0, false; }
    if name == "float2int" { return MP_FLOAT2INT as i32, 0, false; }
    if name == "infer-alignment" { return MP_INFER_ALIGNMENT as i32, 0, false; }
    if mp_param_name_is(name, "mldst-motion") {
        let ps = mp_params(name, "mldst-motion");
        var a: i32 = 0;
        var st: i64 = 0;
        for j in 0..ps.len + 1 {
            if j < ps.len && ps[j] != ';' { continue; }
            let pn = ps[st..j];
            st = j + 1;
            if pn.len == 0 { continue; }
            if pn == "split-footer-bb" { a = 1; }
            else if pn == "no-split-footer-bb" { a = 0; }
            else { mp_perr(str("invalid MergedLoadStoreMotion pass parameter '", pn, "'")); }
        }
        return MP_MLDST_MOTION as i32, a, false;
    }
    if name == "tailcallelim" { return MP_TAILCALLELIM as i32, 0, false; }
    if name == "callsite-splitting" { return MP_CALLSITE_SPLITTING as i32, 0, false; }
    return -1, 0, false;
}

// A module pass name -> (pass id, arg, required); pass id -1 if not ours.
fn mp_parse_module(name: const u8[:]) -> i32, i32, bool {
    return -1, 0, false;
}

fn mp_is_ours(p: i64) -> bool { p >= 400 && p < 600 }

fn mp_class_name(p: i64) -> const u8[:] {
    return match p {
        MP_LOWER_EXPECT => "LowerExpectIntrinsicPass",
        MP_LOWER_CONSTANT_INTRINSICS => "LowerConstantIntrinsicsPass",
        MP_SINK => "SinkingPass",
        MP_SPECULATIVE_EXECUTION => "SpeculativeExecutionPass",
        MP_DIV_REM_PAIRS => "DivRemPairsPass",
        MP_FLOAT2INT => "Float2IntPass",
        MP_INFER_ALIGNMENT => "InferAlignmentPass",
        MP_MLDST_MOTION => "MergedLoadStoreMotionPass",
        MP_TAILCALLELIM => "TailCallElimPass",
        MP_CALLSITE_SPLITTING => "CallSiteSplittingPass",
        _ => "Pass",
    };
}

fn mp_run_function(p: i64, arg: i32, fv: i32) -> u32 {
    match p {
        MP_LOWER_EXPECT => { return lower_expect_run(fv); },
        MP_NOOP_REQUIRE => { return PA_ALL; },
        MP_LOWER_CONSTANT_INTRINSICS => { st_touch(fv); return lower_constant_intrinsics_run(fv); },
        MP_SINK => { st_touch(fv); return sink_run(fv); },
        MP_SPECULATIVE_EXECUTION => { st_touch(fv); return speculative_execution_run(fv, arg != 0); },
        MP_DIV_REM_PAIRS => { st_touch(fv); return div_rem_pairs_run(fv); },
        MP_FLOAT2INT => { return float2int_run(fv); },
        MP_INFER_ALIGNMENT => { st_touch(fv); return infer_alignment_run(fv); },
        MP_MLDST_MOTION => { st_touch(fv); return mldst_motion_run(fv, arg != 0); },
        MP_TAILCALLELIM => { st_touch(fv); return tailcallelim_run(fv, true); },
        MP_CALLSITE_SPLITTING => { st_touch(fv); return callsite_splitting_run(fv); },
        _ => { fatal("internal: unknown misc function pass id"); return PA_ALL; },
    }
}

// Returns the module pass's preserved set (PA_ALL = no change).
fn mp_run_module(p: i64, arg: i32, m: i32) -> u32 {
    fatal("internal: unknown misc module pass id");
    return PA_ALL;
}
