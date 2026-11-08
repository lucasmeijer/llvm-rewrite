// aa-eval: port of llvm/lib/Analysis/AliasAnalysisEvaluator.cpp (AAEvaluator::runInternal, the result
// printers and the report printed when the pass is destroyed, i.e. after the whole pipeline ran).
import std;
import ir;
import irutil;
import instinfo;
import printer;
import flags;
import memloc;
import aa;

var ae_function_count: i64 = 0;
var ae_no_alias: i64 = 0;
var ae_may_alias: i64 = 0;
var ae_partial_alias: i64 = 0;
var ae_must_alias: i64 = 0;
var ae_no_modref: i64 = 0;
var ae_mod: i64 = 0;
var ae_ref: i64 = 0;
var ae_modref: i64 = 0;

// Value::printAsOperand(OS, /*PrintType=*/false) into a buffer
fn ae_operand_text(v: i32, fv: i32, buf: u8[>..]&) {
    let mark = errbuf.len;
    errs_operand(v, fv, false);
    buf.append(errbuf[mark..]);
    errbuf.resize(mark);
}

// Type::print(OS, false, /*NoDetails=*/true)
fn ae_put_type(t: i32) {
    let mark = out.len;
    put_type(t);
    errbuf.append(out[mark..]);
    out.resize(mark);
}

fn ae_print_results(r0: AR, p: bool, v1: i32, t1: i32, v2: i32, t2: i32, fv: i32) {
    if !(ae_flag_all || p) { return; }
    var r = r0;
    var o1: u8[>..] = [];
    var o2: u8[>..] = [];
    ae_operand_text(v1, fv, o1);
    ae_operand_text(v2, fv, o2);
    var ty1 = t1;
    var ty2 = t2;
    var as1 = ae_ptr_addrspace(vals[v1].ty);
    var as2 = ae_ptr_addrspace(vals[v2].ty);
    var swapped = bytes_cmp(o2, o1) < 0;
    if swapped {
        ty1 = t2;
        ty2 = t1;
        as1 = ae_ptr_addrspace(vals[v2].ty);
        as2 = ae_ptr_addrspace(vals[v1].ty);
        r = ar_swap(r, true);
    }
    errs("  ");
    ar_format(errbuf, r);
    errs(":\t");
    ae_put_type(ty1);
    if as1 != 0 { errs(" addrspace("); errs_int(as1); errs(")"); }
    errs("* ");
    if swapped { errs(o2); } else { errs(o1); }
    errs(", ");
    ae_put_type(ty2);
    if as2 != 0 { errs(" addrspace("); errs_int(as2); errs(")"); }
    errs("* ");
    if swapped { errs(o1); } else { errs(o2); }
    errs("\n");
}

fn ae_ptr_addrspace(t: i32) -> i64 { types[ty_scalar(t)].n as i64 }

fn ae_print_modref_loc(msg: const u8[:], p: bool, iv: i32, ptr: i32, t: i32, fv: i32) {
    if !(ae_flag_all || p) { return; }
    errs("  ");
    errs(msg);
    errs(":  Ptr: ");
    ae_put_type(t);
    errs("* ");
    errs_operand(ptr, fv, false);
    errs("\t<->");
    errs_inst(iv, fv);
    errs("\n");
}

fn ae_print_modref_insts(msg: const u8[:], p: bool, a: i32, b: i32, fv: i32) {
    if !(ae_flag_all || p) { return; }
    errs("  ");
    errs(msg);
    errs(": ");
    errs_inst(a, fv);
    errs(" <-> ");
    errs_inst(b, fv);
    errs("\n");
}

fn ae_print_load_store(r: AR, p: bool, a: i32, b: i32, fv: i32) {
    if !(ae_flag_all || p) { return; }
    errs("  ");
    ar_format(errbuf, r);
    errs(": ");
    errs_inst(a, fv);
    errs(" <-> ");
    errs_inst(b, fv);
    errs("\n");
}

var ae_flags_read: bool = false;
var ae_flag_all: bool = false;
var ae_flag_no: bool = false;
var ae_flag_may: bool = false;
var ae_flag_partial: bool = false;
var ae_flag_must: bool = false;
var ae_flag_nomr: bool = false;
var ae_flag_ref: bool = false;
var ae_flag_mod: bool = false;
var ae_flag_modref: bool = false;
var ae_flag_md: bool = false;

fn ae_read_flags() {
    if ae_flags_read { return; }
    ae_flags_read = true;
    ae_flag_all = flag_bool("print-all-alias-modref-info", false);
    ae_flag_no = flag_bool("print-no-aliases", false);
    ae_flag_may = flag_bool("print-may-aliases", false);
    ae_flag_partial = flag_bool("print-partial-aliases", false);
    ae_flag_must = flag_bool("print-must-aliases", false);
    ae_flag_nomr = flag_bool("print-no-modref", false);
    ae_flag_ref = flag_bool("print-ref", false);
    ae_flag_mod = flag_bool("print-mod", false);
    ae_flag_modref = flag_bool("print-modref", false);
    ae_flag_md = flag_bool("evaluate-aa-metadata", false);
}

fn ae_count_alias(r: AR) -> bool {
    let k = r.k as i64;
    if k == AR_NO { ae_no_alias++; return ae_flag_no; }
    if k == AR_MAY { ae_may_alias++; return ae_flag_may; }
    if k == AR_PARTIAL { ae_partial_alias++; return ae_flag_partial; }
    ae_must_alias++;
    return ae_flag_must;
}

fn ae_count_modref(mr: i64) -> bool {
    if mr == MR_NO { ae_no_modref++; return ae_flag_nomr; }
    if mr == MR_MOD { ae_mod++; return ae_flag_mod; }
    if mr == MR_REF { ae_ref++; return ae_flag_ref; }
    ae_modref++;
    return ae_flag_modref;
}
fn ae_modref_msg(mr: i64) -> const u8[:] {
    if mr == MR_NO { return "NoModRef"; }
    if mr == MR_MOD { return "Just Mod"; }
    if mr == MR_REF { return "Just Ref"; }
    return "Both ModRef";
}

// AAEvaluator::run
fn aa_eval_run(fv: i32) {
    ae_read_flags();
    aa_begin(fv);
    ae_function_count++;
    var ptrs: i32[>..] = [];       // pointer values
    var ptys: i32[>..] = [];       // their access types
    var other: i32[>..] = [];
    var loads: i32[>..] = [];
    var stores: i32[>..] = [];
    fn add_ptr(p: i32, t: i32) {
        for x, i in ptrs { if x == p && ptys[i] == t { return; } }
        ptrs.push(p);
        ptys.push(t);
    }
    each_inst(fv) { i =>
        let o = iop(i);
        if o == OP_LOAD { add_ptr(op(i, 0), vals[i].ty); loads.push(i); }
        else if o == OP_STORE { add_ptr(op(i, 1), vals[op(i, 0)].ty); stores.push(i); }
        if is_callbase(i) || inst_is_atomic(i) { other.push(i); }
    };
    if ae_flag_all || ae_flag_no || ae_flag_may || ae_flag_partial || ae_flag_must || ae_flag_nomr || ae_flag_mod || ae_flag_ref || ae_flag_modref {
        errs("Function: ");
        errs(val_name(fv));
        errs(": ");
        errs_int(ptrs.len);
        errs(" pointers, ");
        errs_int(other.len);
        errs(" call sites\n");
    }
    for i1 in ptrs.len {
        let sz1 = ls_store_size(ptys[i1]);
        for i2 in i1 {
            let sz2 = ls_store_size(ptys[i2]);
            let r = aa_alias_simple(ml_make(ptrs[i1], sz1), ml_make(ptrs[i2], sz2));
            let p = ae_count_alias(r);
            ae_print_results(r, p, ptrs[i1], ptys[i1], ptrs[i2], ptys[i2], fv);
        }
    }
    if ae_flag_md {
        for l in loads {
            for s in stores {
                let r = aa_alias_simple(ml_get(l), ml_get(s));
                let p = ae_count_alias(r);
                ae_print_load_store(r, p, l, s, fv);
            }
        }
        for i1 in stores.len {
            for i2 in i1 {
                let r = aa_alias_simple(ml_get(stores[i1]), ml_get(stores[i2]));
                let p = ae_count_alias(r);
                ae_print_load_store(r, p, stores[i1], stores[i2], fv);
            }
        }
    }
    for m in other {
        for i in ptrs.len {
            let mr = aa_inst_loc_mr_simple(m, ml_make(ptrs[i], ls_store_size(ptys[i])));
            let p = ae_count_modref(mr);
            ae_print_modref_loc(ae_modref_msg(mr), p, m, ptrs[i], ptys[i], fv);
        }
    }
    for a in other {
        for b in other {
            if a == b { continue; }
            let mr = aa_inst_inst_mr_simple(a, b);
            let p = ae_count_modref(mr);
            ae_print_modref_insts(ae_modref_msg(mr), p, a, b, fv);
        }
    }
}

fn ae_percent(num: i64, sum: i64) {
    errs("(");
    errs_int(num * 100 / sum);
    errs(".");
    errs_int((num * 1000 / sum) % 10);
    errs("%)\n");
}

// ~AAEvaluator
fn aa_eval_finish() {
    if ae_function_count == 0 { return; }
    let asum = ae_no_alias + ae_may_alias + ae_partial_alias + ae_must_alias;
    errs("===== Alias Analysis Evaluator Report =====\n");
    if asum == 0 {
        errs("  Alias Analysis Evaluator Summary: No pointers!\n");
    } else {
        errs("  "); errs_int(asum); errs(" Total Alias Queries Performed\n");
        errs("  "); errs_int(ae_no_alias); errs(" no alias responses "); ae_percent(ae_no_alias, asum);
        errs("  "); errs_int(ae_may_alias); errs(" may alias responses "); ae_percent(ae_may_alias, asum);
        errs("  "); errs_int(ae_partial_alias); errs(" partial alias responses "); ae_percent(ae_partial_alias, asum);
        errs("  "); errs_int(ae_must_alias); errs(" must alias responses "); ae_percent(ae_must_alias, asum);
        errs("  Alias Analysis Evaluator Pointer Alias Summary: ");
        errs_int(ae_no_alias * 100 / asum); errs("%/");
        errs_int(ae_may_alias * 100 / asum); errs("%/");
        errs_int(ae_partial_alias * 100 / asum); errs("%/");
        errs_int(ae_must_alias * 100 / asum); errs("%\n");
    }
    let msum = ae_no_modref + ae_ref + ae_mod + ae_modref;
    if msum == 0 {
        errs("  Alias Analysis Mod/Ref Evaluator Summary: no mod/ref!\n");
    } else {
        errs("  "); errs_int(msum); errs(" Total ModRef Queries Performed\n");
        errs("  "); errs_int(ae_no_modref); errs(" no mod/ref responses "); ae_percent(ae_no_modref, msum);
        errs("  "); errs_int(ae_mod); errs(" mod responses "); ae_percent(ae_mod, msum);
        errs("  "); errs_int(ae_ref); errs(" ref responses "); ae_percent(ae_ref, msum);
        errs("  "); errs_int(ae_modref); errs(" mod & ref responses "); ae_percent(ae_modref, msum);
        errs("  Alias Analysis Evaluator Mod/Ref Summary: ");
        errs_int(ae_no_modref * 100 / msum); errs("%/");
        errs_int(ae_mod * 100 / msum); errs("%/");
        errs_int(ae_ref * 100 / msum); errs("%/");
        errs_int(ae_modref * 100 / msum); errs("%\n");
    }
}
