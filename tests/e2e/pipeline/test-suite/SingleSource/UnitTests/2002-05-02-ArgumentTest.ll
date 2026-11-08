; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ArgumentTest.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ArgumentTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ArgumentTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [26 x i8] c"%d, %f, %d, %lld, %d, %f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @testfunc(i16 noundef signext %0, float noundef %1, i8 noundef signext %2, i64 noundef %3, i32 noundef %4, double noundef %5) #0 {
  %7 = alloca i16, align 2
  %8 = alloca float, align 4
  %9 = alloca i8, align 1
  %10 = alloca i64, align 8
  %11 = alloca i32, align 4
  %12 = alloca double, align 8
  store i16 %0, ptr %7, align 2, !tbaa !9
  store float %1, ptr %8, align 4, !tbaa !11
  store i8 %2, ptr %9, align 1, !tbaa !13
  store i64 %3, ptr %10, align 8, !tbaa !14
  store i32 %4, ptr %11, align 4, !tbaa !16
  store double %5, ptr %12, align 8, !tbaa !17
  %13 = load i16, ptr %7, align 2, !tbaa !9
  %14 = sext i16 %13 to i32
  %15 = load float, ptr %8, align 4, !tbaa !11
  %16 = fpext float %15 to double
  %17 = load i8, ptr %9, align 1, !tbaa !13
  %18 = sext i8 %17 to i32
  %19 = load i64, ptr %10, align 8, !tbaa !14
  %20 = load i32, ptr %11, align 4, !tbaa !16
  %21 = load double, ptr %12, align 8, !tbaa !17
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %14, double noundef %16, i32 noundef %18, i64 noundef %19, i32 noundef %20, double noundef %21)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @testfunc(i16 noundef signext 12, float noundef 1.245000e+00, i8 noundef signext 120, i64 noundef 123456677890, i32 noundef -10, double noundef 4.500000e+15)
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
!9 = !{!10, !10, i64 0}
!10 = !{!"short", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"float", !7, i64 0}
!13 = !{!7, !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"long long", !7, i64 0}
!16 = !{!6, !6, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"double", !7, i64 0}
