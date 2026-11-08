; @origin: llvm/test/Transforms/LICM/2004-09-14-AliasAnalysisInvalidate.ll (llvmorg-23.1.5)
; @opt: '-passes=require<globals-aa>,function(loop-mssa(licm))'
; RUN: opt < %s -passes='require<globals-aa>,function(loop-mssa(licm))' -disable-output

@PL_regcomp_parse = internal global ptr null		; <ptr> [#uses=2]

define void @test() {
	br label %Outer
Outer:		; preds = %Next, %0
	br label %Inner
Inner:		; preds = %Inner, %Outer
	%tmp.114.i.i.i = load ptr, ptr @PL_regcomp_parse		; <ptr> [#uses=1]
	%tmp.115.i.i.i = load i8, ptr %tmp.114.i.i.i		; <i8> [#uses=0]
	store ptr null, ptr @PL_regcomp_parse
	br i1 false, label %Inner, label %Next
Next:		; preds = %Inner
	br i1 false, label %Outer, label %Exit
Exit:		; preds = %Next
	ret void
}

