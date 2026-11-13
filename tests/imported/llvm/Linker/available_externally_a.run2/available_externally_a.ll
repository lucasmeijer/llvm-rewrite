; @origin: llvm/test/Linker/available_externally_a.ll (llvmorg-23.1.5)
; RUN: llvm-link %s %p/available_externally_b.ll -S -o - | FileCheck %s
; RUN: llvm-link %s -S -o - | FileCheck --check-prefix=AE-ONLY %s

@foo = available_externally unnamed_addr constant i32 0

; CHECK: @foo = hidden unnamed_addr constant i32 0
; AE-ONLY-NOT: @foo
