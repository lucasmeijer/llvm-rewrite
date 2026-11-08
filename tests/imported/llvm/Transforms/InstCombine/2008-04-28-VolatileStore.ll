; @origin: llvm/test/Transforms/InstCombine/2008-04-28-VolatileStore.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "store volatile"

define void @test() {
	%votf = alloca <4 x float>		; <ptr> [#uses=1]
	store volatile <4 x float> zeroinitializer, ptr %votf, align 16
	ret void
}

