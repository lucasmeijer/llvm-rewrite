; @origin: llvm/test/Linker/ctors2.ll (llvmorg-23.1.5)
; RUN: llvm-link -S %s %p/Inputs/ctors2.ll -o - | FileCheck %s

$foo = comdat any
@foo = global i8 0, comdat

; CHECK: @llvm.global_ctors = appending global [0 x { i32, ptr, ptr }] zeroinitializer
; CHECK: @foo = global i8 0, comdat
