; @origin: llvm/test/Verifier/dereferenceable-md-inttoptr.ll (llvmorg-23.1.5)
; @analysis: -passes=verify
; RUN: llvm-as < %s -o /dev/null

define ptr @f_0(i8 %val) {
  %ptr = inttoptr i8 %val to ptr, !dereferenceable_or_null !{i64 2}
  ret ptr %ptr 
}
