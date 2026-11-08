; @origin: llvm/test/Transforms/InstCombine/apint-cast-cast-to-and.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | not grep i41

define i61 @test1(i61 %X) {
        %Y = trunc i61 %X to i41 ;; Turn i61o an AND
        %Z = zext i41 %Y to i61
        ret i61 %Z
}

