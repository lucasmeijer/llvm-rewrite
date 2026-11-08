; @origin: llvm/test/Transforms/InstCombine/2007-05-18-CastFoldBug.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "call.*sret"
; Make sure instcombine doesn't drop the sret attribute.

define void @blah(ptr %tmp10) {
entry:
	call void @objc_msgSend_stret(ptr sret(i16) %tmp10)
	ret void
}

declare ptr @objc_msgSend_stret(ptr, ptr, ...)
