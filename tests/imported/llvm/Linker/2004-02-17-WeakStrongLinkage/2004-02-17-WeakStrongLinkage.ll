; @origin: llvm/test/Linker/2004-02-17-WeakStrongLinkage.ll (llvmorg-23.1.5)
; RUN: llvm-as < %s > %t.out2.bc
; RUN: echo "@me = global ptr null" | llvm-as > %t.out1.bc
; RUN: llvm-link %t.out1.bc %t.out2.bc -o /dev/null

@me = weak global ptr null		; <ptr> [#uses=0]


