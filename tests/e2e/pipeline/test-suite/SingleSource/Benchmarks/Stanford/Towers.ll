; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local global i64 0, align 8
@.str = private unnamed_addr constant [22 x i8] c" Error in Towers: %s\0A\00", align 1
@stack = dso_local global [4 x i32] zeroinitializer, align 16
@freelist = dso_local global i32 0, align 4
@cellspace = dso_local global [19 x %struct.element] zeroinitializer, align 16
@.str.1 = private unnamed_addr constant [16 x i8] c"out of space   \00", align 1
@.str.2 = private unnamed_addr constant [16 x i8] c"disc size error\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"nothing to pop \00", align 1
@movesdone = dso_local global i32 0, align 4
@.str.4 = private unnamed_addr constant [19 x i8] c" Error in Towers.\0A\00", align 1
@.str.5 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@value = dso_local global float 0.000000e+00, align 4
@fixed = dso_local global float 0.000000e+00, align 4
@floated = dso_local global float 0.000000e+00, align 4
@permarray = dso_local global [11 x i32] zeroinitializer, align 16
@pctr = dso_local global i32 0, align 4
@tree = dso_local global ptr null, align 8
@ima = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
@imb = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
@imr = dso_local global [41 x [41 x i32]] zeroinitializer, align 16
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
define dso_local void @Error(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !11
  %3 = load ptr, ptr %2, align 8, !tbaa !11
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %3)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local void @Makenull(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !14
  %3 = load i32, ptr %2, align 4, !tbaa !14
  %4 = sext i32 %3 to i64
  %5 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %4
  store i32 0, ptr %5, align 4, !tbaa !14
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Getelement() #0 {
  %1 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %1) #3
  store i32 0, ptr %1, align 4, !tbaa !14
  %2 = load i32, ptr @freelist, align 4, !tbaa !14
  %3 = icmp sgt i32 %2, 0
  br i1 %3, label %4, label %11

4:                                                ; preds = %0
  %5 = load i32, ptr @freelist, align 4, !tbaa !14
  store i32 %5, ptr %1, align 4, !tbaa !14
  %6 = load i32, ptr @freelist, align 4, !tbaa !14
  %7 = sext i32 %6 to i64
  %8 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %7
  %9 = getelementptr inbounds nuw %struct.element, ptr %8, i32 0, i32 1
  %10 = load i32, ptr %9, align 4, !tbaa !15
  store i32 %10, ptr @freelist, align 4, !tbaa !14
  br label %12

11:                                               ; preds = %0
  call void @Error(ptr noundef @.str.1)
  br label %12

12:                                               ; preds = %11, %4
  %13 = load i32, ptr %1, align 4, !tbaa !14
  call void @llvm.lifetime.end.p0(ptr %1) #3
  ret i32 %13
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nounwind uwtable
define dso_local void @Push(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !14
  store i32 %1, ptr %4, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %5, align 4, !tbaa !14
  %7 = load i32, ptr %4, align 4, !tbaa !14
  %8 = sext i32 %7 to i64
  %9 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %8
  %10 = load i32, ptr %9, align 4, !tbaa !14
  %11 = icmp sgt i32 %10, 0
  br i1 %11, label %12, label %25

12:                                               ; preds = %2
  %13 = load i32, ptr %4, align 4, !tbaa !14
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %14
  %16 = load i32, ptr %15, align 4, !tbaa !14
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %17
  %19 = getelementptr inbounds nuw %struct.element, ptr %18, i32 0, i32 0
  %20 = load i32, ptr %19, align 8, !tbaa !17
  %21 = load i32, ptr %3, align 4, !tbaa !14
  %22 = icmp sle i32 %20, %21
  br i1 %22, label %23, label %24

23:                                               ; preds = %12
  store i32 1, ptr %5, align 4, !tbaa !14
  call void @Error(ptr noundef @.str.2)
  br label %24

24:                                               ; preds = %23, %12
  br label %25

25:                                               ; preds = %24, %2
  %26 = load i32, ptr %5, align 4, !tbaa !14
  %27 = icmp ne i32 %26, 0
  br i1 %27, label %47, label %28

28:                                               ; preds = %25
  %29 = call i32 @Getelement()
  store i32 %29, ptr %6, align 4, !tbaa !14
  %30 = load i32, ptr %4, align 4, !tbaa !14
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %31
  %33 = load i32, ptr %32, align 4, !tbaa !14
  %34 = load i32, ptr %6, align 4, !tbaa !14
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %35
  %37 = getelementptr inbounds nuw %struct.element, ptr %36, i32 0, i32 1
  store i32 %33, ptr %37, align 4, !tbaa !15
  %38 = load i32, ptr %6, align 4, !tbaa !14
  %39 = load i32, ptr %4, align 4, !tbaa !14
  %40 = sext i32 %39 to i64
  %41 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %40
  store i32 %38, ptr %41, align 4, !tbaa !14
  %42 = load i32, ptr %3, align 4, !tbaa !14
  %43 = load i32, ptr %6, align 4, !tbaa !14
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %44
  %46 = getelementptr inbounds nuw %struct.element, ptr %45, i32 0, i32 0
  store i32 %42, ptr %46, align 8, !tbaa !17
  br label %47

47:                                               ; preds = %28, %25
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @Init(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !14
  store i32 %1, ptr %4, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %6 = load i32, ptr %3, align 4, !tbaa !14
  call void @Makenull(i32 noundef %6)
  %7 = load i32, ptr %4, align 4, !tbaa !14
  store i32 %7, ptr %5, align 4, !tbaa !14
  br label %8

8:                                                ; preds = %14, %2
  %9 = load i32, ptr %5, align 4, !tbaa !14
  %10 = icmp sge i32 %9, 1
  br i1 %10, label %11, label %17

11:                                               ; preds = %8
  %12 = load i32, ptr %5, align 4, !tbaa !14
  %13 = load i32, ptr %3, align 4, !tbaa !14
  call void @Push(i32 noundef %12, i32 noundef %13)
  br label %14

14:                                               ; preds = %11
  %15 = load i32, ptr %5, align 4, !tbaa !14
  %16 = add nsw i32 %15, -1
  store i32 %16, ptr %5, align 4, !tbaa !14
  br label %8, !llvm.loop !18

17:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %5) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @Pop(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %7 = load i32, ptr %3, align 4, !tbaa !14
  %8 = sext i32 %7 to i64
  %9 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %8
  %10 = load i32, ptr %9, align 4, !tbaa !14
  %11 = icmp sgt i32 %10, 0
  br i1 %11, label %12, label %46

12:                                               ; preds = %1
  %13 = load i32, ptr %3, align 4, !tbaa !14
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %14
  %16 = load i32, ptr %15, align 4, !tbaa !14
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %17
  %19 = getelementptr inbounds nuw %struct.element, ptr %18, i32 0, i32 0
  %20 = load i32, ptr %19, align 8, !tbaa !17
  store i32 %20, ptr %5, align 4, !tbaa !14
  %21 = load i32, ptr %3, align 4, !tbaa !14
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %22
  %24 = load i32, ptr %23, align 4, !tbaa !14
  %25 = sext i32 %24 to i64
  %26 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %25
  %27 = getelementptr inbounds nuw %struct.element, ptr %26, i32 0, i32 1
  %28 = load i32, ptr %27, align 4, !tbaa !15
  store i32 %28, ptr %4, align 4, !tbaa !14
  %29 = load i32, ptr @freelist, align 4, !tbaa !14
  %30 = load i32, ptr %3, align 4, !tbaa !14
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %31
  %33 = load i32, ptr %32, align 4, !tbaa !14
  %34 = sext i32 %33 to i64
  %35 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %34
  %36 = getelementptr inbounds nuw %struct.element, ptr %35, i32 0, i32 1
  store i32 %29, ptr %36, align 4, !tbaa !15
  %37 = load i32, ptr %3, align 4, !tbaa !14
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %38
  %40 = load i32, ptr %39, align 4, !tbaa !14
  store i32 %40, ptr @freelist, align 4, !tbaa !14
  %41 = load i32, ptr %4, align 4, !tbaa !14
  %42 = load i32, ptr %3, align 4, !tbaa !14
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds [4 x i32], ptr @stack, i64 0, i64 %43
  store i32 %41, ptr %44, align 4, !tbaa !14
  %45 = load i32, ptr %5, align 4, !tbaa !14
  store i32 %45, ptr %2, align 4
  store i32 1, ptr %6, align 4
  br label %48

46:                                               ; preds = %1
  call void @Error(ptr noundef @.str.3)
  br label %47

47:                                               ; preds = %46
  store i32 0, ptr %2, align 4
  store i32 1, ptr %6, align 4
  br label %48

48:                                               ; preds = %47, %12
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  %49 = load i32, ptr %2, align 4
  ret i32 %49
}

; Function Attrs: nounwind uwtable
define dso_local void @Move(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !14
  store i32 %1, ptr %4, align 4, !tbaa !14
  %5 = load i32, ptr %3, align 4, !tbaa !14
  %6 = call i32 @Pop(i32 noundef %5)
  %7 = load i32, ptr %4, align 4, !tbaa !14
  call void @Push(i32 noundef %6, i32 noundef %7)
  %8 = load i32, ptr @movesdone, align 4, !tbaa !14
  %9 = add nsw i32 %8, 1
  store i32 %9, ptr @movesdone, align 4, !tbaa !14
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @tower(i32 noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 %0, ptr %4, align 4, !tbaa !14
  store i32 %1, ptr %5, align 4, !tbaa !14
  store i32 %2, ptr %6, align 4, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %7) #3
  %8 = load i32, ptr %6, align 4, !tbaa !14
  %9 = icmp eq i32 %8, 1
  br i1 %9, label %10, label %13

10:                                               ; preds = %3
  %11 = load i32, ptr %4, align 4, !tbaa !14
  %12 = load i32, ptr %5, align 4, !tbaa !14
  call void @Move(i32 noundef %11, i32 noundef %12)
  br label %28

13:                                               ; preds = %3
  %14 = load i32, ptr %4, align 4, !tbaa !14
  %15 = sub nsw i32 6, %14
  %16 = load i32, ptr %5, align 4, !tbaa !14
  %17 = sub nsw i32 %15, %16
  store i32 %17, ptr %7, align 4, !tbaa !14
  %18 = load i32, ptr %4, align 4, !tbaa !14
  %19 = load i32, ptr %7, align 4, !tbaa !14
  %20 = load i32, ptr %6, align 4, !tbaa !14
  %21 = sub nsw i32 %20, 1
  call void @tower(i32 noundef %18, i32 noundef %19, i32 noundef %21)
  %22 = load i32, ptr %4, align 4, !tbaa !14
  %23 = load i32, ptr %5, align 4, !tbaa !14
  call void @Move(i32 noundef %22, i32 noundef %23)
  %24 = load i32, ptr %7, align 4, !tbaa !14
  %25 = load i32, ptr %5, align 4, !tbaa !14
  %26 = load i32, ptr %6, align 4, !tbaa !14
  %27 = sub nsw i32 %26, 1
  call void @tower(i32 noundef %24, i32 noundef %25, i32 noundef %27)
  br label %28

28:                                               ; preds = %13, %10
  call void @llvm.lifetime.end.p0(ptr %7) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @Towers() #0 {
  %1 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %1) #3
  store i32 1, ptr %1, align 4, !tbaa !14
  br label %2

2:                                                ; preds = %12, %0
  %3 = load i32, ptr %1, align 4, !tbaa !14
  %4 = icmp sle i32 %3, 18
  br i1 %4, label %5, label %15

5:                                                ; preds = %2
  %6 = load i32, ptr %1, align 4, !tbaa !14
  %7 = sub nsw i32 %6, 1
  %8 = load i32, ptr %1, align 4, !tbaa !14
  %9 = sext i32 %8 to i64
  %10 = getelementptr inbounds [19 x %struct.element], ptr @cellspace, i64 0, i64 %9
  %11 = getelementptr inbounds nuw %struct.element, ptr %10, i32 0, i32 1
  store i32 %7, ptr %11, align 4, !tbaa !15
  br label %12

12:                                               ; preds = %5
  %13 = load i32, ptr %1, align 4, !tbaa !14
  %14 = add nsw i32 %13, 1
  store i32 %14, ptr %1, align 4, !tbaa !14
  br label %2, !llvm.loop !20

15:                                               ; preds = %2
  store i32 18, ptr @freelist, align 4, !tbaa !14
  call void @Init(i32 noundef 1, i32 noundef 14)
  call void @Makenull(i32 noundef 2)
  call void @Makenull(i32 noundef 3)
  store i32 0, ptr @movesdone, align 4, !tbaa !14
  call void @tower(i32 noundef 1, i32 noundef 2, i32 noundef 14)
  %16 = load i32, ptr @movesdone, align 4, !tbaa !14
  %17 = icmp ne i32 %16, 16383
  br i1 %17, label %18, label %20

18:                                               ; preds = %15
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  br label %20

20:                                               ; preds = %18, %15
  %21 = load i32, ptr @movesdone, align 4, !tbaa !14
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %21)
  call void @llvm.lifetime.end.p0(ptr %1) #3
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !14
  br label %3

3:                                                ; preds = %7, %0
  %4 = load i32, ptr %2, align 4, !tbaa !14
  %5 = icmp slt i32 %4, 100
  br i1 %5, label %6, label %10

6:                                                ; preds = %3
  call void @Towers()
  br label %7

7:                                                ; preds = %6
  %8 = load i32, ptr %2, align 4, !tbaa !14
  %9 = add nsw i32 %8, 1
  store i32 %9, ptr %2, align 4, !tbaa !14
  br label %3, !llvm.loop !21

10:                                               ; preds = %3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!12 = !{!"p1 omnipotent char", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = !{!16, !6, i64 4}
!16 = !{!"element", !6, i64 0, !6, i64 4}
!17 = !{!16, !6, i64 0}
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.mustprogress"}
!20 = distinct !{!20, !19}
!21 = distinct !{!21, !19}
