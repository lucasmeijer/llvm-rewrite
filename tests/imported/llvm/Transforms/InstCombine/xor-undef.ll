; @origin: llvm/test/Transforms/InstCombine/xor-undef.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep zeroinitializer

define <2 x i64> @f() {
	%tmp = xor <2 x i64> undef, undef
        ret <2 x i64> %tmp
}
