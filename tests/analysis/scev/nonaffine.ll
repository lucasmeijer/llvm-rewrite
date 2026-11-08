; ScalarEvolution: a quadratic recurrence, multiplication and division by constants, umax/smin from selects,
; a loop with two exits (one not computable), and a loop whose trip count is unknown.
; @analysis: -passes='print<scalar-evolution>'
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i64 @quad(i64 %n) {
entry:
  br label %loop

loop:
  %i = phi i64 [ 0, %entry ], [ %i.next, %loop ]
  %s = phi i64 [ 0, %entry ], [ %s.next, %loop ]
  %s.next = add i64 %s, %i
  %t = mul i64 %i, 12
  %u = udiv i64 %t, 4
  %w = shl i64 %u, 2
  %i.next = add nuw i64 %i, 1
  %c = icmp ult i64 %i.next, %n
  br i1 %c, label %loop, label %exit

exit:
  %r = add i64 %s.next, %w
  ret i64 %r
}

define i32 @minmax(i32 %a, i32 %b) {
  %c1 = icmp ugt i32 %a, %b
  %umax = select i1 %c1, i32 %a, i32 %b
  %c2 = icmp slt i32 %a, %b
  %smin = select i1 %c2, i32 %a, i32 %b
  %r = add i32 %umax, %smin
  ret i32 %r
}

define i32 @two_exits(ptr %p, i32 %n) {
entry:
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %latch ]
  %g = getelementptr inbounds i32, ptr %p, i32 %i
  %v = load i32, ptr %g
  %z = icmp eq i32 %v, 0
  br i1 %z, label %exit, label %latch

latch:
  %i.next = add nuw nsw i32 %i, 1
  %c = icmp ult i32 %i.next, %n
  br i1 %c, label %loop, label %exit

exit:
  %r = phi i32 [ %i, %loop ], [ -1, %latch ]
  ret i32 %r
}

define void @unknown(ptr %p) {
entry:
  br label %loop

loop:
  %q = phi ptr [ %p, %entry ], [ %next, %loop ]
  %next = load ptr, ptr %q
  %null = icmp eq ptr %next, null
  br i1 %null, label %exit, label %loop

exit:
  ret void
}
