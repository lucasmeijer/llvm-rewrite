; @origin: llvm/test/Transforms/InstCombine/2012-04-30-SRem.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt -passes=instcombine -S < %s | FileCheck %s
; PR12541

define i32 @foo(i32 %x) {
  %y = xor i32 %x, 3
  %z = srem i32 1656690544, %y
  %sext = shl i32 %z, 24
  %s = ashr exact i32 %sext, 24
  ret i32 %s
; CHECK-NOT: and
; The shifts were wrongly being turned into an and with 112
}
