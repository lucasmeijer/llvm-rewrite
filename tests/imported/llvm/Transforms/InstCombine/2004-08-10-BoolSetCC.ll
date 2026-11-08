; @origin: llvm/test/Transforms/InstCombine/2004-08-10-BoolSetCC.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | \
; RUN:    grep "ret i1 false"

define i1 @test(i1 %V) {
        %Y = icmp ult i1 %V, false              ; <i1> [#uses=1]
        ret i1 %Y
}

