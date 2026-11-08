; @origin: llvm/test/Transforms/InstCombine/2006-11-10-ashr-miscompile.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep lshr
; Verify this is not turned into -1.

define i32 @test(i8 %amt) {
        %shift.upgrd.1 = zext i8 %amt to i32            ; <i32> [#uses=1]
        %B = lshr i32 -1, %shift.upgrd.1                ; <i32> [#uses=1]
        ret i32 %B
}

