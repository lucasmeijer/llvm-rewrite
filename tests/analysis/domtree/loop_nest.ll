; Dominator tree of a loop nest with a guarded preheader, an inner diamond and a shared exit.
; @analysis: -passes='print<domtree>'
define i32 @nest(i32 %n, ptr %p) {
entry:
  %c0 = icmp sgt i32 %n, 0
  br i1 %c0, label %outer, label %exit

outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner

inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner.latch ]
  %idx = add i32 %i, %j
  %g = getelementptr inbounds i32, ptr %p, i32 %idx
  %v = load i32, ptr %g
  %odd = and i32 %v, 1
  %isodd = icmp ne i32 %odd, 0
  br i1 %isodd, label %then, label %else

then:
  %v.t = add i32 %v, 1
  br label %inner.latch

else:
  %v.e = mul i32 %v, 3
  br label %inner.latch

inner.latch:
  %v2 = phi i32 [ %v.t, %then ], [ %v.e, %else ]
  store i32 %v2, ptr %g
  %j.next = add nuw nsw i32 %j, 1
  %cj = icmp slt i32 %j.next, %n
  br i1 %cj, label %inner, label %outer.latch

outer.latch:
  %i.next = add nuw nsw i32 %i, 1
  %ci = icmp slt i32 %i.next, %n
  br i1 %ci, label %outer, label %exit

exit:
  %r = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  ret i32 %r
}

declare void @ext()

define void @single_block() {
  call void @ext()
  ret void
}
