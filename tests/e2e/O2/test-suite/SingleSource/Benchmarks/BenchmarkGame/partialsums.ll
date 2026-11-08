; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/partialsums.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
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

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local <2 x double> @make_vec(double noundef %0, double noundef %1) local_unnamed_addr #0 {
  %3 = insertelement <2 x double> poison, double %0, i64 0
  %4 = insertelement <2 x double> %3, double %1, i64 1
  ret <2 x double> %4
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @sum_vec(<2 x double> noundef %0) local_unnamed_addr #0 {
  %2 = shufflevector <2 x double> %0, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %3 = fadd <2 x double> %0, %2
  %4 = extractelement <2 x double> %3, i64 0
  ret double %4
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #1 {
  br label %3

3:                                                ; preds = %2, %3
  %4 = phi i32 [ 1, %2 ], [ %28, %3 ]
  %5 = phi <4 x double> [ zeroinitializer, %2 ], [ %27, %3 ]
  %6 = uitofp nneg i32 %4 to double
  %7 = add nsw i32 %4, -1
  %8 = sitofp i32 %7 to double
  %9 = tail call double @pow(double noundef f0x3FE5555555555555, double noundef %8) #5
  %10 = tail call double @sqrt(double noundef %6) #5
  %11 = fdiv double 1.000000e+00, %10
  %12 = fmul double %6, %6
  %13 = fmul double %12, %6
  %14 = tail call double @sin(double noundef %6) #5
  %15 = tail call double @cos(double noundef %6) #5
  %16 = insertelement <2 x double> poison, double %13, i64 0
  %17 = shufflevector <2 x double> %16, <2 x double> poison, <2 x i32> zeroinitializer
  %18 = insertelement <2 x double> poison, double %14, i64 0
  %19 = insertelement <2 x double> %18, double %15, i64 1
  %20 = fmul <2 x double> %17, %19
  %21 = fmul <2 x double> %19, %20
  %22 = fdiv <2 x double> splat (double 1.000000e+00), %21
  %23 = insertelement <4 x double> poison, double %9, i64 0
  %24 = insertelement <4 x double> %23, double %11, i64 1
  %25 = shufflevector <2 x double> %22, <2 x double> poison, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %26 = shufflevector <4 x double> %24, <4 x double> %25, <4 x i32> <i32 0, i32 1, i32 4, i32 5>
  %27 = fadd <4 x double> %5, %26
  %28 = add nuw nsw i32 %4, 1
  %29 = icmp eq i32 %28, 2500001
  br i1 %29, label %30, label %3, !llvm.loop !9

30:                                               ; preds = %3, %30
  %31 = phi <2 x double> [ %42, %30 ], [ zeroinitializer, %3 ]
  %32 = phi <2 x double> [ %51, %30 ], [ <double 1.000000e+00, double 2.000000e+00>, %3 ]
  %33 = phi <2 x double> [ %45, %30 ], [ zeroinitializer, %3 ]
  %34 = phi <2 x double> [ %40, %30 ], [ zeroinitializer, %3 ]
  %35 = phi <2 x double> [ %47, %30 ], [ zeroinitializer, %3 ]
  %36 = phi <2 x double> [ %50, %30 ], [ zeroinitializer, %3 ]
  %37 = fadd <2 x double> %32, splat (double 1.000000e+00)
  %38 = fmul <2 x double> %32, %37
  %39 = fdiv <2 x double> splat (double 1.000000e+00), %38
  %40 = fadd <2 x double> %34, %39
  %41 = fdiv <2 x double> splat (double 1.000000e+00), %32
  %42 = fadd <2 x double> %31, %41
  %43 = fmul <2 x double> %32, %32
  %44 = fdiv <2 x double> splat (double 1.000000e+00), %43
  %45 = fadd <2 x double> %33, %44
  %46 = fdiv <2 x double> <double 1.000000e+00, double -1.000000e+00>, %32
  %47 = fadd <2 x double> %35, %46
  %48 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %32, <2 x double> splat (double 2.000000e+00), <2 x double> splat (double -1.000000e+00))
  %49 = fdiv <2 x double> <double 1.000000e+00, double -1.000000e+00>, %48
  %50 = fadd <2 x double> %36, %49
  %51 = fadd <2 x double> %32, splat (double 2.000000e+00)
  %52 = extractelement <2 x double> %51, i64 0
  %53 = fcmp ugt double %52, 2.500000e+06
  br i1 %53, label %54, label %30, !llvm.loop !11

54:                                               ; preds = %30
  %55 = extractelement <4 x double> %27, i64 0
  %56 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %55, ptr noundef nonnull @.str.1)
  %57 = extractelement <4 x double> %27, i64 1
  %58 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %57, ptr noundef nonnull @.str.2)
  %59 = shufflevector <2 x double> %40, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %60 = fadd <2 x double> %40, %59
  %61 = extractelement <2 x double> %60, i64 0
  %62 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %61, ptr noundef nonnull @.str.3)
  %63 = extractelement <4 x double> %27, i64 2
  %64 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %63, ptr noundef nonnull @.str.4)
  %65 = extractelement <4 x double> %27, i64 3
  %66 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %65, ptr noundef nonnull @.str.5)
  %67 = shufflevector <2 x double> %42, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %68 = fadd <2 x double> %42, %67
  %69 = extractelement <2 x double> %68, i64 0
  %70 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %69, ptr noundef nonnull @.str.6)
  %71 = shufflevector <2 x double> %45, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %72 = fadd <2 x double> %45, %71
  %73 = extractelement <2 x double> %72, i64 0
  %74 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %73, ptr noundef nonnull @.str.7)
  %75 = shufflevector <2 x double> %47, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %76 = fadd <2 x double> %47, %75
  %77 = extractelement <2 x double> %76, i64 0
  %78 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %77, ptr noundef nonnull @.str.8)
  %79 = shufflevector <2 x double> %50, <2 x double> poison, <2 x i32> <i32 1, i32 poison>
  %80 = fadd <2 x double> %50, %79
  %81 = extractelement <2 x double> %80, i64 0
  %82 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %81, ptr noundef nonnull @.str.9)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @pow(double noundef, double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sqrt(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @cos(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #3

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="128" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="128" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
!11 = distinct !{!11, !10}
