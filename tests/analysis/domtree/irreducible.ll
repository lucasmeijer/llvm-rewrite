; Dominator tree of an irreducible CFG (two entries into the a/b cycle), unnamed blocks and a switch with
; duplicate successors.
; @analysis: -passes='print<domtree>'
define i32 @irreducible(i1 %c, i32 %x) {
entry:
  br i1 %c, label %a, label %b

a:
  %pa = phi i32 [ 0, %entry ], [ %pb.next, %b ]
  %pa.next = add i32 %pa, 1
  %ca = icmp ult i32 %pa.next, 10
  br i1 %ca, label %b, label %out

b:
  %pb = phi i32 [ 5, %entry ], [ %pa.next, %a ]
  %pb.next = add i32 %pb, 2
  %cb = icmp ult i32 %pb.next, 20
  br i1 %cb, label %a, label %out

out:
  %r = phi i32 [ %pa.next, %a ], [ %pb.next, %b ]
  switch i32 %x, label %3 [
    i32 0, label %1
    i32 1, label %1
    i32 2, label %2
  ]

1:
  br label %3

2:
  br label %3

3:
  %s = phi i32 [ %r, %out ], [ 1, %1 ], [ 2, %2 ]
  ret i32 %s
}
