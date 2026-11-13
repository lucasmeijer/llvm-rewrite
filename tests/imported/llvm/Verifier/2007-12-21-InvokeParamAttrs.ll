; @origin: llvm/test/Verifier/2007-12-21-InvokeParamAttrs.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s > /dev/null 2>&1

declare void @foo(ptr)

define void @bar() {
	invoke void @foo(ptr signext null)
			to label %r unwind label %r
r:
	ret void
}
