; @origin: llvm/test/Transforms/DeadArgElim/comdat.ll (llvmorg-23.1.5)
; @opt: -passes=deadargelim
; RUN: opt -S < %s -passes=deadargelim | FileCheck %s

$f = comdat any

define void @f() comdat {
  call void @g(i32 0)
  ret void
}

define internal void @g(i32 %dead) comdat($f) {
  ret void
}

; CHECK: define internal void @g() comdat($f) {
