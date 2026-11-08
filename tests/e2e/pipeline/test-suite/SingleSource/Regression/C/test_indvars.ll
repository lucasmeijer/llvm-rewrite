; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/test_indvars.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [18 x i8] c"Checksum = %.0lf\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [100 x [200 x i32]], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store double 0.000000e+00, ptr %5, align 8, !tbaa !9
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %6

6:                                                ; preds = %24, %0
  %7 = load i32, ptr %3, align 4, !tbaa !11
  %8 = icmp slt i32 %7, 100
  br i1 %8, label %9, label %27

9:                                                ; preds = %6
  store i32 0, ptr %4, align 4, !tbaa !11
  br label %10

10:                                               ; preds = %20, %9
  %11 = load i32, ptr %4, align 4, !tbaa !11
  %12 = icmp slt i32 %11, 200
  br i1 %12, label %13, label %23

13:                                               ; preds = %10
  %14 = load i32, ptr %3, align 4, !tbaa !11
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 %15
  %17 = load i32, ptr %4, align 4, !tbaa !11
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [200 x i32], ptr %16, i64 0, i64 %18
  store i32 0, ptr %19, align 4, !tbaa !11
  br label %20

20:                                               ; preds = %13
  %21 = load i32, ptr %4, align 4, !tbaa !11
  %22 = add nsw i32 %21, 1
  store i32 %22, ptr %4, align 4, !tbaa !11
  br label %10, !llvm.loop !12

23:                                               ; preds = %10
  br label %24

24:                                               ; preds = %23
  %25 = load i32, ptr %3, align 4, !tbaa !11
  %26 = add nsw i32 %25, 2
  store i32 %26, ptr %3, align 4, !tbaa !11
  br label %6, !llvm.loop !14

27:                                               ; preds = %6
  %28 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 0
  %29 = getelementptr inbounds [200 x i32], ptr %28, i64 0, i64 0
  %30 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 0
  call void @test_indvars(ptr noundef %29, ptr noundef %30)
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %31

31:                                               ; preds = %53, %27
  %32 = load i32, ptr %3, align 4, !tbaa !11
  %33 = icmp slt i32 %32, 100
  br i1 %33, label %34, label %56

34:                                               ; preds = %31
  store i32 0, ptr %4, align 4, !tbaa !11
  br label %35

35:                                               ; preds = %49, %34
  %36 = load i32, ptr %4, align 4, !tbaa !11
  %37 = icmp slt i32 %36, 200
  br i1 %37, label %38, label %52

38:                                               ; preds = %35
  %39 = load i32, ptr %3, align 4, !tbaa !11
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds [100 x [200 x i32]], ptr %2, i64 0, i64 %40
  %42 = load i32, ptr %4, align 4, !tbaa !11
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds [200 x i32], ptr %41, i64 0, i64 %43
  %45 = load i32, ptr %44, align 4, !tbaa !11
  %46 = sitofp i32 %45 to double
  %47 = load double, ptr %5, align 8, !tbaa !9
  %48 = fadd double %47, %46
  store double %48, ptr %5, align 8, !tbaa !9
  br label %49

49:                                               ; preds = %38
  %50 = load i32, ptr %4, align 4, !tbaa !11
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %4, align 4, !tbaa !11
  br label %35, !llvm.loop !15

52:                                               ; preds = %35
  br label %53

53:                                               ; preds = %52
  %54 = load i32, ptr %3, align 4, !tbaa !11
  %55 = add nsw i32 %54, 2
  store i32 %55, ptr %3, align 4, !tbaa !11
  br label %31, !llvm.loop !16

56:                                               ; preds = %31
  %57 = load double, ptr %5, align 8, !tbaa !9
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %57)
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal void @test_indvars(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !17
  store ptr %1, ptr %4, align 8, !tbaa !17
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %7 = load ptr, ptr %4, align 8, !tbaa !17
  %8 = getelementptr inbounds [200 x i32], ptr %7, i64 3
  %9 = getelementptr inbounds [200 x i32], ptr %8, i64 0, i64 6
  store i32 12345, ptr %9, align 4, !tbaa !11
  %10 = load ptr, ptr %3, align 8, !tbaa !17
  %11 = getelementptr inbounds i32, ptr %10, i64 1
  store i32 12345, ptr %11, align 4, !tbaa !11
  store i32 0, ptr %5, align 4, !tbaa !11
  br label %12

12:                                               ; preds = %21, %2
  %13 = load i32, ptr %5, align 4, !tbaa !11
  %14 = icmp ult i32 %13, 100
  br i1 %14, label %15, label %24

15:                                               ; preds = %12
  %16 = load i32, ptr %5, align 4, !tbaa !11
  %17 = load ptr, ptr %3, align 8, !tbaa !17
  %18 = load i32, ptr %5, align 4, !tbaa !11
  %19 = zext i32 %18 to i64
  %20 = getelementptr inbounds nuw i32, ptr %17, i64 %19
  store i32 %16, ptr %20, align 4, !tbaa !11
  br label %21

21:                                               ; preds = %15
  %22 = load i32, ptr %5, align 4, !tbaa !11
  %23 = add i32 %22, 2
  store i32 %23, ptr %5, align 4, !tbaa !11
  br label %12, !llvm.loop !20

24:                                               ; preds = %12
  store i32 3, ptr %5, align 4, !tbaa !11
  br label %25

25:                                               ; preds = %35, %24
  %26 = load i32, ptr %5, align 4, !tbaa !11
  %27 = icmp ult i32 %26, 103
  br i1 %27, label %28, label %38

28:                                               ; preds = %25
  %29 = load i32, ptr %5, align 4, !tbaa !11
  %30 = add i32 %29, 4
  %31 = load ptr, ptr %3, align 8, !tbaa !17
  %32 = load i32, ptr %5, align 4, !tbaa !11
  %33 = zext i32 %32 to i64
  %34 = getelementptr inbounds nuw i32, ptr %31, i64 %33
  store i32 %30, ptr %34, align 4, !tbaa !11
  br label %35

35:                                               ; preds = %28
  %36 = load i32, ptr %5, align 4, !tbaa !11
  %37 = add i32 %36, 1
  store i32 %37, ptr %5, align 4, !tbaa !11
  br label %25, !llvm.loop !21

38:                                               ; preds = %25
  store i32 13, ptr %5, align 4, !tbaa !11
  br label %39

39:                                               ; preds = %67, %38
  %40 = load i32, ptr %5, align 4, !tbaa !11
  %41 = icmp ult i32 %40, 100
  br i1 %41, label %42, label %70

42:                                               ; preds = %39
  store i32 0, ptr %6, align 4, !tbaa !11
  br label %43

43:                                               ; preds = %63, %42
  %44 = load i32, ptr %6, align 4, !tbaa !11
  %45 = icmp ult i32 %44, 100
  br i1 %45, label %46, label %66

46:                                               ; preds = %43
  %47 = load ptr, ptr %4, align 8, !tbaa !17
  %48 = load i32, ptr %5, align 4, !tbaa !11
  %49 = zext i32 %48 to i64
  %50 = getelementptr inbounds nuw [200 x i32], ptr %47, i64 %49
  %51 = load i32, ptr %5, align 4, !tbaa !11
  %52 = zext i32 %51 to i64
  %53 = getelementptr inbounds nuw [200 x i32], ptr %50, i64 0, i64 %52
  %54 = load i32, ptr %53, align 4, !tbaa !11
  %55 = load ptr, ptr %4, align 8, !tbaa !17
  %56 = load i32, ptr %5, align 4, !tbaa !11
  %57 = zext i32 %56 to i64
  %58 = getelementptr inbounds nuw [200 x i32], ptr %55, i64 %57
  %59 = load i32, ptr %6, align 4, !tbaa !11
  %60 = udiv i32 %59, 3
  %61 = zext i32 %60 to i64
  %62 = getelementptr inbounds nuw [200 x i32], ptr %58, i64 0, i64 %61
  store i32 %54, ptr %62, align 4, !tbaa !11
  br label %63

63:                                               ; preds = %46
  %64 = load i32, ptr %6, align 4, !tbaa !11
  %65 = add i32 %64, 3
  store i32 %65, ptr %6, align 4, !tbaa !11
  br label %43, !llvm.loop !22

66:                                               ; preds = %43
  br label %67

67:                                               ; preds = %66
  %68 = load i32, ptr %5, align 4, !tbaa !11
  %69 = add i32 %68, 1
  store i32 %69, ptr %5, align 4, !tbaa !11
  br label %39, !llvm.loop !23

70:                                               ; preds = %39
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = distinct !{!14, !13}
!15 = distinct !{!15, !13}
!16 = distinct !{!16, !13}
!17 = !{!18, !18, i64 0}
!18 = !{!"p1 int", !19, i64 0}
!19 = !{!"any pointer", !7, i64 0}
!20 = distinct !{!20, !13}
!21 = distinct !{!21, !13}
!22 = distinct !{!22, !13}
!23 = distinct !{!23, !13}
