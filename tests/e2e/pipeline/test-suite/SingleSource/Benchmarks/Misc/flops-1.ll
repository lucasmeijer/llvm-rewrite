; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-1.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@A0 = dso_local global double 1.000000e+00, align 8
@A1 = dso_local global double f0xBFC5555555559705, align 8
@A2 = dso_local global double f0x3F811111113AE9A3, align 8
@A3 = dso_local global double f0x3F2A01A03FB1CA71, align 8
@A4 = dso_local global double f0x3EC71DF284AA3566, align 8
@A5 = dso_local global double f0x3E5AEB5A8CF8A426, align 8
@A6 = dso_local global double f0x3DE68DF75229C1A6, align 8
@B0 = dso_local global double 1.000000e+00, align 8
@B1 = dso_local global double f0xBFDFFFFFFFFF8156, align 8
@B2 = dso_local global double f0x3FA5555555290224, align 8
@B3 = dso_local global double f0xBF56C16BFFE76516, align 8
@B4 = dso_local global double f0x3EFA019528242DB7, align 8
@B5 = dso_local global double f0xBE927BB3D47DDB8E, align 8
@B6 = dso_local global double f0x3E2157B275DF182A, align 8
@C0 = dso_local global double 1.000000e+00, align 8
@C1 = dso_local global double f0x3FEFFFFFFE37B3E2, align 8
@C2 = dso_local global double f0x3FDFFFFFCC2BA4B8, align 8
@C3 = dso_local global double f0x3FC555587C476915, align 8
@C4 = dso_local global double f0x3FA5555B7E795548, align 8
@C5 = dso_local global double f0x3F810D9A4AD9120C, align 8
@C6 = dso_local global double f0x3F5713187EDB8C05, align 8
@C7 = dso_local global double f0x3F26C077C8173F3A, align 8
@C8 = dso_local global double f0x3F049D03FE04B1CF, align 8
@D1 = dso_local global double f0x3FA47AE143138374, align 8
@D2 = dso_local global double 9.600000e-04, align 8
@D3 = dso_local global double f0x3EB4B05A0FF4A728, align 8
@E2 = dso_local global double 4.800000e-04, align 8
@E3 = dso_local global double 4.110510e-07, align 8
@.str = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.1 = private unnamed_addr constant [58 x i8] c"   FLOPS C Program (Double Precision), V2.0 18 Dec 1992\0A\0A\00", align 1
@T = dso_local global [36 x double] zeroinitializer, align 16
@TLimit = dso_local global double 0.000000e+00, align 8
@piref = dso_local global double 0.000000e+00, align 8
@one = dso_local global double 0.000000e+00, align 8
@two = dso_local global double 0.000000e+00, align 8
@three = dso_local global double 0.000000e+00, align 8
@four = dso_local global double 0.000000e+00, align 8
@five = dso_local global double 0.000000e+00, align 8
@scale = dso_local global double 0.000000e+00, align 8
@.str.2 = private unnamed_addr constant [48 x i8] c"   Module     Error        RunTime      MFLOPS\0A\00", align 1
@.str.3 = private unnamed_addr constant [36 x i8] c"                            (usec)\0A\00", align 1
@sa = dso_local global double 0.000000e+00, align 8
@sb = dso_local global double 0.000000e+00, align 8
@sc = dso_local global double 0.000000e+00, align 8
@.str.4 = private unnamed_addr constant [36 x i8] c"     1   %13.4lf  %10.4lf  %10.4lf\0A\00", align 1
@nulltime = dso_local global double 0.000000e+00, align 8
@TimeArray = dso_local global [3 x double] zeroinitializer, align 16
@sd = dso_local global double 0.000000e+00, align 8
@piprg = dso_local global double 0.000000e+00, align 8
@pierr = dso_local global double 0.000000e+00, align 8

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca double, align 8
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  call void @llvm.lifetime.start.p0(ptr %5) #4
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  call void @llvm.lifetime.start.p0(ptr %8) #4
  call void @llvm.lifetime.start.p0(ptr %9) #4
  call void @llvm.lifetime.start.p0(ptr %10) #4
  call void @llvm.lifetime.start.p0(ptr %11) #4
  %12 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  store i64 15625, ptr %7, align 8, !tbaa !9
  %14 = load i64, ptr %7, align 8, !tbaa !9
  %15 = sitofp i64 %14 to double
  %16 = fdiv double 1.000000e+06, %15
  store double %16, ptr getelementptr inbounds nuw (i8, ptr @T, i64 8), align 8, !tbaa !11
  store double 1.000000e+00, ptr @TLimit, align 8, !tbaa !11
  store i64 512000000, ptr %8, align 8, !tbaa !9
  store double f0x400921FB54442D18, ptr @piref, align 8, !tbaa !11
  store double 1.000000e+00, ptr @one, align 8, !tbaa !11
  store double 2.000000e+00, ptr @two, align 8, !tbaa !11
  store double 3.000000e+00, ptr @three, align 8, !tbaa !11
  store double 4.000000e+00, ptr @four, align 8, !tbaa !11
  store double 5.000000e+00, ptr @five, align 8, !tbaa !11
  %17 = load double, ptr @one, align 8, !tbaa !11
  store double %17, ptr @scale, align 8, !tbaa !11
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %20 = load i64, ptr %7, align 8, !tbaa !9
  %21 = mul nsw i64 %20, 10000
  store i64 %21, ptr %11, align 8, !tbaa !9
  store double 0.000000e+00, ptr @sa, align 8, !tbaa !11
  %22 = load i64, ptr %11, align 8, !tbaa !9
  %23 = mul nsw i64 2, %22
  store i64 %23, ptr %11, align 8, !tbaa !9
  %24 = load double, ptr @one, align 8, !tbaa !11
  %25 = load i64, ptr %11, align 8, !tbaa !9
  %26 = sitofp i64 %25 to double
  %27 = fdiv double %24, %26
  store double %27, ptr %6, align 8, !tbaa !11
  store double 0.000000e+00, ptr %2, align 8, !tbaa !11
  store double 0.000000e+00, ptr %4, align 8, !tbaa !11
  %28 = load double, ptr @one, align 8, !tbaa !11
  store double %28, ptr %5, align 8, !tbaa !11
  store i64 1, ptr %9, align 8, !tbaa !9
  br label %29

29:                                               ; preds = %61, %0
  %30 = load i64, ptr %9, align 8, !tbaa !9
  %31 = load i64, ptr %11, align 8, !tbaa !9
  %32 = sub nsw i64 %31, 1
  %33 = icmp sle i64 %30, %32
  br i1 %33, label %34, label %64

34:                                               ; preds = %29
  %35 = load double, ptr %4, align 8, !tbaa !11
  %36 = load double, ptr %5, align 8, !tbaa !11
  %37 = fadd double %35, %36
  store double %37, ptr %4, align 8, !tbaa !11
  %38 = load double, ptr %4, align 8, !tbaa !11
  %39 = load double, ptr %6, align 8, !tbaa !11
  %40 = fmul double %38, %39
  store double %40, ptr %3, align 8, !tbaa !11
  %41 = load double, ptr %2, align 8, !tbaa !11
  %42 = load double, ptr @D1, align 8, !tbaa !11
  %43 = load double, ptr %3, align 8, !tbaa !11
  %44 = load double, ptr @D2, align 8, !tbaa !11
  %45 = load double, ptr %3, align 8, !tbaa !11
  %46 = load double, ptr @D3, align 8, !tbaa !11
  %47 = call double @llvm.fmuladd.f64(double %45, double %46, double %44)
  %48 = call double @llvm.fmuladd.f64(double %43, double %47, double %42)
  %49 = load double, ptr %5, align 8, !tbaa !11
  %50 = load double, ptr %3, align 8, !tbaa !11
  %51 = load double, ptr @D1, align 8, !tbaa !11
  %52 = load double, ptr %3, align 8, !tbaa !11
  %53 = load double, ptr @E2, align 8, !tbaa !11
  %54 = load double, ptr %3, align 8, !tbaa !11
  %55 = load double, ptr @E3, align 8, !tbaa !11
  %56 = call double @llvm.fmuladd.f64(double %54, double %55, double %53)
  %57 = call double @llvm.fmuladd.f64(double %52, double %56, double %51)
  %58 = call double @llvm.fmuladd.f64(double %50, double %57, double %49)
  %59 = fdiv double %48, %58
  %60 = fadd double %41, %59
  store double %60, ptr %2, align 8, !tbaa !11
  br label %61

61:                                               ; preds = %34
  %62 = load i64, ptr %9, align 8, !tbaa !9
  %63 = add nsw i64 %62, 1
  store i64 %63, ptr %9, align 8, !tbaa !9
  br label %29, !llvm.loop !13

64:                                               ; preds = %29
  %65 = load double, ptr @D1, align 8, !tbaa !11
  %66 = load double, ptr @D2, align 8, !tbaa !11
  %67 = fadd double %65, %66
  %68 = load double, ptr @D3, align 8, !tbaa !11
  %69 = fadd double %67, %68
  %70 = load double, ptr @one, align 8, !tbaa !11
  %71 = load double, ptr @D1, align 8, !tbaa !11
  %72 = fadd double %70, %71
  %73 = load double, ptr @E2, align 8, !tbaa !11
  %74 = fadd double %72, %73
  %75 = load double, ptr @E3, align 8, !tbaa !11
  %76 = fadd double %74, %75
  %77 = fdiv double %69, %76
  store double %77, ptr @sa, align 8, !tbaa !11
  %78 = load double, ptr @D1, align 8, !tbaa !11
  store double %78, ptr @sb, align 8, !tbaa !11
  %79 = load double, ptr %6, align 8, !tbaa !11
  %80 = load double, ptr @sa, align 8, !tbaa !11
  %81 = load double, ptr @sb, align 8, !tbaa !11
  %82 = fadd double %80, %81
  %83 = load double, ptr @two, align 8, !tbaa !11
  %84 = load double, ptr %2, align 8, !tbaa !11
  %85 = call double @llvm.fmuladd.f64(double %83, double %84, double %82)
  %86 = fmul double %79, %85
  %87 = load double, ptr @two, align 8, !tbaa !11
  %88 = fdiv double %86, %87
  store double %88, ptr @sa, align 8, !tbaa !11
  %89 = load double, ptr @one, align 8, !tbaa !11
  %90 = load double, ptr @sa, align 8, !tbaa !11
  %91 = fdiv double %89, %90
  store double %91, ptr @sb, align 8, !tbaa !11
  %92 = load double, ptr @sb, align 8, !tbaa !11
  %93 = fptosi double %92 to i64
  %94 = mul nsw i64 40000, %93
  %95 = sitofp i64 %94 to double
  %96 = load double, ptr @scale, align 8, !tbaa !11
  %97 = fdiv double %95, %96
  %98 = fptosi double %97 to i64
  store i64 %98, ptr %11, align 8, !tbaa !9
  %99 = load double, ptr @sb, align 8, !tbaa !11
  %100 = fsub double %99, 2.520000e+01
  store double %100, ptr @sc, align 8, !tbaa !11
  %101 = load double, ptr @sc, align 8, !tbaa !11
  %102 = fmul double %101, 1.000000e-30
  %103 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, double noundef %102, double noundef 0.000000e+00, double noundef 0.000000e+00)
  call void @llvm.lifetime.end.p0(ptr %11) #4
  call void @llvm.lifetime.end.p0(ptr %10) #4
  call void @llvm.lifetime.end.p0(ptr %9) #4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind }

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
!10 = !{!"long", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"double", !7, i64 0}
!13 = distinct !{!13, !14}
!14 = !{!"llvm.loop.mustprogress"}
