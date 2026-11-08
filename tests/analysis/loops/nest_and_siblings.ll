; LoopInfo: a two-deep nest followed by a sibling loop with two latches and two exits; header/latch/exiting flags.
; @analysis: -passes='print<loops>'
define void @f(i32 %n, i32 %m, ptr %p) {
entry:
  br label %outer

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner ]
  store i32 %j, ptr %p
  %j.next = add i32 %j, 1
  %cj = icmp slt i32 %j.next, %m
  br i1 %cj, label %inner, label %outer.latch

outer.latch:
  %i.next = add i32 %i, 1
  %ci = icmp slt i32 %i.next, %n
  br i1 %ci, label %outer, label %second

second:
  %k = phi i32 [ 0, %outer.latch ], [ %k.a, %latch.a ], [ %k.b, %latch.b ]
  %v = load i32, ptr %p
  %early = icmp eq i32 %v, 42
  br i1 %early, label %exit, label %body

body:
  %even = and i32 %k, 1
  %ce = icmp eq i32 %even, 0
  br i1 %ce, label %latch.a, label %latch.b

latch.a:
  %k.a = add i32 %k, 1
  br label %second

latch.b:
  %k.b = add i32 %k, 3
  %cb = icmp slt i32 %k.b, %n
  br i1 %cb, label %second, label %exit

exit:
  ret void
}

define void @no_loops() {
  ret void
}
