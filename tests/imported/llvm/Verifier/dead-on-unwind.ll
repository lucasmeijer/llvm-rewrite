; @origin: llvm/test/Verifier/dead-on-unwind.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as -disable-output %s 2>&1 | FileCheck %s

; CHECK: Attribute 'dead_on_unwind' applied to incompatible type!
; CHECK-NEXT: ptr @not_pointer
define void @not_pointer(i32 dead_on_unwind %arg) {
  ret void
}
