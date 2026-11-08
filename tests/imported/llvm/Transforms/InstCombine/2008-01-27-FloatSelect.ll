; @origin: llvm/test/Transforms/InstCombine/2008-01-27-FloatSelect.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | FileCheck %s
; CHECK: select

define double @fold(i1 %a, double %b) {
%s = select i1 %a, double 0., double 1.
%c = fdiv double %b, %s
ret double %c
}
