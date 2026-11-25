; SimplifyCFG hoists two calls whose nofpclass return attributes share no bit: AttributeList::intersectWith drops
; the attribute (addNoFPClassAttr(fcNone) adds nothing) instead of writing nofpclass(none), which the verifier
; rejects (found by a default<O2> sweep on Transforms/Inline/ret_attr_nofpclass.ll).
; @opt: -passes=simplifycfg
declare float @g(float)
define float @f(i1 %c, float %x) {
  br i1 %c, label %a, label %b
a:
  %r1 = call nofpclass(nan) float @g(float %x)
  br label %m
b:
  %r2 = call nofpclass(inf) float @g(float %x)
  br label %m
m:
  %r = phi float [ %r1, %a ], [ %r2, %b ]
  ret float %r
}
