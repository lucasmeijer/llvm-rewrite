; @origin: llvm/test/Transforms/GlobalOpt/deaddeclaration.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt < %s -passes=globalopt -S | FileCheck %s

; CHECK-NOT: aa
; CHECK-NOT: bb

declare void @aa()
@bb = external global i8
