; @origin: llvm/test/Transforms/InstCombine/default-alignment.ll (llvmorg-23.1.5)
; @opt: -passes=verify,instcombine
; RUN: opt -passes=verify,instcombine < %s
%Foo = type <{ i8, x86_fp80 }>

define i8 @t(ptr %arg) {
entry:
  %0 = load i8, ptr %arg, align 1
  ret i8 %0
}

