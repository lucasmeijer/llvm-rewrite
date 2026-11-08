; @source: tests/e2e/src/misc/complex_numbers.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/complex_numbers.c'
source_filename = "tests/e2e/src/misc/complex_numbers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [21 x i8] c"%.6f %.6f %.6f %.6f\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"%.6f %.6f\0A\00", align 1

; Function Attrs: nounwind uwtable
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
  call void @llvm.lifetime.start.p0(ptr %2) #3
  %9 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %10 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  store double 1.000000e+00, ptr %9, align 8
  store double 2.000000e+00, ptr %10, align 8
  call void @llvm.lifetime.start.p0(ptr %3) #3
  %11 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %12 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  store double 3.000000e+00, ptr %11, align 8
  store double -1.000000e+00, ptr %12, align 8
  call void @llvm.lifetime.start.p0(ptr %4) #3
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
  br i1 %27, label %28, label %34, !prof !9

28:                                               ; preds = %0
  %29 = fcmp uno double %26, %26
  br i1 %29, label %30, label %34, !prof !9

30:                                               ; preds = %28
  %31 = call { double, double } @__muldc3(double noundef %14, double noundef %16, double noundef %18, double noundef %20) #3
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
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %39 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %40 = load double, ptr %39, align 8
  %41 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  %42 = load double, ptr %41, align 8
  %43 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %44 = load double, ptr %43, align 8
  %45 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %46 = load double, ptr %45, align 8
  %47 = call { double, double } @__divdc3(double noundef %40, double noundef %42, double noundef %44, double noundef %46) #3
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
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %69 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %70 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  store float 5.000000e-01, ptr %69, align 4
  store float 5.000000e-01, ptr %70, align 4
  call void @llvm.lifetime.start.p0(ptr %7) #3
  store i32 0, ptr %7, align 4, !tbaa !10
  br label %71

71:                                               ; preds = %106, %34
  %72 = load i32, ptr %7, align 4, !tbaa !10
  %73 = icmp slt i32 %72, 5
  br i1 %73, label %75, label %74

74:                                               ; preds = %71
  call void @llvm.lifetime.end.p0(ptr %7) #3
  br label %109

75:                                               ; preds = %71
  %76 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %77 = load float, ptr %76, align 4
  %78 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %79 = load float, ptr %78, align 4
  %80 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %81 = load float, ptr %80, align 4
  %82 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %83 = load float, ptr %82, align 4
  %84 = fmul float %77, %81
  %85 = fmul float %79, %83
  %86 = fmul float %77, %83
  %87 = fmul float %79, %81
  %88 = fsub float %84, %85
  %89 = fadd float %86, %87
  %90 = fcmp uno float %88, %88
  br i1 %90, label %91, label %99, !prof !9

91:                                               ; preds = %75
  %92 = fcmp uno float %89, %89
  br i1 %92, label %93, label %99, !prof !9

93:                                               ; preds = %91
  %94 = call <2 x float> @__mulsc3(float noundef %77, float noundef %79, float noundef %81, float noundef %83) #3
  store <2 x float> %94, ptr %8, align 4
  %95 = getelementptr inbounds nuw { float, float }, ptr %8, i32 0, i32 0
  %96 = load float, ptr %95, align 4
  %97 = getelementptr inbounds nuw { float, float }, ptr %8, i32 0, i32 1
  %98 = load float, ptr %97, align 4
  br label %99

99:                                               ; preds = %93, %91, %75
  %100 = phi float [ %88, %75 ], [ %88, %91 ], [ %96, %93 ]
  %101 = phi float [ %89, %75 ], [ %89, %91 ], [ %98, %93 ]
  %102 = fadd float %100, 1.000000e-01
  %103 = fadd float %101, 2.000000e-01
  %104 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %105 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  store float %102, ptr %104, align 4
  store float %103, ptr %105, align 4
  br label %106

106:                                              ; preds = %99
  %107 = load i32, ptr %7, align 4, !tbaa !10
  %108 = add nsw i32 %107, 1
  store i32 %108, ptr %7, align 4, !tbaa !10
  br label %71, !llvm.loop !11

109:                                              ; preds = %74
  %110 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %111 = load float, ptr %110, align 4
  %112 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %113 = load float, ptr %112, align 4
  %114 = fpext float %111 to double
  %115 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 0
  %116 = load float, ptr %115, align 4
  %117 = getelementptr inbounds nuw { float, float }, ptr %6, i32 0, i32 1
  %118 = load float, ptr %117, align 4
  %119 = fpext float %118 to double
  %120 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %114, double noundef %119)
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare { double, double } @__muldc3(double, double, double, double)

declare { double, double } @__divdc3(double, double, double, double)

declare i32 @printf(ptr noundef, ...) #2

declare <2 x float> @__mulsc3(float, float, float, float)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!4 = !{!5, !6, i64 0}
!5 = !{!"__libc_errno", !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{!"branch_weights", i32 1, i32 1048575}
!10 = !{!6, !6, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
