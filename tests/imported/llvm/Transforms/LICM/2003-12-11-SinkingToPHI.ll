; @origin: llvm/test/Transforms/LICM/2003-12-11-SinkingToPHI.ll (llvmorg-23.1.5)
; @opt: -passes=licm
; RUN: opt < %s -passes=licm | lli -jit-kind=mcjit -force-interpreter

define i32 @main() {
entry:
	br label %Loop
Loop:		; preds = %LoopCont, %entry
	br i1 true, label %LoopCont, label %Out
LoopCont:		; preds = %Loop
	%X = add i32 1, 0		; <i32> [#uses=1]
	br i1 true, label %Out, label %Loop
Out:		; preds = %LoopCont, %Loop
	%V = phi i32 [ 2, %Loop ], [ %X, %LoopCont ]		; <i32> [#uses=1]
	%V2 = sub i32 %V, 1		; <i32> [#uses=1]
	ret i32 %V2
}

