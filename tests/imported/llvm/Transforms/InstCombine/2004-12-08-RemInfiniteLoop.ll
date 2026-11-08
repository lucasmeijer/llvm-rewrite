; @origin: llvm/test/Transforms/InstCombine/2004-12-08-RemInfiniteLoop.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine

define i32 @test(i32 %X, i32 %Z) {
        %Y = srem i32 %X, undef         ; <i32> [#uses=1]
        ret i32 %Y
}

