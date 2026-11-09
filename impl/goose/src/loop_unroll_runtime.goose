// Runtime unrolling: port of llvm/lib/Transforms/Utils/LoopUnrollRuntime.cpp (in progress).
import std;
import ir;

// UnrollRuntimeLoopRemainder: (done, remainder loop)
fn unroll_runtime_loop_remainder(l: i32, count: i64, allow_expensive: bool, use_epilog: bool, unroll_remainder: bool,
                                 forget_all: bool, preserve_lcssa: bool, budget: i64, multi_exit: bool,
                                 has_otc: bool, otc: u64, orig_prob: u32) -> bool, i32 {
    fatal("LoopUnroll: runtime unrolling (UnrollRuntimeLoopRemainder) is not ported yet");
    return false, -1;
}
