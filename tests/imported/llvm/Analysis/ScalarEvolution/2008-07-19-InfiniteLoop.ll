; @origin: llvm/test/Analysis/ScalarEvolution/2008-07-19-InfiniteLoop.ll (llvmorg-23.1.5)
; @analysis: '-passes=print<scalar-evolution>' -scalar-evolution-max-iterations=0
; RUN: opt < %s -disable-output "-passes=print<scalar-evolution>" -scalar-evolution-max-iterations=0 2>&1 | FileCheck %s
; PR2088

; CHECK: Unpredictable

define void @fun() {
entry:
        br label %loop
loop:
        %i = phi i8 [ 0, %entry ], [ %i.next, %loop ]
        %i.next = add i8 %i, 4
        %cond = icmp ne i8 %i.next, 6
        br i1 %cond, label %loop, label %exit
exit:
        ret void
}
