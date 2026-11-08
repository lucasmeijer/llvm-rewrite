; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2007-01-04-KNR-Args.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2007-01-04-KNR-Args.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2007-01-04-KNR-Args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [25 x i8] c"%c %f %d %f %d %f %d %f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @p1(i32 noundef %0, double noundef %1, i32 noundef %2, double noundef %3, i32 noundef %4, double noundef %5, i64 noundef %6, double noundef %7) #0 {
  %9 = alloca i32, align 4
  %10 = alloca i8, align 1
  %11 = alloca float, align 4
  %12 = alloca i16, align 2
  %13 = alloca double, align 8
  %14 = alloca i32, align 4
  %15 = alloca float, align 4
  %16 = alloca i64, align 8
  %17 = alloca double, align 8
  %18 = trunc i32 %0 to i8
  %19 = fptrunc double %1 to float
  %20 = trunc i32 %2 to i16
  %21 = fptrunc double %5 to float
  store i8 %18, ptr %10, align 1
  store float %19, ptr %11, align 4
  store i16 %20, ptr %12, align 2
  store double %3, ptr %13, align 8
  store i32 %4, ptr %14, align 4
  store float %21, ptr %15, align 4
  store i64 %6, ptr %16, align 8
  store double %7, ptr %17, align 8
  %22 = load i8, ptr %10, align 1
  %23 = sext i8 %22 to i32
  %24 = load float, ptr %11, align 4
  %25 = fpext float %24 to double
  %26 = load i16, ptr %12, align 2
  %27 = sext i16 %26 to i32
  %28 = load double, ptr %13, align 8
  %29 = load i32, ptr %14, align 4
  %30 = load float, ptr %15, align 4
  %31 = fpext float %30 to double
  %32 = load i64, ptr %16, align 8
  %33 = load double, ptr %17, align 8
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %23, double noundef %25, i32 noundef %27, double noundef %28, i32 noundef %29, double noundef %31, i64 noundef %32, double noundef %33)
  %35 = load i32, ptr %9, align 4
  ret i32 %35
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @p2(i8 noundef signext %0, float noundef %1, i16 noundef signext %2, double noundef %3, i32 noundef %4, float noundef %5, i64 noundef %6, double noundef %7) #0 {
  %9 = alloca i8, align 1
  %10 = alloca float, align 4
  %11 = alloca i16, align 2
  %12 = alloca double, align 8
  %13 = alloca i32, align 4
  %14 = alloca float, align 4
  %15 = alloca i64, align 8
  %16 = alloca double, align 8
  store i8 %0, ptr %9, align 1
  store float %1, ptr %10, align 4
  store i16 %2, ptr %11, align 2
  store double %3, ptr %12, align 8
  store i32 %4, ptr %13, align 4
  store float %5, ptr %14, align 4
  store i64 %6, ptr %15, align 8
  store double %7, ptr %16, align 8
  %17 = load i8, ptr %9, align 1
  %18 = sext i8 %17 to i32
  %19 = load float, ptr %10, align 4
  %20 = fpext float %19 to double
  %21 = load i16, ptr %11, align 2
  %22 = sext i16 %21 to i32
  %23 = load double, ptr %12, align 8
  %24 = load i32, ptr %13, align 4
  %25 = load float, ptr %14, align 4
  %26 = fpext float %25 to double
  %27 = load i64, ptr %15, align 8
  %28 = load double, ptr %16, align 8
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %18, double noundef %20, i32 noundef %22, double noundef %23, i32 noundef %24, double noundef %26, i64 noundef %27, double noundef %28)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %6 = call i32 @p1(i32 noundef 97, double noundef 4.000000e+00, i32 noundef 1, double noundef 5.000000e+00, i32 noundef 2, double noundef 4.000000e+00, i64 noundef 3, double noundef 5.000000e+00)
  call void @p2(i8 noundef signext 97, float noundef 4.000000e+00, i16 noundef signext 1, double noundef 5.000000e+00, i32 noundef 2, float noundef 4.000000e+00, i64 noundef 3, double noundef 5.000000e+00)
  ret i32 0
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
