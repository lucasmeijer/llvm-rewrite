; The experimental.vector.histogram intrinsics (what loop-vectorize emits with -enable-histogram-loop-vectorization):
; their declarations and the attributes opt prints for them.

define void @histograms(<4 x ptr> %buckets, i32 %inc, <4 x i1> %mask) {
  call void @llvm.experimental.vector.histogram.add.v4p0.i32(<4 x ptr> %buckets, i32 %inc, <4 x i1> %mask)
  call void @llvm.experimental.vector.histogram.uadd.sat.v4p0.i32(<4 x ptr> %buckets, i32 %inc, <4 x i1> %mask)
  call void @llvm.experimental.vector.histogram.umax.v4p0.i32(<4 x ptr> %buckets, i32 %inc, <4 x i1> %mask)
  call void @llvm.experimental.vector.histogram.umin.v4p0.i32(<4 x ptr> %buckets, i32 %inc, <4 x i1> %mask)
  ret void
}

declare void @llvm.experimental.vector.histogram.add.v4p0.i32(<4 x ptr>, i32, <4 x i1>)
declare void @llvm.experimental.vector.histogram.uadd.sat.v4p0.i32(<4 x ptr>, i32, <4 x i1>)
declare void @llvm.experimental.vector.histogram.umax.v4p0.i32(<4 x ptr>, i32, <4 x i1>)
declare void @llvm.experimental.vector.histogram.umin.v4p0.i32(<4 x ptr>, i32, <4 x i1>)
