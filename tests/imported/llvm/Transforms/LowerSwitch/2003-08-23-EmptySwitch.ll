; @origin: llvm/test/Transforms/LowerSwitch/2003-08-23-EmptySwitch.ll (llvmorg-23.1.5)
; @opt: -passes=lower-switch
; RUN: opt < %s -passes=lower-switch

define void @test() {
	switch i32 0, label %Next [
	]
Next:		; preds = %0
	ret void
}

