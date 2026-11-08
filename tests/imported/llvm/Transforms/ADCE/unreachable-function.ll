; @origin: llvm/test/Transforms/ADCE/unreachable-function.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; RUN: opt < %s -passes=adce -disable-output

define void @test() {
	unreachable
}
