; @origin: llvm/test/Transforms/Inline/noinline.ll (llvmorg-23.1.5)
; @opt: -passes=inline
; RUN: opt -passes=inline -S < %s | FileCheck %s
; PR6682
declare void @foo() nounwind

define void @bar() nounwind {
entry:
    tail call void @foo() nounwind
    ret void
}

define void @bazz() nounwind {
entry:
    tail call void @bar() nounwind noinline
    ret void
}

; CHECK: define void @bazz()
; CHECK: call void @bar()
