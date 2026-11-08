; @origin: llvm/test/Transforms/InstCombine/2008-05-22-IDivVector.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -disable-output

define <3 x i8> @f(<3 x i8> %i) {
  %A = sdiv <3 x i8> %i, %i
  ret <3 x i8> %A
}
