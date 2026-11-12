// The small passes of default<O2> that never change the IR of a module without a feature our opt doesn't have
// (or that only drop something). Each one checks LLVM's own early exit and fails loudly where the real
// transformation would start:
// - ForceFunctionAttrsPass (llvm/lib/Transforms/IPO/ForceFunctionAttrs.cpp): nothing without -force-attribute /
//   -force-remove-attribute / -forceattrs-csv-path (unknown options to our opt).
// - MemProfRemoveInfo (llvm/lib/Transforms/IPO/MemProfContextDisambiguation.cpp): drops the call-site "memprof"
//   attribute and !memprof / !callsite metadata.
// - RecomputeGlobalsAAPass (llvm/lib/Analysis/GlobalsModRef.cpp): recomputes a cached GlobalsAA result.
// - LowerCommentStringPass (llvm/lib/Transforms/Utils/LowerCommentStringPass.cpp): AIX only.
// - AllocTokenPass (llvm/lib/Transforms/Instrumentation/AllocToken.cpp): sanitize_alloc_token functions and
//   llvm.alloc.token.id calls only.
// - Annotation2MetadataPass / AnnotationRemarksPass (llvm/lib/Transforms/IPO/Annotation2Metadata.cpp,
//   llvm/lib/Transforms/Scalar/AnnotationRemarks.cpp): only with remarks enabled (no -pass-remarks* in our opt).
// - The coroutine passes (llvm/lib/Transforms/Coroutines/CoroEarly.cpp, CoroCleanup.cpp, CoroElide.cpp,
//   CoroSplit.cpp, CoroAnnotationElide.cpp): only with coroutine intrinsics / presplit coroutines.
// - OpenMPOptPass / OpenMPOptCGSCCPass (llvm/lib/Transforms/IPO/OpenMPOpt.cpp): only with the "openmp" module flag.
// - InjectTLIMappings (llvm/lib/Transforms/Utils/InjectTLIMappings.cpp): only with -vector-library (unknown option).
// - WarnMissedTransformationsPass (llvm/lib/Transforms/Scalar/WarnMissedTransforms.cpp): warnings only.
import std;
import os;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import globalsaa;
import lcg;
import loopinfo;
import loop_md;
import clone_function;
import loopsimplify;
import dinfo;
import mem2reg;
import gen_iids;
import gen_attrs;
import ipoutil;
import build_libcalls;
import autoupgrade;
import datalayout;
import simplifycfg;
import bfi;

fn os_module_get_function(m: i32, name: const u8[:]) -> i32 {
    let v = symtab_lookup(modules[m].symtab, intern(name));
    if v >= 0 && is_func(v) { return v; }
    return -1;
}
fn os_declares_any(m: i32, names: const u8[:][:]) -> bool {
    for n in names { if os_module_get_function(m, n) >= 0 { return true; } }
    return false;
}
fn os_not_ported(what: const u8[:]) { fatal(str(what, " is not implemented yet in the Goose opt")); }

// MemProfRemoveInfo::run
fn memprof_remove_info_run(m: i32) -> u32 {
    var changed = false;
    let kmp = md_kind_id("memprof");
    let kcs = md_kind_id("callsite");
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) {
            each_inst(f) { i =>
                if is_callbase(i) {
                    let ii = inst_of(i);
                    let l = insts[ii].attrs;
                    let fs = alist_fn(l);
                    var has = aset_find_str(fs, "memprof") >= 0;
                    let callee = called_function(i);
                    if !has && callee >= 0 { has = aset_find_str(alist_fn(func_attrs(callee)), "memprof") >= 0; }
                    if has {
                        if aset_find_str(fs, "memprof") >= 0 {
                            var xs: i32[>..<] = [];
                            for j in aset_n(fs) {
                                let a = aset_attr(fs, j);
                                if !(attrs[a].kind == 0 && sbytes(attrs[a].skey) == "memprof") { xs.push(a); }
                            }
                            insts[ii].attrs = os_alist_set_fn(l, aset_get(xs));
                        }
                        changed = true;
                    }
                    if inst_get_md(i, kcs) >= 0 {
                        inst_erase_md(i, kmp);
                        inst_erase_md(i, kcs);
                        changed = true;
                    }
                }
            };
        }
        f = globs[glob_of(f)].next;
    }
    return if changed { PA_NONE } else { PA_ALL };
}

// AttributeList with its function attribute set replaced
fn os_alist_set_fn(l: i32, fs: i32) -> i32 {
    var xs: i32[>..] = [];
    xs.push(fs);
    xs.push(alist_ret(l));
    let n = alists[l].n as i64 - 2;
    for j in n { xs.push(alist_param(l, j)); }
    return alist_get(xs);
}

fn recompute_globalsaa_run(m: i32) -> u32 {
    if gm_valid { gm_compute(m); }
    return PA_ALL;
}

fn lower_comment_string_run(m: i32) -> u32 {
    let t = modules[m].triple;
    if t >= 0 && find(sbytes(t), "-aix") >= 0 && !flag_bool("disable-lower-comment-string", false) {
        os_not_ported("lower-comment-string (AIX)");
    }
    return PA_ALL;
}

fn alloc_token_run(m: i32) -> u32 {
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) && !func_has_fn_attr(f, AK_Naked) && globs[glob_of(f)].linkage as i64 != LK_AVAILABLE_EXTERNALLY {
            if func_has_fn_attr(f, AK_SanitizeAllocToken) && !func_has_fn_attr(f, AK_DisableSanitizerInstrumentation) {
                os_not_ported("alloc-token instrumentation (sanitize_alloc_token)");
            }
            each_inst(f) { i => if iop(i) == OP_CALL && inst_iid(i) == IID_alloc_token_id { os_not_ported("alloc-token lowering of llvm.alloc.token.id"); } };
        }
        f = globs[glob_of(f)].next;
    }
    return PA_ALL;
}

// CoroEarlyPass (declaresCoroEarlyIntrinsics; coro_suspend is overloaded and left out)
fn coro_early_run(m: i32) -> u32 {
    if os_declares_any(m, ["llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.retcon.once", "llvm.coro.id.async",
                           "llvm.coro.destroy", "llvm.coro.done", "llvm.coro.end", "llvm.coro.end.async",
                           "llvm.coro.free", "llvm.coro.promise", "llvm.coro.resume"]) {
        os_not_ported("coro-early (lowering coroutine intrinsics)");
    }
    return PA_ALL;
}
// CoroCleanupPass (declaresCoroCleanupIntrinsics)
fn coro_cleanup_run(m: i32) -> u32 {
    if os_declares_any(m, ["llvm.coro.alloc", "llvm.coro.begin", "llvm.coro.subfn.addr", "llvm.coro.free",
                           "llvm.coro.dead", "llvm.coro.id", "llvm.coro.id.retcon", "llvm.coro.id.async",
                           "llvm.coro.id.retcon.once", "llvm.coro.noop", "llvm.coro.async.size.replace",
                           "llvm.coro.async.resume", "llvm.coro.begin.custom.abi"]) {
        os_not_ported("coro-cleanup (lowering coroutine intrinsics)");
    }
    return PA_ALL;
}
// CoroElidePass: declaresIntrinsics(M, {coro_id})
fn coro_elide_run(fv: i32) -> u32 {
    if os_module_get_function(globs[glob_of(fv)].module, "llvm.coro.id") >= 0 { os_not_ported("coro-elide"); }
    return PA_ALL;
}
// CoroSplitPass on an SCC
fn coro_split_run_scc(c: i32) -> u32 {
    if lcg_scc_size(c) == 0 { return PA_ALL; }
    let m = globs[glob_of(lcg_fn(lcg_scc_node(c, 0)))].module;
    if os_module_get_function(m, "llvm.coro.prepare.retcon") >= 0 || os_module_get_function(m, "llvm.coro.prepare.async") >= 0 {
        os_not_ported("coro-split (llvm.coro.prepare.retcon/async)");
    }
    for k in lcg_scc_size(c) {
        if func_has_fn_attr(lcg_fn(lcg_scc_node(c, k)), AK_PresplitCoroutine) { os_not_ported("coro-split (splitting coroutines)"); }
    }
    return PA_ALL;
}
// CoroAnnotationElidePass on an SCC: a "<callee>.noalloc" variant must exist
fn coro_annotation_elide_run_scc(c: i32) -> u32 {
    for k in lcg_scc_size(c) {
        let f = lcg_fn(lcg_scc_node(c, k));
        if os_module_get_function(globs[glob_of(f)].module, str(val_name(f), ".noalloc")) >= 0 {
            os_not_ported("coro-annotation-elide");
        }
    }
    return PA_ALL;
}

// containsOpenMP: the "openmp" module flag
fn openmp_opt_check(m: i32) {
    if tli_module_flag_present(m, "openmp") { os_not_ported("openmp-opt (OpenMP modules)"); }
}
fn tli_module_flag_present(m: i32, key: const u8[:]) -> bool {
    for &nm in named_mds {
        if nm.module != m || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let e = md_ops[nm.ops + i];
            if e < 0 || mds[e].kind != MK_TUPLE || mds[e].nops < 3 { continue; }
            let kk = md_op(e, 1);
            if kk >= 0 && mds[kk].kind == MK_STRING && sbytes(mds[kk].extra) == key { return true; }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// WarnMissedTransformationsPass

fn tw_warn(l: i32, msg: const u8[:]) {
    var b: u8[>..] = [];
    b.append("warning: ");
    let dl = loop_start_loc(l);
    var file: i32 = -1;
    if dl >= 0 { file = di_scope_file(di_slot(dl, "scope")); }
    if file >= 0 {
        let fnm = di_slot(file, "filename");
        if fnm >= 0 { b.append(sbytes(mds[fnm].extra)); }
        format(b, ":", di_int(dl, "line"), ":", di_int(dl, "column"), ": ");
    } else {
        b.append("<unknown>:0:0: ");
    }
    b.append(msg);
    b.push('\n');
    write_stderr(b);
}

fn tw_vectorize_kind_prefix(l: i32) -> const u8[:] {
    let body = lmd_bool(l, "llvm.loop.vectorize.body");
    let epi = lmd_bool(l, "llvm.loop.vectorize.epilogue");
    if body && epi { return "vectorized epilogue "; }
    if body { return "vectorized "; }
    if epi { return "epilogue "; }
    return "";
}

// getOptionalElementCountLoopAttribute: (isScalar, isVector) of the vectorize width (both false without one)
fn tw_width_kind(l: i32) -> bool, bool {
    let wp, w = lmd_optional_int(l, "llvm.loop.vectorize.width");
    if !wp { return false, false; }
    let sp, s = lmd_optional_int(l, "llvm.loop.vectorize.scalable.enable");
    let sc = sp && s != 0;
    return !sc && w == 1, (sc && w != 0) || w > 1;
}

// hasVectorizeTransformation
fn tw_has_vectorize_transformation(l: i32) -> i64 {
    let ep, ev = lmd_optional_bool(l, "llvm.loop.vectorize.enable");
    if ep && !ev { return TM_SUPPRESSED_BY_USER; }
    let wp, w = lmd_optional_int(l, "llvm.loop.vectorize.width");
    let ip, ic = lmd_optional_int(l, "llvm.loop.interleave.count");
    // ElementCount::isScalar: fixed width 1 (a scalable width of 1 is a vector)
    let scal, vec = tw_width_kind(l);
    if ep && ev && wp && scal && ip && ic == 1 { return TM_SUPPRESSED_BY_USER; }
    if lmd_bool(l, "llvm.loop.isvectorized") { return TM_DISABLE; }
    if ep && ev { return TM_FORCED_BY_USER; }
    if wp && scal && ip && ic == 1 { return TM_DISABLE; }
    if vec || (ip && ic > 1) { return TM_ENABLE; }
    if lmd_disable_all_transforms(l) { return TM_DISABLE; }
    return TM_UNSPECIFIED;
}

fn tw_loop(l: i32) {
    let tail = "the optimizer was unable to perform the requested transformation; the transformation might be disabled or specified as part of an unsupported transformation ordering";
    if has_unroll_transformation(l) == TM_FORCED_BY_USER {
        tw_warn(l, str(tw_vectorize_kind_prefix(l), "loop not unrolled: ", tail));
    }
    if has_unroll_and_jam_transformation(l) == TM_FORCED_BY_USER {
        tw_warn(l, str("loop not unroll-and-jammed: ", tail));
    }
    if tw_has_vectorize_transformation(l) == TM_FORCED_BY_USER {
        let wp, w = lmd_optional_int(l, "llvm.loop.vectorize.width");
        let ip, ic = lmd_optional_int(l, "llvm.loop.interleave.count");
        let scal, isvec = tw_width_kind(l);
        if !wp || isvec { tw_warn(l, str("loop not vectorized: ", tail)); }
        else if !(ip && ic == 1) { tw_warn(l, str("loop not interleaved: ", tail)); }
    }
    if lmd_bool(l, "llvm.loop.distribute.enable") {
        tw_warn(l, str("loop not distributed: ", tail));
    }
}

fn transform_warning_run(fv: i32) -> u32 {
    if func_has_fn_attr(fv, AK_OptimizeNone) { return PA_ALL; }
    li_get(fv);
    var k = li_ntop(fv);
    while k > 0 {
        k--;
        var pre: i32[>..<] = [];
        loop_loops_in_preorder(li_top(fv, k), pre);
        for l in pre { tw_loop(l); }
    }
    return PA_ALL;
}

// ---------------------------------------------------------------------------------------------
// EntryExitInstrumenterPass (llvm/lib/Transforms/Utils/EntryExitInstrumenter.cpp)

fn ee_call(f: i32, callee: i32, fty: i32, args: const i32[:], pos: i32, head: bool, dl: i32) -> i32 {
    var ops: i32[>..<] = [];
    for a in args { ops.push(a); }
    ops.push(callee);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), ops);
    insts[inst_of(c)].ty2 = fty;
    inst_insert_at(c, inst_parent(pos), pos, head);
    if dl >= 0 { inst_set_md(c, 0, dl); }
    return c;
}

fn ee_insert_call(f: i32, name: const u8[:], pos: i32, head: bool, dl: i32) {
    let m = globs[glob_of(f)].module;
    let t = modules[m].triple;
    let ts: const u8[:] = if t >= 0 { sbytes(t) } else { "" };
    if name == "mcount" || name == ".mcount" || name == "llvm.arm.gnu.eabi.mcount" || name == "\x01_mcount" ||
       name == "\x01mcount" || name == "__mcount" || name == "_mcount" || name == "__cyg_profile_func_enter_bare" {
        if find(ts, "-aix") >= 0 || starts_with(ts, "riscv") || starts_with(ts, "aarch64") || starts_with(ts, "arm64") ||
           starts_with(ts, "loongarch") || starts_with(ts, "s390x") || starts_with(ts, "systemz") {
            os_not_ported("ee-instrument's mcount on AIX/RISC-V/AArch64/LoongArch/SystemZ");
        }
        let fty = ty_func_of(T_VOID, [], false);
        cur_module = m;
        let callee = module_get_or_insert_function(name, fty, 0);
        ee_call(f, callee, fty, [], pos, head, dl);
        return;
    }
    if name == "__cyg_profile_func_enter" || name == "__cyg_profile_func_exit" {
        let pt = ty_ptr(dl_prog_as);
        let fty = ty_func_of(T_VOID, [pt, pt], false);
        cur_module = m;
        let callee = module_get_or_insert_function(name, fty, 0);
        let ra = au_get_declaration(IID_returnaddress, [pt]);
        let rfty = globs[glob_of(ra)].vty;
        let r = ee_call(f, ra, rfty, [c_int(T_I32, 0)], pos, head, dl);
        // the second call goes before the same iterator, after the first one
        ee_call(f, callee, fty, [f, r], pos, head, dl);
        return;
    }
    write_stderr(str("LLVM ERROR: Unknown instrumentation function: '", name, "'\n"));
    exit(1);
}

fn ee_remove_fn_attr(f: i32, key: const u8[:]) {
    let g = glob_of(f);
    let l = globs[g].attrs;
    let fs = alist_fn(l);
    var xs: i32[>..<] = [];
    for j in aset_n(fs) {
        let a = aset_attr(fs, j);
        if !(attrs[a].kind == 0 && sbytes(attrs[a].skey) == key) { xs.push(a); }
    }
    globs[g].attrs = os_alist_set_fn(l, aset_get(xs));
}

fn ee_instrument_run(f: i32, post_inline: bool) -> u32 {
    if func_has_fn_attr(f, AK_Naked) { return PA_ALL; }
    if globs[glob_of(f)].linkage as i64 == LK_AVAILABLE_EXTERNALLY { return PA_ALL; }
    let ea: const u8[:] = if post_inline { "instrument-function-entry-inlined" } else { "instrument-function-entry" };
    let xa: const u8[:] = if post_inline { "instrument-function-exit-inlined" } else { "instrument-function-exit" };
    let fs = alist_fn(func_attrs(f));
    let eat = aset_find_str(fs, ea);
    let xat = aset_find_str(fs, xa);
    var ef: u8[>..] = [];
    var xf: u8[>..] = [];
    if eat >= 0 && attrs[eat].sval >= 0 { ef.append(sbytes(attrs[eat].sval)); }
    if xat >= 0 && attrs[xat].sval >= 0 { xf.append(sbytes(attrs[xat].sval)); }
    var changed = false;
    let sp = func_get_md(f, 0);
    if ef.len > 0 {
        var dl: i32 = -1;
        if sp >= 0 { dl = di_location_get(di_int(sp, "scopeLine"), 0, sp, -1, false); }
        let entry = func_entry(f);
        var pos = first_non_phi(entry);
        if pos >= 0 && inst_is_eh_pad(pos) { pos = inst_next(pos); }
        if pos < 0 { os_not_ported("ee-instrument at the end of an entry block"); }
        ee_insert_call(f, ef, pos, true, dl);
        changed = true;
        ee_remove_fn_attr(f, ea);
    }
    if xf.len > 0 {
        var bb = func_first_block(f);
        while bb >= 0 {
            var t = block_terminator(bb);
            if t >= 0 && iop(t) == OP_RET {
                // getTerminatingMustTailCall
                var p = inst_prev(t);
                if p >= 0 && iop(p) == OP_BITCAST { p = inst_prev(p); }
                if p >= 0 && iop(p) == OP_CALL && insts[inst_of(p)].pred == 2 { t = p; }
                var dl = inst_get_md(t, 0);
                if dl < 0 && sp >= 0 { dl = di_location_get(0, 0, sp, -1, false); }
                ee_insert_call(f, xf, t, false, dl);
                changed = true;
            }
            bb = block_next(bb);
        }
        ee_remove_fn_attr(f, xa);
    }
    return if changed { PA_CFG } else { PA_ALL };
}

// ---------------------------------------------------------------------------------------------
// Passes that only act with profile data or PIC; the actual transformations are not ported (fail loudly).

// Function::hasProfileData: a function_entry_count / synthetic_function_entry_count
fn os_has_profile_data(f: i32) -> bool {
    let m = func_get_md(f, md_kind_id("prof"));
    if m < 0 || mds[m].nops < 1 { return false; }
    let s = md_op(m, 0);
    if s < 0 || mds[s].kind != MK_STRING { return false; }
    let n = sbytes(mds[s].extra);
    return n == "function_entry_count" || n == "synthetic_function_entry_count";
}

// LoopSinkPass::run: only with profile data and loops
fn loop_sink_run(fv: i32) -> u32 {
    if !os_has_profile_data(fv) { return PA_ALL; }
    li_get(fv);
    if li_ntop(fv) == 0 { return PA_ALL; }
    os_not_ported("loop-sink (functions with profile data)");
    return PA_ALL;
}

// CGProfilePass: only functions with a (non-synthetic) entry count
fn cg_profile_run(m: i32) -> u32 {
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) {
            let has, c = bf_entry_count(f);
            if has { os_not_ported("cg-profile (functions with entry counts)"); }
        }
        f = globs[glob_of(f)].next;
    }
    return PA_ALL;
}

// RelLookupTableConverterPass: shouldBuildRelLookupTables needs a 64-bit PIC target (opt's default relocation
// model is static except for x86-64 Darwin and Windows)
fn rel_lookup_table_converter_run(m: i32) -> u32 {
    let t = modules[m].triple;
    if t < 0 { return PA_ALL; }
    let ts = sbytes(t);
    if !starts_with(ts, "x86_64") { return PA_ALL; }
    if find(ts, "darwin") < 0 && find(ts, "macos") < 0 && find(ts, "windows") < 0 && find(ts, "win32") < 0 { return PA_ALL; }
    var g = modules[m].first_gvar;
    while g >= 0 {
        if nops(g) > 0 && globs[glob_of(g)].is_const != 0 {
            let u = vals[g].first_use;
            if u >= 0 && uses[u].next < 0 && is_inst(uses[u].user) && iop(uses[u].user) == OP_GEP {
                os_not_ported("rel-lookup-table-converter (PIC targets)");
            }
        }
        g = globs[glob_of(g)].next;
    }
    return PA_ALL;
}
