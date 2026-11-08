; @origin: llvm/test/Transforms/InferFunctionAttrs/readonly_and_writeonly.ll (llvmorg-23.1.5)
; @opt: -mtriple=x86_64-- -passes=inferattrs
; RUN: opt < %s -mtriple=x86_64-- -passes=inferattrs -S | FileCheck --match-full-lines %s

; Frontends can emit math functions with 'readonly', don't crash on it.

; CHECK: declare double @acos(double) [[NOFREE_NOUNWIND_WILLRETURN_READNONE:#[0-9]+]]
declare double @acos(double) readonly

; CHECK-DAG: attributes [[NOFREE_NOUNWIND_WILLRETURN_READNONE]] = { mustprogress nocallback nofree nosync nounwind willreturn memory(none) }
