; @source: tests/e2e/src/misc/vectors.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/vectors.c'
source_filename = "tests/e2e/src/misc/vectors.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d %d %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [21 x i8] c"%.3f %.3f %.3f %.3f\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%.3f %.3f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca <4 x i32>, align 16
  %3 = alloca <4 x i32>, align 16
  %4 = alloca <4 x i32>, align 16
  %5 = alloca <4 x float>, align 16
  %6 = alloca <4 x float>, align 16
  %7 = alloca <2 x double>, align 16
  %8 = alloca <4 x i32>, align 16
  %9 = alloca <4 x i32>, align 16
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store <4 x i32> <i32 1, i32 2, i32 3, i32 4>, ptr %2, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store <4 x i32> <i32 10, i32 20, i32 30, i32 40>, ptr %3, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %10 = load <4 x i32>, ptr %2, align 16, !tbaa !9
  %11 = load <4 x i32>, ptr %3, align 16, !tbaa !9
  %12 = mul <4 x i32> %10, %11
  %13 = load <4 x i32>, ptr %3, align 16, !tbaa !9
  %14 = ashr <4 x i32> %13, splat (i32 1)
  %15 = add <4 x i32> %12, %14
  %16 = load <4 x i32>, ptr %2, align 16, !tbaa !9
  %17 = and <4 x i32> %16, splat (i32 1)
  %18 = sub <4 x i32> %15, %17
  store <4 x i32> %18, ptr %4, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store <4 x float> <float 1.500000e+00, float -2.000000e+00, float 2.500000e-01, float 8.000000e+00>, ptr %5, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #4
  %19 = load <4 x float>, ptr %5, align 16, !tbaa !9
  %20 = load <4 x float>, ptr %5, align 16, !tbaa !9
  %21 = call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %19, <4 x float> %20, <4 x float> splat (float 1.000000e+00))
  store <4 x float> %21, ptr %6, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #4
  store <2 x double> <double 3.000000e+00, double 4.000000e+00>, ptr %7, align 16, !tbaa !9
  %22 = load <2 x double>, ptr %7, align 16, !tbaa !9
  %23 = fdiv <2 x double> %22, splat (double 2.000000e+00)
  store <2 x double> %23, ptr %7, align 16, !tbaa !9
  %24 = load <4 x i32>, ptr %4, align 16, !tbaa !9
  %25 = extractelement <4 x i32> %24, i32 0
  %26 = load <4 x i32>, ptr %4, align 16, !tbaa !9
  %27 = extractelement <4 x i32> %26, i32 1
  %28 = load <4 x i32>, ptr %4, align 16, !tbaa !9
  %29 = extractelement <4 x i32> %28, i32 2
  %30 = load <4 x i32>, ptr %4, align 16, !tbaa !9
  %31 = extractelement <4 x i32> %30, i32 3
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %25, i32 noundef %27, i32 noundef %29, i32 noundef %31)
  %33 = load <4 x float>, ptr %6, align 16, !tbaa !9
  %34 = extractelement <4 x float> %33, i32 0
  %35 = fpext float %34 to double
  %36 = load <4 x float>, ptr %6, align 16, !tbaa !9
  %37 = extractelement <4 x float> %36, i32 1
  %38 = fpext float %37 to double
  %39 = load <4 x float>, ptr %6, align 16, !tbaa !9
  %40 = extractelement <4 x float> %39, i32 2
  %41 = fpext float %40 to double
  %42 = load <4 x float>, ptr %6, align 16, !tbaa !9
  %43 = extractelement <4 x float> %42, i32 3
  %44 = fpext float %43 to double
  %45 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %35, double noundef %38, double noundef %41, double noundef %44)
  %46 = load <2 x double>, ptr %7, align 16, !tbaa !9
  %47 = extractelement <2 x double> %46, i32 0
  %48 = load <2 x double>, ptr %7, align 16, !tbaa !9
  %49 = extractelement <2 x double> %48, i32 1
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %47, double noundef %49)
  call void @llvm.lifetime.start.p0(ptr %8) #4
  %51 = load <4 x i32>, ptr %2, align 16, !tbaa !9
  store <4 x i32> splat (i32 2), ptr %9, align 16, !tbaa !9
  %52 = load <4 x i32>, ptr %9, align 16, !tbaa !9
  %53 = icmp sgt <4 x i32> %51, %52
  %54 = sext <4 x i1> %53 to <4 x i32>
  store <4 x i32> %54, ptr %8, align 16, !tbaa !9
  %55 = load <4 x i32>, ptr %8, align 16, !tbaa !9
  %56 = extractelement <4 x i32> %55, i32 0
  %57 = load <4 x i32>, ptr %8, align 16, !tbaa !9
  %58 = extractelement <4 x i32> %57, i32 1
  %59 = load <4 x i32>, ptr %8, align 16, !tbaa !9
  %60 = extractelement <4 x i32> %59, i32 2
  %61 = load <4 x i32>, ptr %8, align 16, !tbaa !9
  %62 = extractelement <4 x i32> %61, i32 3
  %63 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %56, i32 noundef %58, i32 noundef %60, i32 noundef %62)
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <4 x float> @llvm.fmuladd.v4f32(<4 x float>, <4 x float>, <4 x float>) #2

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!4 = !{!5, !6, i64 0}
!5 = !{!"__libc_errno", !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{!7, !7, i64 0}
