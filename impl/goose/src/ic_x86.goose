// InstCombine x86 target intrinsics: port of llvm/lib/Target/X86/X86InstCombineIntrinsic.cpp
// (X86TTIImpl::instCombineIntrinsic, simplifyDemandedUseBitsIntrinsic, simplifyDemandedVectorEltsIntrinsic).
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import pm;
import apint;
import ic;
import ic_builder;
import ic_common;

// X86TTIImpl::instCombineIntrinsic(IC, II): (result, handled)
fn x86_inst_combine_intrinsic(ii: i32) -> i32, bool {
    ic_not_ported(str("X86TTIImpl::instCombineIntrinsic (", intr_name(call_iid(ii) as i64), ")"));
    return -1, false;
}
