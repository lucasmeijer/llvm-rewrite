; @origin: llvm/test/Transforms/Internalize/externally-initialized.ll (llvmorg-23.1.5)
; @opt: -passes=internalize
; RUN: opt < %s -passes=internalize -S | FileCheck %s

; CHECK: @G0
; CHECK-NOT: internal
; CHECK-SAME: global i32
@G0 = protected externally_initialized global i32 0, align 4
