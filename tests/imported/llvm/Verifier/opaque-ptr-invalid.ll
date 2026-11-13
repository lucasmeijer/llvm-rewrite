; @origin: llvm/test/Verifier/opaque-ptr-invalid.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not opt -passes=verify < %s 2>&1 | FileCheck %s

; CHECK: Attribute 'inalloca' does not support unsized types!
; CHECK-NEXT: ptr @f
define void @f(ptr inalloca(token)) {
    ret void
}
