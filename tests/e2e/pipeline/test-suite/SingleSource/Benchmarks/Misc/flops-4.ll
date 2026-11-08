; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-4.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-4.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/flops-4.c"
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
@.str.4 = private unnamed_addr constant [36 x i8] c"     4   %13.4lf  %10.4lf  %10.4lf\0A\00", align 1
@nulltime = dso_local global double 0.000000e+00, align 8
@TimeArray = dso_local global [3 x double] zeroinitializer, align 16
@T = dso_local global [36 x double] zeroinitializer, align 16
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
  store double 1.000000e+00, ptr @TLimit, align 8, !tbaa !11
  store i64 512000000, ptr %8, align 8, !tbaa !9
  store double f0x400921FB54442D18, ptr @piref, align 8, !tbaa !11
  store double 1.000000e+00, ptr @one, align 8, !tbaa !11
  store double 2.000000e+00, ptr @two, align 8, !tbaa !11
  store double 3.000000e+00, ptr @three, align 8, !tbaa !11
  store double 4.000000e+00, ptr @four, align 8, !tbaa !11
  store double 5.000000e+00, ptr @five, align 8, !tbaa !11
  %14 = load double, ptr @one, align 8, !tbaa !11
  store double %14, ptr @scale, align 8, !tbaa !11
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %17 = load i64, ptr %7, align 8, !tbaa !9
  %18 = mul nsw i64 %17, 10000
  store i64 %18, ptr %10, align 8, !tbaa !9
  %19 = load double, ptr @A3, align 8, !tbaa !11
  %20 = fneg double %19
  store double %20, ptr @A3, align 8, !tbaa !11
  %21 = load double, ptr @A5, align 8, !tbaa !11
  %22 = fneg double %21
  store double %22, ptr @A5, align 8, !tbaa !11
  %23 = load double, ptr @piref, align 8, !tbaa !11
  %24 = load double, ptr @three, align 8, !tbaa !11
  %25 = load i64, ptr %10, align 8, !tbaa !9
  %26 = sitofp i64 %25 to double
  %27 = fmul double %24, %26
  %28 = fdiv double %23, %27
  store double %28, ptr %6, align 8, !tbaa !11
  store double 0.000000e+00, ptr %2, align 8, !tbaa !11
  store double 0.000000e+00, ptr %4, align 8, !tbaa !11
  store i64 1, ptr %9, align 8, !tbaa !9
  br label %29

29:                                               ; preds = %63, %0
  %30 = load i64, ptr %9, align 8, !tbaa !9
  %31 = load i64, ptr %10, align 8, !tbaa !9
  %32 = sub nsw i64 %31, 1
  %33 = icmp sle i64 %30, %32
  br i1 %33, label %34, label %66

34:                                               ; preds = %29
  %35 = load i64, ptr %9, align 8, !tbaa !9
  %36 = sitofp i64 %35 to double
  %37 = load double, ptr %6, align 8, !tbaa !11
  %38 = fmul double %36, %37
  store double %38, ptr %3, align 8, !tbaa !11
  %39 = load double, ptr %3, align 8, !tbaa !11
  %40 = load double, ptr %3, align 8, !tbaa !11
  %41 = fmul double %39, %40
  store double %41, ptr %5, align 8, !tbaa !11
  %42 = load double, ptr %2, align 8, !tbaa !11
  %43 = load double, ptr %5, align 8, !tbaa !11
  %44 = load double, ptr %5, align 8, !tbaa !11
  %45 = load double, ptr %5, align 8, !tbaa !11
  %46 = load double, ptr %5, align 8, !tbaa !11
  %47 = load double, ptr %5, align 8, !tbaa !11
  %48 = load double, ptr @B6, align 8, !tbaa !11
  %49 = load double, ptr %5, align 8, !tbaa !11
  %50 = load double, ptr @B5, align 8, !tbaa !11
  %51 = call double @llvm.fmuladd.f64(double %48, double %49, double %50)
  %52 = load double, ptr @B4, align 8, !tbaa !11
  %53 = call double @llvm.fmuladd.f64(double %47, double %51, double %52)
  %54 = load double, ptr @B3, align 8, !tbaa !11
  %55 = call double @llvm.fmuladd.f64(double %46, double %53, double %54)
  %56 = load double, ptr @B2, align 8, !tbaa !11
  %57 = call double @llvm.fmuladd.f64(double %45, double %55, double %56)
  %58 = load double, ptr @B1, align 8, !tbaa !11
  %59 = call double @llvm.fmuladd.f64(double %44, double %57, double %58)
  %60 = call double @llvm.fmuladd.f64(double %43, double %59, double %42)
  %61 = load double, ptr @one, align 8, !tbaa !11
  %62 = fadd double %60, %61
  store double %62, ptr %2, align 8, !tbaa !11
  br label %63

63:                                               ; preds = %34
  %64 = load i64, ptr %9, align 8, !tbaa !9
  %65 = add nsw i64 %64, 1
  store i64 %65, ptr %9, align 8, !tbaa !9
  br label %29, !llvm.loop !13

66:                                               ; preds = %29
  %67 = load double, ptr @piref, align 8, !tbaa !11
  %68 = load double, ptr @three, align 8, !tbaa !11
  %69 = fdiv double %67, %68
  store double %69, ptr %3, align 8, !tbaa !11
  %70 = load double, ptr %3, align 8, !tbaa !11
  %71 = load double, ptr %3, align 8, !tbaa !11
  %72 = fmul double %70, %71
  store double %72, ptr %5, align 8, !tbaa !11
  %73 = load double, ptr %5, align 8, !tbaa !11
  %74 = load double, ptr %5, align 8, !tbaa !11
  %75 = load double, ptr %5, align 8, !tbaa !11
  %76 = load double, ptr %5, align 8, !tbaa !11
  %77 = load double, ptr %5, align 8, !tbaa !11
  %78 = load double, ptr @B6, align 8, !tbaa !11
  %79 = load double, ptr %5, align 8, !tbaa !11
  %80 = load double, ptr @B5, align 8, !tbaa !11
  %81 = call double @llvm.fmuladd.f64(double %78, double %79, double %80)
  %82 = load double, ptr @B4, align 8, !tbaa !11
  %83 = call double @llvm.fmuladd.f64(double %77, double %81, double %82)
  %84 = load double, ptr @B3, align 8, !tbaa !11
  %85 = call double @llvm.fmuladd.f64(double %76, double %83, double %84)
  %86 = load double, ptr @B2, align 8, !tbaa !11
  %87 = call double @llvm.fmuladd.f64(double %75, double %85, double %86)
  %88 = load double, ptr @B1, align 8, !tbaa !11
  %89 = call double @llvm.fmuladd.f64(double %74, double %87, double %88)
  %90 = load double, ptr @one, align 8, !tbaa !11
  %91 = call double @llvm.fmuladd.f64(double %73, double %89, double %90)
  store double %91, ptr @sa, align 8, !tbaa !11
  %92 = load double, ptr %6, align 8, !tbaa !11
  %93 = load double, ptr @sa, align 8, !tbaa !11
  %94 = load double, ptr @one, align 8, !tbaa !11
  %95 = fadd double %93, %94
  %96 = load double, ptr @two, align 8, !tbaa !11
  %97 = load double, ptr %2, align 8, !tbaa !11
  %98 = call double @llvm.fmuladd.f64(double %96, double %97, double %95)
  %99 = fmul double %92, %98
  %100 = load double, ptr @two, align 8, !tbaa !11
  %101 = fdiv double %99, %100
  store double %101, ptr @sa, align 8, !tbaa !11
  %102 = load double, ptr @piref, align 8, !tbaa !11
  %103 = load double, ptr @three, align 8, !tbaa !11
  %104 = fdiv double %102, %103
  store double %104, ptr %3, align 8, !tbaa !11
  %105 = load double, ptr %3, align 8, !tbaa !11
  %106 = load double, ptr %3, align 8, !tbaa !11
  %107 = fmul double %105, %106
  store double %107, ptr %5, align 8, !tbaa !11
  %108 = load double, ptr %3, align 8, !tbaa !11
  %109 = load double, ptr @A6, align 8, !tbaa !11
  %110 = load double, ptr %5, align 8, !tbaa !11
  %111 = load double, ptr @A5, align 8, !tbaa !11
  %112 = call double @llvm.fmuladd.f64(double %109, double %110, double %111)
  %113 = load double, ptr %5, align 8, !tbaa !11
  %114 = load double, ptr @A4, align 8, !tbaa !11
  %115 = call double @llvm.fmuladd.f64(double %112, double %113, double %114)
  %116 = load double, ptr %5, align 8, !tbaa !11
  %117 = load double, ptr @A3, align 8, !tbaa !11
  %118 = call double @llvm.fmuladd.f64(double %115, double %116, double %117)
  %119 = load double, ptr %5, align 8, !tbaa !11
  %120 = load double, ptr @A2, align 8, !tbaa !11
  %121 = call double @llvm.fmuladd.f64(double %118, double %119, double %120)
  %122 = load double, ptr %5, align 8, !tbaa !11
  %123 = load double, ptr @A1, align 8, !tbaa !11
  %124 = call double @llvm.fmuladd.f64(double %121, double %122, double %123)
  %125 = load double, ptr %5, align 8, !tbaa !11
  %126 = load double, ptr @A0, align 8, !tbaa !11
  %127 = call double @llvm.fmuladd.f64(double %124, double %125, double %126)
  %128 = fmul double %108, %127
  store double %128, ptr @sb, align 8, !tbaa !11
  %129 = load double, ptr @sa, align 8, !tbaa !11
  %130 = load double, ptr @sb, align 8, !tbaa !11
  %131 = fsub double %129, %130
  store double %131, ptr @sc, align 8, !tbaa !11
  %132 = load double, ptr @sc, align 8, !tbaa !11
  %133 = fmul double %132, 1.000000e-30
  %134 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, double noundef %133, double noundef 0.000000e+00, double noundef 0.000000e+00)
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
