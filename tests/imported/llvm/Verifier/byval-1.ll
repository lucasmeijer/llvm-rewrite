; @origin: llvm/test/Verifier/byval-1.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s

; CHECK: Attribute 'byval(i32)' applied to incompatible type!
; CHECK-NEXT: ptr @h
declare void @h(i32 byval(i32) %num)
