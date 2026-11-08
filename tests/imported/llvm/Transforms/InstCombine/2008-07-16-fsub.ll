; @origin: llvm/test/Transforms/InstCombine/2008-07-16-fsub.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep sub
; PR2553

define double @test(double %X) nounwind {
	; fsub of self can't be optimized away.
	%Y = fsub double %X, %X
	ret double %Y
}
