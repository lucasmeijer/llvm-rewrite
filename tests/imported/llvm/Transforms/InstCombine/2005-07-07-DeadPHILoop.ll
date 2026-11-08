; @origin: llvm/test/Transforms/InstCombine/2005-07-07-DeadPHILoop.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

; This example caused instcombine to spin into an infinite loop.

define void @test(ptr %P) {
        ret void

Dead:           ; preds = %Dead
        %X = phi i32 [ %Y, %Dead ]              ; <i32> [#uses=1]
        %Y = sdiv i32 %X, 10            ; <i32> [#uses=2]
        store i32 %Y, ptr %P
        br label %Dead
}

