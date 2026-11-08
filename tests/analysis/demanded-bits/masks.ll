; DemandedBits: bits demanded through trunc, and, shifts, or, zext and an add whose high bits are dead.
; @analysis-unordered: -passes='print<demanded-bits>'
define i8 @f(i32 %x, i32 %y, i16 %z) {
  %a = add i32 %x, %y
  %s = lshr i32 %a, 4
  %m = and i32 %s, 255
  %w = zext i16 %z to i32
  %sh = shl i32 %w, 8
  %o = or i32 %m, %sh
  %t = trunc i32 %o to i8
  ret i8 %t
}

define i1 @sign(i64 %v) {
  %b = ashr i64 %v, 63
  %t = trunc i64 %b to i1
  ret i1 %t
}
