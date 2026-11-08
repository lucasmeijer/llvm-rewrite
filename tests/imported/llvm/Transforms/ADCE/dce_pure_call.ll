; @origin: llvm/test/Transforms/ADCE/dce_pure_call.ll (llvmorg-23.1.5)
; @opt: -passes=adce
; RUN: opt -passes=adce -S < %s | not grep call

declare i32 @strlen(ptr) readonly nounwind willreturn

define void @test() {
	call i32 @strlen( ptr null )		; <i32>:1 [#uses=0]
	ret void
}
