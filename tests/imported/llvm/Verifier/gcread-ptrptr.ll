; @origin: llvm/test/Verifier/gcread-ptrptr.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s > /dev/null 2>&1
; PR1633

%meta = type { ptr }
%obj = type { ptr }

declare ptr @llvm.gcread(ptr, ptr)

define ptr @f() {
entry:
	%x = call ptr @llvm.gcread(ptr null, ptr null)
	ret ptr %x
}
