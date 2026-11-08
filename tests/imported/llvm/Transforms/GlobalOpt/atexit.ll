; @origin: llvm/test/Transforms/GlobalOpt/atexit.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt < %s -passes=globalopt -S | FileCheck %s

; CHECK: ModuleID
define internal i32 @__cxa_atexit(ptr nocapture %func, ptr nocapture %arg, ptr nocapture %dso_handle) nounwind readnone optsize noimplicitfloat {
  unreachable
}
