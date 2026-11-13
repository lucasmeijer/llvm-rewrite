// ExpandMemCmpPass: port of llvm/lib/Transforms/Scalar/ExpandMemCmp.cpp (MemCmpExpansion: the greedy and
// overlapping load sequences, optimiseLoadSequence, the one-block / zero-equality / multi-block expansions;
// expandMemCmp, runImpl, ExpandMemCmpPass::run), with X86TTIImpl::enableMemCmpExpansion
// (llvm/lib/Target/X86/X86TargetTransformInfo.cpp; X86TargetLowering's MaxLoadsPerMemcmp[OptSize] = 2). Without an
// x86 target (NoTTI) there is no expansion. cl::opts: -memcmp-num-loads-per-block, -max-loads-per-memcmp,
// -max-loads-per-memcmp-opt-size.
// The IRBuilder is sroa.goose's (irb_*: insertion point, debug location, ConstantFolder).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import analyses;
import gen_iids;
import gen_attrs;
import gen_tli;
import tli;
import tti;
import tti_x86;
import psi;
import bfi;
import dtu;
import domtree;
import pm;
import cfold;
import knownbits;
import sroa;
import ic;
import aggressive_instcombine;

// TTI::MemCmpExpansionOptions
var emc_max_num_loads: i64 = 0;
var emc_load_sizes: i64[>..];
var emc_num_loads_per_block: i64 = 1;
var emc_allow_overlapping: bool = false;

// enableMemCmpExpansion(OptSize, IsZeroCmp): false when the target has no expansion
fn emc_enable_memcmp_expansion(fv: i32, is_zero_cmp: bool) -> bool {
    emc_load_sizes.clear();
    tti_init_function(fv, globs[glob_of(fv)].module);
    if tti_kind != TTI_X86 { return false; }
    emc_max_num_loads = 2;
    emc_num_loads_per_block = 2;
    emc_allow_overlapping = true;
    if is_zero_cmp {
        let pw = x86_prefer_width;
        if pw >= 512 && x86_avx512() { emc_load_sizes.push(64); }
        if pw >= 256 && x86_avx() { emc_load_sizes.push(32); }
        if pw >= 128 && x86_sse2() { emc_load_sizes.push(16); }
    }
    if x86_is64() { emc_load_sizes.push(8); }
    emc_load_sizes.push(4);
    emc_load_sizes.push(2);
    emc_load_sizes.push(1);
    return true;
}

// MemCmpExpansion state
struct EmcLoad { size: i64, offset: i64 }
var emc_seq: EmcLoad[>..];
var emc_tmp: EmcLoad[>..];
var emc_ci: i32 = -1;
var emc_size: i64 = 0;
var emc_max_load_size: i64 = 0;
var emc_non_one: i64 = 0;
var emc_zero_cmp: bool = false;
var emc_dtu: bool = false;
var emc_res_bb: i32 = -1;
var emc_phi_src1: i32 = -1;
var emc_phi_src2: i32 = -1;
var emc_end: i32 = -1;
var emc_phi_res: i32 = -1;
var emc_blocks: i32[>..];

// computeGreedyLoadSequence over emc_load_sizes[first..]: fills emc_tmp; returns NumLoadsNonOneByte
fn emc_greedy(size0: i64, first: i64) -> i64 {
    emc_tmp.clear();
    var non_one: i64 = 0;
    var off: i64 = 0;
    var size = size0;
    var k = first;
    while size != 0 && k < emc_load_sizes.len {
        let ls = emc_load_sizes[k];
        let n = size / ls;
        if emc_tmp.len + n > emc_max_num_loads { emc_tmp.clear(); return 0; }
        if n > 0 {
            for _j in n { emc_tmp.push(EmcLoad { size: ls, offset: off }); off += ls; }
            if ls > 1 { non_one++; }
            size = size % ls;
        }
        k++;
    }
    return non_one;
}

// computeOverlappingLoadSequence: fills emc_tmp; returns NumLoadsNonOneByte
fn emc_overlapping(size0: i64, max_load: i64) -> i64 {
    emc_tmp.clear();
    if size0 < 2 || max_load < 2 { return 0; }
    let n = size0 / max_load;
    let size = size0 - n * max_load;
    if size == 0 { return 0; }
    if n + 1 > emc_max_num_loads { return 0; }
    var off: i64 = 0;
    for _j in n { emc_tmp.push(EmcLoad { size: max_load, offset: off }); off += max_load; }
    emc_tmp.push(EmcLoad { size: max_load, offset: off - (max_load - size) });
    return 1;
}

// MemCmpExpansion::MemCmpExpansion (optimiseLoadSequence is a no-op: X86 has no AllowedTailExpansions)
fn emc_init(ci: i32, size: i64, zero_cmp: bool) {
    emc_ci = ci;
    emc_size = size;
    emc_zero_cmp = zero_cmp;
    emc_res_bb = -1; emc_phi_src1 = -1; emc_phi_src2 = -1; emc_end = -1; emc_phi_res = -1;
    emc_blocks.clear();
    var first: i64 = 0;
    while first < emc_load_sizes.len && emc_load_sizes[first] > size { first++; }
    if first == emc_load_sizes.len { fatal("internal: expand-memcmp: cannot load Size bytes"); }
    emc_max_load_size = emc_load_sizes[first];
    emc_non_one = emc_greedy(size, first);
    emc_seq.clear();
    for e in emc_tmp { emc_seq.push(e); }
    if emc_allow_overlapping && (emc_seq.len == 0 || emc_seq.len > 2) {
        let ov_non_one = emc_overlapping(size, emc_max_load_size);
        if emc_tmp.len > 0 && (emc_seq.len == 0 || emc_tmp.len < emc_seq.len) {
            emc_seq.clear();
            for e in emc_tmp { emc_seq.push(e); }
            emc_non_one = ov_non_one;
        }
    }
}

fn emc_num_loads() -> i64 { emc_seq.len }
fn emc_num_blocks() -> i64 {
    if emc_zero_cmp {
        let n = emc_num_loads();
        let k = emc_num_loads_per_block;
        return n / k + (if n % k != 0 { 1 } else { 0 });
    }
    return emc_num_loads();
}

fn emc_pow2_ceil(n: i64) -> i64 { var p: i64 = 1; while p < n { p *= 2; } return p; }
fn emc_common_align(a: i64, off: i64) -> i64 {
    // MinAlign(A, Offset): the largest power of two dividing both
    let x = (a | off) as u64;
    return (x & (0 - x)) as i64;
}

// IRBuilder helpers on sroa.goose's builder
fn emc_icmp(p: i64, a: i32, b: i32) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_fold_cmp_operands(p, a, b, -1);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return irb_insert(iv, "", false);
}
fn emc_condbr(c: i32, t: i32, f: i32) -> i32 { irb_insert(create_inst(OP_CONDBR, T_VOID, [c, t, f]), "", false) }
fn emc_br(d: i32) -> i32 { irb_insert(create_inst(OP_BR, T_VOID, [d]), "", false) }
fn emc_dt(kind: i32, from: i32, to: i32) { if emc_dtu { let ups: DTUpdate[1] = [DTUpdate { kind: kind, from: from, to: to }]; dtu_apply_updates(ups); } }
fn emc_dt2(k1: i32, f1: i32, t1: i32, k2: i32, f2: i32, t2: i32) {
    if emc_dtu { let ups: DTUpdate[2] = [DTUpdate { kind: k1, from: f1, to: t1 }, DTUpdate { kind: k2, from: f2, to: t2 }]; dtu_apply_updates(ups); }
}
// setExplicitlyUnknownBranchWeightsIfProfiled(I, "expand-memcmp")
fn emc_unknown_weights(i: i32) {
    let has, c = bf_entry_count(block_func(inst_parent(emc_ci)));
    if !has || c == 0 { return; }
    let ops: i32[2] = [md_string("unknown"), md_string("expand-memcmp")];
    inst_set_md(i, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
}

// getLoadPair(LoadSizeType, BSwapSizeType, CmpSizeType, OffsetBytes): bswap_ty / cmp_ty -1 for nullptr
fn emc_load_pair(load_ty: i32, bswap_ty: i32, cmp_ty: i32, off: i64) -> i32, i32 {
    var ls = cb_arg(emc_ci, 0);
    var rs = cb_arg(emc_ci, 1);
    var la = pointer_alignment(ls);
    var ra = pointer_alignment(rs);
    if off > 0 {
        ls = irb_gep(T_I8, ls, [c_int(T_I64, off)], 0, "", false);
        rs = irb_gep(T_I8, rs, [c_int(T_I64, off)], 0, "", false);
        la = emc_common_align(la, off);
        ra = emc_common_align(ra, off);
    }
    var l: i32 = -1;
    if is_constant(ls) { l = cf_fold_load_from_const_ptr(ls, load_ty, 0, false); }
    if l < 0 { l = irb_load(load_ty, ls, la, false, "", false); }
    var r: i32 = -1;
    if is_constant(rs) { r = cf_fold_load_from_const_ptr(rs, load_ty, 0, false); }
    if r < 0 { r = irb_load(load_ty, rs, ra, false, "", false); }
    if bswap_ty >= 0 && load_ty != bswap_ty {
        l = irb_cast(OP_ZEXT, l, bswap_ty, "", false);
        r = irb_cast(OP_ZEXT, r, bswap_ty, "", false);
    }
    if bswap_ty >= 0 {
        l = irb_intrinsic_call(IID_bswap, [bswap_ty], [l], []);
        r = irb_intrinsic_call(IID_bswap, [bswap_ty], [r], []);
    }
    if cmp_ty >= 0 && cmp_ty != vals[l].ty {
        l = irb_cast(OP_ZEXT, l, cmp_ty, "", false);
        r = irb_cast(OP_ZEXT, r, cmp_ty, "", false);
    }
    return l, r;
}

// emitLoadCompareByteBlock
fn emc_byte_block(bi: i64, off: i64) {
    let bb = emc_blocks[bi];
    irb_set_end(bb);
    let l, r = emc_load_pair(T_I8, -1, T_I32, off);
    let diff = irb_binop(OP_SUB, l, r, "", false);
    phi_add_incoming(emc_phi_res, diff, bb);
    if bi < emc_blocks.len - 1 {
        let cmp = emc_icmp(33, diff, c_int(vals[diff].ty, 0));
        emc_condbr(cmp, emc_end, emc_blocks[bi + 1]);
        emc_dt2(DT_INSERT, bb, emc_end, DT_INSERT, bb, emc_blocks[bi + 1]);
    } else {
        emc_br(emc_end);
        emc_dt(DT_INSERT, bb, emc_end);
    }
}

// getCompareLoadPairs(BlockIndex, LoadIndex): returns Cmp and the new LoadIndex
fn emc_compare_load_pairs(bi: i64, li0: i64) -> i32, i64 {
    var li = li0;
    var xs: i32[>..<] = [];
    var diff: i32 = -1;
    var nl = emc_num_loads() - li;
    if emc_num_loads_per_block < nl { nl = emc_num_loads_per_block; }
    if emc_blocks.len == 0 { irb_set_before(emc_ci); } else { irb_set_end(emc_blocks[bi]); }
    var cmp: i32 = -1;
    let max_ty: i32 = if nl == 1 { -1 } else { ty_int(emc_max_load_size * 8) };
    for _k in nl {
        let e = emc_seq[li];
        let l, r = emc_load_pair(ty_int(e.size * 8), -1, max_ty, e.offset);
        if nl != 1 {
            diff = irb_binop(OP_XOR, l, r, "", false);
            diff = irb_cast(OP_ZEXT, diff, max_ty, "", false);
            xs.push(diff);
        } else {
            cmp = emc_icmp(33, l, r);
        }
        li++;
    }
    if cmp < 0 {
        // pairWiseOr until one value is left
        loop {
            var out: i32[>..<] = [];
            var i: i64 = 0;
            while i + 1 < xs.len { out.push(irb_binop(OP_OR, xs[i], xs[i + 1], "", false)); i += 2; }
            if xs.len % 2 != 0 { out.push(xs[xs.len - 1]); }
            xs.clear();
            for v in out { xs.push(v); }
            if xs.len == 1 { break; }
        }
        cmp = emc_icmp(33, xs[0], c_int(vals[diff].ty, 0));
    }
    return cmp, li;
}

// emitLoadCompareBlockMultipleLoads
fn emc_multi_block(bi: i64, li: i64) -> i64 {
    let cmp, nli = emc_compare_load_pairs(bi, li);
    let next = if bi == emc_blocks.len - 1 { emc_end } else { emc_blocks[bi + 1] };
    let bb = irb_bb;
    let br = emc_condbr(cmp, emc_res_bb, next);
    emc_unknown_weights(br);
    emc_dt2(DT_INSERT, bb, emc_res_bb, DT_INSERT, bb, next);
    if bi == emc_blocks.len - 1 { phi_add_incoming(emc_phi_res, c_int(T_I32, 0), emc_blocks[bi]); }
    return nli;
}

// emitLoadCompareBlock
fn emc_block(bi: i64) {
    let e = emc_seq[bi];
    if e.size == 1 { emc_byte_block(bi, e.offset); return; }
    let load_ty = ty_int(e.size * 8);
    let bswap_ty = ty_int(emc_pow2_ceil(e.size * 8));   // little-endian (x86)
    var mx = emc_pow2_ceil(e.size);
    if emc_max_load_size > mx { mx = emc_max_load_size; }
    let max_ty = ty_int(mx * 8);
    irb_set_end(emc_blocks[bi]);
    let l, r = emc_load_pair(load_ty, bswap_ty, max_ty, e.offset);
    if !emc_zero_cmp {
        phi_add_incoming(emc_phi_src1, l, emc_blocks[bi]);
        phi_add_incoming(emc_phi_src2, r, emc_blocks[bi]);
    }
    let cmp = emc_icmp(32, l, r);
    let next = if bi == emc_blocks.len - 1 { emc_end } else { emc_blocks[bi + 1] };
    let bb = irb_bb;
    let br = emc_condbr(cmp, next, emc_res_bb);
    emc_unknown_weights(br);
    emc_dt2(DT_INSERT, bb, next, DT_INSERT, bb, emc_res_bb);
    if bi == emc_blocks.len - 1 { phi_add_incoming(emc_phi_res, c_int(T_I32, 0), emc_blocks[bi]); }
}

fn emc_first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && (iop(i) == OP_PHI || inst_is_eh_pad(i)) { i = inst_next(i); }
    return i;
}

// emitMemCmpResultBlock
fn emc_result_block() {
    let ip = emc_first_insertion_pt(emc_res_bb);
    irb_set_at(emc_res_bb, ip, true);
    if emc_zero_cmp {
        phi_add_incoming(emc_phi_res, c_int(T_I32, 1), emc_res_bb);
        emc_br(emc_end);
        emc_dt(DT_INSERT, emc_res_bb, emc_end);
        return;
    }
    let cmp = emc_icmp(36, emc_phi_src1, emc_phi_src2);
    let res = irb_select(cmp, c_int(T_I32, -1), c_int(T_I32, 1), "", -1);
    if is_inst(res) { emc_unknown_weights(res); }
    phi_add_incoming(emc_phi_res, res, emc_res_bb);
    emc_br(emc_end);
    emc_dt(DT_INSERT, emc_res_bb, emc_end);
}

// getMemCmpOneBlock: -1 when the call and its user were already replaced
fn emc_one_block() -> i32 {
    let size = emc_size;
    let needs_bswap = size != 1;   // little-endian
    let load_ty = ty_int(size * 8);
    let bswap_ty: i32 = if needs_bswap { ty_int(emc_pow2_ceil(size * 8)) } else { -1 };
    var mx = emc_pow2_ceil(size);
    if emc_max_load_size > mx { mx = emc_max_load_size; }
    let max_ty = ty_int(mx * 8);
    if size == 1 || size == 2 {
        let l, r = emc_load_pair(load_ty, bswap_ty, T_I32, 0);
        return irb_binop(OP_SUB, l, r, "", false);
    }
    let l, r = emc_load_pair(load_ty, bswap_ty, max_ty, 0);
    let ci = emc_ci;
    if ic::has_one_user(ci) {
        let ui = uses[vals[ci].first_use].user;
        var pred: i64 = -1;
        var needs_zext = false;
        let bw = types[vals[ci].ty].n as i64;
        if is_inst_op(ui, OP_LSHR) && m_specific_int(op(ui, 1), (bw - 1) as u64) {
            pred = 40; needs_zext = true;
        } else if is_inst_op(ui, OP_ICMP) && inst_pred(ui) == 38 && op(ui, 0) == ci && m_all_ones(op(ui, 1)) {
            pred = 39;
        } else if is_inst_op(ui, OP_ICMP) && inst_pred(ui) == 40 && op(ui, 0) == ci && m_one(op(ui, 1)) {
            pred = 41;
        } else if is_inst_op(ui, OP_ICMP) && op(ui, 0) == ci && m_zero(op(ui, 1)) {
            pred = inst_pred(ui);
        }
        if pred >= 38 && pred <= 41 {
            let cmp = emc_icmp(pred - 4, l, r);
            let result = if needs_zext { irb_cast(OP_ZEXT, cmp, vals[ui].ty, "", false) } else { cmp };
            rauw(ui, result);
            inst_erase_from_parent(ui);
            inst_erase_from_parent(ci);
            return -1;
        }
    }
    return irb_intrinsic_call(IID_ucmp, [T_I32, vals[l].ty], [l, r], []);
}

// getMemCmpExpansion
fn emc_expansion() -> i32 {
    if emc_num_blocks() != 1 {
        let start = inst_parent(emc_ci);
        emc_end = emc_split_block(start, emc_ci, "endblock");
        // setupEndBlockPHINodes
        irb_set_at(emc_end, block_first(emc_end), true);
        emc_phi_res = irb_phi(T_I32, 2, "phi.res");
        // createResultBlock
        let fv = block_func(start);
        emc_res_bb = create_block_before(fv, emc_end, "res_block");
        if !emc_zero_cmp {
            // setupResultBlockPHINodes
            let t = ty_int(emc_max_load_size * 8);
            irb_set_end(emc_res_bb);
            emc_phi_src1 = irb_phi(t, emc_non_one, "phi.src1");
            emc_phi_src2 = irb_phi(t, emc_non_one, "phi.src2");
        }
        // createLoadCmpBlocks
        for _k in emc_num_blocks() { emc_blocks.push(create_block_before(fv, emc_end, "loadbb")); }
        term_set_succ(block_terminator(start), 0, emc_blocks[0]);
        emc_dt2(DT_INSERT, start, emc_blocks[0], DT_DELETE, start, emc_end);
    }
    irb_dl = inst_get_md(emc_ci, 0);   // SetCurrentDebugLocation(CI->getDebugLoc())
    if emc_zero_cmp {
        if emc_num_blocks() == 1 {
            let cmp, li0 = emc_compare_load_pairs(0, 0);
            return irb_cast(OP_ZEXT, cmp, T_I32, "", false);
        }
        var li: i64 = 0;
        for k in emc_num_blocks() { li = emc_multi_block(k, li); }
        emc_result_block();
        return emc_phi_res;
    }
    if emc_num_blocks() == 1 { return emc_one_block(); }
    for k in emc_num_blocks() { emc_block(k); }
    emc_result_block();
    return emc_phi_res;
}

// SplitBlock(Old, SplitPt, DTU, nullptr, nullptr, Name) (BasicBlockUtils.cpp SplitBlockImpl)
fn emc_split_block(old: i32, at0: i32, name: const u8[:]) -> i32 {
    var at = at0;
    while iop(at) == OP_PHI || inst_is_eh_pad(at) { at = inst_next(at); }
    let nb = split_block(old, at, name);
    if emc_dtu {
        var ups: DTUpdate[>..<] = [];
        ups.push(DTUpdate { kind: DT_INSERT, from: old, to: nb });
        var seen: i32[>..<] = [];
        let t = block_terminator(nb);
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            var dup = false;
            for x in seen { if x == s { dup = true; } }
            if dup { continue; }
            seen.push(s);
            ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: s });
            ups.push(DTUpdate { kind: DT_DELETE, from: old, to: s });
        }
        dtu_apply_updates(ups);
    }
    return nb;
}

// expandMemCmp
fn emc_expand_memcmp(ci: i32, is_bcmp: bool, with_psi: bool, with_bfi: bool) -> bool {
    let fv = block_func(inst_parent(ci));
    if func_has_fn_attr(fv, AK_MinSize) { return false; }
    let sz = cb_arg(ci, 2);
    if vals[sz].kind != VK_CINT { return false; }
    if types[vals[sz].ty].n > 64 { fatal("opt: expand-memcmp with a size wider than 64 bits is not implemented yet in the Goose opt"); }
    let usize = cint_lo(sz);
    if usize == 0 { return false; }
    if usize >= 0x100000000 { return false; }   // far more than MaxNumLoads loads of at most 64 bytes
    let size = usize as i64;
    let zero_cmp = is_bcmp || ic::is_only_used_in_zero_equality_comparison(ci);
    let opt_size = should_optimize_for_size_bb(inst_parent(ci), with_psi, with_bfi);
    if !emc_enable_memcmp_expansion(fv, zero_cmp) { return false; }
    if flag_given("memcmp-num-loads-per-block") { emc_num_loads_per_block = flag_int("memcmp-num-loads-per-block", 1); }
    if opt_size && flag_given("max-loads-per-memcmp-opt-size") { emc_max_num_loads = flag_int("max-loads-per-memcmp-opt-size", 0); }
    if !opt_size && flag_given("max-loads-per-memcmp") { emc_max_num_loads = flag_int("max-loads-per-memcmp", 0); }
    emc_init(ci, size, zero_cmp);
    if emc_num_loads() == 0 { return false; }
    irb_set_before(ci);   // IRBuilder<> Builder(CI)
    irb_set_prefix("");
    let res = emc_expansion();
    if res >= 0 {
        rauw(ci, res);
        inst_erase_from_parent(ci);
    }
    return true;
}

// ExpandMemCmpPass::run + runImpl
fn expand_memcmp_run(fv: i32) -> u32 {
    if func_has_fn_attr(fv, AK_SanitizeAddress) || func_has_fn_attr(fv, AK_SanitizeMemory) ||
       func_has_fn_attr(fv, AK_SanitizeThread) || func_has_fn_attr(fv, AK_SanitizeHWAddress) { return PA_ALL; }
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    let with_psi = psi_cached();
    let with_bfi = with_psi && psi_has_summary;
    if with_bfi { bfi_get(fv); }
    emc_dtu = dt_valid(fv, DT_DOM);
    if emc_dtu { dtu_begin(fv, true, false, true); }
    var calls: i32[>..<] = [];
    var bcmp: bool[>..<] = [];
    each_inst(fv) { i =>
        if iop(i) == OP_CALL && !call_is_nobuiltin(i) {
            let callee = called_function(i);
            if callee >= 0 {
                let lf = tli_get_libfunc(callee);
                if lf == LF_memcmp || lf == LF_bcmp { calls.push(i); bcmp.push(lf == LF_bcmp); }
            }
        }
    };
    var changed = false;
    for k in calls.len {
        if emc_expand_memcmp(calls[k], bcmp[k], with_psi, with_bfi) { changed = true; }
    }
    if changed {
        var bb = func_first_block(fv);
        while bb >= 0 { ai_simplify_instructions_in_block(bb); bb = block_next(bb); }
    }
    if emc_dtu { dtu_flush(); dtu_end(); }
    emc_dtu = false;
    if !changed { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}
