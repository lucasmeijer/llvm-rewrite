; @origin: llvm/test/Transforms/GlobalOpt/alias-used-section.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt -S -passes=globalopt < %s | FileCheck %s

@_Z17in_custom_section = internal global i8 42, section "CUSTOM"
@in_custom_section = internal alias i8, ptr @_Z17in_custom_section

; CHECK: @in_custom_section = internal global i8 42, section "CUSTOM"

@llvm.used = appending global [1 x ptr] [ptr @in_custom_section], section "llvm.metadata"
