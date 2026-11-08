; @origin: llvm/test/Transforms/FunctionAttrs/2010-10-30-volatile.ll (llvmorg-23.1.5)
; @opt: -passes=function-attrs
; RUN: opt < %s -passes=function-attrs -S | FileCheck %s
; PR8279

@g = constant i32 1

; CHECK: Function Attrs
; CHECK-SAME: norecurse
; CHECK-NOT: readonly
; CHECK-NEXT: void @foo()
define void @foo() {
  %tmp = load volatile i32, ptr @g
  ret void
}
