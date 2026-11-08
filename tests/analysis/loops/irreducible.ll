; LoopInfo ignores irreducible cycles: only the natural loop around the irreducible region is reported.
; @analysis: -passes='print<loops>'
define void @f(i1 %c, i32 %n) {
entry:
  br label %outer

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br i1 %c, label %a, label %b

a:
  br i1 %c, label %b, label %outer.latch

b:
  br i1 %c, label %a, label %outer.latch

outer.latch:
  %i.next = add i32 %i, 1
  %ci = icmp slt i32 %i.next, %n
  br i1 %ci, label %outer, label %exit

exit:
  ret void
}
