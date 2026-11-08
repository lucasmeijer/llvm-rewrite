; @origin: llvm/test/Transforms/FunctionAttrs/nonnull-global.ll (llvmorg-23.1.5)
; @opt: -passes=function-attrs
; RUN: opt -S -passes=function-attrs %s | FileCheck %s

@a = external global i8, !absolute_symbol !0

; CHECK-NOT: define nonnull
define ptr @foo() {
  ret ptr @a
}

!0 = !{i64 0, i64 256}
