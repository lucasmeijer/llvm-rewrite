; BlockFrequencyInfo: frequencies through a loop nest with an inner diamond, and through branch weights.
; @analysis: -passes='print<block-freq>'
define void @f(i32 %n, ptr %p) {
entry:
  br label %outer

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner.latch ]
  %v = load i32, ptr %p
  %c = icmp eq i32 %v, %j
  br i1 %c, label %then, label %inner.latch, !prof !0

then:
  store i32 %j, ptr %p
  br label %inner.latch

inner.latch:
  %j.next = add i32 %j, 1
  %cj = icmp slt i32 %j.next, %n
  br i1 %cj, label %inner, label %outer.latch

outer.latch:
  %i.next = add i32 %i, 1
  %ci = icmp slt i32 %i.next, %n
  br i1 %ci, label %outer, label %exit

exit:
  ret void
}

!0 = !{!"branch_weights", i32 3, i32 97}
