// MergeICmps: port of llvm/lib/Transforms/Scalar/MergeICmps.cpp (MergeICmpsPass), with
// DominatorTreeBase::setNewRoot (llvm/include/llvm/Support/GenericDomTree.h) on domtree.goose's tables.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import domtree;
import dtu;
import aa;
import memloc;
import tli;
import tti;
import vt;
import datalayout;
import apint;
import speculate;
import cfgutil;
import profdata;
import build_libcalls;
import simplify_libcalls;
import mem2reg;
import looprotate;
import stdsort;
import gen_attrs;

// One BCECmpBlock: atoms (GEP, load, base id, offset) for both sides, the compare, the block, the block's
// instruction set and the split / order bookkeeping. Kept in parallel arrays (index = block record).
struct MiBlock {
    bb: i32, lgep: i32, lload: i32, lbase: i32, loff: i64, rgep: i32, rload: i32, rbase: i32, roff: i64,
    size_bits: i64, cmp: i32, term: i32, require_split: bool, orig: i64
}
var mi_blocks: MiBlock[>..<];
var mi_bases: i32[>..<];          // BaseIdentifier: value -> order (index + 1)

fn mi_base_id(v: i32) -> i32 {
    for x, k in mi_bases { if x == v { return (k + 1) as i32; } }
    mi_bases.push(v);
    return mi_bases.len as i32;
}

fn mi_in_block_insts(b: MiBlock, i: i32) -> bool {
    return i == b.lload || i == b.rload || i == b.cmp || i == b.term || (b.lgep >= 0 && i == b.lgep) || (b.rgep >= 0 && i == b.rgep);
}

// visitICmpLoadOperand: (ok, gep, load, base id, offset)
fn mi_visit_load_operand(v: i32) -> bool, i32, i32, i32, i64 {
    if !is_inst(v) || iop(v) != OP_LOAD { return false, -1, -1, 0, 0; }
    let li = v;
    if lr_used_outside_block(li, inst_parent(li)) { return false, -1, -1, 0, 0; }
    if inst_is_volatile(li) || insts[inst_of(li)].ord != 0 { return false, -1, -1, 0, 0; }
    let addr = op(li, 0);
    if ptr_as(vals[addr].ty) != 0 { return false, -1, -1, 0, 0; }
    let t = vals[li].ty;
    if dl_size_bits(t) != dl_store_size(t) * 8 { return false, -1, -1, 0, 0; }
    var off: i64 = 0;
    var base = addr;
    var gep: i32 = -1;
    if is_inst(addr) && iop(addr) == OP_GEP {
        gep = addr;
        if lr_used_outside_block(gep, inst_parent(li)) { return false, -1, -1, 0, 0; }
        let w = dl_ptr(0).idx;
        if w > 64 { fatal("mergeicmps: index widths over 64 bits are not ported yet"); }
        let ok, o = gep_accumulate_constant_offset(gep);
        if !ok { return false, -1, -1, 0, 0; }
        off = if w == 64 { o } else { (o << (64 - w)) >> (64 - w) };
        base = op(gep, 0);
    }
    return true, gep, li, mi_base_id(base), off;
}

fn mi_atom_less(b1: i32, o1: i64, b2: i32, o2: i64) -> bool { if b1 != b2 { b1 < b2 } else { o1 < o2 } }

// visitCmpBlock(Val, Block, PhiBlock): appends a record (returns its index, -1 = std::nullopt)
fn mi_visit_cmp_block(val: i32, blk: i32, phibb: i32) -> i64 {
    if block_first(blk) < 0 { return -1; }
    let term = block_terminator(blk);
    var cond: i32 = -1;
    var expected: i64 = 32;
    if iop(term) == OP_BR {
        cond = val;
        expected = 32;
    } else if iop(term) == OP_CONDBR {
        if !is_cint(val) { fatal("mergeicmps: a phi incoming value from a conditional block is not a ConstantInt"); }
        if !cint_is_zero(val) { return -1; }
        let fb = term_succ(term, 1);
        cond = op(term, 0);
        expected = if fb == phibb { 32 } else { 33 };
    } else { return -1; }
    if !is_inst(cond) || iop(cond) != OP_ICMP { return -1; }
    let cmp = cond;
    // visitICmp
    let u = first_use(cmp);
    if u < 0 || use_next(u) >= 0 { return -1; }
    if inst_pred(cmp) != expected { return -1; }
    let lok, lgep, lload, lbase, loff = mi_visit_load_operand(op(cmp, 0));
    if !lok || lbase == 0 { return -1; }
    let rok, rgep, rload, rbase, roff = mi_visit_load_operand(op(cmp, 1));
    if !rok || rbase == 0 { return -1; }
    var b = MiBlock { bb: blk, lgep: lgep, lload: lload, lbase: lbase, loff: loff, rgep: rgep, rload: rload, rbase: rbase,
                      roff: roff, size_bits: dl_size_bits(vals[op(cmp, 0)].ty), cmp: cmp, term: term, require_split: false, orig: 0 };
    // BCECmp: if (Rhs < Lhs) swap
    if mi_atom_less(rbase, roff, lbase, loff) {
        let g = b.lgep; let l = b.lload; let bs = b.lbase; let o = b.loff;
        b.lgep = b.rgep; b.lload = b.rload; b.lbase = b.rbase; b.loff = b.roff;
        b.rgep = g; b.rload = l; b.rbase = bs; b.roff = o;
    }
    mi_blocks.push(b);
    return mi_blocks.len - 1;
}

fn mi_does_other_work(b: MiBlock) -> bool {
    var i = block_first(b.bb);
    while i >= 0 { if !mi_in_block_insts(b, i) { return true; } i = inst_next(i); }
    return false;
}

fn mi_can_sink(b: MiBlock, i: i32) -> bool {
    if inst_may_write_memory(i) {
        for li in [b.lload, b.rload] {
            if (inst_parent(i) != inst_parent(li) || !mi_comes_before(i, li)) && mr_is_mod(aa_inst_loc_mr_simple(i, ml_get(li))) { return false; }
        }
    }
    for k in nops(i) {
        let o = op(i, k);
        if o >= 0 && is_inst(o) && mi_in_block_insts(b, o) { return false; }
    }
    return true;
}
fn mi_comes_before(a: i32, b: i32) -> bool {
    var x = inst_next(a);
    while x >= 0 { if x == b { return true; } x = inst_next(x); }
    return false;
}

// canSplit: (ok, SplitAt)
fn mi_can_split(b: MiBlock) -> bool, i32 {
    var split_at: i32 = -1;
    var i = block_first(b.bb);
    while i >= 0 {
        if !mi_in_block_insts(b, i) {
            split_at = inst_next(i);
            if !mi_can_sink(b, i) { return false, split_at; }
        }
        i = inst_next(i);
    }
    return true, split_at;
}

fn mi_split(b: MiBlock, np: i32) {
    var others: i32[>..<] = [];
    var i = block_first(b.bb);
    while i >= 0 { if !mi_in_block_insts(b, i) { others.push(i); } i = inst_next(i); }
    var k = others.len - 1;
    while k >= 0 {
        inst_move_impl(others[k], np, block_first(np), true, true);
        k--;
    }
}

// the chain: groups of record indices (MergedBlocks_)
var mi_groups: i32[>..<];         // record indices, group after group
var mi_group_at: i64[>..<];
var mi_group_n: i64[>..<];

fn mi_are_contiguous(a: MiBlock, b: MiBlock) -> bool {
    return a.lbase == b.lbase && a.rbase == b.rbase && a.loff + a.size_bits / 8 == b.loff && a.roff + a.size_bits / 8 == b.roff;
}

fn mi_block_less(x: i32, y: i32) -> bool {
    let a = mi_blocks[x];
    let b = mi_blocks[y];
    // std::tie(Lhs, Rhs) <
    if mi_atom_less(a.lbase, a.loff, b.lbase, b.loff) { return true; }
    if mi_atom_less(b.lbase, b.loff, a.lbase, a.loff) { return false; }
    return mi_atom_less(a.rbase, a.roff, b.rbase, b.roff);
}

// mergeBlocks(Comparisons)
fn mi_merge_blocks(cmps: i32[>..<]&) {
    std_sort(cmps, 0, cmps.len) { a, b => mi_block_less(a, b) };
    var groups_at: i64[>..<] = [];
    var groups_n: i64[>..<] = [];
    var flat: i32[>..<] = [];
    for c in cmps {
        if groups_at.len == 0 || !mi_are_contiguous(mi_blocks[flat[flat.len - 1]], mi_blocks[c]) {
            groups_at.push(flat.len);
            groups_n.push(0);
        }
        flat.push(c);
        groups_n[groups_n.len - 1] += 1;
    }
    // sort the groups by their minimal original order (unique keys)
    var order: i64[>..<] = [];
    for g in groups_at.len { order.push(g); }
    fn min_orig(g: i64, groups_at: i64[>..<]&, groups_n: i64[>..<]&, flat: i32[>..<]&) -> i64 {
        var m: i64 = 0x7FFFFFFF;
        for k in groups_n[g] { let o = mi_blocks[flat[groups_at[g] + k]].orig; if o < m { m = o; } }
        return m;
    }
    var keys: i64[>..<] = [];
    for g in groups_at.len { keys.push(min_orig(g, groups_at, groups_n, flat)); }
    std_sort(order, 0, order.len) { a, b => keys[a] < keys[b] };
    mi_groups.clear(); mi_group_at.clear(); mi_group_n.clear();
    for g in order {
        mi_group_at.push(mi_groups.len);
        mi_group_n.push(groups_n[g]);
        for k in groups_n[g] { mi_groups.push(flat[groups_at[g] + k]); }
    }
}

fn mi_at_least_one_merged() -> bool { for n in mi_group_n { if n > 1 { return true; } } return false; }

// MergedBlockName
fn mi_merged_name(g: i64) -> u8[>..] {
    var s: u8[>..] = [];
    let at = mi_group_at[g];
    let n = mi_group_n[g];
    if n == 1 { s.append(val_name(mi_blocks[mi_groups[at]].bb)); return s; }
    var size: i64 = 0;
    for k in n { size += val_name(mi_blocks[mi_groups[at + k]].bb).len; }
    if size == 0 { return s; }
    s.append(val_name(mi_blocks[mi_groups[at]].bb));
    for k in 1..n {
        let nm = val_name(mi_blocks[mi_groups[at + k]].bb);
        if nm.len > 0 { s.push('+'); s.append(nm); }
    }
    return s;
}

fn mi_merged_dl(dls: const i32[:]) -> i32 {
    if dls.len == 0 { return -1; }
    var m = dls[0];
    for k in 1..dls.len {
        m = m2r_merged_location(m, dls[k]);
        if m < 0 { break; }
    }
    return m;
}

// computeMergedBranchWeights: (has, w0, w1)
fn mi_merged_weights(g: i64) -> bool, u64, u64 {
    let at = mi_group_at[g];
    let n = mi_group_n[g];
    var w: u64[>..<] = [];
    if n == 1 {
        if !pd_extract(mi_blocks[mi_groups[at]].term, w) || w.len != 2 { return false, 0, 0; }
        return true, w[0], w[1];
    }
    var t: u64 = 0;
    var f: u64 = 1;
    for k in n {
        w.clear();
        if !pd_extract(mi_blocks[mi_groups[at + k]].term, w) || w.len != 2 { return false, 0, 0; }
        // swap(W[0], W[1]); getDisjunctionWeights({t, f}, W)
        let b0 = w[1];
        let b1 = w[0];
        let nf = f * b1;
        let nt = t * (b0 + b1) + f * b0;
        t = nt; f = nf;
    }
    // swap, fitWeights
    var ws: u64[>..<] = [f, t];
    pd_fit(ws);
    return true, ws[0], ws[1];
}

fn mi_set_dl(i: i32, dl: i32) { if dl >= 0 { inst_set_md(i, 0, dl); } }

// mergeComparisons(Comparisons, InsertBefore, NextCmpBlock, Phi, TLI, AA, DTU)
fn mi_merge_comparisons(g: i64, insert_before: i32, next_cmp: i32, phi: i32) -> i32 {
    let at = mi_group_at[g];
    let n = mi_group_n[g];
    let first = mi_blocks[mi_groups[at]];
    let fv = block_func(next_cmp);
    let name = mi_merged_name(g);
    let bb = create_block_before(fv, insert_before, name);
    // IRBuilder<> Builder(BB): no current debug location
    var lhs: i32 = -1;
    var rhs: i32 = -1;
    if first.lgep >= 0 { lhs = inst_clone(first.lgep); block_append_inst(bb, lhs); } else { lhs = op(first.lload, 0); }
    if first.rgep >= 0 { rhs = inst_clone(first.rgep); block_append_inst(bb, rhs); } else { rhs = op(first.rload, 0); }
    for k in n {
        let b = mi_blocks[mi_groups[at + k]];
        if b.require_split { mi_split(b, bb); break; }
    }
    var is_eq: i32 = -1;
    if n == 1 {
        let ll = inst_clone(first.lload);
        block_append_inst(bb, ll);
        let rl = inst_clone(first.rload);
        block_append_inst(bb, rl);
        set_op(ll, 0, lhs);
        set_op(rl, 0, rhs);
        is_eq = create_inst(OP_ICMP, T_I1, [ll, rl]);
        insts[inst_of(is_eq)].pred = 32;
        block_append_inst(bb, is_eq);
        mi_set_dl(is_eq, inst_get_md(first.cmp, 0));
    } else {
        var total: i64 = 0;
        var dls: i32[>..<] = [];
        for k in n { let b = mi_blocks[mi_groups[at + k]]; total += b.size_bits; dls.push(inst_get_md(b.cmp, 0)); }
        let cdl = mi_merged_dl(dls);
        let mc = mi_emit_memcmp(bb, lhs, rhs, c_int(ty_int(tli_sizet_bits()), total / 8), cdl);
        is_eq = create_inst(OP_ICMP, T_I1, [mc, c_int(ty_int(tli_int_bits()), 0)]);
        insts[inst_of(is_eq)].pred = 32;
        block_append_inst(bb, is_eq);
        mi_set_dl(is_eq, cdl);
    }
    var bdls: i32[>..<] = [];
    for k in n { bdls.push(inst_get_md(mi_blocks[mi_groups[at + k]].term, 0)); }
    let bdl = mi_merged_dl(bdls);
    let phibb = inst_parent(phi);
    if next_cmp == phibb {
        let br = create_inst(OP_BR, T_VOID, [phibb]);
        block_append_inst(bb, br);
        mi_set_dl(br, bdl);
        phi_add_incoming(phi, is_eq, bb);
        let ups: DTUpdate[1] = [DTUpdate { kind: DT_INSERT, from: bb, to: phibb }];
        dtu_apply_updates(ups);
    } else {
        let br = create_inst(OP_CONDBR, T_VOID, [is_eq, next_cmp, phibb]);
        block_append_inst(bb, br);
        mi_set_dl(br, bdl);
        let has, w0, w1 = mi_merged_weights(g);
        if has { let ws: u64[2] = [w0, w1]; pd_set(br, ws, false, false); }
        phi_add_incoming(phi, c_false(), bb);
        let ups: DTUpdate[2] = [DTUpdate { kind: DT_INSERT, from: bb, to: next_cmp }, DTUpdate { kind: DT_INSERT, from: bb, to: phibb }];
        dtu_apply_updates(ups);
    }
    return bb;
}

// emitMemCmp(Ptr1, Ptr2, Len, B, DL, TLI) with the builder at the end of bb and debug location dl
fn mi_emit_memcmp(bb: i32, a: i32, b: i32, len: i32, dl: i32) -> i32 {
    let pt = ty_ptr(0);
    let fty = ty_func_of(ty_int(tli_int_bits()), [pt, pt, ty_int(tli_sizet_bits())], false);
    let f = blc_get_or_insert(LF_memcmp, fty, 0);
    blc_infer_by_name("memcmp");
    let c = create_inst(OP_CALL, ty_fn_ret(fty), [a, b, len, f]);
    insts[inst_of(c)].ty2 = fty;
    block_append_inst(bb, c);
    set_name(c, "memcmp");
    mi_set_dl(c, dl);
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return c;
}

// DominatorTreeBase::setNewRoot(BB)
fn mi_dt_set_new_root(fv: i32, bb: i32) {
    dt_focus(fv, DT_DOM);
    if t_has(bb) { fatal("internal: setNewRoot of a block in the tree"); }
    t_invalidate_dfs();
    let h = hk0();
    t_create_node(bb, -1);
    if dt_heads[h].nroots == 0 { fatal("mergeicmps: setNewRoot of an empty dominator tree is not ported yet"); }
    let old = dt_roots_pool[dt_heads[h].roots_at];
    t_add_child(bb, old);
    dt_nodes[dt_node_idx(old, DT_DOM)].idom = bb;
    t_update_level(old);
    dt_roots_pool[dt_heads[h].roots_at] = bb;
    dt_heads[h].root = bb;
}

fn mi_is_dereferenceable(entry: i32, split_at: i32) -> bool {
    let cx = if split_at >= 0 { split_at } else { block_first(entry) };
    for g in mi_group_n.len {
        let lo = mi_blocks[mi_groups[mi_group_at[g]]];
        var bits: i64 = 0;
        for k in mi_group_n[g] { bits += mi_blocks[mi_groups[mi_group_at[g] + k]].size_bits; }
        let size = ap_u64((bits / 8) as u64, 64);
        for p in [op(lo.lload, 0), op(lo.rload, 0)] {
            spec_cxt = cx;
            spec_use_ac = false;
            spec_use_dt = false;
            spec_use_tli = false;
            spec_visited.clear();
            let ok = spec_deref_aligned(p, 1, size, 16);
            spec_cxt = -1;
            if !ok { return false; }
        }
    }
    return true;
}

fn mi_process_phi(phi: i32) -> bool {
    let n = phi_nincoming(phi);
    if n <= 1 { return false; }
    var last: i32 = -1;
    for k in n {
        let v = phi_value(phi, k);
        if is_cint(v) { continue; }
        if last >= 0 { return false; }
        if !is_inst(v) || iop(v) != OP_ICMP || inst_parent(v) != phi_block(phi, k) { return false; }
        last = phi_block(phi, k);
    }
    if last < 0 { return false; }
    if !(block_nsucc(last) == 1 && block_succ(last, 0) == inst_parent(phi)) { return false; }
    // getOrderedBlocks
    var blocks: i32[>..<] = [];
    for k in n { blocks.push(-1); }
    var cur = last;
    var bi = n - 1;
    while bi > 0 {
        if cu_has_address_taken(cur) { return false; }
        blocks[bi] = cur;
        let sp = single_pred(cur);
        if sp < 0 { return false; }
        if phi_block_index(phi, sp) < 0 { return false; }
        cur = sp;
        bi--;
    }
    blocks[0] = cur;
    // BCECmpChain(Blocks, Phi, AA)
    mi_blocks.clear();
    mi_bases.clear();
    var cmps: i32[>..<] = [];
    var split_at: i32 = -1;
    for blk in blocks {
        if cu_has_address_taken(blk) { return false; }
        let r = mi_visit_cmp_block(phi_value(phi, phi_block_index(phi, blk)), blk, inst_parent(phi));
        if r < 0 { return false; }
        if mi_does_other_work(mi_blocks[r]) {
            if cmps.len == 0 {
                let ok, sa = mi_can_split(mi_blocks[r]);
                split_at = sa;
                if ok {
                    mi_blocks[r].require_split = true;
                    mi_blocks[r].orig = cmps.len;
                    cmps.push(r as i32);
                } else {
                    split_at = -1;
                }
                continue;
            }
            return false;
        }
        mi_blocks[r].orig = cmps.len;
        cmps.push(r as i32);
    }
    if cmps.len == 0 { return false; }
    let entry = mi_blocks[cmps[0]].bb;
    mi_merge_blocks(cmps);
    if !mi_at_least_one_merged() { return false; }
    if !mi_is_dereferenceable(entry, split_at) { return false; }
    // simplify
    var insert_before = entry;
    var next_cmp = inst_parent(phi);
    var g = mi_group_n.len - 1;
    while g >= 0 {
        let nb = mi_merge_comparisons(g, insert_before, next_cmp, phi);
        insert_before = nb;
        next_cmp = nb;
        g--;
    }
    loop {
        var p: i32 = -1;
        each_pred(entry) { x => if p < 0 { p = x; } };
        if p < 0 { break; }
        let t = block_terminator(p);
        for k in nops(t) { if op(t, k) == entry { set_op(t, k, next_cmp); } }
        let ups: DTUpdate[2] = [DTUpdate { kind: DT_DELETE, from: p, to: entry }, DTUpdate { kind: DT_INSERT, from: p, to: next_cmp }];
        dtu_apply_updates(ups);
    }
    let fv = block_func(entry);
    // EntryBlock_->isEntryBlock() (the merged blocks were inserted before it)
    if func_entry(fv) == entry && cu_dtu_has_dt() {
        dtu_get_dt();
        mi_dt_set_new_root(fv, next_cmp);
        let ups: DTUpdate[1] = [DTUpdate { kind: DT_DELETE, from: next_cmp, to: entry }];
        dtu_apply_updates(ups);
    }
    var dead: i32[>..<] = [];
    for x in mi_groups { dead.push(mi_blocks[x].bb); }
    cu_delete_dead_blocks(dead, false);
    return true;
}
fn cu_dtu_has_dt() -> bool { dtu_dt }

fn mergeicmps_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    if tti_kind != TTI_X86 { return PA_ALL; }
    cur_module = globs[glob_of(fv)].module;
    if !blc_is_emittable(LF_memcmp) { return PA_ALL; }
    aa_begin(fv);
    let had_dt = dt_valid(fv, DT_DOM);
    dtu_begin(fv, true, false, false);
    cu_dtu = true;
    var changed = false;
    var bb = block_next(func_first_block(fv));
    while bb >= 0 {
        let p = block_first(bb);
        if p >= 0 && iop(p) == OP_PHI {
            if mi_process_phi(p) { changed = true; }
        }
        bb = block_next(bb);
    }
    cu_dtu = false;
    dtu_end();
    if !changed { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}
