; ScalarEvolution: add recurrences with nuw/nsw, a nested recurrence, sext/zext of IVs, a pointer IV,
; ranges, and backedge-taken counts (exact, constant max, symbolic max).
; @analysis: -passes='print<scalar-evolution>'
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define void @sum2d(ptr %a, i32 %n, i32 %m) {
entry:
  %cn = icmp sgt i32 %n, 0
  %cm = icmp sgt i32 %m, 0
  %both = and i1 %cn, %cm
  br i1 %both, label %outer, label %exit

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  %row = mul nsw i32 %i, %m
  br label %inner

inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner ]
  %idx = add nsw i32 %row, %j
  %idx.ext = sext i32 %idx to i64
  %g = getelementptr inbounds float, ptr %a, i64 %idx.ext
  %v = load float, ptr %g
  %v2 = fadd float %v, 1.0
  store float %v2, ptr %g
  %j.next = add nuw nsw i32 %j, 1
  %cj = icmp slt i32 %j.next, %m
  br i1 %cj, label %inner, label %outer.latch

outer.latch:
  %i.next = add nuw nsw i32 %i, 1
  %ci = icmp slt i32 %i.next, %n
  br i1 %ci, label %outer, label %exit

exit:
  ret void
}

define i64 @strided(ptr %p, ptr %end) {
entry:
  br label %loop

loop:
  %ptr = phi ptr [ %p, %entry ], [ %ptr.next, %loop ]
  %cnt = phi i64 [ 0, %entry ], [ %cnt.next, %loop ]
  %ptr.next = getelementptr inbounds i8, ptr %ptr, i64 16
  %cnt.next = add i64 %cnt, 1
  %done = icmp eq ptr %ptr.next, %end
  br i1 %done, label %exit, label %loop

exit:
  ret i64 %cnt.next
}

define i32 @countdown(i8 %start) {
entry:
  %s = zext i8 %start to i32
  br label %loop

loop:
  %k = phi i32 [ %s, %entry ], [ %k.next, %loop ]
  %acc = phi i32 [ 0, %entry ], [ %acc.next, %loop ]
  %acc.next = add i32 %acc, %k
  %k.next = add nsw i32 %k, -3
  %c = icmp sgt i32 %k.next, 0
  br i1 %c, label %loop, label %exit

exit:
  ret i32 %acc.next
}
