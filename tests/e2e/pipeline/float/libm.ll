; @source: tests/e2e/src/float/libm.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/libm.c'
source_filename = "tests/e2e/src/float/libm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [31 x i8] c"%.12f %.12f %.12f %.12f %.12f\0A\00", align 1
@.str.1 = private unnamed_addr constant [21 x i8] c"%.3f %.3f %.3f %.3f\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%.6f %.6f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca double, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  store double 1.000000e-01, ptr %2, align 8, !tbaa !9
  br label %3

3:                                                ; preds = %19, %0
  %4 = load double, ptr %2, align 8, !tbaa !9
  %5 = fcmp olt double %4, 3.000000e+00
  br i1 %5, label %7, label %6

6:                                                ; preds = %3
  call void @llvm.lifetime.end.p0(ptr %2) #5
  br label %22

7:                                                ; preds = %3
  %8 = load double, ptr %2, align 8, !tbaa !9
  %9 = call double @sqrt(double noundef %8) #5
  %10 = load double, ptr %2, align 8, !tbaa !9
  %11 = call double @sin(double noundef %10) #5
  %12 = load double, ptr %2, align 8, !tbaa !9
  %13 = call double @exp(double noundef %12) #5
  %14 = load double, ptr %2, align 8, !tbaa !9
  %15 = call double @log(double noundef %14) #5
  %16 = load double, ptr %2, align 8, !tbaa !9
  %17 = call double @pow(double noundef %16, double noundef 1.500000e+00) #5
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %9, double noundef %11, double noundef %13, double noundef %15, double noundef %17)
  br label %19

19:                                               ; preds = %7
  %20 = load double, ptr %2, align 8, !tbaa !9
  %21 = fadd double %20, f0x3FE6666666666666
  store double %21, ptr %2, align 8, !tbaa !9
  br label %3, !llvm.loop !11

22:                                               ; preds = %6
  %23 = call double @llvm.floor.f64(double -2.500000e+00)
  %24 = call double @llvm.ceil.f64(double -2.500000e+00)
  %25 = call double @llvm.fabs.f64(double -3.250000e+00)
  %26 = call double @fmod(double noundef 1.050000e+01, double noundef 3.000000e+00) #5
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %23, double noundef %24, double noundef %25, double noundef %26)
  %28 = call float @sqrtf(float noundef 2.000000e+00) #5
  %29 = fpext float %28 to double
  %30 = call nsz float @llvm.maxnum.f32(float 1.000000e+00, float -2.000000e+00)
  %31 = fpext float %30 to double
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %29, double noundef %31)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind
declare double @sqrt(double noundef) #3

; Function Attrs: nounwind
declare double @sin(double noundef) #3

; Function Attrs: nounwind
declare double @exp(double noundef) #3

; Function Attrs: nounwind
declare double @log(double noundef) #3

; Function Attrs: nounwind
declare double @pow(double noundef, double noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.floor.f64(double) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.ceil.f64(double) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #4

; Function Attrs: nounwind
declare double @fmod(double noundef, double noundef) #3

; Function Attrs: nounwind
declare float @sqrtf(float noundef) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.maxnum.f32(float, float) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
