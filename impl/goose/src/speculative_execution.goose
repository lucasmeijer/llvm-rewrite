// SpeculativeExecution: port of llvm/lib/Transforms/Scalar/SpeculativeExecution.cpp (SpeculativeExecutionPass).
// hasBranchDivergence is false for X86 and for NoTTI, so `only-if-divergent-target` makes the pass a no-op.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import calls;
import flags;
import tti;
import tti_x86;
import speculate;
import licm;

fn se_single_succ(bb: i32) -> i32 { if block_nsucc(bb) == 1 { block_succ(bb, 0) } else { -1 } }
fn se_size(bb: i32) -> i64 { var n: i64 = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }

fn se_cost(i: i32) -> i64 {
    let o = iop(i);
    if o == OP_GEP || o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_SELECT || o == OP_SHL ||
       o == OP_SUB || o == OP_LSHR || o == OP_ASHR || o == OP_XOR || o == OP_ZEXT || o == OP_SEXT || o == OP_CALL ||
       o == OP_BITCAST || o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR || o == OP_ADDRSPACECAST ||
       o == OP_FPTOUI || o == OP_FPTOSI || o == OP_UITOFP || o == OP_SITOFP || o == OP_FPEXT || o == OP_FPTRUNC ||
       o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM || o == OP_FNEG || o == OP_ICMP ||
       o == OP_FCMP || o == OP_TRUNC || o == OP_FREEZE || o == OP_EXTRACTELEMENT || o == OP_INSERTELEMENT ||
       o == OP_SHUFFLEVECTOR || o == OP_EXTRACTVALUE || o == OP_INSERTVALUE {
        return tti_instruction_cost(i, TCK_SIZE_AND_LATENCY);
    }
    return TTI_INVALID;
}

fn se_consider_hoisting(from: i32, to: i32) -> bool {
    let max_cost = flag_int("spec-exec-max-speculation-cost", 7);
    let max_not = flag_int("spec-exec-max-not-hoisted", 5);
    var not_hoisted: i32[>..<] = [];
    var total: i64 = 0;
    var nh: i64 = 0;
    var i = block_first(from);
    while i >= 0 {
        let c = se_cost(i);
        var ok = tc_valid(c) && spec_safe(i, -1, false);
        if ok {
            for k in nops(i) {
                let v = op(i, k);
                if v >= 0 && is_inst(v) { for x in not_hoisted { if x == v { ok = false; } } }
            }
        }
        if ok {
            total = tc_add(total, c);
            if total > max_cost { return false; }
        } else {
            nh++;
            if nh > max_not { return false; }
            not_hoisted.push(i);
        }
        i = inst_next(i);
    }
    var it = block_first(from);
    while it >= 0 {
        let cur = it;
        it = inst_next(it);
        var skip = false;
        for x in not_hoisted { if x == cur { skip = true; } }
        if !skip {
            lc_move_before(cur, block_terminator(to), false);
            lc_drop_location(cur);
        }
    }
    return true;
}

fn se_run_on_block(b: i32) -> bool {
    let bi = block_terminator(b);
    if bi < 0 || iop(bi) != OP_CONDBR { return false; }
    let s0 = term_succ(bi, 0);
    let s1 = term_succ(bi, 1);
    if b == s0 || b == s1 || s0 == s1 { return false; }
    if single_pred(s0) >= 0 && se_single_succ(s0) == s1 { return se_consider_hoisting(s0, b); }
    if single_pred(s1) >= 0 && se_single_succ(s1) == s0 { return se_consider_hoisting(s1, b); }
    if single_pred(s0) >= 0 && single_pred(s1) >= 0 && se_single_succ(s1) >= 0 && se_single_succ(s1) != b &&
       se_single_succ(s1) == se_single_succ(s0) {
        if se_size(s1) == 1 { return se_consider_hoisting(s0, b); }
        if se_size(s0) == 1 { return se_consider_hoisting(s1, b); }
    }
    return false;
}

fn speculative_execution_run(fv: i32, only_if_divergent: bool) -> u32 {
    tti_init_function(fv, globs[glob_of(fv)].module);
    if only_if_divergent || flag_bool("spec-exec-only-if-divergent-target", false) { return PA_ALL; }
    var changed = false;
    var bb = func_first_block(fv);
    while bb >= 0 {
        if se_run_on_block(bb) { changed = true; }
        bb = block_next(bb);
    }
    if !changed { return PA_ALL; }
    return PA_CFG;
}
