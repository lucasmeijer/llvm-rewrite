; @origin: llvm/test/Verifier/errno-tbaa-metadata-1.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s

; CHECK: assembly parsed, but does not verify as correct!
; CHECK-NEXT: llvm.errno.tbaa must have at least one operand
!llvm.errno.tbaa = !{}
