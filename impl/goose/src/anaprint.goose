// Analysis printer passes: print<domtree>, print<postdomtree> (llvm/lib/IR/Dominators.cpp,
// llvm/lib/Analysis/PostDominators.cpp, DomTreeBase::print and PrintDomTree in GenericDomTree.h).
import std;
import ir;
import irutil;
import flags;
import domtree;

fn print_domtree(fv: i32, t: i64) {
    errs(if t == DT_DOM { "DominatorTree for function: " } else { "PostDominatorTree for function: " });
    errs(val_name(fv));
    errs("\n");
    dt_get(fv, t);
    errs("=============================--------------------------------\n");
    errs(if t == DT_DOM { "Inorder Dominator Tree: " } else { "Inorder PostDominator Tree: " });
    errs("DFSNumbers invalid: 0 slow queries.");
    errs("\n");
    let root = dt_root(fv, t);
    if root != -1 {
        // PrintDomTree, pre-order; stack of (node, depth)
        var sn: i32[>..<] = [];
        var sd: i32[>..<] = [];
        sn.push(root);
        sd.push(1);
        while sn.len > 0 {
            let n = sn.pop();
            let lev = sd.pop();
            for k in lev { errs("  "); }
            errs("[");
            errs_int(lev as i64);
            errs("] ");
            if n == DT_VROOT { errs(" <<exit node>>"); } else { errs_operand(n, fv, false); }
            errs(" {4294967295,4294967295} [");
            errs_int(if n == DT_VROOT { 0 } else { dt_level(t, n) as i64 });
            errs("]\n");
            let mark = sn.len;
            var c = dt_first_child(fv, t, n);
            while c >= 0 { sn.push(c); sd.push(lev + 1); c = dt_next_sibling(t, c); }
            reverse(sn[mark..]);
        }
    }
    errs("Roots: ");
    for k in dt_nroots(fv, t) {
        errs_operand(dt_root_at(fv, t, k), fv, false);
        errs(" ");
    }
    errs("\n");
}
