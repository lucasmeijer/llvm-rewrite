; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/partialsums.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/partialsums.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/partialsums.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [9 x i8] c"%.9f\09%s\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"(2/3)^k\00", align 1
@.str.2 = private unnamed_addr constant [7 x i8] c"k^-0.5\00", align 1
@.str.3 = private unnamed_addr constant [9 x i8] c"1/k(k+1)\00", align 1
@.str.4 = private unnamed_addr constant [12 x i8] c"Flint Hills\00", align 1
@.str.5 = private unnamed_addr constant [14 x i8] c"Cookson Hills\00", align 1
@.str.6 = private unnamed_addr constant [9 x i8] c"Harmonic\00", align 1
@.str.7 = private unnamed_addr constant [13 x i8] c"Riemann Zeta\00", align 1
@.str.8 = private unnamed_addr constant [21 x i8] c"Alternating Harmonic\00", align 1
@.str.9 = private unnamed_addr constant [8 x i8] c"Gregory\00", align 1

; Function Attrs: nounwind uwtable
define dso_local <2 x double> @make_vec(double noundef %0, double noundef %1) #0 {
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  %5 = alloca <2 x double>, align 16
  %6 = alloca ptr, align 8
  store double %0, ptr %3, align 8, !tbaa !9
  store double %1, ptr %4, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  store ptr %5, ptr %6, align 8, !tbaa !11
  %7 = load double, ptr %3, align 8, !tbaa !9
  %8 = load ptr, ptr %6, align 8, !tbaa !11
  store double %7, ptr %8, align 8, !tbaa !9
  %9 = load double, ptr %4, align 8, !tbaa !9
  %10 = load ptr, ptr %6, align 8, !tbaa !11
  %11 = getelementptr inbounds double, ptr %10, i64 1
  store double %9, ptr %11, align 8, !tbaa !9
  %12 = load <2 x double>, ptr %5, align 16, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret <2 x double> %12
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local double @sum_vec(<2 x double> noundef %0) #0 {
  %2 = alloca <2 x double>, align 16
  %3 = alloca ptr, align 8
  store <2 x double> %0, ptr %2, align 16, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store ptr %2, ptr %3, align 8, !tbaa !11
  %4 = load ptr, ptr %3, align 8, !tbaa !11
  %5 = load double, ptr %4, align 8, !tbaa !9
  %6 = load ptr, ptr %3, align 8, !tbaa !11
  %7 = getelementptr inbounds double, ptr %6, i64 1
  %8 = load double, ptr %7, align 8, !tbaa !9
  %9 = fadd double %5, %8
  call void @llvm.lifetime.end.p0(ptr %3) #5
  ret double %9
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca double, align 8
  %7 = alloca double, align 8
  %8 = alloca double, align 8
  %9 = alloca double, align 8
  %10 = alloca <2 x double>, align 16
  %11 = alloca <2 x double>, align 16
  %12 = alloca <2 x double>, align 16
  %13 = alloca <2 x double>, align 16
  %14 = alloca <2 x double>, align 16
  %15 = alloca <2 x double>, align 16
  %16 = alloca <2 x double>, align 16
  %17 = alloca <2 x double>, align 16
  %18 = alloca <2 x double>, align 16
  %19 = alloca <2 x double>, align 16
  %20 = alloca <2 x double>, align 16
  %21 = alloca <2 x double>, align 16
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  %24 = alloca double, align 8
  %25 = alloca double, align 8
  %26 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !15
  store ptr %1, ptr %5, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %6) #5
  store double 0.000000e+00, ptr %6, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #5
  store double 0.000000e+00, ptr %7, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %8) #5
  store double 0.000000e+00, ptr %8, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %9) #5
  store double 0.000000e+00, ptr %9, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %10) #5
  call void @llvm.lifetime.start.p0(ptr %11) #5
  call void @llvm.lifetime.start.p0(ptr %12) #5
  call void @llvm.lifetime.start.p0(ptr %13) #5
  call void @llvm.lifetime.start.p0(ptr %14) #5
  call void @llvm.lifetime.start.p0(ptr %15) #5
  call void @llvm.lifetime.start.p0(ptr %16) #5
  call void @llvm.lifetime.start.p0(ptr %17) #5
  call void @llvm.lifetime.start.p0(ptr %18) #5
  call void @llvm.lifetime.start.p0(ptr %19) #5
  call void @llvm.lifetime.start.p0(ptr %20) #5
  call void @llvm.lifetime.start.p0(ptr %21) #5
  call void @llvm.lifetime.start.p0(ptr %22) #5
  call void @llvm.lifetime.start.p0(ptr %23) #5
  call void @llvm.lifetime.start.p0(ptr %24) #5
  call void @llvm.lifetime.start.p0(ptr %25) #5
  call void @llvm.lifetime.start.p0(ptr %26) #5
  store i32 2500000, ptr %26, align 4, !tbaa !15
  %27 = call <2 x double> @make_vec(double noundef 0.000000e+00, double noundef 0.000000e+00)
  store <2 x double> %27, ptr %15, align 16, !tbaa !14
  %28 = call <2 x double> @make_vec(double noundef 1.000000e+00, double noundef 1.000000e+00)
  store <2 x double> %28, ptr %16, align 16, !tbaa !14
  %29 = call <2 x double> @make_vec(double noundef 2.000000e+00, double noundef 2.000000e+00)
  store <2 x double> %29, ptr %17, align 16, !tbaa !14
  %30 = call <2 x double> @make_vec(double noundef -1.000000e+00, double noundef -1.000000e+00)
  store <2 x double> %30, ptr %19, align 16, !tbaa !14
  %31 = call <2 x double> @make_vec(double noundef 1.000000e+00, double noundef 2.000000e+00)
  store <2 x double> %31, ptr %18, align 16, !tbaa !14
  %32 = call <2 x double> @make_vec(double noundef 1.000000e+00, double noundef -1.000000e+00)
  store <2 x double> %32, ptr %21, align 16, !tbaa !14
  %33 = load <2 x double>, ptr %15, align 16, !tbaa !14
  store <2 x double> %33, ptr %14, align 16, !tbaa !14
  store <2 x double> %33, ptr %13, align 16, !tbaa !14
  store <2 x double> %33, ptr %12, align 16, !tbaa !14
  store <2 x double> %33, ptr %11, align 16, !tbaa !14
  store <2 x double> %33, ptr %10, align 16, !tbaa !14
  store double 1.000000e+00, ptr %22, align 8, !tbaa !9
  br label %34

34:                                               ; preds = %75, %2
  %35 = load double, ptr %22, align 8, !tbaa !9
  %36 = load i32, ptr %26, align 4, !tbaa !15
  %37 = sitofp i32 %36 to double
  %38 = fcmp ole double %35, %37
  br i1 %38, label %39, label %78

39:                                               ; preds = %34
  %40 = load double, ptr %22, align 8, !tbaa !9
  %41 = fsub double %40, 1.000000e+00
  %42 = call double @pow(double noundef f0x3FE5555555555555, double noundef %41) #5
  %43 = load double, ptr %6, align 8, !tbaa !9
  %44 = fadd double %43, %42
  store double %44, ptr %6, align 8, !tbaa !9
  %45 = load double, ptr %22, align 8, !tbaa !9
  %46 = call double @sqrt(double noundef %45) #5
  %47 = fdiv double 1.000000e+00, %46
  %48 = load double, ptr %7, align 8, !tbaa !9
  %49 = fadd double %48, %47
  store double %49, ptr %7, align 8, !tbaa !9
  %50 = load double, ptr %22, align 8, !tbaa !9
  %51 = load double, ptr %22, align 8, !tbaa !9
  %52 = fmul double %50, %51
  %53 = load double, ptr %22, align 8, !tbaa !9
  %54 = fmul double %52, %53
  store double %54, ptr %23, align 8, !tbaa !9
  %55 = load double, ptr %22, align 8, !tbaa !9
  %56 = call double @sin(double noundef %55) #5
  store double %56, ptr %24, align 8, !tbaa !9
  %57 = load double, ptr %22, align 8, !tbaa !9
  %58 = call double @cos(double noundef %57) #5
  store double %58, ptr %25, align 8, !tbaa !9
  %59 = load double, ptr %23, align 8, !tbaa !9
  %60 = load double, ptr %24, align 8, !tbaa !9
  %61 = fmul double %59, %60
  %62 = load double, ptr %24, align 8, !tbaa !9
  %63 = fmul double %61, %62
  %64 = fdiv double 1.000000e+00, %63
  %65 = load double, ptr %8, align 8, !tbaa !9
  %66 = fadd double %65, %64
  store double %66, ptr %8, align 8, !tbaa !9
  %67 = load double, ptr %23, align 8, !tbaa !9
  %68 = load double, ptr %25, align 8, !tbaa !9
  %69 = fmul double %67, %68
  %70 = load double, ptr %25, align 8, !tbaa !9
  %71 = fmul double %69, %70
  %72 = fdiv double 1.000000e+00, %71
  %73 = load double, ptr %9, align 8, !tbaa !9
  %74 = fadd double %73, %72
  store double %74, ptr %9, align 8, !tbaa !9
  br label %75

75:                                               ; preds = %39
  %76 = load double, ptr %22, align 8, !tbaa !9
  %77 = fadd double %76, 1.000000e+00
  store double %77, ptr %22, align 8, !tbaa !9
  br label %34, !llvm.loop !19

78:                                               ; preds = %34
  %79 = load <2 x double>, ptr %18, align 16, !tbaa !14
  store <2 x double> %79, ptr %20, align 16, !tbaa !14
  br label %80

80:                                               ; preds = %121, %78
  %81 = load double, ptr %20, align 16, !tbaa !9
  %82 = load i32, ptr %26, align 4, !tbaa !15
  %83 = sitofp i32 %82 to double
  %84 = fcmp ole double %81, %83
  br i1 %84, label %85, label %125

85:                                               ; preds = %80
  %86 = load <2 x double>, ptr %16, align 16, !tbaa !14
  %87 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %88 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %89 = load <2 x double>, ptr %16, align 16, !tbaa !14
  %90 = fadd <2 x double> %88, %89
  %91 = fmul <2 x double> %87, %90
  %92 = fdiv <2 x double> %86, %91
  %93 = load <2 x double>, ptr %12, align 16, !tbaa !14
  %94 = fadd <2 x double> %93, %92
  store <2 x double> %94, ptr %12, align 16, !tbaa !14
  %95 = load <2 x double>, ptr %16, align 16, !tbaa !14
  %96 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %97 = fdiv <2 x double> %95, %96
  %98 = load <2 x double>, ptr %10, align 16, !tbaa !14
  %99 = fadd <2 x double> %98, %97
  store <2 x double> %99, ptr %10, align 16, !tbaa !14
  %100 = load <2 x double>, ptr %16, align 16, !tbaa !14
  %101 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %102 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %103 = fmul <2 x double> %101, %102
  %104 = fdiv <2 x double> %100, %103
  %105 = load <2 x double>, ptr %11, align 16, !tbaa !14
  %106 = fadd <2 x double> %105, %104
  store <2 x double> %106, ptr %11, align 16, !tbaa !14
  %107 = load <2 x double>, ptr %21, align 16, !tbaa !14
  %108 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %109 = fdiv <2 x double> %107, %108
  %110 = load <2 x double>, ptr %13, align 16, !tbaa !14
  %111 = fadd <2 x double> %110, %109
  store <2 x double> %111, ptr %13, align 16, !tbaa !14
  %112 = load <2 x double>, ptr %21, align 16, !tbaa !14
  %113 = load <2 x double>, ptr %17, align 16, !tbaa !14
  %114 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %115 = load <2 x double>, ptr %16, align 16, !tbaa !14
  %116 = fneg <2 x double> %115
  %117 = call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %113, <2 x double> %114, <2 x double> %116)
  %118 = fdiv <2 x double> %112, %117
  %119 = load <2 x double>, ptr %14, align 16, !tbaa !14
  %120 = fadd <2 x double> %119, %118
  store <2 x double> %120, ptr %14, align 16, !tbaa !14
  br label %121

121:                                              ; preds = %85
  %122 = load <2 x double>, ptr %17, align 16, !tbaa !14
  %123 = load <2 x double>, ptr %20, align 16, !tbaa !14
  %124 = fadd <2 x double> %123, %122
  store <2 x double> %124, ptr %20, align 16, !tbaa !14
  br label %80, !llvm.loop !21

125:                                              ; preds = %80
  %126 = load double, ptr %6, align 8, !tbaa !9
  %127 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %126, ptr noundef @.str.1)
  %128 = load double, ptr %7, align 8, !tbaa !9
  %129 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %128, ptr noundef @.str.2)
  %130 = load <2 x double>, ptr %12, align 16, !tbaa !14
  %131 = call double @sum_vec(<2 x double> noundef %130)
  %132 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %131, ptr noundef @.str.3)
  %133 = load double, ptr %8, align 8, !tbaa !9
  %134 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %133, ptr noundef @.str.4)
  %135 = load double, ptr %9, align 8, !tbaa !9
  %136 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %135, ptr noundef @.str.5)
  %137 = load <2 x double>, ptr %10, align 16, !tbaa !14
  %138 = call double @sum_vec(<2 x double> noundef %137)
  %139 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %138, ptr noundef @.str.6)
  %140 = load <2 x double>, ptr %11, align 16, !tbaa !14
  %141 = call double @sum_vec(<2 x double> noundef %140)
  %142 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %141, ptr noundef @.str.7)
  %143 = load <2 x double>, ptr %13, align 16, !tbaa !14
  %144 = call double @sum_vec(<2 x double> noundef %143)
  %145 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %144, ptr noundef @.str.8)
  %146 = load <2 x double>, ptr %14, align 16, !tbaa !14
  %147 = call double @sum_vec(<2 x double> noundef %146)
  %148 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %147, ptr noundef @.str.9)
  call void @llvm.lifetime.end.p0(ptr %26) #5
  call void @llvm.lifetime.end.p0(ptr %25) #5
  call void @llvm.lifetime.end.p0(ptr %24) #5
  call void @llvm.lifetime.end.p0(ptr %23) #5
  call void @llvm.lifetime.end.p0(ptr %22) #5
  call void @llvm.lifetime.end.p0(ptr %21) #5
  call void @llvm.lifetime.end.p0(ptr %20) #5
  call void @llvm.lifetime.end.p0(ptr %19) #5
  call void @llvm.lifetime.end.p0(ptr %18) #5
  call void @llvm.lifetime.end.p0(ptr %17) #5
  call void @llvm.lifetime.end.p0(ptr %16) #5
  call void @llvm.lifetime.end.p0(ptr %15) #5
  call void @llvm.lifetime.end.p0(ptr %14) #5
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

; Function Attrs: nounwind
declare double @pow(double noundef, double noundef) #2

; Function Attrs: nounwind
declare double @sqrt(double noundef) #2

; Function Attrs: nounwind
declare double @sin(double noundef) #2

; Function Attrs: nounwind
declare double @cos(double noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #3

declare i32 @printf(ptr noundef, ...) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="128" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }

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
!9 = !{!10, !10, i64 0}
!10 = !{!"double", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 double", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!7, !7, i64 0}
!15 = !{!6, !6, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"p2 omnipotent char", !18, i64 0}
!18 = !{!"any p2 pointer", !13, i64 0}
!19 = distinct !{!19, !20}
!20 = !{!"llvm.loop.mustprogress"}
!21 = distinct !{!21, !20}
