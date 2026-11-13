; @origin: llvm/test/Linker/2004-12-03-DisagreeingType.ll (llvmorg-23.1.5)
; RUN: echo "@G = weak global {{{{double}}}} zeroinitializer " | \
; RUN:   llvm-as > %t.out2.bc
; RUN: llvm-as < %s > %t.out1.bc
; RUN: llvm-link %t.out1.bc %t.out2.bc -S | FileCheck %s
; CHECK-NOT: }

; When linked, the global above should be eliminated, being merged with the 
; global below.

@G = global double 1.0
