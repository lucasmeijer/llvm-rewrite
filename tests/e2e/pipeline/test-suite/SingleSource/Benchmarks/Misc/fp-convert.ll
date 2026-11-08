; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"Total is %g\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local double @loop(ptr noundef %0, ptr noundef %1, i64 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca double, align 8
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !9
  store i64 %2, ptr %6, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %7) #4
  call void @llvm.lifetime.start.p0(ptr %8) #4
  store double 0.000000e+00, ptr %8, align 8, !tbaa !14
  store i64 0, ptr %7, align 8, !tbaa !12
  br label %9

9:                                                ; preds = %26, %3
  %10 = load i64, ptr %7, align 8, !tbaa !12
  %11 = load i64, ptr %6, align 8, !tbaa !12
  %12 = icmp slt i64 %10, %11
  br i1 %12, label %13, label %29

13:                                               ; preds = %9
  %14 = load ptr, ptr %4, align 8, !tbaa !9
  %15 = load i64, ptr %7, align 8, !tbaa !12
  %16 = getelementptr inbounds float, ptr %14, i64 %15
  %17 = load float, ptr %16, align 4, !tbaa !16
  %18 = fpext float %17 to double
  %19 = load ptr, ptr %5, align 8, !tbaa !9
  %20 = load i64, ptr %7, align 8, !tbaa !12
  %21 = getelementptr inbounds float, ptr %19, i64 %20
  %22 = load float, ptr %21, align 4, !tbaa !16
  %23 = fpext float %22 to double
  %24 = load double, ptr %8, align 8, !tbaa !14
  %25 = call double @llvm.fmuladd.f64(double %18, double %23, double %24)
  store double %25, ptr %8, align 8, !tbaa !14
  br label %26

26:                                               ; preds = %13
  %27 = load i64, ptr %7, align 8, !tbaa !12
  %28 = add nsw i64 %27, 1
  store i64 %28, ptr %7, align 8, !tbaa !12
  br label %9, !llvm.loop !18

29:                                               ; preds = %9
  %30 = load double, ptr %8, align 8, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  ret double %30
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca [2048 x float], align 16
  %9 = alloca [2048 x float], align 16
  %10 = alloca double, align 8
  %11 = alloca float, align 4
  %12 = alloca float, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !20
  store ptr %1, ptr %5, align 8, !tbaa !21
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  call void @llvm.lifetime.start.p0(ptr %8) #4
  call void @llvm.lifetime.start.p0(ptr %9) #4
  call void @llvm.lifetime.start.p0(ptr %10) #4
  store double 0.000000e+00, ptr %10, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %11) #4
  store float 0.000000e+00, ptr %11, align 4, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %12) #4
  store float 1.000000e+00, ptr %12, align 4, !tbaa !16
  store i32 0, ptr %6, align 4, !tbaa !20
  br label %13

13:                                               ; preds = %54, %2
  %14 = load i32, ptr %6, align 4, !tbaa !20
  %15 = icmp slt i32 %14, 500000
  br i1 %15, label %16, label %57

16:                                               ; preds = %13
  %17 = load i32, ptr %6, align 4, !tbaa !20
  %18 = srem i32 %17, 10
  %19 = icmp ne i32 %18, 0
  br i1 %19, label %20, label %21

20:                                               ; preds = %16
  store float 0.000000e+00, ptr %11, align 4, !tbaa !16
  store float 1.000000e+00, ptr %12, align 4, !tbaa !16
  br label %26

21:                                               ; preds = %16
  %22 = load float, ptr %11, align 4, !tbaa !16
  %23 = fadd float %22, 1.000000e-01
  store float %23, ptr %11, align 4, !tbaa !16
  %24 = load float, ptr %12, align 4, !tbaa !16
  %25 = fadd float %24, 2.000000e-01
  store float %25, ptr %12, align 4, !tbaa !16
  br label %26

26:                                               ; preds = %21, %20
  store i32 0, ptr %7, align 4, !tbaa !20
  br label %27

27:                                               ; preds = %45, %26
  %28 = load i32, ptr %7, align 4, !tbaa !20
  %29 = icmp slt i32 %28, 2048
  br i1 %29, label %30, label %48

30:                                               ; preds = %27
  %31 = load float, ptr %11, align 4, !tbaa !16
  %32 = load i32, ptr %7, align 4, !tbaa !20
  %33 = sitofp i32 %32 to float
  %34 = fadd float %31, %33
  %35 = load i32, ptr %7, align 4, !tbaa !20
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds [2048 x float], ptr %8, i64 0, i64 %36
  store float %34, ptr %37, align 4, !tbaa !16
  %38 = load float, ptr %12, align 4, !tbaa !16
  %39 = load i32, ptr %7, align 4, !tbaa !20
  %40 = sitofp i32 %39 to float
  %41 = fadd float %38, %40
  %42 = load i32, ptr %7, align 4, !tbaa !20
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds [2048 x float], ptr %9, i64 0, i64 %43
  store float %41, ptr %44, align 4, !tbaa !16
  br label %45

45:                                               ; preds = %30
  %46 = load i32, ptr %7, align 4, !tbaa !20
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %7, align 4, !tbaa !20
  br label %27, !llvm.loop !24

48:                                               ; preds = %27
  %49 = getelementptr inbounds [2048 x float], ptr %8, i64 0, i64 0
  %50 = getelementptr inbounds [2048 x float], ptr %9, i64 0, i64 0
  %51 = call double @loop(ptr noundef %49, ptr noundef %50, i64 noundef 2048)
  %52 = load double, ptr %10, align 8, !tbaa !14
  %53 = fadd double %52, %51
  store double %53, ptr %10, align 8, !tbaa !14
  br label %54

54:                                               ; preds = %48
  %55 = load i32, ptr %6, align 4, !tbaa !20
  %56 = add nsw i32 %55, 1
  store i32 %56, ptr %6, align 4, !tbaa !20
  br label %13, !llvm.loop !25

57:                                               ; preds = %13
  %58 = load double, ptr %10, align 8, !tbaa !14
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %58)
  call void @llvm.lifetime.end.p0(ptr %12) #4
  call void @llvm.lifetime.end.p0(ptr %11) #4
  call void @llvm.lifetime.end.p0(ptr %10) #4
  call void @llvm.lifetime.end.p0(ptr %9) #4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!"p1 float", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"long", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"float", !7, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = !{!6, !6, i64 0}
!21 = !{!22, !22, i64 0}
!22 = !{!"p2 omnipotent char", !23, i64 0}
!23 = !{!"any p2 pointer", !11, i64 0}
!24 = distinct !{!24, !19}
!25 = distinct !{!25, !19}
