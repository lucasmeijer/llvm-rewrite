; @origin: llvm/test/Transforms/SCCP/atomic.ll (llvmorg-23.1.5)
; @opt: -passes=sccp
; RUN: opt < %s -passes=sccp -S | FileCheck %s

define i1 @test_cmpxchg(ptr %addr, i32 %desired, i32 %new) {
; CHECK-LABEL: @test_cmpxchg
; CHECK: cmpxchg ptr %addr, i32 %desired, i32 %new seq_cst seq_cst
  %val = cmpxchg ptr %addr, i32 %desired, i32 %new seq_cst seq_cst
  %res = extractvalue { i32, i1 } %val, 1
  ret i1 %res
}
