// IR utilities every pass needs: CFG queries, the mutation API, and O(1)-reset scratch sets/maps over value ids.
// Ports the relevant parts of llvm/lib/IR/{BasicBlock,Instruction,Instructions,Value}.cpp and
// llvm/include/llvm/IR/CFG.h. See DESIGN.md §8 for the conventions.
import std;
import ir;
import dinfo;

// ---------------------------------------------------------------------------------------------
// Small accessors

fn is_inst(v: i32) -> bool { v >= 0 && vals[v].kind == VK_INST }
fn is_arg(v: i32) -> bool { v >= 0 && vals[v].kind == VK_ARG }
fn is_block(v: i32) -> bool { v >= 0 && vals[v].kind == VK_BLOCK }
fn is_dead(v: i32) -> bool { vals[v].kind == VK_DEAD }
fn is_cint(v: i32) -> bool { v >= 0 && vals[v].kind == VK_CINT }
fn is_poison(v: i32) -> bool { v >= 0 && vals[v].kind == VK_POISON }
fn is_undef_or_poison(v: i32) -> bool { v >= 0 && (vals[v].kind == VK_UNDEF || vals[v].kind == VK_POISON) }
fn is_func(v: i32) -> bool { v >= 0 && vals[v].kind == VK_FUNC }
fn is_gvar(v: i32) -> bool { v >= 0 && vals[v].kind == VK_GVAR }

fn inst_parent(iv: i32) -> i32 { insts[inst_of(iv)].parent }
fn inst_next(iv: i32) -> i32 { insts[inst_of(iv)].next }
fn inst_prev(iv: i32) -> i32 { insts[inst_of(iv)].prev }
fn inst_func(iv: i32) -> i32 { blocks[block_of(insts[inst_of(iv)].parent)].parent }
fn block_first(bv: i32) -> i32 { blocks[block_of(bv)].first }
fn block_last(bv: i32) -> i32 { blocks[block_of(bv)].last }
fn block_next(bv: i32) -> i32 { blocks[block_of(bv)].next }
fn block_prev(bv: i32) -> i32 { blocks[block_of(bv)].prev }
fn block_func(bv: i32) -> i32 { blocks[block_of(bv)].parent }
fn func_entry(fv: i32) -> i32 { globs[glob_of(fv)].first_block }
fn func_first_block(fv: i32) -> i32 { globs[glob_of(fv)].first_block }
fn func_is_decl(fv: i32) -> bool { globs[glob_of(fv)].first_block < 0 }
fn is_terminator(iv: i32) -> bool { is_inst(iv) && is_terminator_op(iop(iv)) }
fn is_phi(iv: i32) -> bool { is_inst(iv) && iop(iv) == OP_PHI }
fn is_call(iv: i32) -> bool { is_inst(iv) && iop(iv) == OP_CALL }
// CallBase: call, invoke, callbr.
fn is_callbase(iv: i32) -> bool { if !is_inst(iv) { return false; } let o = iop(iv); o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR }
fn val_name(v: i32) -> const u8[:] { if vals[v].name >= 0 { sbytes(vals[v].name) } else { "" } }

// Number of blocks of a function (BasicBlock numbering is the block table index; see dt_number_blocks).
fn func_block_count(fv: i32) -> i64 {
    var n = 0;
    var b = func_first_block(fv);
    while b >= 0 { n++; b = block_next(b); }
    return n;
}

// Iterate a function's instructions in order (InstIterator). The successor is read before F runs, so F may
// erase the current instruction (make_early_inc_range).
fn each_inst<F>(fv: i32) {
    var b = func_first_block(fv);
    while b >= 0 {
        let nb = block_next(b);
        var i = block_first(b);
        while i >= 0 {
            let ni = inst_next(i);
            F(i);
            i = ni;
        }
        b = nb;
    }
}

// ---------------------------------------------------------------------------------------------
// CFG (llvm/IR/CFG.h). Successor order is Instruction::getSuccessor order.

// Operand layout of terminators: br [dest]; condbr [cond, true, false]; switch [cond, default, (val, dest)*];
// indirectbr [addr, dests...]; invoke [args..., normal, unwind, callee] (LLVM's Op<-3>, Op<-2>, Op<-1>).
fn term_nsucc(t: i32) -> i64 {
    let o = iop(t);
    let n = nops(t);
    if o == OP_BR { return 1; }
    if o == OP_CONDBR { return 2; }
    if o == OP_SWITCH { return n / 2; }
    if o == OP_INDIRECTBR { return n - 1; }
    if o == OP_INVOKE { return 2; }
    if o == OP_CALLBR { return 1 + iu_callbr_nindirect(t); }
    if o == OP_CATCHRET { return 1; }
    if o == OP_CLEANUPRET { return n - 1; }
    if o == OP_CATCHSWITCH { return n - 1; }
    if o == OP_RET || o == OP_UNREACHABLE || o == OP_RESUME { return 0; }
    fatal(str("successors of this terminator are not supported yet (opcode ", o, ")"));
    return 0;
}

// CallBrInst::getNumIndirectDests (naux == 0: no bundles and no indirect destinations, see calls.goose)
fn iu_callbr_nindirect(t: i32) -> i64 {
    let x = insts[inst_of(t)];
    if x.naux == 0 { return 0; }
    return ints[x.aux + 1] as i64;
}

fn term_succ_opnd(t: i32, k: i64) -> i64 {
    let o = iop(t);
    let n = nops(t);
    if o == OP_BR { return 0; }
    if o == OP_CONDBR { return 1 + k; }
    if o == OP_SWITCH { return if k == 0 { 1 } else { 1 + 2 * k }; }
    if o == OP_INDIRECTBR { return 1 + k; }
    if o == OP_INVOKE { return n - 3 + k; }
    if o == OP_CALLBR { return n - 2 - iu_callbr_nindirect(t) + k; }
    if o == OP_CATCHRET { return 1; }
    if o == OP_CLEANUPRET { return 1; }
    // catchswitch: successors are the unwind dest (if any) then the handlers (CatchSwitchInst::getSuccessor)
    if o == OP_CATCHSWITCH { return 1 + k; }
    fatal("successor of a terminator without successors");
    return 0;
}

fn term_succ(t: i32, k: i64) -> i32 { op(t, term_succ_opnd(t, k)) }
fn term_set_succ(t: i32, k: i64, b: i32) { set_op(t, term_succ_opnd(t, k), b); }

fn block_nsucc(bv: i32) -> i64 { let t = block_terminator(bv); if t < 0 { 0 } else { term_nsucc(t) } }
fn block_succ(bv: i32, k: i64) -> i32 { term_succ(block_terminator(bv), k) }

// predecessors(BB): the users of the block that are terminators, in use-list order (one per edge).
fn each_pred<F>(bv: i32) {
    var u = vals[bv].first_use;
    while u >= 0 {
        let nu = uses[u].next;
        let user = uses[u].user;
        if vals[user].kind == VK_INST && is_terminator_op(iop(user)) { F(insts[inst_of(user)].parent); }
        u = nu;
    }
}

fn pred_count(bv: i32) -> i64 { var n = 0; each_pred(bv) { p => n++; }; return n; }

fn single_pred(bv: i32) -> i32 {
    var r: i32 = -1;
    var n = 0;
    each_pred(bv) { p => if n == 0 { r = p; } n++; };
    return if n == 1 { r } else { -1 };
}

fn first_non_phi(bv: i32) -> i32 {
    var i = block_first(bv);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    return i;
}

// ---------------------------------------------------------------------------------------------
// PHI nodes (llvm/IR/Instructions.cpp PHINode)

fn phi_nincoming(p: i32) -> i64 { nops(p) }
fn phi_value(p: i32, k: i64) -> i32 { op(p, k) }
fn phi_block(p: i32, k: i64) -> i32 { op_aux(p, k) }
fn phi_set_block(p: i32, k: i64, b: i32) { use_aux[vals[p].ops + k] = b; }

fn phi_block_index(p: i32, b: i32) -> i64 {
    for k in nops(p) { if op_aux(p, k) == b { return k; } }
    return -1;
}

fn phi_add_incoming(p: i32, v: i32, b: i32) {
    let k = push_op(p, v);
    phi_set_block(p, k, b);
}

// PHINode::removeIncomingValue(Idx): the last entry moves into Idx, the last use is nulled.
// Erasing an emptied PHI (DeletePHIIfEmpty) is the caller's business: see phi_remove_incoming_block.
fn phi_remove_incoming(p: i32, idx: i64) -> i32 {
    let removed = op(p, idx);
    let last = nops(p) - 1;
    if idx != last {
        set_op(p, idx, op(p, last));
        phi_set_block(p, idx, op_aux(p, last));
    }
    set_op(p, last, -1);
    use_aux[vals[p].ops + last] = -1;
    vals[p].nops = last as i32;
    return removed;
}

// PHINode::removeIncomingValue(BB, DeletePHIIfEmpty)
fn phi_remove_incoming_block(p: i32, b: i32, delete_if_empty: bool) -> i32 {
    let idx = phi_block_index(p, b);
    if idx < 0 { fatal("phi_remove_incoming_block: block is not an incoming block"); }
    let r = phi_remove_incoming(p, idx);
    if nops(p) == 0 && delete_if_empty {
        rauw(p, c_poison(vals[p].ty));
        inst_erase_from_parent(p);
    }
    return r;
}

// PHINode::hasConstantValue
fn phi_has_constant_value(p: i32) -> i32 {
    var cv = op(p, 0);
    for k in 1..nops(p) {
        let v = op(p, k);
        if v != cv && v != p {
            if cv != p { return -1; }
            cv = v;
        }
    }
    if cv == p { return c_poison(vals[p].ty); }
    return cv;
}

// BasicBlock::removePredecessor(Pred, KeepOneInputPHIs)
fn block_remove_predecessor(bv: i32, pred: i32, keep_one_input_phis: bool) {
    let f = block_first(bv);
    if f < 0 || iop(f) != OP_PHI { return; }
    let npreds = nops(f);
    var i = f;
    while i >= 0 && iop(i) == OP_PHI {
        let ni = inst_next(i);
        phi_remove_incoming_block(i, pred, !keep_one_input_phis);
        if !keep_one_input_phis && npreds != 1 {
            let c = phi_has_constant_value(i);
            if c >= 0 {
                rauw(i, c);
                inst_erase_from_parent(i);
            }
        }
        i = ni;
    }
}

// BasicBlock::replacePhiUsesWith(Old, New): every incoming block Old of this block's PHIs becomes New.
fn block_replace_phi_uses_with(bv: i32, old: i32, nw: i32) {
    var i = block_first(bv);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op_aux(i, k) == old { phi_set_block(i, k, nw); } }
        i = inst_next(i);
    }
}

// BasicBlock::replaceSuccessorsPhiUsesWith(Old, New)
fn block_replace_successors_phi_uses_with(bv: i32, old: i32, nw: i32) {
    let t = block_terminator(bv);
    if t < 0 { return; }
    for k in term_nsucc(t) { block_replace_phi_uses_with(term_succ(t, k), old, nw); }
}

// ---------------------------------------------------------------------------------------------
// Mutation API

// Value::setName with the name of another value (copied first: the name bytes live in the pool we append to).
fn set_name_from(v: i32, src: i32) {
    if vals[src].name < 0 { set_name(v, ""); return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(v, buf);
}

// Instruction::removeFromParent: its debug records stay behind (handleMarkerRemoval: they go to the next
// instruction or become trailing), unlink, and drop the name from the function's symbol table.
fn inst_remove_from_parent(iv: i32) {
    if dbgrecs.len > 0 { dbg_records_to_next(iv); }
    if vals[iv].name >= 0 {
        let st = symtab_for(iv);
        if st >= 0 { symtab_remove(st, iv); }
    }
    inst_remove(iv);
}

// Instruction::eraseFromParent. The value must have no uses left (LLVM asserts "Uses remain when a value is
// destroyed!"); its id is never reused, the record becomes VK_DEAD (see DESIGN.md §8.2).
fn inst_erase_from_parent(iv: i32) {
    if vals[iv].first_use >= 0 { fatal("internal: erasing an instruction that still has uses"); }
    // ~Value: ValueAsMetadata::handleDeletion (debug records using it get poison; passes salvage before erasing,
    // as LLVM's do)
    if iv < val_vam.len && val_vam[iv] >= 0 { vam_handle_deletion(iv); }
    inst_remove_from_parent(iv);
    drop_all_refs(iv);
    val_set_dead(iv);
}

// Is v a location operand of any debug record? (ValueAsMetadata, or inside a DIArgList.) Linear in the number
// of records; only used to fail loudly where LLVM would salvage or kill debug locations.
fn md_mentions_value(m: i32, v: i32) -> bool {
    if m < 0 { return false; }
    if mds[m].kind == MK_VALUE { return mds[m].extra == v; }
    if mds[m].kind == MK_STRING { return false; }
    for k in mds[m].nops {
        let o = md_ops[mds[m].ops + k];
        if o >= 0 && mds[o].kind == MK_VALUE && mds[o].extra == v { return true; }
    }
    return false;
}
fn dbg_records_use_value(v: i32) -> bool {
    if !val_used_by_md(v) { return false; }
    var recs: i32[>..<] = [];
    find_dbg_users(v, recs);
    return recs.len > 0;
}

// Insert an unlinked instruction. Names: set them after insertion (IRBuilder::Insert then setName), so the
// function's symbol table uniques them.
// Instruction::insertAfter(Instruction *Pos): a plain list insertion, so the records attached to the next
// instruction stay there (after the new instruction).
fn inst_insert_after(iv: i32, pos: i32) { inst_link(iv, inst_parent(pos), inst_next(pos)); }

// Instruction::moveBeforeImpl(BB, It = (pos, head), Preserve) (Instruction.cpp); pos = -1 is end(). Without
// Preserve the moved instruction leaves its records behind (unless it isn't moving) and, without the head bit,
// adopts the records at the destination. With Preserve its records travel with it.
fn inst_move_impl(iv: i32, bv: i32, pos: i32, head: bool, preserve: bool) {
    if !preserve && inst_first_dbg(iv) >= 0 && (pos != iv || head) { dbg_records_to_next(iv); }
    if pos == iv { return; }
    inst_remove(iv);
    inst_link(iv, bv, pos);
    if !preserve && !head {
        let nx = inst_next(iv);
        let src = marker_take(bv, nx);
        // adoptDbgRecords(BB, It, InsertAtHead = false): after any records the instruction already has
        if src >= 0 { marker_absorb(bv, iv, src, false); }
    }
    if is_terminator_op(iop(iv)) { block_flush_terminator_records(bv); }
}
// Instruction::moveBefore(Instruction *Pos) (same function: the name stays in the same symbol table).
fn inst_move_before(iv: i32, pos: i32) { inst_move_impl(iv, inst_parent(pos), pos, false, false); }
// moveBefore(It) with the head bit set.
fn inst_move_before_head(iv: i32, pos: i32) { inst_move_impl(iv, inst_parent(pos), pos, true, false); }
// moveBeforePreserving(Instruction *Pos)
fn inst_move_before_preserving(iv: i32, pos: i32) { inst_move_impl(iv, inst_parent(pos), pos, false, true); }
// Instruction::moveAfter(Instruction *Pos): before std::next(Pos) with the head bit.
fn inst_move_after(iv: i32, pos: i32) { inst_move_impl(iv, inst_parent(pos), inst_next(pos), true, false); }
// moveAfterPreserving(Instruction *Pos)
fn inst_move_after_preserving(iv: i32, pos: i32) { inst_move_impl(iv, inst_parent(pos), inst_next(pos), true, true); }
// moveBefore(BB, BB->end())
fn inst_move_to_end(iv: i32, bv: i32) { inst_move_impl(iv, bv, -1, false, false); }

// Create an instruction with the given operands (not inserted).
fn create_inst(opc: i64, ty: i32, opsv: const i32[:]) -> i32 {
    let v = new_inst(opc, ty, opsv.len);
    for k in opsv.len { set_op(v, k, opsv[k]); }
    return v;
}

// Instruction::clone(): same opcode, type, operands (new uses, in operand order), flags, attributes and metadata
// attachments; unnamed, not inserted, no debug records. PHI incoming blocks are copied too.
fn inst_clone(iv: i32) -> i32 {
    let n = nops(iv);
    let ii = inst_of(iv);
    let nv = new_inst(iop(iv), vals[iv].ty, n);
    let ni = inst_of(nv);
    let src = insts[ii];
    insts[ni].flags = src.flags;
    insts[ni].fmf = src.fmf;
    insts[ni].pred = src.pred;
    insts[ni].align = src.align;
    insts[ni].ord = src.ord;
    insts[ni].ord2 = src.ord2;
    insts[ni].bits = src.bits;
    insts[ni].ty2 = src.ty2;
    insts[ni].attrs = src.attrs;
    insts[ni].cc = src.cc;
    insts[ni].aux = src.aux;
    insts[ni].naux = src.naux;
    insts[ni].ss = src.ss;
    insts[ni].as_ = src.as_;
    vals[nv].op = vals[iv].op;
    for k in n {
        set_op(nv, k, op(iv, k));
        use_aux[vals[nv].ops + k] = use_aux[vals[iv].ops + k];
    }
    let at = md_att.len as i32;
    for k in src.nmd { let a = md_att[src.md + 2 * k]; let b = md_att[src.md + 2 * k + 1]; md_att.push(a); md_att.push(b); }
    insts[ni].md = at;
    insts[ni].nmd = src.nmd;
    return nv;
}

// IRBuilder-style creation: insert before `before` and name it.
fn build_before(opc: i64, ty: i32, opsv: const i32[:], name: const u8[:], before: i32) -> i32 {
    let v = create_inst(opc, ty, opsv);
    inst_insert_before(v, before);
    if name.len > 0 { set_name(v, name); }
    return v;
}

// UncondBrInst::Create(Target, InsertBefore)
fn build_br(dest: i32, before: i32) -> i32 { build_before(OP_BR, T_VOID, [dest], "", before) }

// Insert a new block after `after` (BasicBlock::Create(Ctx, Name, Parent, InsertBefore=after->next)).
fn create_block_after(fv: i32, after: i32, name: const u8[:]) -> i32 {
    let bv = new_block(-1);
    let b = block_of(bv);
    let g = glob_of(fv);
    block_set_parent(bv, fv);
    if after < 0 {
        func_append_block(fv, bv);
    } else {
        let nx = block_next(after);
        blocks[b].prev = after;
        blocks[b].next = nx;
        blocks[block_of(after)].next = bv;
        if nx >= 0 { blocks[block_of(nx)].prev = bv; } else { globs[g].last_block = bv; }
    }
    if name.len > 0 { set_name(bv, name); }
    return bv;
}

// BasicBlock::splitBasicBlock(I, Name): instructions from I to the end move to a new block inserted after
// this one, this block branches to it, and successors' PHIs now see the new block.
fn split_block(bv: i32, at: i32, name: const u8[:]) -> i32 {
    let fv = block_func(bv);
    let nb = create_block_after(fv, bv, name);
    // New->splice(New->end(), this, I, end()) with I = I->getIterator() (no head bit): I's records stay
    // here and end up in front of the new branch
    block_splice(nb, -1, false, bv, at, false, -1, false);
    let br = create_inst(OP_BR, T_VOID, [nb]);
    block_append_inst(bv, br);
    block_replace_successors_phi_uses_with(nb, bv, nb);
    return nb;
}

// BasicBlock::eraseFromParent for a block whose instructions are already gone or droppable: drops all
// references of its instructions, erases them (last first), unlinks the block. The block must be unused.
fn block_erase(bv: i32) {
    var i = block_first(bv);
    while i >= 0 { drop_all_refs(i); i = inst_next(i); }
    i = block_last(bv);
    while i >= 0 {
        let p = inst_prev(i);
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
        i = p;
    }
    if vals[bv].first_use >= 0 { fatal("internal: erasing a block that still has uses"); }
    if vals[bv].name >= 0 { let st = symtab_for(bv); if st >= 0 { symtab_remove(st, bv); } }
    func_remove_block(bv);
    vals[bv].kind = VK_DEAD;
}

// ---------------------------------------------------------------------------------------------
// Scratch sets and maps over value ids with O(1) clear (an epoch stamp per entry), so per-function work never
// pays for the size of the whole module. 6 set slots and 6 map slots; who owns which slot is listed in
// DESIGN.md §8.4. Entries are created lazily up to vals.len.

let NSLOTS = 6;            // set slots and map slots each
// Sets (vs_*) and maps (vm_*) share one open-addressing hash table keyed by (value id, slot), slots 0..5 for sets
// and 6..11 for maps: memory proportional to the entries a pass touches. (An id-indexed table cost 96 bytes per
// value id ever created, 3.4x the value record itself.) An entry is live while its stamp equals its slot's
// epoch; clearing bumps the epoch, stale entries are dropped when the table is rebuilt. Nothing iterates it.
struct VsEnt { key: i64, stamp: i32, data: i64 }
var vs_tab: VsEnt[>..<];
var vs_used: i64 = 0;
var vs_shift: u64 = 64;
var vs_epoch: i32[12] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];

fn vs_key(s: i64, v: i32) -> i64 { (v as i64) * 16 + s }
fn vs_find(key: i64) -> i64 {
    if vs_tab.len == 0 { return -1; }
    let mask = vs_tab.len - 1;
    var j = (((key as u64) * 0x9E3779B97F4A7C15) >> vs_shift) as i64;
    loop {
        let k = vs_tab[j].key;
        if k == key || k < 0 { return j; }
        j = (j + 1) & mask;
    }
}
fn vs_live(j: i64, s: i64) -> bool { j >= 0 && vs_tab[j].key >= 0 && vs_tab[j].stamp == vs_epoch[s] }
fn vs_rehash() {
    var old: VsEnt[>..<] = [];
    var live: i64 = 0;
    for e in vs_tab {
        if e.key >= 0 && e.stamp == vs_epoch[e.key & 15] { old.push(e); live++; }
    }
    var n: i64 = if vs_tab.len == 0 { 1024 } else { vs_tab.len };
    while live * 4 > n { n *= 2; }
    var lg: u64 = 0;
    while ((1 as i64) << lg) < n { lg++; }
    vs_shift = 64 - lg;
    vs_tab.clear();
    vs_tab.resize(n, VsEnt { key: -1, stamp: 0, data: 0 });
    vs_used = 0;
    for e in old {
        let j = vs_find(e.key);
        vs_tab[j] = e;
        vs_used++;
    }
}
fn vs_slot(s: i64, v: i32) -> i64 {
    let key = vs_key(s, v);
    var j = vs_find(key);
    if j >= 0 && vs_tab[j].key == key { return j; }
    if (vs_used + 1) * 2 > vs_tab.len { vs_rehash(); j = vs_find(key); }
    vs_tab[j].key = key;
    vs_tab[j].stamp = 0;
    vs_used++;
    return j;
}

fn vs_clear(s: i64) { vs_epoch[s] += 1; }
fn vs_has(s: i64, v: i32) -> bool { vs_live(vs_find(vs_key(s, v)), s) }
// Returns true if newly inserted.
fn vs_add(s: i64, v: i32) -> bool {
    let j = vs_slot(s, v);
    if vs_tab[j].stamp == vs_epoch[s] { return false; }
    vs_tab[j].stamp = vs_epoch[s];
    return true;
}
fn vs_del(s: i64, v: i32) {
    let j = vs_find(vs_key(s, v));
    if vs_live(j, s) { vs_tab[j].stamp = 0; }
}

fn vm_clear(s: i64) { vs_epoch[6 + s] += 1; }
fn vm_has(s: i64, v: i32) -> bool { vs_live(vs_find(vs_key(6 + s, v)), 6 + s) }
fn vm_get(s: i64, v: i32, dflt: i64) -> i64 {
    let j = vs_find(vs_key(6 + s, v));
    if vs_live(j, 6 + s) { return vs_tab[j].data; }
    return dflt;
}
fn vm_set(s: i64, v: i32, x: i64) {
    let j = vs_slot(6 + s, v);
    vs_tab[j].stamp = vs_epoch[6 + s];
    vs_tab[j].data = x;
}
fn vm_del(s: i64, v: i32) {
    let j = vs_find(vs_key(6 + s, v));
    if vs_live(j, 6 + s) { vs_tab[j].stamp = 0; }
}

// Slot owners (keep in sync with DESIGN.md §8.4).
let VS_PASS0 = 0;      // transform passes: scratch
let VS_PASS1 = 1;
let VS_ANA0 = 2;       // analyses alive during a pass (DemandedBits: Visited)
let VS_ANA1 = 3;       // ValueTracking: poison.goose, vt.goose getUnderlyingObjects; SCEV KnownPoison
let VS_PASS2 = 4;      // InstSimplifyPass: ToSimplify / Next (VS_PASS1 holds the debug-record values)
let VS_PASS3 = 5;
let VM_PASS0 = 0;
let VM_PASS1 = 1;
let VM_ANA0 = 2;       // DemandedBits: AliveBits
let VM_ANA1 = 3;

// ---------------------------------------------------------------------------------------------
// BasicBlock::splice(Dest, Src, First, Last) with its debug-record handling (BasicBlock.cpp spliceDebugInfo,
// spliceDebugInfoImpl, spliceDebugInfoEmptyBlock). Iterators are (instruction or -1 = end(), bit): the head bit
// of Dest and First, the tail bit of Last (set = don't take the records in front of Last).
fn block_splice(dbv: i32, dpos: i32, dhead: bool, sbv: i32, first: i32, fhead0: bool, last: i32, ltail: bool) {
    if first == last {
        // spliceDebugInfoEmptyBlock
        if block_first(sbv) < 0 {
            if !block_has_trailing(sbv) { return; }
            marker_absorb(dbv, dpos, marker_take(sbv, -1), dhead);
            return;
        }
        if first != block_first(sbv) || !fhead0 { return; }
        if inst_first_dbg(first) < 0 { return; }
        marker_absorb(dbv, dpos, marker_take(sbv, first), dhead);
        return;
    }
    var fhead = fhead0;
    // spliceDebugInfo: normalise trailing records at the destination end()
    var more_dangling: i32 = -1;
    if dpos < 0 && !dhead && block_has_trailing(dbv) {
        if !fhead && inst_first_dbg(first) >= 0 { more_dangling = marker_take(sbv, first); }
        marker_absorb(sbv, first, marker_take(dbv, -1), true);
        fhead = true;
    }
    // spliceDebugInfoImpl
    let read_from_tail = !ltail;
    let dest_marker = marker_take(dbv, dpos);
    if read_from_tail && marker_first(sbv, last) >= 0 {
        marker_absorb(dbv, dpos, marker_take(sbv, last), true);
    }
    if !fhead && inst_first_dbg(first) >= 0 {
        marker_absorb(sbv, last, marker_take(sbv, first), true);
    }
    if dest_marker >= 0 {
        if dhead { marker_absorb(dbv, dpos, dest_marker, false); }
        else { marker_absorb(sbv, first, dest_marker, true); }
    }
    // move the instructions (their records travel with them)
    var i = first;
    while i >= 0 && i != last {
        let ni = inst_next(i);
        inst_remove(i);
        inst_link(i, dbv, dpos);
        i = ni;
    }
    if more_dangling >= 0 { marker_absorb(sbv, last, more_dangling, true); }
    block_flush_terminator_records(dbv);
}
