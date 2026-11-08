; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/spectral-norm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%0.9f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local double @eval_A(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !9
  %5 = load i32, ptr %3, align 4, !tbaa !9
  %6 = load i32, ptr %4, align 4, !tbaa !9
  %7 = add nsw i32 %5, %6
  %8 = load i32, ptr %3, align 4, !tbaa !9
  %9 = load i32, ptr %4, align 4, !tbaa !9
  %10 = add nsw i32 %8, %9
  %11 = add nsw i32 %10, 1
  %12 = mul nsw i32 %7, %11
  %13 = sdiv i32 %12, 2
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = add nsw i32 %13, %14
  %16 = add nsw i32 %15, 1
  %17 = sitofp i32 %16 to double
  %18 = fdiv double 1.000000e+00, %17
  ret double %18
}

; Function Attrs: nounwind uwtable
define dso_local void @eval_A_times_u(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  store ptr %2, ptr %6, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %7) #7
  call void @llvm.lifetime.start.p0(ptr %8) #7
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %41, %3
  %10 = load i32, ptr %7, align 4, !tbaa !9
  %11 = load i32, ptr %4, align 4, !tbaa !9
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %13, label %44

13:                                               ; preds = %9
  %14 = load ptr, ptr %6, align 8, !tbaa !10
  %15 = load i32, ptr %7, align 4, !tbaa !9
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds double, ptr %14, i64 %16
  store double 0.000000e+00, ptr %17, align 8, !tbaa !13
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %18

18:                                               ; preds = %37, %13
  %19 = load i32, ptr %8, align 4, !tbaa !9
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = icmp slt i32 %19, %20
  br i1 %21, label %22, label %40

22:                                               ; preds = %18
  %23 = load i32, ptr %7, align 4, !tbaa !9
  %24 = load i32, ptr %8, align 4, !tbaa !9
  %25 = call double @eval_A(i32 noundef %23, i32 noundef %24)
  %26 = load ptr, ptr %5, align 8, !tbaa !10
  %27 = load i32, ptr %8, align 4, !tbaa !9
  %28 = sext i32 %27 to i64
  %29 = getelementptr inbounds double, ptr %26, i64 %28
  %30 = load double, ptr %29, align 8, !tbaa !13
  %31 = load ptr, ptr %6, align 8, !tbaa !10
  %32 = load i32, ptr %7, align 4, !tbaa !9
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds double, ptr %31, i64 %33
  %35 = load double, ptr %34, align 8, !tbaa !13
  %36 = call double @llvm.fmuladd.f64(double %25, double %30, double %35)
  store double %36, ptr %34, align 8, !tbaa !13
  br label %37

37:                                               ; preds = %22
  %38 = load i32, ptr %8, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %8, align 4, !tbaa !9
  br label %18, !llvm.loop !15

40:                                               ; preds = %18
  br label %41

41:                                               ; preds = %40
  %42 = load i32, ptr %7, align 4, !tbaa !9
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %7, align 4, !tbaa !9
  br label %9, !llvm.loop !17

44:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @eval_At_times_u(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  store ptr %2, ptr %6, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %7) #7
  call void @llvm.lifetime.start.p0(ptr %8) #7
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %41, %3
  %10 = load i32, ptr %7, align 4, !tbaa !9
  %11 = load i32, ptr %4, align 4, !tbaa !9
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %13, label %44

13:                                               ; preds = %9
  %14 = load ptr, ptr %6, align 8, !tbaa !10
  %15 = load i32, ptr %7, align 4, !tbaa !9
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds double, ptr %14, i64 %16
  store double 0.000000e+00, ptr %17, align 8, !tbaa !13
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %18

18:                                               ; preds = %37, %13
  %19 = load i32, ptr %8, align 4, !tbaa !9
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = icmp slt i32 %19, %20
  br i1 %21, label %22, label %40

22:                                               ; preds = %18
  %23 = load i32, ptr %8, align 4, !tbaa !9
  %24 = load i32, ptr %7, align 4, !tbaa !9
  %25 = call double @eval_A(i32 noundef %23, i32 noundef %24)
  %26 = load ptr, ptr %5, align 8, !tbaa !10
  %27 = load i32, ptr %8, align 4, !tbaa !9
  %28 = sext i32 %27 to i64
  %29 = getelementptr inbounds double, ptr %26, i64 %28
  %30 = load double, ptr %29, align 8, !tbaa !13
  %31 = load ptr, ptr %6, align 8, !tbaa !10
  %32 = load i32, ptr %7, align 4, !tbaa !9
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds double, ptr %31, i64 %33
  %35 = load double, ptr %34, align 8, !tbaa !13
  %36 = call double @llvm.fmuladd.f64(double %25, double %30, double %35)
  store double %36, ptr %34, align 8, !tbaa !13
  br label %37

37:                                               ; preds = %22
  %38 = load i32, ptr %8, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %8, align 4, !tbaa !9
  br label %18, !llvm.loop !18

40:                                               ; preds = %18
  br label %41

41:                                               ; preds = %40
  %42 = load i32, ptr %7, align 4, !tbaa !9
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %7, align 4, !tbaa !9
  br label %9, !llvm.loop !19

44:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @eval_AtA_times_u(i32 noundef %0, ptr noundef %1, ptr noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i64, align 8
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  store ptr %2, ptr %6, align 8, !tbaa !10
  %9 = load i32, ptr %4, align 4, !tbaa !9
  %10 = zext i32 %9 to i64
  %11 = call ptr @llvm.stacksave.p0()
  store ptr %11, ptr %7, align 8
  %12 = alloca double, i64 %10, align 16
  store i64 %10, ptr %8, align 8
  %13 = load i32, ptr %4, align 4, !tbaa !9
  %14 = load ptr, ptr %5, align 8, !tbaa !10
  call void @eval_A_times_u(i32 noundef %13, ptr noundef %14, ptr noundef %12)
  %15 = load i32, ptr %4, align 4, !tbaa !9
  %16 = load ptr, ptr %6, align 8, !tbaa !10
  call void @eval_At_times_u(i32 noundef %15, ptr noundef %12, ptr noundef %16)
  %17 = load ptr, ptr %7, align 8
  call void @llvm.stackrestore.p0(ptr %17)
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare ptr @llvm.stacksave.p0() #3

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.stackrestore.p0(ptr) #3

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca double, align 8
  %12 = alloca double, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  %13 = load i32, ptr %4, align 4, !tbaa !9
  %14 = icmp eq i32 %13, 2
  br i1 %14, label %15, label %20

15:                                               ; preds = %2
  %16 = load ptr, ptr %5, align 8, !tbaa !20
  %17 = getelementptr inbounds ptr, ptr %16, i64 1
  %18 = load ptr, ptr %17, align 8, !tbaa !23
  %19 = call i32 @atoi(ptr noundef %18) #8
  br label %21

20:                                               ; preds = %2
  br label %21

21:                                               ; preds = %20, %15
  %22 = phi i32 [ %19, %15 ], [ 2000, %20 ]
  store i32 %22, ptr %7, align 4, !tbaa !9
  %23 = load i32, ptr %7, align 4, !tbaa !9
  %24 = zext i32 %23 to i64
  %25 = call ptr @llvm.stacksave.p0()
  store ptr %25, ptr %8, align 8
  %26 = alloca double, i64 %24, align 16
  store i64 %24, ptr %9, align 8
  %27 = load i32, ptr %7, align 4, !tbaa !9
  %28 = zext i32 %27 to i64
  %29 = alloca double, i64 %28, align 16
  store i64 %28, ptr %10, align 8
  call void @llvm.lifetime.start.p0(ptr %11) #7
  call void @llvm.lifetime.start.p0(ptr %12) #7
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %30

30:                                               ; preds = %38, %21
  %31 = load i32, ptr %6, align 4, !tbaa !9
  %32 = load i32, ptr %7, align 4, !tbaa !9
  %33 = icmp slt i32 %31, %32
  br i1 %33, label %34, label %41

34:                                               ; preds = %30
  %35 = load i32, ptr %6, align 4, !tbaa !9
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds double, ptr %26, i64 %36
  store double 1.000000e+00, ptr %37, align 8, !tbaa !13
  br label %38

38:                                               ; preds = %34
  %39 = load i32, ptr %6, align 4, !tbaa !9
  %40 = add nsw i32 %39, 1
  store i32 %40, ptr %6, align 4, !tbaa !9
  br label %30, !llvm.loop !25

41:                                               ; preds = %30
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %42

42:                                               ; preds = %48, %41
  %43 = load i32, ptr %6, align 4, !tbaa !9
  %44 = icmp slt i32 %43, 10
  br i1 %44, label %45, label %51

45:                                               ; preds = %42
  %46 = load i32, ptr %7, align 4, !tbaa !9
  call void @eval_AtA_times_u(i32 noundef %46, ptr noundef %26, ptr noundef %29)
  %47 = load i32, ptr %7, align 4, !tbaa !9
  call void @eval_AtA_times_u(i32 noundef %47, ptr noundef %29, ptr noundef %26)
  br label %48

48:                                               ; preds = %45
  %49 = load i32, ptr %6, align 4, !tbaa !9
  %50 = add nsw i32 %49, 1
  store i32 %50, ptr %6, align 4, !tbaa !9
  br label %42, !llvm.loop !26

51:                                               ; preds = %42
  store double 0.000000e+00, ptr %12, align 8, !tbaa !13
  store double 0.000000e+00, ptr %11, align 8, !tbaa !13
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %52

52:                                               ; preds = %77, %51
  %53 = load i32, ptr %6, align 4, !tbaa !9
  %54 = load i32, ptr %7, align 4, !tbaa !9
  %55 = icmp slt i32 %53, %54
  br i1 %55, label %56, label %80

56:                                               ; preds = %52
  %57 = load i32, ptr %6, align 4, !tbaa !9
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds double, ptr %26, i64 %58
  %60 = load double, ptr %59, align 8, !tbaa !13
  %61 = load i32, ptr %6, align 4, !tbaa !9
  %62 = sext i32 %61 to i64
  %63 = getelementptr inbounds double, ptr %29, i64 %62
  %64 = load double, ptr %63, align 8, !tbaa !13
  %65 = load double, ptr %11, align 8, !tbaa !13
  %66 = call double @llvm.fmuladd.f64(double %60, double %64, double %65)
  store double %66, ptr %11, align 8, !tbaa !13
  %67 = load i32, ptr %6, align 4, !tbaa !9
  %68 = sext i32 %67 to i64
  %69 = getelementptr inbounds double, ptr %29, i64 %68
  %70 = load double, ptr %69, align 8, !tbaa !13
  %71 = load i32, ptr %6, align 4, !tbaa !9
  %72 = sext i32 %71 to i64
  %73 = getelementptr inbounds double, ptr %29, i64 %72
  %74 = load double, ptr %73, align 8, !tbaa !13
  %75 = load double, ptr %12, align 8, !tbaa !13
  %76 = call double @llvm.fmuladd.f64(double %70, double %74, double %75)
  store double %76, ptr %12, align 8, !tbaa !13
  br label %77

77:                                               ; preds = %56
  %78 = load i32, ptr %6, align 4, !tbaa !9
  %79 = add nsw i32 %78, 1
  store i32 %79, ptr %6, align 4, !tbaa !9
  br label %52, !llvm.loop !27

80:                                               ; preds = %52
  %81 = load double, ptr %11, align 8, !tbaa !13
  %82 = load double, ptr %12, align 8, !tbaa !13
  %83 = fdiv double %81, %82
  %84 = call double @sqrt(double noundef %83) #7
  %85 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %84)
  store i32 0, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %12) #7
  call void @llvm.lifetime.end.p0(ptr %11) #7
  %86 = load ptr, ptr %8, align 8
  call void @llvm.stackrestore.p0(ptr %86)
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  %87 = load i32, ptr %3, align 4
  ret i32 %87
}

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #4 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !23
  %3 = load ptr, ptr %2, align 8, !tbaa !23
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #7
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

declare i32 @printf(ptr noundef, ...) #5

; Function Attrs: nounwind
declare double @sqrt(double noundef) #6

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #6

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
attributes #4 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nounwind }
attributes #8 = { nounwind willreturn memory(read) }

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
!11 = !{!"p1 double", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
!20 = !{!21, !21, i64 0}
!21 = !{!"p2 omnipotent char", !22, i64 0}
!22 = !{!"any p2 pointer", !12, i64 0}
!23 = !{!24, !24, i64 0}
!24 = !{!"p1 omnipotent char", !12, i64 0}
!25 = distinct !{!25, !16}
!26 = distinct !{!26, !16}
!27 = distinct !{!27, !16}
