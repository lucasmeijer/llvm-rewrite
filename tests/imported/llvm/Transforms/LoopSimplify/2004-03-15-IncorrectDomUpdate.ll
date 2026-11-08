; @origin: llvm/test/Transforms/LoopSimplify/2004-03-15-IncorrectDomUpdate.ll (llvmorg-23.1.5)
; @opt: '-passes=loop-simplify,loop-mssa(licm)'
; RUN: opt < %s -passes='loop-simplify,loop-mssa(licm)' -disable-output
define void @main() {
entry:
	br i1 false, label %Out, label %loop
loop:		; preds = %loop, %entry
	%LI = icmp sgt i32 0, 0		; <i1> [#uses=1]
	br i1 %LI, label %loop, label %Out
Out:		; preds = %loop, %entry
	ret void
}

