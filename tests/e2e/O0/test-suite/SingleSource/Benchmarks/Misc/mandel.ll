; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/mandel.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@accum = dso_local global { double, double } zeroinitializer, align 8
@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @emit(double noundef %0, double noundef %1) #0 {
  %3 = alloca { double, double }, align 8
  %4 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  store double %0, ptr %4, align 8
  %5 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double %1, ptr %5, align 8
  %6 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %7 = load double, ptr %6, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %9 = load double, ptr %8, align 8
  %10 = load volatile double, ptr @accum, align 8
  %11 = load volatile double, ptr getelementptr inbounds nuw (i8, ptr @accum, i64 8), align 8
  %12 = fadd double %10, %7
  %13 = fadd double %11, %9
  store volatile double %12, ptr @accum, align 8
  store volatile double %13, ptr getelementptr inbounds nuw (i8, ptr @accum, i64 8), align 8
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @mandel() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca { double, double }, align 8
  %5 = alloca { double, double }, align 8
  %6 = alloca { double, double }, align 8
  store i32 0, ptr %1, align 4
  br label %7

7:                                                ; preds = %94, %0
  %8 = load i32, ptr %1, align 4
  %9 = icmp slt i32 %8, 5000
  br i1 %9, label %10, label %97

10:                                               ; preds = %7
  store i32 0, ptr %2, align 4
  br label %11

11:                                               ; preds = %90, %10
  %12 = load i32, ptr %2, align 4
  %13 = icmp slt i32 %12, 5000
  br i1 %13, label %14, label %93

14:                                               ; preds = %11
  %15 = load i32, ptr %1, align 4
  %16 = sitofp i32 %15 to double
  %17 = fmul double %16, 4.000000e+00
  %18 = fdiv double %17, 5.000000e+03
  %19 = fadd double -2.000000e+00, %18
  %20 = load i32, ptr %2, align 4
  %21 = sitofp i32 %20 to double
  %22 = fmul double %21, 4.000000e+00
  %23 = fdiv double %22, 5.000000e+03
  %24 = fsub double -2.000000e+00, %23
  %25 = fmul double %24, 0.000000e+00
  %26 = fmul double %24, 1.000000e+00
  %27 = fadd double %19, %25
  %28 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %29 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  store double %27, ptr %28, align 8
  store double %26, ptr %29, align 8
  %30 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %31 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  store double 0.000000e+00, ptr %30, align 8
  store double 0.000000e+00, ptr %31, align 8
  store i32 0, ptr %3, align 4
  br label %32

32:                                               ; preds = %76, %14
  %33 = load i32, ptr %3, align 4
  %34 = icmp slt i32 %33, 10
  br i1 %34, label %35, label %79

35:                                               ; preds = %32
  %36 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %37 = load double, ptr %36, align 8
  %38 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  %39 = load double, ptr %38, align 8
  %40 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %41 = load double, ptr %40, align 8
  %42 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
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
  %54 = call { double, double } @__muldc3(double noundef %37, double noundef %39, double noundef %41, double noundef %43) #3
  %55 = extractvalue { double, double } %54, 0
  %56 = extractvalue { double, double } %54, 1
  br label %57

57:                                               ; preds = %53, %51, %35
  %58 = phi double [ %48, %35 ], [ %48, %51 ], [ %55, %53 ]
  %59 = phi double [ %49, %35 ], [ %49, %51 ], [ %56, %53 ]
  %60 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %61 = load double, ptr %60, align 8
  %62 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %63 = load double, ptr %62, align 8
  %64 = fadd double %58, %61
  %65 = fadd double %59, %63
  %66 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %67 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  store double %64, ptr %66, align 8
  store double %65, ptr %67, align 8
  %68 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %69 = load double, ptr %68, align 8
  %70 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  %71 = load double, ptr %70, align 8
  %72 = call double @hypot(double noundef %69, double noundef %71) #3
  %73 = fcmp oge double %72, 2.000000e+00
  br i1 %73, label %74, label %75

74:                                               ; preds = %57
  br label %79

75:                                               ; preds = %57
  br label %76

76:                                               ; preds = %75
  %77 = load i32, ptr %3, align 4
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %3, align 4
  br label %32, !llvm.loop !6

79:                                               ; preds = %74, %32
  %80 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %81 = load double, ptr %80, align 8
  %82 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  %83 = load double, ptr %82, align 8
  %84 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  %85 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  store double %81, ptr %84, align 8
  store double %83, ptr %85, align 8
  %86 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  %87 = load double, ptr %86, align 8
  %88 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  %89 = load double, ptr %88, align 8
  call void @emit(double noundef %87, double noundef %89)
  br label %90

90:                                               ; preds = %79
  %91 = load i32, ptr %2, align 4
  %92 = add nsw i32 %91, 1
  store i32 %92, ptr %2, align 4
  br label %11, !llvm.loop !8

93:                                               ; preds = %11
  br label %94

94:                                               ; preds = %93
  %95 = load i32, ptr %1, align 4
  %96 = add nsw i32 %95, 1
  store i32 %96, ptr %1, align 4
  br label %7, !llvm.loop !9

97:                                               ; preds = %7
  ret void
}

declare { double, double } @__muldc3(double, double, double, double)

; Function Attrs: nounwind
declare double @hypot(double noundef, double noundef) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @mandel()
  %2 = load volatile double, ptr @accum, align 8
  %3 = load volatile double, ptr getelementptr inbounds nuw (i8, ptr @accum, i64 8), align 8
  %4 = fptosi double %2 to i32
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
