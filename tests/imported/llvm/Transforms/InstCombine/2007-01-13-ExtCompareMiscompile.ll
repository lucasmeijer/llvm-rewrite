; @origin: llvm/test/Transforms/InstCombine/2007-01-13-ExtCompareMiscompile.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "icmp ugt"
; PR1107
; PR1940

define i1 @test(i8 %A, i8 %B) {
	%a = zext i8 %A to i32
	%b = zext i8 %B to i32
	%c = icmp sgt i32 %a, %b
	ret i1 %c
}
