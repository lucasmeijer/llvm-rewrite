// DCE: port of llvm/lib/Transforms/Scalar/DCE.cpp (DCEPass: eliminateDeadCode / DCEInstruction).
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import local;
import tli;
import mem2reg;
import salvage;

// SmallSetVector<Instruction *, 16> WorkList: vector + membership in scratch set VS_PASS0.
fn dce_instruction(iv: i32, wl: i32[>..<]&) -> bool {
    if !is_instruction_trivially_dead(iv) { return false; }
    // salvageKnowledge: only with --enable-knowledge-retention (not accepted by our opt)
    salvage_debug_info(iv);
    for k in nops(iv) {
        let opv = op(iv, k);
        set_op(iv, k, -1);
        if opv < 0 || vals[opv].first_use >= 0 || opv == iv { continue; }
        if is_inst(opv) && is_instruction_trivially_dead(opv) {
            if vs_add(VS_PASS0, opv) { wl.push(opv); }
        }
    }
    m2r_erase(iv);
    return true;
}

fn dce_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    m2r_collect_records(fv);     // VS_PASS1: values debug records mention
    vs_clear(VS_PASS0);
    var wl: i32[>..<] = [];
    var changed = false;
    each_inst(fv) { i =>
        if !vs_has(VS_PASS0, i) {
            if dce_instruction(i, wl) { changed = true; }
        }
    };
    while wl.len > 0 {
        let i = wl.pop();
        vs_del(VS_PASS0, i);
        if dce_instruction(i, wl) { changed = true; }
    }
    if !changed { return 0xFFFFFFFF; }
    return PA_CFG;    // preserveSet<CFGAnalyses>
}
