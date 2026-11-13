; @origin: llvm/test/Transforms/GVNHoist/hoist-more-than-two-branches.ll (llvmorg-23.1.5)
; @opt: -passes=gvn-hoist
; RUN: opt -passes=gvn-hoist -S < %s | FileCheck %s

; CHECK: store
; CHECK-NOT: store

; Check that an instruction can be hoisted to a basic block
; with more than two successors.

@G = external global i32, align 4

define void @foo(i32 %c1) {
entry:
  switch i32 %c1, label %exit1 [
    i32 0, label %sw0
    i32 1, label %sw1
  ]

sw0:
  store i32 1, ptr @G
  br label %exit

sw1:
  store i32 1, ptr @G
  br label %exit

exit1:
  store i32 1, ptr @G
  ret void
exit:
  ret void
}
