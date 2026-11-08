; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Comb = type { i32, i32, i32 }

@stderr = external global ptr, align 8
@.str = private unnamed_addr constant [29 x i8] c"Out of memory for work list\0A\00", align 1
@.str.1 = private unnamed_addr constant [36 x i8] c"Out of memory for combination list\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"%d\00", align 1
@.str.3 = private unnamed_addr constant [2 x i8] c" \00", align 1
@.str.4 = private unnamed_addr constant [2 x i8] c"+\00", align 1
@.str.5 = private unnamed_addr constant [2 x i8] c"-\00", align 1
@.str.6 = private unnamed_addr constant [2 x i8] c"*\00", align 1
@.str.7 = private unnamed_addr constant [2 x i8] c":\00", align 1
@.str.8 = private unnamed_addr constant [6 x i8] c" d%d \00", align 1
@.str.9 = private unnamed_addr constant [6 x i8] c"%d=%d\00", align 1
@.str.10 = private unnamed_addr constant [3 x i8] c"; \00", align 1
@.str.11 = private unnamed_addr constant [3 x i8] c".\0A\00", align 1
@.str.12 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.13 = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@stopSearch = internal global i32 0, align 4
@nbNodes = internal global i32 0, align 4
@dmax = internal global i32 0, align 4
@workList = internal global ptr null, align 8
@listLength = internal global i32 0, align 4
@goal = internal global i32 0, align 4
@best = internal global i32 0, align 4
@bestDepth = internal global i32 0, align 4
@solution = internal global ptr null, align 8
@combList = internal global ptr null, align 8
@stdin = external global ptr, align 8

; Function Attrs: nounwind uwtable
define dso_local ptr @newWorkList(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #8
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = sext i32 %4 to i64
  %6 = call noalias ptr @calloc(i64 noundef %5, i64 noundef 4) #9
  store ptr %6, ptr %3, align 8, !tbaa !10
  %7 = load ptr, ptr %3, align 8, !tbaa !10
  %8 = icmp ne ptr %7, null
  br i1 %8, label %9, label %11

9:                                                ; preds = %1
  %10 = load ptr, ptr %3, align 8, !tbaa !10
  call void @llvm.lifetime.end.p0(ptr %3) #8
  ret ptr %10

11:                                               ; preds = %1
  %12 = load ptr, ptr @stderr, align 8, !tbaa !13
  %13 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %12, ptr noundef @.str) #8
  call void @exit(i32 noundef 1) #10
  unreachable
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #2

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #3

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local ptr @newCombList(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #8
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = sext i32 %4 to i64
  %6 = call noalias ptr @calloc(i64 noundef %5, i64 noundef 12) #9
  store ptr %6, ptr %3, align 8, !tbaa !15
  %7 = load ptr, ptr %3, align 8, !tbaa !15
  %8 = icmp ne ptr %7, null
  br i1 %8, label %9, label %11

9:                                                ; preds = %1
  %10 = load ptr, ptr %3, align 8, !tbaa !15
  call void @llvm.lifetime.end.p0(ptr %3) #8
  ret ptr %10

11:                                               ; preds = %1
  %12 = load ptr, ptr @stderr, align 8, !tbaa !13
  %13 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %12, ptr noundef @.str.1) #8
  call void @exit(i32 noundef 1) #10
  unreachable
}

; Function Attrs: nounwind uwtable
define dso_local void @initWorkList(ptr noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !10
  store ptr %1, ptr %5, align 8, !tbaa !10
  store i32 %2, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #8
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %22, %3
  %9 = load i32, ptr %7, align 4, !tbaa !9
  %10 = load i32, ptr %6, align 4, !tbaa !9
  %11 = icmp slt i32 %9, %10
  br i1 %11, label %12, label %25

12:                                               ; preds = %8
  %13 = load ptr, ptr %5, align 8, !tbaa !10
  %14 = load i32, ptr %7, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds i32, ptr %13, i64 %15
  %17 = load i32, ptr %16, align 4, !tbaa !9
  %18 = load ptr, ptr %4, align 8, !tbaa !10
  %19 = load i32, ptr %7, align 4, !tbaa !9
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds i32, ptr %18, i64 %20
  store i32 %17, ptr %21, align 4, !tbaa !9
  br label %22

22:                                               ; preds = %12
  %23 = load i32, ptr %7, align 4, !tbaa !9
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %7, align 4, !tbaa !9
  br label %8, !llvm.loop !16

25:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %7) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @initCombList(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !15
  store i32 %1, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #8
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %16, %2
  %7 = load i32, ptr %5, align 4, !tbaa !9
  %8 = load i32, ptr %4, align 4, !tbaa !9
  %9 = icmp slt i32 %7, %8
  br i1 %9, label %10, label %19

10:                                               ; preds = %6
  %11 = load ptr, ptr %3, align 8, !tbaa !15
  %12 = load i32, ptr %5, align 4, !tbaa !9
  %13 = sext i32 %12 to i64
  %14 = getelementptr inbounds %struct.Comb, ptr %11, i64 %13
  %15 = getelementptr inbounds nuw %struct.Comb, ptr %14, i32 0, i32 2
  store i32 0, ptr %15, align 4, !tbaa !18
  br label %16

16:                                               ; preds = %10
  %17 = load i32, ptr %5, align 4, !tbaa !9
  %18 = add nsw i32 %17, 1
  store i32 %18, ptr %5, align 4, !tbaa !9
  br label %6, !llvm.loop !20

19:                                               ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %5) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @saveSolution(ptr noundef %0, ptr noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !15
  store ptr %1, ptr %5, align 8, !tbaa !15
  store i32 %2, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #8
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %46, %3
  %9 = load i32, ptr %7, align 4, !tbaa !9
  %10 = load i32, ptr %6, align 4, !tbaa !9
  %11 = icmp slt i32 %9, %10
  br i1 %11, label %12, label %49

12:                                               ; preds = %8
  %13 = load ptr, ptr %5, align 8, !tbaa !15
  %14 = load i32, ptr %7, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds %struct.Comb, ptr %13, i64 %15
  %17 = getelementptr inbounds nuw %struct.Comb, ptr %16, i32 0, i32 0
  %18 = load i32, ptr %17, align 4, !tbaa !21
  %19 = load ptr, ptr %4, align 8, !tbaa !15
  %20 = load i32, ptr %7, align 4, !tbaa !9
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds %struct.Comb, ptr %19, i64 %21
  %23 = getelementptr inbounds nuw %struct.Comb, ptr %22, i32 0, i32 0
  store i32 %18, ptr %23, align 4, !tbaa !21
  %24 = load ptr, ptr %5, align 8, !tbaa !15
  %25 = load i32, ptr %7, align 4, !tbaa !9
  %26 = sext i32 %25 to i64
  %27 = getelementptr inbounds %struct.Comb, ptr %24, i64 %26
  %28 = getelementptr inbounds nuw %struct.Comb, ptr %27, i32 0, i32 1
  %29 = load i32, ptr %28, align 4, !tbaa !22
  %30 = load ptr, ptr %4, align 8, !tbaa !15
  %31 = load i32, ptr %7, align 4, !tbaa !9
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds %struct.Comb, ptr %30, i64 %32
  %34 = getelementptr inbounds nuw %struct.Comb, ptr %33, i32 0, i32 1
  store i32 %29, ptr %34, align 4, !tbaa !22
  %35 = load ptr, ptr %5, align 8, !tbaa !15
  %36 = load i32, ptr %7, align 4, !tbaa !9
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds %struct.Comb, ptr %35, i64 %37
  %39 = getelementptr inbounds nuw %struct.Comb, ptr %38, i32 0, i32 2
  %40 = load i32, ptr %39, align 4, !tbaa !18
  %41 = load ptr, ptr %4, align 8, !tbaa !15
  %42 = load i32, ptr %7, align 4, !tbaa !9
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds %struct.Comb, ptr %41, i64 %43
  %45 = getelementptr inbounds nuw %struct.Comb, ptr %44, i32 0, i32 2
  store i32 %40, ptr %45, align 4, !tbaa !18
  br label %46

46:                                               ; preds = %12
  %47 = load i32, ptr %7, align 4, !tbaa !9
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr %7, align 4, !tbaa !9
  br label %8, !llvm.loop !23

49:                                               ; preds = %8
  %50 = load ptr, ptr %4, align 8, !tbaa !15
  %51 = load i32, ptr %6, align 4, !tbaa !9
  %52 = sext i32 %51 to i64
  %53 = getelementptr inbounds %struct.Comb, ptr %50, i64 %52
  %54 = getelementptr inbounds nuw %struct.Comb, ptr %53, i32 0, i32 2
  store i32 0, ptr %54, align 4, !tbaa !18
  call void @llvm.lifetime.end.p0(ptr %7) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @calculate(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !15
  %4 = load ptr, ptr %3, align 8, !tbaa !15
  %5 = getelementptr inbounds nuw %struct.Comb, ptr %4, i32 0, i32 2
  %6 = load i32, ptr %5, align 4, !tbaa !18
  switch i32 %6, label %39 [
    i32 1, label %7
    i32 2, label %15
    i32 3, label %23
    i32 4, label %31
  ]

7:                                                ; preds = %1
  %8 = load ptr, ptr %3, align 8, !tbaa !15
  %9 = getelementptr inbounds nuw %struct.Comb, ptr %8, i32 0, i32 0
  %10 = load i32, ptr %9, align 4, !tbaa !21
  %11 = load ptr, ptr %3, align 8, !tbaa !15
  %12 = getelementptr inbounds nuw %struct.Comb, ptr %11, i32 0, i32 1
  %13 = load i32, ptr %12, align 4, !tbaa !22
  %14 = add nsw i32 %10, %13
  store i32 %14, ptr %2, align 4
  br label %40

15:                                               ; preds = %1
  %16 = load ptr, ptr %3, align 8, !tbaa !15
  %17 = getelementptr inbounds nuw %struct.Comb, ptr %16, i32 0, i32 0
  %18 = load i32, ptr %17, align 4, !tbaa !21
  %19 = load ptr, ptr %3, align 8, !tbaa !15
  %20 = getelementptr inbounds nuw %struct.Comb, ptr %19, i32 0, i32 1
  %21 = load i32, ptr %20, align 4, !tbaa !22
  %22 = sub nsw i32 %18, %21
  store i32 %22, ptr %2, align 4
  br label %40

23:                                               ; preds = %1
  %24 = load ptr, ptr %3, align 8, !tbaa !15
  %25 = getelementptr inbounds nuw %struct.Comb, ptr %24, i32 0, i32 0
  %26 = load i32, ptr %25, align 4, !tbaa !21
  %27 = load ptr, ptr %3, align 8, !tbaa !15
  %28 = getelementptr inbounds nuw %struct.Comb, ptr %27, i32 0, i32 1
  %29 = load i32, ptr %28, align 4, !tbaa !22
  %30 = mul nsw i32 %26, %29
  store i32 %30, ptr %2, align 4
  br label %40

31:                                               ; preds = %1
  %32 = load ptr, ptr %3, align 8, !tbaa !15
  %33 = getelementptr inbounds nuw %struct.Comb, ptr %32, i32 0, i32 0
  %34 = load i32, ptr %33, align 4, !tbaa !21
  %35 = load ptr, ptr %3, align 8, !tbaa !15
  %36 = getelementptr inbounds nuw %struct.Comb, ptr %35, i32 0, i32 1
  %37 = load i32, ptr %36, align 4, !tbaa !22
  %38 = sdiv i32 %34, %37
  store i32 %38, ptr %2, align 4
  br label %40

39:                                               ; preds = %1
  store i32 0, ptr %2, align 4
  br label %40

40:                                               ; preds = %39, %31, %23, %15, %7
  %41 = load i32, ptr %2, align 4
  ret i32 %41
}

; Function Attrs: nounwind uwtable
define dso_local void @printSolution(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !15
  store i32 %1, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #8
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %64, %2
  %7 = load i32, ptr %5, align 4, !tbaa !9
  %8 = load i32, ptr %4, align 4, !tbaa !9
  %9 = icmp slt i32 %7, %8
  br i1 %9, label %10, label %67

10:                                               ; preds = %6
  %11 = load ptr, ptr %3, align 8, !tbaa !15
  %12 = load i32, ptr %5, align 4, !tbaa !9
  %13 = sext i32 %12 to i64
  %14 = getelementptr inbounds %struct.Comb, ptr %11, i64 %13
  %15 = getelementptr inbounds nuw %struct.Comb, ptr %14, i32 0, i32 0
  %16 = load i32, ptr %15, align 4, !tbaa !21
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %16)
  %18 = load ptr, ptr %3, align 8, !tbaa !15
  %19 = load i32, ptr %5, align 4, !tbaa !9
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds %struct.Comb, ptr %18, i64 %20
  %22 = getelementptr inbounds nuw %struct.Comb, ptr %21, i32 0, i32 2
  %23 = load i32, ptr %22, align 4, !tbaa !18
  switch i32 %23, label %34 [
    i32 0, label %24
    i32 1, label %26
    i32 2, label %28
    i32 3, label %30
    i32 4, label %32
  ]

24:                                               ; preds = %10
  %25 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  br label %42

26:                                               ; preds = %10
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  br label %42

28:                                               ; preds = %10
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.5)
  br label %42

30:                                               ; preds = %10
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str.6)
  br label %42

32:                                               ; preds = %10
  %33 = call i32 (ptr, ...) @printf(ptr noundef @.str.7)
  br label %42

34:                                               ; preds = %10
  %35 = load ptr, ptr %3, align 8, !tbaa !15
  %36 = load i32, ptr %5, align 4, !tbaa !9
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds %struct.Comb, ptr %35, i64 %37
  %39 = getelementptr inbounds nuw %struct.Comb, ptr %38, i32 0, i32 2
  %40 = load i32, ptr %39, align 4, !tbaa !18
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef %40)
  br label %42

42:                                               ; preds = %34, %32, %30, %28, %26, %24
  %43 = load ptr, ptr %3, align 8, !tbaa !15
  %44 = load i32, ptr %5, align 4, !tbaa !9
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds %struct.Comb, ptr %43, i64 %45
  %47 = getelementptr inbounds nuw %struct.Comb, ptr %46, i32 0, i32 1
  %48 = load i32, ptr %47, align 4, !tbaa !22
  %49 = load ptr, ptr %3, align 8, !tbaa !15
  %50 = load i32, ptr %5, align 4, !tbaa !9
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds %struct.Comb, ptr %49, i64 %51
  %53 = call i32 @calculate(ptr noundef %52)
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef %48, i32 noundef %53)
  %55 = load i32, ptr %5, align 4, !tbaa !9
  %56 = load i32, ptr %4, align 4, !tbaa !9
  %57 = sub nsw i32 %56, 1
  %58 = icmp slt i32 %55, %57
  br i1 %58, label %59, label %61

59:                                               ; preds = %42
  %60 = call i32 (ptr, ...) @printf(ptr noundef @.str.10)
  br label %63

61:                                               ; preds = %42
  %62 = call i32 (ptr, ...) @printf(ptr noundef @.str.11)
  br label %63

63:                                               ; preds = %61, %59
  br label %64

64:                                               ; preds = %63
  %65 = load i32, ptr %5, align 4, !tbaa !9
  %66 = add nsw i32 %65, 1
  store i32 %66, ptr %5, align 4, !tbaa !9
  br label %6, !llvm.loop !24

67:                                               ; preds = %6
  %68 = call i32 (ptr, ...) @printf(ptr noundef @.str.12)
  call void @llvm.lifetime.end.p0(ptr %5) #8
  ret void
}

declare i32 @printf(ptr noundef, ...) #5

; Function Attrs: nounwind uwtable
define dso_local void @printList(ptr noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !10
  store i32 %1, ptr %5, align 4, !tbaa !9
  store i32 %2, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #8
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %26, %3
  %9 = load i32, ptr %7, align 4, !tbaa !9
  %10 = load i32, ptr %5, align 4, !tbaa !9
  %11 = icmp slt i32 %9, %10
  br i1 %11, label %12, label %29

12:                                               ; preds = %8
  %13 = load i32, ptr %7, align 4, !tbaa !9
  %14 = shl i32 1, %13
  %15 = load i32, ptr %6, align 4, !tbaa !9
  %16 = and i32 %14, %15
  %17 = icmp ne i32 %16, 0
  br i1 %17, label %18, label %19

18:                                               ; preds = %12
  br label %26

19:                                               ; preds = %12
  %20 = load ptr, ptr %4, align 8, !tbaa !10
  %21 = load i32, ptr %7, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds i32, ptr %20, i64 %22
  %24 = load i32, ptr %23, align 4, !tbaa !9
  %25 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, i32 noundef %24)
  br label %26

26:                                               ; preds = %19, %18
  %27 = load i32, ptr %7, align 4, !tbaa !9
  %28 = add nsw i32 %27, 1
  store i32 %28, ptr %7, align 4, !tbaa !9
  br label %8, !llvm.loop !25

29:                                               ; preds = %8
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.12)
  call void @llvm.lifetime.end.p0(ptr %7) #8
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local void @recSearch(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #8
  call void @llvm.lifetime.start.p0(ptr %6) #8
  call void @llvm.lifetime.start.p0(ptr %7) #8
  call void @llvm.lifetime.start.p0(ptr %8) #8
  %13 = load i32, ptr @stopSearch, align 4, !tbaa !9
  %14 = icmp ne i32 %13, 0
  br i1 %14, label %15, label %16

15:                                               ; preds = %2
  store i32 1, ptr %9, align 4
  br label %196

16:                                               ; preds = %2
  %17 = load i32, ptr @nbNodes, align 4, !tbaa !9
  %18 = add nsw i32 %17, 1
  store i32 %18, ptr @nbNodes, align 4, !tbaa !9
  %19 = load i32, ptr %3, align 4, !tbaa !9
  %20 = load i32, ptr @dmax, align 4, !tbaa !9
  %21 = icmp eq i32 %19, %20
  br i1 %21, label %22, label %60

22:                                               ; preds = %16
  %23 = load ptr, ptr @workList, align 8, !tbaa !10
  %24 = load i32, ptr @listLength, align 4, !tbaa !9
  %25 = load i32, ptr %3, align 4, !tbaa !9
  %26 = add nsw i32 %24, %25
  %27 = sub nsw i32 %26, 1
  %28 = sext i32 %27 to i64
  %29 = getelementptr inbounds i32, ptr %23, i64 %28
  %30 = load i32, ptr %29, align 4, !tbaa !9
  %31 = load i32, ptr @goal, align 4, !tbaa !9
  %32 = sub nsw i32 %30, %31
  %33 = call i32 @llvm.abs.i32(i32 %32, i1 true)
  %34 = load i32, ptr @best, align 4, !tbaa !9
  %35 = load i32, ptr @goal, align 4, !tbaa !9
  %36 = sub nsw i32 %34, %35
  %37 = call i32 @llvm.abs.i32(i32 %36, i1 true)
  %38 = icmp slt i32 %33, %37
  br i1 %38, label %39, label %59

39:                                               ; preds = %22
  %40 = load ptr, ptr @workList, align 8, !tbaa !10
  %41 = load i32, ptr @listLength, align 4, !tbaa !9
  %42 = load i32, ptr %3, align 4, !tbaa !9
  %43 = add nsw i32 %41, %42
  %44 = sub nsw i32 %43, 1
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds i32, ptr %40, i64 %45
  %47 = load i32, ptr %46, align 4, !tbaa !9
  store i32 %47, ptr @best, align 4, !tbaa !9
  %48 = load i32, ptr %3, align 4, !tbaa !9
  store i32 %48, ptr @bestDepth, align 4, !tbaa !9
  %49 = load ptr, ptr @solution, align 8, !tbaa !15
  %50 = load ptr, ptr @combList, align 8, !tbaa !15
  %51 = load i32, ptr %3, align 4, !tbaa !9
  call void @saveSolution(ptr noundef %49, ptr noundef %50, i32 noundef %51)
  %52 = load i32, ptr @best, align 4, !tbaa !9
  %53 = load i32, ptr @goal, align 4, !tbaa !9
  %54 = icmp eq i32 %52, %53
  br i1 %54, label %55, label %58

55:                                               ; preds = %39
  %56 = load ptr, ptr @combList, align 8, !tbaa !15
  %57 = load i32, ptr %3, align 4, !tbaa !9
  call void @printSolution(ptr noundef %56, i32 noundef %57)
  store i32 1, ptr @stopSearch, align 4, !tbaa !9
  br label %58

58:                                               ; preds = %55, %39
  br label %59

59:                                               ; preds = %58, %22
  br label %195

60:                                               ; preds = %16
  call void @llvm.lifetime.start.p0(ptr %10) #8
  call void @llvm.lifetime.start.p0(ptr %11) #8
  call void @llvm.lifetime.start.p0(ptr %12) #8
  store i32 1, ptr %5, align 4, !tbaa !9
  br label %61

61:                                               ; preds = %191, %60
  %62 = load i32, ptr %5, align 4, !tbaa !9
  %63 = icmp sle i32 %62, 4
  br i1 %63, label %64, label %194

64:                                               ; preds = %61
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %65

65:                                               ; preds = %187, %64
  %66 = load i32, ptr %7, align 4, !tbaa !9
  %67 = load i32, ptr @listLength, align 4, !tbaa !9
  %68 = load i32, ptr %3, align 4, !tbaa !9
  %69 = add nsw i32 %67, %68
  %70 = icmp slt i32 %66, %69
  br i1 %70, label %71, label %190

71:                                               ; preds = %65
  %72 = load i32, ptr %7, align 4, !tbaa !9
  %73 = shl i32 1, %72
  %74 = load i32, ptr %4, align 4, !tbaa !9
  %75 = and i32 %73, %74
  %76 = icmp ne i32 %75, 0
  br i1 %76, label %77, label %78

77:                                               ; preds = %71
  br label %187

78:                                               ; preds = %71
  store i32 0, ptr %8, align 4, !tbaa !9
  br label %79

79:                                               ; preds = %183, %78
  %80 = load i32, ptr %8, align 4, !tbaa !9
  %81 = load i32, ptr %7, align 4, !tbaa !9
  %82 = icmp slt i32 %80, %81
  br i1 %82, label %83, label %186

83:                                               ; preds = %79
  %84 = load i32, ptr %8, align 4, !tbaa !9
  %85 = shl i32 1, %84
  %86 = load i32, ptr %4, align 4, !tbaa !9
  %87 = and i32 %85, %86
  %88 = icmp ne i32 %87, 0
  br i1 %88, label %89, label %90

89:                                               ; preds = %83
  br label %183

90:                                               ; preds = %83
  %91 = load ptr, ptr @workList, align 8, !tbaa !10
  %92 = load i32, ptr %7, align 4, !tbaa !9
  %93 = sext i32 %92 to i64
  %94 = getelementptr inbounds i32, ptr %91, i64 %93
  %95 = load i32, ptr %94, align 4, !tbaa !9
  store i32 %95, ptr %10, align 4, !tbaa !9
  %96 = load ptr, ptr @workList, align 8, !tbaa !10
  %97 = load i32, ptr %8, align 4, !tbaa !9
  %98 = sext i32 %97 to i64
  %99 = getelementptr inbounds i32, ptr %96, i64 %98
  %100 = load i32, ptr %99, align 4, !tbaa !9
  store i32 %100, ptr %11, align 4, !tbaa !9
  %101 = load i32, ptr %5, align 4, !tbaa !9
  %102 = icmp eq i32 %101, 3
  br i1 %102, label %106, label %103

103:                                              ; preds = %90
  %104 = load i32, ptr %5, align 4, !tbaa !9
  %105 = icmp eq i32 %104, 4
  br i1 %105, label %106, label %113

106:                                              ; preds = %103, %90
  %107 = load i32, ptr %10, align 4, !tbaa !9
  %108 = icmp eq i32 %107, 1
  br i1 %108, label %112, label %109

109:                                              ; preds = %106
  %110 = load i32, ptr %11, align 4, !tbaa !9
  %111 = icmp eq i32 %110, 1
  br i1 %111, label %112, label %113

112:                                              ; preds = %109, %106
  br label %183

113:                                              ; preds = %109, %103
  %114 = load i32, ptr %10, align 4, !tbaa !9
  %115 = icmp eq i32 %114, 0
  br i1 %115, label %119, label %116

116:                                              ; preds = %113
  %117 = load i32, ptr %11, align 4, !tbaa !9
  %118 = icmp eq i32 %117, 0
  br i1 %118, label %119, label %120

119:                                              ; preds = %116, %113
  br label %183

120:                                              ; preds = %116
  %121 = load i32, ptr %5, align 4, !tbaa !9
  %122 = icmp eq i32 %121, 4
  br i1 %122, label %123, label %129

123:                                              ; preds = %120
  %124 = load i32, ptr %10, align 4, !tbaa !9
  %125 = load i32, ptr %11, align 4, !tbaa !9
  %126 = srem i32 %124, %125
  %127 = icmp ne i32 %126, 0
  br i1 %127, label %128, label %129

128:                                              ; preds = %123
  br label %183

129:                                              ; preds = %123, %120
  %130 = load i32, ptr %5, align 4, !tbaa !9
  %131 = icmp eq i32 %130, 4
  br i1 %131, label %135, label %132

132:                                              ; preds = %129
  %133 = load i32, ptr %5, align 4, !tbaa !9
  %134 = icmp eq i32 %133, 2
  br i1 %134, label %135, label %143

135:                                              ; preds = %132, %129
  %136 = load i32, ptr %10, align 4, !tbaa !9
  %137 = load i32, ptr %11, align 4, !tbaa !9
  %138 = icmp slt i32 %136, %137
  br i1 %138, label %139, label %143

139:                                              ; preds = %135
  %140 = load i32, ptr %10, align 4, !tbaa !9
  store i32 %140, ptr %12, align 4, !tbaa !9
  %141 = load i32, ptr %11, align 4, !tbaa !9
  store i32 %141, ptr %10, align 4, !tbaa !9
  %142 = load i32, ptr %12, align 4, !tbaa !9
  store i32 %142, ptr %11, align 4, !tbaa !9
  br label %143

143:                                              ; preds = %139, %135, %132
  %144 = load i32, ptr %4, align 4, !tbaa !9
  %145 = load i32, ptr %7, align 4, !tbaa !9
  %146 = shl i32 1, %145
  %147 = or i32 %144, %146
  %148 = load i32, ptr %8, align 4, !tbaa !9
  %149 = shl i32 1, %148
  %150 = or i32 %147, %149
  store i32 %150, ptr %6, align 4, !tbaa !9
  %151 = load i32, ptr %10, align 4, !tbaa !9
  %152 = load ptr, ptr @combList, align 8, !tbaa !15
  %153 = load i32, ptr %3, align 4, !tbaa !9
  %154 = sext i32 %153 to i64
  %155 = getelementptr inbounds %struct.Comb, ptr %152, i64 %154
  %156 = getelementptr inbounds nuw %struct.Comb, ptr %155, i32 0, i32 0
  store i32 %151, ptr %156, align 4, !tbaa !21
  %157 = load i32, ptr %11, align 4, !tbaa !9
  %158 = load ptr, ptr @combList, align 8, !tbaa !15
  %159 = load i32, ptr %3, align 4, !tbaa !9
  %160 = sext i32 %159 to i64
  %161 = getelementptr inbounds %struct.Comb, ptr %158, i64 %160
  %162 = getelementptr inbounds nuw %struct.Comb, ptr %161, i32 0, i32 1
  store i32 %157, ptr %162, align 4, !tbaa !22
  %163 = load i32, ptr %5, align 4, !tbaa !9
  %164 = load ptr, ptr @combList, align 8, !tbaa !15
  %165 = load i32, ptr %3, align 4, !tbaa !9
  %166 = sext i32 %165 to i64
  %167 = getelementptr inbounds %struct.Comb, ptr %164, i64 %166
  %168 = getelementptr inbounds nuw %struct.Comb, ptr %167, i32 0, i32 2
  store i32 %163, ptr %168, align 4, !tbaa !18
  %169 = load ptr, ptr @combList, align 8, !tbaa !15
  %170 = load i32, ptr %3, align 4, !tbaa !9
  %171 = sext i32 %170 to i64
  %172 = getelementptr inbounds %struct.Comb, ptr %169, i64 %171
  %173 = call i32 @calculate(ptr noundef %172)
  %174 = load ptr, ptr @workList, align 8, !tbaa !10
  %175 = load i32, ptr @listLength, align 4, !tbaa !9
  %176 = load i32, ptr %3, align 4, !tbaa !9
  %177 = add nsw i32 %175, %176
  %178 = sext i32 %177 to i64
  %179 = getelementptr inbounds i32, ptr %174, i64 %178
  store i32 %173, ptr %179, align 4, !tbaa !9
  %180 = load i32, ptr %3, align 4, !tbaa !9
  %181 = add nsw i32 %180, 1
  %182 = load i32, ptr %6, align 4, !tbaa !9
  call void @recSearch(i32 noundef %181, i32 noundef %182)
  br label %183

183:                                              ; preds = %143, %128, %119, %112, %89
  %184 = load i32, ptr %8, align 4, !tbaa !9
  %185 = add nsw i32 %184, 1
  store i32 %185, ptr %8, align 4, !tbaa !9
  br label %79, !llvm.loop !26

186:                                              ; preds = %79
  br label %187

187:                                              ; preds = %186, %77
  %188 = load i32, ptr %7, align 4, !tbaa !9
  %189 = add nsw i32 %188, 1
  store i32 %189, ptr %7, align 4, !tbaa !9
  br label %65, !llvm.loop !27

190:                                              ; preds = %65
  br label %191

191:                                              ; preds = %190
  %192 = load i32, ptr %5, align 4, !tbaa !9
  %193 = add nsw i32 %192, 1
  store i32 %193, ptr %5, align 4, !tbaa !9
  br label %61, !llvm.loop !28

194:                                              ; preds = %61
  call void @llvm.lifetime.end.p0(ptr %12) #8
  call void @llvm.lifetime.end.p0(ptr %11) #8
  call void @llvm.lifetime.end.p0(ptr %10) #8
  br label %195

195:                                              ; preds = %194, %59
  store i32 0, ptr %9, align 4
  br label %196

196:                                              ; preds = %195, %15
  call void @llvm.lifetime.end.p0(ptr %8) #8
  call void @llvm.lifetime.end.p0(ptr %7) #8
  call void @llvm.lifetime.end.p0(ptr %6) #8
  call void @llvm.lifetime.end.p0(ptr %5) #8
  %197 = load i32, ptr %9, align 4
  switch i32 %197, label %199 [
    i32 0, label %198
    i32 1, label %198
  ]

198:                                              ; preds = %196, %196
  ret void

199:                                              ; preds = %196
  unreachable
}

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.abs.i32(i32, i1 immarg) #6

; Function Attrs: nounwind uwtable
define dso_local void @doSearch() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %1) #8
  store i32 0, ptr %1, align 4, !tbaa !9
  br label %3

3:                                                ; preds = %28, %0
  %4 = load i32, ptr %1, align 4, !tbaa !9
  %5 = load i32, ptr @listLength, align 4, !tbaa !9
  %6 = icmp slt i32 %4, %5
  br i1 %6, label %7, label %31

7:                                                ; preds = %3
  %8 = load ptr, ptr @workList, align 8, !tbaa !10
  %9 = load i32, ptr %1, align 4, !tbaa !9
  %10 = sext i32 %9 to i64
  %11 = getelementptr inbounds i32, ptr %8, i64 %10
  %12 = load i32, ptr %11, align 4, !tbaa !9
  %13 = load i32, ptr @goal, align 4, !tbaa !9
  %14 = sub nsw i32 %12, %13
  %15 = call i32 @llvm.abs.i32(i32 %14, i1 true)
  %16 = load i32, ptr @best, align 4, !tbaa !9
  %17 = load i32, ptr @goal, align 4, !tbaa !9
  %18 = sub nsw i32 %16, %17
  %19 = call i32 @llvm.abs.i32(i32 %18, i1 true)
  %20 = icmp slt i32 %15, %19
  br i1 %20, label %21, label %27

21:                                               ; preds = %7
  %22 = load ptr, ptr @workList, align 8, !tbaa !10
  %23 = load i32, ptr %1, align 4, !tbaa !9
  %24 = sext i32 %23 to i64
  %25 = getelementptr inbounds i32, ptr %22, i64 %24
  %26 = load i32, ptr %25, align 4, !tbaa !9
  store i32 %26, ptr @best, align 4, !tbaa !9
  br label %27

27:                                               ; preds = %21, %7
  br label %28

28:                                               ; preds = %27
  %29 = load i32, ptr %1, align 4, !tbaa !9
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %1, align 4, !tbaa !9
  br label %3, !llvm.loop !29

31:                                               ; preds = %3
  %32 = load i32, ptr @best, align 4, !tbaa !9
  %33 = load i32, ptr @goal, align 4, !tbaa !9
  %34 = icmp eq i32 %32, %33
  br i1 %34, label %35, label %37

35:                                               ; preds = %31
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str.11)
  store i32 1, ptr %2, align 4
  br label %57

37:                                               ; preds = %31
  store i32 1, ptr @dmax, align 4, !tbaa !9
  br label %38

38:                                               ; preds = %47, %37
  %39 = load i32, ptr @dmax, align 4, !tbaa !9
  %40 = load i32, ptr @listLength, align 4, !tbaa !9
  %41 = icmp slt i32 %39, %40
  br i1 %41, label %42, label %50

42:                                               ; preds = %38
  call void @recSearch(i32 noundef 0, i32 noundef 0)
  %43 = load i32, ptr @stopSearch, align 4, !tbaa !9
  %44 = icmp ne i32 %43, 0
  br i1 %44, label %45, label %46

45:                                               ; preds = %42
  br label %50

46:                                               ; preds = %42
  br label %47

47:                                               ; preds = %46
  %48 = load i32, ptr @dmax, align 4, !tbaa !9
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr @dmax, align 4, !tbaa !9
  br label %38, !llvm.loop !30

50:                                               ; preds = %45, %38
  %51 = load i32, ptr @stopSearch, align 4, !tbaa !9
  %52 = icmp eq i32 %51, 0
  br i1 %52, label %53, label %56

53:                                               ; preds = %50
  %54 = load ptr, ptr @solution, align 8, !tbaa !15
  %55 = load i32, ptr @bestDepth, align 4, !tbaa !9
  call void @printSolution(ptr noundef %54, i32 noundef %55)
  br label %56

56:                                               ; preds = %53, %50
  store i32 0, ptr %2, align 4
  br label %57

57:                                               ; preds = %56, %35
  call void @llvm.lifetime.end.p0(ptr %1) #8
  %58 = load i32, ptr %2, align 4
  switch i32 %58, label %60 [
    i32 0, label %59
    i32 1, label %59
  ]

59:                                               ; preds = %57, %57
  ret void

60:                                               ; preds = %57
  unreachable
}

; Function Attrs: nounwind uwtable
define dso_local i32 @getInput() #0 {
  %1 = alloca [16 x i32], align 16
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %1) #8
  call void @llvm.lifetime.start.p0(ptr %2) #8
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #8
  %4 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 0
  store i32 13, ptr %4, align 16, !tbaa !9
  %5 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 1
  store i32 32, ptr %5, align 4, !tbaa !9
  %6 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 2
  store i32 14, ptr %6, align 8, !tbaa !9
  %7 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 3
  store i32 1412, ptr %7, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %16, %0
  %9 = call i32 @getchar()
  store i32 %9, ptr %3, align 4, !tbaa !9
  %10 = icmp ne i32 %9, 10
  br i1 %10, label %11, label %14

11:                                               ; preds = %8
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = icmp ne i32 %12, -1
  br label %14

14:                                               ; preds = %11, %8
  %15 = phi i1 [ false, %8 ], [ %13, %11 ]
  br i1 %15, label %16, label %27

16:                                               ; preds = %14
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = load ptr, ptr @stdin, align 8, !tbaa !13
  %19 = call i32 @ungetc(i32 noundef %17, ptr noundef %18)
  %20 = load ptr, ptr @stdin, align 8, !tbaa !13
  %21 = load i32, ptr %2, align 4, !tbaa !9
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 %22
  %24 = call i32 (ptr, ptr, ...) @__isoc99_fscanf(ptr noundef %20, ptr noundef @.str.2, ptr noundef %23)
  %25 = load i32, ptr %2, align 4, !tbaa !9
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %2, align 4, !tbaa !9
  br label %8, !llvm.loop !31

27:                                               ; preds = %14
  %28 = load i32, ptr %2, align 4, !tbaa !9
  %29 = icmp eq i32 %28, 0
  br i1 %29, label %30, label %31

30:                                               ; preds = %27
  store i32 4, ptr %2, align 4, !tbaa !9
  br label %31

31:                                               ; preds = %30, %27
  %32 = load i32, ptr %2, align 4, !tbaa !9
  %33 = sub nsw i32 %32, 1
  store i32 %33, ptr @listLength, align 4, !tbaa !9
  %34 = load i32, ptr @listLength, align 4, !tbaa !9
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 %35
  %37 = load i32, ptr %36, align 4, !tbaa !9
  store i32 %37, ptr @goal, align 4, !tbaa !9
  %38 = load i32, ptr @listLength, align 4, !tbaa !9
  %39 = mul nsw i32 2, %38
  %40 = call ptr @newWorkList(i32 noundef %39)
  store ptr %40, ptr @workList, align 8, !tbaa !10
  %41 = load i32, ptr @listLength, align 4, !tbaa !9
  %42 = call ptr @newCombList(i32 noundef %41)
  store ptr %42, ptr @combList, align 8, !tbaa !15
  %43 = load i32, ptr @listLength, align 4, !tbaa !9
  %44 = call ptr @newCombList(i32 noundef %43)
  store ptr %44, ptr @solution, align 8, !tbaa !15
  %45 = load ptr, ptr @workList, align 8, !tbaa !10
  %46 = getelementptr inbounds [16 x i32], ptr %1, i64 0, i64 0
  %47 = load i32, ptr @listLength, align 4, !tbaa !9
  call void @initWorkList(ptr noundef %45, ptr noundef %46, i32 noundef %47)
  %48 = load ptr, ptr @combList, align 8, !tbaa !15
  %49 = load i32, ptr @listLength, align 4, !tbaa !9
  call void @initCombList(ptr noundef %48, i32 noundef %49)
  %50 = load ptr, ptr @solution, align 8, !tbaa !15
  %51 = load i32, ptr @listLength, align 4, !tbaa !9
  call void @initCombList(ptr noundef %50, i32 noundef %51)
  %52 = load i32, ptr @listLength, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #8
  call void @llvm.lifetime.end.p0(ptr %2) #8
  call void @llvm.lifetime.end.p0(ptr %1) #8
  ret i32 %52
}

; Function Attrs: inlinehint nounwind uwtable
define available_externally i32 @getchar() #7 {
  %1 = load ptr, ptr @stdin, align 8, !tbaa !13
  %2 = call i32 @getc(ptr noundef %1)
  ret i32 %2
}

declare i32 @ungetc(i32 noundef, ptr noundef) #5

declare i32 @__isoc99_fscanf(ptr noundef, ptr noundef, ...) #5

; Function Attrs: nounwind uwtable
define dso_local void @search() #0 {
  store i32 0, ptr @stopSearch, align 4, !tbaa !9
  store i32 0, ptr @nbNodes, align 4, !tbaa !9
  call void @doSearch()
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !32
  %6 = call i32 @getInput()
  %7 = icmp ne i32 %6, 0
  br i1 %7, label %8, label %9

8:                                                ; preds = %2
  call void @search()
  br label %9

9:                                                ; preds = %8, %2
  ret i32 0
}

declare i32 @getc(ptr noundef) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0,1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #7 = { inlinehint nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nounwind }
attributes #9 = { nounwind allocsize(0,1) }
attributes #10 = { noreturn nounwind }

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
!11 = !{!"p1 int", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 _ZTS8_IO_FILE", !12, i64 0}
!15 = !{!12, !12, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = !{!19, !6, i64 8}
!19 = !{!"", !6, i64 0, !6, i64 4, !6, i64 8}
!20 = distinct !{!20, !17}
!21 = !{!19, !6, i64 0}
!22 = !{!19, !6, i64 4}
!23 = distinct !{!23, !17}
!24 = distinct !{!24, !17}
!25 = distinct !{!25, !17}
!26 = distinct !{!26, !17}
!27 = distinct !{!27, !17}
!28 = distinct !{!28, !17}
!29 = distinct !{!29, !17}
!30 = distinct !{!30, !17}
!31 = distinct !{!31, !17}
!32 = !{!33, !33, i64 0}
!33 = !{!"p2 omnipotent char", !34, i64 0}
!34 = !{!"any p2 pointer", !12, i64 0}
