; @origin: llvm/test/Transforms/GlobalDCE/basicvariabletest.ll (llvmorg-23.1.5)
; @opt: -passes=globaldce
; RUN: opt < %s -passes=globaldce -S | FileCheck %s

; CHECK-NOT: global
@X = external global i32
@Y = internal global i32 7

