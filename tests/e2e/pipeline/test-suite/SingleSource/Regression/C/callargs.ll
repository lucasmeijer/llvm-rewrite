; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/callargs.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/callargs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/callargs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [36 x i8] c"\0AprintArgsNoRet with 15 arguments:\0A\00", align 1
@.str.1 = private unnamed_addr constant [29 x i8] c"\09Args 1-5  : %d %f %c %f %c\0A\00", align 1
@.str.2 = private unnamed_addr constant [29 x i8] c"\09Args 6-10 : %d %f %c %f %c\0A\00", align 1
@.str.3 = private unnamed_addr constant [29 x i8] c"\09Args 11-14: %d %f %c %f %c\0A\00", align 1
@.str.4 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.5 = private unnamed_addr constant [2 x i8] c"e\00", align 1
@.str.6 = private unnamed_addr constant [2 x i8] c"j\00", align 1
@.str.7 = private unnamed_addr constant [2 x i8] c"o\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @printArgsNoRet(i32 noundef %0, float noundef %1, i8 noundef signext %2, double noundef %3, ptr noundef %4, i32 noundef %5, float noundef %6, i8 noundef signext %7, double noundef %8, ptr noundef %9, i32 noundef %10, float noundef %11, i8 noundef signext %12, double noundef %13, ptr noundef %14) #0 {
  %16 = alloca i32, align 4
  %17 = alloca float, align 4
  %18 = alloca i8, align 1
  %19 = alloca double, align 8
  %20 = alloca ptr, align 8
  %21 = alloca i32, align 4
  %22 = alloca float, align 4
  %23 = alloca i8, align 1
  %24 = alloca double, align 8
  %25 = alloca ptr, align 8
  %26 = alloca i32, align 4
  %27 = alloca float, align 4
  %28 = alloca i8, align 1
  %29 = alloca double, align 8
  %30 = alloca ptr, align 8
  store i32 %0, ptr %16, align 4, !tbaa !9
  store float %1, ptr %17, align 4, !tbaa !10
  store i8 %2, ptr %18, align 1, !tbaa !12
  store double %3, ptr %19, align 8, !tbaa !13
  store ptr %4, ptr %20, align 8, !tbaa !15
  store i32 %5, ptr %21, align 4, !tbaa !9
  store float %6, ptr %22, align 4, !tbaa !10
  store i8 %7, ptr %23, align 1, !tbaa !12
  store double %8, ptr %24, align 8, !tbaa !13
  store ptr %9, ptr %25, align 8, !tbaa !15
  store i32 %10, ptr %26, align 4, !tbaa !9
  store float %11, ptr %27, align 4, !tbaa !10
  store i8 %12, ptr %28, align 1, !tbaa !12
  store double %13, ptr %29, align 8, !tbaa !13
  store ptr %14, ptr %30, align 8, !tbaa !15
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  %32 = load i32, ptr %16, align 4, !tbaa !9
  %33 = load float, ptr %17, align 4, !tbaa !10
  %34 = fpext float %33 to double
  %35 = load i8, ptr %18, align 1, !tbaa !12
  %36 = sext i8 %35 to i32
  %37 = load double, ptr %19, align 8, !tbaa !13
  %38 = load ptr, ptr %20, align 8, !tbaa !15
  %39 = load i8, ptr %38, align 1, !tbaa !12
  %40 = sext i8 %39 to i32
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %32, double noundef %34, i32 noundef %36, double noundef %37, i32 noundef %40)
  %42 = load i32, ptr %21, align 4, !tbaa !9
  %43 = load float, ptr %22, align 4, !tbaa !10
  %44 = fpext float %43 to double
  %45 = load i8, ptr %23, align 1, !tbaa !12
  %46 = sext i8 %45 to i32
  %47 = load double, ptr %24, align 8, !tbaa !13
  %48 = load ptr, ptr %25, align 8, !tbaa !15
  %49 = load i8, ptr %48, align 1, !tbaa !12
  %50 = sext i8 %49 to i32
  %51 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %42, double noundef %44, i32 noundef %46, double noundef %47, i32 noundef %50)
  %52 = load i32, ptr %26, align 4, !tbaa !9
  %53 = load float, ptr %27, align 4, !tbaa !10
  %54 = fpext float %53 to double
  %55 = load i8, ptr %28, align 1, !tbaa !12
  %56 = sext i8 %55 to i32
  %57 = load double, ptr %29, align 8, !tbaa !13
  %58 = load ptr, ptr %30, align 8, !tbaa !15
  %59 = load i8, ptr %58, align 1, !tbaa !12
  %60 = sext i8 %59 to i32
  %61 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %52, double noundef %54, i32 noundef %56, double noundef %57, i32 noundef %60)
  %62 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !18
  call void @printArgsNoRet(i32 noundef 1, float noundef 2.100000e+00, i8 noundef signext 99, double noundef 4.100000e+00, ptr noundef @.str.5, i32 noundef 6, float noundef 7.100000e+00, i8 noundef signext 104, double noundef 9.100000e+00, ptr noundef @.str.6, i32 noundef 11, float noundef 1.210000e+01, i8 noundef signext 109, double noundef 1.410000e+01, ptr noundef @.str.7)
  ret i32 0
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"float", !7, i64 0}
!12 = !{!7, !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"p1 omnipotent char", !17, i64 0}
!17 = !{!"any pointer", !7, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"p2 omnipotent char", !20, i64 0}
!20 = !{!"any p2 pointer", !17, i64 0}
