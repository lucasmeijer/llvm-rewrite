%struct.point = type { i32, i32 }
%struct.node = type { i64, ptr, [4 x %struct.point] }
%packed = type <{ i8, i32 }>
%opaque = type opaque

@g = global %struct.node zeroinitializer
@v = global <4 x float> <float 1.0, float 2.0, float 0x3FB99999A0000000, float -0.0>
@arr = global [3 x [2 x i16]] [[2 x i16] [i16 1, i16 2], [2 x i16] zeroinitializer, [2 x i16] [i16 -1, i16 5]]

define { i32, double } @mk(i32 %x) {
  %a = insertvalue { i32, double } poison, i32 %x, 0
  %b = insertvalue { i32, double } %a, double 1.5, 1
  ret { i32, double } %b
}

define <4 x i32> @vec(<4 x i32> %a, <vscale x 2 x i64> %s) {
  %e = extractelement <4 x i32> %a, i64 2
  %i = insertelement <4 x i32> %a, i32 %e, i32 0
  %sh = shufflevector <4 x i32> %i, <4 x i32> undef, <4 x i32> <i32 3, i32 2, i32 poison, i32 0>
  ret <4 x i32> %sh
}
