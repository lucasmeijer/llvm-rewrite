; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/pi.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/pi.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/pi.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [16 x i8] c"Starting PI...\0A\00", align 1
@.str.1 = private unnamed_addr constant [45 x i8] c" x = %9.6f    y = %12.2f  low = %8d j = %7d\0A\00", align 1
@.str.2 = private unnamed_addr constant [37 x i8] c"Pi = %9.6f ztot = %12.2f itot = %8d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @myadd(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !9
  %5 = load ptr, ptr %3, align 8, !tbaa !9
  %6 = load float, ptr %5, align 4, !tbaa !12
  %7 = load ptr, ptr %4, align 8, !tbaa !9
  %8 = load float, ptr %7, align 4, !tbaa !12
  %9 = fadd float %6, %8
  %10 = load ptr, ptr %3, align 8, !tbaa !9
  store float %9, ptr %10, align 4, !tbaa !12
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca float, align 4
  %7 = alloca float, align 4
  %8 = alloca float, align 4
  %9 = alloca float, align 4
  %10 = alloca float, align 4
  %11 = alloca float, align 4
  %12 = alloca float, align 4
  %13 = alloca float, align 4
  %14 = alloca float, align 4
  %15 = alloca i64, align 8
  %16 = alloca i64, align 8
  %17 = alloca i64, align 8
  %18 = alloca i64, align 8
  %19 = alloca i64, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !14
  store ptr %1, ptr %5, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  call void @llvm.lifetime.start.p0(ptr %8) #4
  call void @llvm.lifetime.start.p0(ptr %9) #4
  call void @llvm.lifetime.start.p0(ptr %10) #4
  call void @llvm.lifetime.start.p0(ptr %11) #4
  call void @llvm.lifetime.start.p0(ptr %12) #4
  call void @llvm.lifetime.start.p0(ptr %13) #4
  call void @llvm.lifetime.start.p0(ptr %14) #4
  call void @llvm.lifetime.start.p0(ptr %15) #4
  call void @llvm.lifetime.start.p0(ptr %16) #4
  call void @llvm.lifetime.start.p0(ptr %17) #4
  call void @llvm.lifetime.start.p0(ptr %18) #4
  call void @llvm.lifetime.start.p0(ptr %19) #4
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  store float 0.000000e+00, ptr %6, align 4, !tbaa !12
  store i64 1, ptr %15, align 8, !tbaa !18
  store i64 1907, ptr %16, align 8, !tbaa !18
  store float 5.813000e+03, ptr %7, align 4, !tbaa !12
  store float 1.307000e+03, ptr %8, align 4, !tbaa !12
  store float 5.471000e+03, ptr %9, align 4, !tbaa !12
  store i64 40000000, ptr %17, align 8, !tbaa !18
  store i64 1, ptr %18, align 8, !tbaa !18
  br label %21

21:                                               ; preds = %66, %2
  %22 = load i64, ptr %18, align 8, !tbaa !18
  %23 = load i64, ptr %17, align 8, !tbaa !18
  %24 = icmp sle i64 %22, %23
  br i1 %24, label %25, label %69

25:                                               ; preds = %21
  %26 = load i64, ptr %16, align 8, !tbaa !18
  %27 = mul nsw i64 27611, %26
  store i64 %27, ptr %19, align 8, !tbaa !18
  %28 = load i64, ptr %19, align 8, !tbaa !18
  %29 = load i64, ptr %19, align 8, !tbaa !18
  %30 = sdiv i64 %29, 74383
  %31 = mul nsw i64 74383, %30
  %32 = sub nsw i64 %28, %31
  store i64 %32, ptr %16, align 8, !tbaa !18
  %33 = load i64, ptr %16, align 8, !tbaa !18
  %34 = sitofp i64 %33 to float
  %35 = fpext float %34 to double
  %36 = fdiv double %35, 7.438300e+04
  %37 = fptrunc double %36 to float
  store float %37, ptr %10, align 4, !tbaa !12
  %38 = load float, ptr %8, align 4, !tbaa !12
  %39 = load float, ptr %7, align 4, !tbaa !12
  %40 = fmul float %38, %39
  store float %40, ptr %14, align 4, !tbaa !12
  %41 = load float, ptr %14, align 4, !tbaa !12
  %42 = load float, ptr %9, align 4, !tbaa !12
  %43 = load float, ptr %14, align 4, !tbaa !12
  %44 = load float, ptr %9, align 4, !tbaa !12
  %45 = fdiv float %43, %44
  %46 = fptosi float %45 to i64
  %47 = sitofp i64 %46 to float
  %48 = fneg float %42
  %49 = call float @llvm.fmuladd.f32(float %48, float %47, float %41)
  store float %49, ptr %7, align 4, !tbaa !12
  %50 = load float, ptr %7, align 4, !tbaa !12
  %51 = load float, ptr %9, align 4, !tbaa !12
  %52 = fdiv float %50, %51
  store float %52, ptr %11, align 4, !tbaa !12
  %53 = load float, ptr %10, align 4, !tbaa !12
  %54 = load float, ptr %10, align 4, !tbaa !12
  %55 = load float, ptr %11, align 4, !tbaa !12
  %56 = load float, ptr %11, align 4, !tbaa !12
  %57 = fmul float %55, %56
  %58 = call float @llvm.fmuladd.f32(float %53, float %54, float %57)
  store float %58, ptr %12, align 4, !tbaa !12
  call void @myadd(ptr noundef %6, ptr noundef %12)
  %59 = load float, ptr %12, align 4, !tbaa !12
  %60 = fpext float %59 to double
  %61 = fcmp ole double %60, 1.000000e+00
  br i1 %61, label %62, label %65

62:                                               ; preds = %25
  %63 = load i64, ptr %15, align 8, !tbaa !18
  %64 = add nsw i64 %63, 1
  store i64 %64, ptr %15, align 8, !tbaa !18
  br label %65

65:                                               ; preds = %62, %25
  br label %66

66:                                               ; preds = %65
  %67 = load i64, ptr %18, align 8, !tbaa !18
  %68 = add nsw i64 %67, 1
  store i64 %68, ptr %18, align 8, !tbaa !18
  br label %21, !llvm.loop !20

69:                                               ; preds = %21
  %70 = load float, ptr %10, align 4, !tbaa !12
  %71 = fpext float %70 to double
  %72 = load float, ptr %11, align 4, !tbaa !12
  %73 = fpext float %72 to double
  %74 = load i64, ptr %15, align 8, !tbaa !18
  %75 = trunc i64 %74 to i32
  %76 = load i64, ptr %18, align 8, !tbaa !18
  %77 = trunc i64 %76 to i32
  %78 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %71, double noundef %73, i32 noundef %75, i32 noundef %77)
  %79 = load i64, ptr %15, align 8, !tbaa !18
  %80 = sitofp i64 %79 to float
  %81 = fpext float %80 to double
  %82 = fmul double 4.000000e+00, %81
  %83 = load i64, ptr %17, align 8, !tbaa !18
  %84 = sitofp i64 %83 to float
  %85 = fpext float %84 to double
  %86 = fdiv double %82, %85
  %87 = fptrunc double %86 to float
  store float %87, ptr %13, align 4, !tbaa !12
  %88 = load float, ptr %13, align 4, !tbaa !12
  %89 = fpext float %88 to double
  %90 = load float, ptr %6, align 4, !tbaa !12
  %91 = fpext float %90 to double
  %92 = fmul double %91, 0.000000e+00
  %93 = load i64, ptr %17, align 8, !tbaa !18
  %94 = trunc i64 %93 to i32
  %95 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %89, double noundef %92, i32 noundef %94)
  call void @llvm.lifetime.end.p0(ptr %19) #4
  call void @llvm.lifetime.end.p0(ptr %18) #4
  call void @llvm.lifetime.end.p0(ptr %17) #4
  call void @llvm.lifetime.end.p0(ptr %16) #4
  call void @llvm.lifetime.end.p0(ptr %15) #4
  call void @llvm.lifetime.end.p0(ptr %14) #4
  call void @llvm.lifetime.end.p0(ptr %13) #4
  call void @llvm.lifetime.end.p0(ptr %12) #4
  call void @llvm.lifetime.end.p0(ptr %11) #4
  call void @llvm.lifetime.end.p0(ptr %10) #4
  call void @llvm.lifetime.end.p0(ptr %9) #4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 float", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"float", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"p2 omnipotent char", !17, i64 0}
!17 = !{!"any p2 pointer", !11, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"long", !7, i64 0}
!20 = distinct !{!20, !21}
!21 = !{!"llvm.loop.mustprogress"}
