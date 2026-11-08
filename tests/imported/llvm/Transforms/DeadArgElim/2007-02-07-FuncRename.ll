; @origin: llvm/test/Transforms/DeadArgElim/2007-02-07-FuncRename.ll (llvmorg-23.1.5)
; @opt: -passes=deadargelim
; RUN: opt < %s -passes=deadargelim -S | grep "@test("
; RUN: opt < %s -passes=deadargelim -S | not grep dead

define internal i32 @test(i32 %X, i32 %dead) {
	ret i32 %X
}

define i32 @caller() {
	%A = call i32 @test(i32 123, i32 456)
	ret i32 %A
}
