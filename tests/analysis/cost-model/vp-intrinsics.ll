; VP intrinsics through BasicTTIImplBase::getIntrinsicInstrCost (functional opcode / intrinsic, gather, select, reverse).
; @analysis: '-passes=print<cost-model>' -cost-kind=all
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mattr=+avx2
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mattr=+avx512f
target triple = "x86_64-unknown-linux-gnu"
define void @f(<8 x i32> %a, <8 x i32> %b, <8 x i1> %m, i32 %evl, ptr %p, <8 x float> %x, <8 x ptr> %ps) {
  %1 = call <8 x i32> @llvm.vp.add.v8i32(<8 x i32> %a, <8 x i32> %b, <8 x i1> %m, i32 %evl)
  %2 = call <8 x i32> @llvm.vp.load.v8i32.p0(ptr %p, <8 x i1> %m, i32 %evl)
  call void @llvm.vp.store.v8i32.p0(<8 x i32> %a, ptr %p, <8 x i1> %m, i32 %evl)
  %3 = call <8 x i64> @llvm.vp.sext.v8i64.v8i32(<8 x i32> %a, <8 x i1> %m, i32 %evl)
  %4 = call i32 @llvm.vp.reduce.add.v8i32(i32 0, <8 x i32> %a, <8 x i1> %m, i32 %evl)
  %5 = call float @llvm.vp.reduce.fadd.v8f32(float 0.0, <8 x float> %x, <8 x i1> %m, i32 %evl)
  %6 = call <8 x i32> @llvm.vp.select.v8i32(<8 x i1> %m, <8 x i32> %a, <8 x i32> %b, i32 %evl)
  %7 = call <8 x i32> @llvm.vp.gather.v8i32.v8p0(<8 x ptr> %ps, <8 x i1> %m, i32 %evl)
  %8 = call <8 x float> @llvm.vp.fneg.v8f32(<8 x float> %x, <8 x i1> %m, i32 %evl)
  %9 = call <8 x i32> @llvm.vp.smax.v8i32(<8 x i32> %a, <8 x i32> %b, <8 x i1> %m, i32 %evl)
  %10 = call <8 x i32> @llvm.experimental.vp.reverse.v8i32(<8 x i32> %a, <8 x i1> %m, i32 %evl)
  ret void
}
