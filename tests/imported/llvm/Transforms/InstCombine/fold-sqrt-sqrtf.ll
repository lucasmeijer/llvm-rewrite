; @origin: llvm/test/Transforms/InstCombine/fold-sqrt-sqrtf.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine -disable-simplify-libcalls
; RUN: opt -passes=instcombine -S -disable-simplify-libcalls < %s | FileCheck %s
; rdar://10466410

; Instcombine tries to fold (fptrunc (sqrt (fpext x))) -> (sqrtf x), but this
; shouldn't fold when sqrtf isn't available.
define float @foo(float %f) uwtable ssp {
entry:
; CHECK: %conv = fpext float %f to double
; CHECK: %call = tail call double @sqrt(double %conv)
; CHECK: %conv1 = fptrunc double %call to float
  %conv = fpext float %f to double
  %call = tail call double @sqrt(double %conv)
  %conv1 = fptrunc double %call to float
  ret float %conv1
}

declare double @sqrt(double)
