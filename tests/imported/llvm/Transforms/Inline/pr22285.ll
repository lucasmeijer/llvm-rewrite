; @origin: llvm/test/Transforms/Inline/pr22285.ll (llvmorg-23.1.5)
; @opt: '-passes=cgscc(inline),globaldce'
; RUN: opt < %s -passes='cgscc(inline),globaldce' -S | FileCheck %s

$f1 = comdat any
; CHECK-NOT: $f1 = comdat any

define void @f2() {
  call void @f1()
  ret void
}
; CHECK-LABEL: define void @f2

define linkonce_odr void @f1() comdat {
  ret void
}
; CHECK-NOT: define linkonce_odr void @f1() comdat
