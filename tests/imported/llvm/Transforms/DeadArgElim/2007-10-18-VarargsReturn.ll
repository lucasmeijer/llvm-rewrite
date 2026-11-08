; @origin: llvm/test/Transforms/DeadArgElim/2007-10-18-VarargsReturn.ll (llvmorg-23.1.5)
; @opt: -passes=deadargelim
; RUN: opt < %s -passes=deadargelim -S | not grep "ret i32 0"
; PR1735

define internal i32 @test(i32 %A, ...) { 
	ret i32 %A
}

define i32 @foo() {
	%A = call i32(i32, ...) @test(i32 1)
	ret i32 %A
}

