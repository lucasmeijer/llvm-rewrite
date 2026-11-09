// ValueToValueMapTy and the ValueMapper: port of llvm/lib/Transforms/Utils/ValueMapper.cpp (Mapper::mapValue,
// mapSimpleMetadata, mapMetadata for RF_NoModuleLevelChanges, remapInstruction, remapDbgRecord,
// mapBlockAddress) and of llvm/include/llvm/IR/ValueMap.h / ValueMapper.h (ValueToValueMapTy with its MD map,
// RemapInstruction, RemapDbgRecordRange, MapValue, MapMetadata).
//
// A ValueToValueMapTy is a map id (`vmm_new`); maps live on a stack (`vmm_mark` / `vmm_release`), like the
// scoped C++ containers. Keys are value ids (never reused, so a dead key simply stays unmatched) and metadata
// ids (the MD() map). The mapped value is a plain value id; the WeakTrackingVH semantics LLVM's map has are
// approximated as "a mapped value that has been erased reads as null" (`vmm_get`). RAUW of a mapped value is
// not followed (no caller of ours RAUWs a mapped value while its map is alive). Iteration (`vmm_first` /
// `vmm_next`) is insertion order; LLVM iterates a DenseMap, and every caller only copies entries.
//
// Not ported (fail loudly): module-level changes (MDNodeMapper: mapping distinct/uniqued nodes without
// RF_NoModuleLevelChanges), type remapping, value materializers, constant expressions whose operands change
// (other than a blockaddress of a mapped block), key-instruction atom groups (mapAtomInstance / RemapSourceAtom).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import dinfo;
import salvage;
import parser;

let RF_NO_MODULE_LEVEL_CHANGES: i64 = 1;
let RF_IGNORE_MISSING_LOCALS: i64 = 2;
let RF_NULL_MAP_MISSING_GLOBAL_VALUES: i64 = 8;

let MDK_CALLEE_TYPE: i32 = 42;

fn vmp_not_ported(what: const u8[:]) { fatal(str("ValueMapper: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// ValueToValueMapTy

struct VMEnt { map: i32, key: i32, val: i32, onext: i32, epoch: i32 }
struct VMHead { epoch: i32, first: i32, last: i32 }
var vmm_heads: VMHead[>..<];
var vmm_ents: VMEnt[>..<];
var vmm_tab: i32[>..];        // open addressing over vmm_ents; -1 = empty
var vmm_used: i64 = 0;
var vmm_epoch_ctr: i32 = 0;

let VMM_ERASED: i32 = -3;

fn vmm_mark() -> i64 { vmm_heads.len }
fn vmm_release(mark: i64) {
    vmm_heads.resize(mark);
    if mark == 0 { vmm_ents.resize(0); vmm_tab.resize(0); vmm_used = 0; }
}
fn vmm_new() -> i32 {
    vmm_epoch_ctr += 1;
    let m = vmm_heads.len as i32;
    vmm_heads.push(VMHead { epoch: vmm_epoch_ctr, first: -1, last: -1 });
    return m;
}
fn vmm_clear(m: i32) {
    vmm_epoch_ctr += 1;
    vmm_heads[m].epoch = vmm_epoch_ctr;
    vmm_heads[m].first = -1;
    vmm_heads[m].last = -1;
}
fn vmm_hash(m: i32, k: i32) -> u64 {
    var x = ((m as u64) << 32) ^ ((k as! u32) as u64);
    x = x * 0x9E3779B97F4A7C15;
    x ^= x >> 29;
    return x;
}
fn vmm_live(e: i32) -> bool {
    let x = vmm_ents[e];
    return x.map < vmm_heads.len as i32 && vmm_heads[x.map].epoch == x.epoch && x.val != VMM_ERASED;
}
// the table slot holding (m, k), or the empty slot where it would go
fn vmm_slot(m: i32, k: i32) -> i64 {
    let n = vmm_tab.len;
    var j = (vmm_hash(m, k) & ((n - 1) as u64)) as i64;
    loop {
        let e = vmm_tab[j];
        if e < 0 { return j; }
        if vmm_ents[e].map == m && vmm_ents[e].key == k { return j; }
        j = (j + 1) & (n - 1);
    }
    return -1;
}
fn vmm_rehash() {
    var live: i32[>..<] = [];
    for e in vmm_tab { if e >= 0 && vmm_live(e) { live.push(e); } }
    var n: i64 = 64;
    while n < live.len * 4 { n *= 2; }
    vmm_tab.resize(0);
    for k in n { vmm_tab.push(-1); }
    vmm_used = 0;
    for e in live {
        let j = vmm_slot(vmm_ents[e].map, vmm_ents[e].key);
        vmm_tab[j] = e;
        vmm_used++;
    }
}
fn vmm_find(m: i32, k: i32) -> i32 {
    if vmm_tab.len == 0 { return -1; }
    let e = vmm_tab[vmm_slot(m, k)];
    if e < 0 || !vmm_live(e) { return -1; }
    return e;
}
// VMap.count(K)
fn vmm_has(m: i32, k: i32) -> bool { vmm_find(m, k) >= 0 }
// VMap.lookup(K): the mapped value, -1 if none (or if the mapped value has been erased: WeakTrackingVH)
fn vmm_get(m: i32, k: i32) -> i32 {
    let e = vmm_find(m, k);
    if e < 0 { return -1; }
    let v = vmm_ents[e].val;
    if v >= 0 && is_dead(v) { return -1; }
    return v;
}
// VMap[K] = V
fn vmm_set(m: i32, k: i32, v: i32) {
    if vmm_tab.len == 0 || (vmm_used + 1) * 2 > vmm_tab.len { vmm_rehash(); }
    let j = vmm_slot(m, k);
    let e = vmm_tab[j];
    if e >= 0 && vmm_live(e) { vmm_ents[e].val = v; return; }
    let ne = vmm_ents.len as i32;
    vmm_ents.push(VMEnt { map: m, key: k, val: v, onext: -1, epoch: vmm_heads[m].epoch });
    if vmm_heads[m].last >= 0 { vmm_ents[vmm_heads[m].last].onext = ne; } else { vmm_heads[m].first = ne; }
    vmm_heads[m].last = ne;
    if e < 0 { vmm_used++; }
    vmm_tab[j] = ne;
}
fn vmm_erase(m: i32, k: i32) {
    let e = vmm_find(m, k);
    if e >= 0 { vmm_ents[e].val = VMM_ERASED; }
}
// iteration in insertion order over live entries: e = vmm_first(m); while e >= 0 { ...; e = vmm_next(e); }
fn vmm_skip(e0: i32) -> i32 {
    var e = e0;
    while e >= 0 && !vmm_live(e) { e = vmm_ents[e].onext; }
    // an entry for the same key re-set later is the same entry (vmm_set updates in place)
    return e;
}
fn vmm_first(m: i32) -> i32 { vmm_skip(vmm_heads[m].first) }
fn vmm_next(e: i32) -> i32 { vmm_skip(vmm_ents[e].onext) }
fn vmm_ent_key(e: i32) -> i32 { vmm_ents[e].key }
fn vmm_ent_val(e: i32) -> i32 { let v = vmm_ents[e].val; if v >= 0 && is_dead(v) { -1 } else { v } }
fn vmm_is_md_key(k: i32) -> bool { k <= -2 }
// VMap.MD(): metadata keys are stored as -2 - md
fn vmm_md_get(m: i32, md: i32) -> i32 { vmm_get(m, -2 - md) }
fn vmm_md_has(m: i32, md: i32) -> bool { vmm_has(m, -2 - md) }
fn vmm_md_set(m: i32, md: i32, v: i32) { vmm_set(m, -2 - md, v) }
// Copy every entry of `src` into `dst` (for (auto &KV : Src) Dst[KV.first] = KV.second).
fn vmm_copy_into(dst: i32, src: i32) {
    var e = vmm_first(src);
    while e >= 0 { vmm_set(dst, vmm_ents[e].key, vmm_ents[e].val); e = vmm_next(e); }
}

// ---------------------------------------------------------------------------------------------
// Mapper

var vmp_stack: i32[>..<];

// Mapper::mapValue(V): -1 = nullptr
recursive fn vmp_map_value(m: i32, v: i32, flags: i64) -> i32 {
    let found = vmm_find(m, v);
    if found >= 0 {
        let r = vmm_ents[found].val;
        if r >= 0 && !is_dead(r) { return r; }
        fatal("internal: ValueMapper: unexpected null mapping");
    }
    let k = vals[v].kind;
    if k <= VK_GVAR {
        if (flags & RF_NULL_MAP_MISSING_GLOBAL_VALUES) != 0 { return -1; }
        vmm_set(m, v, v);
        return v;
    }
    if k == VK_INLINEASM { vmm_set(m, v, v); return v; }
    if k == VK_MDVAL {
        let md = vals[v].sub;
        if mds[md].kind == MK_VALUE && !is_constant(mds[md].extra) {
            // LocalAsMetadata: look through to the local value
            let lv = vmp_map_value(m, mds[md].extra, flags);
            if lv >= 0 { return get_md_as_value(md_value(lv)); }
            if (flags & RF_IGNORE_MISSING_LOCALS) != 0 { return -1; }
            return get_md_as_value(md_get(MK_TUPLE, -1, [], false));
        }
        if mds[md].kind == MK_DIARGLIST {
            let mark = vmp_stack.len;
            for j in mds[md].nops as i64 {
                let vam = md_op(md, j);
                let x = mds[vam].extra;
                if (flags & RF_NO_MODULE_LEVEL_CHANGES) != 0 && is_constant(x) { vmp_stack.push(vam); continue; }
                let lv = vmp_map_value(m, x, flags);
                if lv >= 0 { vmp_stack.push(if lv == x { vam } else { md_value(lv) }); }
                else if (flags & RF_IGNORE_MISSING_LOCALS) != 0 && !is_constant(x) { vmp_stack.push(vam); }
                else { vmp_stack.push(md_value(c_poison(vals[x].ty))); }
            }
            let nmd = md_get(MK_DIARGLIST, -1, vmp_stack[mark..], false);
            vmp_stack.resize(mark);
            return get_md_as_value(nmd);
        }
        if (flags & RF_NO_MODULE_LEVEL_CHANGES) != 0 { vmm_set(m, v, v); return v; }
        let mm = vmp_map_metadata(m, md, flags);
        if mm == md { vmm_set(m, v, v); return v; }
        let nv = get_md_as_value(mm);
        vmm_set(m, v, nv);
        return nv;
    }
    if !is_constant(v) { return -1; }
    if k == VK_BLOCKADDR { return vmp_map_block_address(m, v, flags); }
    // other constants: identity unless an operand maps elsewhere
    let n = nops(v);
    for j in n {
        let o = op(v, j);
        let mo = vmp_map_value(m, o, flags);
        if mo < 0 { return -1; }
        if mo != o { vmp_not_ported("remapping a constant whose operands change"); }
    }
    vmm_set(m, v, v);
    return v;
}

// Mapper::mapBlockAddress: blockaddress(F, BB) with BB mapped (F is not, under RF_NoModuleLevelChanges)
recursive fn vmp_map_block_address(m: i32, ba: i32, flags: i64) -> i32 {
    let f = vmp_map_value(m, op(ba, 0), flags);
    let bb = op(ba, 1);
    var nbb = vmm_get(m, bb);
    if nbb < 0 { nbb = bb; }
    if f == op(ba, 0) && nbb == bb { vmm_set(m, ba, ba); return ba; }
    let r = cst_get(VK_BLOCKADDR, ty_ptr(0), cst_none(), [f, nbb]);
    vmm_set(m, ba, r);
    return r;
}

// Mapper::mapSimpleMetadata + mapMetadata. -1 = nullptr.
fn vmp_map_metadata(m: i32, md: i32, flags: i64) -> i32 {
    if md < 0 { return -1; }
    let e = vmm_find(m, -2 - md);
    if e >= 0 { return vmm_ents[e].val; }
    if mds[md].kind == MK_STRING { return md; }
    if (flags & RF_NO_MODULE_LEVEL_CHANGES) != 0 { return md; }
    vmp_not_ported("mapping metadata with module-level changes (MDNodeMapper)");
    return md;
}

// RemapSourceAtom / mapAtomInstance: atom groups are not ported
fn vmp_check_atom(i: i32) {
    let dl = inst_get_md(i, 0);
    if dl >= 0 && mds[dl].kind == MK_DI && di_kind(dl) == DIK_LOCATION && di_int(dl, "atomGroup") != 0 {
        vmp_not_ported("key-instructions atom groups (mapAtomInstance)");
    }
}

// RemapInstruction(I, VM, Flags) = Mapper::remapInstruction
fn remap_instruction(i: i32, m: i32, flags: i64) {
    for k in nops(i) {
        let o = op(i, k);
        if o < 0 { continue; }
        let nv = vmp_map_value(m, o, flags);
        if nv >= 0 { set_op(i, k, nv); }
        else if (flags & RF_IGNORE_MISSING_LOCALS) == 0 { fatal("internal: ValueMapper: referenced value not in value map"); }
    }
    if is_callbase(i) {
        if inst_get_md(i, MDK_CALLEE_TYPE) >= 0 && called_operand_is_direct(i) { inst_set_md(i, MDK_CALLEE_TYPE, -1); }
    }
    if iop(i) == OP_PHI {
        for k in nops(i) {
            let b = phi_block(i, k);
            let nb = vmp_map_value(m, b, flags);
            if nb >= 0 { phi_set_block(i, k, nb); }
            else if (flags & RF_IGNORE_MISSING_LOCALS) == 0 { fatal("internal: ValueMapper: referenced block not in value map"); }
        }
    }
    // attached metadata: identity under RF_NoModuleLevelChanges unless the MD map says otherwise
    let ii = inst_of(i);
    let nmd = insts[ii].nmd;
    for k in nmd {
        let kind = md_att[insts[ii].md + 2 * k];
        let old = md_att[insts[ii].md + 2 * k + 1];
        let nw = vmp_map_metadata(m, old, flags);
        if nw != old { inst_set_md(i, kind, nw); }
    }
}
// !CB->isIndirectCall()
fn called_operand_is_direct(i: i32) -> bool {
    let c = cb_callee(i);
    return vals[c].kind == VK_FUNC || vals[c].kind == VK_INLINEASM;
}

// RemapDbgRecord(M, DR, VM, Flags) = Mapper::remapDbgRecord
fn remap_dbg_record(r: i32, m: i32, flags: i64) {
    let dl = vmp_map_metadata(m, dbgrecs[r].dl, flags);
    dbgrecs[r].dl = dl;
    let kind = dbgrecs[r].kind as i64;
    if kind == DR_LABEL {
        dbgrecs[r].dvar = vmp_map_metadata(m, dbgrecs[r].dvar, flags);
        return;
    }
    dbgrecs[r].dvar = vmp_map_metadata(m, dbgrecs[r].dvar, flags);
    let ignore = (flags & RF_IGNORE_MISSING_LOCALS) != 0;
    if kind == DR_ASSIGN {
        vmp_not_ported("remapping #dbg_assign records");
    }
    var vs: i32[>..<] = [];
    dbg_location_ops(r, vs);
    var nvs: i32[>..<] = [];
    var same = true;
    var any_null = false;
    for v in vs {
        let nv = vmp_map_value(m, v, flags);
        nvs.push(nv);
        if nv != v { same = false; }
        if nv < 0 { any_null = true; }
    }
    if same { return; }
    if !ignore && any_null { sv_set_kill_location(r); return; }
    for j in vs.len { if nvs[j] >= 0 { dbg_replace_location_op_idx(r, j, nvs[j]); } }
}
// RemapDbgRecordRange(M, I->getDbgRecordRange(), VM, Flags)
fn remap_dbg_record_range(i: i32, m: i32, flags: i64) {
    var r = inst_first_dbg(i);
    while r >= 0 { let nx = dbgrecs[r].next; remap_dbg_record(r, m, flags); r = nx; }
}
// MapValue(V, VM, Flags): -1 = nullptr
fn map_value(v: i32, m: i32, flags: i64) -> i32 { vmp_map_value(m, v, flags) }
