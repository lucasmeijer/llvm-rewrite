; The X86 subtarget of CPUs with !listremove feature lists, atom tuning, zhaoxin/hygon/AMD/old Intel CPUs, and
; x86-64 levels, through scalar and vector costs that depend on features and tuning (SLM costs, slow divides).
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=alderlake
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=znver4
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=znver5
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=atom
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=c86-4g-m7
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=penryn
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=k8
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=sapphirerapids
; @analysis: '-passes=print<cost-model>' -cost-kind=all -mcpu=x86-64-v3 -mattr=-avx2
target triple = "x86_64-unknown-linux-gnu"
define void @f(i32 %a, i64 %b, <8 x i32> %v, <16 x i16> %w, <4 x double> %d, <32 x i8> %c, <8 x float> %x) {
  %1 = sdiv i64 %b, %b
  %2 = mul <8 x i32> %v, %v
  %3 = shl <16 x i16> %w, %w
  %4 = fdiv <4 x double> %d, %d
  %5 = call <32 x i8> @llvm.ctpop.v32i8(<32 x i8> %c)
  %6 = call <8 x float> @llvm.sqrt.v8f32(<8 x float> %x)
  %7 = shufflevector <8 x i32> %v, <8 x i32> poison, <8 x i32> <i32 7, i32 6, i32 5, i32 4, i32 3, i32 2, i32 1, i32 0>
  %8 = call i32 @llvm.vector.reduce.add.v8i32(<8 x i32> %v)
  %9 = sitofp <8 x i32> %v to <8 x float>
  %10 = extractelement <8 x i32> %v, i32 5
  ret void
}
