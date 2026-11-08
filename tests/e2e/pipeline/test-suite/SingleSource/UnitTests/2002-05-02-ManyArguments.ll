; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ManyArguments.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ManyArguments.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-ManyArguments.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [20 x i8] c"%d, %d, %f, %f, %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [24 x i8] c"%d, %ld, %ld, %d, %lld\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @printfn(i32 noundef %0, i16 noundef signext %1, double noundef %2, float noundef %3, i8 noundef signext %4, i8 noundef signext %5, ptr noundef %6, ptr noundef %7, i32 noundef %8, i64 noundef %9) #0 {
  %11 = alloca i32, align 4
  %12 = alloca i16, align 2
  %13 = alloca double, align 8
  %14 = alloca float, align 4
  %15 = alloca i8, align 1
  %16 = alloca i8, align 1
  %17 = alloca ptr, align 8
  %18 = alloca ptr, align 8
  %19 = alloca i32, align 4
  %20 = alloca i64, align 8
  store i32 %0, ptr %11, align 4, !tbaa !9
  store i16 %1, ptr %12, align 2, !tbaa !10
  store double %2, ptr %13, align 8, !tbaa !12
  store float %3, ptr %14, align 4, !tbaa !14
  store i8 %4, ptr %15, align 1, !tbaa !16
  store i8 %5, ptr %16, align 1, !tbaa !16
  store ptr %6, ptr %17, align 8, !tbaa !17
  store ptr %7, ptr %18, align 8, !tbaa !19
  store i32 %8, ptr %19, align 4, !tbaa !9
  store i64 %9, ptr %20, align 8, !tbaa !21
  %21 = load i32, ptr %11, align 4, !tbaa !9
  %22 = load i16, ptr %12, align 2, !tbaa !10
  %23 = sext i16 %22 to i32
  %24 = load double, ptr %13, align 8, !tbaa !12
  %25 = load float, ptr %14, align 4, !tbaa !14
  %26 = fpext float %25 to double
  %27 = load i8, ptr %15, align 1, !tbaa !16
  %28 = sext i8 %27 to i32
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %21, i32 noundef %23, double noundef %24, double noundef %26, i32 noundef %28)
  %30 = load i8, ptr %16, align 1, !tbaa !16
  %31 = sext i8 %30 to i32
  %32 = load ptr, ptr %17, align 8, !tbaa !17
  %33 = ptrtoint ptr %32 to i64
  %34 = load ptr, ptr %18, align 8, !tbaa !19
  %35 = ptrtoint ptr %34 to i64
  %36 = load i32, ptr %19, align 4, !tbaa !9
  %37 = load i64, ptr %20, align 8, !tbaa !21
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %31, i64 noundef %33, i64 noundef %35, i32 noundef %36, i64 noundef %37)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @printfn(i32 noundef 12, i16 noundef signext 2, double noundef 1.232340e+02, float noundef f0x4499E3F1, i8 noundef signext -12, i8 noundef signext 23, ptr noundef inttoptr (i64 123456 to ptr), ptr noundef null, i32 noundef 1234567, i64 noundef 123124124124)
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
!11 = !{!"short", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"double", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"float", !7, i64 0}
!16 = !{!7, !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"any pointer", !7, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"p1 double", !18, i64 0}
!21 = !{!22, !22, i64 0}
!22 = !{!"long long", !7, i64 0}
