; @origin: llvm/test/Transforms/InstSimplify/ConstProp/2003-05-12-DivideError.ll (llvmorg-23.1.5)
; @opt: -passes=instsimplify
; Make sure that the constant propagator doesn't cause a sigfpe
;
; RUN: opt < %s -passes=instsimplify
;

define i32 @test() {
        %R = sdiv i32 -2147483648, -1           ; <i32> [#uses=1]
        ret i32 %R
}

define i32 @test2() {
        %R = srem i32 -2147483648, -1           ; <i32> [#uses=1]
        ret i32 %R
}

