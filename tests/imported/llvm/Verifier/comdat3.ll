; @origin: llvm/test/Verifier/comdat3.ll (llvmorg-23.1.5)
; @analysis: -passes=verify
; This used to be invalid, but now it's valid.  Ensure the verifier
; doesn't reject it.
; RUN: llvm-as %s -o /dev/null

$v = comdat largest
