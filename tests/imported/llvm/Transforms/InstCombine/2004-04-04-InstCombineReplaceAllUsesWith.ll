; @origin: llvm/test/Transforms/InstCombine/2004-04-04-InstCombineReplaceAllUsesWith.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

define i32 @test() {
        ret i32 0

Loop:           ; preds = %Loop
        %X = add i32 %X, 1              ; <i32> [#uses=1]
        br label %Loop
}

