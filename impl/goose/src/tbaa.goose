// TypeBasedAliasAnalysis and ScopedNoAliasAA: ports of llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp
// (TBAANode, TBAAStructTagNode, TBAAStructTypeNode, matchAccessTags, alias, aliasErrno, getModRefInfoMask,
// getMemoryEffects, getModRefInfo) and llvm/lib/Analysis/ScopedNoAliasAA.cpp. Metadata nodes are md ids
// (uniqued, so pointer identity is id equality); -1 is a null node.
import std;
import ir;
import irutil;
import instinfo;
import gen_attrs;
import memloc;

// ---------------------------------------------------------------------------------------------
// Metadata helpers

fn tb_nops(n: i32) -> i64 { mds[n].nops as i64 }
// dyn_cast_or_null<MDNode>(N->getOperand(k))
fn tb_node_op(n: i32, k: i64) -> i32 {
    let o = md_op(n, k);
    if o < 0 || !md_is_node(o) { return -1; }
    return o;
}
// mdconst::dyn_extract<ConstantInt>(N->getOperand(k)): (value, ok)
fn tb_int_op(n: i32, k: i64) -> u64, bool {
    let o = md_op(n, k);
    if o < 0 || mds[o].kind != MK_VALUE { return 0, false; }
    let v = mds[o].extra;
    if vals[v].kind != VK_CINT { return 0, false; }
    return cint_lo(v), true;
}
fn tb_int_op_x(n: i32, k: i64) -> u64 {
    let v, ok = tb_int_op(n, k);
    if !ok { fatal("TBAA: malformed metadata (expected an integer constant)"); }
    return v;
}

// isNewFormatTypeNode
fn tb_is_new_format_type(n: i32) -> bool {
    if tb_nops(n) < 3 { return false; }
    let o = md_op(n, 0);
    return o >= 0 && md_is_node(o);
}

// TBAANode::getParent
fn tb_type_parent(n: i32) -> i32 {
    if tb_is_new_format_type(n) { return tb_node_op(n, 0); }
    if tb_nops(n) < 2 { return -1; }
    return tb_node_op(n, 1);
}

// TBAAStructTagNode
fn tb_tag_base(t: i32) -> i32 { tb_node_op(t, 0) }
fn tb_tag_access(t: i32) -> i32 { tb_node_op(t, 1) }
fn tb_tag_offset(t: i32) -> u64 { tb_int_op_x(t, 2) }
fn tb_tag_is_new_format(t: i32) -> bool {
    if tb_nops(t) < 4 { return false; }
    let a = tb_tag_access(t);
    if a >= 0 && !tb_is_new_format_type(a) { return false; }
    return true;
}
fn tb_tag_is_type_immutable(t: i32) -> bool {
    let opno: i64 = if tb_tag_is_new_format(t) { 4 } else { 3 };
    if tb_nops(t) < opno + 1 { return false; }
    let v, ok = tb_int_op(t, opno);
    if !ok { return false; }
    return (v & 1) != 0;
}

// TBAAStructTypeNode
fn tb_st_num_fields(n: i32) -> i64 {
    let nf = tb_is_new_format_type(n);
    let first: i64 = if nf { 3 } else { 1 };
    let per: i64 = if nf { 3 } else { 2 };
    return (tb_nops(n) - first) / per;
}
fn tb_st_field_type(n: i32, i: i64) -> i32 {
    let nf = tb_is_new_format_type(n);
    let first: i64 = if nf { 3 } else { 1 };
    let per: i64 = if nf { 3 } else { 2 };
    return md_op(n, first + i * per);
}
// TBAAStructTypeNode::getField(Offset): (field type node or -1, new offset)
fn tb_st_get_field(n: i32, off0: u64) -> i32, u64 {
    var off = off0;
    let nf = tb_is_new_format_type(n);
    let nops = tb_nops(n);
    if nf {
        if nops < 6 { return -1, off; }
    } else {
        if nops < 2 { return -1, off; }
        if nops <= 3 {
            let cur: u64 = if nops == 2 { 0 } else { tb_int_op_x(n, 2) };
            off -= cur;
            return tb_node_op(n, 1), off;
        }
    }
    let first: i64 = if nf { 3 } else { 1 };
    let per: i64 = if nf { 3 } else { 2 };
    var the: i64 = 0;
    var idx = first;
    while idx < nops {
        let cur = tb_int_op_x(n, idx + 1);
        if cur > off { the = idx - per; break; }
        idx += per;
    }
    if the == 0 { the = nops - per; }
    let cur = tb_int_op_x(n, the + 1);
    off -= cur;
    return tb_node_op(n, the), off;
}

// getLeastCommonType
fn tb_least_common_type(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    var pa: i32[>..<] = [];
    var x = a;
    while x >= 0 {
        for y in pa { if y == x { fatal("Cycle found in TBAA metadata."); } }
        pa.push(x);
        x = tb_type_parent(x);
    }
    var pb: i32[>..<] = [];
    x = b;
    while x >= 0 {
        for y in pb { if y == x { fatal("Cycle found in TBAA metadata."); } }
        pb.push(x);
        x = tb_type_parent(x);
    }
    var ia = pa.len - 1;
    var ib = pb.len - 1;
    var ret: i32 = -1;
    while ia >= 0 && ib >= 0 {
        if pa[ia] == pb[ib] { ret = pa[ia]; } else { break; }
        ia--;
        ib--;
    }
    return ret;
}

recursive fn tb_has_field(base: i32, field: i32) -> bool {
    let n = tb_st_num_fields(base);
    for i in n {
        let t = tb_st_field_type(base, i);
        if t == field || tb_has_field(t, field) { return true; }
    }
    return false;
}

// mayBeAccessToSubobjectOf (without the GenericTag output): (matched, MayAlias)
fn tb_may_be_access_to_subobject_of(base_tag: i32, sub_tag: i32, common: i32) -> bool, bool {
    if tb_tag_access(base_tag) == tb_tag_base(base_tag) && tb_tag_access(base_tag) == common { return true, true; }
    let nf = tb_tag_is_new_format(base_tag);
    var bt = tb_tag_base(base_tag);
    var off = tb_tag_offset(base_tag);
    loop {
        if bt < 0 { break; }
        if bt == tb_tag_base(sub_tag) {
            let may = off == tb_tag_offset(sub_tag) || bt == tb_tag_access(base_tag) || tb_tag_base(sub_tag) == tb_tag_access(sub_tag);
            return true, may;
        }
        if nf && bt == tb_tag_access(base_tag) { break; }
        let nb, noff = tb_st_get_field(bt, off);
        bt = nb;
        off = noff;
    }
    if nf {
        let ft = tb_tag_base(sub_tag);
        if bt >= 0 && tb_has_field(bt, ft) { return true, true; }
    }
    return false, false;
}

// matchAccessTags(A, B) == TypeBasedAAResult::Aliases
fn tb_aliases(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if a < 0 || b < 0 { return true; }
    let common = tb_least_common_type(tb_tag_access(a), tb_tag_access(b));
    if common < 0 { return true; }
    let m1, may1 = tb_may_be_access_to_subobject_of(a, b, common);
    if m1 { return may1; }
    let m2, may2 = tb_may_be_access_to_subobject_of(b, a, common);
    if m2 { return may2; }
    return false;
}

// shouldUseTBAA: -enable-tbaa and not sanitize_type on the function
fn tb_enabled(fv: i32) -> bool { tbaa_flag_enabled && !(fv >= 0 && func_has_fn_attr(fv, AK_SanitizeType)) }
var tbaa_flag_enabled: bool = true;

// TypeBasedAAResult::alias: true = MayAlias, false = NoAlias
fn tbaa_alias_may(fv: i32, a: ML, b: ML) -> bool {
    if !tb_enabled(fv) { return true; }
    return tb_aliases(a.tbaa, b.tbaa);
}

// TypeBasedAAResult::aliasErrno: true = MayAlias
fn tbaa_alias_errno_may(fv: i32, loc: ML, m: i32) -> bool {
    if !tb_enabled(fv) { return true; }
    let n = loc.tbaa;
    if n < 0 { return true; }
    var found = false;
    var nm: i32 = -1;
    let key = intern("llvm.errno.tbaa");
    for x, i in named_mds { if x.name == key && x.module == m { nm = i as i32; found = true; } }
    if !found { return true; }
    let r = named_mds[nm];
    for k in r.nops {
        if tb_aliases(n, md_ops[r.ops + k]) { return true; }
    }
    return false;
}

fn tbaa_mod_ref_mask(fv: i32, loc: ML) -> i64 {
    if !tb_enabled(fv) { return MR_MODREF; }
    if loc.tbaa < 0 { return MR_MODREF; }
    if tb_tag_is_type_immutable(loc.tbaa) { return MR_NO; }
    return MR_MODREF;
}

fn tbaa_call_memory_effects(fv: i32, c: i32) -> u64 {
    if !tb_enabled(fv) { return me_of(MR_MODREF); }
    let m = inst_get_md(c, MDK_TBAA);
    if m >= 0 && tb_tag_is_type_immutable(m) { return ME_NONE; }
    return me_of(MR_MODREF);
}

fn tbaa_call_mod_ref(fv: i32, c: i32, loc: ML) -> i64 {
    if !tb_enabled(fv) { return MR_MODREF; }
    if loc.tbaa >= 0 {
        let m = inst_get_md(c, MDK_TBAA);
        if m >= 0 && !tb_aliases(loc.tbaa, m) { return MR_NO; }
    }
    return MR_MODREF;
}

fn tbaa_call_call_mod_ref(fv: i32, c1: i32, c2: i32) -> i64 {
    if !tb_enabled(fv) { return MR_MODREF; }
    let m1 = inst_get_md(c1, MDK_TBAA);
    let m2 = inst_get_md(c2, MDK_TBAA);
    if m1 >= 0 && m2 >= 0 && !tb_aliases(m1, m2) { return MR_NO; }
    return MR_MODREF;
}

// ---------------------------------------------------------------------------------------------
// ScopedNoAliasAA

var sna_flag_enabled: bool = true;

// AliasScopeNode::getDomain
fn sna_domain(n: i32) -> i32 {
    if tb_nops(n) < 2 { return -1; }
    return tb_node_op(n, 1);
}

// mayAliasInScopes(Scopes, NoAlias)
fn sna_may_alias_in_scopes(scopes: i32, noalias: i32) -> bool {
    if scopes < 0 || noalias < 0 { return true; }
    // collectScopedDomains (a set; iteration order doesn't change the answer)
    var domains: i32[>..<] = [];
    for k in tb_nops(noalias) {
        let na = tb_node_op(noalias, k);
        if na < 0 { continue; }
        let d = sna_domain(na);
        if d < 0 { continue; }
        var dup = false;
        for x in domains { if x == d { dup = true; } }
        if !dup { domains.push(d); }
    }
    for d in domains {
        // ScopeNodes = scopes in domain d; NANodes = noalias nodes in domain d; subset test
        var any = false;
        var subset = true;
        for k in tb_nops(scopes) {
            let s = tb_node_op(scopes, k);
            if s < 0 || sna_domain(s) != d { continue; }
            any = true;
            var found = false;
            for j in tb_nops(noalias) {
                let x = tb_node_op(noalias, j);
                if x == s && sna_domain(x) == d { found = true; }
            }
            if !found { subset = false; }
        }
        if !any { continue; }
        if subset { return false; }
    }
    return true;
}

// ScopedNoAliasAAResult::alias: true = MayAlias
fn sna_alias_may(a: ML, b: ML) -> bool {
    if !sna_flag_enabled { return true; }
    if !sna_may_alias_in_scopes(a.scope, b.noalias) { return false; }
    if !sna_may_alias_in_scopes(b.scope, a.noalias) { return false; }
    return true;
}

fn sna_call_mod_ref(c: i32, loc: ML) -> i64 {
    if !sna_flag_enabled { return MR_MODREF; }
    if !sna_may_alias_in_scopes(loc.scope, inst_get_md(c, MDK_NOALIAS)) { return MR_NO; }
    if !sna_may_alias_in_scopes(inst_get_md(c, MDK_ALIAS_SCOPE), loc.noalias) { return MR_NO; }
    return MR_MODREF;
}

fn sna_call_call_mod_ref(c1: i32, c2: i32) -> i64 {
    if !sna_flag_enabled { return MR_MODREF; }
    if !sna_may_alias_in_scopes(inst_get_md(c1, MDK_ALIAS_SCOPE), inst_get_md(c2, MDK_NOALIAS)) { return MR_NO; }
    if !sna_may_alias_in_scopes(inst_get_md(c2, MDK_ALIAS_SCOPE), inst_get_md(c1, MDK_NOALIAS)) { return MR_NO; }
    return MR_MODREF;
}

// createAccessTag(AccessType)
fn tb_create_access_tag(t: i32) -> i32 {
    if t < 0 || tb_nops(t) < 2 { return -1; }
    let off = md_value(c_int(T_I64, 0));
    if tb_is_new_format_type(t) {
        let sz = md_value(c_int(T_I64, -1));
        return md_get(MK_TUPLE, -1, [t, t, off, sz], false);
    }
    return md_get(MK_TUPLE, -1, [t, t, off], false);
}

// mayBeAccessToSubobjectOf with the GenericTag output: (matched, MayAlias, GenericTag)
fn tb_may_be_access_to_subobject_of_g(base_tag: i32, sub_tag: i32, common: i32) -> bool, bool, i32 {
    if tb_tag_access(base_tag) == tb_tag_base(base_tag) && tb_tag_access(base_tag) == common {
        return true, true, tb_create_access_tag(common);
    }
    let nf = tb_tag_is_new_format(base_tag);
    var bt = tb_tag_base(base_tag);
    var off = tb_tag_offset(base_tag);
    loop {
        if bt < 0 { break; }
        if bt == tb_tag_base(sub_tag) {
            let may = off == tb_tag_offset(sub_tag) || bt == tb_tag_access(base_tag) || tb_tag_base(sub_tag) == tb_tag_access(sub_tag);
            return true, may, if may { sub_tag } else { tb_create_access_tag(common) };
        }
        if nf && bt == tb_tag_access(base_tag) { break; }
        let nb, noff = tb_st_get_field(bt, off);
        bt = nb;
        off = noff;
    }
    if nf {
        let ft = tb_tag_base(sub_tag);
        if bt >= 0 && tb_has_field(bt, ft) { return true, true, tb_create_access_tag(common); }
    }
    return false, false, -1;
}

// MDNode::getMostGenericTBAA(A, B) (matchAccessTags with GenericTag)
fn tb_most_generic_tbaa(a: i32, b: i32) -> i32 {
    if a == b { return a; }
    if a < 0 || b < 0 { return -1; }
    let common = tb_least_common_type(tb_tag_access(a), tb_tag_access(b));
    if common < 0 { return -1; }
    let m1, may1, g1 = tb_may_be_access_to_subobject_of_g(a, b, common);
    if m1 { return g1; }
    let m2, may2, g2 = tb_may_be_access_to_subobject_of_g(b, a, common);
    if m2 { return g2; }
    return tb_create_access_tag(common);
}
