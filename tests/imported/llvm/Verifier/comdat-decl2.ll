; @origin: llvm/test/Verifier/comdat-decl2.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

$v = comdat any
@v = external global i32, comdat
; CHECK: Declaration may not be in a Comdat!
