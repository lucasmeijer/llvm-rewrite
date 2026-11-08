; @origin: llvm/test/Transforms/InstCombine/2008-11-01-SRemDemandedBits.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "ret i1 true"
; PR2993

define i1 @foo(i32 %x) {
  %1 = srem i32 %x, -1
  %2 = icmp eq i32 %1, 0
  ret i1 %2
}
