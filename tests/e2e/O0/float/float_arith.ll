; @source: tests/e2e/src/float/float_arith.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/float_arith.c'
source_filename = "tests/e2e/src/float/float_arith.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1
@.str.1 = private unnamed_addr constant [17 x i8] c"%.6e %.6e %.17g\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"%.7f\0A\00", align 1
@.str.3 = private unnamed_addr constant [12 x i8] c"%.17g %.6f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca float, align 4
  %3 = alloca float, align 4
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca float, align 4
  %7 = alloca i32, align 4
  %8 = alloca double, align 8
  %9 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store float 1.250000e+00, ptr %2, align 4
  store float -3.500000e+00, ptr %3, align 4
  store double 1.000000e+100, ptr %4, align 8
  store double 3.000000e+00, ptr %5, align 8
  %10 = load float, ptr %2, align 4
  %11 = load float, ptr %3, align 4
  %12 = fadd float %10, %11
  %13 = fpext float %12 to double
  %14 = load float, ptr %2, align 4
  %15 = load float, ptr %3, align 4
  %16 = fsub float %14, %15
  %17 = fpext float %16 to double
  %18 = load float, ptr %2, align 4
  %19 = load float, ptr %3, align 4
  %20 = fmul float %18, %19
  %21 = fpext float %20 to double
  %22 = load float, ptr %2, align 4
  %23 = load float, ptr %3, align 4
  %24 = fdiv float %22, %23
  %25 = fpext float %24 to double
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %13, double noundef %17, double noundef %21, double noundef %25)
  %27 = load double, ptr %4, align 8
  %28 = load double, ptr %5, align 8
  %29 = fmul double %27, %28
  %30 = load double, ptr %4, align 8
  %31 = load double, ptr %5, align 8
  %32 = fdiv double %30, %31
  %33 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %29, double noundef %32, double noundef f0x3FD5555555555555)
  store float 0.000000e+00, ptr %6, align 4
  store i32 1, ptr %7, align 4
  br label %34

34:                                               ; preds = %43, %0
  %35 = load i32, ptr %7, align 4
  %36 = icmp sle i32 %35, 100
  br i1 %36, label %37, label %46

37:                                               ; preds = %34
  %38 = load i32, ptr %7, align 4
  %39 = sitofp i32 %38 to float
  %40 = fdiv float 1.000000e+00, %39
  %41 = load float, ptr %6, align 4
  %42 = fadd float %41, %40
  store float %42, ptr %6, align 4
  br label %43

43:                                               ; preds = %37
  %44 = load i32, ptr %7, align 4
  %45 = add nsw i32 %44, 1
  store i32 %45, ptr %7, align 4
  br label %34, !llvm.loop !5

46:                                               ; preds = %34
  %47 = load float, ptr %6, align 4
  %48 = fpext float %47 to double
  %49 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %48)
  store double 2.000000e+00, ptr %8, align 8
  store i32 0, ptr %9, align 4
  br label %50

50:                                               ; preds = %59, %46
  %51 = load i32, ptr %9, align 4
  %52 = icmp slt i32 %51, 6
  br i1 %52, label %53, label %62

53:                                               ; preds = %50
  %54 = load double, ptr %8, align 8
  %55 = load double, ptr %8, align 8
  %56 = fdiv double 2.000000e+00, %55
  %57 = fadd double %54, %56
  %58 = fdiv double %57, 2.000000e+00
  store double %58, ptr %8, align 8
  br label %59

59:                                               ; preds = %53
  %60 = load i32, ptr %9, align 4
  %61 = add nsw i32 %60, 1
  store i32 %61, ptr %9, align 4
  br label %50, !llvm.loop !7

62:                                               ; preds = %50
  %63 = load double, ptr %8, align 8
  %64 = load float, ptr %2, align 4
  %65 = fneg float %64
  %66 = fpext float %65 to double
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, double noundef %63, double noundef %66)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
