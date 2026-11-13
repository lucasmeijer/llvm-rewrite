; @origin: llvm/test/Transforms/MergeFunc/too-small.ll (llvmorg-23.1.5)
; @opt: -passes=mergefunc
; RUN: opt -S -passes=mergefunc < %s | FileCheck %s

define void @foo(i32 %x) {
; CHECK-LABEL: @foo(
; CHECK-NOT: call
  ret void
}

define void @bar(i32 %x) {
; CHECK-LABEL: @bar(
; CHECK-NOT: call
  ret void
}

