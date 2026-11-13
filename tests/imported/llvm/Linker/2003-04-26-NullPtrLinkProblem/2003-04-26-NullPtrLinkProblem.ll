; @origin: llvm/test/Linker/2003-04-26-NullPtrLinkProblem.ll (llvmorg-23.1.5)
; This one fails because the LLVM runtime is allowing two null pointers of
; the same type to be created!

; RUN: echo "%%T = type i32" | llvm-as > %t.2.bc
; RUN: llvm-as %s -o %t.1.bc
; RUN: llvm-link %t.1.bc %t.2.bc

%T = type opaque

declare ptr @create()

define void @test() {
	%X = call ptr @create( )		; <ptr> [#uses=1]
	%v = icmp eq ptr %X, null		; <i1> [#uses=0]
	ret void
}

