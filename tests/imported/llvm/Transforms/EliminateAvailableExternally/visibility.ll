; @origin: llvm/test/Transforms/EliminateAvailableExternally/visibility.ll (llvmorg-23.1.5)
; @opt: -passes=elim-avail-extern
; RUN: opt -passes=elim-avail-extern -S < %s | FileCheck %s

; CHECK: declare hidden void @f()
define available_externally hidden void @f() {
  ret void
}

define void @g() {
  call void @f()
  ret void
}
