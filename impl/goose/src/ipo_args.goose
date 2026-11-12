// Internalize and DeadArgumentElimination. Ported from llvm/lib/Transforms/IPO/Internalize.cpp,
// llvm/lib/Transforms/IPO/DeadArgumentElimination.cpp, llvm/lib/Support/GlobPattern.cpp (the subset without
// brace expansion), llvm/lib/IR/Function.cpp (Function::Create / copyAttributesFrom / splice, hasAddressTaken)
// and the CallInst::Create / InvokeInst::Create paths that rebuild a call site.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import dinfo;
import flags;
import scev;
import ipoutil;
import ipo_globals;
import ic_calls;
import ic;
import jt;
import parser;
import pm;

fn ia_fail(what: const u8[:]) { fatal(str("IPO: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Function signature rewriting helpers

// Function::Create(Ty, Linkage, AddrSpace): not linked into the module, arguments unnamed
fn ig_new_function(m: i32, fty: i32, linkage: i64, as_: i64) -> i32 {
    let v = new_glob(VK_FUNC, ty_ptr(as_), -1, 0);
    let g = glob_of(v);
    globs[g].module = m;
    globs[g].vty = fty;
    globs[g].addrspace = as_ as i32;
    globs[g].is_decl = 1;
    ig_set_linkage(v, linkage);
    let np = ty_fn_nparams(fty);
    let args_at = ints.len as i32;
    for k in np { ints.push(-1); }
    globs[g].args = args_at;
    globs[g].nargs = np as i32;
    globs[g].symtab = new_symtab();
    for k in np { ints[args_at + k] = new_arg(v, ty_fn_param(fty, k), k); }
    return v;
}
// Function::copyAttributesFrom (GlobalObject: alignment, section; calling convention, attributes, gc,
// personality / prefix / prologue)
fn ig_fn_copy_attributes_from(nf: i32, f: i32) {
    ig_copy_attributes_from(nf, f);
    let d = glob_of(nf);
    let s = glob_of(f);
    globs[d].cc = globs[s].cc;
    globs[d].attrs = globs[s].attrs;
    globs[d].gc = globs[s].gc;
    if globs[s].has_personality != 0 || globs[s].has_prefix != 0 || globs[s].has_prologue != 0 {
        if nops(nf) == 0 { for k in 3 { add_op_slot(nf); } }
        if globs[s].has_personality != 0 { set_op(nf, 0, op(f, 0)); globs[d].has_personality = 1; }
        if globs[s].has_prefix != 0 { set_op(nf, 1, op(f, 1)); globs[d].has_prefix = 1; }
        if globs[s].has_prologue != 0 { set_op(nf, 2, op(f, 2)); globs[d].has_prologue = 1; }
    }
}
// NF->splice(NF->begin(), F): every block moves to NF (BasicBlock::setParent renumbers them; the names move
// to NF's symbol table: ValueSymbolTable::reinsertValue, which keeps a name that is free there)
fn ig_splice_body(nf: i32, f: i32) {
    var named: i32[>..<] = [];
    var names: i32[>..<] = [];
    var b = func_first_block(f);
    while b >= 0 {
        if vals[b].name >= 0 { named.push(b); names.push(vals[b].name); }
        var i = block_first(b);
        while i >= 0 { if vals[i].name >= 0 { named.push(i); names.push(vals[i].name); } i = inst_next(i); }
        b = block_next(b);
    }
    for v in named { set_name(v, ""); }
    let g = glob_of(f);
    let ng = glob_of(nf);
    globs[ng].first_block = globs[g].first_block;
    globs[ng].last_block = globs[g].last_block;
    globs[g].first_block = -1;
    globs[g].last_block = -1;
    globs[g].is_decl = 1;
    globs[ng].is_decl = 0;
    b = func_first_block(nf);
    while b >= 0 { block_set_parent(b, nf); b = block_next(b); }
    for k in named.len { set_name(named[k], sbytes(names[k])); }
    // a blockaddress names the function its block is in (BlockAddress::getFunction)
    var u = first_use(f);
    while u >= 0 {
        let us = uses[u].user;
        if vals[us].kind == VK_BLOCKADDR { const_handle_operand_change(us, f, nf); u = first_use(f); continue; }
        u = use_next(u);
    }
}
// CallInst::Create(FTy, Callee, Args, CB's operand bundles, "", InsertBefore) or InvokeInst::Create(..., Normal,
// Unwind, ...) appended to `at_end`: a fresh call-like instruction without flags, attributes or metadata
fn ig_create_call_like(cb: i32, fty: i32, callee: i32, args: const i32[:], before: i32, at_end: i32) -> i32 {
    let o = iop(cb);
    if o == OP_CALLBR { ia_fail("rewriting a callbr call site"); }
    var opsv: i32[>..<] = [];
    for a in args { opsv.push(a); }
    var pairs: i32[>..<] = [];
    for k in cb_nbundles(cb) {
        let st = cb_bundle_begin(cb, k);
        let n = cb_bundle_count(cb, k);
        pairs.push(cb_bundle_tag(cb, k));
        pairs.push(n as i32);
        for j in n { opsv.push(op(cb, st + j)); }
    }
    if o == OP_INVOKE { opsv.push(invoke_normal_dest(cb)); opsv.push(invoke_unwind_dest(cb)); }
    opsv.push(callee);
    let i = create_inst(o, ty_fn_ret(fty), opsv);
    insts[inst_of(i)].ty2 = fty;
    cb_set_bundles(i, args.len, pairs, 0);
    if before >= 0 { inst_insert_before(i, before); } else { block_append_inst(at_end, i); }
    return i;
}
// copyMetadata(CB, {MD_prof, MD_dbg})
fn ig_copy_prof_dbg(dst: i32, src: i32) {
    let p = md_kind_id("prof");
    let pm = inst_get_md(src, p);
    if pm >= 0 { inst_set_md(dst, p, pm); }
    let d = inst_get_md(src, 0);
    if d >= 0 { inst_set_md(dst, 0, d); }
}
// Function::getAllMetadata + addMetadata on the new function
fn ig_copy_all_md(nf: i32, f: i32) {
    let g = globs[glob_of(f)];
    for k in g.nmd { glob_add_md(nf, md_att[g.md + 2 * k], md_att[g.md + 2 * k + 1]); }
}
// SP->replaceType(SP->getType()->cloneWithCC(DW_CC_nocall))
fn ig_mark_subprogram_nocall(f: i32) {
    let sp = dinfo_func_subprogram(f);
    if sp < 0 || mds[sp].kind as i64 != MK_DI || di_kind(sp) != DIK_SUBPROGRAM { return; }
    let tk = di_field_index(DIK_SUBPROGRAM, "type");
    let ty = md_op(sp, tk);
    if ty < 0 { ia_fail("DW_CC_nocall on a DISubprogram without a type"); }
    var opsv: i32[>..<] = [];
    for k in mds[ty].nops as i64 { opsv.push(md_op(ty, k)); }
    let ck = di_field_index(DIK_SUBROUTINETYPE, "cc");
    opsv[ck] = md_int(3);
    let nt = md_get(MK_DI, DIK_SUBROUTINETYPE as i32, opsv, false);
    if mds[sp].distinct == 0 { ia_fail("replacing the type of a uniqued DISubprogram"); }
    md_ops[mds[sp].ops + tk] = nt;
}
// Instruction::isUsedByMetadata (debug records)
fn ig_used_by_md(v: i32) -> bool { v < val_vam.len && val_vam[v] >= 0 }

// ---------------------------------------------------------------------------------------------
// GlobPattern (GlobPattern.cpp): `*`, `?`, `[...]` with ranges and `^`/`!` negation, `\` escapes

fn gp_match(pat: const u8[:], s: const u8[:]) -> bool {
    var p: i64 = 0;
    var i: i64 = 0;
    var star_p: i64 = -1;
    var star_i: i64 = 0;
    while i < s.len {
        if p < pat.len {
            let c = pat[p];
            if c == '*' { star_p = p; star_i = i; p++; continue; }
            if c == '?' { p++; i++; continue; }
            if c == '[' {
                var q = p + 1;
                var neg = false;
                if q < pat.len && (pat[q] == '^' || pat[q] == '!') { neg = true; q++; }
                var hit = false;
                var first = true;
                while q < pat.len && (first || pat[q] != ']') {
                    first = false;
                    var lo = pat[q];
                    if lo == '\\' && q + 1 < pat.len { q++; lo = pat[q]; }
                    if q + 2 < pat.len && pat[q + 1] == '-' && pat[q + 2] != ']' {
                        let hi = pat[q + 2];
                        if s[i] >= lo && s[i] <= hi { hit = true; }
                        q += 3;
                    } else {
                        if s[i] == lo { hit = true; }
                        q++;
                    }
                }
                if q >= pat.len { ia_fail("an unterminated [ in a glob pattern"); }
                if hit != neg { p = q + 1; i++; continue; }
            } else {
                var lit = c;
                var adv: i64 = 1;
                if c == '\\' && p + 1 < pat.len { lit = pat[p + 1]; adv = 2; }
                if lit == s[i] { p += adv; i++; continue; }
            }
        }
        if star_p >= 0 { p = star_p + 1; star_i++; i = star_i; continue; }
        return false;
    }
    while p < pat.len && pat[p] == '*' { p++; }
    return p == pat.len;
}

// ---------------------------------------------------------------------------------------------
// InternalizePass

var in_patterns: i32[>..<];        // string ids of the -internalize-public-api-list globs
var in_preserve_gv: i32[>..<];     // internalize<preserve-gv=...> names (exact)
var in_has_preserve_param = false;
var in_always: i32[>..<];          // AlwaysPreserved names (string ids)
var in_comdat_size: i32[>..<];     // per comdat id
var in_comdat_ext: bool[>..<];
var in_comdat_seen: bool[>..<];

fn in_must_preserve(v: i32) -> bool {
    if in_has_preserve_param {
        for p in in_preserve_gv { if vals[v].name == p { return true; } }
        return false;
    }
    for p in in_patterns { if gp_match(sbytes(p), val_name(v)) { return true; } }
    return false;
}
fn in_should_preserve(v: i32) -> bool {
    if ig_is_declaration(v) { return true; }
    if gv_linkage(v) == LK_AVAILABLE_EXTERNALLY { return true; }
    if globs[glob_of(v)].dll == 2 { return true; }   // dllexport
    if vals[v].kind == VK_GVAR && globs[glob_of(v)].ext_init != 0 { return true; }
    if gv_has_local_linkage(v) { return false; }
    for a in in_always { if vals[v].name == a { return true; } }
    return in_must_preserve(v);
}
fn in_check_comdat(v: i32) {
    let c = ig_comdat(v);
    if c < 0 { return; }
    while in_comdat_size.len <= (c as i64) { in_comdat_size.push(0); in_comdat_ext.push(false); in_comdat_seen.push(false); }
    in_comdat_seen[c] = true;
    in_comdat_size[c] = in_comdat_size[c] + 1;
    if in_should_preserve(v) { in_comdat_ext[c] = true; }
}
fn in_maybe_internalize(v: i32) -> bool {
    let c = ig_comdat(v);
    if c >= 0 {
        if (c as i64) < in_comdat_ext.len && in_comdat_ext[c] { return false; }
        if vals[v].kind != VK_ALIAS {
            if (c as i64) >= in_comdat_seen.len || !in_comdat_seen[c] { ia_fail("internalize: a comdat missing from the comdat map"); }
            if in_comdat_size[c] == 1 { globs[glob_of(v)].comdat = -1; }
            else { comdats[c].kind = 3; }   // Comdat::NoDeduplicate
        }
        if gv_has_local_linkage(v) { return false; }
    } else {
        if gv_has_local_linkage(v) { return false; }
        if in_should_preserve(v) { return false; }
    }
    ig_set_visibility(v, 0);
    ig_set_linkage(v, LK_INTERNAL);
    return true;
}
fn internalize_run(m: i32) -> bool {
    in_patterns.clear();
    if flag_given("internalize-public-api-file") { ia_fail("-internalize-public-api-file"); }
    for fl in cl_flags {
        if sbytes(fl.name) != "internalize-public-api-list" { continue; }
        let s = sbytes(fl.value);
        var st: i64 = 0;
        for j in 0..s.len + 1 {
            if j < s.len && s[j] != ',' { continue; }
            let pat = s[st..j];
            st = j + 1;
            for c in pat { if c == '{' { ia_fail("brace expansion in a glob pattern"); } }
            in_patterns.push(intern(pat));
        }
    }
    let ts = modules[m].triple;
    let triple = if ts >= 0 { sbytes(ts) } else { "" };
    in_comdat_size.clear();
    in_comdat_ext.clear();
    in_comdat_seen.clear();
    in_always.clear();
    var changed = false;
    var used: i32[>..<] = [];
    ig_collect_used(m, false, used);
    if comdats.len > 0 {
        var f = modules[m].first_func;
        while f >= 0 { in_check_comdat(f); f = globs[glob_of(f)].next; }
        var g = modules[m].first_gvar;
        while g >= 0 { in_check_comdat(g); g = globs[glob_of(g)].next; }
        var a = modules[m].first_alias;
        while a >= 0 { in_check_comdat(a); a = globs[glob_of(a)].next; }
    }
    for u in used { if vals[u].name >= 0 { in_always.push(vals[u].name); } }
    in_always.push(intern("llvm.used"));
    in_always.push(intern("llvm.compiler.used"));
    in_always.push(intern("llvm.global_ctors"));
    in_always.push(intern("llvm.global_dtors"));
    in_always.push(intern("llvm.global.annotations"));
    in_always.push(intern("__stack_chk_fail"));
    if contains_str(triple, "aix") { in_always.push(intern("__ssp_canary_word")); }
    else { in_always.push(intern("__stack_chk_guard")); }
    if starts_with(triple, "nvptx") { in_always.push(intern("__llvm_rpc_client")); }
    if contains_str(triple, "wasm") { ia_fail("internalize for a wasm target"); }
    var f = modules[m].first_func;
    while f >= 0 { if in_maybe_internalize(f) { changed = true; } f = globs[glob_of(f)].next; }
    var g = modules[m].first_gvar;
    while g >= 0 { if in_maybe_internalize(g) { changed = true; } g = globs[glob_of(g)].next; }
    var a = modules[m].first_alias;
    while a >= 0 { if in_maybe_internalize(a) { changed = true; } a = globs[glob_of(a)].next; }
    return changed;
}
fn contains_str(s: const u8[:], t: const u8[:]) -> bool {
    if t.len > s.len { return false; }
    for i in 0..s.len - t.len + 1 { if s[i..i + t.len] == t { return true; } }
    return false;
}

// ---------------------------------------------------------------------------------------------
// DeadArgumentEliminationPass

let DAE_LIVE = 0;
let DAE_MAYBE = 1;
// RetOrArg: (function, index, is-argument)
fn dae_key(f: i32, idx: i64, is_arg: bool) -> u64 { hk2(f, ((idx * 2) + (if is_arg { 1 } else { 0 })) as i32) }
fn dae_key_fn(k: u64) -> i32 { (k >> 32) as! i32 }
var dae_live_set = hm_new();          // LiveValues
var dae_uses_head = hm_new();         // Uses: key -> head of its list in dae_ul_*
var dae_ul_val: u64[>..<];
var dae_ul_next: i64[>..<];
var dae_mlu: u64[>..<];               // MaybeLiveUses vectors (runs)

fn dae_frozen(f: i32) -> bool { vs_has(VS_PASS0, f) }
fn dae_is_live(k: u64) -> bool { dae_frozen(dae_key_fn(k)) || hm_has(dae_live_set, k) }
fn dae_num_ret_vals(f: i32) -> i64 {
    let rt = ty_fn_ret(globs[glob_of(f)].vty);
    if rt == T_VOID { return 0; }
    if ty_kind(rt) == TK_STRUCT || ty_kind(rt) == TK_ARRAY { return ty_count(rt); }
    return 1;
}
fn dae_ret_component_type(f: i32, idx: i64) -> i32 {
    let rt = ty_fn_ret(globs[glob_of(f)].vty);
    if ty_kind(rt) == TK_STRUCT { return ty_field(rt, idx); }
    if ty_kind(rt) == TK_ARRAY { return ty_elem(rt); }
    return rt;
}
fn dae_mark_if_not_live(k: u64) -> i64 {
    if dae_is_live(k) { return DAE_LIVE; }
    dae_mlu.push(k);
    return DAE_MAYBE;
}
// surveyUse(U, MaybeLiveUses, RetValNum); MaybeLiveUses is the top of dae_mlu
recursive fn dae_survey_use(u: i32, ret_val_num: i64) -> i64 {
    let v = uses[u].user;
    if !is_inst(v) { return DAE_LIVE; }
    let o = iop(v);
    if o == OP_RET {
        let f = inst_func(v);
        if ret_val_num != -1 { return dae_mark_if_not_live(dae_key(f, ret_val_num, false)); }
        var result = DAE_MAYBE;
        for ri in dae_num_ret_vals(f) {
            let sub = dae_mark_if_not_live(dae_key(f, ri, false));
            if result != DAE_LIVE { result = sub; }
        }
        return result;
    }
    if o == OP_INSERTVALUE {
        var rvn = ret_val_num;
        let opno = (u - vals[v].ops) as i64;
        if opno != 0 && insts[inst_of(v)].naux > 0 { rvn = ints[insts[inst_of(v)].aux] as i64; }
        var result = DAE_MAYBE;
        var uu = first_use(v);
        while uu >= 0 {
            result = dae_survey_use(uu, rvn);
            if result == DAE_LIVE { break; }
            uu = use_next(uu);
        }
        return result;
    }
    if is_callbase(v) {
        let f = called_function(v);
        if f >= 0 {
            let opno = (u - vals[v].ops) as i64;
            let na = cb_nargs(v);
            // isBundleOperand
            if opno >= na && opno < na + cb_bundle_ops(v) { return DAE_LIVE; }
            if opno >= ty_fn_nparams(globs[glob_of(f)].vty) { return DAE_LIVE; }
            return dae_mark_if_not_live(dae_key(f, opno, true));
        }
    }
    return DAE_LIVE;
}
// surveyUses(V, MaybeLiveUses)
fn dae_survey_uses(v: i32) -> i64 {
    var result = DAE_MAYBE;
    var u = first_use(v);
    while u >= 0 {
        result = dae_survey_use(u, -1);
        if result == DAE_LIVE { break; }
        u = use_next(u);
    }
    return result;
}
// markLive(RA) and propagateLiveness, with an explicit worklist
fn dae_mark_live(k: u64) {
    if dae_is_live(k) { return; }
    hm_put(dae_live_set, k, 1);
    dae_propagate(k);
}
fn dae_propagate(k0: u64) {
    var wl: u64[>..<] = [];
    wl.push(k0);
    while wl.len > 0 {
        let k = wl.pop();
        var e = hm_get(dae_uses_head, k, -1);
        if e < 0 { continue; }
        hm_del(dae_uses_head, k);
        while e >= 0 {
            let t = dae_ul_val[e];
            if !dae_is_live(t) { hm_put(dae_live_set, t, 1); wl.push(t); }
            e = dae_ul_next[e];
        }
    }
}
// markValue(RA, L, MaybeLiveUses = dae_mlu[base..])
fn dae_mark_value(ra: u64, l: i64, uses_v: const u64[:]) {
    if l == DAE_LIVE { dae_mark_live(ra); return; }
    for mu in uses_v {
        if dae_is_live(mu) { dae_mark_live(ra); break; }
        // Uses.emplace(MaybeLiveUse, RA)
        dae_ul_val.push(ra);
        dae_ul_next.push(hm_get(dae_uses_head, mu, -1));
        hm_put(dae_uses_head, mu, dae_ul_val.len - 1);
    }
}
// markFrozen(F)
fn dae_mark_frozen(f: i32) {
    vs_add(VS_PASS0, f);
    for k in func_nargs(f) { dae_propagate(dae_key(f, k, true)); }
    for r in dae_num_ret_vals(f) { dae_propagate(dae_key(f, r, false)); }
}
// BasicBlock::getTerminatingMustTailCall
fn dae_terminating_musttail(bb: i32) -> i32 {
    let ri = block_last(bb);
    if ri < 0 || iop(ri) != OP_RET || ri == block_first(bb) { return -1; }
    var prev = inst_prev(ri);
    if prev < 0 { return -1; }
    if nops(ri) > 0 {
        var rv = op(ri, 0);
        if rv != prev { return -1; }
        if iop(prev) == OP_BITCAST {
            rv = op(prev, 0);
            prev = inst_prev(prev);
            if prev < 0 || rv != prev { return -1; }
        }
    }
    if dae_is_musttail(prev) { return prev; }
    return -1;
}
fn dae_is_musttail(cb: i32) -> bool { iop(cb) == OP_CALL && insts[inst_of(cb)].pred == 2 }
fn dae_has_attr_somewhere(f: i32, kind: i64) -> bool {
    let l = globs[glob_of(f)].attrs;
    for k in alists[l].n { if aset_has(alist_runs[alists[l].at + k], kind) { return true; } }
    return false;
}

// surveyFunction(F)
fn dae_survey_function(f: i32) {
    if !gv_has_local_linkage(f) { dae_mark_frozen(f); return; }
    if dae_has_attr_somewhere(f, AK_InAlloca) || dae_has_attr_somewhere(f, AK_Preallocated) { dae_mark_frozen(f); return; }
    if fn_has(f, 0, AK_Naked) { dae_mark_frozen(f); return; }
    if gv_may_be_derefined(f) { dae_mark_frozen(f); return; }
    let ret_count = dae_num_ret_vals(f);
    var ret_live: i64[>..<] = [];
    for r in ret_count { ret_live.push(DAE_MAYBE); }
    var ru_idx: i64[>..<] = [];     // MaybeLiveRetUses as (index, use) pairs
    var ru_key: u64[>..<] = [];
    var b = func_first_block(f);
    while b >= 0 {
        if dae_terminating_musttail(b) >= 0 { dae_mark_frozen(f); return; }
        b = block_next(b);
    }
    var num_live: i64 = 0;
    let fty = globs[glob_of(f)].vty;
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        let nu = use_next(u);
        if vals[cb].kind == VK_BLOCKADDR { u = nu; continue; }
        if !is_callbase(cb) || (u - vals[cb].ops) as i64 != nops(cb) - 1 || insts[inst_of(cb)].ty2 != fty {
            dae_mark_frozen(f);
            return;
        }
        if dae_is_musttail(cb) { dae_mark_frozen(f); return; }
        if num_live == ret_count { u = nu; continue; }
        var uu = first_use(cb);
        while uu >= 0 {
            let ext = uses[uu].user;
            if is_inst(ext) && iop(ext) == OP_EXTRACTVALUE {
                let idx = ints[insts[inst_of(ext)].aux] as i64;
                if ret_live[idx] != DAE_LIVE {
                    let base = dae_mlu.len;
                    ret_live[idx] = dae_survey_uses(ext);
                    if ret_live[idx] == DAE_LIVE { num_live++; }
                    var j = base;
                    while j < dae_mlu.len { ru_idx.push(idx); ru_key.push(dae_mlu[j]); j++; }
                    dae_mlu.resize(base);
                }
            } else {
                let base = dae_mlu.len;
                if dae_survey_use(uu, -1) == DAE_LIVE {
                    dae_mlu.resize(base);
                    num_live = ret_count;
                    for r in ret_count { ret_live[r] = DAE_LIVE; }
                    break;
                }
                for r in ret_count {
                    if ret_live[r] != DAE_LIVE {
                        var j = base;
                        while j < dae_mlu.len { ru_idx.push(r); ru_key.push(dae_mlu[j]); j++; }
                    }
                }
                dae_mlu.resize(base);
            }
            uu = use_next(uu);
        }
        u = nu;
    }
    var tmp: u64[>..<] = [];
    for r in ret_count {
        tmp.clear();
        for j in ru_idx.len { if ru_idx[j] == r { tmp.push(ru_key[j]); } }
        dae_mark_value(dae_key(f, r, false), ret_live[r], tmp);
    }
    for k in func_nargs(f) {
        var result = DAE_LIVE;
        let base = dae_mlu.len;
        if !ty_fn_vararg(fty) { result = dae_survey_uses(func_arg(f, k)); }
        tmp.clear();
        var j = base;
        while j < dae_mlu.len { tmp.push(dae_mlu[j]); j++; }
        dae_mlu.resize(base);
        dae_mark_value(dae_key(f, k, true), result, tmp);
    }
}

// deleteDeadVarargs(F)
fn dae_delete_dead_varargs(f: i32) -> bool {
    if ig_is_declaration(f) || !gv_has_local_linkage(f) { return false; }
    if ia_has_address_taken(f) { return false; }
    if fn_has(f, 0, AK_Naked) { return false; }
    var b = func_first_block(f);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if iop(i) == OP_CALL {
                if dae_is_musttail(i) { return false; }
                if inst_iid(i) == IID_va_start { return false; }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    let fty = globs[glob_of(f)].vty;
    var params: i32[>..<] = [];
    let num_args = ty_fn_nparams(fty);
    for k in num_args { params.push(ty_fn_param(fty, k)); }
    let nfty = ty_func_of(ty_fn_ret(fty), params, false);
    let m = globs[glob_of(f)].module;
    let nf = ig_new_function(m, nfty, gv_linkage(f), globs[glob_of(f)].addrspace as i64);
    ig_fn_copy_attributes_from(nf, f);
    globs[glob_of(nf)].comdat = globs[glob_of(f)].comdat;
    ig_insert_global_before(nf, f);
    ig_take_name(nf, f);
    var args: i32[>..<] = [];
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        let nu = use_next(u);
        if !is_callbase(cb) { u = nu; continue; }
        args.clear();
        for k in num_args { args.push(cb_arg(cb, k)); }
        var pal = insts[inst_of(cb)].attrs;
        if pal != 0 {
            var sets: i32[>..<] = [];
            sets.push(alist_fn(pal));
            sets.push(alist_ret(pal));
            for k in num_args { sets.push(alist_param(pal, k)); }
            pal = alist_get(sets);
        }
        var ncb: i32 = -1;
        if iop(cb) == OP_INVOKE { ncb = ig_create_call_like(cb, nfty, nf, args, cb, -1); }
        else {
            ncb = ig_create_call_like(cb, nfty, nf, args, cb, -1);
            insts[inst_of(ncb)].pred = insts[inst_of(cb)].pred;
        }
        insts[inst_of(ncb)].cc = insts[inst_of(cb)].cc;
        insts[inst_of(ncb)].attrs = pal;
        ig_copy_prof_dbg(ncb, cb);
        if first_use(cb) >= 0 { rauw(cb, ncb); }
        ig_take_name(ncb, cb);
        inst_erase_from_parent(cb);
        u = nu;
    }
    ig_splice_body(nf, f);
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        let a2 = func_arg(nf, k);
        rauw(a, a2);
        ig_take_name(a2, a);
    }
    ig_copy_all_md(nf, f);
    ig_rauw(f, nf);
    sc_remove_dead_constant_users(nf);
    ig_erase_global(f, false);
    return true;
}
// Function::hasAddressTaken() with the default arguments (IgnoreAssumeLikeCalls = true); a blockaddress is not
// a use
fn ia_has_address_taken(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 {
        let us = uses[u].user;
        let nu = use_next(u);
        if vals[us].kind == VK_BLOCKADDR { u = nu; continue; }
        if !is_inst(us) || !is_callbase(us) {
            let o = opcode_of(us);
            if o == OP_BITCAST || o == OP_ADDRSPACECAST {
                var all = true;
                var w = first_use(us);
                while w >= 0 { let x = uses[w].user; if !(is_inst(x) && ia_is_assume_like(x)) { all = false; break; } w = use_next(w); }
                if all { u = nu; continue; }
            }
            return true;
        }
        if ia_is_assume_like(us) { u = nu; continue; }
        if (u - vals[us].ops) as i64 != nops(us) - 1 || insts[inst_of(us)].ty2 != globs[glob_of(f)].vty { return true; }
        u = nu;
    }
    return false;
}
// IntrinsicInst::isAssumeLikeIntrinsic
fn ia_is_assume_like(i: i32) -> bool {
    if !is_callbase(i) { return false; }
    let id = inst_iid(i);
    return id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe || id == IID_dbg_assign || id == IID_dbg_declare ||
        id == IID_dbg_value || id == IID_dbg_label || id == IID_invariant_start || id == IID_invariant_end ||
        id == IID_lifetime_start || id == IID_lifetime_end || id == IID_experimental_noalias_scope_decl ||
        id == IID_objectsize || id == IID_ptr_annotation || id == IID_var_annotation;
}

// removeDeadStuffFromFunction(F)
fn dae_remove_dead_stuff(f: i32) -> bool {
    if dae_frozen(f) { return false; }
    let fty = globs[glob_of(f)].vty;
    let pal = globs[glob_of(f)].attrs;
    var params: i32[>..<] = [];
    var arg_attrs: i32[>..<] = [];
    var alive: bool[>..<] = [];
    var has_live_returned = false;
    for k in func_nargs(f) {
        let key = dae_key(f, k, true);
        if hm_has(dae_live_set, key) {
            hm_del(dae_live_set, key);
            params.push(ty_fn_param(fty, k));
            alive.push(true);
            arg_attrs.push(alist_param(pal, k));
            if aset_has(alist_param(pal, k), AK_Returned) { has_live_returned = true; }
        } else {
            alive.push(false);
        }
    }
    let ret_ty = ty_fn_ret(fty);
    var nret_ty: i32 = -1;
    let ret_count = dae_num_ret_vals(f);
    var new_ret_idx: i64[>..<] = [];
    for r in ret_count { new_ret_idx.push(-1); }
    var ret_types: i32[>..<] = [];
    if ret_ty == T_VOID || has_live_returned || vs_has(VS_PASS1, f) {
        nret_ty = ret_ty;
    } else {
        for r in ret_count {
            let key = dae_key(f, r, false);
            if hm_has(dae_live_set, key) {
                hm_del(dae_live_set, key);
                ret_types.push(dae_ret_component_type(f, r));
                new_ret_idx[r] = ret_types.len - 1;
            }
        }
        if ret_types.len > 1 {
            if ty_kind(ret_ty) == TK_STRUCT { let at = ints.len as i32;
                for t in ret_types { ints.push(t); }
                nret_ty = ty_struct_run(at, ret_types.len, (types[ret_ty].flags & TF_PACKED) != 0); }
            else { nret_ty = ty_array(ret_types[0], ret_types.len); }
        } else if ret_types.len == 1 {
            nret_ty = ret_types[0];
        } else {
            nret_ty = T_VOID;
        }
    }
    var rattrs = alist_ret(pal);
    if nret_ty == T_VOID { rattrs = ic::aset_remove_incompatible(nret_ty, rattrs, 3); }
    let fn_attrs = aset_without(alist_fn(pal), [AK_AllocSize]);
    var sets: i32[>..<] = [];
    sets.push(fn_attrs);
    sets.push(rattrs);
    for s in arg_attrs { sets.push(s); }
    let new_pal = alist_get(sets);
    let nfty = ty_func_of(nret_ty, params, ty_fn_vararg(fty));
    if nfty == fty { return false; }
    let m = globs[glob_of(f)].module;
    let nf = ig_new_function(m, nfty, gv_linkage(f), globs[glob_of(f)].addrspace as i64);
    ig_fn_copy_attributes_from(nf, f);
    globs[glob_of(nf)].comdat = globs[glob_of(f)].comdat;
    globs[glob_of(nf)].attrs = new_pal;
    ig_insert_global_before(nf, f);
    ig_take_name(nf, f);
    var args: i32[>..<] = [];
    var cattrs: i32[>..<] = [];
    loop {
        // F->user_back(): the head of the use list (blockaddresses are not users)
        var u = first_use(f);
        while u >= 0 && vals[uses[u].user].kind == VK_BLOCKADDR { u = use_next(u); }
        if u < 0 { break; }
        let cb = uses[u].user;
        if !is_callbase(cb) { fatal("internal: deadargelim: a non-call use of a non-frozen function"); }
        let cpal = insts[inst_of(cb)].attrs;
        let crattrs = ic::aset_remove_incompatible(nret_ty, alist_ret(cpal), 3);
        args.clear();
        cattrs.clear();
        var pi: i64 = 0;
        let np = ty_fn_nparams(fty);
        while pi < np {
            if alive[pi] {
                args.push(cb_arg(cb, pi));
                let s = alist_param(cpal, pi);
                if nret_ty != ret_ty && aset_has(s, AK_Returned) { cattrs.push(aset_without(s, [AK_Returned])); }
                else { cattrs.push(s); }
            }
            pi++;
        }
        let na = cb_nargs(cb);
        while pi < na { args.push(cb_arg(cb, pi)); cattrs.push(alist_param(cpal, pi)); pi++; }
        var csets: i32[>..<] = [];
        csets.push(aset_without(alist_fn(cpal), [AK_AllocSize]));
        csets.push(crattrs);
        for s in cattrs { csets.push(s); }
        let new_cpal = alist_get(csets);
        var ncb: i32 = -1;
        if iop(cb) == OP_INVOKE { ncb = ig_create_call_like(cb, nfty, nf, args, -1, inst_parent(cb)); }
        else {
            ncb = ig_create_call_like(cb, nfty, nf, args, cb, -1);
            insts[inst_of(ncb)].pred = insts[inst_of(cb)].pred;
        }
        insts[inst_of(ncb)].cc = insts[inst_of(cb)].cc;
        insts[inst_of(ncb)].attrs = new_cpal;
        ig_copy_prof_dbg(ncb, cb);
        if first_use(cb) >= 0 || ig_used_by_md(cb) {
            if vals[ncb].ty == vals[cb].ty {
                rauw(cb, ncb);
                ig_take_name(ncb, cb);
            } else if vals[ncb].ty == T_VOID {
                rauw(cb, c_poison(vals[cb].ty));
            } else {
                var ip = cb;
                if iop(cb) == OP_INVOKE {
                    let ne = jt_split_edge(inst_parent(ncb), invoke_normal_dest(cb));
                    ip = first_insertion_pt(ne);
                }
                var rv = c_poison(ret_ty);
                for r in ret_count {
                    if new_ret_idx[r] != -1 {
                        var v = ncb;
                        if ret_types.len > 1 { v = dae_extract_value(ncb, new_ret_idx[r], "newret", ip); }
                        rv = dae_insert_value(rv, v, r, "oldret", ip);
                    }
                }
                rauw(cb, rv);
                ig_take_name(ncb, cb);
            }
        }
        inst_erase_from_parent(cb);
    }
    ig_splice_body(nf, f);
    var j: i64 = 0;
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        if alive[k] {
            let a2 = func_arg(nf, j);
            rauw(a, a2);
            ig_take_name(a2, a);
            j++;
        } else {
            rauw(a, c_poison(vals[a].ty));
        }
    }
    if ty_fn_ret(fty) != ty_fn_ret(nfty) {
        var b = func_first_block(nf);
        while b >= 0 {
            let ri = block_terminator(b);
            if ri >= 0 && iop(ri) == OP_RET {
                var rv: i32 = -1;
                if ty_fn_ret(nfty) != T_VOID {
                    let old_ret = op(ri, 0);
                    rv = c_poison(nret_ty);
                    for r in ret_count {
                        if new_ret_idx[r] != -1 {
                            let ev = dae_extract_value(old_ret, r, "oldret", ri);
                            if ret_types.len > 1 { rv = dae_insert_value(rv, ev, new_ret_idx[r], "newret", ri); }
                            else { rv = ev; }
                        }
                    }
                }
                let nr = if rv >= 0 { create_inst(OP_RET, T_VOID, [rv]) } else { create_inst(OP_RET, T_VOID, []) };
                inst_insert_before(nr, ri);
                let dl = inst_get_md(ri, 0);
                if dl >= 0 { inst_set_md(nr, 0, dl); }
                inst_erase_from_parent(ri);
            }
            b = block_next(b);
        }
    }
    ig_copy_all_md(nf, f);
    if nfty != fty && dinfo_func_subprogram(nf) >= 0 { ig_mark_subprogram_nocall(nf); }
    ig_erase_global(f, false);
    return true;
}
// IRBuilder<NoFolder>(InsertPt).CreateExtractValue / CreateInsertValue (the builder takes InsertPt's debug location)
fn dae_extract_value(agg: i32, idx: i64, name: const u8[:], ip: i32) -> i32 {
    let t: i32 = vals[agg].ty;
    let et = if ty_kind(t) == TK_STRUCT { ty_field(t, idx) } else { ty_elem(t) };
    let e = create_inst(OP_EXTRACTVALUE, et, [agg]);
    let at = ints.len as i32;
    ints.push(idx as i32);
    insts[inst_of(e)].aux = at;
    insts[inst_of(e)].naux = 1;
    return dae_builder_insert(e, name, ip);
}
fn dae_insert_value(agg: i32, v: i32, idx: i64, name: const u8[:], ip: i32) -> i32 {
    let e = create_inst(OP_INSERTVALUE, vals[agg].ty, [agg, v]);
    let at = ints.len as i32;
    ints.push(idx as i32);
    insts[inst_of(e)].aux = at;
    insts[inst_of(e)].naux = 1;
    return dae_builder_insert(e, name, ip);
}
fn dae_builder_insert(e: i32, name: const u8[:], ip: i32) -> i32 {
    inst_insert_before(e, ip);
    set_name(e, name);
    let dl = inst_get_md(ip, 0);
    if dl >= 0 { inst_set_md(e, 0, dl); }
    return e;
}

// removeDeadArgumentsFromCallers(F)
fn dae_remove_dead_args_from_callers(f: i32) -> bool {
    if !gv_has_exact_definition(f) { return false; }
    let fty = globs[glob_of(f)].vty;
    if gv_has_local_linkage(f) && !dae_frozen(f) && !ty_fn_vararg(fty) { return false; }
    if fn_has(f, 0, AK_Naked) { return false; }
    if ig_use_empty(f) { return false; }
    var unused: i64[>..<] = [];
    var changed = false;
    let ub: i64[3] = [AK_NoUndef, AK_Dereferenceable, AK_DereferenceableOrNull];
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        let s = alist_param(globs[glob_of(f)].attrs, k);
        let pass_by_value = aset_has(s, AK_ByVal) || aset_has(s, AK_InAlloca) || aset_has(s, AK_Preallocated);
        if !aset_has(s, AK_SwiftError) && first_use(a) < 0 && !pass_by_value {
            if ig_used_by_md(a) { rauw(a, c_poison(vals[a].ty)); changed = true; }
            unused.push(k);
            fn_set_aset(f, 2 + k, aset_without(s, ub));
        }
    }
    if unused.len == 0 { return false; }
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        let nu = use_next(u);
        if !is_inst(cb) || !is_callbase(cb) || (u - vals[cb].ops) as i64 != nops(cb) - 1 || insts[inst_of(cb)].ty2 != fty { u = nu; continue; }
        for k in unused {
            let a = cb_arg(cb, k);
            set_op(cb, k, c_poison(vals[a].ty));
            // CB->removeParamAttrs(ArgNo, UBImplyingAttributes)
            let l = insts[inst_of(cb)].attrs;
            if l != 0 {
                let s = alist_param(l, k);
                let ns = aset_without(s, ub);
                if ns != s {
                    var sets: i32[>..<] = [];
                    for j in alists[l].n as i64 { sets.push(alist_runs[alists[l].at + j]); }
                    while sets.len < k + 3 { sets.push(0); }
                    sets[k + 2] = ns;
                    insts[inst_of(cb)].attrs = alist_get(sets);
                }
            }
            changed = true;
        }
        u = nu;
    }
    return changed;
}

fn deadargelim_run(m: i32) -> bool {
    var changed = false;
    vs_clear(VS_PASS0);
    vs_clear(VS_PASS1);
    hm_clear(dae_live_set);
    hm_clear(dae_uses_head);
    dae_ul_val.clear();
    dae_ul_next.clear();
    dae_mlu.clear();
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if ty_fn_vararg(globs[glob_of(f)].vty) { if dae_delete_dead_varargs(f) { changed = true; } }
        f = nf;
    }
    f = modules[m].first_func;
    while f >= 0 { dae_survey_function(f); f = globs[glob_of(f)].next; }
    f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if dae_remove_dead_stuff(f) { changed = true; }
        f = nf;
    }
    f = modules[m].first_func;
    while f >= 0 { if dae_remove_dead_args_from_callers(f) { changed = true; } f = globs[glob_of(f)].next; }
    return changed;
}
