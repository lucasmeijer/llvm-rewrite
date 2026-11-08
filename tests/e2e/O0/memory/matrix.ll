; @source: tests/e2e/src/memory/matrix.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/matrix.c'
source_filename = "tests/e2e/src/memory/matrix.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = internal global [12 x [12 x double]] zeroinitializer, align 16
@b = internal global [12 x [12 x double]] zeroinitializer, align 16
@c = internal global [12 x [12 x double]] zeroinitializer, align 16
@.str = private unnamed_addr constant [11 x i8] c"%.3f %.3f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca double, align 8
  %7 = alloca i32, align 4
  %8 = alloca double, align 8
  %9 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  br label %10

10:                                               ; preds = %44, %0
  %11 = load i32, ptr %2, align 4
  %12 = icmp slt i32 %11, 12
  br i1 %12, label %13, label %47

13:                                               ; preds = %10
  store i32 0, ptr %3, align 4
  br label %14

14:                                               ; preds = %40, %13
  %15 = load i32, ptr %3, align 4
  %16 = icmp slt i32 %15, 12
  br i1 %16, label %17, label %43

17:                                               ; preds = %14
  %18 = load i32, ptr %2, align 4
  %19 = sitofp i32 %18 to double
  %20 = load i32, ptr %3, align 4
  %21 = sitofp i32 %20 to double
  %22 = call double @llvm.fmuladd.f64(double %21, double 5.000000e-01, double %19)
  %23 = load i32, ptr %2, align 4
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds [12 x [12 x double]], ptr @a, i64 0, i64 %24
  %26 = load i32, ptr %3, align 4
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [12 x double], ptr %25, i64 0, i64 %27
  store double %22, ptr %28, align 8
  %29 = load i32, ptr %2, align 4
  %30 = load i32, ptr %3, align 4
  %31 = icmp eq i32 %29, %30
  %32 = zext i1 %31 to i64
  %33 = select i1 %31, double 2.000000e+00, double 2.500000e-01
  %34 = load i32, ptr %2, align 4
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [12 x [12 x double]], ptr @b, i64 0, i64 %35
  %37 = load i32, ptr %3, align 4
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds [12 x double], ptr %36, i64 0, i64 %38
  store double %33, ptr %39, align 8
  br label %40

40:                                               ; preds = %17
  %41 = load i32, ptr %3, align 4
  %42 = add nsw i32 %41, 1
  store i32 %42, ptr %3, align 4
  br label %14, !llvm.loop !5

43:                                               ; preds = %14
  br label %44

44:                                               ; preds = %43
  %45 = load i32, ptr %2, align 4
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %2, align 4
  br label %10, !llvm.loop !7

47:                                               ; preds = %10
  store i32 0, ptr %4, align 4
  br label %48

48:                                               ; preds = %91, %47
  %49 = load i32, ptr %4, align 4
  %50 = icmp slt i32 %49, 12
  br i1 %50, label %51, label %94

51:                                               ; preds = %48
  store i32 0, ptr %5, align 4
  br label %52

52:                                               ; preds = %87, %51
  %53 = load i32, ptr %5, align 4
  %54 = icmp slt i32 %53, 12
  br i1 %54, label %55, label %90

55:                                               ; preds = %52
  store double 0.000000e+00, ptr %6, align 8
  store i32 0, ptr %7, align 4
  br label %56

56:                                               ; preds = %76, %55
  %57 = load i32, ptr %7, align 4
  %58 = icmp slt i32 %57, 12
  br i1 %58, label %59, label %79

59:                                               ; preds = %56
  %60 = load i32, ptr %4, align 4
  %61 = sext i32 %60 to i64
  %62 = getelementptr inbounds [12 x [12 x double]], ptr @a, i64 0, i64 %61
  %63 = load i32, ptr %7, align 4
  %64 = sext i32 %63 to i64
  %65 = getelementptr inbounds [12 x double], ptr %62, i64 0, i64 %64
  %66 = load double, ptr %65, align 8
  %67 = load i32, ptr %7, align 4
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds [12 x [12 x double]], ptr @b, i64 0, i64 %68
  %70 = load i32, ptr %5, align 4
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds [12 x double], ptr %69, i64 0, i64 %71
  %73 = load double, ptr %72, align 8
  %74 = load double, ptr %6, align 8
  %75 = call double @llvm.fmuladd.f64(double %66, double %73, double %74)
  store double %75, ptr %6, align 8
  br label %76

76:                                               ; preds = %59
  %77 = load i32, ptr %7, align 4
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %7, align 4
  br label %56, !llvm.loop !8

79:                                               ; preds = %56
  %80 = load double, ptr %6, align 8
  %81 = load i32, ptr %4, align 4
  %82 = sext i32 %81 to i64
  %83 = getelementptr inbounds [12 x [12 x double]], ptr @c, i64 0, i64 %82
  %84 = load i32, ptr %5, align 4
  %85 = sext i32 %84 to i64
  %86 = getelementptr inbounds [12 x double], ptr %83, i64 0, i64 %85
  store double %80, ptr %86, align 8
  br label %87

87:                                               ; preds = %79
  %88 = load i32, ptr %5, align 4
  %89 = add nsw i32 %88, 1
  store i32 %89, ptr %5, align 4
  br label %52, !llvm.loop !9

90:                                               ; preds = %52
  br label %91

91:                                               ; preds = %90
  %92 = load i32, ptr %4, align 4
  %93 = add nsw i32 %92, 1
  store i32 %93, ptr %4, align 4
  br label %48, !llvm.loop !10

94:                                               ; preds = %48
  store double 0.000000e+00, ptr %8, align 8
  store i32 0, ptr %9, align 4
  br label %95

95:                                               ; preds = %108, %94
  %96 = load i32, ptr %9, align 4
  %97 = icmp slt i32 %96, 12
  br i1 %97, label %98, label %111

98:                                               ; preds = %95
  %99 = load i32, ptr %9, align 4
  %100 = sext i32 %99 to i64
  %101 = getelementptr inbounds [12 x [12 x double]], ptr @c, i64 0, i64 %100
  %102 = load i32, ptr %9, align 4
  %103 = sext i32 %102 to i64
  %104 = getelementptr inbounds [12 x double], ptr %101, i64 0, i64 %103
  %105 = load double, ptr %104, align 8
  %106 = load double, ptr %8, align 8
  %107 = fadd double %106, %105
  store double %107, ptr %8, align 8
  br label %108

108:                                              ; preds = %98
  %109 = load i32, ptr %9, align 4
  %110 = add nsw i32 %109, 1
  store i32 %110, ptr %9, align 4
  br label %95, !llvm.loop !11

111:                                              ; preds = %95
  %112 = load double, ptr %8, align 8
  %113 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 344), align 8
  %114 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %112, double noundef %113)
  ret i32 0
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

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
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !6}
!11 = distinct !{!11, !6}
