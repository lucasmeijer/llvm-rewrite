; @origin: llvm/test/Transforms/Inline/zero-cost.ll (llvmorg-23.1.5)
; @opt: -passes=inline
; RUN: opt -passes=inline -S %s | FileCheck %s

define void @f() {
entry:
  tail call void @g()
  unreachable

; CHECK-LABEL: @f
; CHECK-NOT: call
; CHECK: unreachable
}

define void @g() {
entry:
  unreachable
}

