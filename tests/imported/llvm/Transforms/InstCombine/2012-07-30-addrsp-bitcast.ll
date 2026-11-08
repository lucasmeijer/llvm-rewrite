; @origin: llvm/test/Transforms/InstCombine/2012-07-30-addrsp-bitcast.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | FileCheck %s
; CHECK: addrspacecast

@base = internal unnamed_addr addrspace(3) global [16 x i32] zeroinitializer, align 16
declare void @foo(ptr)

define void @test() nounwind {
  call void @foo(ptr getelementptr (i32, ptr addrspacecast (ptr addrspace(3) @base to ptr), i64 2147483647)) nounwind
  ret void
}
