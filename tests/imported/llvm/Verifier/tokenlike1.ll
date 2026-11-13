; @origin: llvm/test/Verifier/tokenlike1.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as -disable-output %s 2>&1 | FileCheck %s

define void @f(target("dx.RawBuffer", half, 1, 0) %A, target("dx.RawBuffer", half, 1, 0) %B) {
entry:
  br label %bb

bb:
  %phi = phi target("dx.RawBuffer", half, 1, 0) [ %A, %bb ], [ %B, %entry]
; CHECK: PHI nodes cannot have token type!
  br label %bb
}
