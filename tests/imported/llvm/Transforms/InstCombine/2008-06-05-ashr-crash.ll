; @origin: llvm/test/Transforms/InstCombine/2008-06-05-ashr-crash.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine

define i65 @foo(i65 %x) nounwind  {
entry:
	%tmp2 = ashr i65 %x, 65		; <i65> [#uses=1]
	ret i65 %tmp2
}
