; @origin: llvm/test/Verifier/comdat.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

$v = comdat any
@v = common global i32 0, comdat($v)
; CHECK: 'common' global may not be in a Comdat!
