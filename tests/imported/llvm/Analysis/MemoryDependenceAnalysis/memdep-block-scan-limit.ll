; @origin: llvm/test/Analysis/MemoryDependenceAnalysis/memdep-block-scan-limit.ll (llvmorg-23.1.5)
; @opt: -passes=gvn
; @opt: -memdep-block-scan-limit=1 -passes=gvn
; RUN: opt -S -passes=gvn < %s | FileCheck %s
; RUN: opt -S -memdep-block-scan-limit=1 -passes=gvn < %s | FileCheck %s --check-prefix=WITH-LIMIT
; CHECK-LABEL: @test(
; CHECK: load
; CHECK-NOT: load
; WITH-LIMIT-LABEL: @test(
; WITH-LIMIT-CHECK: load
; WITH-LIMIT-CHECK: load
define i32 @test(ptr %p) {
 %1 = load i32, ptr %p
 %2 = add i32 %1, 3
 %3 = load i32, ptr %p
 %4 = add i32 %2, %3
 ret i32 %4
}
