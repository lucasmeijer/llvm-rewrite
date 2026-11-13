; @origin: llvm/test/Verifier/comdat-decl1.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

$v = comdat any
@v = available_externally global i32 0, comdat
; CHECK: Declaration may not be in a Comdat!
