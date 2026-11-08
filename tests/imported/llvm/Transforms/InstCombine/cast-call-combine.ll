; @origin: llvm/test/Transforms/InstCombine/cast-call-combine.ll (llvmorg-23.1.5)
; @opt: '-passes=function(instcombine),always-inline'
; RUN: opt < %s -passes='function(instcombine),always-inline' -S | FileCheck %s

define internal void @foo(ptr) alwaysinline {
  ret void
}

define void @bar() noinline noreturn {
  unreachable
}

define void @test() {
  br i1 false, label %then, label %else

then:
  call void @bar()
  unreachable

else:
  ; CHECK-NOT: call
  call void @foo (ptr null)
  ret void
}

