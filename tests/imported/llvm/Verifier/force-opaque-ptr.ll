; @origin: llvm/test/Verifier/force-opaque-ptr.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not opt -passes=verify -S < %s 2>&1 | FileCheck %s

declare i32 @llvm.umax.i32(i32, i32)

define void @intrinsic_signature_mismatch() {
; CHECK: Intrinsic called with incompatible signature
  call i32 @llvm.umax.i32(i32 0)
  ret void
}
