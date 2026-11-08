; @origin: llvm/test/Transforms/Inline/internal-scc-members.ll (llvmorg-23.1.5)
; @opt: -passes=inline
; @opt: -passes=inliner-wrapper
; Test that the inliner can handle deleting functions within an SCC while still
; processing the calls in that SCC.
;
; RUN: opt < %s -S -passes=inline | FileCheck %s
; RUN: opt < %s -S -passes=inliner-wrapper | FileCheck %s

; CHECK-LABEL: define internal void @test1_scc0()
; CHECK-NOT: call
; CHECK: call void @test1_scc0()
; CHECK-NOT: call
; CHECK: ret
define internal void @test1_scc0() {
entry:
  call void @test1_scc1()
  ret void
}

; CHECK-NOT: @test1_scc1
define internal void @test1_scc1() {
entry:
  call void @test1_scc0()
  ret void
}

; CHECK-LABEL: define void @test1()
; CHECK: call void @test1_scc0()
define void @test1() {
entry:
  call void @test1_scc0() noinline
  ret void
}
