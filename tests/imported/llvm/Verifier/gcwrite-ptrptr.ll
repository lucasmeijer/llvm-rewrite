; @origin: llvm/test/Verifier/gcwrite-ptrptr.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s > /dev/null 2>&1
; PR1633

%meta = type { ptr }
%obj = type { ptr }

declare void @llvm.gcwrite(ptr, ptr, ptr)

define void @f() {
entry:
	call void @llvm.gcwrite(ptr null, ptr null, ptr null)
	ret void
}
