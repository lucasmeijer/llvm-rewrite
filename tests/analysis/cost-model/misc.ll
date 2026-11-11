; Calls of unknown llvm.* functions (isa<IntrinsicInst> without an intrinsic ID), scalable vectors on x86,
; cttz.elts, and the -intrinsic-cost-strategy options.
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mtriple=x86_64-unknown-linux-gnu
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mtriple=x86_64-unknown-linux-gnu -intrinsic-cost-strategy=intrinsic-cost
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mtriple=x86_64-unknown-linux-gnu -intrinsic-cost-strategy=type-based-intrinsic-cost -mattr=+avx2
define void @f(i32 %a, <vscale x 4 x i32> %s, <8 x i1> %m, <4 x i32> %v) {
  %1 = call i32 @llvm.unknown.thing(i32 %a)
  %2 = add <vscale x 4 x i32> %s, %s
  %3 = extractelement <vscale x 4 x i32> %s, i32 1
  %4 = call i64 @llvm.experimental.cttz.elts.i64.v8i1(<8 x i1> %m, i1 true)
  %5 = call i32 @llvm.experimental.cttz.elts.i32.v8i1(<8 x i1> %m, i1 false)
  %6 = call <4 x i32> @llvm.fshl.v4i32(<4 x i32> %v, <4 x i32> %v, <4 x i32> splat (i32 3))
  %7 = call <4 x i32> @llvm.umax.v4i32(<4 x i32> %v, <4 x i32> %v)
  ret void
}
declare i32 @llvm.unknown.thing(i32)
