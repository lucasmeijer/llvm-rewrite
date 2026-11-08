; Post-dominator tree with several returns, an unreachable terminator and a loop with two exits.
; @analysis: -passes='print<postdomtree>'
declare void @abort() noreturn

define i32 @f(i32 %n, i32 %k) {
entry:
  %neg = icmp slt i32 %n, 0
  br i1 %neg, label %bad, label %loop

bad:
  call void @abort()
  unreachable

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %latch ]
  %hit = icmp eq i32 %i, %k
  br i1 %hit, label %found, label %latch

latch:
  %i.next = add i32 %i, 1
  %done = icmp eq i32 %i.next, %n
  br i1 %done, label %notfound, label %loop

found:
  ret i32 %i

notfound:
  ret i32 -1
}
