; @origin: llvm/test/Linker/internalize-lazy.ll (llvmorg-23.1.5)
; RUN: llvm-link -S -internalize %s %p/Inputs/internalize-lazy.ll | FileCheck %s

; CHECK: define internal void @f
; CHECK: define internal void @g
