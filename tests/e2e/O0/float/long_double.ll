; @source: tests/e2e/src/float/long_double.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/long_double.c'
source_filename = "tests/e2e/src/float/long_double.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"%.18Lf %d %.18Lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"%.17g %lld %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca x86_fp80, align 16
  %3 = alloca x86_fp80, align 16
  %4 = alloca x86_fp80, align 16
  %5 = alloca i32, align 4
  %6 = alloca double, align 8
  %7 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  store x86_fp80 f0x3FFDAAAAAAAAAAAAAAAB, ptr %2, align 16
  %8 = load x86_fp80, ptr %2, align 16
  %9 = call x86_fp80 @llvm.fmuladd.f80(x86_fp80 %8, x86_fp80 3.000000e+00, x86_fp80 -1.000000e+00)
  store x86_fp80 %9, ptr %3, align 16
  store x86_fp80 0.000000e+00, ptr %4, align 16
  store i32 1, ptr %5, align 4
  br label %10

10:                                               ; preds = %22, %0
  %11 = load i32, ptr %5, align 4
  %12 = icmp sle i32 %11, 50
  br i1 %12, label %13, label %25

13:                                               ; preds = %10
  %14 = load i32, ptr %5, align 4
  %15 = sitofp i32 %14 to x86_fp80
  %16 = load i32, ptr %5, align 4
  %17 = sitofp i32 %16 to x86_fp80
  %18 = fmul x86_fp80 %15, %17
  %19 = fdiv x86_fp80 1.000000e+00, %18
  %20 = load x86_fp80, ptr %4, align 16
  %21 = fadd x86_fp80 %20, %19
  store x86_fp80 %21, ptr %4, align 16
  br label %22

22:                                               ; preds = %13
  %23 = load i32, ptr %5, align 4
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %5, align 4
  br label %10, !llvm.loop !5

25:                                               ; preds = %10
  %26 = load x86_fp80, ptr %2, align 16
  %27 = load x86_fp80, ptr %3, align 16
  %28 = fcmp olt x86_fp80 %27, 1.000000e-10
  br i1 %28, label %29, label %32

29:                                               ; preds = %25
  %30 = load x86_fp80, ptr %3, align 16
  %31 = fcmp ogt x86_fp80 %30, -1.000000e-10
  br label %32

32:                                               ; preds = %29, %25
  %33 = phi i1 [ false, %25 ], [ %31, %29 ]
  %34 = zext i1 %33 to i32
  %35 = load x86_fp80, ptr %4, align 16
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str, x86_fp80 noundef %26, i32 noundef %34, x86_fp80 noundef %35)
  %37 = load x86_fp80, ptr %4, align 16
  %38 = fptrunc x86_fp80 %37 to double
  store double %38, ptr %6, align 8
  %39 = load x86_fp80, ptr %4, align 16
  %40 = fmul x86_fp80 %39, 1.000000e+15
  %41 = fptosi x86_fp80 %40 to i64
  store i64 %41, ptr %7, align 8
  %42 = load double, ptr %6, align 8
  %43 = load i64, ptr %7, align 8
  %44 = load x86_fp80, ptr %2, align 16
  %45 = fcmp olt x86_fp80 %44, 3.400000e-01
  %46 = zext i1 %45 to i32
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %42, i64 noundef %43, i32 noundef %46)
  ret i32 0
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare x86_fp80 @llvm.fmuladd.f80(x86_fp80, x86_fp80, x86_fp80) #1

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
