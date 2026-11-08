; @source: tests/function/src/abi/varargs_callee.c
; @llc: -O0
; @driver: tests/function/src/abi/varargs_callee.driver.c
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/varargs_callee.c'
source_filename = "tests/function/src/abi/varargs_callee.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

; Function Attrs: noinline nounwind uwtable
define dso_local double @vsum(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  store double 0.000000e+00, ptr %4, align 8
  %7 = load ptr, ptr %2, align 8
  store ptr %7, ptr %5, align 8
  br label %8

8:                                                ; preds = %97, %1
  %9 = load ptr, ptr %5, align 8
  %10 = load i8, ptr %9, align 1
  %11 = icmp ne i8 %10, 0
  br i1 %11, label %12, label %100

12:                                               ; preds = %8
  %13 = load ptr, ptr %5, align 8
  %14 = load i8, ptr %13, align 1
  %15 = sext i8 %14 to i32
  switch i32 %15, label %96 [
    i32 105, label %16
    i32 108, label %36
    i32 100, label %56
    i32 112, label %75
  ]

16:                                               ; preds = %12
  %17 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %18 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 0
  %19 = load i32, ptr %18, align 16
  %20 = icmp ule i32 %19, 40
  br i1 %20, label %21, label %26

21:                                               ; preds = %16
  %22 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 3
  %23 = load ptr, ptr %22, align 16
  %24 = getelementptr i8, ptr %23, i32 %19
  %25 = add i32 %19, 8
  store i32 %25, ptr %18, align 16
  br label %30

26:                                               ; preds = %16
  %27 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %17, i32 0, i32 2
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr i8, ptr %28, i32 8
  store ptr %29, ptr %27, align 8
  br label %30

30:                                               ; preds = %26, %21
  %31 = phi ptr [ %24, %21 ], [ %28, %26 ]
  %32 = load i32, ptr %31, align 4
  %33 = sitofp i32 %32 to double
  %34 = load double, ptr %4, align 8
  %35 = fadd double %34, %33
  store double %35, ptr %4, align 8
  br label %96

36:                                               ; preds = %12
  %37 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %38 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %37, i32 0, i32 0
  %39 = load i32, ptr %38, align 16
  %40 = icmp ule i32 %39, 40
  br i1 %40, label %41, label %46

41:                                               ; preds = %36
  %42 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %37, i32 0, i32 3
  %43 = load ptr, ptr %42, align 16
  %44 = getelementptr i8, ptr %43, i32 %39
  %45 = add i32 %39, 8
  store i32 %45, ptr %38, align 16
  br label %50

46:                                               ; preds = %36
  %47 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %37, i32 0, i32 2
  %48 = load ptr, ptr %47, align 8
  %49 = getelementptr i8, ptr %48, i32 8
  store ptr %49, ptr %47, align 8
  br label %50

50:                                               ; preds = %46, %41
  %51 = phi ptr [ %44, %41 ], [ %48, %46 ]
  %52 = load i64, ptr %51, align 8
  %53 = sitofp i64 %52 to double
  %54 = load double, ptr %4, align 8
  %55 = fadd double %54, %53
  store double %55, ptr %4, align 8
  br label %96

56:                                               ; preds = %12
  %57 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %58 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 1
  %59 = load i32, ptr %58, align 4
  %60 = icmp ule i32 %59, 160
  br i1 %60, label %61, label %66

61:                                               ; preds = %56
  %62 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 3
  %63 = load ptr, ptr %62, align 16
  %64 = getelementptr i8, ptr %63, i32 %59
  %65 = add i32 %59, 16
  store i32 %65, ptr %58, align 4
  br label %70

66:                                               ; preds = %56
  %67 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 2
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr i8, ptr %68, i32 8
  store ptr %69, ptr %67, align 8
  br label %70

70:                                               ; preds = %66, %61
  %71 = phi ptr [ %64, %61 ], [ %68, %66 ]
  %72 = load double, ptr %71, align 8
  %73 = load double, ptr %4, align 8
  %74 = fadd double %73, %72
  store double %74, ptr %4, align 8
  br label %96

75:                                               ; preds = %12
  %76 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %77 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %76, i32 0, i32 0
  %78 = load i32, ptr %77, align 16
  %79 = icmp ule i32 %78, 40
  br i1 %79, label %80, label %85

80:                                               ; preds = %75
  %81 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %76, i32 0, i32 3
  %82 = load ptr, ptr %81, align 16
  %83 = getelementptr i8, ptr %82, i32 %78
  %84 = add i32 %78, 8
  store i32 %84, ptr %77, align 16
  br label %89

85:                                               ; preds = %75
  %86 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %76, i32 0, i32 2
  %87 = load ptr, ptr %86, align 8
  %88 = getelementptr i8, ptr %87, i32 8
  store ptr %88, ptr %86, align 8
  br label %89

89:                                               ; preds = %85, %80
  %90 = phi ptr [ %83, %80 ], [ %87, %85 ]
  %91 = load ptr, ptr %90, align 8
  %92 = load i32, ptr %91, align 4
  %93 = sitofp i32 %92 to double
  %94 = load double, ptr %4, align 8
  %95 = fadd double %94, %93
  store double %95, ptr %4, align 8
  br label %96

96:                                               ; preds = %12, %89, %70, %50, %30
  br label %97

97:                                               ; preds = %96
  %98 = load ptr, ptr %5, align 8
  %99 = getelementptr inbounds nuw i8, ptr %98, i32 1
  store ptr %99, ptr %5, align 8
  br label %8, !llvm.loop !5

100:                                              ; preds = %8
  %101 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %101)
  %102 = load double, ptr %4, align 8
  ret double %102
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #1

; Function Attrs: noinline nounwind uwtable
define dso_local double @vforward(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  store i32 %0, ptr %2, align 4
  %5 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %5)
  %6 = load i32, ptr %2, align 4
  %7 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %8 = call double @vinner(i32 noundef %6, ptr noundef %7)
  store double %8, ptr %4, align 8
  %9 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %9)
  %10 = load double, ptr %4, align 8
  ret double %10
}

; Function Attrs: noinline nounwind uwtable
define internal double @vinner(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4
  store ptr %1, ptr %4, align 8
  store double 0.000000e+00, ptr %5, align 8
  store i32 0, ptr %6, align 4
  br label %7

7:                                                ; preds = %33, %2
  %8 = load i32, ptr %6, align 4
  %9 = load i32, ptr %3, align 4
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %11, label %36

11:                                               ; preds = %7
  %12 = load ptr, ptr %4, align 8
  %13 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 1
  %14 = load i32, ptr %13, align 4
  %15 = icmp ule i32 %14, 160
  br i1 %15, label %16, label %21

16:                                               ; preds = %11
  %17 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 3
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr i8, ptr %18, i32 %14
  %20 = add i32 %14, 16
  store i32 %20, ptr %13, align 4
  br label %25

21:                                               ; preds = %11
  %22 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 2
  %23 = load ptr, ptr %22, align 8
  %24 = getelementptr i8, ptr %23, i32 8
  store ptr %24, ptr %22, align 8
  br label %25

25:                                               ; preds = %21, %16
  %26 = phi ptr [ %19, %16 ], [ %23, %21 ]
  %27 = load double, ptr %26, align 8
  %28 = load i32, ptr %6, align 4
  %29 = add nsw i32 %28, 1
  %30 = sitofp i32 %29 to double
  %31 = load double, ptr %5, align 8
  %32 = call double @llvm.fmuladd.f64(double %27, double %30, double %31)
  store double %32, ptr %5, align 8
  br label %33

33:                                               ; preds = %25
  %34 = load i32, ptr %6, align 4
  %35 = add nsw i32 %34, 1
  store i32 %35, ptr %6, align 4
  br label %7, !llvm.loop !7

36:                                               ; preds = %7
  %37 = load double, ptr %5, align 8
  ret double %37
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
