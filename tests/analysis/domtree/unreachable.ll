; Unreachable blocks are not in the dominator tree; an unreachable cycle and a block only reachable from it.
; @analysis: -passes='print<domtree>'
define i32 @f(i32 %x) {
entry:
  %c = icmp eq i32 %x, 0
  br i1 %c, label %zero, label %nonzero

zero:
  ret i32 0

nonzero:
  ret i32 1

dead1:
  br label %dead2

dead2:
  br i1 true, label %dead1, label %dead3

dead3:
  br label %nonzero
}
