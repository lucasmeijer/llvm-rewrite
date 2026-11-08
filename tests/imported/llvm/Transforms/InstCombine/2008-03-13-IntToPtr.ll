; @origin: llvm/test/Transforms/InstCombine/2008-03-13-IntToPtr.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "16" | count 1

define ptr @bork(ptr %qux) {
  %tmp275 = load ptr, ptr %qux, align 1
  %tmp275276 = ptrtoint ptr %tmp275 to i32
  %tmp277 = add i32 %tmp275276, 16
  %tmp277278 = inttoptr i32 %tmp277 to ptr
  ret ptr %tmp277278
}
