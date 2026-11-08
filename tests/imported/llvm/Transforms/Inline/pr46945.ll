; @origin: llvm/test/Transforms/Inline/pr46945.ll (llvmorg-23.1.5)
; @opt: '-passes=default<O2>'
; @opt: -passes=inliner-wrapper
; RUN: opt %s -o - -S -passes='default<O2>' | FileCheck %s
; RUN: opt %s -o - -S -passes=inliner-wrapper | FileCheck %s

; CHECK-NOT: call void @b()
define void @b() alwaysinline {
entry:
  br label %for.cond

for.cond:
  call void @a()
  br label %for.cond
}

define void @a() {
entry:
  call void @b()
  ret void
}
