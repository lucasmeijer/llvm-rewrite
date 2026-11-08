; @origin: llvm/test/Transforms/InferFunctionAttrs/nobuiltin.ll (llvmorg-23.1.5)
; @opt: -passes=inferattrs
; RUN: opt -S -passes=inferattrs < %s | FileCheck %s

; CHECK: Function Attrs: nobuiltin allocsize(0){{$}}
; CHECK: declare ptr @_Znwm(i32)
declare ptr @_Znwm(i32) nobuiltin allocsize(0)
