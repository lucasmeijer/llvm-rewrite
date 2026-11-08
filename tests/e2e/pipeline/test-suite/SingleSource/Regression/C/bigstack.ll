; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/bigstack.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Mixed_struct = type { i32, [10 x double], [10 x [10 x double]], [10 x %struct.Flat_struct] }
%struct.Flat_struct = type { i8, float }

@.str = private unnamed_addr constant [16 x i8] c"Sum(M)  = %.2f\0A\00", align 1
@.str.1 = private unnamed_addr constant [20 x i8] c"Sum(MA[%d]) = %.2f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local double @AddMixed(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca double, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store double 0.000000e+00, ptr %3, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store i32 0, ptr %4, align 4, !tbaa !14
  br label %6

6:                                                ; preds = %18, %1
  %7 = load i32, ptr %4, align 4, !tbaa !14
  %8 = icmp slt i32 %7, 10
  br i1 %8, label %9, label %21

9:                                                ; preds = %6
  %10 = load ptr, ptr %2, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %10, i32 0, i32 1
  %12 = load i32, ptr %4, align 4, !tbaa !14
  %13 = sext i32 %12 to i64
  %14 = getelementptr inbounds [10 x double], ptr %11, i64 0, i64 %13
  %15 = load double, ptr %14, align 8, !tbaa !12
  %16 = load double, ptr %3, align 8, !tbaa !12
  %17 = fadd double %16, %15
  store double %17, ptr %3, align 8, !tbaa !12
  br label %18

18:                                               ; preds = %9
  %19 = load i32, ptr %4, align 4, !tbaa !14
  %20 = add nsw i32 %19, 1
  store i32 %20, ptr %4, align 4, !tbaa !14
  br label %6, !llvm.loop !15

21:                                               ; preds = %6
  store i32 0, ptr %4, align 4, !tbaa !14
  br label %22

22:                                               ; preds = %45, %21
  %23 = load i32, ptr %4, align 4, !tbaa !14
  %24 = icmp slt i32 %23, 10
  br i1 %24, label %25, label %48

25:                                               ; preds = %22
  store i32 0, ptr %5, align 4, !tbaa !14
  br label %26

26:                                               ; preds = %41, %25
  %27 = load i32, ptr %5, align 4, !tbaa !14
  %28 = icmp slt i32 %27, 10
  br i1 %28, label %29, label %44

29:                                               ; preds = %26
  %30 = load ptr, ptr %2, align 8, !tbaa !9
  %31 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %30, i32 0, i32 2
  %32 = load i32, ptr %4, align 4, !tbaa !14
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds [10 x [10 x double]], ptr %31, i64 0, i64 %33
  %35 = load i32, ptr %5, align 4, !tbaa !14
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds [10 x double], ptr %34, i64 0, i64 %36
  %38 = load double, ptr %37, align 8, !tbaa !12
  %39 = load double, ptr %3, align 8, !tbaa !12
  %40 = fadd double %39, %38
  store double %40, ptr %3, align 8, !tbaa !12
  br label %41

41:                                               ; preds = %29
  %42 = load i32, ptr %5, align 4, !tbaa !14
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %5, align 4, !tbaa !14
  br label %26, !llvm.loop !17

44:                                               ; preds = %26
  br label %45

45:                                               ; preds = %44
  %46 = load i32, ptr %4, align 4, !tbaa !14
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %4, align 4, !tbaa !14
  br label %22, !llvm.loop !18

48:                                               ; preds = %22
  store i32 0, ptr %4, align 4, !tbaa !14
  br label %49

49:                                               ; preds = %73, %48
  %50 = load i32, ptr %4, align 4, !tbaa !14
  %51 = icmp slt i32 %50, 10
  br i1 %51, label %52, label %76

52:                                               ; preds = %49
  %53 = load ptr, ptr %2, align 8, !tbaa !9
  %54 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %53, i32 0, i32 3
  %55 = load i32, ptr %4, align 4, !tbaa !14
  %56 = sext i32 %55 to i64
  %57 = getelementptr inbounds [10 x %struct.Flat_struct], ptr %54, i64 0, i64 %56
  %58 = getelementptr inbounds nuw %struct.Flat_struct, ptr %57, i32 0, i32 0
  %59 = load i8, ptr %58, align 8, !tbaa !19
  %60 = sitofp i8 %59 to double
  %61 = load double, ptr %3, align 8, !tbaa !12
  %62 = fadd double %61, %60
  store double %62, ptr %3, align 8, !tbaa !12
  %63 = load ptr, ptr %2, align 8, !tbaa !9
  %64 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %63, i32 0, i32 3
  %65 = load i32, ptr %4, align 4, !tbaa !14
  %66 = sext i32 %65 to i64
  %67 = getelementptr inbounds [10 x %struct.Flat_struct], ptr %64, i64 0, i64 %66
  %68 = getelementptr inbounds nuw %struct.Flat_struct, ptr %67, i32 0, i32 1
  %69 = load float, ptr %68, align 4, !tbaa !22
  %70 = fpext float %69 to double
  %71 = load double, ptr %3, align 8, !tbaa !12
  %72 = fadd double %71, %70
  store double %72, ptr %3, align 8, !tbaa !12
  br label %73

73:                                               ; preds = %52
  %74 = load i32, ptr %4, align 4, !tbaa !14
  %75 = add nsw i32 %74, 1
  store i32 %75, ptr %4, align 4, !tbaa !14
  br label %49, !llvm.loop !23

76:                                               ; preds = %49
  %77 = load double, ptr %3, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  ret double %77
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @InitializeMixed(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %5, align 4, !tbaa !14
  br label %7

7:                                                ; preds = %20, %2
  %8 = load i32, ptr %5, align 4, !tbaa !14
  %9 = icmp slt i32 %8, 10
  br i1 %9, label %10, label %23

10:                                               ; preds = %7
  %11 = load i32, ptr %5, align 4, !tbaa !14
  %12 = load i32, ptr %4, align 4, !tbaa !14
  %13 = add nsw i32 %11, %12
  %14 = sitofp i32 %13 to double
  %15 = load ptr, ptr %3, align 8, !tbaa !9
  %16 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %15, i32 0, i32 1
  %17 = load i32, ptr %5, align 4, !tbaa !14
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [10 x double], ptr %16, i64 0, i64 %18
  store double %14, ptr %19, align 8, !tbaa !12
  br label %20

20:                                               ; preds = %10
  %21 = load i32, ptr %5, align 4, !tbaa !14
  %22 = add nsw i32 %21, 1
  store i32 %22, ptr %5, align 4, !tbaa !14
  br label %7, !llvm.loop !24

23:                                               ; preds = %7
  store i32 0, ptr %5, align 4, !tbaa !14
  br label %24

24:                                               ; preds = %51, %23
  %25 = load i32, ptr %5, align 4, !tbaa !14
  %26 = icmp slt i32 %25, 10
  br i1 %26, label %27, label %54

27:                                               ; preds = %24
  store i32 0, ptr %6, align 4, !tbaa !14
  br label %28

28:                                               ; preds = %47, %27
  %29 = load i32, ptr %6, align 4, !tbaa !14
  %30 = icmp slt i32 %29, 10
  br i1 %30, label %31, label %50

31:                                               ; preds = %28
  %32 = load i32, ptr %5, align 4, !tbaa !14
  %33 = mul nsw i32 %32, 10
  %34 = load i32, ptr %6, align 4, !tbaa !14
  %35 = add nsw i32 %33, %34
  %36 = load i32, ptr %4, align 4, !tbaa !14
  %37 = add nsw i32 %35, %36
  %38 = sitofp i32 %37 to double
  %39 = load ptr, ptr %3, align 8, !tbaa !9
  %40 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %39, i32 0, i32 2
  %41 = load i32, ptr %5, align 4, !tbaa !14
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds [10 x [10 x double]], ptr %40, i64 0, i64 %42
  %44 = load i32, ptr %6, align 4, !tbaa !14
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [10 x double], ptr %43, i64 0, i64 %45
  store double %38, ptr %46, align 8, !tbaa !12
  br label %47

47:                                               ; preds = %31
  %48 = load i32, ptr %6, align 4, !tbaa !14
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %6, align 4, !tbaa !14
  br label %28, !llvm.loop !25

50:                                               ; preds = %28
  br label %51

51:                                               ; preds = %50
  %52 = load i32, ptr %5, align 4, !tbaa !14
  %53 = add nsw i32 %52, 1
  store i32 %53, ptr %5, align 4, !tbaa !14
  br label %24, !llvm.loop !26

54:                                               ; preds = %24
  store i32 0, ptr %5, align 4, !tbaa !14
  br label %55

55:                                               ; preds = %76, %54
  %56 = load i32, ptr %5, align 4, !tbaa !14
  %57 = icmp slt i32 %56, 10
  br i1 %57, label %58, label %79

58:                                               ; preds = %55
  %59 = load ptr, ptr %3, align 8, !tbaa !9
  %60 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %59, i32 0, i32 3
  %61 = load i32, ptr %5, align 4, !tbaa !14
  %62 = sext i32 %61 to i64
  %63 = getelementptr inbounds [10 x %struct.Flat_struct], ptr %60, i64 0, i64 %62
  %64 = getelementptr inbounds nuw %struct.Flat_struct, ptr %63, i32 0, i32 0
  store i8 81, ptr %64, align 8, !tbaa !19
  %65 = load i32, ptr %5, align 4, !tbaa !14
  %66 = sdiv i32 %65, 10
  %67 = load i32, ptr %4, align 4, !tbaa !14
  %68 = add nsw i32 %66, %67
  %69 = sitofp i32 %68 to float
  %70 = load ptr, ptr %3, align 8, !tbaa !9
  %71 = getelementptr inbounds nuw %struct.Mixed_struct, ptr %70, i32 0, i32 3
  %72 = load i32, ptr %5, align 4, !tbaa !14
  %73 = sext i32 %72 to i64
  %74 = getelementptr inbounds [10 x %struct.Flat_struct], ptr %71, i64 0, i64 %73
  %75 = getelementptr inbounds nuw %struct.Flat_struct, ptr %74, i32 0, i32 1
  store float %69, ptr %75, align 4, !tbaa !22
  br label %76

76:                                               ; preds = %58
  %77 = load i32, ptr %5, align 4, !tbaa !14
  %78 = add nsw i32 %77, 1
  store i32 %78, ptr %5, align 4, !tbaa !14
  br label %55, !llvm.loop !27

79:                                               ; preds = %55
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca %struct.Mixed_struct, align 8
  %7 = alloca [4 x %struct.Mixed_struct], align 16
  %8 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !14
  store ptr %1, ptr %5, align 8, !tbaa !28
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  call void @InitializeMixed(ptr noundef %6, i32 noundef 100)
  %9 = call double @AddMixed(ptr noundef %6)
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %9)
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %11

11:                                               ; preds = %27, %2
  %12 = load i32, ptr %8, align 4, !tbaa !14
  %13 = icmp slt i32 %12, 4
  br i1 %13, label %14, label %30

14:                                               ; preds = %11
  %15 = load i32, ptr %8, align 4, !tbaa !14
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds [4 x %struct.Mixed_struct], ptr %7, i64 0, i64 %16
  %18 = load i32, ptr %8, align 4, !tbaa !14
  %19 = add nsw i32 %18, 2
  %20 = mul nsw i32 100, %19
  call void @InitializeMixed(ptr noundef %17, i32 noundef %20)
  %21 = load i32, ptr %8, align 4, !tbaa !14
  %22 = load i32, ptr %8, align 4, !tbaa !14
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [4 x %struct.Mixed_struct], ptr %7, i64 0, i64 %23
  %25 = call double @AddMixed(ptr noundef %24)
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %21, double noundef %25)
  br label %27

27:                                               ; preds = %14
  %28 = load i32, ptr %8, align 4, !tbaa !14
  %29 = add nsw i32 %28, 1
  store i32 %29, ptr %8, align 4, !tbaa !14
  br label %11, !llvm.loop !31

30:                                               ; preds = %11
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

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
!10 = !{!"p1 _ZTS12Mixed_struct", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"double", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = !{!20, !7, i64 0}
!20 = !{!"Flat_struct", !7, i64 0, !21, i64 4}
!21 = !{!"float", !7, i64 0}
!22 = !{!20, !21, i64 4}
!23 = distinct !{!23, !16}
!24 = distinct !{!24, !16}
!25 = distinct !{!25, !16}
!26 = distinct !{!26, !16}
!27 = distinct !{!27, !16}
!28 = !{!29, !29, i64 0}
!29 = !{!"p2 omnipotent char", !30, i64 0}
!30 = !{!"any p2 pointer", !11, i64 0}
!31 = distinct !{!31, !16}
