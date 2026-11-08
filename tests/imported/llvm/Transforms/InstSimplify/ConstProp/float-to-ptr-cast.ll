; @origin: llvm/test/Transforms/InstSimplify/ConstProp/float-to-ptr-cast.ll (llvmorg-23.1.5)
; @opt: -passes=instsimplify
; RUN: opt < %s -passes=instsimplify -S | FileCheck %s

define ptr @test1() {
        %X = inttoptr i64 0 to ptr             ; <ptr> [#uses=1]
        ret ptr %X
}

; CHECK:  ret ptr null

define ptr @test2() {
        ret ptr null
}

; CHECK:  ret ptr null

