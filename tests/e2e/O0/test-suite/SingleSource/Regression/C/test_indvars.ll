; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"Checksum = %.0lf\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [100 x [200 x i32]], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  store i32 0, ptr %1, align 4
  store double 0.000000e+00, ptr %5, align 8
  store i32 0, ptr %3, align 4
  br label %6

6:                                                ; preds = %24, %0
  %7 = load i32, ptr %3, align 4
  %8 = icmp slt i32 %7, 100
  br i1 %8, label %9, label %27

9:                                                ; preds = %6
  store i32 0, ptr %4, align 4
  br label %10

10:                                               ; preds = %20, %9
  %11 = load i32, ptr %4, align 4
  %12 = icmp slt i32 %11, 200
  br i1 %12, label %13, label %23

13:                                               ; preds = %10
  %14 = load i32, ptr %3, align 4
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 %15
  %17 = load i32, ptr %4, align 4
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [200 x i32], ptr %16, i64 0, i64 %18
  store i32 0, ptr %19, align 4
  br label %20

20:                                               ; preds = %13
  %21 = load i32, ptr %4, align 4
  %22 = add nsw i32 %21, 1
  store i32 %22, ptr %4, align 4
  br label %10, !llvm.loop !5

23:                                               ; preds = %10
  br label %24

24:                                               ; preds = %23
  %25 = load i32, ptr %3, align 4
  %26 = add nsw i32 %25, 2
  store i32 %26, ptr %3, align 4
  br label %6, !llvm.loop !7

27:                                               ; preds = %6
  %28 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 0
  %29 = getelementptr inbounds [200 x i32], ptr %28, i64 0, i64 0
  %30 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 0
  call void @test_indvars(ptr noundef %29, ptr noundef %30)
  store i32 0, ptr %3, align 4
  br label %31

31:                                               ; preds = %53, %27
  %32 = load i32, ptr %3, align 4
  %33 = icmp slt i32 %32, 100
  br i1 %33, label %34, label %56

34:                                               ; preds = %31
  store i32 0, ptr %4, align 4
  br label %35

35:                                               ; preds = %49, %34
  %36 = load i32, ptr %4, align 4
  %37 = icmp slt i32 %36, 200
  br i1 %37, label %38, label %52

38:                                               ; preds = %35
  %39 = load i32, ptr %3, align 4
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 %40
  %42 = load i32, ptr %4, align 4
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds [200 x i32], ptr %41, i64 0, i64 %43
  %45 = load i32, ptr %44, align 4
  %46 = sitofp i32 %45 to double
  %47 = load double, ptr %5, align 8
  %48 = fadd double %47, %46
  store double %48, ptr %5, align 8
  br label %49

49:                                               ; preds = %38
  %50 = load i32, ptr %4, align 4
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %4, align 4
  br label %35, !llvm.loop !8

52:                                               ; preds = %35
  br label %53

53:                                               ; preds = %52
  %54 = load i32, ptr %3, align 4
  %55 = add nsw i32 %54, 2
  store i32 %55, ptr %3, align 4
  br label %31, !llvm.loop !9

56:                                               ; preds = %31
  %57 = load double, ptr %5, align 8
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %57)
  ret i32 0
}

; Function Attrs: noinline nounwind uwtable
define internal void @test_indvars(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %7 = load ptr, ptr %4, align 8
  %8 = getelementptr inbounds [200 x i32], ptr %7, i64 3
  %9 = getelementptr inbounds [200 x i32], ptr %8, i64 0, i64 6
  store i32 12345, ptr %9, align 4
  %10 = load ptr, ptr %3, align 8
  %11 = getelementptr inbounds i32, ptr %10, i64 1
  store i32 12345, ptr %11, align 4
  store i32 0, ptr %5, align 4
  br label %12

12:                                               ; preds = %21, %2
  %13 = load i32, ptr %5, align 4
  %14 = icmp ult i32 %13, 100
  br i1 %14, label %15, label %24

15:                                               ; preds = %12
  %16 = load i32, ptr %5, align 4
  %17 = load ptr, ptr %3, align 8
  %18 = load i32, ptr %5, align 4
  %19 = zext i32 %18 to i64
  %20 = getelementptr inbounds nuw i32, ptr %17, i64 %19
  store i32 %16, ptr %20, align 4
  br label %21

21:                                               ; preds = %15
  %22 = load i32, ptr %5, align 4
  %23 = add i32 %22, 2
  store i32 %23, ptr %5, align 4
  br label %12, !llvm.loop !10

24:                                               ; preds = %12
  store i32 3, ptr %5, align 4
  br label %25

25:                                               ; preds = %35, %24
  %26 = load i32, ptr %5, align 4
  %27 = icmp ult i32 %26, 103
  br i1 %27, label %28, label %38

28:                                               ; preds = %25
  %29 = load i32, ptr %5, align 4
  %30 = add i32 %29, 4
  %31 = load ptr, ptr %3, align 8
  %32 = load i32, ptr %5, align 4
  %33 = zext i32 %32 to i64
  %34 = getelementptr inbounds nuw i32, ptr %31, i64 %33
  store i32 %30, ptr %34, align 4
  br label %35

35:                                               ; preds = %28
  %36 = load i32, ptr %5, align 4
  %37 = add i32 %36, 1
  store i32 %37, ptr %5, align 4
  br label %25, !llvm.loop !11

38:                                               ; preds = %25
  store i32 13, ptr %5, align 4
  br label %39

39:                                               ; preds = %67, %38
  %40 = load i32, ptr %5, align 4
  %41 = icmp ult i32 %40, 100
  br i1 %41, label %42, label %70

42:                                               ; preds = %39
  store i32 0, ptr %6, align 4
  br label %43

43:                                               ; preds = %63, %42
  %44 = load i32, ptr %6, align 4
  %45 = icmp ult i32 %44, 100
  br i1 %45, label %46, label %66

46:                                               ; preds = %43
  %47 = load ptr, ptr %4, align 8
  %48 = load i32, ptr %5, align 4
  %49 = zext i32 %48 to i64
  %50 = getelementptr inbounds nuw [200 x i32], ptr %47, i64 %49
  %51 = load i32, ptr %5, align 4
  %52 = zext i32 %51 to i64
  %53 = getelementptr inbounds nuw [200 x i32], ptr %50, i64 0, i64 %52
  %54 = load i32, ptr %53, align 4
  %55 = load ptr, ptr %4, align 8
  %56 = load i32, ptr %5, align 4
  %57 = zext i32 %56 to i64
  %58 = getelementptr inbounds nuw [200 x i32], ptr %55, i64 %57
  %59 = load i32, ptr %6, align 4
  %60 = udiv i32 %59, 3
  %61 = zext i32 %60 to i64
  %62 = getelementptr inbounds nuw [200 x i32], ptr %58, i64 0, i64 %61
  store i32 %54, ptr %62, align 4
  br label %63

63:                                               ; preds = %46
  %64 = load i32, ptr %6, align 4
  %65 = add i32 %64, 3
  store i32 %65, ptr %6, align 4
  br label %43, !llvm.loop !12

66:                                               ; preds = %43
  br label %67

67:                                               ; preds = %66
  %68 = load i32, ptr %5, align 4
  %69 = add i32 %68, 1
  store i32 %69, ptr %5, align 4
  br label %39, !llvm.loop !13

70:                                               ; preds = %39
  ret void
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
!11 = distinct !{!11, !6}
!12 = distinct !{!12, !6}
!13 = distinct !{!13, !6}
