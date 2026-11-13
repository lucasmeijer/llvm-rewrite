; @origin: llvm/test/Linker/2003-08-24-InheritPtrSize.ll (llvmorg-23.1.5)
; Linking a module with a specified pointer size to one without a 
; specified pointer size should not cause a warning!

; RUN: llvm-as < %s > %t.out1.bc
; RUN: echo "" | llvm-as > %t.out2.bc
; RUN: llvm-link %t.out1.bc %t.out2.bc 2>&1 | FileCheck %s 
; CHECK-NOT: warning

target datalayout = "e-p:64:64"

