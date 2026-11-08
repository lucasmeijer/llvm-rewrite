; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/sumarray2d.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [23 x i8] c"Sum(Array[%d,%d] = %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @SumArray(ptr noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store ptr %0, ptr %4, align 8
  store i32 %1, ptr %5, align 4
  store i32 %2, ptr %6, align 4
  store i32 0, ptr %9, align 4
  store i32 0, ptr %7, align 4
  br label %10

10:                                               ; preds = %34, %3
  %11 = load i32, ptr %7, align 4
  %12 = load i32, ptr %5, align 4
  %13 = icmp ult i32 %11, %12
  br i1 %13, label %14, label %37

14:                                               ; preds = %10
  store i32 0, ptr %8, align 4
  br label %15

15:                                               ; preds = %30, %14
  %16 = load i32, ptr %8, align 4
  %17 = load i32, ptr %6, align 4
  %18 = icmp ult i32 %16, %17
  br i1 %18, label %19, label %33

19:                                               ; preds = %15
  %20 = load ptr, ptr %4, align 8
  %21 = load i32, ptr %7, align 4
  %22 = zext i32 %21 to i64
  %23 = getelementptr inbounds nuw [100 x i32], ptr %20, i64 %22
  %24 = load i32, ptr %8, align 4
  %25 = zext i32 %24 to i64
  %26 = getelementptr inbounds nuw [100 x i32], ptr %23, i64 0, i64 %25
  %27 = load i32, ptr %26, align 4
  %28 = load i32, ptr %9, align 4
  %29 = add nsw i32 %28, %27
  store i32 %29, ptr %9, align 4
  br label %30

30:                                               ; preds = %19
  %31 = load i32, ptr %8, align 4
  %32 = add i32 %31, 1
  store i32 %32, ptr %8, align 4
  br label %15, !llvm.loop !5

33:                                               ; preds = %15
  br label %34

34:                                               ; preds = %33
  %35 = load i32, ptr %7, align 4
  %36 = add i32 %35, 1
  store i32 %36, ptr %7, align 4
  br label %10, !llvm.loop !7

37:                                               ; preds = %10
  %38 = load i32, ptr %9, align 4
  ret i32 %38
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [100 x [100 x i32]], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %3, align 4
  br label %5

5:                                                ; preds = %17, %0
  %6 = load i32, ptr %3, align 4
  %7 = icmp ult i32 %6, 100
  br i1 %7, label %8, label %20

8:                                                ; preds = %5
  %9 = load i32, ptr %3, align 4
  %10 = sub i32 0, %9
  %11 = load i32, ptr %3, align 4
  %12 = zext i32 %11 to i64
  %13 = getelementptr inbounds nuw [100 x [100 x i32]], ptr %2, i64 0, i64 %12
  %14 = load i32, ptr %3, align 4
  %15 = zext i32 %14 to i64
  %16 = getelementptr inbounds nuw [100 x i32], ptr %13, i64 0, i64 %15
  store i32 %10, ptr %16, align 4
  br label %17

17:                                               ; preds = %8
  %18 = load i32, ptr %3, align 4
  %19 = add i32 %18, 1
  store i32 %19, ptr %3, align 4
  br label %5, !llvm.loop !8

20:                                               ; preds = %5
  store i32 0, ptr %3, align 4
  br label %21

21:                                               ; preds = %47, %20
  %22 = load i32, ptr %3, align 4
  %23 = icmp ult i32 %22, 100
  br i1 %23, label %24, label %50

24:                                               ; preds = %21
  store i32 0, ptr %4, align 4
  br label %25

25:                                               ; preds = %43, %24
  %26 = load i32, ptr %4, align 4
  %27 = icmp ult i32 %26, 100
  br i1 %27, label %28, label %46

28:                                               ; preds = %25
  %29 = load i32, ptr %4, align 4
  %30 = load i32, ptr %3, align 4
  %31 = icmp ne i32 %29, %30
  br i1 %31, label %32, label %42

32:                                               ; preds = %28
  %33 = load i32, ptr %3, align 4
  %34 = load i32, ptr %4, align 4
  %35 = add i32 %33, %34
  %36 = load i32, ptr %3, align 4
  %37 = zext i32 %36 to i64
  %38 = getelementptr inbounds nuw [100 x [100 x i32]], ptr %2, i64 0, i64 %37
  %39 = load i32, ptr %4, align 4
  %40 = zext i32 %39 to i64
  %41 = getelementptr inbounds nuw [100 x i32], ptr %38, i64 0, i64 %40
  store i32 %35, ptr %41, align 4
  br label %42

42:                                               ; preds = %32, %28
  br label %43

43:                                               ; preds = %42
  %44 = load i32, ptr %4, align 4
  %45 = add i32 %44, 1
  store i32 %45, ptr %4, align 4
  br label %25, !llvm.loop !9

46:                                               ; preds = %25
  br label %47

47:                                               ; preds = %46
  %48 = load i32, ptr %3, align 4
  %49 = add i32 %48, 1
  store i32 %49, ptr %3, align 4
  br label %21, !llvm.loop !10

50:                                               ; preds = %21
  %51 = getelementptr inbounds [100 x [100 x i32]], ptr %2, i64 0, i64 0
  %52 = call i32 @SumArray(ptr noundef %51, i32 noundef 100, i32 noundef 100)
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef 100, i32 noundef 100, i32 noundef %52)
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
!8 = distinct !{!8, !6}
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !6}
