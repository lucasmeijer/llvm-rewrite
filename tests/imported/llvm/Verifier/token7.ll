; @origin: llvm/test/Verifier/token7.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

define void @f() {
entry:
  call token () undef ()
  ret void
}
; CHECK: Return type cannot be token for indirect call!
