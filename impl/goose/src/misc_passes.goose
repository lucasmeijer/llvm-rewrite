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
import o2_small;
import jump_table_to_switch;
import called_value_propagation;
import alignment_from_assumptions;
import drop_unnecessary_assumes;
import move_auto_init;
import libcalls_shrinkwrap;
import lcg;

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
let MP_EE_INSTRUMENT = 410;            // arg: 1 = post-inline
let MP_TRANSFORM_WARNING = 411;
let MP_ANNOTATION_REMARKS = 412;
let MP_CORO_ELIDE = 413;
let MP_INJECT_TLI_MAPPINGS = 414;
let MP_ALIGNMENT_FROM_ASSUMPTIONS = 415;
let MP_DROP_UNNECESSARY_ASSUMES = 416;  // arg: 1 = drop-deref
let MP_MOVE_AUTO_INIT = 417;
let MP_LIBCALLS_SHRINKWRAP = 418;
let MP_JUMP_TABLE_TO_SWITCH = 419;
let MP_LOOP_SINK = 420;
// module passes
let MP_FORCEATTRS = 500;
let MP_MEMPROF_REMOVE_ATTRIBUTES = 501;
let MP_RECOMPUTE_GLOBALSAA = 502;
let MP_LOWER_COMMENT_STRING = 503;
let MP_ALLOC_TOKEN = 504;
let MP_ANNOTATION2METADATA = 505;
let MP_CORO_EARLY = 506;
let MP_CORO_CLEANUP = 507;
let MP_OPENMP_OPT = 508;
let MP_CALLED_VALUE_PROPAGATION = 509;
let MP_CG_PROFILE = 510;
let MP_REL_LOOKUP_TABLE_CONVERTER = 511;
// CGSCC passes
let MP_CORO_SPLIT = 550;
let MP_CORO_ANNOTATION_ELIDE = 551;
let MP_OPENMP_OPT_CGSCC = 552;
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
    write_stderr(str("opt: ", msg, "\n"));
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
    if mp_param_name_is(name, "ee-instrument") {
        let ps = mp_params(name, "ee-instrument");
        var a: i32 = 0;
        if ps == "post-inline" { a = 1; }
        else if ps.len > 0 { mp_perr(str("invalid EntryExitInstrumenter pass parameter '", ps, "'")); }
        return MP_EE_INSTRUMENT as i32, a, true;
    }
    if name == "transform-warning" { return MP_TRANSFORM_WARNING as i32, 0, false; }
    if name == "annotation-remarks" { return MP_ANNOTATION_REMARKS as i32, 0, true; }
    if name == "coro-elide" { return MP_CORO_ELIDE as i32, 0, true; }
    if name == "inject-tli-mappings" { return MP_INJECT_TLI_MAPPINGS as i32, 0, false; }
    if name == "alignment-from-assumptions" { return MP_ALIGNMENT_FROM_ASSUMPTIONS as i32, 0, false; }
    if mp_param_name_is(name, "drop-unnecessary-assumes") {
        let ps = mp_params(name, "drop-unnecessary-assumes");
        var a: i32 = 0;
        var st: i64 = 0;
        for j in 0..ps.len + 1 {
            if j < ps.len && ps[j] != ';' { continue; }
            let pn = ps[st..j];
            st = j + 1;
            if pn.len == 0 { continue; }
            if pn == "drop-deref" { a = 1; }
            else { mp_perr(str("invalid DropUnnecessaryAssumes pass parameter '", pn, "'")); }
        }
        return MP_DROP_UNNECESSARY_ASSUMES as i32, a, false;
    }
    if name == "move-auto-init" { return MP_MOVE_AUTO_INIT as i32, 0, false; }
    if name == "libcalls-shrinkwrap" { return MP_LIBCALLS_SHRINKWRAP as i32, 0, false; }
    if name == "jump-table-to-switch" { return MP_JUMP_TABLE_TO_SWITCH as i32, 0, false; }
    if name == "loop-sink" { return MP_LOOP_SINK as i32, 0, false; }
    if name == "callsite-splitting" { return MP_CALLSITE_SPLITTING as i32, 0, false; }
    return -1, 0, false;
}

// A module pass name -> (pass id, arg, required); pass id -1 if not ours.
fn mp_parse_module(name: const u8[:]) -> i32, i32, bool {
    if name == "forceattrs" { return MP_FORCEATTRS as i32, 0, false; }
    if name == "memprof-remove-attributes" { return MP_MEMPROF_REMOVE_ATTRIBUTES as i32, 0, false; }
    if name == "recompute-globalsaa" { return MP_RECOMPUTE_GLOBALSAA as i32, 0, false; }
    if name == "lower-comment-string" { return MP_LOWER_COMMENT_STRING as i32, 0, true; }
    if mp_param_name_is(name, "alloc-token") {
        if name != "alloc-token" { mp_perr("alloc-token pass parameters are not supported yet in the Goose opt"); }
        return MP_ALLOC_TOKEN as i32, 0, true;
    }
    if name == "annotation2metadata" { return MP_ANNOTATION2METADATA as i32, 0, false; }
    if name == "coro-early" { return MP_CORO_EARLY as i32, 0, true; }
    if name == "coro-cleanup" { return MP_CORO_CLEANUP as i32, 0, true; }
    if name == "openmp-opt" { return MP_OPENMP_OPT as i32, 0, false; }
    if name == "called-value-propagation" { return MP_CALLED_VALUE_PROPAGATION as i32, 0, false; }
    if mp_param_name_is(name, "cg-profile") {
        let ps = mp_params(name, "cg-profile");
        if ps.len > 0 && ps != "in-lto-post-link" { mp_perr(str("invalid CGProfile pass parameter '", ps, "'")); }
        return MP_CG_PROFILE as i32, 0, false;
    }
    if name == "rel-lookup-table-converter" { return MP_REL_LOOKUP_TABLE_CONVERTER as i32, 0, false; }
    return -1, 0, false;
}

fn mp_is_ours(p: i64) -> bool { p >= 400 && p < 600 }

// A CGSCC pass name -> (pass id, arg, required); pass id -1 if not ours.
fn mp_parse_cgscc(name: const u8[:]) -> i32, i32, bool {
    if mp_param_name_is(name, "coro-split") {
        if name != "coro-split" && name != "coro-split<>" { mp_perr("coro-split pass parameters are not supported yet in the Goose opt"); }
        return MP_CORO_SPLIT as i32, 0, true;
    }
    if name == "coro-annotation-elide" { return MP_CORO_ANNOTATION_ELIDE as i32, 0, false; }
    if name == "openmp-opt-cgscc" { return MP_OPENMP_OPT_CGSCC as i32, 0, false; }
    return -1, 0, false;
}

fn mp_run_cgscc(p: i64, arg: i32, c: i32) -> u32 {
    match p {
        MP_CORO_SPLIT => { return coro_split_run_scc(c); },
        MP_CORO_ANNOTATION_ELIDE => { return coro_annotation_elide_run_scc(c); },
        MP_OPENMP_OPT_CGSCC => {
            if lcg_scc_size(c) > 0 { openmp_opt_check(globs[glob_of(lcg_fn(lcg_scc_node(c, 0)))].module); }
            return PA_ALL;
        },
        _ => { fatal("internal: unknown misc CGSCC pass id"); return PA_ALL; },
    }
}

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
        MP_EE_INSTRUMENT => "EntryExitInstrumenterPass",
        MP_TRANSFORM_WARNING => "WarnMissedTransformationsPass",
        MP_ANNOTATION_REMARKS => "AnnotationRemarksPass",
        MP_CORO_ELIDE => "CoroElidePass",
        MP_INJECT_TLI_MAPPINGS => "InjectTLIMappings",
        MP_ALIGNMENT_FROM_ASSUMPTIONS => "AlignmentFromAssumptionsPass",
        MP_DROP_UNNECESSARY_ASSUMES => "DropUnnecessaryAssumesPass",
        MP_MOVE_AUTO_INIT => "MoveAutoInitPass",
        MP_LIBCALLS_SHRINKWRAP => "LibCallsShrinkWrapPass",
        MP_JUMP_TABLE_TO_SWITCH => "JumpTableToSwitchPass",
        MP_LOOP_SINK => "LoopSinkPass",
        MP_CALLED_VALUE_PROPAGATION => "CalledValuePropagationPass",
        MP_CG_PROFILE => "CGProfilePass",
        MP_REL_LOOKUP_TABLE_CONVERTER => "RelLookupTableConverterPass",
        MP_FORCEATTRS => "ForceFunctionAttrsPass",
        MP_MEMPROF_REMOVE_ATTRIBUTES => "MemProfRemoveInfo",
        MP_RECOMPUTE_GLOBALSAA => "RecomputeGlobalsAAPass",
        MP_LOWER_COMMENT_STRING => "LowerCommentStringPass",
        MP_ALLOC_TOKEN => "AllocTokenPass",
        MP_ANNOTATION2METADATA => "Annotation2MetadataPass",
        MP_CORO_EARLY => "CoroEarlyPass",
        MP_CORO_CLEANUP => "CoroCleanupPass",
        MP_OPENMP_OPT => "OpenMPOptPass",
        MP_CORO_SPLIT => "CoroSplitPass",
        MP_CORO_ANNOTATION_ELIDE => "CoroAnnotationElidePass",
        MP_OPENMP_OPT_CGSCC => "OpenMPOptCGSCCPass",
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
        MP_EE_INSTRUMENT => { return ee_instrument_run(fv, arg != 0); },
        MP_TRANSFORM_WARNING => { return transform_warning_run(fv); },
        MP_ANNOTATION_REMARKS => { return PA_ALL; },
        MP_CORO_ELIDE => { return coro_elide_run(fv); },
        MP_INJECT_TLI_MAPPINGS => { return PA_ALL; },
        MP_ALIGNMENT_FROM_ASSUMPTIONS => { st_touch(fv); return alignment_from_assumptions_run(fv); },
        MP_DROP_UNNECESSARY_ASSUMES => { st_touch(fv); return drop_unnecessary_assumes_run(fv, arg != 0); },
        MP_MOVE_AUTO_INIT => { st_touch(fv); return move_auto_init_run(fv); },
        MP_LIBCALLS_SHRINKWRAP => { return libcalls_shrinkwrap_run(fv); },
        MP_JUMP_TABLE_TO_SWITCH => { return jump_table_to_switch_run(fv); },
        MP_LOOP_SINK => { return loop_sink_run(fv); },
        _ => { fatal("internal: unknown misc function pass id"); return PA_ALL; },
    }
}

// Returns the module pass's preserved set (PA_ALL = no change).
fn mp_run_module(p: i64, arg: i32, m: i32) -> u32 {
    match p {
        MP_FORCEATTRS => { return PA_ALL; },
        MP_MEMPROF_REMOVE_ATTRIBUTES => { return memprof_remove_info_run(m); },
        MP_RECOMPUTE_GLOBALSAA => { return recompute_globalsaa_run(m); },
        MP_LOWER_COMMENT_STRING => { return lower_comment_string_run(m); },
        MP_ALLOC_TOKEN => { return alloc_token_run(m); },
        MP_ANNOTATION2METADATA => { return PA_ALL; },
        MP_CORO_EARLY => { return coro_early_run(m); },
        MP_CORO_CLEANUP => { return coro_cleanup_run(m); },
        MP_OPENMP_OPT => { openmp_opt_check(m); return PA_ALL; },
        MP_CALLED_VALUE_PROPAGATION => { return called_value_propagation_run(m); },
        MP_CG_PROFILE => { return cg_profile_run(m); },
        MP_REL_LOOKUP_TABLE_CONVERTER => { return rel_lookup_table_converter_run(m); },
        _ => { fatal("internal: unknown misc module pass id"); return PA_ALL; },
    }
}
