; @origin: llvm/test/Verifier/x86_amx5.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

define void @f(x86_amx %A) {
entry:
  ret void
}
; CHECK: Function takes x86_amx but isn't an intrinsic
