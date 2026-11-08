; @origin: llvm/test/Transforms/StripDeadPrototypes/remove-global-variable-declaration.ll (llvmorg-23.1.5)
; @opt: -passes=strip-dead-prototypes -verify-analysis-invalidation
; RUN: opt -passes=strip-dead-prototypes -S -verify-analysis-invalidation < %s | FileCheck %s

; The declaration of the unused global variable @.str should be removed without
; getting any error from -verify-analysis-invalidation.

; CHECK-NOT: @.str

@.str = external constant [15 x i16]

