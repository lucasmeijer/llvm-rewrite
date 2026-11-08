; @origin: llvm/test/Transforms/InstCombine/switch-truncate-crash.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt -passes=instcombine < %s

define void @test() {
  switch i32 0, label %out [i32 0, label %out]
out:
  ret void
}
