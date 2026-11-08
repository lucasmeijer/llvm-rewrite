; @origin: llvm/test/Transforms/InstCombine/2008-10-23-ConstFoldWithoutMask.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine
; PR2940

define i32 @tstid() {
	%var0 = inttoptr i32 1 to ptr		; <ptr> [#uses=1]
	%var2 = ptrtoint ptr %var0 to i32		; <i32> [#uses=1]
	ret i32 %var2
}
