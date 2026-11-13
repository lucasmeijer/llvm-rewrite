; @origin: llvm/test/Verifier/tokenlike6.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

define target("dx.RawBuffer", half, 1, 0) @f() {
entry:
  ret target("dx.RawBuffer", half, 1, 0) poison
}
; CHECK: Function returns a token but isn't an intrinsic
