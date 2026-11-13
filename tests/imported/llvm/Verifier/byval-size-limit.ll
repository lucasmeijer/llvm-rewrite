; @origin: llvm/test/Verifier/byval-size-limit.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s 2>&1 | FileCheck %s

; CHECK: huge 'byval' arguments are unsupported
define void @f(ptr byval([2147483648 x i16])) { ret void }
