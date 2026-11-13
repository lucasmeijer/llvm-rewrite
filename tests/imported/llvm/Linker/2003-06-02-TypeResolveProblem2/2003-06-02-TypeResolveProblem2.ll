; @origin: llvm/test/Linker/2003-06-02-TypeResolveProblem2.ll (llvmorg-23.1.5)
; RUN: echo "%%T = type i32" | llvm-as > %t.1.bc
; RUN: llvm-as < %s > %t.2.bc
; RUN: llvm-link %t.1.bc %t.2.bc

%T = type opaque
@X = constant { ptr } zeroinitializer		; <ptr> [#uses=0]

