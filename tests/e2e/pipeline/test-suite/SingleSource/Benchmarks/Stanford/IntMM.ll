; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local global i64 0, align 8
@ima = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
@imb = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
@imr = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@value = dso_local global float 0.000000e+00, align 4
@fixed = dso_local global float 0.000000e+00, align 4
@floated = dso_local global float 0.000000e+00, align 4
@permarray = dso_local global [11 x i32] zeroinitializer, align 16
@pctr = dso_local global i32 0, align 4
@tree = dso_local global ptr null, align 8
@stack = dso_local global [4 x i32] zeroinitializer, align 16
@cellspace = dso_local global [19 x %struct.element] zeroinitializer, align 16
@freelist = dso_local global i32 0, align 4
@movesdone = dso_local global i32 0, align 4
@rma = dso_local global [41 x [41 x float]] zeroinitializer, align 16
@rmb = dso_local global [41 x [41 x float]] zeroinitializer, align 16
@rmr = dso_local global [41 x [41 x float]] zeroinitializer, align 16
@piececount = dso_local global [4 x i32] zeroinitializer, align 16
@class = dso_local global [13 x i32] zeroinitializer, align 16
@piecemax = dso_local global [13 x i32] zeroinitializer, align 16
@puzzl = dso_local global [512 x i32] zeroinitializer, align 16
@p = dso_local global [13 x [512 x i32]] zeroinitializer, align 16
@n = dso_local global i32 0, align 4
@kount = dso_local global i32 0, align 4
@sortlist = dso_local global [5001 x i32] zeroinitializer, align 16
@biggest = dso_local global i32 0, align 4
@littlest = dso_local global i32 0, align 4
@top = dso_local global i32 0, align 4
@z = dso_local global [257 x %struct.complex] zeroinitializer, align 16
@w = dso_local global [257 x %struct.complex] zeroinitializer, align 16
@e = dso_local global [130 x %struct.complex] zeroinitializer, align 16
@zr = dso_local global float 0.000000e+00, align 4
@zi = dso_local global float 0.000000e+00, align 4

; Function Attrs: nounwind uwtable
define dso_local void @Initrand() #0 {
  store i64 74755, ptr @seed, align 8, !tbaa !9
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Rand() #0 {
  %1 = load i64, ptr @seed, align 8, !tbaa !9
  %2 = mul nsw i64 %1, 1309
  %3 = add nsw i64 %2, 13849
  %4 = and i64 %3, 65535
  store i64 %4, ptr @seed, align 8, !tbaa !9
  %5 = load i64, ptr @seed, align 8, !tbaa !9
  %6 = trunc i64 %5 to i32
  ret i32 %6
}

; Function Attrs: nounwind uwtable
define dso_local void @Initmatrix(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store i32 1, ptr %4, align 4, !tbaa !14
  br label %6

6:                                                ; preds = %32, %1
  %7 = load i32, ptr %4, align 4, !tbaa !14
  %8 = icmp sle i32 %7, 40
  br i1 %8, label %9, label %35

9:                                                ; preds = %6
  store i32 1, ptr %5, align 4, !tbaa !14
  br label %10

10:                                               ; preds = %28, %9
  %11 = load i32, ptr %5, align 4, !tbaa !14
  %12 = icmp sle i32 %11, 40
  br i1 %12, label %13, label %31

13:                                               ; preds = %10
  %14 = call i32 @Rand()
  store i32 %14, ptr %3, align 4, !tbaa !14
  %15 = load i32, ptr %3, align 4, !tbaa !14
  %16 = load i32, ptr %3, align 4, !tbaa !14
  %17 = sdiv i32 %16, 120
  %18 = mul nsw i32 %17, 120
  %19 = sub nsw i32 %15, %18
  %20 = sub nsw i32 %19, 60
  %21 = load ptr, ptr %2, align 8, !tbaa !11
  %22 = load i32, ptr %4, align 4, !tbaa !14
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [41 x i32], ptr %21, i64 %23
  %25 = load i32, ptr %5, align 4, !tbaa !14
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds [41 x i32], ptr %24, i64 0, i64 %26
  store i32 %20, ptr %27, align 4, !tbaa !14
  br label %28

28:                                               ; preds = %13
  %29 = load i32, ptr %5, align 4, !tbaa !14
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %5, align 4, !tbaa !14
  br label %10, !llvm.loop !15

31:                                               ; preds = %10
  br label %32

32:                                               ; preds = %31
  %33 = load i32, ptr %4, align 4, !tbaa !14
  %34 = add nsw i32 %33, 1
  store i32 %34, ptr %4, align 4, !tbaa !14
  br label %6, !llvm.loop !17

35:                                               ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @Innerproduct(ptr noundef %0, ptr noundef %1, ptr noundef %2, i32 noundef %3, i32 noundef %4) #0 {
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  store ptr %0, ptr %6, align 8, !tbaa !11
  store ptr %1, ptr %7, align 8, !tbaa !11
  store ptr %2, ptr %8, align 8, !tbaa !11
  store i32 %3, ptr %9, align 4, !tbaa !14
  store i32 %4, ptr %10, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %11) #3
  %12 = load ptr, ptr %6, align 8, !tbaa !11
  store i32 0, ptr %12, align 4, !tbaa !14
  store i32 1, ptr %11, align 4, !tbaa !14
  br label %13

13:                                               ; preds = %38, %5
  %14 = load i32, ptr %11, align 4, !tbaa !14
  %15 = icmp sle i32 %14, 40
  br i1 %15, label %16, label %41

16:                                               ; preds = %13
  %17 = load ptr, ptr %6, align 8, !tbaa !11
  %18 = load i32, ptr %17, align 4, !tbaa !14
  %19 = load ptr, ptr %7, align 8, !tbaa !11
  %20 = load i32, ptr %9, align 4, !tbaa !14
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds [41 x i32], ptr %19, i64 %21
  %23 = load i32, ptr %11, align 4, !tbaa !14
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds [41 x i32], ptr %22, i64 0, i64 %24
  %26 = load i32, ptr %25, align 4, !tbaa !14
  %27 = load ptr, ptr %8, align 8, !tbaa !11
  %28 = load i32, ptr %11, align 4, !tbaa !14
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [41 x i32], ptr %27, i64 %29
  %31 = load i32, ptr %10, align 4, !tbaa !14
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds [41 x i32], ptr %30, i64 0, i64 %32
  %34 = load i32, ptr %33, align 4, !tbaa !14
  %35 = mul nsw i32 %26, %34
  %36 = add nsw i32 %18, %35
  %37 = load ptr, ptr %6, align 8, !tbaa !11
  store i32 %36, ptr %37, align 4, !tbaa !14
  br label %38

38:                                               ; preds = %16
  %39 = load i32, ptr %11, align 4, !tbaa !14
  %40 = add nsw i32 %39, 1
  store i32 %40, ptr %11, align 4, !tbaa !14
  br label %13, !llvm.loop !18

41:                                               ; preds = %13
  call void @llvm.lifetime.end.p0(ptr %11) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @Intmm(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @Initrand()
  call void @Initmatrix(ptr noundef @ima)
  call void @Initmatrix(ptr noundef @imb)
  store i32 1, ptr %3, align 4, !tbaa !14
  br label %5

5:                                                ; preds = %25, %1
  %6 = load i32, ptr %3, align 4, !tbaa !14
  %7 = icmp sle i32 %6, 40
  br i1 %7, label %8, label %28

8:                                                ; preds = %5
  store i32 1, ptr %4, align 4, !tbaa !14
  br label %9

9:                                                ; preds = %21, %8
  %10 = load i32, ptr %4, align 4, !tbaa !14
  %11 = icmp sle i32 %10, 40
  br i1 %11, label %12, label %24

12:                                               ; preds = %9
  %13 = load i32, ptr %3, align 4, !tbaa !14
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds [41 x [41 x i32]], ptr @imr, i64 0, i64 %14
  %16 = load i32, ptr %4, align 4, !tbaa !14
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [41 x i32], ptr %15, i64 0, i64 %17
  %19 = load i32, ptr %3, align 4, !tbaa !14
  %20 = load i32, ptr %4, align 4, !tbaa !14
  call void @Innerproduct(ptr noundef %18, ptr noundef @ima, ptr noundef @imb, i32 noundef %19, i32 noundef %20)
  br label %21

21:                                               ; preds = %12
  %22 = load i32, ptr %4, align 4, !tbaa !14
  %23 = add nsw i32 %22, 1
  store i32 %23, ptr %4, align 4, !tbaa !14
  br label %9, !llvm.loop !19

24:                                               ; preds = %9
  br label %25

25:                                               ; preds = %24
  %26 = load i32, ptr %3, align 4, !tbaa !14
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %3, align 4, !tbaa !14
  br label %5, !llvm.loop !20

28:                                               ; preds = %5
  %29 = load i32, ptr %2, align 4, !tbaa !14
  %30 = add nsw i32 %29, 1
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [41 x [41 x i32]], ptr @imr, i64 0, i64 %31
  %33 = load i32, ptr %2, align 4, !tbaa !14
  %34 = add nsw i32 %33, 1
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [41 x i32], ptr %32, i64 0, i64 %35
  %37 = load i32, ptr %36, align 4, !tbaa !14
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %37)
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  ret void
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !14
  br label %3

3:                                                ; preds = %8, %0
  %4 = load i32, ptr %2, align 4, !tbaa !14
  %5 = icmp slt i32 %4, 10
  br i1 %5, label %6, label %11

6:                                                ; preds = %3
  %7 = load i32, ptr %2, align 4, !tbaa !14
  call void @Intmm(i32 noundef %7)
  br label %8

8:                                                ; preds = %6
  %9 = load i32, ptr %2, align 4, !tbaa !14
  %10 = add nsw i32 %9, 1
  store i32 %10, ptr %2, align 4, !tbaa !14
  br label %3, !llvm.loop !21

11:                                               ; preds = %3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

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
!10 = !{!"long", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 int", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16}
!21 = distinct !{!21, !16}
