; @origin: llvm/test/Transforms/InstCombine/2007-01-18-VectorInfLoop.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

define <4 x i32> @test(<4 x i32> %A) {
    %B = xor <4 x i32> %A, < i32 -1, i32 -1, i32 -1, i32 -1 > 
    %C = and <4 x i32> %B, < i32 -1, i32 -1, i32 -1, i32 -1 >
    ret <4 x i32> %C
}
