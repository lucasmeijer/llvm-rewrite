; @source: tests/e2e/src/structs/array_of_structs.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/array_of_structs.c'
source_filename = "tests/e2e/src/structs/array_of_structs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.item = type { ptr, i32, double }

@.str = private unnamed_addr constant [6 x i8] c"%.2f\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%s\0A\00", align 1
@.str.2 = private unnamed_addr constant [6 x i8] c"apple\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"pear\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"fig\00", align 1
@.str.5 = private unnamed_addr constant [5 x i8] c"kiwi\00", align 1
@inv = internal global [4 x { ptr, i32, [4 x i8], double }] [{ ptr, i32, [4 x i8], double } { ptr @.str.2, i32 3, [4 x i8] zeroinitializer, double 5.000000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.3, i32 10, [4 x i8] zeroinitializer, double 7.500000e-01 }, { ptr, i32, [4 x i8], double } { ptr @.str.4, i32 2, [4 x i8] zeroinitializer, double 2.250000e+00 }, { ptr, i32, [4 x i8], double } { ptr @.str.5, i32 7, [4 x i8] zeroinitializer, double 3.000000e-01 }], align 16

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca %struct.item, align 8
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %5

5:                                                ; preds = %17, %0
  %6 = load i32, ptr %2, align 4, !tbaa !9
  %7 = icmp slt i32 %6, 4
  br i1 %7, label %9, label %8

8:                                                ; preds = %5
  call void @llvm.lifetime.end.p0(ptr %2) #4
  br label %20

9:                                                ; preds = %5
  %10 = load i32, ptr %2, align 4, !tbaa !9
  %11 = load i32, ptr %2, align 4, !tbaa !9
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %12
  %14 = getelementptr inbounds nuw %struct.item, ptr %13, i32 0, i32 1
  %15 = load i32, ptr %14, align 8, !tbaa !10
  %16 = add nsw i32 %15, %10
  store i32 %16, ptr %14, align 8, !tbaa !10
  br label %17

17:                                               ; preds = %9
  %18 = load i32, ptr %2, align 4, !tbaa !9
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %2, align 4, !tbaa !9
  br label %5, !llvm.loop !15

20:                                               ; preds = %8
  %21 = call double @total(ptr noundef @inv, i32 noundef 4)
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %21)
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 16 @inv, i64 24, i1 false), !tbaa.struct !17
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i32 1, ptr %4, align 4, !tbaa !9
  br label %23

23:                                               ; preds = %52, %20
  %24 = load i32, ptr %4, align 4, !tbaa !9
  %25 = icmp slt i32 %24, 4
  br i1 %25, label %27, label %26

26:                                               ; preds = %23
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %55

27:                                               ; preds = %23
  %28 = load i32, ptr %4, align 4, !tbaa !9
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %29
  %31 = getelementptr inbounds nuw %struct.item, ptr %30, i32 0, i32 1
  %32 = load i32, ptr %31, align 8, !tbaa !10
  %33 = sitofp i32 %32 to double
  %34 = load i32, ptr %4, align 4, !tbaa !9
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %35
  %37 = getelementptr inbounds nuw %struct.item, ptr %36, i32 0, i32 2
  %38 = load double, ptr %37, align 8, !tbaa !20
  %39 = fmul double %33, %38
  %40 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 1
  %41 = load i32, ptr %40, align 8, !tbaa !10
  %42 = sitofp i32 %41 to double
  %43 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 2
  %44 = load double, ptr %43, align 8, !tbaa !20
  %45 = fmul double %42, %44
  %46 = fcmp ogt double %39, %45
  br i1 %46, label %47, label %51

47:                                               ; preds = %27
  %48 = load i32, ptr %4, align 4, !tbaa !9
  %49 = sext i32 %48 to i64
  %50 = getelementptr inbounds [4 x %struct.item], ptr @inv, i64 0, i64 %49
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 %50, i64 24, i1 false), !tbaa.struct !17
  br label %51

51:                                               ; preds = %47, %27
  br label %52

52:                                               ; preds = %51
  %53 = load i32, ptr %4, align 4, !tbaa !9
  %54 = add nsw i32 %53, 1
  store i32 %54, ptr %4, align 4, !tbaa !9
  br label %23, !llvm.loop !21

55:                                               ; preds = %26
  %56 = getelementptr inbounds nuw %struct.item, ptr %3, i32 0, i32 0
  %57 = load ptr, ptr %56, align 8, !tbaa !22
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, ptr noundef %57)
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal double @total(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca double, align 8
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !23
  store i32 %1, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store double 0.000000e+00, ptr %5, align 8, !tbaa !19
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i32 0, ptr %6, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %28, %2
  %8 = load i32, ptr %6, align 4, !tbaa !9
  %9 = load i32, ptr %4, align 4, !tbaa !9
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %12, label %11

11:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %6) #4
  br label %31

12:                                               ; preds = %7
  %13 = load ptr, ptr %3, align 8, !tbaa !23
  %14 = load i32, ptr %6, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds %struct.item, ptr %13, i64 %15
  %17 = getelementptr inbounds nuw %struct.item, ptr %16, i32 0, i32 1
  %18 = load i32, ptr %17, align 8, !tbaa !10
  %19 = sitofp i32 %18 to double
  %20 = load ptr, ptr %3, align 8, !tbaa !23
  %21 = load i32, ptr %6, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds %struct.item, ptr %20, i64 %22
  %24 = getelementptr inbounds nuw %struct.item, ptr %23, i32 0, i32 2
  %25 = load double, ptr %24, align 8, !tbaa !20
  %26 = load double, ptr %5, align 8, !tbaa !19
  %27 = call double @llvm.fmuladd.f64(double %19, double %25, double %26)
  store double %27, ptr %5, align 8, !tbaa !19
  br label %28

28:                                               ; preds = %12
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %6, align 4, !tbaa !9
  br label %7, !llvm.loop !25

31:                                               ; preds = %11
  %32 = load double, ptr %5, align 8, !tbaa !19
  call void @llvm.lifetime.end.p0(ptr %5) #4
  ret double %32
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!10 = !{!11, !6, i64 8}
!11 = !{!"item", !12, i64 0, !6, i64 8, !14, i64 16}
!12 = !{!"p1 omnipotent char", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{i64 0, i64 8, !18, i64 8, i64 4, !9, i64 16, i64 8, !19}
!18 = !{!12, !12, i64 0}
!19 = !{!14, !14, i64 0}
!20 = !{!11, !14, i64 16}
!21 = distinct !{!21, !16}
!22 = !{!11, !12, i64 0}
!23 = !{!24, !24, i64 0}
!24 = !{!"p1 _ZTS4item", !13, i64 0}
!25 = distinct !{!25, !16}
