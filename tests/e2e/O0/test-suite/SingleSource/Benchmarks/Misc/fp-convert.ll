; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"Total is %g\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local double @loop(ptr noundef %0, ptr noundef %1, i64 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca double, align 8
  store ptr %0, ptr %4, align 8
  store ptr %1, ptr %5, align 8
  store i64 %2, ptr %6, align 8
  store double 0.000000e+00, ptr %8, align 8
  store i64 0, ptr %7, align 8
  br label %9

9:                                                ; preds = %26, %3
  %10 = load i64, ptr %7, align 8
  %11 = load i64, ptr %6, align 8
  %12 = icmp slt i64 %10, %11
  br i1 %12, label %13, label %29

13:                                               ; preds = %9
  %14 = load ptr, ptr %4, align 8
  %15 = load i64, ptr %7, align 8
  %16 = getelementptr inbounds float, ptr %14, i64 %15
  %17 = load float, ptr %16, align 4
  %18 = fpext float %17 to double
  %19 = load ptr, ptr %5, align 8
  %20 = load i64, ptr %7, align 8
  %21 = getelementptr inbounds float, ptr %19, i64 %20
  %22 = load float, ptr %21, align 4
  %23 = fpext float %22 to double
  %24 = load double, ptr %8, align 8
  %25 = call double @llvm.fmuladd.f64(double %18, double %23, double %24)
  store double %25, ptr %8, align 8
  br label %26

26:                                               ; preds = %13
  %27 = load i64, ptr %7, align 8
  %28 = add nsw i64 %27, 1
  store i64 %28, ptr %7, align 8
  br label %9, !llvm.loop !5

29:                                               ; preds = %9
  %30 = load double, ptr %8, align 8
  ret double %30
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca [2048 x float], align 16
  %9 = alloca [2048 x float], align 16
  %10 = alloca double, align 8
  %11 = alloca float, align 4
  %12 = alloca float, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  store double 0.000000e+00, ptr %10, align 8
  store float 0.000000e+00, ptr %11, align 4
  store float 1.000000e+00, ptr %12, align 4
  store i32 0, ptr %6, align 4
  br label %13

13:                                               ; preds = %54, %2
  %14 = load i32, ptr %6, align 4
  %15 = icmp slt i32 %14, 500000
  br i1 %15, label %16, label %57

16:                                               ; preds = %13
  %17 = load i32, ptr %6, align 4
  %18 = srem i32 %17, 10
  %19 = icmp ne i32 %18, 0
  br i1 %19, label %20, label %21

20:                                               ; preds = %16
  store float 0.000000e+00, ptr %11, align 4
  store float 1.000000e+00, ptr %12, align 4
  br label %26

21:                                               ; preds = %16
  %22 = load float, ptr %11, align 4
  %23 = fadd float %22, 1.000000e-01
  store float %23, ptr %11, align 4
  %24 = load float, ptr %12, align 4
  %25 = fadd float %24, 2.000000e-01
  store float %25, ptr %12, align 4
  br label %26

26:                                               ; preds = %21, %20
  store i32 0, ptr %7, align 4
  br label %27

27:                                               ; preds = %45, %26
  %28 = load i32, ptr %7, align 4
  %29 = icmp slt i32 %28, 2048
  br i1 %29, label %30, label %48

30:                                               ; preds = %27
  %31 = load float, ptr %11, align 4
  %32 = load i32, ptr %7, align 4
  %33 = sitofp i32 %32 to float
  %34 = fadd float %31, %33
  %35 = load i32, ptr %7, align 4
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds [2048 x float], ptr %8, i64 0, i64 %36
  store float %34, ptr %37, align 4
  %38 = load float, ptr %12, align 4
  %39 = load i32, ptr %7, align 4
  %40 = sitofp i32 %39 to float
  %41 = fadd float %38, %40
  %42 = load i32, ptr %7, align 4
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds [2048 x float], ptr %9, i64 0, i64 %43
  store float %41, ptr %44, align 4
  br label %45

45:                                               ; preds = %30
  %46 = load i32, ptr %7, align 4
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %7, align 4
  br label %27, !llvm.loop !7

48:                                               ; preds = %27
  %49 = getelementptr inbounds [2048 x float], ptr %8, i64 0, i64 0
  %50 = getelementptr inbounds [2048 x float], ptr %9, i64 0, i64 0
  %51 = call double @loop(ptr noundef %49, ptr noundef %50, i64 noundef 2048)
  %52 = load double, ptr %10, align 8
  %53 = fadd double %52, %51
  store double %53, ptr %10, align 8
  br label %54

54:                                               ; preds = %48
  %55 = load i32, ptr %6, align 4
  %56 = add nsw i32 %55, 1
  store i32 %56, ptr %6, align 4
  br label %13, !llvm.loop !8

57:                                               ; preds = %13
  %58 = load double, ptr %10, align 8
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %58)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
!7 = distinct !{!7, !6}
!8 = distinct !{!8, !6}
