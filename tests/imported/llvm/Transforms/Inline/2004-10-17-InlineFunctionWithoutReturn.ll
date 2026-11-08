; @origin: llvm/test/Transforms/Inline/2004-10-17-InlineFunctionWithoutReturn.ll (llvmorg-23.1.5)
; @opt: -passes=inline
; RUN: opt < %s -passes=inline -disable-output

define i32 @test() {
        unreachable
}

define i32 @caller() {
        %X = call i32 @test( )          ; <i32> [#uses=1]
        ret i32 %X
}

