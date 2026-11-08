; BranchProbabilityInfo with !prof branch_weights on a br and a switch.
; @analysis: -passes='print<branch-prob>'
define i32 @f(i32 %x) {
entry:
  %c = icmp eq i32 %x, 0
  br i1 %c, label %a, label %b, !prof !0

a:
  switch i32 %x, label %d [
    i32 1, label %b
    i32 2, label %d2
  ], !prof !1

b:
  ret i32 1

d:
  ret i32 2

d2:
  ret i32 3
}

!0 = !{!"branch_weights", i32 1, i32 1000}
!1 = !{!"branch_weights", i32 7, i32 2, i32 1}
