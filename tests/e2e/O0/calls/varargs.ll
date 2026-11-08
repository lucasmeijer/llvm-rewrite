; @source: tests/e2e/src/calls/varargs.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/calls/varargs.c'
source_filename = "tests/e2e/src/calls/varargs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%.3f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i64 (i32, ...) @sum(i32 noundef 10, i32 noundef 1, i32 noundef 2, i32 noundef 3, i32 noundef 4, i32 noundef 5, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, i32 noundef 10)
  %3 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %2)
  %4 = call double (i32, ...) @mixed(i32 noundef 8, i64 noundef 1, double noundef 5.000000e-01, i64 noundef 2, double noundef 2.500000e-01, i64 noundef 3, double noundef 1.250000e-01, i64 noundef 4, double noundef 1.000000e+10)
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %4)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal i64 @sum(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  store i64 0, ptr %4, align 8
  store i32 0, ptr %5, align 4
  br label %7

7:                                                ; preds = %31, %1
  %8 = load i32, ptr %5, align 4
  %9 = load i32, ptr %2, align 4
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %11, label %34

11:                                               ; preds = %7
  %12 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %13 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 0
  %14 = load i32, ptr %13, align 16
  %15 = icmp ule i32 %14, 40
  br i1 %15, label %16, label %21

16:                                               ; preds = %11
  %17 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 3
  %18 = load ptr, ptr %17, align 16
  %19 = getelementptr i8, ptr %18, i32 %14
  %20 = add i32 %14, 8
  store i32 %20, ptr %13, align 16
  br label %25

21:                                               ; preds = %11
  %22 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %12, i32 0, i32 2
  %23 = load ptr, ptr %22, align 8
  %24 = getelementptr i8, ptr %23, i32 8
  store ptr %24, ptr %22, align 8
  br label %25

25:                                               ; preds = %21, %16
  %26 = phi ptr [ %19, %16 ], [ %23, %21 ]
  %27 = load i32, ptr %26, align 4
  %28 = sext i32 %27 to i64
  %29 = load i64, ptr %4, align 8
  %30 = add nsw i64 %29, %28
  store i64 %30, ptr %4, align 8
  br label %31

31:                                               ; preds = %25
  %32 = load i32, ptr %5, align 4
  %33 = add nsw i32 %32, 1
  store i32 %33, ptr %5, align 4
  br label %7, !llvm.loop !5

34:                                               ; preds = %7
  %35 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %35)
  %36 = load i64, ptr %4, align 8
  ret i64 %36
}

; Function Attrs: noinline nounwind uwtable
define internal double @mixed(i32 noundef %0, ...) #0 {
  %2 = alloca i32, align 4
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca double, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %6)
  store double 0.000000e+00, ptr %4, align 8
  store i32 0, ptr %5, align 4
  br label %7

7:                                                ; preds = %55, %1
  %8 = load i32, ptr %5, align 4
  %9 = load i32, ptr %2, align 4
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %11, label %58

11:                                               ; preds = %7
  %12 = load i32, ptr %5, align 4
  %13 = srem i32 %12, 2
  %14 = icmp ne i32 %13, 0
  br i1 %14, label %15, label %34

15:                                               ; preds = %11
  %16 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %17 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %16, i32 0, i32 1
  %18 = load i32, ptr %17, align 4
  %19 = icmp ule i32 %18, 160
  br i1 %19, label %20, label %25

20:                                               ; preds = %15
  %21 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %16, i32 0, i32 3
  %22 = load ptr, ptr %21, align 16
  %23 = getelementptr i8, ptr %22, i32 %18
  %24 = add i32 %18, 16
  store i32 %24, ptr %17, align 4
  br label %29

25:                                               ; preds = %15
  %26 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %16, i32 0, i32 2
  %27 = load ptr, ptr %26, align 8
  %28 = getelementptr i8, ptr %27, i32 8
  store ptr %28, ptr %26, align 8
  br label %29

29:                                               ; preds = %25, %20
  %30 = phi ptr [ %23, %20 ], [ %27, %25 ]
  %31 = load double, ptr %30, align 8
  %32 = load double, ptr %4, align 8
  %33 = fadd double %32, %31
  store double %33, ptr %4, align 8
  br label %54

34:                                               ; preds = %11
  %35 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %36 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %35, i32 0, i32 0
  %37 = load i32, ptr %36, align 16
  %38 = icmp ule i32 %37, 40
  br i1 %38, label %39, label %44

39:                                               ; preds = %34
  %40 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %35, i32 0, i32 3
  %41 = load ptr, ptr %40, align 16
  %42 = getelementptr i8, ptr %41, i32 %37
  %43 = add i32 %37, 8
  store i32 %43, ptr %36, align 16
  br label %48

44:                                               ; preds = %34
  %45 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %35, i32 0, i32 2
  %46 = load ptr, ptr %45, align 8
  %47 = getelementptr i8, ptr %46, i32 8
  store ptr %47, ptr %45, align 8
  br label %48

48:                                               ; preds = %44, %39
  %49 = phi ptr [ %42, %39 ], [ %46, %44 ]
  %50 = load i64, ptr %49, align 8
  %51 = sitofp i64 %50 to double
  %52 = load double, ptr %4, align 8
  %53 = fadd double %52, %51
  store double %53, ptr %4, align 8
  br label %54

54:                                               ; preds = %48, %29
  br label %55

55:                                               ; preds = %54
  %56 = load i32, ptr %5, align 4
  %57 = add nsw i32 %56, 1
  store i32 %57, ptr %5, align 4
  br label %7, !llvm.loop !7

58:                                               ; preds = %7
  %59 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %59)
  %60 = load double, ptr %4, align 8
  ret double %60
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn }

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
