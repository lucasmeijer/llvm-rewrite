; @origin: llvm/test/Transforms/FunctionAttrs/assume.ll (llvmorg-23.1.5)
; @opt: -passes=function-attrs
; RUN: opt -S -o - -passes=function-attrs %s | FileCheck %s

; CHECK-NOT: readnone
declare void @llvm.assume(i1)
