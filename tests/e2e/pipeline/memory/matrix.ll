; @source: tests/e2e/src/memory/matrix.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/matrix.c'
source_filename = "tests/e2e/src/memory/matrix.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = internal global [12 x [12 x double]] zeroinitializer, align 16
@b = internal global [12 x [12 x double]] zeroinitializer, align 16
@c = internal global [12 x [12 x double]] zeroinitializer, align 16
@.str = private unnamed_addr constant [11 x i8] c"%.3f %.3f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca double, align 8
  %8 = alloca i32, align 4
  %9 = alloca double, align 8
  %10 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %11

11:                                               ; preds = %47, %0
  %12 = load i32, ptr %2, align 4, !tbaa !9
  %13 = icmp slt i32 %12, 12
  br i1 %13, label %15, label %14

14:                                               ; preds = %11
  store i32 2, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  br label %50

15:                                               ; preds = %11
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %16

16:                                               ; preds = %43, %15
  %17 = load i32, ptr %4, align 4, !tbaa !9
  %18 = icmp slt i32 %17, 12
  br i1 %18, label %20, label %19

19:                                               ; preds = %16
  store i32 5, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %46

20:                                               ; preds = %16
  %21 = load i32, ptr %2, align 4, !tbaa !9
  %22 = sitofp i32 %21 to double
  %23 = load i32, ptr %4, align 4, !tbaa !9
  %24 = sitofp i32 %23 to double
  %25 = call double @llvm.fmuladd.f64(double %24, double 5.000000e-01, double %22)
  %26 = load i32, ptr %2, align 4, !tbaa !9
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [12 x [12 x double]], ptr @a, i64 0, i64 %27
  %29 = load i32, ptr %4, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [12 x double], ptr %28, i64 0, i64 %30
  store double %25, ptr %31, align 8, !tbaa !10
  %32 = load i32, ptr %2, align 4, !tbaa !9
  %33 = load i32, ptr %4, align 4, !tbaa !9
  %34 = icmp eq i32 %32, %33
  %35 = zext i1 %34 to i64
  %36 = select i1 %34, double 2.000000e+00, double 2.500000e-01
  %37 = load i32, ptr %2, align 4, !tbaa !9
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds [12 x [12 x double]], ptr @b, i64 0, i64 %38
  %40 = load i32, ptr %4, align 4, !tbaa !9
  %41 = sext i32 %40 to i64
  %42 = getelementptr inbounds [12 x double], ptr %39, i64 0, i64 %41
  store double %36, ptr %42, align 8, !tbaa !10
  br label %43

43:                                               ; preds = %20
  %44 = load i32, ptr %4, align 4, !tbaa !9
  %45 = add nsw i32 %44, 1
  store i32 %45, ptr %4, align 4, !tbaa !9
  br label %16, !llvm.loop !12

46:                                               ; preds = %19
  br label %47

47:                                               ; preds = %46
  %48 = load i32, ptr %2, align 4, !tbaa !9
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %2, align 4, !tbaa !9
  br label %11, !llvm.loop !14

50:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %51

51:                                               ; preds = %97, %50
  %52 = load i32, ptr %5, align 4, !tbaa !9
  %53 = icmp slt i32 %52, 12
  br i1 %53, label %55, label %54

54:                                               ; preds = %51
  store i32 8, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %100

55:                                               ; preds = %51
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %56

56:                                               ; preds = %93, %55
  %57 = load i32, ptr %6, align 4, !tbaa !9
  %58 = icmp slt i32 %57, 12
  br i1 %58, label %60, label %59

59:                                               ; preds = %56
  store i32 11, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  br label %96

60:                                               ; preds = %56
  call void @llvm.lifetime.start.p0(ptr %7) #4
  store double 0.000000e+00, ptr %7, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %8) #4
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %61

61:                                               ; preds = %82, %60
  %62 = load i32, ptr %8, align 4, !tbaa !9
  %63 = icmp slt i32 %62, 12
  br i1 %63, label %65, label %64

64:                                               ; preds = %61
  store i32 14, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %8) #4
  br label %85

65:                                               ; preds = %61
  %66 = load i32, ptr %5, align 4, !tbaa !9
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds [12 x [12 x double]], ptr @a, i64 0, i64 %67
  %69 = load i32, ptr %8, align 4, !tbaa !9
  %70 = sext i32 %69 to i64
  %71 = getelementptr inbounds [12 x double], ptr %68, i64 0, i64 %70
  %72 = load double, ptr %71, align 8, !tbaa !10
  %73 = load i32, ptr %8, align 4, !tbaa !9
  %74 = sext i32 %73 to i64
  %75 = getelementptr inbounds [12 x [12 x double]], ptr @b, i64 0, i64 %74
  %76 = load i32, ptr %6, align 4, !tbaa !9
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds [12 x double], ptr %75, i64 0, i64 %77
  %79 = load double, ptr %78, align 8, !tbaa !10
  %80 = load double, ptr %7, align 8, !tbaa !10
  %81 = call double @llvm.fmuladd.f64(double %72, double %79, double %80)
  store double %81, ptr %7, align 8, !tbaa !10
  br label %82

82:                                               ; preds = %65
  %83 = load i32, ptr %8, align 4, !tbaa !9
  %84 = add nsw i32 %83, 1
  store i32 %84, ptr %8, align 4, !tbaa !9
  br label %61, !llvm.loop !15

85:                                               ; preds = %64
  %86 = load double, ptr %7, align 8, !tbaa !10
  %87 = load i32, ptr %5, align 4, !tbaa !9
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds [12 x [12 x double]], ptr @c, i64 0, i64 %88
  %90 = load i32, ptr %6, align 4, !tbaa !9
  %91 = sext i32 %90 to i64
  %92 = getelementptr inbounds [12 x double], ptr %89, i64 0, i64 %91
  store double %86, ptr %92, align 8, !tbaa !10
  call void @llvm.lifetime.end.p0(ptr %7) #4
  br label %93

93:                                               ; preds = %85
  %94 = load i32, ptr %6, align 4, !tbaa !9
  %95 = add nsw i32 %94, 1
  store i32 %95, ptr %6, align 4, !tbaa !9
  br label %56, !llvm.loop !16

96:                                               ; preds = %59
  br label %97

97:                                               ; preds = %96
  %98 = load i32, ptr %5, align 4, !tbaa !9
  %99 = add nsw i32 %98, 1
  store i32 %99, ptr %5, align 4, !tbaa !9
  br label %51, !llvm.loop !17

100:                                              ; preds = %54
  call void @llvm.lifetime.start.p0(ptr %9) #4
  store double 0.000000e+00, ptr %9, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %10) #4
  store i32 0, ptr %10, align 4, !tbaa !9
  br label %101

101:                                              ; preds = %115, %100
  %102 = load i32, ptr %10, align 4, !tbaa !9
  %103 = icmp slt i32 %102, 12
  br i1 %103, label %105, label %104

104:                                              ; preds = %101
  store i32 17, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %10) #4
  br label %118

105:                                              ; preds = %101
  %106 = load i32, ptr %10, align 4, !tbaa !9
  %107 = sext i32 %106 to i64
  %108 = getelementptr inbounds [12 x [12 x double]], ptr @c, i64 0, i64 %107
  %109 = load i32, ptr %10, align 4, !tbaa !9
  %110 = sext i32 %109 to i64
  %111 = getelementptr inbounds [12 x double], ptr %108, i64 0, i64 %110
  %112 = load double, ptr %111, align 8, !tbaa !10
  %113 = load double, ptr %9, align 8, !tbaa !10
  %114 = fadd double %113, %112
  store double %114, ptr %9, align 8, !tbaa !10
  br label %115

115:                                              ; preds = %105
  %116 = load i32, ptr %10, align 4, !tbaa !9
  %117 = add nsw i32 %116, 1
  store i32 %117, ptr %10, align 4, !tbaa !9
  br label %101, !llvm.loop !18

118:                                              ; preds = %104
  %119 = load double, ptr %9, align 8, !tbaa !10
  %120 = load double, ptr getelementptr inbounds nuw (i8, ptr @c, i64 344), align 8, !tbaa !10
  %121 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %119, double noundef %120)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %3, align 4
  call void @llvm.lifetime.end.p0(ptr %9) #4
  %122 = load i32, ptr %1, align 4
  ret i32 %122
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"double", !7, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = distinct !{!14, !13}
!15 = distinct !{!15, !13}
!16 = distinct !{!16, !13}
!17 = distinct !{!17, !13}
!18 = distinct !{!18, !13}
