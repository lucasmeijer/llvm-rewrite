; @origin: llvm/test/Transforms/InstCombine/2004-05-07-UnsizedCastLoad.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

%Ty = type opaque

define i32 @test(ptr %X) {
        %Z = load i32, ptr %X               ; <i32> [#uses=1]
        ret i32 %Z
}

