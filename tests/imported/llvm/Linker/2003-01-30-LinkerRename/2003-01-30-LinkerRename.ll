; @origin: llvm/test/Linker/2003-01-30-LinkerRename.ll (llvmorg-23.1.5)
; RUN: llvm-as %S/Inputs/2003-01-30-LinkerRename.ll -o %t.1.bc
; RUN: llvm-as %s -o %t.2.bc
; RUN: llvm-link %t.1.bc %t.2.bc -S | FileCheck %s

; CHECK: @bar = global ptr @foo.2

; CHECK:      define internal i32 @foo.2() {
; CHECK-NEXT:   ret i32 7
; CHECK-NEXT: }

; CHECK:      define i32 @foo() {
; CHECK-NEXT:   ret i32 0
; CHECK-NEXT: }

define i32 @foo() {
  ret i32 0
}
