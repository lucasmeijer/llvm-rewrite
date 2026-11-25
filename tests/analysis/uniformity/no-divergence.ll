; UniformityInfoPrinterPass without branch divergence (every x86 / no-target TTI) and
; InlineAdvisorAnalysisPrinterPass without a cached advisor.
; @analysis: '-passes=print<uniformity>'
; @analysis: '-passes=print<inline-advisor>'
; @analysis: '-passes=function(require<uniformity>,require<ssp-layout>),print<inline-advisor>'
target triple = "x86_64-unknown-linux-gnu"
define i32 @f(i32 %x, i1 %c) {
entry:
  br i1 %c, label %a, label %b
a:
  br label %b
b:
  %p = phi i32 [ %x, %entry ], [ 0, %a ]
  ret i32 %p
}
declare void @g()
