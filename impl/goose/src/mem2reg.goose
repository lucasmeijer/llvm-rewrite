// mem2reg: port of llvm/lib/Transforms/Utils/Mem2Reg.cpp (PromotePass), llvm/lib/Transforms/Utils/
// PromoteMemoryToRegister.cpp (isAllocaPromotable, PromoteMemToReg) and the forward IDFCalculator of
// llvm/include/llvm/Support/GenericIteratedDominanceFrontier.h. The debug-info helpers it calls
// (ConvertDebugDeclareToDebugValue, InsertDebugValueAtStoreLoc, getDebugValueLoc, valueCoversEntireFragment)
// are ported from llvm/lib/Transforms/Utils/Local.cpp.
//
// Orders that show in the output and how they are reproduced:
// - Allocas: entry-block order, and RemoveFromAllocasList swaps the last one into the hole (alloca numbers
//   key NewPhiNodes and pick the PHI insertion order).
// - NewPhiNodes is a DenseMap<pair<unsigned, unsigned>, PHINode *>; its remove_if (PHI simplification) and the
//   final poison-filling loop walk it in bucket order, so the map is ported bit for bit (m2r_pm_*).
// - PHI names: alloca name + "." + version, versions in block-number order (BasicBlock::getNumber).
// Not ported (fails loudly): assignment tracking (dbg_assign), getMergedLocation of two different DILocations.
import std;
import ir;
import irutil;
import analyses;
import calls;
import instinfo;
import local;
import domtree;
import dinfo;
import datalayout;
import gen_iids;
import autoupgrade;
import intrinsics;
import knownbits;
import vt;
import poison;
import instsimplify;

// ---------------------------------------------------------------------------------------------
// Value-tracking queries (poison.goose, vt.goose, instsimplify.goose)

fn m2r_not_ported(what: const u8[:]) { fatal(str("mem2reg: ", what, " is not ported yet")); }

// isGuaranteedNotToBePoison(V, AC, CtxI = nullptr, DT)
fn m2r_not_poison(v: i32) -> bool { return is_guaranteed_not_to_be_poison(v, -1, 0); }
// simplifyInstruction(PN, SQ): -1 = no simplification
fn m2r_simplify_phi(p: i32) -> i32 { return simplify_instruction(p); }
// isKnownNonZero(V, SimplifyQuery(DL, DT, AC, LI))
fn m2r_known_non_zero(v: i32, li: i32) -> bool {
    let save = kb_cxt;
    kb_cxt = li;
    let r = is_known_non_zero(v, 0);
    kb_cxt = save;
    return r;
}

// ---------------------------------------------------------------------------------------------
// isAllocaPromotable and helpers

fn m2r_is_droppable(iv: i32) -> bool {
    if !is_inst(iv) || iop(iv) != OP_CALL { return false; }
    let id = call_iid(iv);
    return id == IID_assume || id == IID_pseudoprobe;
}

// onlyUsedByLifetimeMarkersOrDroppableInstsHelper
fn m2r_only_lifetime_or_droppable(v: i32, allow_droppable: bool) -> bool {
    var u = first_use(v);
    while u >= 0 {
        let us = use_user(u);
        if !is_inst(us) || !is_intrinsic_inst(us) { return false; }
        if !inst_is_lifetime_start_or_end(us) && !(allow_droppable && m2r_is_droppable(us)) { return false; }
        u = use_next(u);
    }
    return true;
}

fn is_alloca_promotable(ai: i32) -> bool {
    var expected: i32 = -1;
    var u = first_use(ai);
    while u >= 0 {
        let us = use_user(u);
        u = use_next(u);
        if !is_inst(us) { return false; }
        let o = iop(us);
        if o == OP_LOAD {
            if inst_is_volatile(us) { return false; }
            if expected < 0 { expected = vals[us].ty; } else if vals[us].ty != expected { return false; }
        } else if o == OP_STORE {
            if op(us, 0) == ai { return false; }
            if inst_is_volatile(us) { return false; }
            let st = vals[op(us, 0)].ty;
            if expected < 0 { expected = st; } else if st != expected { return false; }
        } else if is_intrinsic_inst(us) {
            if !inst_is_lifetime_start_or_end(us) && !m2r_is_droppable(us) && call_iid(us) != IID_fake_use { return false; }
        } else if o == OP_BITCAST {
            if !m2r_only_lifetime_or_droppable(us, true) { return false; }
        } else if o == OP_GEP {
            if !gep_all_zero_ci(us) { return false; }
            if !m2r_only_lifetime_or_droppable(us, true) { return false; }
        } else if o == OP_ADDRSPACECAST {
            if !m2r_only_lifetime_or_droppable(us, false) { return false; }
        } else {
            return false;
        }
    }
    return true;
}

// GetElementPtrInst::hasAllZeroIndices: every index is a ConstantInt zero.
fn gep_all_zero_ci(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if vals[x].kind != VK_CINT || !is_null_value(x) { return false; }
    }
    return true;
}

// Value::dropDroppableUse(U) for an llvm.assume user.
fn m2r_drop_droppable_use(u: i32) {
    let us = use_user(u);
    if call_iid(us) != IID_assume { fatal("mem2reg: unknown droppable use"); }
    let opno = (u - vals[us].ops) as i64;
    if opno == 0 { use_set(u, c_true()); return; }
    use_set(u, c_poison(vals[uses[u].val].ty));
    for k in cb_nbundles(us) {
        let b = cb_bundle_begin(us, k);
        if opno >= b && opno < b + cb_bundle_count(us, k) {
            ints[insts[inst_of(us)].aux + 2 + 3 * k] = intern("ignore");
            return;
        }
    }
    fatal("mem2reg: droppable use is not a bundle operand");
}

fn m2r_remove_intrinsic_users(ai: i32) {
    var u = first_use(ai);
    while u >= 0 {
        let nu = use_next(u);
        let i = use_user(u);
        let o = iop(i);
        if o == OP_LOAD || o == OP_STORE { u = nu; continue; }
        if m2r_is_droppable(i) { m2r_drop_droppable_use(u); u = nu; continue; }
        if vals[i].ty != T_VOID {
            var uu = first_use(i);
            while uu >= 0 {
                let nuu = use_next(uu);
                let inst = use_user(uu);
                if m2r_is_droppable(inst) { m2r_drop_droppable_use(uu); }
                else {
                    // the erased user may hold a later use of i: re-read the list head when that happens
                    m2r_erase(inst);
                }
                uu = nuu;
            }
        }
        // erasing i can unlink the next use of ai only if i uses ai twice; re-read like make_early_inc_range
        m2r_erase(i);
        u = nu;
    }
}

// ---------------------------------------------------------------------------------------------
// Debug records (DbgVariableRecord) helpers

fn m2r_is_address_of_variable(r: i32) -> bool { dbgrecs[r].kind as i64 == DR_DECLARE }
fn m2r_is_value_of_variable(r: i32) -> bool { let k = dbgrecs[r].kind as i64; k == DR_VALUE }

// DIExpression::startsWithDeref / isDeref
fn diexpr_nelems(e: i32) -> i64 { if e < 0 { 0 } else { mds[e].nops as i64 } }
fn diexpr_elem(e: i32, k: i64) -> i64 { md_int_val(md_op(e, k)) }
let DW_OP_deref = 0x06;
let DW_OP_LLVM_fragment = 0x1000;
let DW_OP_LLVM_arg = 0x1005;
let DW_OP_LLVM_extract_bits_sext = 0x1006;
let DW_OP_LLVM_extract_bits_zext = 0x1007;

// DIExpression::getSingleLocationExpressionElements-based startsWithDeref
fn diexpr_starts_with_deref(e: i32) -> bool {
    let n = diexpr_nelems(e);
    var s: i64 = 0;
    if n >= 2 && diexpr_elem(e, 0) == DW_OP_LLVM_arg {
        // isSingleLocationExpression: DW_OP_LLVM_arg 0 is the only arg
        s = 2;
    }
    return n > s && diexpr_elem(e, s) == DW_OP_deref;
}
// DIExpression::isDeref: the single-location elements are exactly { DW_OP_deref }.
fn diexpr_is_deref(e: i32) -> bool {
    let n = diexpr_nelems(e);
    if n == 1 { return diexpr_elem(e, 0) == DW_OP_deref; }
    if n == 3 && diexpr_elem(e, 0) == DW_OP_LLVM_arg && diexpr_elem(e, 1) == 0 { return diexpr_elem(e, 2) == DW_OP_deref; }
    return false;
}

// DIVariable::getSizeInBits: -1 = unknown
fn divar_size_bits(var_: i32) -> i64 {
    var t = di_slot(var_, "type");
    while t >= 0 && mds[t].kind == MK_DI {
        let k = di_kind(t);
        let is_type = k == DIK_BASICTYPE || k == DIK_DERIVEDTYPE || k == DIK_COMPOSITETYPE || k == DIK_SUBROUTINETYPE ||
            k == DIK_STRINGTYPE || k == DIK_FIXEDPOINTTYPE || k == DIK_SUBRANGETYPE;
        if !is_type { break; }
        if k == DIK_SUBROUTINETYPE { break; }      // size 0, not derived
        let sz = di_slot(t, "size");
        if sz >= 0 {
            // DIType::getSizeInBits: an integer, or ConstantAsMetadata(ConstantInt); other metadata = 0
            var s: i64 = 0;
            if mds[sz].kind == MK_INTLIT { s = md_int_val(sz); }
            else if mds[sz].kind == MK_VALUE && vals[mds[sz].extra].kind == VK_CINT { s = csts[vals[mds[sz].extra].sub].lo as! i64; }
            if s != 0 { return s; }
        }
        if k == DIK_DERIVEDTYPE { t = di_slot(t, "baseType"); continue; }
        break;
    }
    return -1;
}

// DIExpression::getActiveBits(Var): -1 = unknown
fn diexpr_active_bits(e: i32, var_: i32) -> i64 {
    let init = divar_size_bits(var_);
    var active = init;
    let n = diexpr_nelems(e);
    var k: i64 = 0;
    while k < n {
        let o = diexpr_elem(e, k);
        if o == DW_OP_LLVM_extract_bits_zext || o == DW_OP_LLVM_extract_bits_sext {
            fatal("mem2reg: DIExpression::getActiveBits with DW_OP_LLVM_extract_bits is not ported");
        } else if o == DW_OP_LLVM_fragment {
            let sz = diexpr_elem(e, k + 2);
            if active >= 0 { active = min(active, sz); } else { active = sz; }
        } else {
            active = init;
        }
        k += diexpr_op_size(o);
    }
    return active;
}

// valueCoversEntireFragment(ValTy, DVR)
fn m2r_value_covers_entire_fragment(ty: i32, r: i32) -> bool {
    let vsize = dl_alloc_size(ty) * 8;
    let fs = diexpr_active_bits(dbgrecs[r].expr, dbgrecs[r].dvar);
    if fs >= 0 { return vsize >= fs; }
    if m2r_is_address_of_variable(r) {
        let l = dbgrecs[r].loc;
        if l >= 0 && mds[l].kind == MK_VALUE {
            let ai = mds[l].extra;
            if is_inst(ai) && iop(ai) == OP_ALLOCA {
                // AllocaInst::getAllocationSizeInBits: constant array size only
                let n = op(ai, 0);
                if vals[n].kind != VK_CINT { return false; }
                let cnt = csts[vals[n].sub].lo as! i64;
                return vsize >= dl_alloc_size(insts[inst_of(ai)].ty2) * 8 * cnt;
            }
        }
    }
    return false;
}

// getDebugValueLoc(DVR): DILocation(line 0, column 0, scope, inlinedAt of the declare's location)
fn m2r_debug_value_loc(r: i32) -> i32 {
    let dl = dbgrecs[r].dl;
    if dl < 0 { return -1; }
    let scope = di_slot(dl, "scope");
    let ia = di_slot(dl, "inlinedAt");
    var slots: i32[7] = [-1, -1, -1, -1, -1, -1, -1];
    slots[di_field_index(DIK_LOCATION, "scope")] = scope;
    slots[di_field_index(DIK_LOCATION, "inlinedAt")] = ia;
    return md_get(MK_DI, DIK_LOCATION as i32, slots, false);
}

// new DbgVariableRecord(ValueAsMetadata::get(V), Var, Expr, Loc), appended to `before`'s records.
fn m2r_insert_dbg_value(v: i32, var_: i32, expr: i32, loc: i32, before: i32) -> i32 {
    let r = new_dbgrec(DR_VALUE);
    dbgrecs[r].loc = md_value(v);
    dbgrecs[r].dvar = var_;
    dbgrecs[r].expr = expr;
    dbgrecs[r].dl = loc;
    inst_add_dbg(before, r);
    m2r_recs.push(r);
    if !is_constant(v) { vs_add(VS_PASS1, v); }
    return r;
}

// ConvertDebugDeclareToDebugValue(DVR, StoreInst *SI)
fn m2r_convert_declare_at_store(r: i32, si: i32) {
    if dbgrecs[r].kind as i64 == DR_ASSIGN { m2r_not_ported("assignment tracking (dbg_assign)"); }
    let dvar = dbgrecs[r].dvar;
    let expr = dbgrecs[r].expr;
    let dv = op(si, 0);
    let nl = m2r_debug_value_loc(r);
    let can = diexpr_is_deref(expr) || (!diexpr_starts_with_deref(expr) && m2r_value_covers_entire_fragment(vals[dv].ty, r));
    if can { m2r_insert_dbg_value(dv, dvar, expr, nl, si); return; }
    m2r_insert_dbg_value(c_poison(vals[dv].ty), dvar, expr, nl, si);
}

// InsertDebugValueAtStoreLoc(DVR, SI)
fn m2r_insert_debug_value_at_store_loc(r: i32, si: i32) {
    let e = dbgrecs[r].expr;
    let drop: i64 = if diexpr_elem(e, 0) == DW_OP_LLVM_arg { 3 } else { 1 };
    var els: i32[>..<] = [];
    for k in drop..diexpr_nelems(e) { els.push(md_op(e, k)); }
    let ne = md_get(MK_DIEXPR, -1, els, false);
    let nl = m2r_debug_value_loc(r);
    m2r_insert_dbg_value(op(si, 0), dbgrecs[r].dvar, ne, nl, si);
}

// The records mem2reg itself attached to new PHIs (findDbgValues(APN) can only find these).
var m2r_phi_dbg: i32[>..<];      // pairs (phi, record)

// ConvertDebugDeclareToDebugValue(DVR, PHINode *APN)
fn m2r_convert_declare_at_phi(r: i32, p: i32) {
    if dbgrecs[r].kind as i64 == DR_ASSIGN { m2r_not_ported("assignment tracking (dbg_assign)"); }
    let dvar = dbgrecs[r].dvar;
    let expr = dbgrecs[r].expr;
    // PhiHasDebugValue
    var k: i64 = 0;
    while k < m2r_phi_dbg.len {
        if m2r_phi_dbg[k] == p {
            let x = m2r_phi_dbg[k + 1];
            if dbgrecs[x].dvar == dvar && dbgrecs[x].expr == expr { return; }
        }
        k += 2;
    }
    if !m2r_value_covers_entire_fragment(vals[p].ty, r) { return; }
    let bb = inst_parent(p);
    // getFirstInsertionPt: first non-PHI, skipping EH pads
    let ip = first_non_phi(bb);
    if ip < 0 { return; }
    if inst_is_eh_pad(ip) {
        if iop(ip) == OP_CATCHSWITCH { return; }
        m2r_not_ported("debug value insertion after an EH pad");
    }
    let nl = m2r_debug_value_loc(r);
    let nr = m2r_insert_dbg_value(p, dvar, expr, nl, ip);
    m2r_phi_dbg.push(p);
    m2r_phi_dbg.push(nr);
}

// Debug records of the function being processed (collected once per mem2reg run, plus the ones we create),
// and VS_PASS1 = the values some record's location mentions. LLVM keeps these links in ValueAsMetadata;
// here they make findDbgUsers, ValueAsMetadata::handleRAUW and handleDeletion cost nothing for values no
// record mentions.
var m2r_recs: i32[>..<];

fn m2r_md_note_values(m: i32) {
    if m < 0 { return; }
    if mds[m].kind == MK_VALUE { vs_add(VS_PASS1, mds[m].extra); return; }
    if mds[m].kind == MK_DIARGLIST {
        for k in mds[m].nops { let o = md_op(m, k); if o >= 0 && mds[o].kind == MK_VALUE { vs_add(VS_PASS1, mds[o].extra); } }
    }
}
fn m2r_collect_records(fv: i32) {
    m2r_recs.clear();
    vs_clear(VS_PASS1);
    if dbgrecs.len == 0 { return; }
    var b = func_first_block(fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            var r = inst_first_dbg(i);
            while r >= 0 {
                if dbgrecs[r].kind as i64 != DR_LABEL {
                    m2r_recs.push(r);
                    m2r_md_note_values(dbgrecs[r].loc);
                    m2r_md_note_values(dbgrecs[r].addr);
                }
                r = dbgrecs[r].next;
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
}

// findDbgUsers(V): records whose location mentions V, in instruction order.
fn m2r_find_dbg_users(v: i32, out: i32[>..<]&) {
    if !vs_has(VS_PASS1, v) { return; }
    for r in m2r_recs {
        if dbgrecs[r].owner >= 0 && (md_mentions_value(dbgrecs[r].loc, v) || md_mentions_value(dbgrecs[r].addr, v)) { out.push(r); }
    }
}

// The location metadata m with every mention of `old` replaced by `nw`.
fn m2r_md_replace_value(m: i32, old: i32, nw: i32) -> i32 {
    if m < 0 { return m; }
    if mds[m].kind == MK_VALUE { return if mds[m].extra == old { md_value(nw) } else { m }; }
    if mds[m].kind == MK_DIARGLIST {
        var ops: i32[>..<] = [];
        var changed = false;
        for k in mds[m].nops {
            let o = md_op(m, k);
            if o >= 0 && mds[o].kind == MK_VALUE && mds[o].extra == old { ops.push(md_value(nw)); changed = true; }
            else { ops.push(o); }
        }
        if !changed { return m; }
        return md_get(MK_DIARGLIST, -1, ops, false);
    }
    return m;
}

// ValueAsMetadata::handleRAUW(old, nw) for debug-record locations.
fn m2r_dbg_rauw(old: i32, nw: i32) {
    if !vs_has(VS_PASS1, old) { return; }
    for r in m2r_recs {
        if dbgrecs[r].owner < 0 { continue; }
        dbgrecs[r].loc = m2r_md_replace_value(dbgrecs[r].loc, old, nw);
        dbgrecs[r].addr = m2r_md_replace_value(dbgrecs[r].addr, old, nw);
    }
    vs_del(VS_PASS1, old);
    if !is_constant(nw) { vs_add(VS_PASS1, nw); }
}

// Instruction::eraseFromParent: the value's ValueAsMetadata is deleted, and debug records that used it get
// poison (ValueAsMetadata::handleDeletion, DebugValueUser::handleChangedValue). No salvaging here.
fn m2r_erase(iv: i32) {
    if vals[iv].first_use >= 0 { fatal("internal: mem2reg: erasing an instruction that still has uses"); }
    if dbgrecs.len > 0 {
        m2r_dbg_rauw(iv, c_poison(vals[iv].ty));
        dbg_records_to_next(iv);
    }
    inst_remove_from_parent(iv);
    drop_all_refs(iv);
    val_set_dead(iv);
}

// DILocalScope::getSubprogram
fn di_scope_subprogram(sc0: i32) -> i32 {
    var sc = sc0;
    while sc >= 0 && mds[sc].kind == MK_DI {
        let k = di_kind(sc);
        if k == DIK_SUBPROGRAM { return sc; }
        if k != DIK_LEXICALBLOCK && k != DIK_LEXICALBLOCKFILE { return -1; }
        sc = di_slot(sc, "scope");
    }
    return -1;
}
// DIScope::getFile
fn di_scope_file(sc: i32) -> i32 { if sc < 0 { -1 } else { di_slot(sc, "file") } }

fn di_location_get(line: i64, col: i64, scope: i32, ia: i32, implicit: bool) -> i32 {
    var slots: i32[7] = [-1, -1, -1, -1, -1, -1, -1];
    if line != 0 { slots[0] = md_int(line); }
    if col != 0 { slots[1] = md_int(col); }
    slots[2] = scope;
    slots[3] = ia;
    if implicit { slots[4] = md_int(1); }
    return md_get(MK_DI, DIK_LOCATION as i32, slots, false);
}

// MergeLocPair inside DILocation::getMergedLocation (EqualScopesMatcher; same-file case).
fn m2r_merge_loc_pair(l1: i32, l2: i32, ia: i32) -> i32 {
    let s1 = di_slot(l1, "scope");
    let s2 = di_slot(l2, "scope");
    if l1 == l2 {
        if di_int(l1, "atomGroup") != 0 || di_int(l1, "atomRank") != 0 { m2r_not_ported("getMergedLocation with key-instruction atoms"); }
        return di_location_get(di_int(l1, "line"), di_int(l1, "column"), s1, ia, di_int(l1, "isImplicitCode") != 0);
    }
    if di_scope_subprogram(s1) != di_scope_subprogram(s2) { return -1; }
    // getNearestMatchingScope<EqualScopesMatcher>: first scope of L2's chain that is in L1's chain
    var scope: i32 = -1;
    var x = s2;
    while x >= 0 && scope < 0 {
        var y = s1;
        while y >= 0 {
            if y == x { scope = x; break; }
            if di_kind(y) == DIK_SUBPROGRAM { break; }
            y = di_slot(y, "scope");
        }
        if scope >= 0 || di_kind(x) == DIK_SUBPROGRAM { break; }
        x = di_slot(x, "scope");
    }
    if scope < 0 { fatal("internal: getMergedLocation: no common scope in the same subprogram"); }
    let f1 = di_scope_file(s1);
    if di_scope_file(scope) != f1 || f1 != di_scope_file(s2) { m2r_not_ported("getMergedLocation of locations in different files"); }
    let same_line = di_int(l1, "line") == di_int(l2, "line");
    let same_col = di_int(l1, "column") == di_int(l2, "column");
    let line = if same_line { di_int(l1, "line") } else { 0 };
    let col = if same_line && same_col { di_int(l1, "column") } else { 0 };
    let implicit = di_int(l1, "isImplicitCode") != 0 && di_int(l2, "isImplicitCode") != 0;
    if same_line && (di_int(l1, "atomGroup") != 0 || di_int(l2, "atomGroup") != 0) { m2r_not_ported("getMergedLocation with key-instruction atoms"); }
    return di_location_get(line, col, scope, ia, implicit);
}

// DebugLoc::getMergedLocation / DILocation::getMergedLocation
fn m2r_merged_location(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    var alocs: i32[>..<] = [];
    var x = a;
    while x >= 0 { alocs.push(x); x = di_slot(x, "inlinedAt"); }
    var blocs: i32[>..<] = [];
    var ai: i64 = -1;     // index in alocs of the matching starting location
    var bi: i64 = -1;
    x = b;
    while x >= 0 {
        blocs.push(x);
        let sp = di_scope_subprogram(di_slot(x, "scope"));
        let ia = di_slot(x, "inlinedAt");
        for k in alocs.len {
            if di_scope_subprogram(di_slot(alocs[k], "scope")) == sp && di_slot(alocs[k], "inlinedAt") == ia { ai = k; break; }
        }
        if ai >= 0 { bi = blocs.len - 1; break; }
        x = ia;
    }
    var result: i32 = if ai >= 0 { di_slot(alocs[ai], "inlinedAt") } else { -1 };
    while ai >= 0 && bi >= 0 {
        let t = m2r_merge_loc_pair(alocs[ai], blocs[bi], result);
        if t < 0 { break; }
        result = t;
        ai--; bi--;
    }
    if result >= 0 { return result; }
    return di_location_get(0, 0, di_slot(a, "scope"), -1, false);
}

// ---------------------------------------------------------------------------------------------
// DenseMap<std::pair<unsigned, unsigned>, PHINode *> (llvm/ADT/DenseMap.h, LLVM 23: linear probing,
// tombstone-free deletion, rehash in place after remove_if).

var m2r_pm_key: i64[>..<];
var m2r_pm_val: i32[>..<];
var m2r_pm_used: bool[>..<];
var m2r_pm_count: i64 = 0;

fn m2r_pm_hash(key: i64) -> u64 {
    let a = ((key >> 32) as! u64) & 0xFFFFFFFF;
    let b = (key as! u64) & 0xFFFFFFFF;
    let ha = (a * 37) & 0xFFFFFFFF;
    let hb = (b * 37) & 0xFFFFFFFF;
    var x = (ha << 32) | hb;
    x = x * 0xbf58476d1ce4e5b9;
    x = x ^ (x >> 31);
    return x & 0xFFFFFFFF;
}
fn m2r_pm_reset() { m2r_pm_key.clear(); m2r_pm_val.clear(); m2r_pm_used.clear(); m2r_pm_count = 0; }
fn m2r_pm_nb() -> i64 { m2r_pm_key.len }
// LookupBucketFor: (found, bucket)
fn m2r_pm_lookup(key: i64) -> bool, i64 {
    let nb = m2r_pm_nb();
    if nb == 0 { return false, -1; }
    let mask = (nb - 1) as! u64;
    var b = (m2r_pm_hash(key) & mask) as! i64;
    loop {
        if !m2r_pm_used[b] { return false, b; }
        if m2r_pm_key[b] == key { return true, b; }
        b = (((b + 1) as! u64) & mask) as! i64;
    }
    return false, -1;
}
// grow(MinNumBuckets): rehash every used bucket, in bucket order, into a table of the new size.
fn m2r_pm_grow(min_buckets: i64) {
    var nbk: i64 = 64;
    while nbk < min_buckets { nbk *= 2; }
    var ok: i64[>..<] = [];
    var ov: i32[>..<] = [];
    for b in m2r_pm_nb() { if m2r_pm_used[b] { ok.push(m2r_pm_key[b]); ov.push(m2r_pm_val[b]); } }
    m2r_pm_key.clear(); m2r_pm_val.clear(); m2r_pm_used.clear();
    m2r_pm_key.resize(nbk, 0); m2r_pm_val.resize(nbk, -1); m2r_pm_used.resize(nbk, false);
    let mask = (nbk - 1) as! u64;
    for k in ok.len {
        var b = (m2r_pm_hash(ok[k]) & mask) as! i64;
        while m2r_pm_used[b] { b = (((b + 1) as! u64) & mask) as! i64; }
        m2r_pm_used[b] = true; m2r_pm_key[b] = ok[k]; m2r_pm_val[b] = ov[k];
    }
}
// operator[]: bucket index of key, inserted (value -1) if missing.
fn m2r_pm_slot(key: i64) -> i64 {
    var found, b = m2r_pm_lookup(key);
    if found { return b; }
    let nb = m2r_pm_nb();
    if (m2r_pm_count + 1) * 4 >= nb * 3 {
        m2r_pm_grow(nb * 2);
        found, b = m2r_pm_lookup(key);
    }
    m2r_pm_used[b] = true;
    m2r_pm_key[b] = key;
    m2r_pm_val[b] = -1;
    m2r_pm_count++;
    return b;
}

// ---------------------------------------------------------------------------------------------
// Block-keyed scratch (BasicBlock numbers are dense per function; tables indexed by block index).

var m2r_bstamp: i32[>..];
var m2r_bdata: i32[>..];
var m2r_bepoch: i32[8] = [1, 1, 1, 1, 1, 1, 1, 1];
let MB_VISITED = 0;     // RenamePass Visited
let MB_NPREDS = 1;      // BBNumPreds (data = count)
let MB_DEF = 2;         // DefBlocks
let MB_LIVE = 3;        // LiveInBlocks
let MB_VPQ = 4;         // IDF VisitedPQ
let MB_VWL = 5;         // IDF VisitedWorklist
let MB_SUCC = 6;        // RenamePass VisitedSuccs
let MB_UBVIS = 7;       // programUndefinedIfUndefOrPoison Visited
let MB_N = 8;

fn mb_clear(s: i64) { m2r_bepoch[s] += 1; }
fn mb_has(s: i64, bv: i32) -> bool {
    let k = (block_of(bv) as i64) * MB_N + s;
    return k < m2r_bstamp.len && m2r_bstamp[k] == m2r_bepoch[s];
}
fn mb_add(s: i64, bv: i32) -> bool {
    let k = (block_of(bv) as i64) * MB_N + s;
    if k >= m2r_bstamp.len {
        let want = (blocks.len as i64) * MB_N;
        while m2r_bstamp.len < want { m2r_bstamp.push(0); m2r_bdata.push(0); }
    }
    if m2r_bstamp[k] == m2r_bepoch[s] { return false; }
    m2r_bstamp[k] = m2r_bepoch[s];
    return true;
}
fn mb_get(s: i64, bv: i32) -> i32 { m2r_bdata[(block_of(bv) as i64) * MB_N + s] }
fn mb_set(s: i64, bv: i32, x: i32) { mb_add(s, bv); m2r_bdata[(block_of(bv) as i64) * MB_N + s] = x; }

// ---------------------------------------------------------------------------------------------
// The pass

// convertMetadataToAssumes(LI, Val, DL, AC, DT)
fn m2r_convert_metadata_to_assumes(li: i32, v: i32) {
    let k_noundef = md_kind_id("noundef");
    if is_undef_or_poison(v) && inst_get_md(li, k_noundef) >= 0 {
        // store i1 true, ptr poison (a non-terminator unreachable), before LI
        let st = create_inst(OP_STORE, T_VOID, [c_true(), c_poison(ty_ptr(0))]);
        insts[inst_of(st)].align = 1;
        m2r_insert_before_adopting(st, li);
        return;
    }
    if inst_get_md(li, md_kind_id("nonnull")) >= 0 && inst_get_md(li, k_noundef) >= 0 && !m2r_known_non_zero(v, li) {
        // addAssumeNonNull
        let assume = au_get_declaration(IID_assume, []);
        let cmp = create_inst(OP_ICMP, T_I1, [li, c_null(vals[li].ty)]);
        insts[inst_of(cmp)].pred = 33;
        m2r_insert_after(cmp, li);
        let ci = create_inst(OP_CALL, T_VOID, [cmp, assume]);
        insts[inst_of(ci)].ty2 = globs[glob_of(assume)].vty;
        m2r_insert_after(ci, cmp);
    }
}

// Instruction::insertBefore(BB, It) with It not at the head: the new instruction adopts the debug records
// that were attached to the position.
fn m2r_insert_before_adopting(iv: i32, pos: i32) {
    inst_insert_before(iv, pos);
    let pi = inst_of(pos);
    if pi < inst_dbg.len && inst_dbg[pi] >= 0 {
        let ni = inst_of(iv);
        while inst_dbg.len <= ni { inst_dbg.push(-1); }
        inst_dbg[ni] = inst_dbg[pi];
        inst_dbg[pi] = -1;
        var r = inst_dbg[ni];
        while r >= 0 { dbgrecs[r].owner = iv; r = dbgrecs[r].next; }
    }
}
// Instruction::insertAfter(It): inserted before std::next(It) (not at the head of its records).
fn m2r_insert_after(iv: i32, pos: i32) {
    let n = inst_next(pos);
    if n >= 0 { m2r_insert_before_adopting(iv, n); } else { block_append_inst(inst_parent(pos), iv); }
}

// LargeBlockInfo::isInterestingInstruction
fn m2r_interesting(i: i32) -> bool {
    let o = iop(i);
    if o == OP_LOAD { let p = op(i, 0); return is_inst(p) && iop(p) == OP_ALLOCA; }
    if o == OP_STORE { let p = op(i, 1); return is_inst(p) && iop(p) == OP_ALLOCA; }
    return false;
}
// LargeBlockInfo::getInstructionIndex (map in VM_PASS1, never cleared within one PromoteMemToReg; LLVM's
// deleteValue only drops dead entries, and our ids are never reused).
fn m2r_inst_index(i: i32) -> i64 {
    if vm_has(VM_PASS1, i) { return vm_get(VM_PASS1, i, 0); }
    var n: i64 = 0;
    var x = block_first(inst_parent(i));
    while x >= 0 {
        if m2r_interesting(x) { vm_set(VM_PASS1, x, n); n++; }
        x = inst_next(x);
    }
    return vm_get(VM_PASS1, i, 0);
}

// RAUW of a load that debug records may still refer to.
fn m2r_replace_load(li: i32, v: i32) {
    if dbgrecs.len > 0 { m2r_dbg_rauw(li, v); }
    rauw(li, v);
    m2r_erase(li);
}

fn m2r_erase_record(r: i32) { dbg_erase_record(r); }

// PromoteMemToReg(Allocas, DT, AC)
fn promote_mem_to_reg(fv: i32, allocas: i32[>..<]&) {
    if allocas.len == 0 { return; }
    let no_signed_zeros = func_str_attr_is_true(fv, "no-signed-zeros-fp-math");

    var avals: i32[>..<] = [];       // AllocaValueTypes
    var dpu_at: i32[>..<] = [];      // AllocaDPUsers: run in dpu_pool (start, count)
    var dpu_n: i32[>..<] = [];
    var dpu_pool: i32[>..<] = [];
    avals.resize(allocas.len, -1);
    dpu_at.resize(allocas.len, 0);
    dpu_n.resize(allocas.len, 0);

    // AllocaInfo
    var def_blocks: i32[>..<] = [];
    var using_blocks: i32[>..<] = [];
    var only_store: i32 = -1;
    var only_block: i32 = -1;
    var only_one_block = true;
    var value_type: i32 = -1;
    var dpusers: i32[>..<] = [];

    vm_clear(VM_PASS0);      // AllocaLookup
    vm_clear(VM_PASS1);      // LargeBlockInfo
    vs_clear(VS_PASS0);      // PhiToAllocaMap membership (value in VM? no: phi -> alloca index in vm below)
    mb_clear(MB_NPREDS);
    m2r_pm_reset();
    m2r_phi_dbg.clear();

    fn analyze_alloca(ai: i32) {
        def_blocks.clear(); using_blocks.clear();
        only_store = -1; only_block = -1; only_one_block = true; value_type = -1;
        dpusers.clear();
        var u = first_use(ai);
        while u >= 0 {
            let us = use_user(u);
            if iop(us) == OP_STORE {
                def_blocks.push(inst_parent(us));
                only_store = us;
                if value_type < 0 { value_type = vals[op(us, 0)].ty; }
            } else {
                using_blocks.push(inst_parent(us));
                if value_type < 0 { value_type = vals[us].ty; }
            }
            if only_one_block {
                if only_block < 0 { only_block = inst_parent(us); }
                else if only_block != inst_parent(us) { only_one_block = false; }
            }
            u = use_next(u);
        }
        if dbgrecs.len > 0 {
            var all: i32[>..<] = [];
            m2r_find_dbg_users(ai, all);
            for r in all {
                if dbgrecs[r].kind as i64 == DR_ASSIGN { m2r_not_ported("assignment tracking (dbg_assign)"); }
                dpusers.push(r);
            }
            // at::getDVRAssignmentMarkers(AI): DIAssignID attachments
            if inst_get_md(ai, md_kind_id("DIAssignID")) >= 0 { m2r_not_ported("assignment tracking (DIAssignID)"); }
        }
    }

    fn num_preds(bv: i32) -> i64 {
        if mb_has(MB_NPREDS, bv) { return mb_get(MB_NPREDS, bv) as i64; }
        let n = pred_count(bv);
        mb_set(MB_NPREDS, bv, n as i32);
        return n;
    }

    // rewriteSingleStoreAlloca
    fn rewrite_single_store(ai: i32) -> bool {
        let os = only_store;
        var repl = op(os, 0);
        let require_dom = is_inst(repl) || !m2r_not_poison(repl);
        let store_bb = inst_parent(os);
        var store_index: i64 = -1;
        using_blocks.clear();
        var u = first_use(ai);
        while u >= 0 {
            let nu = use_next(u);
            let us = use_user(u);
            if us == os { u = nu; continue; }
            let li = us;
            if require_dom {
                if inst_parent(li) == store_bb {
                    if store_index == -1 { store_index = m2r_inst_index(os); }
                    if store_index > m2r_inst_index(li) {
                        using_blocks.push(store_bb);
                        u = nu;
                        continue;
                    }
                } else if !dt_dominates_block(DT_DOM, store_bb, inst_parent(li)) {
                    using_blocks.push(inst_parent(li));
                    u = nu;
                    continue;
                }
            }
            if repl == li { repl = c_poison(vals[li].ty); }
            m2r_convert_metadata_to_assumes(li, repl);
            m2r_replace_load(li, repl);
            u = nu;
        }
        if using_blocks.len > 0 { return false; }
        for r in dpusers {
            let e = dbgrecs[r].expr;
            if m2r_is_address_of_variable(r) {
                m2r_convert_declare_at_store(r, os);
                m2r_erase_record(r);
            } else if m2r_is_value_of_variable(r) && diexpr_starts_with_deref(e) {
                m2r_insert_debug_value_at_store_loc(r, os);
                m2r_erase_record(r);
            } else if diexpr_starts_with_deref(e) {
                m2r_erase_record(r);
            }
        }
        m2r_erase(os);
        if has_uses(ai) { fatal("internal: mem2reg: alloca still used after single-store promotion"); }
        m2r_erase(ai);
        return true;
    }

    // promoteSingleBlockAlloca
    fn promote_single_block(ai: i32) -> bool {
        var sidx: i64[>..<] = [];
        var sinst: i32[>..<] = [];
        var u = first_use(ai);
        while u >= 0 {
            let us = use_user(u);
            if iop(us) == OP_STORE { sidx.push(m2r_inst_index(us)); sinst.push(us); }
            u = use_next(u);
        }
        // llvm::sort(less_first): indices are distinct, so the order is total
        var perm: i64[>..<] = [];
        for k in sidx.len { perm.push(k); }
        sort(perm) { a, b => sidx[a] < sidx[b] };
        var ss_idx: i64[>..<] = [];
        var ss_inst: i32[>..<] = [];
        for k in perm { ss_idx.push(sidx[k]); ss_inst.push(sinst[k]); }
        u = first_use(ai);
        while u >= 0 {
            let nu = use_next(u);
            let li = use_user(u);
            if iop(li) != OP_LOAD { u = nu; continue; }
            let lidx = m2r_inst_index(li);
            // lower_bound on (LoadIdx, nullptr) with less_first
            var lo: i64 = 0;
            var hi = ss_idx.len;
            while lo < hi { let mid = (lo + hi) / 2; if ss_idx[mid] < lidx { lo = mid + 1; } else { hi = mid; } }
            var repl: i32 = -1;
            if lo == 0 {
                if ss_idx.len == 0 { repl = c_undef(vals[li].ty); }
                else { return false; }
            } else {
                repl = op(ss_inst[lo - 1], 0);
            }
            m2r_convert_metadata_to_assumes(li, repl);
            if repl == li { repl = c_poison(vals[li].ty); }
            m2r_replace_load(li, repl);
            u = nu;
        }
        while has_uses(ai) {
            // AI->user_back(): the last use in the use list
            var lu = first_use(ai);
            while use_next(lu) >= 0 { lu = use_next(lu); }
            let si = use_user(lu);
            for r in dpusers { if m2r_is_address_of_variable(r) { m2r_convert_declare_at_store(r, si); } }
            m2r_erase(si);
        }
        m2r_erase(ai);
        for r in dpusers {
            if m2r_is_address_of_variable(r) || diexpr_starts_with_deref(dbgrecs[r].expr) { m2r_erase_record(r); }
        }
        return true;
    }

    // ComputeLiveInBlocks
    fn compute_live_in(ai: i32, live: i32[>..<]&) {
        var wl: i32[>..<] = [];
        for b in using_blocks { wl.push(b); }
        var i: i64 = 0;
        var e = wl.len;
        while i < e {
            let bb = wl[i];
            if !mb_has(MB_DEF, bb) { i++; continue; }
            var x = block_first(bb);
            var removed = false;
            while x >= 0 {
                let o = iop(x);
                if o == OP_STORE {
                    if op(x, 1) == ai {
                        wl[i] = wl[wl.len - 1];
                        wl.pop();
                        e--;
                        removed = true;
                        break;
                    }
                } else if o == OP_LOAD {
                    if op(x, 0) == ai { break; }
                }
                x = inst_next(x);
            }
            if !removed { i++; }
        }
        mb_clear(MB_LIVE);
        while wl.len > 0 {
            let bb = wl.pop();
            if !mb_add(MB_LIVE, bb) { continue; }
            live.push(bb);
            each_pred(bb) { p =>
                if !mb_has(MB_DEF, p) { wl.push(p); }
            };
        }
    }

    // ForwardIDFCalculator::calculate with live-in pruning. MB_DEF / MB_LIVE hold the sets.
    fn idf_calculate(defs: const i32[:], out: i32[>..<]&) {
        mb_clear(MB_VPQ);
        mb_clear(MB_VWL);
        // std::priority_queue (max-heap) on (level, DFSNumIn), as a min-heap of complemented keys
        dt_update_dfs_numbers(fv, DT_DOM);
        var pq: i64[>..<] = [];
        var pqb: i32[>..<] = [];
        fn pq_push(bv: i32) {
            let lvl = dt_level(DT_DOM, bv) as i64;
            let dfs = dt_dfs_in(fv, DT_DOM, bv) as i64;
            let idx = pqb.len as i64;
            if lvl >= (1 << 20) || dfs >= (1 << 21) || idx >= (1 << 21) { fatal("mem2reg: function too large for the IDF priority key"); }
            pqb.push(bv);
            heap_push(pq, (((1 << 20) - 1 - lvl) << 42) | (((1 << 21) - 1 - dfs) << 21) | idx);
        }
        for bb in defs {
            if dt_has_node(DT_DOM, bb) { pq_push(bb); mb_add(MB_VWL, bb); }
        }
        var wl: i32[>..<] = [];
        while pq.len > 0 {
            let top = heap_pop(pq);
            let root = pqb[top & 0x1FFFFF];
            let root_level = dt_level(DT_DOM, root);
            wl.push(root);
            while wl.len > 0 {
                let n = wl.pop();
                let t = block_terminator(n);
                if t >= 0 {
                    for k in term_nsucc(t) {
                        let s = term_succ(t, k);
                        if dt_level(DT_DOM, s) > root_level { continue; }
                        if !mb_add(MB_VPQ, s) { continue; }
                        if !mb_has(MB_LIVE, s) { continue; }
                        out.push(s);
                        if !mb_has(MB_DEF, s) { pq_push(s); }
                    }
                }
                var c = dt_first_child(fv, DT_DOM, n);
                while c >= 0 {
                    if mb_add(MB_VWL, c) { wl.push(c); }
                    c = dt_next_sibling(DT_DOM, c);
                }
            }
        }
    }

    // QueuePhiNode
    var cur_version: i64 = 0;
    fn queue_phi(bb: i32, ano: i64) -> bool {
        let key = ((block_number(bb) as i64) << 32) | ano;
        let slot = m2r_pm_slot(key);
        if m2r_pm_val[slot] >= 0 { return false; }
        let reserve = num_preds(bb);
        let pn = new_inst(OP_PHI, avals[ano], reserve);
        vals[pn].nops = 0;
        let f = block_first(bb);
        inst_insert_before(pn, f);
        var nm: u8[>..] = [];
        nm.append(val_name(allocas[ano]));
        nm.append(".");
        nm.append(str(cur_version));
        cur_version++;
        set_name(pn, nm);
        // the slot index can move if the map grew: look it up again
        let slot2 = m2r_pm_slot(key);
        m2r_pm_val[slot2] = pn;
        vm_set(VM_PASS0, pn, ano);    // PhiToAllocaMap (phis and allocas are distinct ids)
        vs_add(VS_PASS0, pn);
        return true;
    }

    // run()
    var an: i64 = 0;
    while an < allocas.len {
        let ai = allocas[an];
        m2r_remove_intrinsic_users(ai);
        if !has_uses(ai) {
            m2r_erase(ai);
            allocas[an] = allocas[allocas.len - 1];
            allocas.pop();
            continue;
        }
        analyze_alloca(ai);
        if def_blocks.len == 1 {
            if rewrite_single_store(ai) {
                allocas[an] = allocas[allocas.len - 1];
                allocas.pop();
                continue;
            }
        }
        if only_one_block && promote_single_block(ai) {
            allocas[an] = allocas[allocas.len - 1];
            allocas.pop();
            continue;
        }
        if dpusers.len > 0 {
            dpu_at[an] = dpu_pool.len as i32;
            dpu_n[an] = dpusers.len as i32;
            for r in dpusers { dpu_pool.push(r); }
        }
        avals[an] = value_type;
        vm_set(VM_PASS0, ai, an);
        mb_clear(MB_DEF);
        var defs: i32[>..<] = [];
        for b in def_blocks { if mb_add(MB_DEF, b) { defs.push(b); } }
        var live: i32[>..<] = [];
        compute_live_in(ai, live);
        var phib: i32[>..<] = [];
        idf_calculate(defs, phib);
        sort(phib) { a, b => block_number(a) < block_number(b) };
        cur_version = 0;
        for bb in phib { queue_phi(bb, an); }
        an++;
    }
    if allocas.len == 0 { return; }

    // IncomingVals / IncomingLocs with undo logs
    var inc_vals: i32[>..<] = [];
    var inc_locs: i32[>..<] = [];
    var undo_vi: i32[>..<] = [];     // (index, old value) pairs
    var undo_li: i32[>..<] = [];
    for k in allocas.len { inc_vals.push(c_undef(avals[k])); inc_locs.push(-1); }
    fn set_val(k: i64, v: i32) { if inc_vals[k] == v { return; } undo_vi.push(k as i32); undo_vi.push(inc_vals[k]); inc_vals[k] = v; }
    fn set_loc(k: i64, v: i32) { if inc_locs[k] == v { return; } undo_li.push(k as i32); undo_li.push(inc_locs[k]); inc_locs[k] = v; }

    mb_clear(MB_VISITED);
    // Worklist of RenamePassData (BB, Pred, UndoVals, UndoLocs)
    var wl_bb: i32[>..<] = [];
    var wl_pred: i32[>..<] = [];
    var wl_uv: i64[>..<] = [];
    var wl_ul: i64[>..<] = [];
    fn push_wl(bb: i32, pred: i32) { wl_bb.push(bb); wl_pred.push(pred); wl_uv.push(undo_vi.len); wl_ul.push(undo_li.len); }

    fn rename_pass(bb: i32, pred: i32) {
        var apn = block_first(bb);
        if apn >= 0 && iop(apn) == OP_PHI && vs_has(VS_PASS0, apn) {
            let new_phi_nops = nops(apn);
            var nedges: i64 = 0;
            let pt = block_terminator(pred);
            for k in term_nsucc(pt) { if term_succ(pt, k) == bb { nedges++; } }
            loop {
                let ano = vm_get(VM_PASS0, apn, 0);    // PhiToAllocaMap[APN] (default 0, like operator[])
                // updateForIncomingValueLocation
                let dl = inc_locs[ano];
                if nops(apn) > 0 {
                    let m = m2r_merged_location(inst_get_md(apn, 0), dl);
                    m2r_set_dl(apn, m);
                } else {
                    m2r_set_dl(apn, dl);
                }
                for e in nedges { phi_add_incoming(apn, inc_vals[ano], pred); }
                if no_signed_zeros && is_fp_math_operator(apn) { insts[inst_of(apn)].fmf |= FMF_NSZ; }
                set_val(ano, apn);
                for k in dpu_n[ano] {
                    let r = dpu_pool[dpu_at[ano] + k];
                    if m2r_is_address_of_variable(r) { m2r_convert_declare_at_phi(r, apn); }
                }
                apn = inst_next(apn);
                if apn < 0 || iop(apn) != OP_PHI { break; }
                if nops(apn) != new_phi_nops { break; }
            }
        }
        if !mb_add(MB_VISITED, bb) { return; }
        var i = block_first(bb);
        while i >= 0 && !is_terminator(i) {
            let ni = inst_next(i);
            let o = iop(i);
            if o == OP_LOAD {
                let src = op(i, 0);
                if is_inst(src) && iop(src) == OP_ALLOCA && vm_has(VM_PASS0, src) {
                    let v = inc_vals[vm_get(VM_PASS0, src, 0)];
                    m2r_convert_metadata_to_assumes(i, v);
                    m2r_replace_load(i, v);
                }
            } else if o == OP_STORE {
                let dst = op(i, 1);
                if is_inst(dst) && iop(dst) == OP_ALLOCA && vm_has(VM_PASS0, dst) {
                    let ano = vm_get(VM_PASS0, dst, 0);
                    set_val(ano, op(i, 0));
                    set_loc(ano, inst_get_md(i, 0));
                    for k in dpu_n[ano] {
                        let r = dpu_pool[dpu_at[ano] + k];
                        if m2r_is_address_of_variable(r) { m2r_convert_declare_at_store(r, i); }
                    }
                    m2r_erase(i);
                }
            }
            i = ni;
        }
        // successors in reverse, each once
        let t = block_terminator(bb);
        if t < 0 { return; }
        mb_clear(MB_SUCC);
        var k = term_nsucc(t);
        while k > 0 {
            k--;
            let s = term_succ(t, k);
            if mb_add(MB_SUCC, s) { push_wl(s, bb); }
        }
    }

    push_wl(func_entry(fv), -1);
    while wl_bb.len > 0 {
        let bb = wl_bb.pop();
        let pred = wl_pred.pop();
        let uv = wl_uv.pop();
        let ul = wl_ul.pop();
        while undo_vi.len > uv { let old = undo_vi.pop(); let idx = undo_vi.pop(); inc_vals[idx] = old; }
        while undo_li.len > ul { let old = undo_li.pop(); let idx = undo_li.pop(); inc_locs[idx] = old; }
        rename_pass(bb, pred);
    }

    for a in allocas {
        if has_uses(a) { if dbgrecs.len > 0 { m2r_dbg_rauw(a, c_poison(vals[a].ty)); } rauw(a, c_poison(vals[a].ty)); }
        m2r_erase(a);
    }
    for k in allocas.len {
        for j in dpu_n[k] {
            let r = dpu_pool[dpu_at[k] + j];
            if m2r_is_address_of_variable(r) || diexpr_starts_with_deref(dbgrecs[r].expr) { m2r_erase_record(r); }
        }
    }
    // Note: AllocaDPUsers is indexed by the alloca number at the time it was recorded, as in LLVM.

    // Eliminate PHIs that simplify (NewPhiNodes.remove_if, repeated until nothing changes).
    var eliminated = true;
    while eliminated {
        eliminated = false;
        let nb = m2r_pm_nb();
        for b in nb {
            if !m2r_pm_used[b] { continue; }
            let pn = m2r_pm_val[b];
            let v = m2r_simplify_phi(pn);
            if v >= 0 {
                if dbgrecs.len > 0 { m2r_dbg_rauw(pn, v); }
                rauw(pn, v);
                m2r_erase(pn);
                m2r_pm_used[b] = false;
                m2r_pm_count--;
                eliminated = true;
            }
        }
        if eliminated { m2r_pm_grow(nb); }
    }

    // Add poison incoming values for unreachable predecessors.
    for b in m2r_pm_nb() {
        if !m2r_pm_used[b] { continue; }
        var some = m2r_pm_val[b];
        let bb = inst_parent(some);
        if block_first(bb) != some { continue; }
        if nops(some) == num_preds(bb) { continue; }
        var preds: i32[>..<] = [];
        each_pred(bb) { p => preds.push(p); };
        sort(preds) { x, y => block_number(x) < block_number(y) };
        for k in nops(some) {
            let ib = phi_block(some, k);
            var lo: i64 = 0;
            var hi = preds.len;
            let n = block_number(ib);
            while lo < hi { let mid = (lo + hi) / 2; if block_number(preds[mid]) < n { lo = mid + 1; } else { hi = mid; } }
            if lo >= preds.len || preds[lo] != ib { fatal("internal: mem2reg: PHI has an entry for a non-predecessor"); }
            remove_at(preds, lo);
        }
        let nbad = nops(some);
        var x = block_first(bb);
        while x >= 0 && iop(x) == OP_PHI && nops(x) == nbad {
            let pv = c_poison(vals[x].ty);
            for p in preds { phi_add_incoming(x, pv, p); }
            x = inst_next(x);
        }
    }
}

fn m2r_set_dl(iv: i32, dl: i32) {
    if dl < 0 { inst_erase_md(iv, 0); } else { inst_set_md(iv, 0, dl); }
}

// Attribute::getValueAsBool of a function string attribute ("true").
fn func_str_attr_is_true(fv: i32, key: const u8[:]) -> bool {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    if a < 0 { return false; }
    return sbytes(attrs[a].sval) == "true";
}

// PromotePass::run (promoteMemoryToRegister)
fn mem2reg_run(fv: i32) -> u32 {
    dt_get(fv, DT_DOM);
    m2r_collect_records(fv);
    let entry = func_entry(fv);
    var changed = false;
    var allocas: i32[>..<] = [];
    loop {
        allocas.clear();
        var i = block_first(entry);
        let last = block_last(entry);
        while i >= 0 && i != last {
            if iop(i) == OP_ALLOCA && is_alloca_promotable(i) { allocas.push(i); }
            i = inst_next(i);
        }
        if allocas.len == 0 { break; }
        promote_mem_to_reg(fv, allocas);
        changed = true;
    }
    if !changed { return 0xFFFFFFFF; }
    return PA_CFG;     // CFGAnalyses
}
