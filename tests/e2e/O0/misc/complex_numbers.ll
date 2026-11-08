; @source: tests/e2e/src/misc/complex_numbers.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/complex_numbers.c'
source_filename = "tests/e2e/src/misc/complex_numbers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"%.6f %.6f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca { double, double }, align 8
  %3 = alloca { double, double }, align 8
  %4 = alloca { double, double }, align 8
  %5 = alloca { double, double }, align 8
  %6 = alloca { float, float }, align 4
  %7 = alloca i32, align 4
  %8 = alloca { float, float }, align 4
  store i32 0, ptr %1, align 4
  %9 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %10 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  store double 1.000000e+00, ptr %9, align 8
  store double 2.000000e+00, ptr %10, align 8
  %11 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %12 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double 3.000000e+00, ptr %11, align 8
  store double -1.000000e+00, ptr %12, align 8
  %13 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %14 = load double, ptr %13, align 8
  %15 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  %16 = load double, ptr %15, align 8
  %17 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %18 = load double, ptr %17, align 8
  %19 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %20 = load double, ptr %19, align 8
  %21 = fmul double %14, %18
  %22 = fmul double %16, %20
  %23 = fmul double %14, %20
  %24 = fmul double %16, %18
  %25 = fsub double %21, %22
  %26 = fadd double %23, %24
  %27 = fcmp uno double %25, %25
  br i1 %27, label %28, label %34, !prof !5

28:                                               ; preds = %0
  %29 = fcmp uno double %26, %26
  br i1 %29, label %30, label %34, !prof !5

30:                                               ; preds = %28
  %31 = call { double, double } @__muldc3(double noundef %14, double noundef %16, double noundef %18, double noundef %20) #2
  %32 = extractvalue { double, double } %31, 0
  %33 = extractvalue { double, double } %31, 1
  br label %34

34:                                               ; preds = %30, %28, %0
  %35 = phi double [ %25, %0 ], [ %25, %28 ], [ %32, %30 ]
  %36 = phi double [ %26, %0 ], [ %26, %28 ], [ %33, %30 ]
  %37 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %38 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  store double %35, ptr %37, align 8
  store double %36, ptr %38, align 8
  %39 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %40 = load double, ptr %39, align 8
  %41 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  %42 = load double, ptr %41, align 8
  %43 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %44 = load double, ptr %43, align 8
  %45 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %46 = load double, ptr %45, align 8
  %47 = call { double, double } @__divdc3(double noundef %40, double noundef %42, double noundef %44, double noundef %46) #2
  %48 = extractvalue { double, double } %47, 0
  %49 = extractvalue { double, double } %47, 1
  %50 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %51 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  store double %48, ptr %50, align 8
  store double %49, ptr %51, align 8
  %52 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %53 = load double, ptr %52, align 8
  %54 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %55 = load double, ptr %54, align 8
  %56 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 0
  %57 = load double, ptr %56, align 8
  %58 = getelementptr inbounds nuw { double, double }, ptr %4, i32 0, i32 1
  %59 = load double, ptr %58, align 8
  %60 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %61 = load double, ptr %60, align 8
  %62 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  %63 = load double, ptr %62, align 8
  %64 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  %65 = load double, ptr %64, align 8
  %66 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  %67 = load double, ptr %66, align 8
  %68 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %53, double noundef %59, double noundef %61, double noundef %67)
  %69 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %70 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  store float 5.000000e-01, ptr %69, align 4
  store float 5.000000e-01, ptr %70, align 4
  store i32 0, ptr %7, align 4
  br label %71

71:                                               ; preds = %105, %34
  %72 = load i32, ptr %7, align 4
  %73 = icmp slt i32 %72, 5
  br i1 %73, label %74, label %108

74:                                               ; preds = %71
  %75 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %76 = load float, ptr %75, align 4
  %77 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %78 = load float, ptr %77, align 4
  %79 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %80 = load float, ptr %79, align 4
  %81 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %82 = load float, ptr %81, align 4
  %83 = fmul float %76, %80
  %84 = fmul float %78, %82
  %85 = fmul float %76, %82
  %86 = fmul float %78, %80
  %87 = fsub float %83, %84
  %88 = fadd float %85, %86
  %89 = fcmp uno float %87, %87
  br i1 %89, label %90, label %98, !prof !5

90:                                               ; preds = %74
  %91 = fcmp uno float %88, %88
  br i1 %91, label %92, label %98, !prof !5

92:                                               ; preds = %90
  %93 = call <2 x float> @__mulsc3(float noundef %76, float noundef %78, float noundef %80, float noundef %82) #2
  store <2 x float> %93, ptr %8, align 4
  %94 = getelementptr inbounds nuw { float, float }, ptr %8, i32 0, i32 0
  %95 = load float, ptr %94, align 4
  %96 = getelementptr inbounds nuw { float, float }, ptr %8, i32 0, i32 1
  %97 = load float, ptr %96, align 4
  br label %98

98:                                               ; preds = %92, %90, %74
  %99 = phi float [ %87, %74 ], [ %87, %90 ], [ %95, %92 ]
  %100 = phi float [ %88, %74 ], [ %88, %90 ], [ %97, %92 ]
  %101 = fadd float %99, 1.000000e-01
  %102 = fadd float %100, 2.000000e-01
  %103 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %104 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  store float %101, ptr %103, align 4
  store float %102, ptr %104, align 4
  br label %105

105:                                              ; preds = %98
  %106 = load i32, ptr %7, align 4
  %107 = add nsw i32 %106, 1
  store i32 %107, ptr %7, align 4
  br label %71, !llvm.loop !6

108:                                              ; preds = %71
  %109 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %110 = load float, ptr %109, align 4
  %111 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %112 = load float, ptr %111, align 4
  %113 = fpext float %110 to double
  %114 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %115 = load float, ptr %114, align 4
  %116 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %117 = load float, ptr %116, align 4
  %118 = fpext float %117 to double
  %119 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %113, double noundef %118)
  ret i32 0
}

declare { double, double } @__muldc3(double, double, double, double)

declare { double, double } @__divdc3(double, double, double, double)

declare i32 @printf(ptr noundef, ...) #1

declare <2 x float> @__mulsc3(float, float, float, float)

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
