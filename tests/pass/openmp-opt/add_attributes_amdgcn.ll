; @origin: derived from llvm/test/Transforms/OpenMP/add_attributes_amdgcn.ll (llvmorg-23.1.5): the target triple and the RUN lines'
; -mtriple and remark flags removed, so the device code runs through OpenMPOpt on a module without a GPU target
; @opt: -passes=openmp-opt-cgscc
; @opt: -passes=openmp-opt-cgscc -openmp-ir-builder-optimistic-attributes
; RUN: opt < %s -S -passes=openmp-opt-cgscc | FileCheck %s
; RUN: opt < %s -S -passes=openmp-opt-cgscc -openmp-ir-builder-optimistic-attributes | FileCheck %s --check-prefix=OPTIMISTIC


define void @call_all(i64 %arg) {
  call void @__kmpc_syncwarp(i64 %arg)
  call i64 @__kmpc_warp_active_thread_mask()
  ret void
}

declare i64 @__kmpc_warp_active_thread_mask()

declare void @__kmpc_syncwarp(i64)

; CHECK: ; Function Attrs: convergent nounwind
; CHECK-NEXT: declare i64 @__kmpc_warp_active_thread_mask()

; CHECK: ; Function Attrs: convergent nounwind
; CHECK-NEXT: declare void @__kmpc_syncwarp(i64)

; OPTIMISTIC: ; Function Attrs: convergent nounwind
; OPTIMISTIC-NEXT: declare i64 @__kmpc_warp_active_thread_mask()

; OPTIMISTIC: ; Function Attrs: convergent nounwind
; OPTIMISTIC-NEXT: declare void @__kmpc_syncwarp(i64)

!llvm.module.flags = !{!0}

!0 = !{i32 7, !"openmp", i32 50}
