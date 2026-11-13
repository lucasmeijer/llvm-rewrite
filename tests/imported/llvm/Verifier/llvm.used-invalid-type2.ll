; @origin: llvm/test/Verifier/llvm.used-invalid-type2.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s
@llvm.used = appending global i32 0, section "llvm.metadata"

; CHECK: Only global arrays can have appending linkage!
; CHECK-NEXT: ptr @llvm.used
