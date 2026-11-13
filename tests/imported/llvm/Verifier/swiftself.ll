; @origin: llvm/test/Verifier/swiftself.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as %s -o /dev/null 2>&1 | FileCheck %s

declare void @a(ptr swiftself %a, ptr swiftself %b)
; CHECK: Cannot have multiple 'swiftself' parameters!
