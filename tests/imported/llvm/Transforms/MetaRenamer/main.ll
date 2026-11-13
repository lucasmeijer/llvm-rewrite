; @origin: llvm/test/Transforms/MetaRenamer/main.ll (llvmorg-23.1.5)
; @opt: -passes=metarenamer
; Make sure @main is left untouched.
; RUN: opt -passes=metarenamer -S %s | FileCheck %s

; CHECK: define void @main
; CHECK: call void @main

define void @main() {
  call void @patatino()
  ret void
}

define void @patatino() {
  call void @main()
  ret void
}
