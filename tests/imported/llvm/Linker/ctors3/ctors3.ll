; @origin: llvm/test/Linker/ctors3.ll (llvmorg-23.1.5)
; RUN: llvm-link -S %s %p/Inputs/ctors3.ll -o - | FileCheck %s

$foo = comdat any
%t = type { i8 }
@foo = global %t zeroinitializer, comdat

; CHECK: @llvm.global_ctors = appending global [0 x { i32, ptr, ptr }] zeroinitializer
; CHECK: @foo = global %t zeroinitializer, comdat
