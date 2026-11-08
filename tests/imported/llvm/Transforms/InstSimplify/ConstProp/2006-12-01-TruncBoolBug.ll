; @origin: llvm/test/Transforms/InstSimplify/ConstProp/2006-12-01-TruncBoolBug.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | \
; RUN:   grep "ret i1 false"
define i1 @test() {
        %X = trunc i32 320 to i1                ; <i1> [#uses=1]
        ret i1 %X
}

