; @origin: llvm/test/Verifier/global-initializer-sized.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s 2>&1 | FileCheck %s

@g = global target("opaque") undef

; CHECK: Global variable initializer must be sized
