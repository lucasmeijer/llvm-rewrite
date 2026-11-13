; @origin: llvm/test/Verifier/module-flags-3.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s

!llvm.module.flags = !{!0}
!0 = !{i32 1, null, null}

; CHECK: invalid ID operand in module flag (expected metadata string)
