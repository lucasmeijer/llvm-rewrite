; @origin: llvm/test/Linker/scalable-vector-type-construction.ll (llvmorg-23.1.5)
; RUN: llvm-link %p/Inputs/fixed-vector-type-construction.ll %s -S -o - | FileCheck %s
%t = type {i32, float}
; CHECK: define void @foo(<4 x
; CHECK: define void @bar(<vscale x 4 x
define void @bar(<vscale x 4 x ptr> %x) {
  ret void
}
