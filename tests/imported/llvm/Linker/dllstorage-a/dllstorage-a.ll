; @origin: llvm/test/Linker/dllstorage-a.ll (llvmorg-23.1.5)
; RUN: llvm-link %s %p/dllstorage-b.ll -S -o - | FileCheck %s
@foo = external global i32

; CHECK: @foo = dllexport global i32 42
