; @origin: llvm/test/Transforms/DeadStoreElimination/int_sideeffect.ll (llvmorg-23.1.5)
; @opt: -passes=dse
; RUN: opt -S < %s -passes=dse | FileCheck %s

declare void @llvm.sideeffect()

; Dead store elimination across a @llvm.sideeffect.

; CHECK-LABEL: dse
; CHECK: store
; CHECK-NOT: store
define void @dse(ptr %p) {
    store float 0.0, ptr %p
    call void @llvm.sideeffect()
    store float 0.0, ptr %p
    ret void
}
