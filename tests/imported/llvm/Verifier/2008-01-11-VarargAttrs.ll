; @origin: llvm/test/Verifier/2008-01-11-VarargAttrs.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s > /dev/null 2>&1

%struct = type {  }

declare void @foo(...)

define void @bar() {
	call void (...) @foo(ptr sret(%struct) null )
	ret void
}
