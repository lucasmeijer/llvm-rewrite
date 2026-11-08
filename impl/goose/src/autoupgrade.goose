// Intrinsic auto-upgrade at the end of parsing. Port of the parts of llvm/lib/IR/AutoUpgrade.cpp that the
// corpus needs (UpgradeIntrinsicFunction / upgradeIntrinsicFunction1, UpgradeIntrinsicCall,
// UpgradeCallsToIntrinsic) and of LLParser::validateEndOfModule's intrinsic auto-declaration.
// Unported upgrade families (most llvm.x86.*, arm/aarch64/nvvm/amdgcn) fail loudly.
import std;
import os;
import ir;
import calls;
import intrinsics;
import datalayout;
import dinfo;
import constfold;
import autoupgrade_x86;
import flags;

// ---------------------------------------------------------------------------------------------
// Small IR helpers

// Function::Create(FT, ExternalLinkage, Name, M): appended to the module; the name is uniqued.
fn au_create_function(name: const u8[:], fty: i32) -> i32 {
    let f = new_glob(VK_FUNC, T_PTR, -1, 0);
    let g = glob_of(f);
    globs[g].vty = fty;
    globs[g].symtab = new_symtab();
    let np = ty_fn_nparams(fty);
    let at = ints.len as i32;
    for k in np { ints.push(-1); }
    globs[g].args = at;
    globs[g].nargs = np as i32;
    for k in np { ints[at + k] = new_arg(f, ty_fn_param(fty, k), k); }
    symtab_set_name(modules[cur_module].symtab, f, name, true);
    module_append_global(f);
    func_update_iid(f);
    // Function constructor: intrinsics get their attributes if the signature is valid
    let id = func_iid(f);
    if id != 0 && intr_signature_valid(id, fty) { globs[g].attrs = intr_attributes(id, fty); }
    return f;
}

fn au_rename(f: i32, name: const u8[:]) {
    set_name(f, name);
    func_update_iid(f);
}

// rename(F): F->setName(F->getName() + ".old")
fn au_rename_old(f: i32) {
    var nm: u8[>..] = [];
    nm.append(sbytes(vals[f].name));
    nm.append(".old");
    au_rename(f, nm);
}

fn au_erase_function(f: i32) {
    module_remove_global(f);
    let st = modules[cur_module].symtab;
    if vals[f].name >= 0 { symtab_remove(st, f); }
    vals[f].kind = VK_DEAD;
}

// getOrInsertIntrinsicDeclarationImpl
fn au_get_declaration(id: i64, ov: const i32[:]) -> i32 {
    let fty = intr_get_type(id, ov);
    let name = intr_full_name(id, ov);
    let st = modules[cur_module].symtab;
    let ex = symtab_lookup(st, intern(name));
    if ex >= 0 {
        if vals[ex].kind == VK_FUNC && globs[glob_of(ex)].vty == fty { return ex; }
        var nn: u8[>..] = [];
        nn.append(name);
        nn.append(".invalid");
        au_rename(ex, nn);
    }
    return au_create_function(name, fty);
}

// Intrinsic::remangleIntrinsicFunction: -1 if no change.
fn au_remangle(f: i32) -> i32 {
    let id = func_iid(f);
    let fty = globs[glob_of(f)].vty;
    if !intr_signature_valid(id, fty) { return -1; }
    var ov: i32[>..] = [];
    for t in otys { ov.push(t); }
    let want = intr_full_name(id, ov);
    if sbytes(vals[f].name) == want { return -1; }
    let st = modules[cur_module].symtab;
    var nf: i32 = -1;
    let ex = symtab_lookup(st, intern(want));
    if ex >= 0 {
        if vals[ex].kind == VK_FUNC && globs[glob_of(ex)].vty == fty { nf = ex; }
        else {
            var nn: u8[>..] = [];
            nn.append(want);
            nn.append(".renamed");
            au_rename(ex, nn);
        }
    }
    if nf < 0 { nf = au_get_declaration(id, ov); }
    globs[glob_of(nf)].cc = globs[glob_of(f)].cc;
    return nf;
}

fn au_param_type(f: i32, k: i64) -> i32 { ty_fn_param(globs[glob_of(f)].vty, k) }
fn au_ret_type(f: i32) -> i32 { ty_fn_ret(globs[glob_of(f)].vty) }
fn au_nparams(f: i32) -> i64 { ty_fn_nparams(globs[glob_of(f)].vty) }

// ---------------------------------------------------------------------------------------------
// upgradeIntrinsicFunction1 (subset). Returns (upgraded, NewFn or -1).

fn au_intr_id(name: const u8[:]) -> i64 {
    let id = intr_lookup(name);
    if id == 0 { fatal(str("internal: unknown intrinsic ", name)); }
    return id;
}

fn upgrade_intrinsic_function1(f: i32) -> bool, i32 {
    if vals[f].name < 0 { return false, -1; }
    let full = sbytes(vals[f].name);
    if !starts_with(full, "llvm.") || full.len == 5 { return false, -1; }
    var nmb: u8[>..] = [];
    nmb.append(full[5..]);
    let name: const u8[:] = nmb;
    let np = au_nparams(f);
    let c = name[0];
    if c == 'c' && np == 1 {
        if starts_with(name, "convert.") {
            // convertIntrinsicValidType: to.fp16 (fptrunc + bitcast) / from.fp16 (bitcast + fpext)
            let pt = au_param_type(f, 0);
            let r = au_ret_type(f);
            let hb = ty_bits(ty_scalar(r));
            if starts_with(name[8..], "to.fp16") && ty_is_fp(pt) && !ty_is_vector(pt) && ty_is_int(r) && ty_bits(r) == 16 { return true, -1; }
            if starts_with(name[8..], "from.fp16") && ty_is_int(pt) && ty_bits(pt) == 16 && ty_is_fp(r) && !ty_is_vector(r) && types[r].kind != TK_HALF { return true, -1; }
        }
        var id: i64 = 0;
        if starts_with(name, "ctlz.") { id = au_intr_id("llvm.ctlz"); }
        else if starts_with(name, "cttz.") { id = au_intr_id("llvm.cttz"); }
        if id != 0 {
            au_rename_old(f);
            let t = au_param_type(f, 0);
            return true, au_get_declaration(id, [t]);
        }
    }
    if c == 'c' && np == 2 && name == "coro.end" {
        au_rename_old(f);
        return true, au_get_declaration(au_intr_id("llvm.coro.end"), []);
    }
    if c == 'd' && starts_with(name, "dbg.") {
        let r = name[4..];
        if r == "addr" || r == "value" || r == "assign" || r == "declare" || r == "label" { return true, -1; }
    }
    if c == 'e' && starts_with(name, "experimental.vector.") {
        let rest = name[20..];
        if starts_with(rest, "extract.") && !starts_with(rest, "extract.last.active.") || starts_with(rest, "insert.") ||
           starts_with(rest, "reverse.") || starts_with(rest, "interleave2.") || starts_with(rest, "deinterleave2.") ||
           starts_with(rest, "partial.reduce.add") || starts_with(rest, "reduce.") || starts_with(rest, "splice") {
            fatal("llvm.experimental.vector.* upgrade is not supported yet");
        }
    }
    if c == 'e' && starts_with(name, "experimental.stepvector.") {
        au_rename_old(f);
        let r = au_ret_type(f);
        return true, au_get_declaration(au_intr_id("llvm.stepvector"), [r]);
    }
    if c == 'f' && starts_with(name, "flt.rounds") {
        au_rename_old(f);
        return true, au_get_declaration(au_intr_id("llvm.get.rounding"), []);
    }
    if c == 'i' && starts_with(name, "invariant.group.barrier") {
        let t = au_param_type(f, 0);
        au_rename_old(f);
        return true, au_get_declaration(au_intr_id("llvm.launder.invariant.group"), [t]);
    }
    if c == 'l' {
        let is_start = starts_with(name, "lifetime.start");
        let is_end = !is_start && starts_with(name, "lifetime.end");
        if is_start || is_end {
            let tail = if is_start { name[14..] } else { name[12..] };
            if np == 2 {
                let id = au_intr_id(if is_start { "llvm.lifetime.start" } else { "llvm.lifetime.end" });
                au_rename_old(f);
                let t = au_param_type(f, 1);
                return true, au_get_declaration(id, [t]);
            } else if np == 1 && tail == ".i64" {
                return true, -1;
            }
        }
    }
    if c == 'm' {
        var mid: i64 = 0;
        if starts_with(name, "memcpy.") { mid = au_intr_id("llvm.memcpy"); }
        else if starts_with(name, "memmove.") { mid = au_intr_id("llvm.memmove"); }
        if mid != 0 && np == 5 {
            au_rename_old(f);
            let a = au_param_type(f, 0);
            let b = au_param_type(f, 1);
            let l = au_param_type(f, 2);
            return true, au_get_declaration(mid, [a, b, l]);
        }
        if starts_with(name, "memset.") && np == 5 {
            au_rename_old(f);
            let a = au_param_type(f, 0);
            let l = au_param_type(f, 2);
            return true, au_get_declaration(au_intr_id("llvm.memset"), [a, l]);
        }
        var masked: i64 = 0;
        if starts_with(name, "masked.load") { masked = 1; }
        else if starts_with(name, "masked.gather") { masked = 2; }
        else if starts_with(name, "masked.store") { masked = 3; }
        else if starts_with(name, "masked.scatter") { masked = 4; }
        if masked != 0 && np == 4 {
            au_rename_old(f);
            if masked == 1 || masked == 2 {
                let id = au_intr_id(if masked == 1 { "llvm.masked.load" } else { "llvm.masked.gather" });
                let r = au_ret_type(f);
                let p = au_param_type(f, 0);
                return true, au_get_declaration(id, [r, p]);
            }
            let id = au_intr_id(if masked == 3 { "llvm.masked.store" } else { "llvm.masked.scatter" });
            let a = au_param_type(f, 0);
            let p = au_param_type(f, 1);
            return true, au_get_declaration(id, [a, p]);
        }
    }
    if c == 'o' && starts_with(name, "objectsize.") {
        if np == 2 || np == 3 {
            let r = au_ret_type(f);
            let p = au_param_type(f, 0);
            au_rename_old(f);
            return true, au_get_declaration(au_intr_id("llvm.objectsize"), [r, p]);
        }
    }
    if c == 'p' && starts_with(name, "ptr.annotation.") && np == 4 {
        let a = au_param_type(f, 0);
        let b = au_param_type(f, 1);
        au_rename_old(f);
        return true, au_get_declaration(au_intr_id("llvm.ptr.annotation"), [a, b]);
    }
    if c == 's' && name == "stackprotectorcheck" { return true, -1; }
    if c == 't' && name == "thread.pointer" {
        let r = au_ret_type(f);
        return true, au_get_declaration(au_intr_id("llvm.thread.pointer"), [r]);
    }
    if c == 'v' {
        if name == "var.annotation" && np == 4 {
            let a = au_param_type(f, 0);
            let b = au_param_type(f, 1);
            au_rename_old(f);
            return true, au_get_declaration(au_intr_id("llvm.var.annotation"), [a, b]);
        }
        if starts_with(name, "vector.splice") && !(starts_with(name, "vector.splice.left") || starts_with(name, "vector.splice.right")) {
            fatal("llvm.vector.splice upgrade is not supported yet");
        }
    }
    let id = func_iid(f);
    if c == 'x' && starts_with(name, "x86.") {
        // upgradeX86IntrinsicFunction
        let xn = name[4..];
        if x86_should_upgrade(xn) { return true, -1; }
        if starts_with(xn, "xop.") && np == 2 && (xn == "xop.vfrcz.ss" || xn == "xop.vfrcz.sd") {
            au_rename_old(f);
            return true, au_get_declaration(au_intr_id(if xn == "xop.vfrcz.ss" { "llvm.x86.xop.vfrcz.ss" } else { "llvm.x86.xop.vfrcz.sd" }), []);
        }
        // the remaining cases of upgradeX86IntrinsicFunction rewrite old signatures of known intrinsics
        if id != 0 && !intr_signature_valid(id, globs[glob_of(f)].vty) {
            fatal(str("x86 intrinsic auto-upgrade is not supported yet (@", full, ")"));
        }
    }
    if c == 'a' && (starts_with(name, "arm.") || starts_with(name, "aarch64.") || starts_with(name, "amdgcn.")) {
        fatal(str("arm/aarch64/amdgcn intrinsic auto-upgrade is not supported (@", full, ")"));
    }
    if c == 'n' && starts_with(name, "nvvm.") { fatal(str("nvvm intrinsic auto-upgrade is not supported (@", full, ")")); }
    // named or packed struct return -> literal struct
    let rt = au_ret_type(f);
    if types[rt].kind == TK_STRUCT && ((types[rt].flags & TF_NAMED) != 0 || (types[rt].flags & TF_PACKED) != 0) && id != 0 {
        if intr_has_struct_return(id) {
            // replace the return type with the literal non-packed struct of the same elements
            let fty = globs[glob_of(f)].vty;
            let at = ints.len as i32;
            for k in types[rt].cnt { ints.push(ty_field(rt, k)); }
            let nst = ty_struct_run(at, types[rt].cnt, false);
            let fat = ints.len as i32;
            ints.push(nst);
            for k in ty_fn_nparams(fty) { ints.push(ty_fn_param(fty, k)); }
            let nft = ty_func_run(fat, ty_fn_nparams(fty) + 1, ty_fn_vararg(fty));
            var nm: u8[>..] = [];
            nm.append(sbytes(vals[f].name));
            au_rename_old(f);
            var nf = au_create_function(nm, nft);
            globs[glob_of(nf)].linkage = globs[glob_of(f)].linkage;
            let r = au_remangle(nf);
            if r >= 0 { nf = r; }
            return true, nf;
        }
    }
    let r = au_remangle(f);
    if r >= 0 { return true, r; }
    return false, -1;
}

// UpgradeIntrinsicFunction
fn upgrade_intrinsic_function(f: i32) -> bool, i32 {
    let up, nf = upgrade_intrinsic_function1(f);
    let g = if nf >= 0 { nf } else { f };
    let id = func_iid(g);
    if id != 0 && intr_signature_valid(id, globs[glob_of(g)].vty) {
        globs[glob_of(g)].attrs = intr_attributes(id, globs[glob_of(g)].vty);
    }
    return up, nf;
}

// ---------------------------------------------------------------------------------------------
// UpgradeIntrinsicCall

fn au_set_callee(ci: i32, nf: i32) { set_op(ci, nops(ci) - 1, nf); }

fn aset_with(s: i32, a: i32) -> i32 {
    var xs: i32[>..] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind != attrs[a].kind { xs.push(x); } }
    xs.push(a);
    return aset_get(xs);
}
fn aset_without(s: i32, kind: i64) -> i32 {
    var xs: i32[>..] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind as i64 != kind { xs.push(x); } }
    return aset_get(xs);
}
// set param k of an attribute list to set s
fn alist_set_param(l: i32, k: i64, s: i32) -> i32 {
    var xs: i32[>..] = [];
    xs.push(alist_fn(l));
    xs.push(alist_ret(l));
    let n = max(alists[l].n as i64 - 2, k + 1);
    for j in n { xs.push(if j == k { s } else { alist_param(l, j) }); }
    return alist_get(xs);
}

fn align_attr(a: i64) -> i32 { attr_int(AK_Alignment, a as u64) }

// IRBuilder::CreateCall at ci (inherits ci's !dbg and, for FP math calls, its fast-math flags).
fn au_create_call(ci: i32, nf: i32, argsv: const i32[:]) -> i32 {
    let fty = globs[glob_of(nf)].vty;
    let v = new_inst(OP_CALL, ty_fn_ret(fty), argsv.len + 1);
    for k in argsv.len { set_op(v, k, argsv[k]); }
    set_op(v, argsv.len, nf);
    let ii = inst_of(v);
    insts[ii].ty2 = fty;
    let oi = inst_of(ci);
    if au_is_fp_math(ty_fn_ret(fty)) && au_is_fp_math(vals[ci].ty) { insts[ii].fmf = insts[oi].fmf; }
    // debug location
    for k in insts[oi].nmd {
        if md_att[insts[oi].md + 2 * k] == 0 {
            let at = md_att.len as i32;
            md_att.push(0);
            md_att.push(md_att[insts[oi].md + 2 * k + 1]);
            insts[ii].md = at;
            insts[ii].nmd = 1;
        }
    }
    inst_insert_before(v, ci);
    return v;
}

fn au_is_fp_math(t: i32) -> bool {
    var s = t;
    while types[s].kind == TK_ARRAY { s = types[s].a; }
    if types[s].kind == TK_STRUCT {
        if types[s].cnt == 0 { return false; }
        let e = ints[types[s].a];
        for k in types[s].cnt { if ints[types[s].a + k] != e { return false; } }
        s = e;
    }
    return ty_is_fp(ty_scalar(s));
}

// NewCall->takeName(CI); CI->replaceAllUsesWith(NewCall); CI->eraseFromParent()
fn au_replace_call(ci: i32, nc: i32) {
    if vals[ci].name >= 0 {
        let st = symtab_for(ci);
        let nm = vals[ci].name;
        symtab_remove(st, ci);
        vals[ci].name = -1;
        vals[nc].name = nm;
        symtab_insert_raw(st, nc);
    }
    rauw(ci, nc);
        au_erase_inst(ci);
}

fn cint_zext(v: i32) -> u64 { cint_lo(v) }

fn upgrade_intrinsic_call(ci: i32, nf: i32) {
    let f = cb_callee(ci);
    if vals[f].kind != VK_FUNC { return; }
    if nf < 0 {
        let name = sbytes(vals[f].name);
        if starts_with(name, "llvm.x86.") {
            let rep = upgrade_x86_call(name[9..], ci);
            if rep >= 0 { rauw(ci, rep); }
            au_erase_inst(ci);
            return;
        }
        if starts_with(name, "llvm.convert.") {
            // upgradeConvertIntrinsicCall (IRBuilder with constant folding)
            let half = ty_simple(TK_HALF);
            var rep: i32 = -1;
            if starts_with(name[13..], "to.fp16") {
                let c = au_build_cast(ci, OP_FPTRUNC, op(ci, 0), half);
                rep = au_build_cast(ci, OP_BITCAST, c, vals[ci].ty);
            } else {
                let c = au_build_cast(ci, OP_BITCAST, op(ci, 0), half);
                rep = au_build_cast(ci, OP_FPEXT, c, vals[ci].ty);
            }
            rauw(ci, rep);
            au_erase_inst(ci);
            return;
        }
        if starts_with(name, "llvm.dbg.") {
            upgrade_dbg_intrinsic_to_record(name[9..], ci);
                        au_erase_inst(ci);
            return;
        }
        if name == "llvm.stackprotectorcheck" || name == "llvm.lifetime.start.i64" || name == "llvm.lifetime.end.i64" {
            au_erase_inst(ci);
            return;
        }
        fatal(str("intrinsic call upgrade for @", name, " is not supported yet"));
    }
    let id = func_iid(nf);
    let iname = intr_name(id);
    let nargs = cb_nargs(ci);
    if iname == "llvm.x86.xop.vfrcz.ss" || iname == "llvm.x86.xop.vfrcz.sd" {
        if nargs == 2 {
            let nc = au_create_call(ci, nf, [op(ci, 1)]);
            au_replace_call(ci, nc);
            return;
        }
    }
    if iname == "llvm.coro.end" {
        var a: i32[>..] = [];
        for k in nargs { a.push(op(ci, k)); }
        a.push(c_simple(VK_CTOKENNONE, T_TOKEN));
        let nc = au_create_call(ci, nf, a);
        au_replace_call(ci, nc);
        return;
    }
    if iname == "llvm.ctlz" || iname == "llvm.cttz" {
        if nargs == 1 {
            let nc = au_create_call(ci, nf, [op(ci, 0), c_false()]);
            au_replace_call(ci, nc);
            return;
        }
    } else if iname == "llvm.objectsize" {
        let a2 = if nargs == 2 { c_false() } else { op(ci, 2) };
        let a3 = if nargs < 4 { c_false() } else { op(ci, 3) };
        let nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 1), a2, a3]);
        au_replace_call(ci, nc);
        return;
    } else if iname == "llvm.ptr.annotation" || iname == "llvm.var.annotation" {
        if nargs == 4 {
            let nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 1), op(ci, 2), op(ci, 3), c_null(T_PTR)]);
            au_replace_call(ci, nc);
            return;
        }
    } else if iname == "llvm.thread.pointer" {
        let nc = au_create_call(ci, nf, []);
        au_replace_call(ci, nc);
        return;
    } else if iname == "llvm.memcpy" || iname == "llvm.memmove" || iname == "llvm.memset" {
        if nargs == 5 {
            let nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 1), op(ci, 2), op(ci, 4)]);
            let ol = insts[inst_of(ci)].attrs;
            var l = alist_get([alist_fn(ol), alist_ret(ol), alist_param(ol, 0), alist_param(ol, 1), alist_param(ol, 2), alist_param(ol, 4)]);
            let a = cint_zext(op(ci, 3)) as i64;
            l = alist_set_param(l, 0, aset_without(alist_param(l, 0), AK_Alignment));
            if a != 0 { l = alist_set_param(l, 0, aset_with(alist_param(l, 0), align_attr(a))); }
            if iname != "llvm.memset" {
                l = alist_set_param(l, 1, aset_without(alist_param(l, 1), AK_Alignment));
                if a != 0 { l = alist_set_param(l, 1, aset_with(alist_param(l, 1), align_attr(a))); }
            }
            insts[inst_of(nc)].attrs = l;
            au_replace_call(ci, nc);
            return;
        }
    } else if iname == "llvm.masked.load" || iname == "llvm.masked.gather" || iname == "llvm.masked.store" || iname == "llvm.masked.scatter" {
        if nargs == 4 {
            var nc: i32 = -1;
            var al: i64 = 0;
            if iname == "llvm.masked.load" {
                al = cint_zext(op(ci, 1)) as i64;
                if al == 0 { fatal("Invalid zero alignment argument"); }
                nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 2), op(ci, 3)]);
            } else if iname == "llvm.masked.gather" {
                al = cint_zext(op(ci, 1)) as i64;
                if al == 0 { al = dl_align(ty_scalar(vals[ci].ty), true); }
                nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 2), op(ci, 3)]);
            } else if iname == "llvm.masked.store" {
                al = cint_zext(op(ci, 2)) as i64;
                if al == 0 { fatal("Invalid zero alignment argument"); }
                nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 1), op(ci, 3)]);
            } else {
                al = cint_zext(op(ci, 2)) as i64;
                if al == 0 { al = dl_align(ty_scalar(vals[op(ci, 0)].ty), true); }
                nc = au_create_call(ci, nf, [op(ci, 0), op(ci, 1), op(ci, 3)]);
            }
            let pk: i64 = if iname == "llvm.masked.load" || iname == "llvm.masked.gather" { 0 } else { 1 };
            insts[inst_of(nc)].attrs = alist_set_param(0, pk, aset_get([align_attr(al)]));
            // copyMetadata (all attachments) and the tail call kind
            insts[inst_of(nc)].md = insts[inst_of(ci)].md;
            insts[inst_of(nc)].nmd = insts[inst_of(ci)].nmd;
            insts[inst_of(nc)].pred = insts[inst_of(ci)].pred;
            au_replace_call(ci, nc);
            return;
        }
    } else if iname == "llvm.lifetime.start" || iname == "llvm.lifetime.end" {
        if nargs == 2 {
            var p = op(ci, 1);
            p = strip_pointer_casts(p);
            if vals[p].kind == VK_INST && iop(p) == OP_ALLOCA {
                let lid = au_intr_id(iname);
                let d = au_get_declaration(lid, [vals[p].ty]);
                let nc = au_create_call(ci, d, [p]);
                au_replace_call(ci, nc);
                return;
            }
            au_erase_inst(ci);
            return;
        }
    }
    // DefaultCase
    if f == nf { return; }
    if insts[inst_of(ci)].ty2 == globs[glob_of(nf)].vty { au_set_callee(ci, nf); return; }
    let ost = vals[ci].ty;
    if types[ost].kind == TK_STRUCT {
        // upgrade from a named to a literal struct return
        var a: i32[>..] = [];
        for k in nargs { a.push(op(ci, k)); }
        let nc = au_create_call(ci, nf, a);
        insts[inst_of(nc)].attrs = insts[inst_of(ci)].attrs;
        var res = c_poison(ost);
        for k in types[ost].cnt {
            let e = au_create_aggop(ci, OP_EXTRACTVALUE, ty_field(vals[nc].ty, k), nc, -1, k);
            res = au_create_aggop(ci, OP_INSERTVALUE, ost, res, e, k);
        }
        rauw(ci, res);
        au_erase_inst(ci);
        return;
    }
    fatal(str("intrinsic call upgrade to @", sbytes(vals[nf].name), " with a different type is not supported yet"));
}

// Value::stripPointerCasts (PSK_ZeroIndicesAndAliases... without aliases): bitcast, addrspacecast, all-zero GEPs.
fn strip_pointer_casts(v0: i32) -> i32 {
    var v = v0;
    loop {
        let k = vals[v].kind;
        if k == VK_INST {
            let o = iop(v);
            if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
            if o == OP_GEP {
                var allz = true;
                for j in 1..nops(v) { let x = op(v, j); if !(vals[x].kind == VK_CINT && cint_is_zero(x)) { allz = false; } }
                if allz { v = op(v, 0); continue; }
            }
        } else if k == VK_CEXPR {
            let o = csts[vals[v].sub].op as i64;
            if o == OP_BITCAST || o == OP_ADDRSPACECAST { v = op(v, 0); continue; }
        }
        return v;
    }
}

// UpgradeCallsToIntrinsic
fn upgrade_calls_to_intrinsic(f: i32) {
    let up, nf = upgrade_intrinsic_function(f);
    if !up { return; }
    var users: i32[>..] = [];
    var u = vals[f].first_use;
    while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
    for ci in users {
        if vals[ci].kind == VK_INST && is_call_base_op(iop(ci)) { upgrade_intrinsic_call(ci, nf); }
    }
    if f != nf { au_erase_function(f); }
}

fn upgrade_module_intrinsics() {
    var f = modules[cur_module].first_func;
    while f >= 0 {
        let next = globs[glob_of(f)].next;
        upgrade_calls_to_intrinsic(f);
        f = next;
    }
}

// unwrapMAVMetadataOp / unwrapMAVOp
fn mav_md(ci: i32, k: i64) -> i32 {
    if k >= cb_nargs(ci) { return -1; }
    let a = op(ci, k);
    if vals[a].kind != VK_MDVAL { return -1; }
    return vals[a].sub;
}
fn mav_node(ci: i32, k: i64) -> i32 {
    let m = mav_md(ci, k);
    if m >= 0 && md_is_node(m) { return m; }
    return -1;
}

// upgradeDbgIntrinsicToDbgRecord
fn upgrade_dbg_intrinsic_to_record(kind: const u8[:], ci: i32) {
    var r: i32 = -1;
    if kind == "label" {
        r = new_dbgrec(DR_LABEL);
        dbgrecs[r].dvar = mav_node(ci, 0);
    } else if kind == "assign" {
        r = new_dbgrec(DR_ASSIGN);
        dbgrecs[r].loc = mav_md(ci, 0);
        dbgrecs[r].dvar = mav_node(ci, 1);
        dbgrecs[r].expr = mav_node(ci, 2);
        dbgrecs[r].aid = mav_node(ci, 3);
        dbgrecs[r].addr = mav_md(ci, 4);
        dbgrecs[r].aexpr = mav_node(ci, 5);
    } else if kind == "declare" {
        r = new_dbgrec(DR_DECLARE);
        dbgrecs[r].loc = mav_md(ci, 0);
        dbgrecs[r].dvar = mav_node(ci, 1);
        dbgrecs[r].expr = mav_node(ci, 2);
    } else if kind == "addr" {
        fatal("llvm.dbg.addr upgrade is not supported yet");
    } else if kind == "value" {
        var vo: i64 = 1;
        var eo: i64 = 2;
        if cb_nargs(ci) == 4 {
            let off = op(ci, 1);
            if !(is_constant(off) && is_null_value(off)) { return; }
            vo = 2;
            eo = 3;
        }
        r = new_dbgrec(DR_VALUE);
        dbgrecs[r].loc = mav_md(ci, 0);
        dbgrecs[r].dvar = mav_node(ci, vo);
        dbgrecs[r].expr = mav_node(ci, eo);
    } else {
        return;
    }
    // DebugLoc from the call's !dbg
    let ii = inst_of(ci);
    for k in insts[ii].nmd { if md_att[insts[ii].md + 2 * k] == 0 { dbgrecs[r].dl = md_att[insts[ii].md + 2 * k + 1]; } }
    inst_add_dbg(ci, r);
}

fn au_erase_inst(ci: i32) { dbg_records_to_next(ci); inst_erase(ci); }

// UpgradeModuleFlags (the behaviour upgrades; ObjC/Swift/amdgpu flags fail loudly).
fn upgrade_module_flags() {
    for &nm in named_mds {
        if nm.module != cur_module || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let op = md_ops[nm.ops + i];
            if op < 0 || mds[op].kind != MK_TUPLE || mds[op].nops != 3 { continue; }
            let id = md_op(op, 1);
            if id < 0 || mds[id].kind != MK_STRING { continue; }
            let s = sbytes(mds[id].extra);
            let b = md_op(op, 0);
            var beh: i64 = -1;
            if b >= 0 && mds[b].kind == MK_VALUE && vals[mds[b].extra].kind == VK_CINT { beh = cint_lo(mds[b].extra) as! i64; }
            var nb: i64 = -1;
            if s == "PIC Level" && (beh == 1 || beh == 7) { nb = 8; }
            if s == "PIE Level" && beh == 1 { nb = 7; }
            if (s == "branch-target-enforcement" || starts_with(s, "sign-return-address")) && beh == 1 { nb = 8; }
            if s == "Objective-C Image Info Version" || s == "Objective-C Garbage Collection" || s == "amdgpu_code_object_version" || s == "Objective-C Image Info Section" {
                fatal(str("module flag upgrade for '", s, "' is not supported yet"));
            }
            if nb >= 0 {
                let nv = md_value(c_int(T_I32, nb));
                md_ops[nm.ops + i] = md_get(MK_TUPLE, -1, [nv, id, md_op(op, 2)], false);
            }
        }
    }
}

// UpgradeTBAANode on every instruction's !tbaa (LLParser's InstsWithTBAATag).
fn upgrade_tbaa_node(m: i32) -> i32 {
    if m < 0 || mds[m].kind != MK_TUPLE { return m; }
    let n = mds[m].nops as i64;
    if n == 0 { return m; }
    let o0 = md_op(m, 0);
    if o0 >= 0 && md_is_node(o0) && n >= 3 { return m; }
    let zero = md_value(c_int(T_I64, 0));
    if n == 3 {
        let st = md_get(MK_TUPLE, -1, [md_op(m, 0), md_op(m, 1)], false);
        return md_get(MK_TUPLE, -1, [st, st, zero, md_op(m, 2)], false);
    }
    return md_get(MK_TUPLE, -1, [m, m, zero], false);
}

fn upgrade_tbaa() {
    var f = modules[cur_module].first_func;
    while f >= 0 {
        var b = globs[glob_of(f)].first_block;
        while b >= 0 {
            var iv = blocks[block_of(b)].first;
            while iv >= 0 {
                let ii = inst_of(iv);
                for k in insts[ii].nmd {
                    let at = insts[ii].md + 2 * k;
                    if md_att[at] == 1 { md_att[at + 1] = upgrade_tbaa_node(md_att[at + 1]); }
                }
                iv = insts[ii].next;
            }
            b = blocks[block_of(b)].next;
        }
        f = globs[glob_of(f)].next;
    }
}

// UpgradeDebugInfo: without "Debug Info Version" 3 in llvm.module.flags, StripDebugInfo (DebugInfo.cpp).
// (LLVM also strips debug info that fails the verifier; that part is not ported.)
fn upgrade_debug_info() {
    var version: i64 = 0;
    for nm in named_mds {
        if nm.module != cur_module || sbytes(nm.name) != "llvm.module.flags" { continue; }
        for i in nm.nops {
            let op = md_ops[nm.ops + i];
            if op < 0 || mds[op].kind != MK_TUPLE || mds[op].nops < 3 { continue; }
            let id = md_op(op, 1);
            if id < 0 || mds[id].kind != MK_STRING || sbytes(mds[id].extra) != "Debug Info Version" { continue; }
            let v = md_op(op, 2);
            if v >= 0 && mds[v].kind == MK_VALUE && vals[mds[v].extra].kind == VK_CINT { version = cint_lo(mds[v].extra) as! i64; }
        }
    }
    if version == 3 {
        if !debug_info_broken() { return; }
        // DiagnosticInfoIgnoringInvalidDebugMetadata (the Verifier printed its findings first)
        errs(str("warning: ignoring invalid debug info in ", sbytes(modules[cur_module].module_id), "\n"));
    }
    let modified = strip_debug_info();
    if modified && version != 3 {
        // DiagnosticInfoDebugMetadataVersion
        errs(str("warning: ignoring debug info with an invalid version (", version, ") in ", sbytes(modules[cur_module].module_id), "\n"));
    }
}

fn has_dbg_att(at: i32, n: i32) -> bool { for k in n { if md_att[at + 2 * k] == 0 { return true; } } return false; }

// The Verifier's debug-info checks that make UpgradeDebugInfo strip debug info (subset: inlinable calls
// without !dbg in a function with a subprogram).
fn debug_info_broken() -> bool {
    var broken = false;
    var f = modules[cur_module].first_func;
    while f >= 0 {
        let g = glob_of(f);
        if has_dbg_att(globs[g].md, globs[g].nmd) {
            var b = globs[g].first_block;
            while b >= 0 {
                var iv = blocks[block_of(b)].first;
                while iv >= 0 {
                    let ii = inst_of(iv);
                    if is_call_base_op(iop(iv)) {
                        let c = cb_callee(iv);
                        if vals[c].kind == VK_FUNC && globs[glob_of(c)].vty == insts[ii].ty2 {
                            let cg = glob_of(c);
                            let lk = globs[cg].linkage as i64;
                            let interposable = lk == LK_WEAK_ANY || lk == LK_LINKONCE_ANY || lk == LK_COMMON || lk == LK_EXTERN_WEAK;
                            if !interposable && globs[cg].is_decl == 0 && has_dbg_att(globs[cg].md, globs[cg].nmd) && !has_dbg_att(insts[ii].md, insts[ii].nmd) {
                                errs("inlinable function call in a function with debug info must have a !dbg location\n");
                                errs_inst_module_slots(iv, f);
                                errs("\n");
                                broken = true;
                            }
                        }
                    }
                    iv = insts[ii].next;
                }
                b = blocks[block_of(b)].next;
            }
        }
        f = globs[g].next;
    }
    return broken;
}

fn att_remove_kind(at: i32, n: i32, kind: i32) -> i32 {
    // compacts the run in place; returns the new count
    var w = 0;
    for k in n {
        if md_att[at + 2 * k] == kind { continue; }
        md_att[at + 2 * w] = md_att[at + 2 * k];
        md_att[at + 2 * w + 1] = md_att[at + 2 * k + 1];
        w++;
    }
    return w as i32;
}

fn is_dilocation(m: i32) -> bool { m >= 0 && mds[m].kind == MK_DI && di_kind(m) == DIK_LOCATION }

// stripDebugLocFromLoopID (direct DILocation operands only)
fn strip_loop_id_locs(n: i32) -> i32 {
    if n < 0 || mds[n].kind != MK_TUPLE || mds[n].nops == 0 { return n; }
    var any = false;
    var all = true;
    for k in 1..mds[n].nops { if is_dilocation(md_op(n, k)) { any = true; } else { all = false; } }
    if !any { return n; }
    if all { return -1; }
    var opsv: i32[>..] = [];
    opsv.push(-1);
    for k in 1..mds[n].nops { let o = md_op(n, k); if !is_dilocation(o) { opsv.push(o); } }
    let r = md_get(MK_TUPLE, -1, opsv, true);
    md_ops[mds[r].ops] = r;
    return r;
}

// Returns StripDebugInfo's "Changed": named llvm.dbg.*/llvm.gcov metadata, a function's or global's !dbg, an
// instruction's debug location (not loop IDs, heapallocsite, DIAssignID or debug records).
fn strip_debug_info() -> bool {
    var changed = false;
    // named metadata llvm.dbg.* and llvm.gcov
    var w = 0;
    for k in named_mds.len {
        let nm = named_mds[k];
        let s = sbytes(nm.name);
        if nm.module == cur_module && (starts_with(s, "llvm.dbg.") || s == "llvm.gcov") { changed = true; continue; }
        named_mds[w] = nm;
        w++;
    }
    named_mds.resize(w);
    let k_heap = md_kind_id("heapallocsite");
    let k_assign = md_kind_id("DIAssignID");
    let k_loop = md_kind_id("llvm.loop");
    var f = modules[cur_module].first_func;
    while f >= 0 {
        let g = glob_of(f);
        if has_dbg_att(globs[g].md, globs[g].nmd) { changed = true; }
        globs[g].nmd = att_remove_kind(globs[g].md, globs[g].nmd, 0);
        var b = globs[g].first_block;
        while b >= 0 {
            var iv = blocks[block_of(b)].first;
            while iv >= 0 {
                let ii = inst_of(iv);
                if has_dbg_att(insts[ii].md, insts[ii].nmd) { changed = true; }
                var n = att_remove_kind(insts[ii].md, insts[ii].nmd, 0);
                n = att_remove_kind(insts[ii].md, n, k_heap);
                n = att_remove_kind(insts[ii].md, n, k_assign);
                for k in n {
                    let at = insts[ii].md + 2 * k;
                    if md_att[at] == k_loop { md_att[at + 1] = strip_loop_id_locs(md_att[at + 1]); }
                }
                // a loop ID reduced to nothing is removed
                var w2 = 0;
                for k in n {
                    if md_att[insts[ii].md + 2 * k + 1] < 0 { continue; }
                    md_att[insts[ii].md + 2 * w2] = md_att[insts[ii].md + 2 * k];
                    md_att[insts[ii].md + 2 * w2 + 1] = md_att[insts[ii].md + 2 * k + 1];
                    w2++;
                }
                insts[ii].nmd = w2 as i32;
                if ii < inst_dbg.len { inst_dbg[ii] = -1; }
                iv = insts[ii].next;
            }
            b = blocks[block_of(b)].next;
        }
        f = globs[g].next;
    }
    var gv = modules[cur_module].first_gvar;
    while gv >= 0 {
        let g = glob_of(gv);
        if has_dbg_att(globs[g].md, globs[g].nmd) { changed = true; }
        globs[g].nmd = att_remove_kind(globs[g].md, globs[g].nmd, 0);
        gv = globs[g].next;
    }
    return changed;
}

// IRBuilder::CreateExtractValue / CreateInsertValue at ci (one index; inherits ci's !dbg)
fn au_create_aggop(ci: i32, opc: i64, ty: i32, agg: i32, val: i32, idx: i64) -> i32 {
    let n = if opc == OP_INSERTVALUE { 2 } else { 1 };
    let v = new_inst(opc, ty, n);
    set_op(v, 0, agg);
    if opc == OP_INSERTVALUE { set_op(v, 1, val); }
    let ii = inst_of(v);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = 1;
    ints.push(idx as i32);
    let oi = inst_of(ci);
    for k in insts[oi].nmd {
        if md_att[insts[oi].md + 2 * k] == 0 {
            let at = md_att.len as i32;
            md_att.push(0);
            md_att.push(md_att[insts[oi].md + 2 * k + 1]);
            insts[ii].md = at;
            insts[ii].nmd = 1;
        }
    }
    inst_insert_before(v, ci);
    return v;
}

// IRBuilder::CreateCast with the default ConstantFolder; otherwise a new cast before ci (with ci's !dbg)
fn au_build_cast(ci: i32, opc: i64, v: i32, ty: i32) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        let f = if is_desirable_cast_op(opc) { ce_cast(opc, v, ty) } else { cf_cast(opc, v, ty) };
        if f >= 0 { return f; }
    }
    let n = new_inst(opc, ty, 1);
    set_op(n, 0, v);
    let oi = inst_of(ci);
    let ii = inst_of(n);
    for k in insts[oi].nmd {
        if md_att[insts[oi].md + 2 * k] == 0 {
            let at = md_att.len as i32;
            md_att.push(0);
            md_att.push(md_att[insts[oi].md + 2 * k + 1]);
            insts[ii].md = at;
            insts[ii].nmd = 1;
        }
    }
    inst_insert_before(n, ci);
    return n;
}
