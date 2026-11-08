; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.DLL = type { i32, ptr, ptr }

@.str = private unnamed_addr constant [12 x i8] c"length: %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [28 x i8] c"i:%3d  v:%3d  n:%3d  p:%3d\0A\00", align 1
@.str.2 = private unnamed_addr constant [34 x i8] c"[last entry points to list head]\0A\00", align 1
@.str.3 = private unnamed_addr constant [31 x i8] c"[val of next of tail is:  %d]\0A\00", align 1
@.str.4 = private unnamed_addr constant [27 x i8] c"li2 and li1 are not equal\0A\00", align 1
@.str.5 = private unnamed_addr constant [25 x i8] c"li2 should be empty now\0A\00", align 1
@.str.6 = private unnamed_addr constant [25 x i8] c"li3 should be empty now\0A\00", align 1
@.str.7 = private unnamed_addr constant [42 x i8] c"li1 first value wrong, wanted %d, got %d\0A\00", align 1
@.str.8 = private unnamed_addr constant [37 x i8] c"last value wrong, wanted %d, got %d\0A\00", align 1
@.str.9 = private unnamed_addr constant [42 x i8] c"li2 first value wrong, wanted %d, got %d\0A\00", align 1
@.str.10 = private unnamed_addr constant [35 x i8] c"li1 size wrong, wanted %d, got %d\0A\00", align 1
@.str.11 = private unnamed_addr constant [27 x i8] c"li1 and li2 are not equal\0A\00", align 1
@.str.12 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @list_push_tail(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #7
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw %struct.DLL, ptr %6, i32 0, i32 2
  %8 = load ptr, ptr %7, align 8, !tbaa !12
  store ptr %8, ptr %5, align 8, !tbaa !9
  %9 = load ptr, ptr %4, align 8, !tbaa !9
  %10 = load ptr, ptr %5, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 1
  store ptr %9, ptr %11, align 8, !tbaa !14
  %12 = load ptr, ptr %3, align 8, !tbaa !9
  %13 = load ptr, ptr %4, align 8, !tbaa !9
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 1
  store ptr %12, ptr %14, align 8, !tbaa !14
  %15 = load ptr, ptr %4, align 8, !tbaa !9
  %16 = load ptr, ptr %3, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 2
  store ptr %15, ptr %17, align 8, !tbaa !12
  %18 = load ptr, ptr %5, align 8, !tbaa !9
  %19 = load ptr, ptr %4, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 2
  store ptr %18, ptr %20, align 8, !tbaa !12
  %21 = load ptr, ptr %3, align 8, !tbaa !9
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 0
  %23 = load i32, ptr %22, align 8, !tbaa !15
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %22, align 8, !tbaa !15
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local ptr @list_pop_tail(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #7
  call void @llvm.lifetime.start.p0(ptr %5) #7
  %7 = load ptr, ptr %3, align 8, !tbaa !9
  %8 = call i32 @list_empty(ptr noundef %7)
  %9 = icmp ne i32 %8, 0
  br i1 %9, label %10, label %11

10:                                               ; preds = %1
  store ptr null, ptr %2, align 8
  store i32 1, ptr %6, align 4
  br label %29

11:                                               ; preds = %1
  %12 = load ptr, ptr %3, align 8, !tbaa !9
  %13 = getelementptr inbounds nuw %struct.DLL, ptr %12, i32 0, i32 2
  %14 = load ptr, ptr %13, align 8, !tbaa !12
  store ptr %14, ptr %5, align 8, !tbaa !9
  %15 = load ptr, ptr %5, align 8, !tbaa !9
  %16 = getelementptr inbounds nuw %struct.DLL, ptr %15, i32 0, i32 2
  %17 = load ptr, ptr %16, align 8, !tbaa !12
  store ptr %17, ptr %4, align 8, !tbaa !9
  %18 = load ptr, ptr %3, align 8, !tbaa !9
  %19 = load ptr, ptr %4, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 1
  store ptr %18, ptr %20, align 8, !tbaa !14
  %21 = load ptr, ptr %4, align 8, !tbaa !9
  %22 = load ptr, ptr %3, align 8, !tbaa !9
  %23 = getelementptr inbounds nuw %struct.DLL, ptr %22, i32 0, i32 2
  store ptr %21, ptr %23, align 8, !tbaa !12
  %24 = load ptr, ptr %3, align 8, !tbaa !9
  %25 = getelementptr inbounds nuw %struct.DLL, ptr %24, i32 0, i32 0
  %26 = load i32, ptr %25, align 8, !tbaa !15
  %27 = add nsw i32 %26, -1
  store i32 %27, ptr %25, align 8, !tbaa !15
  %28 = load ptr, ptr %5, align 8, !tbaa !9
  store ptr %28, ptr %2, align 8
  store i32 1, ptr %6, align 4
  br label %29

29:                                               ; preds = %11, %10
  call void @llvm.lifetime.end.p0(ptr %5) #7
  call void @llvm.lifetime.end.p0(ptr %4) #7
  %30 = load ptr, ptr %2, align 8
  ret ptr %30
}

; Function Attrs: nounwind uwtable
define internal i32 @list_empty(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = call i32 @list_length(ptr noundef %3)
  %5 = icmp eq i32 %4, 0
  %6 = zext i1 %5 to i32
  ret i32 %6
}

; Function Attrs: nounwind uwtable
define dso_local void @list_push_head(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #7
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw %struct.DLL, ptr %6, i32 0, i32 1
  %8 = load ptr, ptr %7, align 8, !tbaa !14
  store ptr %8, ptr %5, align 8, !tbaa !9
  %9 = load ptr, ptr %4, align 8, !tbaa !9
  %10 = load ptr, ptr %3, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 1
  store ptr %9, ptr %11, align 8, !tbaa !14
  %12 = load ptr, ptr %4, align 8, !tbaa !9
  %13 = load ptr, ptr %5, align 8, !tbaa !9
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 2
  store ptr %12, ptr %14, align 8, !tbaa !12
  %15 = load ptr, ptr %5, align 8, !tbaa !9
  %16 = load ptr, ptr %4, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 1
  store ptr %15, ptr %17, align 8, !tbaa !14
  %18 = load ptr, ptr %3, align 8, !tbaa !9
  %19 = load ptr, ptr %4, align 8, !tbaa !9
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 2
  store ptr %18, ptr %20, align 8, !tbaa !12
  %21 = load ptr, ptr %3, align 8, !tbaa !9
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 0
  %23 = load i32, ptr %22, align 8, !tbaa !15
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %22, align 8, !tbaa !15
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local ptr @list_pop_head(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #7
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = call i32 @list_empty(ptr noundef %6)
  %8 = icmp ne i32 %7, 0
  br i1 %8, label %9, label %10

9:                                                ; preds = %1
  store ptr null, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %29

10:                                               ; preds = %1
  %11 = load ptr, ptr %3, align 8, !tbaa !9
  %12 = getelementptr inbounds nuw %struct.DLL, ptr %11, i32 0, i32 1
  %13 = load ptr, ptr %12, align 8, !tbaa !14
  store ptr %13, ptr %4, align 8, !tbaa !9
  %14 = load ptr, ptr %4, align 8, !tbaa !9
  %15 = getelementptr inbounds nuw %struct.DLL, ptr %14, i32 0, i32 1
  %16 = load ptr, ptr %15, align 8, !tbaa !14
  %17 = load ptr, ptr %3, align 8, !tbaa !9
  %18 = getelementptr inbounds nuw %struct.DLL, ptr %17, i32 0, i32 1
  store ptr %16, ptr %18, align 8, !tbaa !14
  %19 = load ptr, ptr %3, align 8, !tbaa !9
  %20 = load ptr, ptr %4, align 8, !tbaa !9
  %21 = getelementptr inbounds nuw %struct.DLL, ptr %20, i32 0, i32 1
  %22 = load ptr, ptr %21, align 8, !tbaa !14
  %23 = getelementptr inbounds nuw %struct.DLL, ptr %22, i32 0, i32 2
  store ptr %19, ptr %23, align 8, !tbaa !12
  %24 = load ptr, ptr %3, align 8, !tbaa !9
  %25 = getelementptr inbounds nuw %struct.DLL, ptr %24, i32 0, i32 0
  %26 = load i32, ptr %25, align 8, !tbaa !15
  %27 = add nsw i32 %26, -1
  store i32 %27, ptr %25, align 8, !tbaa !15
  %28 = load ptr, ptr %4, align 8, !tbaa !9
  store ptr %28, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %29

29:                                               ; preds = %10, %9
  call void @llvm.lifetime.end.p0(ptr %4) #7
  %30 = load ptr, ptr %2, align 8
  ret ptr %30
}

; Function Attrs: nounwind uwtable
define dso_local i32 @list_equal(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  %9 = load ptr, ptr %4, align 8, !tbaa !9
  store ptr %9, ptr %6, align 8, !tbaa !9
  %10 = load ptr, ptr %5, align 8, !tbaa !9
  store ptr %10, ptr %7, align 8, !tbaa !9
  br label %11

11:                                               ; preds = %27, %2
  %12 = load ptr, ptr %6, align 8, !tbaa !9
  %13 = getelementptr inbounds nuw %struct.DLL, ptr %12, i32 0, i32 1
  %14 = load ptr, ptr %13, align 8, !tbaa !14
  %15 = load ptr, ptr %4, align 8, !tbaa !9
  %16 = icmp ne ptr %14, %15
  br i1 %16, label %17, label %34

17:                                               ; preds = %11
  %18 = load ptr, ptr %6, align 8, !tbaa !9
  %19 = getelementptr inbounds nuw %struct.DLL, ptr %18, i32 0, i32 0
  %20 = load i32, ptr %19, align 8, !tbaa !15
  %21 = load ptr, ptr %7, align 8, !tbaa !9
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 0
  %23 = load i32, ptr %22, align 8, !tbaa !15
  %24 = icmp ne i32 %20, %23
  br i1 %24, label %25, label %26

25:                                               ; preds = %17
  store i32 0, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %50

26:                                               ; preds = %17
  br label %27

27:                                               ; preds = %26
  %28 = load ptr, ptr %6, align 8, !tbaa !9
  %29 = getelementptr inbounds nuw %struct.DLL, ptr %28, i32 0, i32 1
  %30 = load ptr, ptr %29, align 8, !tbaa !14
  store ptr %30, ptr %6, align 8, !tbaa !9
  %31 = load ptr, ptr %7, align 8, !tbaa !9
  %32 = getelementptr inbounds nuw %struct.DLL, ptr %31, i32 0, i32 1
  %33 = load ptr, ptr %32, align 8, !tbaa !14
  store ptr %33, ptr %7, align 8, !tbaa !9
  br label %11, !llvm.loop !16

34:                                               ; preds = %11
  %35 = load ptr, ptr %6, align 8, !tbaa !9
  %36 = getelementptr inbounds nuw %struct.DLL, ptr %35, i32 0, i32 0
  %37 = load i32, ptr %36, align 8, !tbaa !15
  %38 = load ptr, ptr %7, align 8, !tbaa !9
  %39 = getelementptr inbounds nuw %struct.DLL, ptr %38, i32 0, i32 0
  %40 = load i32, ptr %39, align 8, !tbaa !15
  %41 = icmp ne i32 %37, %40
  br i1 %41, label %42, label %43

42:                                               ; preds = %34
  store i32 0, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %50

43:                                               ; preds = %34
  %44 = load ptr, ptr %7, align 8, !tbaa !9
  %45 = getelementptr inbounds nuw %struct.DLL, ptr %44, i32 0, i32 1
  %46 = load ptr, ptr %45, align 8, !tbaa !14
  %47 = load ptr, ptr %5, align 8, !tbaa !9
  %48 = icmp eq ptr %46, %47
  %49 = zext i1 %48 to i32
  store i32 %49, ptr %3, align 4
  store i32 1, ptr %8, align 4
  br label %50

50:                                               ; preds = %43, %42, %25
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  %51 = load i32, ptr %3, align 4
  ret i32 %51
}

; Function Attrs: nounwind uwtable
define dso_local void @list_print(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !18
  store ptr %1, ptr %4, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #7
  call void @llvm.lifetime.start.p0(ptr %6) #7
  %8 = load ptr, ptr %4, align 8, !tbaa !9
  %9 = getelementptr inbounds nuw %struct.DLL, ptr %8, i32 0, i32 1
  %10 = load ptr, ptr %9, align 8, !tbaa !14
  store ptr %10, ptr %6, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #7
  store i32 0, ptr %7, align 4, !tbaa !20
  %11 = load ptr, ptr %3, align 8, !tbaa !18
  %12 = call i32 @puts(ptr noundef %11)
  %13 = load ptr, ptr %4, align 8, !tbaa !9
  %14 = call i32 @list_length(ptr noundef %13)
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %14)
  %16 = load ptr, ptr %4, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 1
  %18 = load ptr, ptr %17, align 8, !tbaa !14
  store ptr %18, ptr %5, align 8, !tbaa !9
  br label %19

19:                                               ; preds = %42, %2
  %20 = load ptr, ptr %5, align 8, !tbaa !9
  %21 = getelementptr inbounds nuw %struct.DLL, ptr %20, i32 0, i32 1
  %22 = load ptr, ptr %21, align 8, !tbaa !14
  %23 = load ptr, ptr %6, align 8, !tbaa !9
  %24 = icmp ne ptr %22, %23
  br i1 %24, label %25, label %46

25:                                               ; preds = %19
  %26 = load i32, ptr %7, align 4, !tbaa !20
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %7, align 4, !tbaa !20
  %28 = load ptr, ptr %5, align 8, !tbaa !9
  %29 = getelementptr inbounds nuw %struct.DLL, ptr %28, i32 0, i32 0
  %30 = load i32, ptr %29, align 8, !tbaa !15
  %31 = load ptr, ptr %5, align 8, !tbaa !9
  %32 = getelementptr inbounds nuw %struct.DLL, ptr %31, i32 0, i32 1
  %33 = load ptr, ptr %32, align 8, !tbaa !14
  %34 = getelementptr inbounds nuw %struct.DLL, ptr %33, i32 0, i32 0
  %35 = load i32, ptr %34, align 8, !tbaa !15
  %36 = load ptr, ptr %5, align 8, !tbaa !9
  %37 = getelementptr inbounds nuw %struct.DLL, ptr %36, i32 0, i32 2
  %38 = load ptr, ptr %37, align 8, !tbaa !12
  %39 = getelementptr inbounds nuw %struct.DLL, ptr %38, i32 0, i32 0
  %40 = load i32, ptr %39, align 8, !tbaa !15
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %27, i32 noundef %30, i32 noundef %35, i32 noundef %40)
  br label %42

42:                                               ; preds = %25
  %43 = load ptr, ptr %5, align 8, !tbaa !9
  %44 = getelementptr inbounds nuw %struct.DLL, ptr %43, i32 0, i32 1
  %45 = load ptr, ptr %44, align 8, !tbaa !14
  store ptr %45, ptr %5, align 8, !tbaa !9
  br label %19, !llvm.loop !21

46:                                               ; preds = %19
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %48 = load ptr, ptr %5, align 8, !tbaa !9
  %49 = getelementptr inbounds nuw %struct.DLL, ptr %48, i32 0, i32 1
  %50 = load ptr, ptr %49, align 8, !tbaa !14
  %51 = getelementptr inbounds nuw %struct.DLL, ptr %50, i32 0, i32 0
  %52 = load i32, ptr %51, align 8, !tbaa !15
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %52)
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret void
}

declare i32 @puts(ptr noundef) #2

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal i32 @list_length(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 0
  %5 = load i32, ptr %4, align 8, !tbaa !15
  ret i32 %5
}

; Function Attrs: nounwind uwtable
define dso_local ptr @list_new() #0 {
  %1 = alloca ptr, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #7
  %2 = call noalias ptr @malloc(i64 noundef 24) #8
  store ptr %2, ptr %1, align 8, !tbaa !9
  %3 = load ptr, ptr %1, align 8, !tbaa !9
  %4 = load ptr, ptr %1, align 8, !tbaa !9
  %5 = getelementptr inbounds nuw %struct.DLL, ptr %4, i32 0, i32 1
  store ptr %3, ptr %5, align 8, !tbaa !14
  %6 = load ptr, ptr %1, align 8, !tbaa !9
  %7 = load ptr, ptr %1, align 8, !tbaa !9
  %8 = getelementptr inbounds nuw %struct.DLL, ptr %7, i32 0, i32 2
  store ptr %6, ptr %8, align 8, !tbaa !12
  %9 = load ptr, ptr %1, align 8, !tbaa !9
  %10 = getelementptr inbounds nuw %struct.DLL, ptr %9, i32 0, i32 0
  store i32 0, ptr %10, align 8, !tbaa !15
  %11 = load ptr, ptr %1, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %1) #7
  ret ptr %11
}

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #3

; Function Attrs: nounwind uwtable
define dso_local ptr @list_sequence(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  store i32 %0, ptr %3, align 4, !tbaa !20
  store i32 %1, ptr %4, align 4, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %5) #7
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  call void @llvm.lifetime.start.p0(ptr %8) #7
  call void @llvm.lifetime.start.p0(ptr %9) #7
  %10 = load i32, ptr %3, align 4, !tbaa !20
  %11 = load i32, ptr %4, align 4, !tbaa !20
  %12 = icmp sgt i32 %10, %11
  br i1 %12, label %13, label %17

13:                                               ; preds = %2
  %14 = load i32, ptr %3, align 4, !tbaa !20
  store i32 %14, ptr %6, align 4, !tbaa !20
  %15 = load i32, ptr %4, align 4, !tbaa !20
  store i32 %15, ptr %3, align 4, !tbaa !20
  %16 = load i32, ptr %6, align 4, !tbaa !20
  store i32 %16, ptr %4, align 4, !tbaa !20
  br label %17

17:                                               ; preds = %13, %2
  %18 = load i32, ptr %4, align 4, !tbaa !20
  %19 = load i32, ptr %3, align 4, !tbaa !20
  %20 = sub nsw i32 %18, %19
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %5, align 4, !tbaa !20
  %22 = load i32, ptr %5, align 4, !tbaa !20
  %23 = add nsw i32 %22, 1
  %24 = sext i32 %23 to i64
  %25 = mul i64 %24, 24
  %26 = call noalias ptr @malloc(i64 noundef %25) #8
  store ptr %26, ptr %9, align 8, !tbaa !9
  %27 = load i32, ptr %3, align 4, !tbaa !20
  %28 = add nsw i32 %27, -1
  store i32 %28, ptr %3, align 4, !tbaa !20
  store i32 0, ptr %7, align 4, !tbaa !20
  store i32 1, ptr %8, align 4, !tbaa !20
  br label %29

29:                                               ; preds = %61, %17
  %30 = load i32, ptr %7, align 4, !tbaa !20
  %31 = load i32, ptr %5, align 4, !tbaa !20
  %32 = icmp slt i32 %30, %31
  br i1 %32, label %33, label %66

33:                                               ; preds = %29
  %34 = load ptr, ptr %9, align 8, !tbaa !9
  %35 = load i32, ptr %7, align 4, !tbaa !20
  %36 = add nsw i32 %35, 1
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds %struct.DLL, ptr %34, i64 %37
  %39 = load ptr, ptr %9, align 8, !tbaa !9
  %40 = load i32, ptr %7, align 4, !tbaa !20
  %41 = sext i32 %40 to i64
  %42 = getelementptr inbounds %struct.DLL, ptr %39, i64 %41
  %43 = getelementptr inbounds nuw %struct.DLL, ptr %42, i32 0, i32 1
  store ptr %38, ptr %43, align 8, !tbaa !14
  %44 = load ptr, ptr %9, align 8, !tbaa !9
  %45 = load i32, ptr %8, align 4, !tbaa !20
  %46 = sub nsw i32 %45, 1
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds %struct.DLL, ptr %44, i64 %47
  %49 = load ptr, ptr %9, align 8, !tbaa !9
  %50 = load i32, ptr %8, align 4, !tbaa !20
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds %struct.DLL, ptr %49, i64 %51
  %53 = getelementptr inbounds nuw %struct.DLL, ptr %52, i32 0, i32 2
  store ptr %48, ptr %53, align 8, !tbaa !12
  %54 = load i32, ptr %3, align 4, !tbaa !20
  %55 = add nsw i32 %54, 1
  store i32 %55, ptr %3, align 4, !tbaa !20
  %56 = load ptr, ptr %9, align 8, !tbaa !9
  %57 = load i32, ptr %7, align 4, !tbaa !20
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds %struct.DLL, ptr %56, i64 %58
  %60 = getelementptr inbounds nuw %struct.DLL, ptr %59, i32 0, i32 0
  store i32 %54, ptr %60, align 8, !tbaa !15
  br label %61

61:                                               ; preds = %33
  %62 = load i32, ptr %7, align 4, !tbaa !20
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %7, align 4, !tbaa !20
  %64 = load i32, ptr %8, align 4, !tbaa !20
  %65 = add nsw i32 %64, 1
  store i32 %65, ptr %8, align 4, !tbaa !20
  br label %29, !llvm.loop !22

66:                                               ; preds = %29
  %67 = load ptr, ptr %9, align 8, !tbaa !9
  %68 = load i32, ptr %5, align 4, !tbaa !20
  %69 = sext i32 %68 to i64
  %70 = getelementptr inbounds %struct.DLL, ptr %67, i64 %69
  %71 = load ptr, ptr %9, align 8, !tbaa !9
  %72 = getelementptr inbounds %struct.DLL, ptr %71, i64 0
  %73 = getelementptr inbounds nuw %struct.DLL, ptr %72, i32 0, i32 2
  store ptr %70, ptr %73, align 8, !tbaa !12
  %74 = load ptr, ptr %9, align 8, !tbaa !9
  %75 = getelementptr inbounds %struct.DLL, ptr %74, i64 0
  %76 = load ptr, ptr %9, align 8, !tbaa !9
  %77 = load i32, ptr %5, align 4, !tbaa !20
  %78 = sext i32 %77 to i64
  %79 = getelementptr inbounds %struct.DLL, ptr %76, i64 %78
  %80 = getelementptr inbounds nuw %struct.DLL, ptr %79, i32 0, i32 1
  store ptr %75, ptr %80, align 8, !tbaa !14
  %81 = load ptr, ptr %9, align 8, !tbaa !9
  %82 = load i32, ptr %5, align 4, !tbaa !20
  %83 = sub nsw i32 %82, 1
  %84 = sext i32 %83 to i64
  %85 = getelementptr inbounds %struct.DLL, ptr %81, i64 %84
  %86 = load ptr, ptr %9, align 8, !tbaa !9
  %87 = load i32, ptr %5, align 4, !tbaa !20
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds %struct.DLL, ptr %86, i64 %88
  %90 = getelementptr inbounds nuw %struct.DLL, ptr %89, i32 0, i32 2
  store ptr %85, ptr %90, align 8, !tbaa !12
  %91 = load i32, ptr %3, align 4, !tbaa !20
  %92 = load ptr, ptr %9, align 8, !tbaa !9
  %93 = load i32, ptr %5, align 4, !tbaa !20
  %94 = sext i32 %93 to i64
  %95 = getelementptr inbounds %struct.DLL, ptr %92, i64 %94
  %96 = getelementptr inbounds nuw %struct.DLL, ptr %95, i32 0, i32 0
  store i32 %91, ptr %96, align 8, !tbaa !15
  %97 = load i32, ptr %5, align 4, !tbaa !20
  %98 = load ptr, ptr %9, align 8, !tbaa !9
  %99 = getelementptr inbounds %struct.DLL, ptr %98, i64 0
  %100 = getelementptr inbounds nuw %struct.DLL, ptr %99, i32 0, i32 0
  store i32 %97, ptr %100, align 8, !tbaa !15
  %101 = load ptr, ptr %9, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %9) #7
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  ret ptr %101
}

; Function Attrs: nounwind uwtable
define dso_local ptr @list_copy(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #7
  call void @llvm.lifetime.start.p0(ptr %4) #7
  call void @llvm.lifetime.start.p0(ptr %5) #7
  %8 = load ptr, ptr %2, align 8, !tbaa !9
  %9 = call i32 @list_length(ptr noundef %8)
  store i32 %9, ptr %5, align 4, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  %10 = load i32, ptr %5, align 4, !tbaa !20
  %11 = add nsw i32 %10, 1
  %12 = sext i32 %11 to i64
  %13 = mul i64 %12, 24
  %14 = call noalias ptr @malloc(i64 noundef %13) #8
  store ptr %14, ptr %7, align 8, !tbaa !9
  store i32 0, ptr %3, align 4, !tbaa !20
  store i32 1, ptr %4, align 4, !tbaa !20
  %15 = load ptr, ptr %2, align 8, !tbaa !9
  store ptr %15, ptr %6, align 8, !tbaa !9
  br label %16

16:                                               ; preds = %47, %1
  %17 = load i32, ptr %3, align 4, !tbaa !20
  %18 = load i32, ptr %5, align 4, !tbaa !20
  %19 = icmp slt i32 %17, %18
  br i1 %19, label %20, label %55

20:                                               ; preds = %16
  %21 = load ptr, ptr %7, align 8, !tbaa !9
  %22 = load i32, ptr %4, align 4, !tbaa !20
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds %struct.DLL, ptr %21, i64 %23
  %25 = load ptr, ptr %7, align 8, !tbaa !9
  %26 = load i32, ptr %3, align 4, !tbaa !20
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds %struct.DLL, ptr %25, i64 %27
  %29 = getelementptr inbounds nuw %struct.DLL, ptr %28, i32 0, i32 1
  store ptr %24, ptr %29, align 8, !tbaa !14
  %30 = load ptr, ptr %7, align 8, !tbaa !9
  %31 = load i32, ptr %3, align 4, !tbaa !20
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds %struct.DLL, ptr %30, i64 %32
  %34 = load ptr, ptr %7, align 8, !tbaa !9
  %35 = load i32, ptr %4, align 4, !tbaa !20
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds %struct.DLL, ptr %34, i64 %36
  %38 = getelementptr inbounds nuw %struct.DLL, ptr %37, i32 0, i32 2
  store ptr %33, ptr %38, align 8, !tbaa !12
  %39 = load ptr, ptr %6, align 8, !tbaa !9
  %40 = getelementptr inbounds nuw %struct.DLL, ptr %39, i32 0, i32 0
  %41 = load i32, ptr %40, align 8, !tbaa !15
  %42 = load ptr, ptr %7, align 8, !tbaa !9
  %43 = load i32, ptr %3, align 4, !tbaa !20
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds %struct.DLL, ptr %42, i64 %44
  %46 = getelementptr inbounds nuw %struct.DLL, ptr %45, i32 0, i32 0
  store i32 %41, ptr %46, align 8, !tbaa !15
  br label %47

47:                                               ; preds = %20
  %48 = load i32, ptr %3, align 4, !tbaa !20
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %3, align 4, !tbaa !20
  %50 = load i32, ptr %4, align 4, !tbaa !20
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %4, align 4, !tbaa !20
  %52 = load ptr, ptr %6, align 8, !tbaa !9
  %53 = getelementptr inbounds nuw %struct.DLL, ptr %52, i32 0, i32 1
  %54 = load ptr, ptr %53, align 8, !tbaa !14
  store ptr %54, ptr %6, align 8, !tbaa !9
  br label %16, !llvm.loop !23

55:                                               ; preds = %16
  %56 = load ptr, ptr %7, align 8, !tbaa !9
  %57 = load i32, ptr %5, align 4, !tbaa !20
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds %struct.DLL, ptr %56, i64 %58
  %60 = load ptr, ptr %7, align 8, !tbaa !9
  %61 = getelementptr inbounds %struct.DLL, ptr %60, i64 0
  %62 = getelementptr inbounds nuw %struct.DLL, ptr %61, i32 0, i32 2
  store ptr %59, ptr %62, align 8, !tbaa !12
  %63 = load ptr, ptr %7, align 8, !tbaa !9
  %64 = getelementptr inbounds %struct.DLL, ptr %63, i64 0
  %65 = load ptr, ptr %7, align 8, !tbaa !9
  %66 = load i32, ptr %5, align 4, !tbaa !20
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds %struct.DLL, ptr %65, i64 %67
  %69 = getelementptr inbounds nuw %struct.DLL, ptr %68, i32 0, i32 1
  store ptr %64, ptr %69, align 8, !tbaa !14
  %70 = load ptr, ptr %2, align 8, !tbaa !9
  %71 = call ptr @list_last(ptr noundef %70)
  %72 = getelementptr inbounds nuw %struct.DLL, ptr %71, i32 0, i32 0
  %73 = load i32, ptr %72, align 8, !tbaa !15
  %74 = load ptr, ptr %7, align 8, !tbaa !9
  %75 = load i32, ptr %5, align 4, !tbaa !20
  %76 = sext i32 %75 to i64
  %77 = getelementptr inbounds %struct.DLL, ptr %74, i64 %76
  %78 = getelementptr inbounds nuw %struct.DLL, ptr %77, i32 0, i32 0
  store i32 %73, ptr %78, align 8, !tbaa !15
  %79 = load ptr, ptr %7, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  call void @llvm.lifetime.end.p0(ptr %4) #7
  call void @llvm.lifetime.end.p0(ptr %3) #7
  ret ptr %79
}

; Function Attrs: nounwind uwtable
define internal ptr @list_last(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 2
  %5 = load ptr, ptr %4, align 8, !tbaa !12
  ret ptr %5
}

; Function Attrs: nounwind uwtable
define dso_local void @list_reverse(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #7
  call void @llvm.lifetime.start.p0(ptr %4) #7
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  store ptr %5, ptr %4, align 8, !tbaa !9
  br label %6

6:                                                ; preds = %19, %1
  %7 = load ptr, ptr %4, align 8, !tbaa !9
  %8 = getelementptr inbounds nuw %struct.DLL, ptr %7, i32 0, i32 1
  %9 = load ptr, ptr %8, align 8, !tbaa !14
  store ptr %9, ptr %3, align 8, !tbaa !9
  %10 = load ptr, ptr %4, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 2
  %12 = load ptr, ptr %11, align 8, !tbaa !12
  %13 = load ptr, ptr %4, align 8, !tbaa !9
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 1
  store ptr %12, ptr %14, align 8, !tbaa !14
  %15 = load ptr, ptr %3, align 8, !tbaa !9
  %16 = load ptr, ptr %4, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 2
  store ptr %15, ptr %17, align 8, !tbaa !12
  %18 = load ptr, ptr %3, align 8, !tbaa !9
  store ptr %18, ptr %4, align 8, !tbaa !9
  br label %19

19:                                               ; preds = %6
  %20 = load ptr, ptr %4, align 8, !tbaa !9
  %21 = load ptr, ptr %2, align 8, !tbaa !9
  %22 = icmp ne ptr %20, %21
  br i1 %22, label %6, label %23, !llvm.loop !24

23:                                               ; preds = %19
  call void @llvm.lifetime.end.p0(ptr %4) #7
  call void @llvm.lifetime.end.p0(ptr %3) #7
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @test_lists() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #7
  store i32 0, ptr %1, align 4, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %2) #7
  %5 = call ptr @list_sequence(i32 noundef 1, i32 noundef 100)
  store ptr %5, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #7
  %6 = load ptr, ptr %2, align 8, !tbaa !9
  %7 = call ptr @list_copy(ptr noundef %6)
  store ptr %7, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #7
  %8 = call ptr @list_new()
  store ptr %8, ptr %4, align 8, !tbaa !9
  %9 = load ptr, ptr %3, align 8, !tbaa !9
  %10 = load ptr, ptr %2, align 8, !tbaa !9
  %11 = call i32 @list_equal(ptr noundef %9, ptr noundef %10)
  %12 = icmp ne i32 %11, 0
  br i1 %12, label %15, label %13

13:                                               ; preds = %0
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  call void @exit(i32 noundef 1) #9
  unreachable

15:                                               ; preds = %0
  br label %16

16:                                               ; preds = %21, %15
  %17 = load ptr, ptr %3, align 8, !tbaa !9
  %18 = call i32 @list_empty(ptr noundef %17)
  %19 = icmp ne i32 %18, 0
  %20 = xor i1 %19, true
  br i1 %20, label %21, label %25

21:                                               ; preds = %16
  %22 = load ptr, ptr %4, align 8, !tbaa !9
  %23 = load ptr, ptr %3, align 8, !tbaa !9
  %24 = call ptr @list_pop_head(ptr noundef %23)
  call void @list_push_tail(ptr noundef %22, ptr noundef %24)
  br label %16, !llvm.loop !25

25:                                               ; preds = %16
  %26 = load ptr, ptr %3, align 8, !tbaa !9
  %27 = call i32 @list_empty(ptr noundef %26)
  %28 = icmp ne i32 %27, 0
  br i1 %28, label %31, label %29

29:                                               ; preds = %25
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.5)
  call void @exit(i32 noundef 1) #9
  unreachable

31:                                               ; preds = %25
  br label %32

32:                                               ; preds = %37, %31
  %33 = load ptr, ptr %4, align 8, !tbaa !9
  %34 = call i32 @list_empty(ptr noundef %33)
  %35 = icmp ne i32 %34, 0
  %36 = xor i1 %35, true
  br i1 %36, label %37, label %41

37:                                               ; preds = %32
  %38 = load ptr, ptr %3, align 8, !tbaa !9
  %39 = load ptr, ptr %4, align 8, !tbaa !9
  %40 = call ptr @list_pop_tail(ptr noundef %39)
  call void @list_push_tail(ptr noundef %38, ptr noundef %40)
  br label %32, !llvm.loop !26

41:                                               ; preds = %32
  %42 = load ptr, ptr %4, align 8, !tbaa !9
  %43 = call i32 @list_empty(ptr noundef %42)
  %44 = icmp ne i32 %43, 0
  br i1 %44, label %47, label %45

45:                                               ; preds = %41
  %46 = call i32 (ptr, ...) @printf(ptr noundef @.str.6)
  call void @exit(i32 noundef 1) #9
  unreachable

47:                                               ; preds = %41
  %48 = load ptr, ptr %2, align 8, !tbaa !9
  call void @list_reverse(ptr noundef %48)
  %49 = load ptr, ptr %2, align 8, !tbaa !9
  %50 = call ptr @list_first(ptr noundef %49)
  %51 = getelementptr inbounds nuw %struct.DLL, ptr %50, i32 0, i32 0
  %52 = load i32, ptr %51, align 8, !tbaa !15
  %53 = icmp ne i32 %52, 100
  br i1 %53, label %54, label %60

54:                                               ; preds = %47
  %55 = load ptr, ptr %2, align 8, !tbaa !9
  %56 = call ptr @list_first(ptr noundef %55)
  %57 = getelementptr inbounds nuw %struct.DLL, ptr %56, i32 0, i32 0
  %58 = load i32, ptr %57, align 8, !tbaa !15
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef 100, i32 noundef %58)
  call void @exit(i32 noundef 1) #9
  unreachable

60:                                               ; preds = %47
  %61 = load ptr, ptr %2, align 8, !tbaa !9
  %62 = call ptr @list_last(ptr noundef %61)
  %63 = getelementptr inbounds nuw %struct.DLL, ptr %62, i32 0, i32 0
  %64 = load i32, ptr %63, align 8, !tbaa !15
  %65 = icmp ne i32 %64, 1
  br i1 %65, label %66, label %72

66:                                               ; preds = %60
  %67 = load ptr, ptr %2, align 8, !tbaa !9
  %68 = call ptr @list_last(ptr noundef %67)
  %69 = getelementptr inbounds nuw %struct.DLL, ptr %68, i32 0, i32 0
  %70 = load i32, ptr %69, align 8, !tbaa !15
  %71 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef 100, i32 noundef %70)
  call void @exit(i32 noundef 1) #9
  unreachable

72:                                               ; preds = %60
  %73 = load ptr, ptr %3, align 8, !tbaa !9
  %74 = call ptr @list_first(ptr noundef %73)
  %75 = getelementptr inbounds nuw %struct.DLL, ptr %74, i32 0, i32 0
  %76 = load i32, ptr %75, align 8, !tbaa !15
  %77 = icmp ne i32 %76, 100
  br i1 %77, label %78, label %84

78:                                               ; preds = %72
  %79 = load ptr, ptr %3, align 8, !tbaa !9
  %80 = call ptr @list_first(ptr noundef %79)
  %81 = getelementptr inbounds nuw %struct.DLL, ptr %80, i32 0, i32 0
  %82 = load i32, ptr %81, align 8, !tbaa !15
  %83 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef 100, i32 noundef %82)
  call void @exit(i32 noundef 1) #9
  unreachable

84:                                               ; preds = %72
  %85 = load ptr, ptr %3, align 8, !tbaa !9
  %86 = call ptr @list_last(ptr noundef %85)
  %87 = getelementptr inbounds nuw %struct.DLL, ptr %86, i32 0, i32 0
  %88 = load i32, ptr %87, align 8, !tbaa !15
  %89 = icmp ne i32 %88, 1
  br i1 %89, label %90, label %96

90:                                               ; preds = %84
  %91 = load ptr, ptr %3, align 8, !tbaa !9
  %92 = call ptr @list_last(ptr noundef %91)
  %93 = getelementptr inbounds nuw %struct.DLL, ptr %92, i32 0, i32 0
  %94 = load i32, ptr %93, align 8, !tbaa !15
  %95 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef 100, i32 noundef %94)
  call void @exit(i32 noundef 1) #9
  unreachable

96:                                               ; preds = %84
  %97 = load ptr, ptr %2, align 8, !tbaa !9
  %98 = call i32 @list_length(ptr noundef %97)
  %99 = icmp ne i32 %98, 100
  br i1 %99, label %100, label %104

100:                                              ; preds = %96
  %101 = load ptr, ptr %2, align 8, !tbaa !9
  %102 = call i32 @list_length(ptr noundef %101)
  %103 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, i32 noundef 100, i32 noundef %102)
  call void @exit(i32 noundef 1) #9
  unreachable

104:                                              ; preds = %96
  %105 = load ptr, ptr %2, align 8, !tbaa !9
  %106 = load ptr, ptr %3, align 8, !tbaa !9
  %107 = call i32 @list_equal(ptr noundef %105, ptr noundef %106)
  %108 = icmp ne i32 %107, 0
  br i1 %108, label %111, label %109

109:                                              ; preds = %104
  %110 = call i32 (ptr, ...) @printf(ptr noundef @.str.11)
  call void @exit(i32 noundef 1) #9
  unreachable

111:                                              ; preds = %104
  %112 = load ptr, ptr %2, align 8, !tbaa !9
  %113 = call i32 @list_length(ptr noundef %112)
  store i32 %113, ptr %1, align 4, !tbaa !20
  %114 = load ptr, ptr %2, align 8, !tbaa !9
  call void @free(ptr noundef %114) #7
  %115 = load ptr, ptr %3, align 8, !tbaa !9
  call void @free(ptr noundef %115) #7
  %116 = load ptr, ptr %4, align 8, !tbaa !9
  call void @free(ptr noundef %116) #7
  %117 = load i32, ptr %1, align 4, !tbaa !20
  call void @llvm.lifetime.end.p0(ptr %4) #7
  call void @llvm.lifetime.end.p0(ptr %3) #7
  call void @llvm.lifetime.end.p0(ptr %2) #7
  call void @llvm.lifetime.end.p0(ptr %1) #7
  ret i32 %117
}

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #4

; Function Attrs: nounwind uwtable
define internal ptr @list_first(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 1
  %5 = load ptr, ptr %4, align 8, !tbaa !14
  ret ptr %5
}

; Function Attrs: nounwind
declare void @free(ptr noundef) #5

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !20
  store ptr %1, ptr %5, align 8, !tbaa !27
  call void @llvm.lifetime.start.p0(ptr %6) #7
  %8 = load i32, ptr %4, align 4, !tbaa !20
  %9 = icmp eq i32 %8, 2
  br i1 %9, label %10, label %15

10:                                               ; preds = %2
  %11 = load ptr, ptr %5, align 8, !tbaa !27
  %12 = getelementptr inbounds ptr, ptr %11, i64 1
  %13 = load ptr, ptr %12, align 8, !tbaa !18
  %14 = call i32 @atoi(ptr noundef %13) #10
  br label %16

15:                                               ; preds = %2
  br label %16

16:                                               ; preds = %15, %10
  %17 = phi i32 [ %14, %10 ], [ 3000000, %15 ]
  store i32 %17, ptr %6, align 4, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %7) #7
  store i32 0, ptr %7, align 4, !tbaa !20
  br label %18

18:                                               ; preds = %22, %16
  %19 = load i32, ptr %6, align 4, !tbaa !20
  %20 = add nsw i32 %19, -1
  store i32 %20, ptr %6, align 4, !tbaa !20
  %21 = icmp ne i32 %19, 0
  br i1 %21, label %22, label %24

22:                                               ; preds = %18
  %23 = call i32 @test_lists()
  store i32 %23, ptr %7, align 4, !tbaa !20
  br label %18, !llvm.loop !30

24:                                               ; preds = %18
  %25 = load i32, ptr %7, align 4, !tbaa !20
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %25)
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  ret i32 0
}

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #6 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !18
  %3 = load ptr, ptr %2, align 8, !tbaa !18
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #7
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nounwind }
attributes #8 = { nounwind allocsize(0) }
attributes #9 = { noreturn nounwind }
attributes #10 = { nounwind willreturn memory(read) }

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
!10 = !{!"p1 _ZTS3DLL", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !10, i64 16}
!13 = !{!"DLL", !6, i64 0, !10, i64 8, !10, i64 16}
!14 = !{!13, !10, i64 8}
!15 = !{!13, !6, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = !{!19, !19, i64 0}
!19 = !{!"p1 omnipotent char", !11, i64 0}
!20 = !{!6, !6, i64 0}
!21 = distinct !{!21, !17}
!22 = distinct !{!22, !17}
!23 = distinct !{!23, !17}
!24 = distinct !{!24, !17}
!25 = distinct !{!25, !17}
!26 = distinct !{!26, !17}
!27 = !{!28, !28, i64 0}
!28 = !{!"p2 omnipotent char", !29, i64 0}
!29 = !{!"any p2 pointer", !11, i64 0}
!30 = distinct !{!30, !17}
