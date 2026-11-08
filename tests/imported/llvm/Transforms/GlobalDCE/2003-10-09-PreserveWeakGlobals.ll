; @origin: llvm/test/Transforms/GlobalDCE/2003-10-09-PreserveWeakGlobals.ll (llvmorg-23.1.5)
; @opt: -passes=globaldce
; Weak variables should be preserved by global DCE!

; RUN: opt < %s -passes=globaldce -S | FileCheck %s

; CHECK: @A
@A = weak global i32 54
