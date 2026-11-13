; @origin: llvm/test/Analysis/RegionInfo/infinite_loop_5_b.ll (llvmorg-23.1.5)
; @analysis: '-passes=print<regions>'
; RUN: opt -passes='print<regions>' -disable-output < %s 2>&1 | FileCheck %s

define void @normal_condition() nounwind {
"0":
    br label %"7"
"7":
    br i1 1, label %"1", label %"9"
"9":
    br label %"8"
"1":
    br i1 1, label %"6", label %"3"
"6":
    br label %"9"
"8":
    br label %"8"
"3":
    br label %"4"
"4":
    ret void
}

; CHECK:      Region tree:
; CHECK-NEXT: [0] 0 => <Function Return>
; CHECK-NEXT: End region tree
