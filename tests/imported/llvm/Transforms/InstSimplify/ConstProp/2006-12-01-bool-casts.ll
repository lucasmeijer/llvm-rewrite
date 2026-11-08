; @origin: llvm/test/Transforms/InstSimplify/ConstProp/2006-12-01-bool-casts.ll (llvmorg-23.1.5)
; @opt: -passes=instsimplify
; RUN: opt < %s -passes=instsimplify -S | \
; RUN:    grep "ret i32 -1"
; RUN: opt < %s -passes=instsimplify -S | \
; RUN:    grep "ret i32 1"

define i32 @test1() {
        %A = sext i1 true to i32                ; <i32> [#uses=1]
        ret i32 %A
}

define i32 @test2() {
        %A = zext i1 true to i32                ; <i32> [#uses=1]
        ret i32 %A
}

