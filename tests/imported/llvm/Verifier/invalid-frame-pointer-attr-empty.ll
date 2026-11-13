; @origin: llvm/test/Verifier/invalid-frame-pointer-attr-empty.ll (llvmorg-23.1.5)
; @error: -passes=verify
; RUN: not llvm-as < %s -o /dev/null 2>&1 | FileCheck %s

; CHECK: invalid value for 'frame-pointer' attribute:

define void @func() #0 {
  ret void
}

attributes #0 = { "frame-pointer"="" }
