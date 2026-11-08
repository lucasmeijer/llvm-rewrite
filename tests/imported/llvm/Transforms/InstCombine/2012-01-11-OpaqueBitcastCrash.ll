; @origin: llvm/test/Transforms/InstCombine/2012-01-11-OpaqueBitcastCrash.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

%opaque_struct = type opaque

@G = external global [0 x %opaque_struct]

declare void @foo(ptr)

define void @bar() {
  call void @foo(ptr @G)
  ret void
}
