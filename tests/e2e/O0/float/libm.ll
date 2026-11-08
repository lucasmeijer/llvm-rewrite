; @source: tests/e2e/src/float/libm.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/libm.c'
source_filename = "tests/e2e/src/float/libm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [31 x i8] c"%.12f %.12f %.12f %.12f %.12f\0A\00", align 1
@.str.1 = private unnamed_addr constant [21 x i8] c"%.3f %.3f %.3f %.3f\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%.6f %.6f\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca double, align 8
  store i32 0, ptr %1, align 4
  store double 1.000000e-01, ptr %2, align 8
  br label %3

3:                                                ; preds = %18, %0
  %4 = load double, ptr %2, align 8
  %5 = fcmp olt double %4, 3.000000e+00
  br i1 %5, label %6, label %21

6:                                                ; preds = %3
  %7 = load double, ptr %2, align 8
  %8 = call double @sqrt(double noundef %7) #4
  %9 = load double, ptr %2, align 8
  %10 = call double @sin(double noundef %9) #4
  %11 = load double, ptr %2, align 8
  %12 = call double @exp(double noundef %11) #4
  %13 = load double, ptr %2, align 8
  %14 = call double @log(double noundef %13) #4
  %15 = load double, ptr %2, align 8
  %16 = call double @pow(double noundef %15, double noundef 1.500000e+00) #4
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %8, double noundef %10, double noundef %12, double noundef %14, double noundef %16)
  br label %18

18:                                               ; preds = %6
  %19 = load double, ptr %2, align 8
  %20 = fadd double %19, f0x3FE6666666666666
  store double %20, ptr %2, align 8
  br label %3, !llvm.loop !5

21:                                               ; preds = %3
  %22 = call double @llvm.floor.f64(double -2.500000e+00)
  %23 = call double @llvm.ceil.f64(double -2.500000e+00)
  %24 = call double @llvm.fabs.f64(double -3.250000e+00)
  %25 = call double @fmod(double noundef 1.050000e+01, double noundef 3.000000e+00) #4
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %22, double noundef %23, double noundef %24, double noundef %25)
  %27 = call float @sqrtf(float noundef 2.000000e+00) #4
  %28 = fpext float %27 to double
  %29 = call nsz float @llvm.maxnum.f32(float 1.000000e+00, float -2.000000e+00)
  %30 = fpext float %29 to double
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %28, double noundef %30)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind
declare double @sqrt(double noundef) #2

; Function Attrs: nounwind
declare double @sin(double noundef) #2

; Function Attrs: nounwind
declare double @exp(double noundef) #2

; Function Attrs: nounwind
declare double @log(double noundef) #2

; Function Attrs: nounwind
declare double @pow(double noundef, double noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.floor.f64(double) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.ceil.f64(double) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #3

; Function Attrs: nounwind
declare double @fmod(double noundef, double noundef) #2

; Function Attrs: nounwind
declare float @sqrtf(float noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.maxnum.f32(float, float) #3

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
