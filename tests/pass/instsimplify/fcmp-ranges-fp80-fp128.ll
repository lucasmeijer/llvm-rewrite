; ConstantFPRange for x86_fp80 (explicit integer bit: infinity is exponent 0x7FFF with the integer bit set, next()
; across a binade changes the exponent) and fp128: simplifyAndOrOfFCmpsWithConstants and isImpliedCondition.
; @opt: -passes=instsimplify
; @opt: -passes=gvn

define i1 @and_disjoint_fp80(x86_fp80 %x) {
  %c1 = fcmp olt x86_fp80 %x, 0xK3FFF8000000000000000
  %c2 = fcmp ogt x86_fp80 %x, 0xK40008000000000000000
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @and_nested_fp80(x86_fp80 %x) {
  %c1 = fcmp olt x86_fp80 %x, 0xK3FFF8000000000000000
  %c2 = fcmp olt x86_fp80 %x, 0xK40008000000000000000
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @and_overlap_huge_fp80(x86_fp80 %x) {
  %c1 = fcmp ogt x86_fp80 %x, 0xK00000000000000000000
  %c2 = fcmp oge x86_fp80 %x, 0xK40699DC5ADA82B70B800
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @and_strict_adjacent_fp80(x86_fp80 %x) {
  %c1 = fcmp olt x86_fp80 %x, 0xK3FFF8000000000000000
  %c2 = fcmp oge x86_fp80 %x, 0xK3FFEFFFFFFFFFFFFFFFF
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @and_strict_denormal_fp80(x86_fp80 %x) {
  %c1 = fcmp olt x86_fp80 %x, 0xK00018000000000000000
  %c2 = fcmp oge x86_fp80 %x, 0xK00007FFFFFFFFFFFFFFF
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @or_inf_fp80(x86_fp80 %x) {
  %c1 = fcmp oeq x86_fp80 %x, 0xK7FFF8000000000000000
  %c2 = fcmp ogt x86_fp80 %x, 0xK7FFEFFFFFFFFFFFFFFFF
  %r = or i1 %c1, %c2
  ret i1 %r
}
define i1 @and_fp128(fp128 %x) {
  %c1 = fcmp ogt fp128 %x, 0xL00000000000000004000000000000000
  %c2 = fcmp olt fp128 %x, 0xL00000000000000003FFF000000000000
  %r = and i1 %c1, %c2
  ret i1 %r
}
define i1 @or_zero_fp128(fp128 %x) {
  %c1 = fcmp ogt fp128 %x, 0xL00000000000000000000000000000000
  %c2 = fcmp oeq fp128 %x, 0xL00000000000000008000000000000000
  %r = or i1 %c1, %c2
  ret i1 %r
}
define i1 @implied_fp80(x86_fp80 %x) {
entry:
  %c = fcmp ogt x86_fp80 %x, 0xK00000000000000000000
  br i1 %c, label %t, label %e
t:
  %d = fcmp oge x86_fp80 %x, 0xK40699DC5ADA82B70B800
  ret i1 %d
e:
  %f = fcmp ogt x86_fp80 %x, 0xK3FFF8000000000000000
  ret i1 %f
}
