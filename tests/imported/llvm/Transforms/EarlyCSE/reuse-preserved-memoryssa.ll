; @origin: llvm/test/Transforms/EarlyCSE/reuse-preserved-memoryssa.ll (llvmorg-23.1.5)
; @opt: '-passes=require<memoryssa>,gvn,early-cse<memssa>'
; RUN: opt -passes='require<memoryssa>,gvn,early-cse<memssa>' %s -S | FileCheck %s

; CHECK: define void @foo(

define void @foo() {
  ret void
}
