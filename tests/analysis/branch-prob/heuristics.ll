; BranchProbabilityInfo heuristics without profile data: loop back edges, pointer and zero compares, an
; unreachable successor, a cold (noreturn) call, and a switch.
; @analysis: -passes='print<branch-prob>'
declare void @abort() noreturn
declare void @cold() cold

define i32 @f(ptr %p, i32 %n, i32 %k) {
entry:
  %isnull = icmp eq ptr %p, null
  br i1 %isnull, label %fail, label %loop

fail:
  call void @abort()
  unreachable

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %latch ]
  %z = icmp eq i32 %i, %k
  br i1 %z, label %rare, label %latch

rare:
  call void @cold()
  br label %latch

latch:
  %i.next = add i32 %i, 1
  %c = icmp slt i32 %i.next, %n
  br i1 %c, label %loop, label %sw

sw:
  switch i32 %k, label %d [
    i32 0, label %r0
    i32 1, label %r1
    i32 2, label %r1
  ]

r0:
  ret i32 0

r1:
  ret i32 1

d:
  %neg = icmp slt i32 %k, 0
  br i1 %neg, label %r0, label %r1
}
