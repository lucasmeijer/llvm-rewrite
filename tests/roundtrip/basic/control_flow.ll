define i32 @loop(i32 %n) {
entry:
  br label %header

header:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %acc = phi i32 [ 0, %entry ], [ %acc.next, %body ]
  %cmp = icmp slt i32 %i, %n
  br i1 %cmp, label %body, label %exit

body:
  %acc.next = add i32 %acc, %i
  %next = add nuw nsw i32 %i, 1
  br label %header

exit:
  %r = select i1 %cmp, i32 -1, i32 %acc
  switch i32 %r, label %default [
    i32 0, label %zero
    i32 7, label %zero
  ]

zero:
  ret i32 0

default:
  unreachable
}
