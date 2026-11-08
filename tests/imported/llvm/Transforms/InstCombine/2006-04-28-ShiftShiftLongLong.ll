; @origin: llvm/test/Transforms/InstCombine/2006-04-28-ShiftShiftLongLong.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | FileCheck %s

; This cannot be turned into a sign extending cast!

define i64 @test(i64 %X) {
        %Y = shl i64 %X, 16             ; <i64> [#uses=1]
; CHECK: %Y = shl i64 %X, 16
        %Z = ashr i64 %Y, 16            ; <i64> [#uses=1]
; CHECK: %Z = ashr exact i64 %Y, 16
        ret i64 %Z
; CHECK: ret i64 %Z
}

