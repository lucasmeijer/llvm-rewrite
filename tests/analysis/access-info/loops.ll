; LoopAccessAnalysis: a vectorizable loop that needs a runtime alias check, one with a forward dependence that
; is safe, and one with a backward dependence of distance 1 that is unsafe.
; @analysis: -passes='print<access-info>'
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define void @runtime_check(ptr %a, ptr %b, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %gb = getelementptr inbounds float, ptr %b, i64 %i
  %v = load float, ptr %gb
  %m = fmul float %v, 2.0
  %ga = getelementptr inbounds float, ptr %a, i64 %i
  store float %m, ptr %ga
  %i.next = add nuw nsw i64 %i, 1
  %c = icmp ult i64 %i.next, %n
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

define void @forward(ptr noalias %a, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %i.next = add nuw nsw i64 %i, 1
  %g1 = getelementptr inbounds i32, ptr %a, i64 %i.next
  %v = load i32, ptr %g1
  %g0 = getelementptr inbounds i32, ptr %a, i64 %i
  store i32 %v, ptr %g0
  %c = icmp ult i64 %i.next, %n
  br i1 %c, label %loop, label %exit

exit:
  ret void
}

define void @backward(ptr noalias %a, i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 1, %entry ], [ %i.next, %loop ]
  %im1 = add nsw i64 %i, -1
  %gp = getelementptr inbounds i32, ptr %a, i64 %im1
  %v = load i32, ptr %gp
  %v1 = add i32 %v, 1
  %g = getelementptr inbounds i32, ptr %a, i64 %i
  store i32 %v1, ptr %g
  %i.next = add nuw nsw i64 %i, 1
  %c = icmp ult i64 %i.next, %n
  br i1 %c, label %loop, label %exit

exit:
  ret void
}
