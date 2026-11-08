; @origin: llvm/test/Transforms/ConstantMerge/2003-10-28-MergeExternalConstants.ll (llvmorg-23.1.5)
; @opt: -passes=constmerge
; RUN: opt -S -passes=constmerge < %s | FileCheck %s

; CHECK: @foo = constant i32 6
; CHECK: @bar = constant i32 6
@foo = constant i32 6           ; <ptr> [#uses=0]
@bar = constant i32 6           ; <ptr> [#uses=0]

