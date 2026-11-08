// print<scalar-evolution>: ScalarEvolutionPrinterPass, ScalarEvolution::print and PrintLoopInfo
// (llvm/lib/Analysis/ScalarEvolution.cpp).
import std;
import scev_guards;
import ir;
import irutil;
import flags;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;
import scev_lt;

fn print_scev(fv: i32) {
    scev_get(fv);
    errs("Printing analysis 'Scalar Evolution Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    sc_print_all();
}

fn sc_disp_name(d: i64) -> const u8[:] {
    if d == LD_VARIANT { return "Variant"; }
    if d == LD_INVARIANT { return "Invariant"; }
    if d == LD_UNIFORM { return "Uniform"; }
    return "Computable";
}

// PrintSCEVWithTypeHint
fn sc_print_with_type_hint(s: i32) {
    if sc_is_const(s) { sc_errs_type(sc_ty(s)); errs(" "); }
    sc_print(s);
}

fn sc_is_cmp_inst(i: i32) -> bool { iop(i) == OP_ICMP || iop(i) == OP_FCMP }

// depth_first(L) excluding L itself: preorder
fn sc_print_inner_dispositions(s: i32, l: i32) {
    var stack: i32[>..<] = [];
    var k = loop_nsubs(l) - 1;
    while k >= 0 { stack.push(loop_sub(l, k)); k--; }
    while stack.len > 0 {
        let x = stack.pop();
        errs(", ");
        errs_operand(loop_header(x), sc_fv, false);
        errs(": ");
        errs(sc_disp_name(sc_get_loop_disposition(s, x)));
        var j = loop_nsubs(x) - 1;
        while j >= 0 { stack.push(loop_sub(x, j)); j--; }
    }
}

fn sc_print_all() {
    let fv = sc_fv;
    if sc_classify_expressions {
        errs("Classifying expressions for: ");
        errs_operand(fv, fv, false);
        errs("\n");
        var insts_list: i32[>..<] = [];
        each_inst(fv) { i => insts_list.push(i); };
        for i in insts_list {
            if !sc_is_scevable(vals[i].ty) || sc_is_cmp_inst(i) { continue; }
            errs_inst(i, fv);
            errs("\n");
            errs("  -->  ");
            let sv = sc_get_scev(i);
            sc_print(sv);
            if !sc_is_cnc(sv) {
                errs(" U: ");
                sc_errs_range(sc_get_unsigned_range(sv));
                errs(" S: ");
                sc_errs_range(sc_get_signed_range(sv));
            }
            let l = li_loop_for(inst_parent(i));
            let at_use = sc_get_scev_at_scope(sv, l);
            if at_use != sv {
                errs("  -->  ");
                sc_print(at_use);
                if !sc_is_cnc(at_use) {
                    errs(" U: ");
                    sc_errs_range(sc_get_unsigned_range(at_use));
                    errs(" S: ");
                    sc_errs_range(sc_get_signed_range(at_use));
                }
            }
            if l >= 0 {
                errs("\t\tExits: ");
                let ev = sc_get_scev_at_scope(sv, loop_parent(l));
                if !sc_is_loop_invariant(ev, l) { errs("<<Unknown>>"); } else { sc_print(ev); }
                var first = true;
                var it = l;
                while it >= 0 {
                    if first { errs("\t\tLoopDispositions: { "); first = false; } else { errs(", "); }
                    errs_operand(loop_header(it), fv, false);
                    errs(": ");
                    errs(sc_disp_name(sc_get_loop_disposition(sv, it)));
                    it = loop_parent(it);
                }
                sc_print_inner_dispositions(sv, l);
                errs(" }");
            }
            errs("\n");
        }
    }
    errs("Determining loop execution counts for: ");
    errs_operand(fv, fv, false);
    errs("\n");
    for k in li_ntop(fv) { sc_print_loop_info(li_top(fv, k)); }
}

fn sc_loop_hdr(l: i32) {
    errs("Loop ");
    errs_operand(loop_header(l), sc_fv, false);
    errs(": ");
}

fn sc_print_preds_from(mark: i64, depth: i64) {
    for k in mark..sc_out_preds.len { sc_print_predicate(sc_out_preds[k], depth); }
    sc_out_preds.resize(mark);
}

recursive fn sc_print_loop_info(l: i32) {
    for k in loop_nsubs(l) { sc_print_loop_info(loop_sub(l, k)); }
    sc_print_loop_info_body(l);
}

fn sc_print_loop_info_body(l: i32) {
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    sc_loop_hdr(l);
    if exiting.len != 1 { errs("<multiple exits> "); }
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    if !sc_is_cnc(btc) { errs("backedge-taken count is "); sc_print_with_type_hint(btc); }
    else { errs("Unpredictable backedge-taken count."); }
    errs("\n");
    if exiting.len > 1 {
        for bb in exiting {
            errs("  exit count for ");
            errs(val_name(bb));
            errs(": ");
            var ec = sc_get_exit_count(l, bb, BTC_EXACT, false);
            sc_print_with_type_hint(ec);
            if sc_is_cnc(ec) {
                let m = sc_out_preds.len;
                ec = sc_get_exit_count(l, bb, BTC_EXACT, true);
                if !sc_is_cnc(ec) {
                    errs("\n  predicated exit count for ");
                    errs(val_name(bb));
                    errs(": ");
                    sc_print_with_type_hint(ec);
                    errs("\n   Predicates:\n");
                    sc_print_preds_from(m, 4);
                }
                sc_out_preds.resize(m);
            }
            errs("\n");
        }
    }
    sc_loop_hdr(l);
    let cbtc = sc_get_constant_max_backedge_taken_count(l);
    if !sc_is_cnc(cbtc) {
        errs("constant max backedge-taken count is ");
        sc_print_with_type_hint(cbtc);
        if sc_is_backedge_taken_count_max_or_zero(l) { errs(", actual taken count either this or zero."); }
    } else { errs("Unpredictable constant max backedge-taken count. "); }
    errs("\n");
    sc_loop_hdr(l);
    let sbtc = sc_get_symbolic_max_backedge_taken_count(l);
    if !sc_is_cnc(sbtc) {
        errs("symbolic max backedge-taken count is ");
        sc_print_with_type_hint(sbtc);
        if sc_is_backedge_taken_count_max_or_zero(l) { errs(", actual taken count either this or zero."); }
    } else { errs("Unpredictable symbolic max backedge-taken count. "); }
    errs("\n");
    if exiting.len > 1 {
        for bb in exiting {
            errs("  symbolic max exit count for ");
            errs(val_name(bb));
            errs(": ");
            var ec = sc_get_exit_count(l, bb, BTC_SYMBOLIC_MAX, false);
            sc_print_with_type_hint(ec);
            if sc_is_cnc(ec) {
                let m = sc_out_preds.len;
                ec = sc_get_exit_count(l, bb, BTC_SYMBOLIC_MAX, true);
                if !sc_is_cnc(ec) {
                    errs("\n  predicated symbolic max exit count for ");
                    errs(val_name(bb));
                    errs(": ");
                    sc_print_with_type_hint(ec);
                    errs("\n   Predicates:\n");
                    sc_print_preds_from(m, 4);
                }
                sc_out_preds.resize(m);
            }
            errs("\n");
        }
    }
    {
        let m = sc_out_preds.len;
        let pbt = sc_get_predicated_btc(l, BTC_EXACT);
        if pbt != btc {
            sc_loop_hdr(l);
            if !sc_is_cnc(pbt) { errs("Predicated backedge-taken count is "); sc_print_with_type_hint(pbt); }
            else { errs("Unpredictable predicated backedge-taken count."); }
            errs("\n");
            errs(" Predicates:\n");
            sc_print_preds_from(m, 4);
        }
        sc_out_preds.resize(m);
    }
    {
        let m = sc_out_preds.len;
        let pcm = sc_get_predicated_btc(l, BTC_CONSTANT_MAX);
        if pcm != cbtc {
            sc_loop_hdr(l);
            if !sc_is_cnc(pcm) { errs("Predicated constant max backedge-taken count is "); sc_print_with_type_hint(pcm); }
            else { errs("Unpredictable predicated constant max backedge-taken count."); }
            errs("\n");
            errs(" Predicates:\n");
            sc_print_preds_from(m, 4);
        }
        sc_out_preds.resize(m);
    }
    {
        let m = sc_out_preds.len;
        let psm = sc_get_predicated_btc(l, BTC_SYMBOLIC_MAX);
        if sbtc != psm {
            sc_loop_hdr(l);
            if !sc_is_cnc(psm) { errs("Predicated symbolic max backedge-taken count is "); sc_print_with_type_hint(psm); }
            else { errs("Unpredictable predicated symbolic max backedge-taken count."); }
            errs("\n");
            errs(" Predicates:\n");
            sc_print_preds_from(m, 4);
        }
        sc_out_preds.resize(m);
    }
    if !sc_is_cnc(sc_get_backedge_taken_count(l, BTC_EXACT)) {
        sc_loop_hdr(l);
        errs("Trip multiple is ");
        errs_int(sc_get_small_constant_trip_multiple(l));
        errs("\n");
    }
}
