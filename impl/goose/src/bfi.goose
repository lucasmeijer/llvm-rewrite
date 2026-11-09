// BlockFrequencyInfo: a port of llvm/lib/Analysis/BlockFrequencyInfo.cpp, BlockFrequencyInfoImpl.cpp/.h and
// llvm/lib/Support/ScaledNumber.cpp.
import std;
import ir;
import irutil;
import bpi;

fn bfi_not_ported() { fatal("BlockFrequencyInfo is not ported yet"); }
fn bfi_valid(fv: i32) -> bool { false }
fn bfi_compute(fv: i32) { bfi_not_ported(); }
fn bfi_invalidate() {}
fn bfi_get(bb: i32) -> u64 { bfi_not_ported(); return 0; }
fn bfi_set(bb: i32, f: u64) { bfi_not_ported(); }
