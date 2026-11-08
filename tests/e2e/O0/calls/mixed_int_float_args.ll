; @source: tests/e2e/src/calls/mixed_int_float_args.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/mixed_int_float_args.c'
source_filename = "tests/e2e/src/calls/mixed_int_float_args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"%.4f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call double @f(i32 noundef 1, double noundef 2.500000e+00, i64 noundef 3, float noundef 4.250000e+00, i8 noundef signext 5, double noundef 6.125000e+00, i32 noundef 7, float noundef 8.500000e+00, double noundef 9.000000e+00, double noundef 1.000000e+01, double noundef 1.100000e+01, double noundef 1.200000e+01, double noundef 1.306250e+01)
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %2)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal double @f(i32 noundef %0, double noundef %1, i64 noundef %2, float noundef %3, i8 noundef signext %4, double noundef %5, i32 noundef %6, float noundef %7, double noundef %8, double noundef %9, double noundef %10, double noundef %11, double noundef %12) #0 {
  %14 = alloca i32, align 4
  %15 = alloca double, align 8
  %16 = alloca i64, align 8
  %17 = alloca float, align 4
  %18 = alloca i8, align 1
  %19 = alloca double, align 8
  %20 = alloca i32, align 4
  %21 = alloca float, align 4
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  %24 = alloca double, align 8
  %25 = alloca double, align 8
  %26 = alloca double, align 8
  store i32 %0, ptr %14, align 4
  store double %1, ptr %15, align 8
  store i64 %2, ptr %16, align 8
  store float %3, ptr %17, align 4
  store i8 %4, ptr %18, align 1
  store double %5, ptr %19, align 8
  store i32 %6, ptr %20, align 4
  store float %7, ptr %21, align 4
  store double %8, ptr %22, align 8
  store double %9, ptr %23, align 8
  store double %10, ptr %24, align 8
  store double %11, ptr %25, align 8
  store double %12, ptr %26, align 8
  %27 = load i32, ptr %14, align 4
  %28 = sitofp i32 %27 to double
  %29 = load double, ptr %15, align 8
  %30 = fadd double %28, %29
  %31 = load i64, ptr %16, align 8
  %32 = sitofp i64 %31 to double
  %33 = fadd double %30, %32
  %34 = load float, ptr %17, align 4
  %35 = fpext float %34 to double
  %36 = fadd double %33, %35
  %37 = load i8, ptr %18, align 1
  %38 = sext i8 %37 to i32
  %39 = sitofp i32 %38 to double
  %40 = fadd double %36, %39
  %41 = load double, ptr %19, align 8
  %42 = fadd double %40, %41
  %43 = load i32, ptr %20, align 4
  %44 = sitofp i32 %43 to double
  %45 = fadd double %42, %44
  %46 = load float, ptr %21, align 4
  %47 = fpext float %46 to double
  %48 = fadd double %45, %47
  %49 = load double, ptr %22, align 8
  %50 = fadd double %48, %49
  %51 = load double, ptr %23, align 8
  %52 = fadd double %50, %51
  %53 = load double, ptr %24, align 8
  %54 = fadd double %52, %53
  %55 = load double, ptr %25, align 8
  %56 = fadd double %54, %55
  %57 = load double, ptr %26, align 8
  %58 = fadd double %56, %57
  ret double %58
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
