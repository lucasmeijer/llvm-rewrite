; @source: tests/e2e/src/float/conversions.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/conversions.c'
source_filename = "tests/e2e/src/float/conversions.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%lld %lld %.3f %.3f\0A\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c"%u %llu\0A\00", align 1
@.str.2 = private unnamed_addr constant [21 x i8] c"%.1f %.1f %.1f %.1f\0A\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"%.1f %.1f %.1f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [7 x double], align 16
  %3 = alloca i32, align 4
  %4 = alloca double, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  %8 = alloca i8, align 1
  %9 = alloca i8, align 1
  %10 = alloca i16, align 2
  store i32 0, ptr %1, align 4
  call void @llvm.memset.p0.i64(ptr align 16 %2, i8 0, i64 56, i1 false)
  %11 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 1
  store double -5.000000e-01, ptr %11, align 8
  %12 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 2
  store double 1.500000e+00, ptr %12, align 16
  %13 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 3
  store double -2.750000e+00, ptr %13, align 8
  %14 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 4
  store double f0x40FE240C9FBE76C9, ptr %14, align 16
  %15 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 5
  store double f0x41EFFFFFFFE00000, ptr %15, align 8
  %16 = getelementptr inbounds [7 x double], ptr %2, i32 0, i32 6
  store double f0xC1E0000000000000, ptr %16, align 16
  store i32 0, ptr %3, align 4
  br label %17

17:                                               ; preds = %45, %0
  %18 = load i32, ptr %3, align 4
  %19 = icmp slt i32 %18, 7
  br i1 %19, label %20, label %48

20:                                               ; preds = %17
  %21 = load i32, ptr %3, align 4
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [7 x double], ptr %2, i64 0, i64 %22
  %24 = load double, ptr %23, align 8
  store double %24, ptr %4, align 8
  %25 = load double, ptr %4, align 8
  %26 = fptosi double %25 to i64
  %27 = load double, ptr %4, align 8
  %28 = fptosi double %27 to i64
  %29 = load double, ptr %4, align 8
  %30 = fptrunc double %29 to float
  %31 = fpext float %30 to double
  %32 = load double, ptr %4, align 8
  %33 = fptrunc double %32 to float
  %34 = fpext float %33 to double
  %35 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %26, i64 noundef %28, double noundef %31, double noundef %34)
  %36 = load double, ptr %4, align 8
  %37 = fcmp oge double %36, 0.000000e+00
  br i1 %37, label %38, label %44

38:                                               ; preds = %20
  %39 = load double, ptr %4, align 8
  %40 = fptoui double %39 to i32
  %41 = load double, ptr %4, align 8
  %42 = fptoui double %41 to i64
  %43 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %40, i64 noundef %42)
  br label %44

44:                                               ; preds = %38, %20
  br label %45

45:                                               ; preds = %44
  %46 = load i32, ptr %3, align 4
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %3, align 4
  br label %17, !llvm.loop !5

48:                                               ; preds = %17
  store i64 -1, ptr %5, align 8
  store i64 -9007199254740993, ptr %6, align 8
  store i32 -1, ptr %7, align 4
  %49 = load i64, ptr %5, align 8
  %50 = uitofp i64 %49 to double
  %51 = load i64, ptr %6, align 8
  %52 = sitofp i64 %51 to double
  %53 = load i32, ptr %7, align 4
  %54 = uitofp i32 %53 to double
  %55 = load i64, ptr %5, align 8
  %56 = uitofp i64 %55 to float
  %57 = fpext float %56 to double
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %50, double noundef %52, double noundef %54, double noundef %57)
  store i8 -7, ptr %8, align 1
  store i8 -6, ptr %9, align 1
  store i16 -1234, ptr %10, align 2
  %59 = load i8, ptr %8, align 1
  %60 = sitofp i8 %59 to double
  %61 = load i8, ptr %9, align 1
  %62 = uitofp i8 %61 to float
  %63 = fpext float %62 to double
  %64 = load i16, ptr %10, align 2
  %65 = sitofp i16 %64 to double
  %66 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, double noundef %60, double noundef %63, double noundef %65)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
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
