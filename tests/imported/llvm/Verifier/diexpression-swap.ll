; @origin: llvm/test/Verifier/diexpression-swap.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not opt -S < %s 2>&1 | FileCheck %s

!named = !{!0}
; CHECK: invalid expression
!0 = !DIExpression(DW_OP_swap)
