; @origin: llvm/test/Verifier/token6.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

define token @f() {
entry:
  ret token undef
}
; CHECK: Function returns a token but isn't an intrinsic
