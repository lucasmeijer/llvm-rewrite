; @origin: llvm/test/Verifier/module-flags-2.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s

!llvm.module.flags = !{!0}
!0 = !{null, null, null}

; CHECK: invalid behavior operand in module flag (expected constant integer)
