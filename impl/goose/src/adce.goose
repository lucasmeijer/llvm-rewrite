// ADCE: port of llvm/lib/Transforms/Scalar/ADCE.cpp (AggressiveDeadCodeElimination), with
// FindFunctionBackedges (llvm/lib/Analysis/CFG.cpp) and ReverseIDFCalculator
// (llvm/include/llvm/Support/GenericIteratedDominanceFrontier.h).
// The deleted CFG edges are applied to the cached dominator tree and the post-dominator tree through an
// eager DomTreeUpdater (dtu.goose), and both trees are preserved, as in LLVM.
import std;
import ir;
import irutil;
import analyses;
import calls;
import instinfo;
import local;
import tli;
import flags;
import domtree;
import dtu;
import dinfo;

fn adce_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    let remove_cf = flag_bool("adce-remove-control-flow", true);
    let remove_loops = flag_bool("adce-remove-loops", false);
    dt_get(fv, DT_POST);

    // BlockInfo, indexed by a local block number (BB->getNumber()).
    var blk: i32[>..<] = [];
    vm_clear(VM_PASS0);
    var b = func_first_block(fv);
    while b >= 0 { vm_set(VM_PASS0, b, blk.len); blk.push(b); b = block_next(b); }
    let nb = blk.len;
    fn bnum(bv: i32) -> i64 { vm_get(VM_PASS0, bv, -1) }
    var live_b: bool[>..<] = [];
    var phis_b: bool[>..<] = [];
    var cflive_b: bool[>..<] = [];
    var porder: i32[>..<] = [];
    live_b.resize(nb, false); phis_b.resize(nb, false); cflive_b.resize(nb, false); porder.resize(nb, 0);

    vs_clear(VS_PASS0);           // LiveInst
    var worklist: i32[>..<] = [];
    var bwdt: i32[>..<] = [];     // BlocksWithDeadTerminators (SetVector; membership: VS_PASS1)
    vs_clear(VS_PASS1);
    var new_live: i32[>..<] = []; // NewLiveBlocks (set; order irrelevant)
    var new_live_mark: bool[>..<] = [];
    new_live_mark.resize(nb, false);

    fn is_live(i: i32) -> bool { vs_has(VS_PASS0, i) }
    // SetVector::remove keeps the order of the others: membership is the set, the array is filtered on use.
    var bwdt_count: i64 = 0;
    fn bwdt_remove(bv: i32) {
        if !vs_has(VS_PASS1, bv) { return; }
        vs_del(VS_PASS1, bv);
        bwdt_count--;
    }
    fn add_new_live(k: i64) { if !new_live_mark[k] { new_live_mark[k] = true; new_live.push(blk[k]); } }
    // markLive(UncondBr terminator of a block that is already live)
    fn mark_uncond_term(i: i32) {
        if !vs_add(VS_PASS0, i) { return; }
        worklist.push(i);
        let dl = inst_get_md(i, 0);
        if dl >= 0 { collect_live_scopes_dl(dl); }
        bwdt_remove(inst_parent(i));
    }
    // markLive(BasicBlock *)
    fn mark_block(bv: i32) {
        let k = bnum(bv);
        if live_b[k] { return; }
        live_b[k] = true;
        if !cflive_b[k] { cflive_b[k] = true; add_new_live(k); }
        let t = block_last(bv);
        if iop(t) == OP_BR { mark_uncond_term(t); }
    }
    // AliveScopes (keyed by md id in VM_PASS1)
    vm_clear(VM_PASS1);
    fn collect_live_scopes_ls(ls0: i32) {
        var ls = ls0;
        while ls >= 0 {
            if vm_has(VM_PASS1, ls) { return; }
            vm_set(VM_PASS1, ls, 1);
            if mds[ls].kind != MK_DI || di_kind(ls) == DIK_SUBPROGRAM { return; }
            ls = di_slot(ls, "scope");
        }
    }
    fn collect_live_scopes_dl(dl0: i32) {
        var dl = dl0;
        while dl >= 0 {
            if vm_has(VM_PASS1, dl) { return; }
            vm_set(VM_PASS1, dl, 1);
            collect_live_scopes_ls(di_slot(dl, "scope"));
            dl = di_slot(dl, "inlinedAt");
        }
    }
    fn inst_dl(i: i32) -> i32 { inst_get_md(i, 0) }
    // markLive(Instruction *)
    fn mark_inst(i: i32) {
        if !vs_add(VS_PASS0, i) { return; }
        worklist.push(i);
        let dl = inst_dl(i);
        if dl >= 0 { collect_live_scopes_dl(dl); }
        let bv = inst_parent(i);
        if i == block_last(bv) {
            bwdt_remove(bv);
            if iop(i) != OP_BR {
                for k in term_nsucc(i) { mark_block(term_succ(i, k)); }
            }
        }
        mark_block(bv);
    }
    // isInstrumentsConstant
    fn instruments_constant(i: i32) -> bool {
        if iop(i) != OP_CALL { return false; }
        let c = called_function(i);
        if c < 0 { return false; }
        if val_name(c) != "__llvm_profile_instrument_target" { return false; }
        return is_constant(cb_arg(i, 0));
    }
    fn is_always_live(i: i32) -> bool {
        if inst_is_eh_pad(i) || inst_may_have_side_effects(i) {
            if instruments_constant(i) { return false; }
            return true;
        }
        if !is_terminator(i) { return false; }
        let o = iop(i);
        if remove_cf && (o == OP_BR || o == OP_CONDBR || o == OP_SWITCH) { return false; }
        return true;
    }

    // initialize()
    each_inst(fv) { i => if is_always_live(i) { mark_inst(i); } };
    if remove_cf {
        if !remove_loops {
            // FindFunctionBackedges: mark the source terminators live
            let entry = func_entry(fv);
            if block_nsucc(entry) > 0 {
                var visited: bool[>..<] = [];
                var instack: bool[>..<] = [];
                visited.resize(nb, false); instack.resize(nb, false);
                var st_b: i32[>..<] = [];
                var st_i: i32[>..<] = [];
                var srcs: i32[>..<] = [];
                visited[bnum(entry)] = true;
                instack[bnum(entry)] = true;
                st_b.push(entry); st_i.push(0);
                while st_b.len > 0 {
                    let top = st_b.len - 1;
                    let pb = st_b[top];
                    var it = st_i[top] as i64;
                    let ns = block_nsucc(pb);
                    var found: i32 = -1;
                    while it < ns {
                        let s = block_succ(pb, it);
                        it++;
                        if !visited[bnum(s)] { visited[bnum(s)] = true; found = s; break; }
                        if instack[bnum(s)] { srcs.push(pb); }
                    }
                    st_i[top] = it as i32;
                    if found >= 0 {
                        instack[bnum(found)] = true;
                        st_b.push(found); st_i.push(0);
                    } else {
                        instack[bnum(pb)] = false;
                        st_b.pop(); st_i.pop();
                    }
                }
                for s in srcs { mark_inst(block_terminator(s)); }
            }
        }
        // Blocks with no path to a return: mark the post-dominator subtree of non-return root children live.
        var c = dt_first_child(fv, DT_POST, DT_VROOT);
        while c >= 0 {
            let last = block_last(c);
            if iop(last) != OP_RET {
                dt_each_subtree(fv, c) { n => mark_inst(block_last(n)); };
            }
            c = dt_next_sibling(DT_POST, c);
        }
        let entry = func_entry(fv);
        live_b[bnum(entry)] = true;
        if iop(block_last(entry)) == OP_BR { mark_inst(block_last(entry)); }
        for x in blk { if !is_live(block_last(x)) { if vs_add(VS_PASS1, x) { bwdt.push(x); bwdt_count++; } } }
    }

    // markLiveInstructions()
    fn mark_phi_live(p: i32) {
        let bv = inst_parent(p);
        let k = bnum(bv);
        if phis_b[k] { return; }
        phis_b[k] = true;
        each_pred(bv) { pb =>
            let pk = bnum(pb);
            if !cflive_b[pk] { cflive_b[pk] = true; add_new_live(pk); }
        };
    }
    // ReverseIDFCalculator over the post-dominator tree: defining blocks = NewLiveBlocks, live-in = BWDT.
    fn mark_live_branches_from_control_dependences() {
        if bwdt_count == 0 { return; }
        dt_update_dfs_numbers(fv, DT_POST);     // IDFCalculatorBase::calculate
        var idf: i32[>..<] = [];
        var vis_pq: bool[>..<] = [];
        var vis_wl: bool[>..<] = [];
        var is_def: bool[>..<] = [];
        vis_pq.resize(nb, false); vis_wl.resize(nb, false); is_def.resize(nb, false);
        // priority queue on dominator-tree level, deepest first (the set computed doesn't depend on tie order)
        var pq: i64[>..<] = [];
        fn pq_push(x: i32) { heap_push(pq, ((1000000000 - dt_level(DT_POST, x) as i64) << 32) | bnum(x)); }
        for x in new_live { is_def[bnum(x)] = true; pq_push(x); vis_wl[bnum(x)] = true; }
        var wl2: i32[>..<] = [];
        while pq.len > 0 {
            let top = heap_pop(pq);
            let root = blk[top & 0xFFFFFFFF];
            let rl = dt_level(DT_POST, root);
            wl2.push(root);
            while wl2.len > 0 {
                let n = wl2.pop();
                each_pred(n) { s =>
                    let sk = bnum(s);
                    if dt_level(DT_POST, s) <= rl && !vis_pq[sk] {
                        vis_pq[sk] = true;
                        if vs_has(VS_PASS1, s) {
                            idf.push(s);
                            if !is_def[sk] { pq_push(s); }
                        }
                    }
                };
                var ch = dt_first_child(fv, DT_POST, n);
                while ch >= 0 {
                    if !vis_wl[bnum(ch)] { vis_wl[bnum(ch)] = true; wl2.push(ch); }
                    ch = dt_next_sibling(DT_POST, ch);
                }
            }
        }
        for x in new_live { new_live_mark[bnum(x)] = false; }
        new_live.clear();
        for x in idf { mark_inst(block_terminator(x)); }
    }
    loop {
        while worklist.len > 0 {
            let li = worklist.pop();
            for k in nops(li) {
                let o = op(li, k);
                if is_inst(o) { mark_inst(o); }
            }
            if iop(li) == OP_PHI { mark_phi_live(li); }
        }
        mark_live_branches_from_control_dependences();
        if worklist.len == 0 { break; }
    }

    // removeDeadInstructions() -> updateDeadRegions()
    var changed_cf = false;
    var have_po = false;
    fn compute_reverse_post_order() {
        var visited: bool[>..<] = [];
        visited.resize(nb, false);
        var num: i32 = 0;
        var st_b: i32[>..<] = [];
        var st_u: i32[>..<] = [];       // next use to look at in the block's use list
        for x in blk {
            if block_nsucc(x) != 0 { continue; }
            if visited[bnum(x)] { continue; }
            visited[bnum(x)] = true;
            st_b.push(x); st_u.push(vals[x].first_use);
            while st_b.len > 0 {
                let top = st_b.len - 1;
                var u = st_u[top];
                var pushed = false;
                while u >= 0 {
                    let user = uses[u].user;
                    u = uses[u].next;
                    if vals[user].kind == VK_INST && is_terminator_op(iop(user)) {
                        let p = inst_parent(user);
                        if !visited[bnum(p)] {
                            visited[bnum(p)] = true;
                            st_u[top] = u;
                            st_b.push(p); st_u.push(vals[p].first_use);
                            pushed = true;
                            break;
                        }
                    }
                }
                if pushed { continue; }
                porder[bnum(st_b[top])] = num;
                num++;
                st_b.pop(); st_u.pop();
            }
        }
    }
    var deleted_edges: DTUpdate[>..<] = [];
    for bb in bwdt {
        if !vs_has(VS_PASS1, bb) { continue; }
        let t = block_last(bb);
        if iop(t) == OP_BR { vs_add(VS_PASS0, t); continue; }
        if !have_po { compute_reverse_post_order(); have_po = true; }
        var pref: i32 = -1;
        var pref_po: i32 = 0;
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            let spo = porder[bnum(s)];
            if pref_po < spo { pref = s; pref_po = spo; }
        }
        if pref < 0 { fatal("ADCE: failed to find safe successor for dead branch"); }
        var first = true;
        var removed: i32[>..<] = [];
        let ns = term_nsucc(t);
        var succs: i32[>..<] = [];
        for k in ns { succs.push(term_succ(t, k)); }
        for s in succs {
            if !first || s != pref {
                block_remove_predecessor(s, bb, false);
                if position(removed, s) < 0 { removed.push(s); }
            } else { first = false; }
        }
        // makeUnconditional(BB, PreferredSucc)
        let tdl = inst_dl(t);
        if tdl >= 0 { collect_live_scopes_dl(tdl); }
        let br = build_br(pref, t);
        vs_add(VS_PASS0, br);
        if tdl >= 0 { inst_set_md(br, 0, tdl); }
        inst_erase_from_parent(t);
        changed_cf = true;
        for s in removed { if s != pref { deleted_edges.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); } }
    }
    if deleted_edges.len > 0 {
        dtu_begin(fv, true, true, false);
        dtu_apply_updates(deleted_edges);
        dtu_end();
    }

    // Erase everything not live, in reverse instruction order.
    var dead: i32[>..<] = [];
    var bb = globs[glob_of(fv)].last_block;
    while bb >= 0 {
        var i = block_last(bb);
        while i >= 0 {
            // drop debug records whose scope isn't alive
            var prev_r: i32 = -1;
            var r = inst_first_dbg(i);
            while r >= 0 {
                let nr = dbgrecs[r].next;
                if dbgrecs[r].kind as i64 == DR_ASSIGN { fatal("ADCE: dbg_assign records (assignment tracking) are not ported yet"); }
                let dl = dbgrecs[r].dl;
                let sc = if dl >= 0 { di_slot(dl, "scope") } else { -1 };
                if sc >= 0 && vm_has(VM_PASS1, sc) {
                    prev_r = r;
                } else {
                    if prev_r < 0 { inst_dbg[inst_of(i)] = nr; } else { dbgrecs[prev_r].next = nr; }
                }
                r = nr;
            }
            if !is_live(i) { dead.push(i); }
            i = inst_prev(i);
        }
        bb = block_prev(bb);
    }
    for i in dead { drop_all_refs(i); }
    for i in dead { inst_erase_from_parent(i); }
    if !changed_cf && dead.len == 0 { return 0xFFFFFFFF; }
    if !changed_cf { return PA_CFG; }
    return ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_POSTDOMTREE);
}

// depth_first over a post-dominator subtree (pre-order).
fn dt_each_subtree<F>(fv: i32, root: i32) {
    var stack: i32[>..<] = [];
    stack.push(root);
    while stack.len > 0 {
        let n = stack.pop();
        F(n);
        let mark = stack.len;
        var c = dt_first_child(fv, DT_POST, n);
        while c >= 0 { stack.push(c); c = dt_next_sibling(DT_POST, c); }
        reverse(stack[mark..]);
    }
}
