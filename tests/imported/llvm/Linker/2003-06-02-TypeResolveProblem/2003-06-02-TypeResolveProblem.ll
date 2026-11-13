; @origin: llvm/test/Linker/2003-06-02-TypeResolveProblem.ll (llvmorg-23.1.5)
; RUN: echo "%%T = type opaque" | llvm-as > %t.2.bc
; RUN: llvm-as < %s > %t.1.bc
; RUN: llvm-link %t.1.bc %t.2.bc

%T = type opaque
@a = constant { ptr } zeroinitializer		; <ptr> [#uses=0]

