// InstCombine and/or/xor: port of llvm/lib/Transforms/InstCombine/InstCombineAndOrXor.cpp.
// So far only the helpers other files need: insertRangeTest (used by InstCombineCompares.cpp). The porter of
// visitAnd/visitOr/visitXor extends this file.
namespace ic;
import std;
import ir;
import irutil;
import pm;
import apint;
import implied;
import ic;
import ic_builder;
import ic_common;

// insertRangeTest(V, Lo, Hi, isSigned, Inside): (V >= Lo && V < Hi) if Inside, else (V < Lo || V >= Hi)
fn insert_range_test(v: i32, lo: AP, hi: AP, signed: bool, inside: bool) -> i32 {
    let ty = vals[v].ty;
    var p = if inside { P_ULT } else { P_UGE };
    if (signed && ap_is_min_signed(lo)) || (!signed && ap_is_zero(lo)) {
        if signed { p = p + 4; }
        return icb_icmp(p, v, c_int_ap(ty, hi), "");
    }
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(".off");
    let vml = icb_sub(v, c_int_ap(ty, lo), nm);
    let hml = c_int_ap(ty, ap_sub(hi, lo));
    return icb_icmp(p, vml, hml, "");
}
