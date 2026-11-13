; @origin: llvm/test/Linker/lto-attributes.ll (llvmorg-23.1.5)
; RUN: llvm-link -S %s -o - | FileCheck %s

; CHECK-DAG: @foo = private externally_initialized global ptr null
@foo = private externally_initialized global ptr null

@useFoo = global ptr @foo

; CHECK-DAG: @array = appending global [7 x i8] c"abcdefg", align 1
@array = appending global [7 x i8] c"abcdefg", align 1

