; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-05-CastFPToUint.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [30 x i8] c"DC = %lf, DS = %lf, DI = %lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [27 x i8] c"uc = %u, us = %u, ui = %u\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca double, align 8
  %7 = alloca double, align 8
  %8 = alloca double, align 8
  %9 = alloca i8, align 1
  %10 = alloca i16, align 2
  %11 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %12 = call double @getDC()
  store double %12, ptr %6, align 8
  %13 = call double @getDS()
  store double %13, ptr %7, align 8
  %14 = call double @getDI()
  store double %14, ptr %8, align 8
  %15 = load double, ptr %6, align 8
  %16 = fptoui double %15 to i8
  store i8 %16, ptr %9, align 1
  %17 = load double, ptr %7, align 8
  %18 = fptoui double %17 to i16
  store i16 %18, ptr %10, align 2
  %19 = load double, ptr %8, align 8
  %20 = fptoui double %19 to i32
  store i32 %20, ptr %11, align 4
  %21 = load double, ptr %6, align 8
  %22 = load double, ptr %7, align 8
  %23 = load double, ptr %8, align 8
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %21, double noundef %22, double noundef %23)
  %25 = load i8, ptr %9, align 1
  %26 = zext i8 %25 to i32
  %27 = load i16, ptr %10, align 2
  %28 = zext i16 %27 to i32
  %29 = load i32, ptr %11, align 4
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %26, i32 noundef %28, i32 noundef %29)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal double @getDC() #0 {
  ret double 2.400000e+02
}

; Function Attrs: noinline nounwind uwtable
define internal double @getDS() #0 {
  ret double 6.552000e+04
}

; Function Attrs: noinline nounwind uwtable
define internal double @getDI() #0 {
  ret double f0x41EFFFFFFE000000
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
