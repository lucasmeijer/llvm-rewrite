; @source: tests/function/src/abi/many_args.c
; @llc: -O2
; @driver: tests/function/src/abi/many_args.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/many_args.c'
source_filename = "tests/function/src/abi/many_args.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @mixed20(i32 noundef %0, double noundef %1, i8 noundef signext %2, float noundef %3, i64 noundef %4, double noundef %5, i16 noundef signext %6, float noundef %7, i32 noundef %8, double noundef %9, i64 noundef %10, float noundef %11, i32 noundef %12, double noundef %13, i8 noundef signext %14, double noundef %15, i64 noundef %16, float noundef %17, i32 noundef %18, double noundef %19) local_unnamed_addr #0 {
  %21 = sitofp i32 %0 to double
  %22 = tail call double @llvm.fmuladd.f64(double %1, double 2.000000e+00, double %21)
  %23 = sext i8 %2 to i32
  %24 = mul nsw i32 %23, 3
  %25 = sitofp i32 %24 to double
  %26 = fadd double %22, %25
  %27 = fmul float %3, 4.000000e+00
  %28 = fpext float %27 to double
  %29 = fadd double %26, %28
  %30 = mul nsw i64 %4, 5
  %31 = sitofp i64 %30 to double
  %32 = fadd double %29, %31
  %33 = tail call double @llvm.fmuladd.f64(double %5, double 6.000000e+00, double %32)
  %34 = sext i16 %6 to i32
  %35 = mul nsw i32 %34, 7
  %36 = sitofp i32 %35 to double
  %37 = fadd double %33, %36
  %38 = fmul float %7, 8.000000e+00
  %39 = fpext float %38 to double
  %40 = fadd double %37, %39
  %41 = mul nsw i32 %8, 9
  %42 = sitofp i32 %41 to double
  %43 = fadd double %40, %42
  %44 = tail call double @llvm.fmuladd.f64(double %9, double 1.000000e+01, double %43)
  %45 = mul nsw i64 %10, 11
  %46 = sitofp i64 %45 to double
  %47 = fadd double %44, %46
  %48 = fmul float %11, 1.200000e+01
  %49 = fpext float %48 to double
  %50 = fadd double %47, %49
  %51 = mul nsw i32 %12, 13
  %52 = sitofp i32 %51 to double
  %53 = fadd double %50, %52
  %54 = tail call double @llvm.fmuladd.f64(double %13, double 1.400000e+01, double %53)
  %55 = sext i8 %14 to i32
  %56 = mul nsw i32 %55, 15
  %57 = sitofp i32 %56 to double
  %58 = fadd double %54, %57
  %59 = tail call double @llvm.fmuladd.f64(double %15, double 1.600000e+01, double %58)
  %60 = mul nsw i64 %16, 17
  %61 = sitofp i64 %60 to double
  %62 = fadd double %59, %61
  %63 = fmul float %17, 1.800000e+01
  %64 = fpext float %63 to double
  %65 = fadd double %62, %64
  %66 = mul nsw i32 %18, 19
  %67 = sitofp i32 %66 to double
  %68 = fadd double %65, %67
  %69 = tail call double @llvm.fmuladd.f64(double %19, double 2.000000e+01, double %68)
  ret double %69
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local i64 @ints12(i64 noundef %0, i64 noundef %1, i64 noundef %2, i64 noundef %3, i64 noundef %4, i64 noundef %5, i64 noundef %6, i64 noundef %7, i64 noundef %8, i64 noundef %9, i64 noundef %10, i64 noundef %11) local_unnamed_addr #0 {
  %13 = mul i64 %11, -3
  %14 = add i64 %0, %2
  %15 = add i64 %1, %3
  %16 = add i64 %14, %4
  %17 = add i64 %15, %5
  %18 = add i64 %16, %6
  %19 = add i64 %17, %7
  %20 = add i64 %18, %8
  %21 = add i64 %19, %9
  %22 = sub i64 %20, %21
  %23 = add nsw i64 %22, %10
  %24 = add i64 %23, %13
  ret i64 %24
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local float @floats10(float noundef %0, float noundef %1, float noundef %2, float noundef %3, float noundef %4, float noundef %5, float noundef %6, float noundef %7, float noundef %8, float noundef %9) local_unnamed_addr #0 {
  %11 = fadd float %0, %1
  %12 = fsub float %11, %2
  %13 = fadd float %12, %3
  %14 = fsub float %13, %4
  %15 = fadd float %14, %5
  %16 = fsub float %15, %6
  %17 = fadd float %16, %7
  %18 = fsub float %17, %8
  %19 = tail call float @llvm.fmuladd.f32(float %9, float 5.000000e-01, float %18)
  ret float %19
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef zeroext i8 @small_args(i8 noundef zeroext %0, i8 noundef signext %1, i16 noundef zeroext %2, i16 noundef signext %3, i1 noundef zeroext %4) local_unnamed_addr #0 {
  %6 = add i8 %1, %0
  %7 = trunc i16 %2 to i8
  %8 = add i8 %6, %7
  %9 = trunc i16 %3 to i8
  %10 = add i8 %8, %9
  %11 = zext i1 %4 to i8
  %12 = add i8 %10, %11
  ret i8 %12
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
