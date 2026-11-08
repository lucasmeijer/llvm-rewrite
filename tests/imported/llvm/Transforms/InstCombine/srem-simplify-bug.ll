; @origin: llvm/test/Transforms/InstCombine/srem-simplify-bug.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "ret i1 false"
; PR2276

define i1 @f(i32 %x) {
  %A = or i32 %x, 1
  %B = srem i32 %A, 1
  %C = icmp ne i32 %B, 0
  ret i1 %C
}
