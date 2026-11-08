; @origin: llvm/test/Transforms/SCCP/2009-05-27-VectorOperandZero.ll (llvmorg-23.1.5)
; @opt: -passes=sccp
; RUN: opt < %s -passes=sccp -disable-output
; PR4277

define i32 @main() nounwind {
entry:
	%0 = tail call signext i8 (...) @sin() nounwind
	ret i32 0
}

declare signext i8 @sin(...)
