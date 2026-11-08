; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/hash.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/hash.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/hash.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.ht_node = type { ptr, i32, ptr }
%struct.ht_ht = type { i32, ptr, i32, ptr, i32 }

@.str = private unnamed_addr constant [15 x i8] c"malloc ht_node\00", align 1
@.str.1 = private unnamed_addr constant [14 x i8] c"strdup newkey\00", align 1
@ht_prime_list = internal global [28 x i64] [i64 53, i64 97, i64 193, i64 389, i64 769, i64 1543, i64 3079, i64 6151, i64 12289, i64 24593, i64 49157, i64 98317, i64 196613, i64 393241, i64 786433, i64 1572869, i64 3145739, i64 6291469, i64 12582917, i64 25165843, i64 50331653, i64 100663319, i64 201326611, i64 402653189, i64 805306457, i64 1610612741, i64 3221225473, i64 4294967291], align 16
@.str.2 = private unnamed_addr constant [3 x i8] c"%x\00", align 1
@.str.3 = private unnamed_addr constant [3 x i8] c"%d\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local ptr @ht_node_create(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #10
  call void @llvm.lifetime.start.p0(ptr %4) #10
  %5 = call noalias ptr @malloc(i64 noundef 24) #11
  store ptr %5, ptr %4, align 8, !tbaa !12
  %6 = icmp eq ptr %5, null
  br i1 %6, label %7, label %8

7:                                                ; preds = %1
  call void @perror(ptr noundef @.str) #12
  call void @exit(i32 noundef 1) #13
  unreachable

8:                                                ; preds = %1
  %9 = load ptr, ptr %2, align 8, !tbaa !9
  %10 = call noalias ptr @strdup(ptr noundef %9) #10
  store ptr %10, ptr %3, align 8, !tbaa !9
  %11 = icmp eq ptr %10, null
  br i1 %11, label %12, label %13

12:                                               ; preds = %8
  call void @perror(ptr noundef @.str.1) #12
  call void @exit(i32 noundef 1) #13
  unreachable

13:                                               ; preds = %8
  %14 = load ptr, ptr %3, align 8, !tbaa !9
  %15 = load ptr, ptr %4, align 8, !tbaa !12
  %16 = getelementptr inbounds nuw %struct.ht_node, ptr %15, i32 0, i32 0
  store ptr %14, ptr %16, align 8, !tbaa !14
  %17 = load ptr, ptr %4, align 8, !tbaa !12
  %18 = getelementptr inbounds nuw %struct.ht_node, ptr %17, i32 0, i32 1
  store i32 0, ptr %18, align 8, !tbaa !16
  %19 = load ptr, ptr %4, align 8, !tbaa !12
  %20 = getelementptr inbounds nuw %struct.ht_node, ptr %19, i32 0, i32 2
  store ptr null, ptr %20, align 8, !tbaa !17
  %21 = load ptr, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %4) #10
  call void @llvm.lifetime.end.p0(ptr %3) #10
  ret ptr %21
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: cold
declare void @perror(ptr noundef) #3

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #4

; Function Attrs: nounwind
declare noalias ptr @strdup(ptr noundef) #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local ptr @ht_create(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %3) #10
  store i32 0, ptr %3, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %4) #10
  %5 = call noalias ptr @malloc(i64 noundef 40) #11
  store ptr %5, ptr %4, align 8, !tbaa !19
  br label %6

6:                                                ; preds = %14, %1
  %7 = load i32, ptr %3, align 4, !tbaa !18
  %8 = sext i32 %7 to i64
  %9 = getelementptr inbounds [28 x i64], ptr @ht_prime_list, i64 0, i64 %8
  %10 = load i64, ptr %9, align 8, !tbaa !21
  %11 = load i32, ptr %2, align 4, !tbaa !18
  %12 = sext i32 %11 to i64
  %13 = icmp ult i64 %10, %12
  br i1 %13, label %14, label %17

14:                                               ; preds = %6
  %15 = load i32, ptr %3, align 4, !tbaa !18
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %3, align 4, !tbaa !18
  br label %6, !llvm.loop !23

17:                                               ; preds = %6
  %18 = load i32, ptr %3, align 4, !tbaa !18
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds [28 x i64], ptr @ht_prime_list, i64 0, i64 %19
  %21 = load i64, ptr %20, align 8, !tbaa !21
  %22 = trunc i64 %21 to i32
  %23 = load ptr, ptr %4, align 8, !tbaa !19
  %24 = getelementptr inbounds nuw %struct.ht_ht, ptr %23, i32 0, i32 0
  store i32 %22, ptr %24, align 8, !tbaa !25
  %25 = load ptr, ptr %4, align 8, !tbaa !19
  %26 = getelementptr inbounds nuw %struct.ht_ht, ptr %25, i32 0, i32 0
  %27 = load i32, ptr %26, align 8, !tbaa !25
  %28 = sext i32 %27 to i64
  %29 = call noalias ptr @calloc(i64 noundef %28, i64 noundef 8) #14
  %30 = load ptr, ptr %4, align 8, !tbaa !19
  %31 = getelementptr inbounds nuw %struct.ht_ht, ptr %30, i32 0, i32 1
  store ptr %29, ptr %31, align 8, !tbaa !29
  %32 = load ptr, ptr %4, align 8, !tbaa !19
  %33 = getelementptr inbounds nuw %struct.ht_ht, ptr %32, i32 0, i32 2
  store i32 0, ptr %33, align 8, !tbaa !30
  %34 = load ptr, ptr %4, align 8, !tbaa !19
  %35 = getelementptr inbounds nuw %struct.ht_ht, ptr %34, i32 0, i32 3
  store ptr null, ptr %35, align 8, !tbaa !31
  %36 = load ptr, ptr %4, align 8, !tbaa !19
  %37 = getelementptr inbounds nuw %struct.ht_ht, ptr %36, i32 0, i32 4
  store i32 0, ptr %37, align 8, !tbaa !32
  %38 = load ptr, ptr %4, align 8, !tbaa !19
  call void @llvm.lifetime.end.p0(ptr %4) #10
  call void @llvm.lifetime.end.p0(ptr %3) #10
  ret ptr %38
}

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #6

; Function Attrs: nounwind uwtable
define dso_local void @ht_destroy(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !19
  call void @llvm.lifetime.start.p0(ptr %3) #10
  call void @llvm.lifetime.start.p0(ptr %4) #10
  call void @llvm.lifetime.start.p0(ptr %5) #10
  store i32 0, ptr %5, align 4, !tbaa !18
  br label %6

6:                                                ; preds = %33, %1
  %7 = load i32, ptr %5, align 4, !tbaa !18
  %8 = load ptr, ptr %2, align 8, !tbaa !19
  %9 = getelementptr inbounds nuw %struct.ht_ht, ptr %8, i32 0, i32 0
  %10 = load i32, ptr %9, align 8, !tbaa !25
  %11 = icmp slt i32 %7, %10
  br i1 %11, label %12, label %36

12:                                               ; preds = %6
  %13 = load ptr, ptr %2, align 8, !tbaa !19
  %14 = getelementptr inbounds nuw %struct.ht_ht, ptr %13, i32 0, i32 1
  %15 = load ptr, ptr %14, align 8, !tbaa !29
  %16 = load i32, ptr %5, align 4, !tbaa !18
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds ptr, ptr %15, i64 %17
  %19 = load ptr, ptr %18, align 8, !tbaa !12
  store ptr %19, ptr %4, align 8, !tbaa !12
  br label %20

20:                                               ; preds = %23, %12
  %21 = load ptr, ptr %4, align 8, !tbaa !12
  %22 = icmp ne ptr %21, null
  br i1 %22, label %23, label %32

23:                                               ; preds = %20
  %24 = load ptr, ptr %4, align 8, !tbaa !12
  store ptr %24, ptr %3, align 8, !tbaa !12
  %25 = load ptr, ptr %4, align 8, !tbaa !12
  %26 = getelementptr inbounds nuw %struct.ht_node, ptr %25, i32 0, i32 2
  %27 = load ptr, ptr %26, align 8, !tbaa !17
  store ptr %27, ptr %4, align 8, !tbaa !12
  %28 = load ptr, ptr %3, align 8, !tbaa !12
  %29 = getelementptr inbounds nuw %struct.ht_node, ptr %28, i32 0, i32 0
  %30 = load ptr, ptr %29, align 8, !tbaa !14
  call void @free(ptr noundef %30) #10
  %31 = load ptr, ptr %3, align 8, !tbaa !12
  call void @free(ptr noundef %31) #10
  br label %20, !llvm.loop !33

32:                                               ; preds = %20
  br label %33

33:                                               ; preds = %32
  %34 = load i32, ptr %5, align 4, !tbaa !18
  %35 = add nsw i32 %34, 1
  store i32 %35, ptr %5, align 4, !tbaa !18
  br label %6, !llvm.loop !34

36:                                               ; preds = %6
  %37 = load ptr, ptr %2, align 8, !tbaa !19
  %38 = getelementptr inbounds nuw %struct.ht_ht, ptr %37, i32 0, i32 1
  %39 = load ptr, ptr %38, align 8, !tbaa !29
  call void @free(ptr noundef %39) #10
  %40 = load ptr, ptr %2, align 8, !tbaa !19
  call void @free(ptr noundef %40) #10
  call void @llvm.lifetime.end.p0(ptr %5) #10
  call void @llvm.lifetime.end.p0(ptr %4) #10
  call void @llvm.lifetime.end.p0(ptr %3) #10
  ret void
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
  %8 = alloca i32, align 4
  %9 = alloca [32 x i8], align 16
  %10 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !18
  store ptr %1, ptr %5, align 8, !tbaa !35
  call void @llvm.lifetime.start.p0(ptr %6) #10
  call void @llvm.lifetime.start.p0(ptr %7) #10
  store i32 0, ptr %7, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %8) #10
  %11 = load i32, ptr %4, align 4, !tbaa !18
  %12 = icmp eq i32 %11, 2
  br i1 %12, label %13, label %18

13:                                               ; preds = %2
  %14 = load ptr, ptr %5, align 8, !tbaa !35
  %15 = getelementptr inbounds ptr, ptr %14, i64 1
  %16 = load ptr, ptr %15, align 8, !tbaa !9
  %17 = call i32 @atoi(ptr noundef %16) #15
  br label %19

18:                                               ; preds = %2
  br label %19

19:                                               ; preds = %18, %13
  %20 = phi i32 [ %17, %13 ], [ 3500000, %18 ]
  store i32 %20, ptr %8, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %9) #10
  call void @llvm.lifetime.start.p0(ptr %10) #10
  %21 = load i32, ptr %8, align 4, !tbaa !18
  %22 = call ptr @ht_create(i32 noundef %21)
  store ptr %22, ptr %10, align 8, !tbaa !19
  store i32 1, ptr %6, align 4, !tbaa !18
  br label %23

23:                                               ; preds = %36, %19
  %24 = load i32, ptr %6, align 4, !tbaa !18
  %25 = load i32, ptr %8, align 4, !tbaa !18
  %26 = icmp sle i32 %24, %25
  br i1 %26, label %27, label %39

27:                                               ; preds = %23
  %28 = getelementptr inbounds [32 x i8], ptr %9, i64 0, i64 0
  %29 = load i32, ptr %6, align 4, !tbaa !18
  %30 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef %28, ptr noundef @.str.2, i32 noundef %29) #10
  %31 = load i32, ptr %6, align 4, !tbaa !18
  %32 = load ptr, ptr %10, align 8, !tbaa !19
  %33 = getelementptr inbounds [32 x i8], ptr %9, i64 0, i64 0
  %34 = call ptr @ht_find_new(ptr noundef %32, ptr noundef %33)
  %35 = getelementptr inbounds nuw %struct.ht_node, ptr %34, i32 0, i32 1
  store i32 %31, ptr %35, align 8, !tbaa !16
  br label %36

36:                                               ; preds = %27
  %37 = load i32, ptr %6, align 4, !tbaa !18
  %38 = add nsw i32 %37, 1
  store i32 %38, ptr %6, align 4, !tbaa !18
  br label %23, !llvm.loop !37

39:                                               ; preds = %23
  %40 = load i32, ptr %8, align 4, !tbaa !18
  store i32 %40, ptr %6, align 4, !tbaa !18
  br label %41

41:                                               ; preds = %56, %39
  %42 = load i32, ptr %6, align 4, !tbaa !18
  %43 = icmp sgt i32 %42, 0
  br i1 %43, label %44, label %59

44:                                               ; preds = %41
  %45 = getelementptr inbounds [32 x i8], ptr %9, i64 0, i64 0
  %46 = load i32, ptr %6, align 4, !tbaa !18
  %47 = call i32 (ptr, ptr, ...) @sprintf(ptr noundef %45, ptr noundef @.str.3, i32 noundef %46) #10
  %48 = load ptr, ptr %10, align 8, !tbaa !19
  %49 = getelementptr inbounds [32 x i8], ptr %9, i64 0, i64 0
  %50 = call ptr @ht_find(ptr noundef %48, ptr noundef %49)
  %51 = icmp ne ptr %50, null
  br i1 %51, label %52, label %55

52:                                               ; preds = %44
  %53 = load i32, ptr %7, align 4, !tbaa !18
  %54 = add nsw i32 %53, 1
  store i32 %54, ptr %7, align 4, !tbaa !18
  br label %55

55:                                               ; preds = %52, %44
  br label %56

56:                                               ; preds = %55
  %57 = load i32, ptr %6, align 4, !tbaa !18
  %58 = add nsw i32 %57, -1
  store i32 %58, ptr %6, align 4, !tbaa !18
  br label %41, !llvm.loop !38

59:                                               ; preds = %41
  %60 = load ptr, ptr %10, align 8, !tbaa !19
  call void @ht_destroy(ptr noundef %60)
  %61 = load i32, ptr %7, align 4, !tbaa !18
  %62 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %61)
  call void @llvm.lifetime.end.p0(ptr %10) #10
  call void @llvm.lifetime.end.p0(ptr %9) #10
  call void @llvm.lifetime.end.p0(ptr %8) #10
  call void @llvm.lifetime.end.p0(ptr %7) #10
  call void @llvm.lifetime.end.p0(ptr %6) #10
  ret i32 0
}

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #7 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #10
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

; Function Attrs: nounwind
declare i32 @sprintf(ptr noundef, ptr noundef, ...) #5

; Function Attrs: nounwind uwtable
define internal ptr @ht_find_new(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !19
  store ptr %1, ptr %5, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #10
  %10 = load ptr, ptr %4, align 8, !tbaa !19
  %11 = load ptr, ptr %5, align 8, !tbaa !9
  %12 = call i32 @ht_hashcode(ptr noundef %10, ptr noundef %11)
  store i32 %12, ptr %6, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %7) #10
  store ptr null, ptr %7, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %8) #10
  %13 = load ptr, ptr %4, align 8, !tbaa !19
  %14 = getelementptr inbounds nuw %struct.ht_ht, ptr %13, i32 0, i32 1
  %15 = load ptr, ptr %14, align 8, !tbaa !29
  %16 = load i32, ptr %6, align 4, !tbaa !18
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds ptr, ptr %15, i64 %17
  %19 = load ptr, ptr %18, align 8, !tbaa !12
  store ptr %19, ptr %8, align 8, !tbaa !12
  br label %20

20:                                               ; preds = %32, %2
  %21 = load ptr, ptr %8, align 8, !tbaa !12
  %22 = icmp ne ptr %21, null
  br i1 %22, label %23, label %37

23:                                               ; preds = %20
  %24 = load ptr, ptr %5, align 8, !tbaa !9
  %25 = load ptr, ptr %8, align 8, !tbaa !12
  %26 = getelementptr inbounds nuw %struct.ht_node, ptr %25, i32 0, i32 0
  %27 = load ptr, ptr %26, align 8, !tbaa !14
  %28 = call i32 @strcmp(ptr noundef %24, ptr noundef %27) #15
  %29 = icmp eq i32 %28, 0
  br i1 %29, label %30, label %32

30:                                               ; preds = %23
  %31 = load ptr, ptr %8, align 8, !tbaa !12
  store ptr %31, ptr %3, align 8
  store i32 1, ptr %9, align 4
  br label %58

32:                                               ; preds = %23
  %33 = load ptr, ptr %8, align 8, !tbaa !12
  store ptr %33, ptr %7, align 8, !tbaa !12
  %34 = load ptr, ptr %8, align 8, !tbaa !12
  %35 = getelementptr inbounds nuw %struct.ht_node, ptr %34, i32 0, i32 2
  %36 = load ptr, ptr %35, align 8, !tbaa !17
  store ptr %36, ptr %8, align 8, !tbaa !12
  br label %20, !llvm.loop !39

37:                                               ; preds = %20
  %38 = load ptr, ptr %4, align 8, !tbaa !19
  %39 = getelementptr inbounds nuw %struct.ht_ht, ptr %38, i32 0, i32 4
  %40 = load i32, ptr %39, align 8, !tbaa !32
  %41 = add nsw i32 %40, 1
  store i32 %41, ptr %39, align 8, !tbaa !32
  %42 = load ptr, ptr %7, align 8, !tbaa !12
  %43 = icmp ne ptr %42, null
  br i1 %43, label %44, label %49

44:                                               ; preds = %37
  %45 = load ptr, ptr %5, align 8, !tbaa !9
  %46 = call ptr @ht_node_create(ptr noundef %45)
  %47 = load ptr, ptr %7, align 8, !tbaa !12
  %48 = getelementptr inbounds nuw %struct.ht_node, ptr %47, i32 0, i32 2
  store ptr %46, ptr %48, align 8, !tbaa !17
  store ptr %46, ptr %3, align 8
  store i32 1, ptr %9, align 4
  br label %58

49:                                               ; preds = %37
  %50 = load ptr, ptr %5, align 8, !tbaa !9
  %51 = call ptr @ht_node_create(ptr noundef %50)
  %52 = load ptr, ptr %4, align 8, !tbaa !19
  %53 = getelementptr inbounds nuw %struct.ht_ht, ptr %52, i32 0, i32 1
  %54 = load ptr, ptr %53, align 8, !tbaa !29
  %55 = load i32, ptr %6, align 4, !tbaa !18
  %56 = sext i32 %55 to i64
  %57 = getelementptr inbounds ptr, ptr %54, i64 %56
  store ptr %51, ptr %57, align 8, !tbaa !12
  store ptr %51, ptr %3, align 8
  store i32 1, ptr %9, align 4
  br label %58

58:                                               ; preds = %49, %44, %30
  call void @llvm.lifetime.end.p0(ptr %8) #10
  call void @llvm.lifetime.end.p0(ptr %7) #10
  call void @llvm.lifetime.end.p0(ptr %6) #10
  %59 = load ptr, ptr %3, align 8
  ret ptr %59
}

; Function Attrs: nounwind uwtable
define internal ptr @ht_find(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !19
  store ptr %1, ptr %5, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #10
  %9 = load ptr, ptr %4, align 8, !tbaa !19
  %10 = load ptr, ptr %5, align 8, !tbaa !9
  %11 = call i32 @ht_hashcode(ptr noundef %9, ptr noundef %10)
  store i32 %11, ptr %6, align 4, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %7) #10
  %12 = load ptr, ptr %4, align 8, !tbaa !19
  %13 = getelementptr inbounds nuw %struct.ht_ht, ptr %12, i32 0, i32 1
  %14 = load ptr, ptr %13, align 8, !tbaa !29
  %15 = load i32, ptr %6, align 4, !tbaa !18
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds ptr, ptr %14, i64 %16
  %18 = load ptr, ptr %17, align 8, !tbaa !12
  store ptr %18, ptr %7, align 8, !tbaa !12
  br label %19

19:                                               ; preds = %31, %2
  %20 = load ptr, ptr %7, align 8, !tbaa !12
  %21 = icmp ne ptr %20, null
  br i1 %21, label %22, label %35

22:                                               ; preds = %19
  %23 = load ptr, ptr %5, align 8, !tbaa !9
  %24 = load ptr, ptr %7, align 8, !tbaa !12
  %25 = getelementptr inbounds nuw %struct.ht_node, ptr %24, i32 0, i32 0
  %26 = load ptr, ptr %25, align 8, !tbaa !14
  %27 = call i32 @strcmp(ptr noundef %23, ptr noundef %26) #15
  %28 = icmp eq i32 %27, 0
  br i1 %28, label %29, label %31

29:                                               ; preds = %22
  %30 = load ptr, ptr %7, align 8, !tbaa !12
  store ptr %30, ptr %3, align 8
  store i32 1, ptr %8, align 4
  br label %36

31:                                               ; preds = %22
  %32 = load ptr, ptr %7, align 8, !tbaa !12
  %33 = getelementptr inbounds nuw %struct.ht_node, ptr %32, i32 0, i32 2
  %34 = load ptr, ptr %33, align 8, !tbaa !17
  store ptr %34, ptr %7, align 8, !tbaa !12
  br label %19, !llvm.loop !40

35:                                               ; preds = %19
  store ptr null, ptr %3, align 8
  store i32 1, ptr %8, align 4
  br label %36

36:                                               ; preds = %35, %29
  call void @llvm.lifetime.end.p0(ptr %7) #10
  call void @llvm.lifetime.end.p0(ptr %6) #10
  %37 = load ptr, ptr %3, align 8
  ret ptr %37
}

declare i32 @printf(ptr noundef, ...) #8

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #5

; Function Attrs: nounwind uwtable
define internal i32 @ht_hashcode(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i64, align 8
  store ptr %0, ptr %3, align 8, !tbaa !19
  store ptr %1, ptr %4, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #10
  store i64 0, ptr %5, align 8, !tbaa !21
  br label %6

6:                                                ; preds = %17, %2
  %7 = load ptr, ptr %4, align 8, !tbaa !9
  %8 = load i8, ptr %7, align 1, !tbaa !41
  %9 = icmp ne i8 %8, 0
  br i1 %9, label %10, label %20

10:                                               ; preds = %6
  %11 = load i64, ptr %5, align 8, !tbaa !21
  %12 = mul i64 5, %11
  %13 = load ptr, ptr %4, align 8, !tbaa !9
  %14 = load i8, ptr %13, align 1, !tbaa !41
  %15 = sext i8 %14 to i64
  %16 = add i64 %12, %15
  store i64 %16, ptr %5, align 8, !tbaa !21
  br label %17

17:                                               ; preds = %10
  %18 = load ptr, ptr %4, align 8, !tbaa !9
  %19 = getelementptr inbounds nuw i8, ptr %18, i32 1
  store ptr %19, ptr %4, align 8, !tbaa !9
  br label %6, !llvm.loop !42

20:                                               ; preds = %6
  %21 = load i64, ptr %5, align 8, !tbaa !21
  %22 = load ptr, ptr %3, align 8, !tbaa !19
  %23 = getelementptr inbounds nuw %struct.ht_ht, ptr %22, i32 0, i32 0
  %24 = load i32, ptr %23, align 8, !tbaa !25
  %25 = sext i32 %24 to i64
  %26 = urem i64 %21, %25
  %27 = trunc i64 %26 to i32
  call void @llvm.lifetime.end.p0(ptr %5) #10
  ret i32 %27
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #9

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { cold "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind allocsize(0,1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { nounwind }
attributes #11 = { nounwind allocsize(0) }
attributes #12 = { cold }
attributes #13 = { noreturn nounwind }
attributes #14 = { nounwind allocsize(0,1) }
attributes #15 = { nounwind willreturn memory(read) }

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 _ZTS7ht_node", !11, i64 0}
!14 = !{!15, !10, i64 0}
!15 = !{!"ht_node", !10, i64 0, !6, i64 8, !13, i64 16}
!16 = !{!15, !6, i64 8}
!17 = !{!15, !13, i64 16}
!18 = !{!6, !6, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"p1 _ZTS5ht_ht", !11, i64 0}
!21 = !{!22, !22, i64 0}
!22 = !{!"long", !7, i64 0}
!23 = distinct !{!23, !24}
!24 = !{!"llvm.loop.mustprogress"}
!25 = !{!26, !6, i64 0}
!26 = !{!"ht_ht", !6, i64 0, !27, i64 8, !6, i64 16, !13, i64 24, !6, i64 32}
!27 = !{!"p2 _ZTS7ht_node", !28, i64 0}
!28 = !{!"any p2 pointer", !11, i64 0}
!29 = !{!26, !27, i64 8}
!30 = !{!26, !6, i64 16}
!31 = !{!26, !13, i64 24}
!32 = !{!26, !6, i64 32}
!33 = distinct !{!33, !24}
!34 = distinct !{!34, !24}
!35 = !{!36, !36, i64 0}
!36 = !{!"p2 omnipotent char", !28, i64 0}
!37 = distinct !{!37, !24}
!38 = distinct !{!38, !24}
!39 = distinct !{!39, !24}
!40 = distinct !{!40, !24}
!41 = !{!7, !7, i64 0}
!42 = distinct !{!42, !24}
