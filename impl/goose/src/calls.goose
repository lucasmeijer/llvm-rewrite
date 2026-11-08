// CallBase accessors (llvm/IR/InstrTypes.h CallBase, Instructions.h InvokeInst/CallBrInst) and EH pads.
//
// Operand layout, as in LLVM:
//   call:   args..., bundle operands..., callee
//   invoke: args..., bundle operands..., normal dest, unwind dest, callee
//   callbr: args..., bundle operands..., default dest, indirect dests..., callee
// Bundle info lives in `ints` at insts[].aux (naux = 2 + 3 * nbundles, 0 = no bundles and no indirect dests):
//   [nbundles, nindirect, (tag string id, first operand index, operand count) * nbundles]
// landingpad: operands are the clauses (filter clauses have array type); insts[].bits & 1 = cleanup.
// catchswitch: [parent pad, (unwind dest if bits & 1), handlers...]. cleanuppad/catchpad: [args..., parent pad].
// catchret: [pad, successor]. cleanupret: [pad, (unwind dest if any)].
import ir;

fn is_call_base_op(o: i64) -> bool { o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR }

fn cb_nbundles(iv: i32) -> i64 {
    let x = insts[inst_of(iv)];
    if x.naux == 0 || iop(iv) == OP_SHUFFLEVECTOR || iop(iv) == OP_EXTRACTVALUE || iop(iv) == OP_INSERTVALUE { return 0; }
    return ints[x.aux] as i64;
}
fn cb_nindirect(iv: i32) -> i64 {
    let x = insts[inst_of(iv)];
    if x.naux == 0 { return 0; }
    return ints[x.aux + 1] as i64;
}
fn cb_bundle_tag(iv: i32, k: i64) -> i32 { ints[insts[inst_of(iv)].aux + 2 + 3 * k] }
fn cb_bundle_begin(iv: i32, k: i64) -> i64 { ints[insts[inst_of(iv)].aux + 3 + 3 * k] as i64 }
fn cb_bundle_count(iv: i32, k: i64) -> i64 { ints[insts[inst_of(iv)].aux + 4 + 3 * k] as i64 }

// Operands after the bundle operands and before the callee.
fn cb_num_extra(iv: i32) -> i64 {
    let o = iop(iv);
    if o == OP_INVOKE { return 2; }
    if o == OP_CALLBR { return 1 + cb_nindirect(iv); }
    return 0;
}
fn cb_callee(iv: i32) -> i32 { op(iv, nops(iv) - 1) }
fn cb_bundle_ops(iv: i32) -> i64 {
    var n: i64 = 0;
    for k in cb_nbundles(iv) { n += cb_bundle_count(iv, k); }
    return n;
}
fn cb_nargs(iv: i32) -> i64 { nops(iv) - 1 - cb_num_extra(iv) - cb_bundle_ops(iv) }
fn cb_arg(iv: i32, k: i64) -> i32 { op(iv, k) }
fn invoke_normal_dest(iv: i32) -> i32 { op(iv, nops(iv) - 3) }
fn invoke_unwind_dest(iv: i32) -> i32 { op(iv, nops(iv) - 2) }
fn callbr_default_dest(iv: i32) -> i32 { op(iv, nops(iv) - 2 - cb_nindirect(iv)) }
fn callbr_indirect_dest(iv: i32, k: i64) -> i32 { op(iv, nops(iv) - 1 - cb_nindirect(iv) + k) }

// Stores the bundle table for a call-like instruction. tags/counts: pairs (tag, count) in order.
fn cb_set_bundles(iv: i32, first: i64, pairs: const i32[:], nindirect: i64) {
    let nb = pairs.len / 2;
    if nb == 0 && nindirect == 0 { return; }
    let at = ints.len as i32;
    ints.push(nb as i32);
    ints.push(nindirect as i32);
    var pos = first;
    for k in nb {
        ints.push(pairs[2 * k]);
        ints.push(pos as i32);
        ints.push(pairs[2 * k + 1]);
        pos += pairs[2 * k + 1] as i64;
    }
    insts[inst_of(iv)].aux = at;
    insts[inst_of(iv)].naux = (2 + 3 * nb) as i32;
}
