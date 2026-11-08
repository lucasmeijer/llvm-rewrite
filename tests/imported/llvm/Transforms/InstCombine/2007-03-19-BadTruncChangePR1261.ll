; @origin: llvm/test/Transforms/InstCombine/2007-03-19-BadTruncChangePR1261.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep zext
; PR1261. 

define i16 @test(i31 %zzz) {
  %A = sext i31 %zzz to i32
  %B = add i32 %A, 16384
  %C = lshr i32 %B, 15
  %D = trunc i32 %C to i16
  ret i16 %D
}
