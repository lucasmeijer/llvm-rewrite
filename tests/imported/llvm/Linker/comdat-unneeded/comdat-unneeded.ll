; @origin: llvm/test/Linker/comdat-unneeded.ll (llvmorg-23.1.5)
; RUN: llvm-link %s -S -o - | FileCheck %s

$foo = comdat largest
define internal void @foo() comdat($foo) {
  ret void
}

; CHECK-NOT: foo
