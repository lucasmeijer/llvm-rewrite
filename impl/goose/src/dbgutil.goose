// Debug-record utilities of llvm/lib/Transforms/Utils/Local.cpp (replaceAllDbgUsesWith, rewriteDebugUsers,
// isBitCastSemanticsPreserving, LowerDbgDeclare, isCompositeType, ConvertDebugDeclareToDebugValue for loads),
// llvm/lib/Transforms/Utils/BasicBlockUtils.cpp (RemoveRedundantDbgInstrs and its backward/forward scans),
// llvm/lib/Transforms/Scalar/DCE.cpp (RedundantDbgInstEliminationPass) and the DIExpression helpers they use
// (llvm/lib/IR/DebugInfoMetadata.cpp: append, appendToStack, appendExt, getExtOps, getFragmentInfo).
//
// dbg_assign records (assignment tracking) fail loudly everywhere here.
import std;
import ir;
import irutil;
import dinfo;
import datalayout;
import domtree;
import mem2reg;
import salvage;
import gen_dwarf;
import instinfo;
import analyses;

let DU_OP_STACK_VALUE = 0x9f;
let DU_OP_LLVM_CONVERT = 0x1001;
let DU_ATE_SIGNED = 0x05;
let DU_ATE_UNSIGNED = 0x07;

fn du_expr(ops: const i64[:]) -> i32 {
    var els: i32[>..<] = [];
    for x in ops { els.push(md_int(x)); }
    return md_get(MK_DIEXPR, -1, els, false);
}

// DIExpression::append(Expr, Ops): the new ops go before DW_OP_stack_value / DW_OP_LLVM_fragment.
fn du_expr_append(e: i32, add: const i64[:]) -> i32 {
    var out: i64[>..<] = [];
    var pending = true;
    let n = diexpr_nelems(e);
    var k: i64 = 0;
    while k < n {
        let o = diexpr_elem(e, k);
        if pending && (o == DU_OP_STACK_VALUE || o == DW_OP_LLVM_fragment) {
            for x in add { out.push(x); }
            pending = false;
        }
        let sz = diexpr_op_size(o);
        for j in sz { if k + j < n { out.push(diexpr_elem(e, k + j)); } }
        k += sz;
    }
    if pending { for x in add { out.push(x); } }
    return du_expr(out);
}

// DIExpression::appendToStack(Expr, Ops)
fn du_expr_append_to_stack(e: i32, add: const i64[:]) -> i32 {
    let n = diexpr_nelems(e);
    let has_frag, fo, fs = du_fragment(e);
    let _ = fo; let _ = fs;
    let drop: i64 = if has_frag { 3 } else { 0 };
    let before = n - drop;
    let needs_deref = n > drop && diexpr_elem(e, before - 1) != DU_OP_STACK_VALUE;
    let needs_stack_value = needs_deref || before == 0;
    var ops: i64[>..<] = [];
    if needs_deref { ops.push(DW_OP_deref); }
    for x in add { ops.push(x); }
    if needs_stack_value { ops.push(DU_OP_STACK_VALUE); }
    return du_expr_append(e, ops);
}

// DIExpression::getFragmentInfo: (has, offset, size)
fn du_fragment(e: i32) -> bool, i64, i64 {
    let n = diexpr_nelems(e);
    var k: i64 = 0;
    while k < n {
        let o = diexpr_elem(e, k);
        if o == DW_OP_LLVM_fragment { return true, diexpr_elem(e, k + 1), diexpr_elem(e, k + 2); }
        k += diexpr_op_size(o);
    }
    return false, 0, 0;
}

// The size in bits of an integer or pointer type (DataLayout::getTypeSizeInBits).
fn du_int_or_ptr_bits(t: i32) -> i64 {
    if ty_kind(t) == TK_INT { return ty_bits(t); }
    return dl_ptr(types[t].n as i64).bits;
}
fn du_is_int_or_ptr(t: i32) -> bool { ty_kind(t) == TK_INT || ty_kind(t) == TK_PTR }

// isBitCastSemanticsPreserving(DL, FromTy, ToTy)
fn du_bitcast_semantics_preserving(from: i32, to: i32) -> bool {
    if from == to { return true; }
    if du_is_int_or_ptr(from) && du_is_int_or_ptr(to) {
        let same = du_int_or_ptr_bits(from) == du_int_or_ptr_bits(to);
        let lossless = !(ty_kind(from) == TK_PTR && dl_is_nonintegral_as(types[from].n as i64)) &&
            !(ty_kind(to) == TK_PTR && dl_is_nonintegral_as(types[to].n as i64));
        return same && lossless;
    }
    return false;
}

// DIVariable::getSignedness: 1 signed, 0 unsigned, -1 unknown (only a DIBasicType type is looked at).
fn du_var_signedness(var_: i32) -> i64 {
    let t = di_slot(var_, "type");
    if t < 0 || mds[t].kind != MK_DI || di_kind(t) != DIK_BASICTYPE { return -1; }
    let enc = di_int(t, "encoding");
    if enc == DU_ATE_SIGNED || enc == 0x06 { return 1; }       // DW_ATE_signed, DW_ATE_signed_char
    if enc == DU_ATE_UNSIGNED || enc == 0x08 { return 0; }     // DW_ATE_unsigned, DW_ATE_unsigned_char
    return -1;
}

// BasicBlock::insertDbgRecordAfter(DR, I): at the head of the next position's marker.
fn du_insert_record_after(r: i32, i: i32) {
    marker_absorb(inst_parent(i), inst_next(i), r, true);
}
// DbgRecord::removeFromParent
fn du_remove_record(r: i32) { dbg_erase_record(r); }

// rewriteDebugUsers(From, To, DomPoint, DT, RewriteDVRExpr) with the rewrite given as: kind 0 = identity,
// kind 1 = sign/zero extension from `to_bits` to `from_bits` bits (appendExt), when the variable's signedness
// is known.
fn du_rewrite_debug_users(from: i32, to: i32, dom_point: i32, kind: i64, to_bits: i64, from_bits: i64) -> bool {
    var users: i32[>..<] = [];
    find_dbg_users(from, users);
    if users.len == 0 { return false; }
    var changed = false;
    var undef_or_salvage: i32[>..<] = [];
    if is_inst(to) {
        let dom_after_from = inst_next(from) == dom_point;
        for r in users {
            let marked = dbgrecs[r].owner;
            if marked < 0 { fatal("replaceAllDbgUsesWith: a debug user without a marker is not ported"); }
            if dom_after_from && marked == dom_point {
                du_remove_record(r);
                du_insert_record_after(r, dom_point);
                changed = true;
            } else if !dt_value_dominates_inst(dom_point, marked) {
                undef_or_salvage.push(r);
            }
        }
    }
    for r in users {
        var skip = false;
        for x in undef_or_salvage { if x == r { skip = true; } }
        if skip { continue; }
        if dbgrecs[r].kind as i64 == DR_ASSIGN { fatal("replaceAllDbgUsesWith: dbg_assign records are not ported yet"); }
        var ne = dbgrecs[r].expr;
        if kind == 1 {
            let s = du_var_signedness(dbgrecs[r].dvar);
            if s < 0 { continue; }
            let tk = if s == 1 { DU_ATE_SIGNED } else { DU_ATE_UNSIGNED };
            let ext: i64[6] = [DU_OP_LLVM_CONVERT, to_bits, tk, DU_OP_LLVM_CONVERT, from_bits, tk];
            ne = du_expr_append_to_stack(ne, ext);
        }
        dbg_set_loc(r, m2r_md_replace_value(dbgrecs[r].loc, from, to));
        dbgrecs[r].expr = ne;
        changed = true;
    }
    if undef_or_salvage.len > 0 {
        salvage_debug_info(from);
        changed = true;
    }
    return changed;
}

// replaceAllDbgUsesWith(From, To, DomPoint, DT)
fn replace_all_dbg_uses_with(from: i32, to: i32, dom_point: i32) -> bool {
    if !val_used_by_md(from) { return false; }
    let fty = vals[from].ty as i32;
    let tty = vals[to].ty as i32;
    if du_bitcast_semantics_preserving(fty, tty) { return du_rewrite_debug_users(from, to, dom_point, 0, 0, 0); }
    if ty_kind(fty) == TK_INT && ty_kind(tty) == TK_INT {
        let fb = ty_bits(fty);
        let tb = ty_bits(tty);
        if fb < tb { return du_rewrite_debug_users(from, to, dom_point, 0, 0, 0); }
        return du_rewrite_debug_users(from, to, dom_point, 1, tb, fb);
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// RemoveRedundantDbgInstrs(BB)

fn du_rec_inlined_at(r: i32) -> i32 { let dl = dbgrecs[r].dl; if dl < 0 { -1 } else { di_slot(dl, "inlinedAt") } }

// removeRedundantDbgInstrsUsingBackwardScan: per instruction (one sequence of records), the last record of each
// (variable, fragment, inlinedAt) wins.
fn du_backward_scan(bb: i32) -> bool {
    var to_remove: i32[>..<] = [];
    var keys: i64[>..<] = [];      // (var, inlinedAt, has frag, off, size) per seen record
    var i = block_last(bb);
    while i >= 0 {
        var recs: i32[>..<] = [];
        var r = inst_first_dbg(i);
        while r >= 0 { if dbgrecs[r].kind as i64 != DR_LABEL { recs.push(r); } r = dbgrecs[r].next; }
        var k = recs.len - 1;
        while k >= 0 {
            let x = recs[k];
            k--;
            let hf, fo, fsz = du_fragment(dbgrecs[x].expr);
            let v = dbgrecs[x].dvar as i64;
            let ia = du_rec_inlined_at(x) as i64;
            let h: i64 = if hf { 1 } else { 0 };
            var seen = false;
            var j: i64 = 0;
            while j < keys.len {
                if keys[j] == v && keys[j + 1] == ia && keys[j + 2] == h && (h == 0 || (keys[j + 3] == fo && keys[j + 4] == fsz)) { seen = true; break; }
                j += 5;
            }
            if !seen {
                keys.push(v); keys.push(ia); keys.push(h); keys.push(if hf { fo } else { 0 }); keys.push(if hf { fsz } else { 0 });
                continue;
            }
            if dbgrecs[x].kind as i64 == DR_ASSIGN { fatal("RemoveRedundantDbgInstrs: dbg_assign records are not ported yet"); }
            to_remove.push(x);
        }
        keys.clear();
        i = inst_prev(i);
    }
    for x in to_remove { dbg_delete_record(x); }
    return to_remove.len > 0;
}

// removeRedundantDbgInstrsUsingForwardScan: a record that repeats the variable's current (locations, expression)
// (keyed on variable and inlinedAt, without the fragment) is removed.
fn du_forward_scan(bb: i32) -> bool {
    var removed = false;
    var kvar: i32[>..<] = [];
    var kia: i32[>..<] = [];
    var kloc: i32[>..<] = [];      // the location metadata (equal metadata = equal location values)
    var kexpr: i32[>..<] = [];
    var i = block_first(bb);
    while i >= 0 {
        var r = inst_first_dbg(i);
        while r >= 0 {
            let nr = dbgrecs[r].next;
            let kind = dbgrecs[r].kind as i64;
            if kind == DR_LABEL || kind == DR_DECLARE { r = nr; continue; }
            if kind == DR_ASSIGN { fatal("RemoveRedundantDbgInstrs: dbg_assign records are not ported yet"); }
            let v = dbgrecs[r].dvar;
            let ia = du_rec_inlined_at(r);
            var at: i64 = -1;
            for k in kvar.len { if kvar[k] == v && kia[k] == ia { at = k; break; } }
            let loc = du_loc_key(r);
            if at < 0 {
                kvar.push(v); kia.push(ia); kloc.push(loc); kexpr.push(dbgrecs[r].expr);
                r = nr;
                continue;
            }
            if kloc[at] != loc || kexpr[at] != dbgrecs[r].expr {
                kloc[at] = loc;
                kexpr[at] = dbgrecs[r].expr;
                r = nr;
                continue;
            }
            dbg_delete_record(r);
            removed = true;
            r = nr;
        }
        i = inst_next(i);
    }
    return removed;
}
// location_ops() as a comparable key: a single location and a one-element DIArgList of it are the same list of
// values in LLVM (SmallVector<Value*> comparison).
fn du_loc_key(r: i32) -> i32 {
    let l = dbgrecs[r].loc;
    if l >= 0 && mds[l].kind == MK_DIARGLIST && mds[l].nops == 1 { return md_op(l, 0); }
    return l;
}

fn remove_redundant_dbg_instrs(bb: i32) -> bool {
    var changed = du_backward_scan(bb);
    // removeUndefDbgAssignsFromEntryBlock only matters with dbg_assign records (fail loudly above)
    if du_forward_scan(bb) { changed = true; }
    return changed;
}

// RedundantDbgInstEliminationPass::run
fn redundant_dbg_inst_elim_run(fv: i32) -> u32 {
    var changed = false;
    var b = func_first_block(fv);
    while b >= 0 { if remove_redundant_dbg_instrs(b) { changed = true; } b = block_next(b); }
    if !changed { return 0xFFFFFFFF; }
    return PA_CFG;
}

// ---------------------------------------------------------------------------------------------
// LowerDbgDeclare(F)

// isCompositeType(DVR)
fn du_is_composite_type(r: i32) -> bool {
    var t = di_slot(dbgrecs[r].dvar, "type");
    if t < 0 { return true; }
    while mds[t].kind == MK_DI && di_kind(t) == DIK_DERIVEDTYPE {
        let tag = di_int(t, "tag");
        // pointer, reference, rvalue reference, ptr_to_member, LLVM_ptrauth
        if tag == 0x0f || tag == 0x10 || tag == 0x42 || tag == 0x1f || tag == 0x4300 { return false; }
        // typedef, const, volatile, restrict, atomic, immutable
        if tag == 0x16 || tag == 0x26 || tag == 0x35 || tag == 0x37 || tag == 0x47 || tag == 0x4b {
            t = di_slot(t, "baseType");
            if t < 0 { return true; }
            continue;
        }
        break;
    }
    return !(mds[t].kind == MK_DI && di_kind(t) == DIK_BASICTYPE);
}

// ConvertDebugDeclareToDebugValue(DVR, LoadInst *LI, DIB)
fn du_convert_declare_at_load(r: i32, li: i32) {
    if !m2r_value_covers_entire_fragment(vals[li].ty as i32, r) { return; }
    let nl = m2r_debug_value_loc(r);
    let nr = new_dbgrec(DR_VALUE);
    dbgrecs[nr].loc = md_value(li);
    dbgrecs[nr].dvar = dbgrecs[r].dvar;
    dbgrecs[nr].expr = dbgrecs[r].expr;
    dbgrecs[nr].dl = nl;
    dbg_track_new(nr);
    du_insert_record_after(nr, li);
}

fn du_lower_one(r: i32) -> bool {
    let l = dbgrecs[r].loc;
    var ai: i32 = -1;
    if l >= 0 && mds[l].kind == MK_VALUE { ai = mds[l].extra; }
    else if l >= 0 && mds[l].kind == MK_DIARGLIST && mds[l].nops > 0 { let o = md_op(l, 0); if mds[o].kind == MK_VALUE { ai = mds[o].extra; } }
    if !is_inst(ai) || iop(ai) != OP_ALLOCA { return false; }
    if !is_constant(op(ai, 0)) || du_is_composite_type(r) { return false; }
    var u = first_use(ai);
    while u >= 0 {
        let us = use_user(u);
        if is_inst(us) && iop(us) == OP_LOAD && inst_is_volatile(us) { return false; }
        if is_inst(us) && iop(us) == OP_STORE && inst_is_volatile(us) { return false; }
        u = use_next(u);
    }
    var wl: i32[>..<] = [];
    wl.push(ai);
    while wl.len > 0 {
        let v = wl.pop();
        var uu = first_use(v);
        while uu >= 0 {
            let us = use_user(uu);
            let opno = (uu - vals[us].ops) as i64;
            uu = use_next(uu);
            if !is_inst(us) { continue; }
            let o = iop(us);
            if o == OP_STORE {
                if opno == 1 { m2r_convert_declare_at_store(r, us); }
            } else if o == OP_LOAD {
                du_convert_declare_at_load(r, us);
            } else if o == OP_CALL {
                if !inst_is_lifetime_start_or_end(us) {
                    let nl = m2r_debug_value_loc(r);
                    let deref: i64[1] = [DW_OP_deref];
                    let de = du_expr_append(dbgrecs[r].expr, deref);
                    m2r_insert_dbg_value(ai, dbgrecs[r].dvar, de, nl, us);
                }
            } else if o == OP_BITCAST {
                if ty_kind(vals[us].ty) == TK_PTR { wl.push(us); }
            }
        }
    }
    dbg_delete_record(r);
    return true;
}

fn lower_dbg_declare(fv: i32) -> bool {
    var decls: i32[>..<] = [];
    var b = func_first_block(fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            var r = inst_first_dbg(i);
            while r >= 0 { if dbgrecs[r].kind as i64 == DR_DECLARE { decls.push(r); } r = dbgrecs[r].next; }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    if decls.len == 0 { return false; }
    var changed = false;
    for r in decls { if du_lower_one(r) { changed = true; } }
    if changed {
        b = func_first_block(fv);
        while b >= 0 { remove_redundant_dbg_instrs(b); b = block_next(b); }
    }
    return changed;
}
