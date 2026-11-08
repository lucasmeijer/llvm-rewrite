; The x86 cost model (all cost kinds) for scalar and vector integer/float arithmetic, at several -mattr levels.
; @analysis: -mtriple=x86_64-unknown-linux-gnu '-passes=print<cost-model>' -cost-kind=all
; @analysis: -mtriple=x86_64-unknown-linux-gnu '-passes=print<cost-model>' -cost-kind=all -mattr=+avx2
; @analysis: -mtriple=x86_64-unknown-linux-gnu '-passes=print<cost-model>' -cost-kind=all -mattr=+avx512f,+avx512bw
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define void @arith(i32 %a, i64 %b, <4 x i32> %v4, <8 x i32> %v8, <16 x i8> %b16, <4 x float> %f4, <8 x double> %d8) {
  %1 = add i32 %a, %a
  %2 = mul i64 %b, %b
  %3 = sdiv i32 %a, 7
  %4 = udiv i64 %b, %b
  %5 = mul <4 x i32> %v4, %v4
  %6 = add <8 x i32> %v8, %v8
  %7 = shl <8 x i32> %v8, %v8
  %8 = mul <16 x i8> %b16, %b16
  %9 = fadd <4 x float> %f4, %f4
  %10 = fdiv <8 x double> %d8, %d8
  %11 = sdiv <4 x i32> %v4, <i32 4, i32 4, i32 4, i32 4>
  ret void
}

define void @casts_and_memory(ptr %p, <4 x i32> %v4, <8 x i16> %w8) {
  %1 = sext <8 x i16> %w8 to <8 x i32>
  %2 = trunc <4 x i32> %v4 to <4 x i8>
  %3 = sitofp <4 x i32> %v4 to <4 x double>
  %4 = load <8 x float>, ptr %p, align 4
  store <4 x i32> %v4, ptr %p, align 16
  %5 = extractelement <4 x i32> %v4, i32 2
  %6 = insertelement <8 x i16> %w8, i16 1, i32 0
  %7 = shufflevector <4 x i32> %v4, <4 x i32> %v4, <4 x i32> <i32 3, i32 2, i32 1, i32 0>
  %8 = icmp sgt <4 x i32> %v4, zeroinitializer
  %9 = select <4 x i1> %8, <4 x i32> %v4, <4 x i32> zeroinitializer
  ret void
}
