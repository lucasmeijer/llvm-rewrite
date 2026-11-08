; @origin: llvm/test/Transforms/DCE/guards.ll (llvmorg-23.1.5)
; @opt: -passes=dce
; RUN: opt -passes=dce -S < %s | FileCheck %s

declare void @llvm.experimental.guard(i1,...)

define void @f(i32 %val) {
; CHECK-LABEL: @f(
; CHECK-NEXT: ret void
  %val2 = add i32 %val, 1
  call void(i1, ...) @llvm.experimental.guard(i1 true) [ "deopt"(i32 %val2) ]
  ret void
}
