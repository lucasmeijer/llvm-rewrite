; Post-dominator tree of a function with an infinite loop: the loop gets a virtual root next to the real exit.
; @analysis: -passes='print<postdomtree>'
declare void @work(i32)

define void @f(i1 %c) {
entry:
  br i1 %c, label %forever, label %exit

forever:
  %i = phi i32 [ 0, %entry ], [ %i.next, %forever.body ]
  call void @work(i32 %i)
  br label %forever.body

forever.body:
  %i.next = add i32 %i, 1
  br label %forever

exit:
  ret void
}

define void @only_infinite() {
entry:
  br label %spin

spin:
  br label %spin
}
