; @source: tests/function/src/arith/float_ops.c
; @llc: -O0
; @driver: tests/function/src/arith/float_ops.driver.c
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/arith/float_ops.c'
source_filename = "tests/function/src/arith/float_ops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: noinline nounwind uwtable
define dso_local float @fadd(float noundef %0, float noundef %1) #0 {
  %3 = alloca float, align 4
  %4 = alloca float, align 4
  store float %0, ptr %3, align 4
  store float %1, ptr %4, align 4
  %5 = load float, ptr %3, align 4
  %6 = load float, ptr %4, align 4
  %7 = fadd float %5, %6
  ret float %7
}

; Function Attrs: noinline nounwind uwtable
define dso_local float @fmul(float noundef %0, float noundef %1) #0 {
  %3 = alloca float, align 4
  %4 = alloca float, align 4
  store float %0, ptr %3, align 4
  store float %1, ptr %4, align 4
  %5 = load float, ptr %3, align 4
  %6 = load float, ptr %4, align 4
  %7 = fmul float %5, %6
  ret float %7
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @ddiv(double noundef %0, double noundef %1) #0 {
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  store double %0, ptr %3, align 8
  store double %1, ptr %4, align 8
  %5 = load double, ptr %3, align 8
  %6 = load double, ptr %4, align 8
  %7 = fdiv double %5, %6
  ret double %7
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @dsub(double noundef %0, double noundef %1) #0 {
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  store double %0, ptr %3, align 8
  store double %1, ptr %4, align 8
  %5 = load double, ptr %3, align 8
  %6 = load double, ptr %4, align 8
  %7 = fsub double %5, %6
  ret double %7
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @fma_like(double noundef %0, double noundef %1, double noundef %2) #0 {
  %4 = alloca double, align 8
  %5 = alloca double, align 8
  %6 = alloca double, align 8
  store double %0, ptr %4, align 8
  store double %1, ptr %5, align 8
  store double %2, ptr %6, align 8
  %7 = load double, ptr %4, align 8
  %8 = load double, ptr %5, align 8
  %9 = load double, ptr %6, align 8
  %10 = call double @llvm.fmuladd.f64(double %7, double %8, double %9)
  ret double %10
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @fcmp_all(double noundef %0, double noundef %1) #0 {
  %3 = alloca double, align 8
  %4 = alloca double, align 8
  store double %0, ptr %3, align 8
  store double %1, ptr %4, align 8
  %5 = load double, ptr %3, align 8
  %6 = load double, ptr %4, align 8
  %7 = fcmp olt double %5, %6
  %8 = zext i1 %7 to i32
  %9 = load double, ptr %3, align 8
  %10 = load double, ptr %4, align 8
  %11 = fcmp ole double %9, %10
  %12 = zext i1 %11 to i32
  %13 = shl i32 %12, 1
  %14 = or i32 %8, %13
  %15 = load double, ptr %3, align 8
  %16 = load double, ptr %4, align 8
  %17 = fcmp ogt double %15, %16
  %18 = zext i1 %17 to i32
  %19 = shl i32 %18, 2
  %20 = or i32 %14, %19
  %21 = load double, ptr %3, align 8
  %22 = load double, ptr %4, align 8
  %23 = fcmp oge double %21, %22
  %24 = zext i1 %23 to i32
  %25 = shl i32 %24, 3
  %26 = or i32 %20, %25
  %27 = load double, ptr %3, align 8
  %28 = load double, ptr %4, align 8
  %29 = fcmp oeq double %27, %28
  %30 = zext i1 %29 to i32
  %31 = shl i32 %30, 4
  %32 = or i32 %26, %31
  %33 = load double, ptr %3, align 8
  %34 = load double, ptr %4, align 8
  %35 = fcmp une double %33, %34
  %36 = zext i1 %35 to i32
  %37 = shl i32 %36, 5
  %38 = or i32 %32, %37
  ret i32 %38
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @neg(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = fneg double %3
  ret double %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local float @to_float(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = fptrunc double %3 to float
  ret float %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @to_double(float noundef %0) #0 {
  %2 = alloca float, align 4
  store float %0, ptr %2, align 4
  %3 = load float, ptr %2, align 4
  %4 = fpext float %3 to double
  ret double %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @d2i(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = fptosi double %3 to i32
  ret i32 %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @d2ll(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = fptosi double %3 to i64
  ret i64 %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @d2u(double noundef %0) #0 {
  %2 = alloca double, align 8
  store double %0, ptr %2, align 8
  %3 = load double, ptr %2, align 8
  %4 = fptoui double %3 to i32
  ret i32 %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @i2d(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = sitofp i32 %3 to double
  ret double %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @u2d(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = uitofp i32 %3 to double
  ret double %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local double @ull2d(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = uitofp i64 %3 to double
  ret double %4
}

; Function Attrs: noinline nounwind uwtable
define dso_local float @ll2f(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = sitofp i64 %3 to float
  ret float %4
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
