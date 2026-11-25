; SimplifyCFG's FoldTwoEntryPHINode / SpeculativelyExecuteBB costs a phi operand that is a constant-expression GEP
; with TTI::getInstructionCost (only the GEP's own operands are its indices; found by a default<O2> sweep on
; Transforms/FunctionSpecialization/function-specialization-constant-expression.ll).
; @opt: -passes=simplifycfg
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
@G = global [8 x i64] zeroinitializer
define i64 @f(i1 %c) {
entry:
  br i1 %c, label %then, label %end
then:
  br label %end
end:
  %p = phi i64 [ ptrtoint (ptr getelementptr inbounds (i8, ptr @G, i64 24) to i64), %then ], [ ptrtoint (ptr getelementptr inbounds (i8, ptr @G, i64 32) to i64), %entry ]
  ret i64 %p
}
define ptr @g(i1 %c) {
entry:
  br i1 %c, label %then, label %end
then:
  br label %end
end:
  %p = phi ptr [ getelementptr inbounds (i8, ptr @G, i64 24), %then ], [ @G, %entry ]
  ret ptr %p
}
