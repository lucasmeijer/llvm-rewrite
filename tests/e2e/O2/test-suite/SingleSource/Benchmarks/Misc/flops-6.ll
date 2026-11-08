; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-6.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-6.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-6.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@A0 = dso_local local_unnamed_addr global double 1.000000e+00, align 8
@A1 = dso_local local_unnamed_addr global double f0xBFC5555555559705, align 8
@A2 = dso_local local_unnamed_addr global double f0x3F811111113AE9A3, align 8
@A3 = dso_local local_unnamed_addr global double f0x3F2A01A03FB1CA71, align 8
@A4 = dso_local local_unnamed_addr global double f0x3EC71DF284AA3566, align 8
@A5 = dso_local local_unnamed_addr global double f0x3E5AEB5A8CF8A426, align 8
@A6 = dso_local local_unnamed_addr global double f0x3DE68DF75229C1A6, align 8
@B0 = dso_local local_unnamed_addr global double 1.000000e+00, align 8
@B1 = dso_local local_unnamed_addr global double f0xBFDFFFFFFFFF8156, align 8
@B2 = dso_local local_unnamed_addr global double f0x3FA5555555290224, align 8
@B3 = dso_local local_unnamed_addr global double f0xBF56C16BFFE76516, align 8
@B4 = dso_local local_unnamed_addr global double f0x3EFA019528242DB7, align 8
@B5 = dso_local local_unnamed_addr global double f0xBE927BB3D47DDB8E, align 8
@B6 = dso_local local_unnamed_addr global double f0x3E2157B275DF182A, align 8
@C0 = dso_local local_unnamed_addr global double 1.000000e+00, align 8
@C1 = dso_local local_unnamed_addr global double f0x3FEFFFFFFE37B3E2, align 8
@C2 = dso_local local_unnamed_addr global double f0x3FDFFFFFCC2BA4B8, align 8
@C3 = dso_local local_unnamed_addr global double f0x3FC555587C476915, align 8
@C4 = dso_local local_unnamed_addr global double f0x3FA5555B7E795548, align 8
@C5 = dso_local local_unnamed_addr global double f0x3F810D9A4AD9120C, align 8
@C6 = dso_local local_unnamed_addr global double f0x3F5713187EDB8C05, align 8
@C7 = dso_local local_unnamed_addr global double f0x3F26C077C8173F3A, align 8
@C8 = dso_local local_unnamed_addr global double f0x3F049D03FE04B1CF, align 8
@D1 = dso_local local_unnamed_addr global double f0x3FA47AE143138374, align 8
@D2 = dso_local local_unnamed_addr global double 9.600000e-04, align 8
@D3 = dso_local local_unnamed_addr global double f0x3EB4B05A0FF4A728, align 8
@E2 = dso_local local_unnamed_addr global double 4.800000e-04, align 8
@E3 = dso_local local_unnamed_addr global double 4.110510e-07, align 8
@TLimit = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@piref = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@one = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@two = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@three = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@four = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@five = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@scale = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@sa = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@sb = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@sc = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@.str.4 = private unnamed_addr constant [36 x i8] c"     6   %13.4lf  %10.4lf  %10.4lf\0A\00", align 1
@nulltime = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@TimeArray = dso_local local_unnamed_addr global [3 x double] zeroinitializer, align 16
@T = dso_local local_unnamed_addr global [36 x double] zeroinitializer, align 16
@sd = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@piprg = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@pierr = dso_local local_unnamed_addr global double 0.000000e+00, align 8
@str = private unnamed_addr constant [57 x i8] c"   FLOPS C Program (Double Precision), V2.0 18 Dec 1992\0A\00", align 1
@str.5 = private unnamed_addr constant [47 x i8] c"   Module     Error        RunTime      MFLOPS\00", align 1
@str.6 = private unnamed_addr constant [35 x i8] c"                            (usec)\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i32 @putchar(i32 10)
  %2 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  store double 1.000000e+00, ptr @TLimit, align 8, !tbaa !9
  store double f0x400921FB54442D18, ptr @piref, align 8, !tbaa !9
  store double 1.000000e+00, ptr @one, align 8, !tbaa !9
  store double 2.000000e+00, ptr @two, align 8, !tbaa !9
  store double 3.000000e+00, ptr @three, align 8, !tbaa !9
  store double 4.000000e+00, ptr @four, align 8, !tbaa !9
  store double 5.000000e+00, ptr @five, align 8, !tbaa !9
  store double 1.000000e+00, ptr @scale, align 8, !tbaa !9
  %3 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.5)
  %4 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.6)
  %5 = load double, ptr @piref, align 8, !tbaa !9
  %6 = load double, ptr @four, align 8, !tbaa !9
  %7 = fmul double %6, 1.562500e+08
  %8 = fdiv double %5, %7
  %9 = load double, ptr @A6, align 8, !tbaa !9
  %10 = load double, ptr @A5, align 8, !tbaa !9
  %11 = load double, ptr @A4, align 8, !tbaa !9
  %12 = load double, ptr @A3, align 8, !tbaa !9
  %13 = load double, ptr @A2, align 8, !tbaa !9
  %14 = load double, ptr @A1, align 8, !tbaa !9
  %15 = load double, ptr @one, align 8, !tbaa !9
  %16 = load double, ptr @B6, align 8, !tbaa !9
  %17 = load double, ptr @B5, align 8, !tbaa !9
  %18 = load double, ptr @B4, align 8, !tbaa !9
  %19 = load double, ptr @B3, align 8, !tbaa !9
  %20 = load double, ptr @B2, align 8, !tbaa !9
  %21 = load double, ptr @B1, align 8, !tbaa !9
  %22 = insertelement <2 x double> poison, double %15, i64 0
  %23 = insertelement <2 x double> %22, double %17, i64 1
  br label %24

24:                                               ; preds = %0, %24
  %25 = phi double [ 0.000000e+00, %0 ], [ %48, %24 ]
  %26 = phi i64 [ 1, %0 ], [ %49, %24 ]
  %27 = uitofp nneg i64 %26 to double
  %28 = fmul double %8, %27
  %29 = fmul double %28, %28
  %30 = tail call double @llvm.fmuladd.f64(double %9, double %29, double %10)
  %31 = tail call double @llvm.fmuladd.f64(double %30, double %29, double %11)
  %32 = tail call double @llvm.fmuladd.f64(double %31, double %29, double %12)
  %33 = tail call double @llvm.fmuladd.f64(double %32, double %29, double %13)
  %34 = tail call double @llvm.fmuladd.f64(double %33, double %29, double %14)
  %35 = insertelement <2 x double> poison, double %34, i64 0
  %36 = insertelement <2 x double> %35, double %16, i64 1
  %37 = insertelement <2 x double> poison, double %29, i64 0
  %38 = shufflevector <2 x double> %37, <2 x double> poison, <2 x i32> zeroinitializer
  %39 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %36, <2 x double> %38, <2 x double> %23)
  %40 = extractelement <2 x double> %39, i64 0
  %41 = fmul double %28, %40
  %42 = extractelement <2 x double> %39, i64 1
  %43 = tail call double @llvm.fmuladd.f64(double %29, double %42, double %18)
  %44 = tail call double @llvm.fmuladd.f64(double %29, double %43, double %19)
  %45 = tail call double @llvm.fmuladd.f64(double %29, double %44, double %20)
  %46 = tail call double @llvm.fmuladd.f64(double %29, double %45, double %21)
  %47 = tail call double @llvm.fmuladd.f64(double %29, double %46, double %15)
  %48 = tail call double @llvm.fmuladd.f64(double %41, double %47, double %25)
  %49 = add nuw nsw i64 %26, 1
  %50 = icmp eq i64 %49, 156250000
  br i1 %50, label %51, label %24, !llvm.loop !11

51:                                               ; preds = %24
  %52 = fdiv double %5, %6
  %53 = fmul double %52, %52
  %54 = tail call double @llvm.fmuladd.f64(double %9, double %53, double %10)
  %55 = tail call double @llvm.fmuladd.f64(double %54, double %53, double %11)
  %56 = tail call double @llvm.fmuladd.f64(double %55, double %53, double %12)
  %57 = tail call double @llvm.fmuladd.f64(double %56, double %53, double %13)
  %58 = tail call double @llvm.fmuladd.f64(double %57, double %53, double %14)
  %59 = tail call double @llvm.fmuladd.f64(double %58, double %53, double %15)
  %60 = fmul double %52, %59
  %61 = tail call double @llvm.fmuladd.f64(double %16, double %53, double %17)
  %62 = tail call double @llvm.fmuladd.f64(double %53, double %61, double %18)
  %63 = tail call double @llvm.fmuladd.f64(double %53, double %62, double %19)
  %64 = tail call double @llvm.fmuladd.f64(double %53, double %63, double %20)
  %65 = tail call double @llvm.fmuladd.f64(double %53, double %64, double %21)
  %66 = tail call double @llvm.fmuladd.f64(double %53, double %65, double %15)
  %67 = fmul double %60, %66
  %68 = load double, ptr @two, align 8, !tbaa !9
  %69 = tail call double @llvm.fmuladd.f64(double %68, double %48, double %67)
  %70 = fmul double %8, %69
  %71 = fdiv double %70, %68
  store double %71, ptr @sa, align 8, !tbaa !9
  store double 2.500000e-01, ptr @sb, align 8, !tbaa !9
  %72 = fadd double %71, -2.500000e-01
  store double %72, ptr @sc, align 8, !tbaa !9
  %73 = fmul double %72, 1.000000e-30
  %74 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.4, double noundef %73, double noundef 0.000000e+00, double noundef 0.000000e+00)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #3

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #4

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree nounwind }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
