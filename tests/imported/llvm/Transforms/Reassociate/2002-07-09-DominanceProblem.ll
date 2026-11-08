; @origin: llvm/test/Transforms/Reassociate/2002-07-09-DominanceProblem.ll (llvmorg-23.1.5)
; @opt: -passes=reassociate
; The reassociate pass is not preserving dominance properties correctly
;
; RUN: opt < %s -passes=reassociate

define i32 @compute_dist(i32 %i, i32 %j) {
	%reg119 = sub i32 %j, %i		; <i32> [#uses=1]
	ret i32 %reg119
}


