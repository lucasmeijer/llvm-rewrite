; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
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

; Function Attrs: noinline nounwind uwtable
define dso_local void @list_push_tail(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %6 = load ptr, ptr %3, align 8
  %7 = getelementptr inbounds nuw %struct.DLL, ptr %6, i32 0, i32 2
  %8 = load ptr, ptr %7, align 8
  store ptr %8, ptr %5, align 8
  %9 = load ptr, ptr %4, align 8
  %10 = load ptr, ptr %5, align 8
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 1
  store ptr %9, ptr %11, align 8
  %12 = load ptr, ptr %3, align 8
  %13 = load ptr, ptr %4, align 8
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 1
  store ptr %12, ptr %14, align 8
  %15 = load ptr, ptr %4, align 8
  %16 = load ptr, ptr %3, align 8
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 2
  store ptr %15, ptr %17, align 8
  %18 = load ptr, ptr %5, align 8
  %19 = load ptr, ptr %4, align 8
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 2
  store ptr %18, ptr %20, align 8
  %21 = load ptr, ptr %3, align 8
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 0
  %23 = load i32, ptr %22, align 8
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %22, align 8
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @list_pop_tail(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  %6 = load ptr, ptr %3, align 8
  %7 = call i32 @list_empty(ptr noundef %6)
  %8 = icmp ne i32 %7, 0
  br i1 %8, label %9, label %10

9:                                                ; preds = %1
  store ptr null, ptr %2, align 8
  br label %28

10:                                               ; preds = %1
  %11 = load ptr, ptr %3, align 8
  %12 = getelementptr inbounds nuw %struct.DLL, ptr %11, i32 0, i32 2
  %13 = load ptr, ptr %12, align 8
  store ptr %13, ptr %5, align 8
  %14 = load ptr, ptr %5, align 8
  %15 = getelementptr inbounds nuw %struct.DLL, ptr %14, i32 0, i32 2
  %16 = load ptr, ptr %15, align 8
  store ptr %16, ptr %4, align 8
  %17 = load ptr, ptr %3, align 8
  %18 = load ptr, ptr %4, align 8
  %19 = getelementptr inbounds nuw %struct.DLL, ptr %18, i32 0, i32 1
  store ptr %17, ptr %19, align 8
  %20 = load ptr, ptr %4, align 8
  %21 = load ptr, ptr %3, align 8
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 2
  store ptr %20, ptr %22, align 8
  %23 = load ptr, ptr %3, align 8
  %24 = getelementptr inbounds nuw %struct.DLL, ptr %23, i32 0, i32 0
  %25 = load i32, ptr %24, align 8
  %26 = add nsw i32 %25, -1
  store i32 %26, ptr %24, align 8
  %27 = load ptr, ptr %5, align 8
  store ptr %27, ptr %2, align 8
  br label %28

28:                                               ; preds = %10, %9
  %29 = load ptr, ptr %2, align 8
  ret ptr %29
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @list_empty(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = call i32 @list_length(ptr noundef %3)
  %5 = icmp eq i32 %4, 0
  %6 = zext i1 %5 to i32
  ret i32 %6
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @list_push_head(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %6 = load ptr, ptr %3, align 8
  %7 = getelementptr inbounds nuw %struct.DLL, ptr %6, i32 0, i32 1
  %8 = load ptr, ptr %7, align 8
  store ptr %8, ptr %5, align 8
  %9 = load ptr, ptr %4, align 8
  %10 = load ptr, ptr %3, align 8
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 1
  store ptr %9, ptr %11, align 8
  %12 = load ptr, ptr %4, align 8
  %13 = load ptr, ptr %5, align 8
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 2
  store ptr %12, ptr %14, align 8
  %15 = load ptr, ptr %5, align 8
  %16 = load ptr, ptr %4, align 8
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 1
  store ptr %15, ptr %17, align 8
  %18 = load ptr, ptr %3, align 8
  %19 = load ptr, ptr %4, align 8
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 2
  store ptr %18, ptr %20, align 8
  %21 = load ptr, ptr %3, align 8
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 0
  %23 = load i32, ptr %22, align 8
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %22, align 8
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @list_pop_head(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  %5 = load ptr, ptr %3, align 8
  %6 = call i32 @list_empty(ptr noundef %5)
  %7 = icmp ne i32 %6, 0
  br i1 %7, label %8, label %9

8:                                                ; preds = %1
  store ptr null, ptr %2, align 8
  br label %28

9:                                                ; preds = %1
  %10 = load ptr, ptr %3, align 8
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 1
  %12 = load ptr, ptr %11, align 8
  store ptr %12, ptr %4, align 8
  %13 = load ptr, ptr %4, align 8
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 1
  %15 = load ptr, ptr %14, align 8
  %16 = load ptr, ptr %3, align 8
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 1
  store ptr %15, ptr %17, align 8
  %18 = load ptr, ptr %3, align 8
  %19 = load ptr, ptr %4, align 8
  %20 = getelementptr inbounds nuw %struct.DLL, ptr %19, i32 0, i32 1
  %21 = load ptr, ptr %20, align 8
  %22 = getelementptr inbounds nuw %struct.DLL, ptr %21, i32 0, i32 2
  store ptr %18, ptr %22, align 8
  %23 = load ptr, ptr %3, align 8
  %24 = getelementptr inbounds nuw %struct.DLL, ptr %23, i32 0, i32 0
  %25 = load i32, ptr %24, align 8
  %26 = add nsw i32 %25, -1
  store i32 %26, ptr %24, align 8
  %27 = load ptr, ptr %4, align 8
  store ptr %27, ptr %2, align 8
  br label %28

28:                                               ; preds = %9, %8
  %29 = load ptr, ptr %2, align 8
  ret ptr %29
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @list_equal(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  store ptr %0, ptr %4, align 8
  store ptr %1, ptr %5, align 8
  %8 = load ptr, ptr %4, align 8
  store ptr %8, ptr %6, align 8
  %9 = load ptr, ptr %5, align 8
  store ptr %9, ptr %7, align 8
  br label %10

10:                                               ; preds = %26, %2
  %11 = load ptr, ptr %6, align 8
  %12 = getelementptr inbounds nuw %struct.DLL, ptr %11, i32 0, i32 1
  %13 = load ptr, ptr %12, align 8
  %14 = load ptr, ptr %4, align 8
  %15 = icmp ne ptr %13, %14
  br i1 %15, label %16, label %33

16:                                               ; preds = %10
  %17 = load ptr, ptr %6, align 8
  %18 = getelementptr inbounds nuw %struct.DLL, ptr %17, i32 0, i32 0
  %19 = load i32, ptr %18, align 8
  %20 = load ptr, ptr %7, align 8
  %21 = getelementptr inbounds nuw %struct.DLL, ptr %20, i32 0, i32 0
  %22 = load i32, ptr %21, align 8
  %23 = icmp ne i32 %19, %22
  br i1 %23, label %24, label %25

24:                                               ; preds = %16
  store i32 0, ptr %3, align 4
  br label %49

25:                                               ; preds = %16
  br label %26

26:                                               ; preds = %25
  %27 = load ptr, ptr %6, align 8
  %28 = getelementptr inbounds nuw %struct.DLL, ptr %27, i32 0, i32 1
  %29 = load ptr, ptr %28, align 8
  store ptr %29, ptr %6, align 8
  %30 = load ptr, ptr %7, align 8
  %31 = getelementptr inbounds nuw %struct.DLL, ptr %30, i32 0, i32 1
  %32 = load ptr, ptr %31, align 8
  store ptr %32, ptr %7, align 8
  br label %10, !llvm.loop !5

33:                                               ; preds = %10
  %34 = load ptr, ptr %6, align 8
  %35 = getelementptr inbounds nuw %struct.DLL, ptr %34, i32 0, i32 0
  %36 = load i32, ptr %35, align 8
  %37 = load ptr, ptr %7, align 8
  %38 = getelementptr inbounds nuw %struct.DLL, ptr %37, i32 0, i32 0
  %39 = load i32, ptr %38, align 8
  %40 = icmp ne i32 %36, %39
  br i1 %40, label %41, label %42

41:                                               ; preds = %33
  store i32 0, ptr %3, align 4
  br label %49

42:                                               ; preds = %33
  %43 = load ptr, ptr %7, align 8
  %44 = getelementptr inbounds nuw %struct.DLL, ptr %43, i32 0, i32 1
  %45 = load ptr, ptr %44, align 8
  %46 = load ptr, ptr %5, align 8
  %47 = icmp eq ptr %45, %46
  %48 = zext i1 %47 to i32
  store i32 %48, ptr %3, align 4
  br label %49

49:                                               ; preds = %42, %41, %24
  %50 = load i32, ptr %3, align 4
  ret i32 %50
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @list_print(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %8 = load ptr, ptr %4, align 8
  %9 = getelementptr inbounds nuw %struct.DLL, ptr %8, i32 0, i32 1
  %10 = load ptr, ptr %9, align 8
  store ptr %10, ptr %6, align 8
  store i32 0, ptr %7, align 4
  %11 = load ptr, ptr %3, align 8
  %12 = call i32 @puts(ptr noundef %11)
  %13 = load ptr, ptr %4, align 8
  %14 = call i32 @list_length(ptr noundef %13)
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %14)
  %16 = load ptr, ptr %4, align 8
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 1
  %18 = load ptr, ptr %17, align 8
  store ptr %18, ptr %5, align 8
  br label %19

19:                                               ; preds = %42, %2
  %20 = load ptr, ptr %5, align 8
  %21 = getelementptr inbounds nuw %struct.DLL, ptr %20, i32 0, i32 1
  %22 = load ptr, ptr %21, align 8
  %23 = load ptr, ptr %6, align 8
  %24 = icmp ne ptr %22, %23
  br i1 %24, label %25, label %46

25:                                               ; preds = %19
  %26 = load i32, ptr %7, align 4
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %7, align 4
  %28 = load ptr, ptr %5, align 8
  %29 = getelementptr inbounds nuw %struct.DLL, ptr %28, i32 0, i32 0
  %30 = load i32, ptr %29, align 8
  %31 = load ptr, ptr %5, align 8
  %32 = getelementptr inbounds nuw %struct.DLL, ptr %31, i32 0, i32 1
  %33 = load ptr, ptr %32, align 8
  %34 = getelementptr inbounds nuw %struct.DLL, ptr %33, i32 0, i32 0
  %35 = load i32, ptr %34, align 8
  %36 = load ptr, ptr %5, align 8
  %37 = getelementptr inbounds nuw %struct.DLL, ptr %36, i32 0, i32 2
  %38 = load ptr, ptr %37, align 8
  %39 = getelementptr inbounds nuw %struct.DLL, ptr %38, i32 0, i32 0
  %40 = load i32, ptr %39, align 8
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %27, i32 noundef %30, i32 noundef %35, i32 noundef %40)
  br label %42

42:                                               ; preds = %25
  %43 = load ptr, ptr %5, align 8
  %44 = getelementptr inbounds nuw %struct.DLL, ptr %43, i32 0, i32 1
  %45 = load ptr, ptr %44, align 8
  store ptr %45, ptr %5, align 8
  br label %19, !llvm.loop !7

46:                                               ; preds = %19
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %48 = load ptr, ptr %5, align 8
  %49 = getelementptr inbounds nuw %struct.DLL, ptr %48, i32 0, i32 1
  %50 = load ptr, ptr %49, align 8
  %51 = getelementptr inbounds nuw %struct.DLL, ptr %50, i32 0, i32 0
  %52 = load i32, ptr %51, align 8
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %52)
  ret void
}

declare i32 @puts(ptr noundef) #1

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal i32 @list_length(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 0
  %5 = load i32, ptr %4, align 8
  ret i32 %5
}

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @list_new() #0 {
  %1 = alloca ptr, align 8
  %2 = call noalias ptr @malloc(i64 noundef 24) #6
  store ptr %2, ptr %1, align 8
  %3 = load ptr, ptr %1, align 8
  %4 = load ptr, ptr %1, align 8
  %5 = getelementptr inbounds nuw %struct.DLL, ptr %4, i32 0, i32 1
  store ptr %3, ptr %5, align 8
  %6 = load ptr, ptr %1, align 8
  %7 = load ptr, ptr %1, align 8
  %8 = getelementptr inbounds nuw %struct.DLL, ptr %7, i32 0, i32 2
  store ptr %6, ptr %8, align 8
  %9 = load ptr, ptr %1, align 8
  %10 = getelementptr inbounds nuw %struct.DLL, ptr %9, i32 0, i32 0
  store i32 0, ptr %10, align 8
  %11 = load ptr, ptr %1, align 8
  ret ptr %11
}

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @list_sequence(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  store i32 %0, ptr %3, align 4
  store i32 %1, ptr %4, align 4
  %10 = load i32, ptr %3, align 4
  %11 = load i32, ptr %4, align 4
  %12 = icmp sgt i32 %10, %11
  br i1 %12, label %13, label %17

13:                                               ; preds = %2
  %14 = load i32, ptr %3, align 4
  store i32 %14, ptr %6, align 4
  %15 = load i32, ptr %4, align 4
  store i32 %15, ptr %3, align 4
  %16 = load i32, ptr %6, align 4
  store i32 %16, ptr %4, align 4
  br label %17

17:                                               ; preds = %13, %2
  %18 = load i32, ptr %4, align 4
  %19 = load i32, ptr %3, align 4
  %20 = sub nsw i32 %18, %19
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %5, align 4
  %22 = load i32, ptr %5, align 4
  %23 = add nsw i32 %22, 1
  %24 = sext i32 %23 to i64
  %25 = mul i64 %24, 24
  %26 = call noalias ptr @malloc(i64 noundef %25) #6
  store ptr %26, ptr %9, align 8
  %27 = load i32, ptr %3, align 4
  %28 = add nsw i32 %27, -1
  store i32 %28, ptr %3, align 4
  store i32 0, ptr %7, align 4
  store i32 1, ptr %8, align 4
  br label %29

29:                                               ; preds = %61, %17
  %30 = load i32, ptr %7, align 4
  %31 = load i32, ptr %5, align 4
  %32 = icmp slt i32 %30, %31
  br i1 %32, label %33, label %66

33:                                               ; preds = %29
  %34 = load ptr, ptr %9, align 8
  %35 = load i32, ptr %7, align 4
  %36 = add nsw i32 %35, 1
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds %struct.DLL, ptr %34, i64 %37
  %39 = load ptr, ptr %9, align 8
  %40 = load i32, ptr %7, align 4
  %41 = sext i32 %40 to i64
  %42 = getelementptr inbounds %struct.DLL, ptr %39, i64 %41
  %43 = getelementptr inbounds nuw %struct.DLL, ptr %42, i32 0, i32 1
  store ptr %38, ptr %43, align 8
  %44 = load ptr, ptr %9, align 8
  %45 = load i32, ptr %8, align 4
  %46 = sub nsw i32 %45, 1
  %47 = sext i32 %46 to i64
  %48 = getelementptr inbounds %struct.DLL, ptr %44, i64 %47
  %49 = load ptr, ptr %9, align 8
  %50 = load i32, ptr %8, align 4
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds %struct.DLL, ptr %49, i64 %51
  %53 = getelementptr inbounds nuw %struct.DLL, ptr %52, i32 0, i32 2
  store ptr %48, ptr %53, align 8
  %54 = load i32, ptr %3, align 4
  %55 = add nsw i32 %54, 1
  store i32 %55, ptr %3, align 4
  %56 = load ptr, ptr %9, align 8
  %57 = load i32, ptr %7, align 4
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds %struct.DLL, ptr %56, i64 %58
  %60 = getelementptr inbounds nuw %struct.DLL, ptr %59, i32 0, i32 0
  store i32 %54, ptr %60, align 8
  br label %61

61:                                               ; preds = %33
  %62 = load i32, ptr %7, align 4
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %7, align 4
  %64 = load i32, ptr %8, align 4
  %65 = add nsw i32 %64, 1
  store i32 %65, ptr %8, align 4
  br label %29, !llvm.loop !8

66:                                               ; preds = %29
  %67 = load ptr, ptr %9, align 8
  %68 = load i32, ptr %5, align 4
  %69 = sext i32 %68 to i64
  %70 = getelementptr inbounds %struct.DLL, ptr %67, i64 %69
  %71 = load ptr, ptr %9, align 8
  %72 = getelementptr inbounds %struct.DLL, ptr %71, i64 0
  %73 = getelementptr inbounds nuw %struct.DLL, ptr %72, i32 0, i32 2
  store ptr %70, ptr %73, align 8
  %74 = load ptr, ptr %9, align 8
  %75 = getelementptr inbounds %struct.DLL, ptr %74, i64 0
  %76 = load ptr, ptr %9, align 8
  %77 = load i32, ptr %5, align 4
  %78 = sext i32 %77 to i64
  %79 = getelementptr inbounds %struct.DLL, ptr %76, i64 %78
  %80 = getelementptr inbounds nuw %struct.DLL, ptr %79, i32 0, i32 1
  store ptr %75, ptr %80, align 8
  %81 = load ptr, ptr %9, align 8
  %82 = load i32, ptr %5, align 4
  %83 = sub nsw i32 %82, 1
  %84 = sext i32 %83 to i64
  %85 = getelementptr inbounds %struct.DLL, ptr %81, i64 %84
  %86 = load ptr, ptr %9, align 8
  %87 = load i32, ptr %5, align 4
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds %struct.DLL, ptr %86, i64 %88
  %90 = getelementptr inbounds nuw %struct.DLL, ptr %89, i32 0, i32 2
  store ptr %85, ptr %90, align 8
  %91 = load i32, ptr %3, align 4
  %92 = load ptr, ptr %9, align 8
  %93 = load i32, ptr %5, align 4
  %94 = sext i32 %93 to i64
  %95 = getelementptr inbounds %struct.DLL, ptr %92, i64 %94
  %96 = getelementptr inbounds nuw %struct.DLL, ptr %95, i32 0, i32 0
  store i32 %91, ptr %96, align 8
  %97 = load i32, ptr %5, align 4
  %98 = load ptr, ptr %9, align 8
  %99 = getelementptr inbounds %struct.DLL, ptr %98, i64 0
  %100 = getelementptr inbounds nuw %struct.DLL, ptr %99, i32 0, i32 0
  store i32 %97, ptr %100, align 8
  %101 = load ptr, ptr %9, align 8
  ret ptr %101
}

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @list_copy(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %8 = load ptr, ptr %2, align 8
  %9 = call i32 @list_length(ptr noundef %8)
  store i32 %9, ptr %5, align 4
  %10 = load i32, ptr %5, align 4
  %11 = add nsw i32 %10, 1
  %12 = sext i32 %11 to i64
  %13 = mul i64 %12, 24
  %14 = call noalias ptr @malloc(i64 noundef %13) #6
  store ptr %14, ptr %7, align 8
  store i32 0, ptr %3, align 4
  store i32 1, ptr %4, align 4
  %15 = load ptr, ptr %2, align 8
  store ptr %15, ptr %6, align 8
  br label %16

16:                                               ; preds = %47, %1
  %17 = load i32, ptr %3, align 4
  %18 = load i32, ptr %5, align 4
  %19 = icmp slt i32 %17, %18
  br i1 %19, label %20, label %55

20:                                               ; preds = %16
  %21 = load ptr, ptr %7, align 8
  %22 = load i32, ptr %4, align 4
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds %struct.DLL, ptr %21, i64 %23
  %25 = load ptr, ptr %7, align 8
  %26 = load i32, ptr %3, align 4
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds %struct.DLL, ptr %25, i64 %27
  %29 = getelementptr inbounds nuw %struct.DLL, ptr %28, i32 0, i32 1
  store ptr %24, ptr %29, align 8
  %30 = load ptr, ptr %7, align 8
  %31 = load i32, ptr %3, align 4
  %32 = sext i32 %31 to i64
  %33 = getelementptr inbounds %struct.DLL, ptr %30, i64 %32
  %34 = load ptr, ptr %7, align 8
  %35 = load i32, ptr %4, align 4
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds %struct.DLL, ptr %34, i64 %36
  %38 = getelementptr inbounds nuw %struct.DLL, ptr %37, i32 0, i32 2
  store ptr %33, ptr %38, align 8
  %39 = load ptr, ptr %6, align 8
  %40 = getelementptr inbounds nuw %struct.DLL, ptr %39, i32 0, i32 0
  %41 = load i32, ptr %40, align 8
  %42 = load ptr, ptr %7, align 8
  %43 = load i32, ptr %3, align 4
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds %struct.DLL, ptr %42, i64 %44
  %46 = getelementptr inbounds nuw %struct.DLL, ptr %45, i32 0, i32 0
  store i32 %41, ptr %46, align 8
  br label %47

47:                                               ; preds = %20
  %48 = load i32, ptr %3, align 4
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %3, align 4
  %50 = load i32, ptr %4, align 4
  %51 = add nsw i32 %50, 1
  store i32 %51, ptr %4, align 4
  %52 = load ptr, ptr %6, align 8
  %53 = getelementptr inbounds nuw %struct.DLL, ptr %52, i32 0, i32 1
  %54 = load ptr, ptr %53, align 8
  store ptr %54, ptr %6, align 8
  br label %16, !llvm.loop !9

55:                                               ; preds = %16
  %56 = load ptr, ptr %7, align 8
  %57 = load i32, ptr %5, align 4
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds %struct.DLL, ptr %56, i64 %58
  %60 = load ptr, ptr %7, align 8
  %61 = getelementptr inbounds %struct.DLL, ptr %60, i64 0
  %62 = getelementptr inbounds nuw %struct.DLL, ptr %61, i32 0, i32 2
  store ptr %59, ptr %62, align 8
  %63 = load ptr, ptr %7, align 8
  %64 = getelementptr inbounds %struct.DLL, ptr %63, i64 0
  %65 = load ptr, ptr %7, align 8
  %66 = load i32, ptr %5, align 4
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds %struct.DLL, ptr %65, i64 %67
  %69 = getelementptr inbounds nuw %struct.DLL, ptr %68, i32 0, i32 1
  store ptr %64, ptr %69, align 8
  %70 = load ptr, ptr %2, align 8
  %71 = call ptr @list_last(ptr noundef %70)
  %72 = getelementptr inbounds nuw %struct.DLL, ptr %71, i32 0, i32 0
  %73 = load i32, ptr %72, align 8
  %74 = load ptr, ptr %7, align 8
  %75 = load i32, ptr %5, align 4
  %76 = sext i32 %75 to i64
  %77 = getelementptr inbounds %struct.DLL, ptr %74, i64 %76
  %78 = getelementptr inbounds nuw %struct.DLL, ptr %77, i32 0, i32 0
  store i32 %73, ptr %78, align 8
  %79 = load ptr, ptr %7, align 8
  ret ptr %79
}

; Function Attrs: noinline nounwind uwtable
define internal ptr @list_last(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 2
  %5 = load ptr, ptr %4, align 8
  ret ptr %5
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @list_reverse(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %5 = load ptr, ptr %2, align 8
  store ptr %5, ptr %4, align 8
  br label %6

6:                                                ; preds = %19, %1
  %7 = load ptr, ptr %4, align 8
  %8 = getelementptr inbounds nuw %struct.DLL, ptr %7, i32 0, i32 1
  %9 = load ptr, ptr %8, align 8
  store ptr %9, ptr %3, align 8
  %10 = load ptr, ptr %4, align 8
  %11 = getelementptr inbounds nuw %struct.DLL, ptr %10, i32 0, i32 2
  %12 = load ptr, ptr %11, align 8
  %13 = load ptr, ptr %4, align 8
  %14 = getelementptr inbounds nuw %struct.DLL, ptr %13, i32 0, i32 1
  store ptr %12, ptr %14, align 8
  %15 = load ptr, ptr %3, align 8
  %16 = load ptr, ptr %4, align 8
  %17 = getelementptr inbounds nuw %struct.DLL, ptr %16, i32 0, i32 2
  store ptr %15, ptr %17, align 8
  %18 = load ptr, ptr %3, align 8
  store ptr %18, ptr %4, align 8
  br label %19

19:                                               ; preds = %6
  %20 = load ptr, ptr %4, align 8
  %21 = load ptr, ptr %2, align 8
  %22 = icmp ne ptr %20, %21
  br i1 %22, label %6, label %23, !llvm.loop !10

23:                                               ; preds = %19
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @test_lists() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  %5 = call ptr @list_sequence(i32 noundef 1, i32 noundef 100)
  store ptr %5, ptr %2, align 8
  %6 = load ptr, ptr %2, align 8
  %7 = call ptr @list_copy(ptr noundef %6)
  store ptr %7, ptr %3, align 8
  %8 = call ptr @list_new()
  store ptr %8, ptr %4, align 8
  %9 = load ptr, ptr %3, align 8
  %10 = load ptr, ptr %2, align 8
  %11 = call i32 @list_equal(ptr noundef %9, ptr noundef %10)
  %12 = icmp ne i32 %11, 0
  br i1 %12, label %15, label %13

13:                                               ; preds = %0
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  call void @exit(i32 noundef 1) #7
  unreachable

15:                                               ; preds = %0
  br label %16

16:                                               ; preds = %21, %15
  %17 = load ptr, ptr %3, align 8
  %18 = call i32 @list_empty(ptr noundef %17)
  %19 = icmp ne i32 %18, 0
  %20 = xor i1 %19, true
  br i1 %20, label %21, label %25

21:                                               ; preds = %16
  %22 = load ptr, ptr %4, align 8
  %23 = load ptr, ptr %3, align 8
  %24 = call ptr @list_pop_head(ptr noundef %23)
  call void @list_push_tail(ptr noundef %22, ptr noundef %24)
  br label %16, !llvm.loop !11

25:                                               ; preds = %16
  %26 = load ptr, ptr %3, align 8
  %27 = call i32 @list_empty(ptr noundef %26)
  %28 = icmp ne i32 %27, 0
  br i1 %28, label %31, label %29

29:                                               ; preds = %25
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.5)
  call void @exit(i32 noundef 1) #7
  unreachable

31:                                               ; preds = %25
  br label %32

32:                                               ; preds = %37, %31
  %33 = load ptr, ptr %4, align 8
  %34 = call i32 @list_empty(ptr noundef %33)
  %35 = icmp ne i32 %34, 0
  %36 = xor i1 %35, true
  br i1 %36, label %37, label %41

37:                                               ; preds = %32
  %38 = load ptr, ptr %3, align 8
  %39 = load ptr, ptr %4, align 8
  %40 = call ptr @list_pop_tail(ptr noundef %39)
  call void @list_push_tail(ptr noundef %38, ptr noundef %40)
  br label %32, !llvm.loop !12

41:                                               ; preds = %32
  %42 = load ptr, ptr %4, align 8
  %43 = call i32 @list_empty(ptr noundef %42)
  %44 = icmp ne i32 %43, 0
  br i1 %44, label %47, label %45

45:                                               ; preds = %41
  %46 = call i32 (ptr, ...) @printf(ptr noundef @.str.6)
  call void @exit(i32 noundef 1) #7
  unreachable

47:                                               ; preds = %41
  %48 = load ptr, ptr %2, align 8
  call void @list_reverse(ptr noundef %48)
  %49 = load ptr, ptr %2, align 8
  %50 = call ptr @list_first(ptr noundef %49)
  %51 = getelementptr inbounds nuw %struct.DLL, ptr %50, i32 0, i32 0
  %52 = load i32, ptr %51, align 8
  %53 = icmp ne i32 %52, 100
  br i1 %53, label %54, label %60

54:                                               ; preds = %47
  %55 = load ptr, ptr %2, align 8
  %56 = call ptr @list_first(ptr noundef %55)
  %57 = getelementptr inbounds nuw %struct.DLL, ptr %56, i32 0, i32 0
  %58 = load i32, ptr %57, align 8
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef 100, i32 noundef %58)
  call void @exit(i32 noundef 1) #7
  unreachable

60:                                               ; preds = %47
  %61 = load ptr, ptr %2, align 8
  %62 = call ptr @list_last(ptr noundef %61)
  %63 = getelementptr inbounds nuw %struct.DLL, ptr %62, i32 0, i32 0
  %64 = load i32, ptr %63, align 8
  %65 = icmp ne i32 %64, 1
  br i1 %65, label %66, label %72

66:                                               ; preds = %60
  %67 = load ptr, ptr %2, align 8
  %68 = call ptr @list_last(ptr noundef %67)
  %69 = getelementptr inbounds nuw %struct.DLL, ptr %68, i32 0, i32 0
  %70 = load i32, ptr %69, align 8
  %71 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef 100, i32 noundef %70)
  call void @exit(i32 noundef 1) #7
  unreachable

72:                                               ; preds = %60
  %73 = load ptr, ptr %3, align 8
  %74 = call ptr @list_first(ptr noundef %73)
  %75 = getelementptr inbounds nuw %struct.DLL, ptr %74, i32 0, i32 0
  %76 = load i32, ptr %75, align 8
  %77 = icmp ne i32 %76, 100
  br i1 %77, label %78, label %84

78:                                               ; preds = %72
  %79 = load ptr, ptr %3, align 8
  %80 = call ptr @list_first(ptr noundef %79)
  %81 = getelementptr inbounds nuw %struct.DLL, ptr %80, i32 0, i32 0
  %82 = load i32, ptr %81, align 8
  %83 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef 100, i32 noundef %82)
  call void @exit(i32 noundef 1) #7
  unreachable

84:                                               ; preds = %72
  %85 = load ptr, ptr %3, align 8
  %86 = call ptr @list_last(ptr noundef %85)
  %87 = getelementptr inbounds nuw %struct.DLL, ptr %86, i32 0, i32 0
  %88 = load i32, ptr %87, align 8
  %89 = icmp ne i32 %88, 1
  br i1 %89, label %90, label %96

90:                                               ; preds = %84
  %91 = load ptr, ptr %3, align 8
  %92 = call ptr @list_last(ptr noundef %91)
  %93 = getelementptr inbounds nuw %struct.DLL, ptr %92, i32 0, i32 0
  %94 = load i32, ptr %93, align 8
  %95 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef 100, i32 noundef %94)
  call void @exit(i32 noundef 1) #7
  unreachable

96:                                               ; preds = %84
  %97 = load ptr, ptr %2, align 8
  %98 = call i32 @list_length(ptr noundef %97)
  %99 = icmp ne i32 %98, 100
  br i1 %99, label %100, label %104

100:                                              ; preds = %96
  %101 = load ptr, ptr %2, align 8
  %102 = call i32 @list_length(ptr noundef %101)
  %103 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, i32 noundef 100, i32 noundef %102)
  call void @exit(i32 noundef 1) #7
  unreachable

104:                                              ; preds = %96
  %105 = load ptr, ptr %2, align 8
  %106 = load ptr, ptr %3, align 8
  %107 = call i32 @list_equal(ptr noundef %105, ptr noundef %106)
  %108 = icmp ne i32 %107, 0
  br i1 %108, label %111, label %109

109:                                              ; preds = %104
  %110 = call i32 (ptr, ...) @printf(ptr noundef @.str.11)
  call void @exit(i32 noundef 1) #7
  unreachable

111:                                              ; preds = %104
  %112 = load ptr, ptr %2, align 8
  %113 = call i32 @list_length(ptr noundef %112)
  store i32 %113, ptr %1, align 4
  %114 = load ptr, ptr %2, align 8
  call void @free(ptr noundef %114) #8
  %115 = load ptr, ptr %3, align 8
  call void @free(ptr noundef %115) #8
  %116 = load ptr, ptr %4, align 8
  call void @free(ptr noundef %116) #8
  %117 = load i32, ptr %1, align 4
  ret i32 %117
}

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #3

; Function Attrs: noinline nounwind uwtable
define internal ptr @list_first(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.DLL, ptr %3, i32 0, i32 1
  %5 = load ptr, ptr %4, align 8
  ret ptr %5
}

; Function Attrs: nounwind
declare void @free(ptr noundef) #4

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  %8 = load i32, ptr %4, align 4
  %9 = icmp eq i32 %8, 2
  br i1 %9, label %10, label %15

10:                                               ; preds = %2
  %11 = load ptr, ptr %5, align 8
  %12 = getelementptr inbounds ptr, ptr %11, i64 1
  %13 = load ptr, ptr %12, align 8
  %14 = call i32 @atoi(ptr noundef %13) #9
  br label %16

15:                                               ; preds = %2
  br label %16

16:                                               ; preds = %15, %10
  %17 = phi i32 [ %14, %10 ], [ 3000000, %15 ]
  store i32 %17, ptr %6, align 4
  store i32 0, ptr %7, align 4
  br label %18

18:                                               ; preds = %22, %16
  %19 = load i32, ptr %6, align 4
  %20 = add nsw i32 %19, -1
  store i32 %20, ptr %6, align 4
  %21 = icmp ne i32 %19, 0
  br i1 %21, label %22, label %24

22:                                               ; preds = %18
  %23 = call i32 @test_lists()
  store i32 %23, ptr %7, align 4
  br label %18, !llvm.loop !13

24:                                               ; preds = %18
  %25 = load i32, ptr %7, align 4
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %25)
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @atoi(ptr noundef) #5

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind allocsize(0) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { noreturn nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind allocsize(0) }
attributes #7 = { noreturn nounwind }
attributes #8 = { nounwind }
attributes #9 = { nounwind willreturn memory(read) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
!7 = distinct !{!7, !6}
!8 = distinct !{!8, !6}
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !6}
!11 = distinct !{!11, !6}
!12 = distinct !{!12, !6}
!13 = distinct !{!13, !6}
