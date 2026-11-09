// IVUsers (print<iv-users>).
// Port of llvm/lib/Analysis/IVUsers.cpp (LLVM 23.1.5): isInteresting, IVUseShouldUsePostIncValue (in
// scev_create.goose, next to the normalization rewriter it is the predicate of), AddUsersIfInteresting, AddUser,
// the IVUsers constructor (with CodeMetrics::collectEphemeralValues), print, getReplacementExpr. Not ported
// (only LSR needs them): getExpr, findAddRecForLoop, getStride, IVStrideUse::transformToPostInc/deleted.
// The post-increment normalization (ScalarEvolutionNormalization.cpp) is
// scev_create.goose's RW_NORMALIZE rewriter.
//
// One IVUsers at a time (the analysis of the loop being printed). AddUsersIfInteresting recurses, so its
// UniqueUsers lists are runs on iu_stack.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import datalayout;
import flags;
import speculate;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_eval;
import scev_btc;

// IVStrideUse: the user, the operand (OperandValToReplace) and PostIncLoops (a SmallPtrSet<Loop*, 2>: printed in
// insertion order while it has at most two loops)
struct IUse { user: i32, oper: i32, pl0: i32, pl1: i32, npl: i32 }

var iu_l: i32 = -1;
var iu_processed = hm_new();
var iu_uses: IUse[>..<];
var iu_eph = hm_new();
var iu_stack: i32[>..<];

// isInteresting(S, I, L, SE, LI)
recursive fn iu_is_interesting(s: i32, i: i32, l: i32) -> bool {
    if sc_is_addrec(s) {
        if sc_loop(s) == l {
            return sc_is_affine(s) || (!loop_contains(l, inst_parent(i)) && sc_get_scev_at_scope(s, li_loop_for(inst_parent(i))) != s);
        }
        return iu_is_interesting(sc_op(s, 0), i, l) && !iu_is_interesting(sc_get_step_recurrence(s), i, l);
    }
    if sc_kind(s) == SC_ADD {
        var any = false;
        for k in sc_nops(s) {
            if iu_is_interesting(sc_op(s, k), i, l) {
                if any { return false; }
                any = true;
            }
        }
        return any;
    }
    return false;
}

// AddUsersIfInteresting(I)
recursive fn iu_add_users_if_interesting(i: i32) -> bool {
    if hm_has(iu_processed, i as u64) { return true; }
    hm_put(iu_processed, i as u64, 1);
    if !sc_is_scevable(vals[i].ty) { return false; }
    if iop(i) != OP_PHI && !spec_safe(i, -1, false) { return false; }
    let width = sc_type_bits(vals[i].ty);
    if width > 64 || !dl_is_legal_integer(width) { return false; }
    if hm_has(iu_eph, i as u64) { return false; }
    var ise = sc_get_scev(i);
    if !iu_is_interesting(ise, i, iu_l) { return false; }
    // UniqueUsers, in use-list order
    let mark = iu_stack.len;
    var u = vals[i].first_use;
    while u >= 0 {
        let user = uses[u].user;
        u = uses[u].next;
        var seen = false;
        for k in mark..iu_stack.len { if iu_stack[k] == user { seen = true; break; } }
        if !seen { iu_stack.push(user); }
    }
    let end = iu_stack.len;
    var k = mark;
    while k < end {
        let user = iu_stack[k];
        k++;
        if iop(user) == OP_PHI && hm_has(iu_processed, user as u64) { continue; }
        var add = false;
        if li_loop_for(inst_parent(user)) != iu_l {
            if iop(user) == OP_PHI || hm_has(iu_processed, user as u64) || !iu_add_users_if_interesting(user) { add = true; }
        } else if hm_has(iu_processed, user as u64) || !iu_add_users_if_interesting(user) {
            add = true;
        }
        if add {
            iu_uses.push(IUse { user: user, oper: i, pl0: -1, pl1: -1, npl: 0 });
            let orig = ise;
            // normalizeForPostIncUseIf(ISE, NormalizePred): the accepted loops become NewUse.PostIncLoops
            sc_norm_loops.clear();
            sc_norm_iv_pred = true;
            sc_norm_user = user;
            sc_norm_oper = i;
            ise = sc_normalize_for_post_inc_use_if(ise);
            sc_norm_iv_pred = false;
            iu_set_post_inc_loops(iu_uses.len - 1);
            if orig != ise {
                let den = sc_denormalize_for_post_inc_use(ise);
                if orig != den {
                    iu_uses.pop();
                    iu_stack.resize(mark);
                    return false;
                }
            }
        }
    }
    iu_stack.resize(mark);
    return true;
}
recursive fn iu_set_post_inc_loops(k: i64) {
    let n = sc_norm_loops.len;
    if n > 2 { fatal("IVUsers: a use post-incremented in more than two loops (SmallPtrSet order) is not supported"); }
    iu_uses[k].npl = n as i32;
    if n >= 1 { iu_uses[k].pl0 = sc_norm_loops[0]; }
    if n >= 2 { iu_uses[k].pl1 = sc_norm_loops[1]; }
}

// CodeMetrics::collectEphemeralValues(L, AC, EphValues)
fn iu_collect_ephemeral_values(l: i32) {
    hm_clear(iu_eph);
    var visited = hm_new();
    var wl: i32[>..<] = [];
    fn append_speculatable_operands(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            if hm_has(visited, o as u64) { continue; }
            hm_put(visited, o as u64, 1);
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    let fv = block_func(loop_header(l));
    var b = func_entry(fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if inst_iid(i) == IID_assume && loop_contains(l, inst_parent(i)) {
                if !hm_has(iu_eph, i as u64) { hm_put(iu_eph, i as u64, 1); append_speculatable_operands(i); }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !hm_has(iu_eph, uses[u].user as u64) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        hm_put(iu_eph, v as u64, 1);
        append_speculatable_operands(v);
    }
}

// IVUsers(L, AC, LI, DT, SE)
fn iu_build(l: i32) {
    iu_l = l;
    hm_clear(iu_processed);
    iu_uses.clear();
    iu_stack.clear();
    iu_collect_ephemeral_values(l);
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI {
        iu_add_users_if_interesting(p);
        p = inst_next(p);
    }
}

// IVUsersPrinterPass::run: IVUsers::print
fn print_iv_users(l: i32) {
    let fv = block_func(loop_header(l));
    scev_get(fv);
    iu_build(l);
    errs("IV Users for loop ");
    errs_operand(loop_header(l), fv, false);
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if !sc_is_cnc(btc) {
        errs(" with backedge-taken count ");
        sc_print(btc);
    }
    errs(":\n");
    for k in iu_uses.len {
        let u = iu_uses[k];
        errs("  ");
        errs_operand(u.oper, fv, false);
        errs(" = ");
        sc_print(sc_get_scev(u.oper));
        for j in u.npl {
            errs(" (post-inc with loop ");
            errs_operand(loop_header(if j == 0 { u.pl0 } else { u.pl1 }), fv, false);
            errs(")");
        }
        errs(" in  ");
        if u.user >= 0 { errs_inst(u.user, fv); } else { errs("Printing <null> User"); }
        errs("\n");
    }
}
