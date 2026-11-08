; @origin: llvm/test/Transforms/InstCombine/pr28143.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt -S -passes=instcombine < %s | FileCheck %s

define void @test1() {
entry:
  call void @tan()
  ret void
}
; CHECK-LABEL: define void @test1(
; CHECK:      call void @tan()
; CHECK-NEXT: ret void

declare void @tan()
