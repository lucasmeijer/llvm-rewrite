; @origin: llvm/test/Transforms/InstCombine/2004-11-22-Missed-and-fold.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | not grep and

define i8 @test21(i8 %A) {
        ;; sign extend
        %C = ashr i8 %A, 7              ; <i8> [#uses=1]
        ;; chop off sign
        %D = and i8 %C, 1               ; <i8> [#uses=1]
        ret i8 %D
}

