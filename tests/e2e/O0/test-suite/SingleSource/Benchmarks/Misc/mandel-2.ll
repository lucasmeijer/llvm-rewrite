; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel-2.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel-2.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel-2.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@max_i = dso_local global i32 65536, align 4
@.str = private unnamed_addr constant [2 x i8] c"*\00", align 1
@.str.1 = private unnamed_addr constant [2 x i8] c" \00", align 1
@.str.2 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local double @sqr(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = load double, ptr %2, align 8
  %5 = fmul double %3, %4
  ret double %5
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @cnorm2(double noundef %0, double noundef %1) #0 {
  %3 = alloca { double, double }, align 8
  %4 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %9 = load double, ptr %8, align 8
  %10 = call double @sqr(double noundef %7)
  %11 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %12 = load double, ptr %11, align 8
  %13 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %14 = load double, ptr %13, align 8
  %15 = call double @sqr(double noundef %14)
  %16 = fadd double %10, %15
  ret double %16
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @loop(double noundef %0, double noundef %1) #0 {
  %3 = alloca { double, double }, align 8
  %4 = alloca { double, double }, align 8
  %5 = alloca i32, align 4
  %6 = alloca { double, double }, align 8
  %7 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  store double %0, ptr %7, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %8, align 8
  %9 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %10 = load double, ptr %9, align 8
  %11 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %12 = load double, ptr %11, align 8
  %13 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %14 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  store double %10, ptr %13, align 8
  store double %12, ptr %14, align 8
  store i32 1, ptr %5, align 4
  br label %15

15:                                               ; preds = %57, %2
  %16 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %17 = load double, ptr %16, align 8
  %18 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %19 = load double, ptr %18, align 8
  %20 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  %21 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  store double %17, ptr %20, align 8
  store double %19, ptr %21, align 8
  %22 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  %23 = load double, ptr %22, align 8
  %24 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  %25 = load double, ptr %24, align 8
  %26 = call double @cnorm2(double noundef %23, double noundef %25)
  %27 = fcmp ole double %26, 4.000000e+00
  br i1 %27, label %28, label %33

28:                                               ; preds = %15
  %29 = load i32, ptr %5, align 4
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %5, align 4
  %31 = load i32, ptr @max_i, align 4
  %32 = icmp slt i32 %29, %31
  br label %33

33:                                               ; preds = %28, %15
  %34 = phi i1 [ false, %15 ], [ %32, %28 ]
  br i1 %34, label %35, label %68

35:                                               ; preds = %33
  %36 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %37 = load double, ptr %36, align 8
  %38 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %39 = load double, ptr %38, align 8
  %40 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %41 = load double, ptr %40, align 8
  %42 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %43 = load double, ptr %42, align 8
  %44 = fmul double %37, %41
  %45 = fmul double %39, %43
  %46 = fmul double %37, %43
  %47 = fmul double %39, %41
  %48 = fsub double %44, %45
  %49 = fadd double %46, %47
  %50 = fcmp uno double %48, %48
  br i1 %50, label %51, label %57, !prof !5

51:                                               ; preds = %35
  %52 = fcmp uno double %49, %49
  br i1 %52, label %53, label %57, !prof !5

53:                                               ; preds = %51
  %54 = call { double, double } @__muldc3(double noundef %37, double noundef %39, double noundef %41, double noundef %43) #2
  %55 = extractvalue { double, double } %54, 0
  %56 = extractvalue { double, double } %54, 1
  br label %57

57:                                               ; preds = %53, %51, %35
  %58 = phi double [ %48, %35 ], [ %48, %51 ], [ %55, %53 ]
  %59 = phi double [ %49, %35 ], [ %49, %51 ], [ %56, %53 ]
  %60 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %61 = load double, ptr %60, align 8
  %62 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %63 = load double, ptr %62, align 8
  %64 = fadd double %58, %61
  %65 = fadd double %59, %63
  %66 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %67 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  store double %64, ptr %66, align 8
  store double %65, ptr %67, align 8
  br label %15, !llvm.loop !6

68:                                               ; preds = %33
  %69 = load i32, ptr %5, align 4
  ret i32 %69
}

declare { double, double } @__muldc3(double, double, double, double)

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca { double, double }, align 8
  store i32 0, ptr %1, align 4
  store i32 -39, ptr %3, align 4
  br label %5

5:                                                ; preds = %40, %0
  %6 = load i32, ptr %3, align 4
  %7 = icmp slt i32 %6, 39
  br i1 %7, label %8, label %43

8:                                                ; preds = %5
  store i32 -39, ptr %2, align 4
  br label %9

9:                                                ; preds = %35, %8
  %10 = load i32, ptr %2, align 4
  %11 = icmp slt i32 %10, 39
  br i1 %11, label %12, label %38

12:                                               ; preds = %9
  %13 = load i32, ptr %3, align 4
  %14 = sitofp i32 %13 to double
  %15 = fdiv double %14, 4.000000e+01
  %16 = fsub double %15, 5.000000e-01
  %17 = load i32, ptr %2, align 4
  %18 = sitofp i32 %17 to double
  %19 = fdiv double %18, 4.000000e+01
  %20 = fmul double %19, 0.000000e+00
  %21 = fmul double %19, 1.000000e+00
  %22 = fadd double %16, %20
  %23 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %24 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  store double %22, ptr %23, align 8
  store double %21, ptr %24, align 8
  %25 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %26 = load double, ptr %25, align 8
  %27 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %28 = load double, ptr %27, align 8
  %29 = call i32 @loop(double noundef %26, double noundef %28)
  %30 = load i32, ptr @max_i, align 4
  %31 = icmp sgt i32 %29, %30
  %32 = zext i1 %31 to i64
  %33 = select i1 %31, ptr @.str, ptr @.str.1
  %34 = call i32 (ptr, ...) @printf(ptr noundef %33)
  br label %35

35:                                               ; preds = %12
  %36 = load i32, ptr %2, align 4
  %37 = add nsw i32 %36, 1
  store i32 %37, ptr %2, align 4
  br label %9, !llvm.loop !8

38:                                               ; preds = %9
  %39 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  br label %40

40:                                               ; preds = %38
  %41 = load i32, ptr %3, align 4
  %42 = add nsw i32 %41, 1
  store i32 %42, ptr %3, align 4
  br label %5, !llvm.loop !9

43:                                               ; preds = %5
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = !{!"branch_weights", i32 1, i32 1048575}
!6 = distinct !{!6, !7}
!7 = !{!"llvm.loop.mustprogress"}
!8 = distinct !{!8, !7}
!9 = distinct !{!9, !7}
