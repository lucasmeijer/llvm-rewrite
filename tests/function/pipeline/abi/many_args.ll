; @source: tests/function/src/abi/many_args.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/abi/many_args.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/many_args.c'
source_filename = "tests/function/src/abi/many_args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local double @mixed20(i32 noundef %0, double noundef %1, i8 noundef signext %2, float noundef %3, i64 noundef %4, double noundef %5, i16 noundef signext %6, float noundef %7, i32 noundef %8, double noundef %9, i64 noundef %10, float noundef %11, i32 noundef %12, double noundef %13, i8 noundef signext %14, double noundef %15, i64 noundef %16, float noundef %17, i32 noundef %18, double noundef %19) #0 {
  %21 = alloca i32, align 4
  %22 = alloca double, align 8
  %23 = alloca i8, align 1
  %24 = alloca float, align 4
  %25 = alloca i64, align 8
  %26 = alloca double, align 8
  %27 = alloca i16, align 2
  %28 = alloca float, align 4
  %29 = alloca i32, align 4
  %30 = alloca double, align 8
  %31 = alloca i64, align 8
  %32 = alloca float, align 4
  %33 = alloca i32, align 4
  %34 = alloca double, align 8
  %35 = alloca i8, align 1
  %36 = alloca double, align 8
  %37 = alloca i64, align 8
  %38 = alloca float, align 4
  %39 = alloca i32, align 4
  %40 = alloca double, align 8
  store i32 %0, ptr %21, align 4, !tbaa !9
  store double %1, ptr %22, align 8, !tbaa !10
  store i8 %2, ptr %23, align 1, !tbaa !12
  store float %3, ptr %24, align 4, !tbaa !13
  store i64 %4, ptr %25, align 8, !tbaa !15
  store double %5, ptr %26, align 8, !tbaa !10
  store i16 %6, ptr %27, align 2, !tbaa !17
  store float %7, ptr %28, align 4, !tbaa !13
  store i32 %8, ptr %29, align 4, !tbaa !9
  store double %9, ptr %30, align 8, !tbaa !10
  store i64 %10, ptr %31, align 8, !tbaa !15
  store float %11, ptr %32, align 4, !tbaa !13
  store i32 %12, ptr %33, align 4, !tbaa !9
  store double %13, ptr %34, align 8, !tbaa !10
  store i8 %14, ptr %35, align 1, !tbaa !12
  store double %15, ptr %36, align 8, !tbaa !10
  store i64 %16, ptr %37, align 8, !tbaa !15
  store float %17, ptr %38, align 4, !tbaa !13
  store i32 %18, ptr %39, align 4, !tbaa !9
  store double %19, ptr %40, align 8, !tbaa !10
  %41 = load i32, ptr %21, align 4, !tbaa !9
  %42 = sitofp i32 %41 to double
  %43 = load double, ptr %22, align 8, !tbaa !10
  %44 = call double @llvm.fmuladd.f64(double %43, double 2.000000e+00, double %42)
  %45 = load i8, ptr %23, align 1, !tbaa !12
  %46 = sext i8 %45 to i32
  %47 = mul nsw i32 %46, 3
  %48 = sitofp i32 %47 to double
  %49 = fadd double %44, %48
  %50 = load float, ptr %24, align 4, !tbaa !13
  %51 = fmul float %50, 4.000000e+00
  %52 = fpext float %51 to double
  %53 = fadd double %49, %52
  %54 = load i64, ptr %25, align 8, !tbaa !15
  %55 = mul nsw i64 %54, 5
  %56 = sitofp i64 %55 to double
  %57 = fadd double %53, %56
  %58 = load double, ptr %26, align 8, !tbaa !10
  %59 = call double @llvm.fmuladd.f64(double %58, double 6.000000e+00, double %57)
  %60 = load i16, ptr %27, align 2, !tbaa !17
  %61 = sext i16 %60 to i32
  %62 = mul nsw i32 %61, 7
  %63 = sitofp i32 %62 to double
  %64 = fadd double %59, %63
  %65 = load float, ptr %28, align 4, !tbaa !13
  %66 = fmul float %65, 8.000000e+00
  %67 = fpext float %66 to double
  %68 = fadd double %64, %67
  %69 = load i32, ptr %29, align 4, !tbaa !9
  %70 = mul nsw i32 %69, 9
  %71 = sitofp i32 %70 to double
  %72 = fadd double %68, %71
  %73 = load double, ptr %30, align 8, !tbaa !10
  %74 = call double @llvm.fmuladd.f64(double %73, double 1.000000e+01, double %72)
  %75 = load i64, ptr %31, align 8, !tbaa !15
  %76 = mul nsw i64 %75, 11
  %77 = sitofp i64 %76 to double
  %78 = fadd double %74, %77
  %79 = load float, ptr %32, align 4, !tbaa !13
  %80 = fmul float %79, 1.200000e+01
  %81 = fpext float %80 to double
  %82 = fadd double %78, %81
  %83 = load i32, ptr %33, align 4, !tbaa !9
  %84 = mul nsw i32 %83, 13
  %85 = sitofp i32 %84 to double
  %86 = fadd double %82, %85
  %87 = load double, ptr %34, align 8, !tbaa !10
  %88 = call double @llvm.fmuladd.f64(double %87, double 1.400000e+01, double %86)
  %89 = load i8, ptr %35, align 1, !tbaa !12
  %90 = sext i8 %89 to i32
  %91 = mul nsw i32 %90, 15
  %92 = sitofp i32 %91 to double
  %93 = fadd double %88, %92
  %94 = load double, ptr %36, align 8, !tbaa !10
  %95 = call double @llvm.fmuladd.f64(double %94, double 1.600000e+01, double %93)
  %96 = load i64, ptr %37, align 8, !tbaa !15
  %97 = mul nsw i64 %96, 17
  %98 = sitofp i64 %97 to double
  %99 = fadd double %95, %98
  %100 = load float, ptr %38, align 4, !tbaa !13
  %101 = fmul float %100, 1.800000e+01
  %102 = fpext float %101 to double
  %103 = fadd double %99, %102
  %104 = load i32, ptr %39, align 4, !tbaa !9
  %105 = mul nsw i32 %104, 19
  %106 = sitofp i32 %105 to double
  %107 = fadd double %103, %106
  %108 = load double, ptr %40, align 8, !tbaa !10
  %109 = call double @llvm.fmuladd.f64(double %108, double 2.000000e+01, double %107)
  ret double %109
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: nounwind uwtable
define dso_local i64 @ints12(i64 noundef %0, i64 noundef %1, i64 noundef %2, i64 noundef %3, i64 noundef %4, i64 noundef %5, i64 noundef %6, i64 noundef %7, i64 noundef %8, i64 noundef %9, i64 noundef %10, i64 noundef %11) #0 {
  %13 = alloca i64, align 8
  %14 = alloca i64, align 8
  %15 = alloca i64, align 8
  %16 = alloca i64, align 8
  %17 = alloca i64, align 8
  %18 = alloca i64, align 8
  %19 = alloca i64, align 8
  %20 = alloca i64, align 8
  %21 = alloca i64, align 8
  %22 = alloca i64, align 8
  %23 = alloca i64, align 8
  %24 = alloca i64, align 8
  store i64 %0, ptr %13, align 8, !tbaa !15
  store i64 %1, ptr %14, align 8, !tbaa !15
  store i64 %2, ptr %15, align 8, !tbaa !15
  store i64 %3, ptr %16, align 8, !tbaa !15
  store i64 %4, ptr %17, align 8, !tbaa !15
  store i64 %5, ptr %18, align 8, !tbaa !15
  store i64 %6, ptr %19, align 8, !tbaa !15
  store i64 %7, ptr %20, align 8, !tbaa !15
  store i64 %8, ptr %21, align 8, !tbaa !15
  store i64 %9, ptr %22, align 8, !tbaa !15
  store i64 %10, ptr %23, align 8, !tbaa !15
  store i64 %11, ptr %24, align 8, !tbaa !15
  %25 = load i64, ptr %13, align 8, !tbaa !15
  %26 = load i64, ptr %14, align 8, !tbaa !15
  %27 = sub nsw i64 %25, %26
  %28 = load i64, ptr %15, align 8, !tbaa !15
  %29 = add nsw i64 %27, %28
  %30 = load i64, ptr %16, align 8, !tbaa !15
  %31 = sub nsw i64 %29, %30
  %32 = load i64, ptr %17, align 8, !tbaa !15
  %33 = add nsw i64 %31, %32
  %34 = load i64, ptr %18, align 8, !tbaa !15
  %35 = sub nsw i64 %33, %34
  %36 = load i64, ptr %19, align 8, !tbaa !15
  %37 = add nsw i64 %35, %36
  %38 = load i64, ptr %20, align 8, !tbaa !15
  %39 = sub nsw i64 %37, %38
  %40 = load i64, ptr %21, align 8, !tbaa !15
  %41 = add nsw i64 %39, %40
  %42 = load i64, ptr %22, align 8, !tbaa !15
  %43 = sub nsw i64 %41, %42
  %44 = load i64, ptr %23, align 8, !tbaa !15
  %45 = add nsw i64 %43, %44
  %46 = load i64, ptr %24, align 8, !tbaa !15
  %47 = mul nsw i64 %46, 3
  %48 = sub nsw i64 %45, %47
  ret i64 %48
}

; Function Attrs: nounwind uwtable
define dso_local float @floats10(float noundef %0, float noundef %1, float noundef %2, float noundef %3, float noundef %4, float noundef %5, float noundef %6, float noundef %7, float noundef %8, float noundef %9) #0 {
  %11 = alloca float, align 4
  %12 = alloca float, align 4
  %13 = alloca float, align 4
  %14 = alloca float, align 4
  %15 = alloca float, align 4
  %16 = alloca float, align 4
  %17 = alloca float, align 4
  %18 = alloca float, align 4
  %19 = alloca float, align 4
  %20 = alloca float, align 4
  store float %0, ptr %11, align 4, !tbaa !13
  store float %1, ptr %12, align 4, !tbaa !13
  store float %2, ptr %13, align 4, !tbaa !13
  store float %3, ptr %14, align 4, !tbaa !13
  store float %4, ptr %15, align 4, !tbaa !13
  store float %5, ptr %16, align 4, !tbaa !13
  store float %6, ptr %17, align 4, !tbaa !13
  store float %7, ptr %18, align 4, !tbaa !13
  store float %8, ptr %19, align 4, !tbaa !13
  store float %9, ptr %20, align 4, !tbaa !13
  %21 = load float, ptr %11, align 4, !tbaa !13
  %22 = load float, ptr %12, align 4, !tbaa !13
  %23 = fadd float %21, %22
  %24 = load float, ptr %13, align 4, !tbaa !13
  %25 = fsub float %23, %24
  %26 = load float, ptr %14, align 4, !tbaa !13
  %27 = fadd float %25, %26
  %28 = load float, ptr %15, align 4, !tbaa !13
  %29 = fsub float %27, %28
  %30 = load float, ptr %16, align 4, !tbaa !13
  %31 = fadd float %29, %30
  %32 = load float, ptr %17, align 4, !tbaa !13
  %33 = fsub float %31, %32
  %34 = load float, ptr %18, align 4, !tbaa !13
  %35 = fadd float %33, %34
  %36 = load float, ptr %19, align 4, !tbaa !13
  %37 = fsub float %35, %36
  %38 = load float, ptr %20, align 4, !tbaa !13
  %39 = call float @llvm.fmuladd.f32(float %38, float 5.000000e-01, float %37)
  ret float %39
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #1

; Function Attrs: nounwind uwtable
define dso_local zeroext i8 @small_args(i8 noundef zeroext %0, i8 noundef signext %1, i16 noundef zeroext %2, i16 noundef signext %3, i1 noundef zeroext %4) #0 {
  %6 = alloca i8, align 1
  %7 = alloca i8, align 1
  %8 = alloca i16, align 2
  %9 = alloca i16, align 2
  %10 = alloca i8, align 1
  store i8 %0, ptr %6, align 1, !tbaa !12
  store i8 %1, ptr %7, align 1, !tbaa !12
  store i16 %2, ptr %8, align 2, !tbaa !17
  store i16 %3, ptr %9, align 2, !tbaa !17
  %11 = zext i1 %4 to i8
  store i8 %11, ptr %10, align 1, !tbaa !19
  %12 = load i8, ptr %6, align 1, !tbaa !12
  %13 = zext i8 %12 to i32
  %14 = load i8, ptr %7, align 1, !tbaa !12
  %15 = sext i8 %14 to i32
  %16 = add nsw i32 %13, %15
  %17 = load i16, ptr %8, align 2, !tbaa !17
  %18 = zext i16 %17 to i32
  %19 = add nsw i32 %16, %18
  %20 = load i16, ptr %9, align 2, !tbaa !17
  %21 = sext i16 %20 to i32
  %22 = add nsw i32 %19, %21
  %23 = load i8, ptr %10, align 1, !tbaa !19, !range !21, !noundef !22
  %24 = trunc i8 %23 to i1
  %25 = zext i1 %24 to i32
  %26 = add nsw i32 %22, %25
  %27 = trunc i32 %26 to i8
  ret i8 %27
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"double", !7, i64 0}
!12 = !{!7, !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"float", !7, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"long", !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"short", !7, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"_Bool", !7, i64 0}
!21 = !{i8 0, i8 2}
!22 = !{}
