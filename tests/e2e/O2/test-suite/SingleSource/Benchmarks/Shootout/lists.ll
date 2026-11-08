; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/lists.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [12 x i8] c"length: %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [28 x i8] c"i:%3d  v:%3d  n:%3d  p:%3d\0A\00", align 1
@.str.3 = private unnamed_addr constant [31 x i8] c"[val of next of tail is:  %d]\0A\00", align 1
@.str.7 = private unnamed_addr constant [42 x i8] c"li1 first value wrong, wanted %d, got %d\0A\00", align 1
@.str.8 = private unnamed_addr constant [37 x i8] c"last value wrong, wanted %d, got %d\0A\00", align 1
@.str.9 = private unnamed_addr constant [42 x i8] c"li2 first value wrong, wanted %d, got %d\0A\00", align 1
@.str.12 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@str = private unnamed_addr constant [33 x i8] c"[last entry points to list head]\00", align 1
@str.13 = private unnamed_addr constant [26 x i8] c"li2 and li1 are not equal\00", align 1
@str.16 = private unnamed_addr constant [26 x i8] c"li1 and li2 are not equal\00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @list_push_tail(ptr noundef %0, ptr noundef %1) local_unnamed_addr #0 {
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %4 = load ptr, ptr %3, align 8, !tbaa !9
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 8
  store ptr %1, ptr %5, align 8, !tbaa !13
  %6 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store ptr %0, ptr %6, align 8, !tbaa !13
  store ptr %1, ptr %3, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store ptr %4, ptr %7, align 8, !tbaa !9
  %8 = load i32, ptr %0, align 8, !tbaa !14
  %9 = add nsw i32 %8, 1
  store i32 %9, ptr %0, align 8, !tbaa !14
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local ptr @list_pop_tail(ptr noundef %0) local_unnamed_addr #1 {
  %2 = load i32, ptr %0, align 8, !tbaa !14
  %3 = icmp eq i32 %2, 0
  br i1 %3, label %11, label %4

4:                                                ; preds = %1
  %5 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %6 = load ptr, ptr %5, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw i8, ptr %6, i64 16
  %8 = load ptr, ptr %7, align 8, !tbaa !9
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 8
  store ptr %0, ptr %9, align 8, !tbaa !13
  store ptr %8, ptr %5, align 8, !tbaa !9
  %10 = add nsw i32 %2, -1
  store i32 %10, ptr %0, align 8, !tbaa !14
  br label %11

11:                                               ; preds = %1, %4
  %12 = phi ptr [ %6, %4 ], [ null, %1 ]
  ret ptr %12
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @list_push_head(ptr noundef %0, ptr noundef %1) local_unnamed_addr #0 {
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %4 = load ptr, ptr %3, align 8, !tbaa !13
  store ptr %1, ptr %3, align 8, !tbaa !13
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 16
  store ptr %1, ptr %5, align 8, !tbaa !9
  %6 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store ptr %4, ptr %6, align 8, !tbaa !13
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store ptr %0, ptr %7, align 8, !tbaa !9
  %8 = load i32, ptr %0, align 8, !tbaa !14
  %9 = add nsw i32 %8, 1
  store i32 %9, ptr %0, align 8, !tbaa !14
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local ptr @list_pop_head(ptr noundef %0) local_unnamed_addr #1 {
  %2 = load i32, ptr %0, align 8, !tbaa !14
  %3 = icmp eq i32 %2, 0
  br i1 %3, label %11, label %4

4:                                                ; preds = %1
  %5 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %6 = load ptr, ptr %5, align 8, !tbaa !13
  %7 = getelementptr inbounds nuw i8, ptr %6, i64 8
  %8 = load ptr, ptr %7, align 8, !tbaa !13
  store ptr %8, ptr %5, align 8, !tbaa !13
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 16
  store ptr %0, ptr %9, align 8, !tbaa !9
  %10 = add nsw i32 %2, -1
  store i32 %10, ptr %0, align 8, !tbaa !14
  br label %11

11:                                               ; preds = %1, %4
  %12 = phi ptr [ %6, %4 ], [ null, %1 ]
  ret ptr %12
}

; Function Attrs: nofree norecurse nosync nounwind memory(read, inaccessiblemem: none, target_mem: none) uwtable
define dso_local range(i32 0, 2) i32 @list_equal(ptr nofree noundef readonly captures(address) %0, ptr nofree noundef readonly captures(address) %1) local_unnamed_addr #2 {
  %3 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %4 = load ptr, ptr %3, align 8, !tbaa !13
  %5 = icmp eq ptr %4, %0
  br i1 %5, label %19, label %6

6:                                                ; preds = %2, %13
  %7 = phi ptr [ %17, %13 ], [ %4, %2 ]
  %8 = phi ptr [ %15, %13 ], [ %1, %2 ]
  %9 = phi ptr [ %7, %13 ], [ %0, %2 ]
  %10 = load i32, ptr %9, align 8, !tbaa !14
  %11 = load i32, ptr %8, align 8, !tbaa !14
  %12 = icmp eq i32 %10, %11
  br i1 %12, label %13, label %30

13:                                               ; preds = %6
  %14 = getelementptr inbounds nuw i8, ptr %8, i64 8
  %15 = load ptr, ptr %14, align 8, !tbaa !13
  %16 = getelementptr inbounds nuw i8, ptr %7, i64 8
  %17 = load ptr, ptr %16, align 8, !tbaa !13
  %18 = icmp eq ptr %17, %0
  br i1 %18, label %19, label %6, !llvm.loop !15

19:                                               ; preds = %13, %2
  %20 = phi ptr [ %0, %2 ], [ %7, %13 ]
  %21 = phi ptr [ %1, %2 ], [ %15, %13 ]
  %22 = load i32, ptr %20, align 8, !tbaa !14
  %23 = load i32, ptr %21, align 8, !tbaa !14
  %24 = icmp eq i32 %22, %23
  br i1 %24, label %25, label %30

25:                                               ; preds = %19
  %26 = getelementptr inbounds nuw i8, ptr %21, i64 8
  %27 = load ptr, ptr %26, align 8, !tbaa !13
  %28 = icmp eq ptr %27, %1
  %29 = zext i1 %28 to i32
  br label %30

30:                                               ; preds = %6, %19, %25
  %31 = phi i32 [ %29, %25 ], [ 0, %19 ], [ 0, %6 ]
  ret i32 %31
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @list_print(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #3 {
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %4 = load ptr, ptr %3, align 8, !tbaa !13
  %5 = tail call i32 @puts(ptr noundef nonnull dereferenceable(1) %0)
  %6 = load i32, ptr %1, align 8, !tbaa !14
  %7 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %6)
  %8 = load ptr, ptr %3, align 8, !tbaa !13
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 8
  %10 = load ptr, ptr %9, align 8, !tbaa !13
  %11 = icmp eq ptr %10, %4
  br i1 %11, label %28, label %12

12:                                               ; preds = %2, %12
  %13 = phi ptr [ %26, %12 ], [ %10, %2 ]
  %14 = phi ptr [ %25, %12 ], [ %9, %2 ]
  %15 = phi ptr [ %24, %12 ], [ %8, %2 ]
  %16 = phi i32 [ %17, %12 ], [ 0, %2 ]
  %17 = add nuw nsw i32 %16, 1
  %18 = load i32, ptr %15, align 8, !tbaa !14
  %19 = load i32, ptr %13, align 8, !tbaa !14
  %20 = getelementptr inbounds nuw i8, ptr %15, i64 16
  %21 = load ptr, ptr %20, align 8, !tbaa !9
  %22 = load i32, ptr %21, align 8, !tbaa !14
  %23 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %17, i32 noundef %18, i32 noundef %19, i32 noundef %22)
  %24 = load ptr, ptr %14, align 8, !tbaa !13
  %25 = getelementptr inbounds nuw i8, ptr %24, i64 8
  %26 = load ptr, ptr %25, align 8, !tbaa !13
  %27 = icmp eq ptr %26, %4
  br i1 %27, label %28, label %12, !llvm.loop !17

28:                                               ; preds = %12, %2
  %29 = phi ptr [ %9, %2 ], [ %25, %12 ]
  %30 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %31 = load ptr, ptr %29, align 8, !tbaa !13
  %32 = load i32, ptr %31, align 8, !tbaa !14
  %33 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i32 noundef %32)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #4

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: mustprogress nofree nounwind willreturn memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable
define dso_local noundef ptr @list_new() local_unnamed_addr #5 {
  %1 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #16
  %2 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store ptr %1, ptr %2, align 8, !tbaa !13
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store ptr %1, ptr %3, align 8, !tbaa !9
  store i32 0, ptr %1, align 8, !tbaa !14
  ret ptr %1
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #6

; Function Attrs: nofree nounwind memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable
define dso_local noundef ptr @list_sequence(i32 noundef %0, i32 noundef %1) local_unnamed_addr #7 {
  %3 = tail call i32 @llvm.smax.i32(i32 %0, i32 %1)
  %4 = tail call i32 @llvm.smin.i32(i32 %0, i32 %1)
  %5 = sub nsw i32 %3, %4
  %6 = add nsw i32 %5, 2
  %7 = sext i32 %6 to i64
  %8 = mul nsw i64 %7, 24
  %9 = tail call noalias ptr @malloc(i64 noundef %8) #16
  %10 = add nsw i32 %4, -1
  %11 = icmp slt i32 %5, 0
  br i1 %11, label %58, label %12

12:                                               ; preds = %2
  %13 = add i32 %3, 1
  %14 = sub i32 %13, %4
  %15 = zext i32 %14 to i64
  %16 = and i64 %15, 1
  %17 = icmp eq i32 %14, 1
  br i1 %17, label %45, label %18

18:                                               ; preds = %12
  %19 = and i64 %15, 4294967294
  br label %20

20:                                               ; preds = %20, %18
  %21 = phi i64 [ 0, %18 ], [ %33, %20 ]
  %22 = phi i64 [ 1, %18 ], [ %40, %20 ]
  %23 = phi i32 [ %10, %18 ], [ %39, %20 ]
  %24 = phi i64 [ 0, %18 ], [ %41, %20 ]
  %25 = or disjoint i64 %21, 1
  %26 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %25
  %27 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %21
  %28 = getelementptr inbounds nuw i8, ptr %27, i64 8
  store ptr %26, ptr %28, align 8, !tbaa !13
  %29 = getelementptr [24 x i8], ptr %9, i64 %22
  %30 = getelementptr i8, ptr %29, i64 -24
  %31 = getelementptr inbounds nuw i8, ptr %29, i64 16
  store ptr %30, ptr %31, align 8, !tbaa !9
  %32 = add nsw i32 %23, 1
  store i32 %23, ptr %27, align 8, !tbaa !14
  %33 = add nuw nsw i64 %21, 2
  %34 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %33
  %35 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %25
  %36 = getelementptr inbounds nuw i8, ptr %35, i64 8
  store ptr %34, ptr %36, align 8, !tbaa !13
  %37 = getelementptr [24 x i8], ptr %9, i64 %22
  %38 = getelementptr i8, ptr %37, i64 40
  store ptr %37, ptr %38, align 8, !tbaa !9
  %39 = add nsw i32 %23, 2
  store i32 %32, ptr %35, align 8, !tbaa !14
  %40 = add nuw nsw i64 %22, 2
  %41 = add nuw i64 %24, 2
  %42 = icmp eq i64 %41, %19
  br i1 %42, label %43, label %20, !llvm.loop !18

43:                                               ; preds = %20
  %44 = icmp eq i64 %16, 0
  br i1 %44, label %58, label %45

45:                                               ; preds = %43, %12
  %46 = phi i64 [ 0, %12 ], [ %33, %43 ]
  %47 = phi i64 [ 1, %12 ], [ %40, %43 ]
  %48 = phi i32 [ %10, %12 ], [ %39, %43 ]
  %49 = trunc i32 %14 to i1
  tail call void @llvm.assume(i1 %49)
  %50 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %46
  %51 = getelementptr inbounds nuw i8, ptr %50, i64 24
  %52 = getelementptr inbounds nuw [24 x i8], ptr %9, i64 %46
  %53 = getelementptr inbounds nuw i8, ptr %52, i64 8
  store ptr %51, ptr %53, align 8, !tbaa !13
  %54 = getelementptr [24 x i8], ptr %9, i64 %47
  %55 = getelementptr i8, ptr %54, i64 -24
  %56 = getelementptr inbounds nuw i8, ptr %54, i64 16
  store ptr %55, ptr %56, align 8, !tbaa !9
  %57 = add nsw i32 %48, 1
  store i32 %48, ptr %52, align 8, !tbaa !14
  br label %58

58:                                               ; preds = %45, %43, %2
  %59 = phi i32 [ %10, %2 ], [ %39, %43 ], [ %57, %45 ]
  %60 = add nsw i32 %5, 1
  %61 = sext i32 %60 to i64
  %62 = getelementptr inbounds [24 x i8], ptr %9, i64 %61
  %63 = getelementptr inbounds nuw i8, ptr %9, i64 16
  store ptr %62, ptr %63, align 8, !tbaa !9
  %64 = getelementptr inbounds nuw i8, ptr %62, i64 8
  store ptr %9, ptr %64, align 8, !tbaa !13
  %65 = sext i32 %5 to i64
  %66 = getelementptr inbounds [24 x i8], ptr %9, i64 %65
  %67 = getelementptr inbounds nuw i8, ptr %62, i64 16
  store ptr %66, ptr %67, align 8, !tbaa !9
  store i32 %59, ptr %62, align 8, !tbaa !14
  store i32 %60, ptr %9, align 8, !tbaa !14
  ret ptr %9
}

; Function Attrs: nofree nounwind memory(readwrite, argmem: read, target_mem: none) uwtable
define dso_local noundef ptr @list_copy(ptr nofree noundef readonly captures(none) %0) local_unnamed_addr #8 {
  %2 = load i32, ptr %0, align 8, !tbaa !14
  %3 = add nsw i32 %2, 1
  %4 = sext i32 %3 to i64
  %5 = mul nsw i64 %4, 24
  %6 = tail call noalias ptr @malloc(i64 noundef %5) #16
  %7 = icmp sgt i32 %2, 0
  br i1 %7, label %8, label %51

8:                                                ; preds = %1
  %9 = zext nneg i32 %2 to i64
  %10 = and i64 %9, 1
  %11 = icmp eq i32 %2, 1
  br i1 %11, label %41, label %12

12:                                               ; preds = %8
  %13 = and i64 %9, 2147483646
  br label %14

14:                                               ; preds = %14, %12
  %15 = phi i64 [ 1, %12 ], [ %34, %14 ]
  %16 = phi i64 [ 0, %12 ], [ %33, %14 ]
  %17 = phi ptr [ %0, %12 ], [ %36, %14 ]
  %18 = phi i64 [ 0, %12 ], [ %37, %14 ]
  %19 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %15
  %20 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %16
  %21 = getelementptr inbounds nuw i8, ptr %20, i64 8
  store ptr %19, ptr %21, align 8, !tbaa !13
  %22 = getelementptr inbounds nuw i8, ptr %19, i64 16
  store ptr %20, ptr %22, align 8, !tbaa !9
  %23 = load i32, ptr %17, align 8, !tbaa !14
  store i32 %23, ptr %20, align 8, !tbaa !14
  %24 = getelementptr inbounds nuw i8, ptr %17, i64 8
  %25 = load ptr, ptr %24, align 8, !tbaa !13
  %26 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %15
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 24
  %28 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %16
  %29 = getelementptr inbounds nuw i8, ptr %28, i64 24
  %30 = getelementptr inbounds nuw i8, ptr %28, i64 32
  store ptr %27, ptr %30, align 8, !tbaa !13
  %31 = getelementptr inbounds nuw i8, ptr %26, i64 40
  store ptr %29, ptr %31, align 8, !tbaa !9
  %32 = load i32, ptr %25, align 8, !tbaa !14
  store i32 %32, ptr %29, align 8, !tbaa !14
  %33 = add nuw nsw i64 %16, 2
  %34 = add nuw nsw i64 %15, 2
  %35 = getelementptr inbounds nuw i8, ptr %25, i64 8
  %36 = load ptr, ptr %35, align 8, !tbaa !13
  %37 = add nuw i64 %18, 2
  %38 = icmp eq i64 %37, %13
  br i1 %38, label %39, label %14, !llvm.loop !19

39:                                               ; preds = %14
  %40 = icmp eq i64 %10, 0
  br i1 %40, label %51, label %41

41:                                               ; preds = %39, %8
  %42 = phi i64 [ 1, %8 ], [ %34, %39 ]
  %43 = phi i64 [ 0, %8 ], [ %33, %39 ]
  %44 = phi ptr [ %0, %8 ], [ %36, %39 ]
  %45 = trunc i32 %2 to i1
  tail call void @llvm.assume(i1 %45)
  %46 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %42
  %47 = getelementptr inbounds nuw [24 x i8], ptr %6, i64 %43
  %48 = getelementptr inbounds nuw i8, ptr %47, i64 8
  store ptr %46, ptr %48, align 8, !tbaa !13
  %49 = getelementptr inbounds nuw i8, ptr %46, i64 16
  store ptr %47, ptr %49, align 8, !tbaa !9
  %50 = load i32, ptr %44, align 8, !tbaa !14
  store i32 %50, ptr %47, align 8, !tbaa !14
  br label %51

51:                                               ; preds = %41, %39, %1
  %52 = sext i32 %2 to i64
  %53 = getelementptr inbounds [24 x i8], ptr %6, i64 %52
  %54 = getelementptr inbounds nuw i8, ptr %6, i64 16
  store ptr %53, ptr %54, align 8, !tbaa !9
  %55 = getelementptr inbounds nuw i8, ptr %53, i64 8
  store ptr %6, ptr %55, align 8, !tbaa !13
  %56 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %57 = load ptr, ptr %56, align 8, !tbaa !9
  %58 = load i32, ptr %57, align 8, !tbaa !14
  store i32 %58, ptr %53, align 8, !tbaa !14
  ret ptr %6
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @list_reverse(ptr nofree noundef captures(address) %0) local_unnamed_addr #9 {
  br label %2

2:                                                ; preds = %2, %1
  %3 = phi ptr [ %0, %1 ], [ %5, %2 ]
  %4 = getelementptr inbounds nuw i8, ptr %3, i64 8
  %5 = load ptr, ptr %4, align 8, !tbaa !13
  %6 = getelementptr inbounds nuw i8, ptr %3, i64 16
  %7 = load ptr, ptr %6, align 8, !tbaa !9
  store ptr %7, ptr %4, align 8, !tbaa !13
  store ptr %5, ptr %6, align 8, !tbaa !9
  %8 = icmp eq ptr %5, %0
  br i1 %8, label %9, label %2, !llvm.loop !20

9:                                                ; preds = %2
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @test_lists() local_unnamed_addr #10 {
  %1 = tail call noalias dereferenceable_or_null(2424) ptr @malloc(i64 noundef 2424) #16
  br label %2

2:                                                ; preds = %2, %0
  %3 = phi i64 [ 0, %0 ], [ %14, %2 ]
  %4 = phi i64 [ 1, %0 ], [ %20, %2 ]
  %5 = trunc i64 %3 to i32
  %6 = or disjoint i64 %3, 1
  %7 = getelementptr inbounds nuw [24 x i8], ptr %1, i64 %6
  %8 = getelementptr inbounds nuw [24 x i8], ptr %1, i64 %3
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 8
  store ptr %7, ptr %9, align 8, !tbaa !13
  %10 = getelementptr [24 x i8], ptr %1, i64 %4
  %11 = getelementptr i8, ptr %10, i64 -24
  %12 = getelementptr inbounds nuw i8, ptr %10, i64 16
  store ptr %11, ptr %12, align 8, !tbaa !9
  store i32 %5, ptr %8, align 8, !tbaa !14
  %13 = trunc i64 %6 to i32
  %14 = add nuw nsw i64 %3, 2
  %15 = getelementptr inbounds nuw [24 x i8], ptr %1, i64 %14
  %16 = getelementptr inbounds nuw [24 x i8], ptr %1, i64 %6
  %17 = getelementptr inbounds nuw i8, ptr %16, i64 8
  store ptr %15, ptr %17, align 8, !tbaa !13
  %18 = getelementptr [24 x i8], ptr %1, i64 %4
  %19 = getelementptr i8, ptr %18, i64 40
  store ptr %18, ptr %19, align 8, !tbaa !9
  store i32 %13, ptr %16, align 8, !tbaa !14
  %20 = add nuw nsw i64 %4, 2
  %21 = icmp eq i64 %14, 100
  br i1 %21, label %22, label %2, !llvm.loop !18

22:                                               ; preds = %2
  %23 = getelementptr inbounds nuw i8, ptr %1, i64 2400
  %24 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store ptr %23, ptr %24, align 8, !tbaa !9
  %25 = getelementptr inbounds nuw i8, ptr %1, i64 2408
  store ptr %1, ptr %25, align 8, !tbaa !13
  %26 = getelementptr inbounds nuw i8, ptr %1, i64 2376
  %27 = getelementptr inbounds nuw i8, ptr %1, i64 2416
  store ptr %26, ptr %27, align 8, !tbaa !9
  store i32 100, ptr %23, align 8, !tbaa !14
  store i32 100, ptr %1, align 8, !tbaa !14
  %28 = tail call noalias dereferenceable_or_null(2424) ptr @malloc(i64 noundef 2424) #16
  br label %29

29:                                               ; preds = %29, %22
  %30 = phi i64 [ 1, %22 ], [ %48, %29 ]
  %31 = phi i64 [ 0, %22 ], [ %47, %29 ]
  %32 = phi ptr [ %1, %22 ], [ %50, %29 ]
  %33 = getelementptr inbounds nuw [24 x i8], ptr %28, i64 %30
  %34 = getelementptr inbounds nuw [24 x i8], ptr %28, i64 %31
  %35 = getelementptr inbounds nuw i8, ptr %34, i64 8
  store ptr %33, ptr %35, align 8, !tbaa !13
  %36 = getelementptr inbounds nuw i8, ptr %33, i64 16
  store ptr %34, ptr %36, align 8, !tbaa !9
  %37 = load i32, ptr %32, align 8, !tbaa !14
  store i32 %37, ptr %34, align 8, !tbaa !14
  %38 = getelementptr inbounds nuw i8, ptr %32, i64 8
  %39 = load ptr, ptr %38, align 8, !tbaa !13
  %40 = getelementptr inbounds nuw [24 x i8], ptr %28, i64 %30
  %41 = getelementptr inbounds nuw i8, ptr %40, i64 24
  %42 = getelementptr inbounds nuw [24 x i8], ptr %28, i64 %31
  %43 = getelementptr inbounds nuw i8, ptr %42, i64 24
  %44 = getelementptr inbounds nuw i8, ptr %42, i64 32
  store ptr %41, ptr %44, align 8, !tbaa !13
  %45 = getelementptr inbounds nuw i8, ptr %40, i64 40
  store ptr %43, ptr %45, align 8, !tbaa !9
  %46 = load i32, ptr %39, align 8, !tbaa !14
  store i32 %46, ptr %43, align 8, !tbaa !14
  %47 = add nuw nsw i64 %31, 2
  %48 = add nuw nsw i64 %30, 2
  %49 = getelementptr inbounds nuw i8, ptr %39, i64 8
  %50 = load ptr, ptr %49, align 8, !tbaa !13
  %51 = icmp eq i64 %47, 100
  br i1 %51, label %52, label %29, !llvm.loop !19

52:                                               ; preds = %29
  %53 = getelementptr inbounds nuw i8, ptr %28, i64 2400
  %54 = getelementptr inbounds nuw i8, ptr %28, i64 16
  store ptr %53, ptr %54, align 8, !tbaa !9
  %55 = getelementptr inbounds nuw i8, ptr %28, i64 2408
  store ptr %28, ptr %55, align 8, !tbaa !13
  store i32 100, ptr %53, align 8, !tbaa !14
  %56 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #16
  %57 = getelementptr inbounds nuw i8, ptr %56, i64 8
  store ptr %56, ptr %57, align 8, !tbaa !13
  %58 = getelementptr inbounds nuw i8, ptr %56, i64 16
  store ptr %56, ptr %58, align 8, !tbaa !9
  store i32 0, ptr %56, align 8, !tbaa !14
  %59 = getelementptr inbounds nuw i8, ptr %28, i64 8
  %60 = load ptr, ptr %59, align 8, !tbaa !13
  %61 = icmp eq ptr %60, %28
  br i1 %61, label %77, label %62

62:                                               ; preds = %52, %69
  %63 = phi ptr [ %73, %69 ], [ %60, %52 ]
  %64 = phi ptr [ %71, %69 ], [ %1, %52 ]
  %65 = phi ptr [ %63, %69 ], [ %28, %52 ]
  %66 = load i32, ptr %65, align 8, !tbaa !14
  %67 = load i32, ptr %64, align 8, !tbaa !14
  %68 = icmp eq i32 %66, %67
  br i1 %68, label %69, label %106

69:                                               ; preds = %62
  %70 = getelementptr inbounds nuw i8, ptr %64, i64 8
  %71 = load ptr, ptr %70, align 8, !tbaa !13
  %72 = getelementptr inbounds nuw i8, ptr %63, i64 8
  %73 = load ptr, ptr %72, align 8, !tbaa !13
  %74 = icmp eq ptr %73, %28
  br i1 %74, label %75, label %62, !llvm.loop !15

75:                                               ; preds = %69
  %76 = load i32, ptr %71, align 8, !tbaa !14
  br label %77

77:                                               ; preds = %75, %52
  %78 = phi i32 [ 100, %52 ], [ %76, %75 ]
  %79 = phi ptr [ %28, %52 ], [ %63, %75 ]
  %80 = phi ptr [ %1, %52 ], [ %71, %75 ]
  %81 = load i32, ptr %79, align 8, !tbaa !14
  %82 = icmp eq i32 %81, %78
  br i1 %82, label %83, label %106

83:                                               ; preds = %77
  %84 = getelementptr inbounds nuw i8, ptr %80, i64 8
  %85 = load ptr, ptr %84, align 8, !tbaa !13
  %86 = icmp eq ptr %85, %1
  br i1 %86, label %87, label %106

87:                                               ; preds = %83
  %88 = load i32, ptr %28, align 8, !tbaa !14
  %89 = icmp eq i32 %88, 0
  br i1 %89, label %142, label %90

90:                                               ; preds = %87
  %91 = add i32 %88, -1
  %92 = and i32 %88, 1
  %93 = icmp eq i32 %92, 0
  br i1 %93, label %103, label %94

94:                                               ; preds = %90
  %95 = load ptr, ptr %59, align 8, !tbaa !13
  %96 = getelementptr inbounds nuw i8, ptr %95, i64 8
  %97 = load ptr, ptr %96, align 8, !tbaa !13
  store ptr %97, ptr %59, align 8, !tbaa !13
  %98 = getelementptr inbounds nuw i8, ptr %97, i64 16
  store ptr %28, ptr %98, align 8, !tbaa !9
  %99 = add nsw i32 %88, -1
  %100 = load ptr, ptr %58, align 8, !tbaa !9
  %101 = getelementptr inbounds nuw i8, ptr %100, i64 8
  store ptr %95, ptr %101, align 8, !tbaa !13
  store ptr %56, ptr %96, align 8, !tbaa !13
  store ptr %95, ptr %58, align 8, !tbaa !9
  %102 = getelementptr inbounds nuw i8, ptr %95, i64 16
  store ptr %100, ptr %102, align 8, !tbaa !9
  br label %103

103:                                              ; preds = %94, %90
  %104 = phi i32 [ %88, %90 ], [ %99, %94 ]
  %105 = icmp eq i32 %91, 0
  br i1 %105, label %126, label %108

106:                                              ; preds = %62, %77, %83
  %107 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.13)
  tail call void @exit(i32 noundef 1) #17
  unreachable

108:                                              ; preds = %103, %108
  %109 = phi i32 [ %121, %108 ], [ %104, %103 ]
  %110 = load ptr, ptr %59, align 8, !tbaa !13
  %111 = getelementptr inbounds nuw i8, ptr %110, i64 8
  %112 = load ptr, ptr %111, align 8, !tbaa !13
  store ptr %112, ptr %59, align 8, !tbaa !13
  %113 = getelementptr inbounds nuw i8, ptr %112, i64 16
  store ptr %28, ptr %113, align 8, !tbaa !9
  %114 = load ptr, ptr %58, align 8, !tbaa !9
  %115 = getelementptr inbounds nuw i8, ptr %114, i64 8
  store ptr %110, ptr %115, align 8, !tbaa !13
  store ptr %56, ptr %111, align 8, !tbaa !13
  store ptr %110, ptr %58, align 8, !tbaa !9
  %116 = getelementptr inbounds nuw i8, ptr %110, i64 16
  store ptr %114, ptr %116, align 8, !tbaa !9
  %117 = load ptr, ptr %59, align 8, !tbaa !13
  %118 = getelementptr inbounds nuw i8, ptr %117, i64 8
  %119 = load ptr, ptr %118, align 8, !tbaa !13
  store ptr %119, ptr %59, align 8, !tbaa !13
  %120 = getelementptr inbounds nuw i8, ptr %119, i64 16
  store ptr %28, ptr %120, align 8, !tbaa !9
  %121 = add nsw i32 %109, -2
  %122 = load ptr, ptr %58, align 8, !tbaa !9
  %123 = getelementptr inbounds nuw i8, ptr %122, i64 8
  store ptr %117, ptr %123, align 8, !tbaa !13
  store ptr %56, ptr %118, align 8, !tbaa !13
  store ptr %117, ptr %58, align 8, !tbaa !9
  %124 = getelementptr inbounds nuw i8, ptr %117, i64 16
  store ptr %122, ptr %124, align 8, !tbaa !9
  %125 = icmp eq i32 %121, 0
  br i1 %125, label %126, label %108, !llvm.loop !21

126:                                              ; preds = %108, %103
  %127 = and i32 %88, 1
  %128 = icmp eq i32 %127, 0
  br i1 %128, label %138, label %129

129:                                              ; preds = %126
  %130 = load ptr, ptr %58, align 8, !tbaa !9
  %131 = getelementptr inbounds nuw i8, ptr %130, i64 16
  %132 = load ptr, ptr %131, align 8, !tbaa !9
  %133 = getelementptr inbounds nuw i8, ptr %132, i64 8
  store ptr %56, ptr %133, align 8, !tbaa !13
  store ptr %132, ptr %58, align 8, !tbaa !9
  %134 = add nsw i32 %88, -1
  %135 = load ptr, ptr %54, align 8, !tbaa !9
  %136 = getelementptr inbounds nuw i8, ptr %135, i64 8
  store ptr %130, ptr %136, align 8, !tbaa !13
  %137 = getelementptr inbounds nuw i8, ptr %130, i64 8
  store ptr %28, ptr %137, align 8, !tbaa !13
  store ptr %130, ptr %54, align 8, !tbaa !9
  store ptr %135, ptr %131, align 8, !tbaa !9
  br label %138

138:                                              ; preds = %129, %126
  %139 = phi i32 [ %88, %126 ], [ %134, %129 ]
  %140 = icmp eq i32 %91, 0
  br i1 %140, label %141, label %143

141:                                              ; preds = %143, %138
  store i32 0, ptr %56, align 8, !tbaa !14
  store i32 %88, ptr %28, align 8, !tbaa !14
  br label %142

142:                                              ; preds = %87, %141
  br label %161

143:                                              ; preds = %138, %143
  %144 = phi i32 [ %156, %143 ], [ %139, %138 ]
  %145 = load ptr, ptr %58, align 8, !tbaa !9
  %146 = getelementptr inbounds nuw i8, ptr %145, i64 16
  %147 = load ptr, ptr %146, align 8, !tbaa !9
  %148 = getelementptr inbounds nuw i8, ptr %147, i64 8
  store ptr %56, ptr %148, align 8, !tbaa !13
  store ptr %147, ptr %58, align 8, !tbaa !9
  %149 = load ptr, ptr %54, align 8, !tbaa !9
  %150 = getelementptr inbounds nuw i8, ptr %149, i64 8
  store ptr %145, ptr %150, align 8, !tbaa !13
  %151 = getelementptr inbounds nuw i8, ptr %145, i64 8
  store ptr %28, ptr %151, align 8, !tbaa !13
  store ptr %145, ptr %54, align 8, !tbaa !9
  store ptr %149, ptr %146, align 8, !tbaa !9
  %152 = load ptr, ptr %58, align 8, !tbaa !9
  %153 = getelementptr inbounds nuw i8, ptr %152, i64 16
  %154 = load ptr, ptr %153, align 8, !tbaa !9
  %155 = getelementptr inbounds nuw i8, ptr %154, i64 8
  store ptr %56, ptr %155, align 8, !tbaa !13
  store ptr %154, ptr %58, align 8, !tbaa !9
  %156 = add nsw i32 %144, -2
  %157 = load ptr, ptr %54, align 8, !tbaa !9
  %158 = getelementptr inbounds nuw i8, ptr %157, i64 8
  store ptr %152, ptr %158, align 8, !tbaa !13
  %159 = getelementptr inbounds nuw i8, ptr %152, i64 8
  store ptr %28, ptr %159, align 8, !tbaa !13
  store ptr %152, ptr %54, align 8, !tbaa !9
  store ptr %157, ptr %153, align 8, !tbaa !9
  %160 = icmp eq i32 %156, 0
  br i1 %160, label %141, label %143, !llvm.loop !22

161:                                              ; preds = %142, %161
  %162 = phi ptr [ %164, %161 ], [ %1, %142 ]
  %163 = getelementptr inbounds nuw i8, ptr %162, i64 8
  %164 = load ptr, ptr %163, align 8, !tbaa !13
  %165 = getelementptr inbounds nuw i8, ptr %162, i64 16
  %166 = load ptr, ptr %165, align 8, !tbaa !9
  store ptr %166, ptr %163, align 8, !tbaa !13
  store ptr %164, ptr %165, align 8, !tbaa !9
  %167 = icmp eq ptr %164, %1
  br i1 %167, label %168, label %161, !llvm.loop !20

168:                                              ; preds = %161
  %169 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %170 = load ptr, ptr %169, align 8, !tbaa !13
  %171 = load i32, ptr %170, align 8, !tbaa !14
  %172 = icmp eq i32 %171, 100
  br i1 %172, label %175, label %173

173:                                              ; preds = %168
  %174 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.7, i32 noundef 100, i32 noundef %171)
  tail call void @exit(i32 noundef 1) #17
  unreachable

175:                                              ; preds = %168
  %176 = load ptr, ptr %24, align 8, !tbaa !9
  %177 = load i32, ptr %176, align 8, !tbaa !14
  %178 = icmp eq i32 %177, 1
  br i1 %178, label %181, label %179

179:                                              ; preds = %175
  %180 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.8, i32 noundef 100, i32 noundef %177)
  tail call void @exit(i32 noundef 1) #17
  unreachable

181:                                              ; preds = %175
  %182 = load ptr, ptr %59, align 8, !tbaa !13
  %183 = load i32, ptr %182, align 8, !tbaa !14
  %184 = icmp eq i32 %183, 100
  br i1 %184, label %187, label %185

185:                                              ; preds = %181
  %186 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.9, i32 noundef 100, i32 noundef %183)
  tail call void @exit(i32 noundef 1) #17
  unreachable

187:                                              ; preds = %181
  %188 = load ptr, ptr %54, align 8, !tbaa !9
  %189 = load i32, ptr %188, align 8, !tbaa !14
  %190 = icmp eq i32 %189, 1
  br i1 %190, label %193, label %191

191:                                              ; preds = %187
  %192 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.8, i32 noundef 100, i32 noundef %189)
  tail call void @exit(i32 noundef 1) #17
  unreachable

193:                                              ; preds = %187
  %194 = icmp eq ptr %170, %1
  br i1 %194, label %211, label %195

195:                                              ; preds = %193, %202
  %196 = phi ptr [ %206, %202 ], [ %170, %193 ]
  %197 = phi ptr [ %204, %202 ], [ %28, %193 ]
  %198 = phi ptr [ %196, %202 ], [ %1, %193 ]
  %199 = load i32, ptr %198, align 8, !tbaa !14
  %200 = load i32, ptr %197, align 8, !tbaa !14
  %201 = icmp eq i32 %199, %200
  br i1 %201, label %202, label %220

202:                                              ; preds = %195
  %203 = getelementptr inbounds nuw i8, ptr %197, i64 8
  %204 = load ptr, ptr %203, align 8, !tbaa !13
  %205 = getelementptr inbounds nuw i8, ptr %196, i64 8
  %206 = load ptr, ptr %205, align 8, !tbaa !13
  %207 = icmp eq ptr %206, %1
  br i1 %207, label %208, label %195, !llvm.loop !15

208:                                              ; preds = %202
  %209 = load i32, ptr %196, align 8, !tbaa !14
  %210 = load i32, ptr %204, align 8, !tbaa !14
  br label %211

211:                                              ; preds = %208, %193
  %212 = phi i32 [ %88, %193 ], [ %210, %208 ]
  %213 = phi i32 [ 100, %193 ], [ %209, %208 ]
  %214 = phi ptr [ %28, %193 ], [ %204, %208 ]
  %215 = icmp eq i32 %213, %212
  br i1 %215, label %216, label %220

216:                                              ; preds = %211
  %217 = getelementptr inbounds nuw i8, ptr %214, i64 8
  %218 = load ptr, ptr %217, align 8, !tbaa !13
  %219 = icmp eq ptr %218, %28
  br i1 %219, label %222, label %220

220:                                              ; preds = %195, %211, %216
  %221 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.16)
  tail call void @exit(i32 noundef 1) #17
  unreachable

222:                                              ; preds = %216
  tail call void @free(ptr noundef %1) #18
  tail call void @free(ptr noundef %28) #18
  tail call void @free(ptr noundef %56) #18
  ret i32 100
}

; Function Attrs: nofree noreturn nounwind
declare void @exit(i32 noundef) local_unnamed_addr #11

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #12

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #10 {
  %3 = icmp eq i32 %0, 2
  br i1 %3, label %4, label %10

4:                                                ; preds = %2
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %6 = load ptr, ptr %5, align 8, !tbaa !23
  %7 = tail call i64 @strtol(ptr noundef nonnull captures(none) %6, ptr noundef null, i32 noundef 10) #18, !inline_history !25
  %8 = trunc i64 %7 to i32
  %9 = icmp eq i32 %8, 0
  br i1 %9, label %17, label %10

10:                                               ; preds = %2, %4
  %11 = phi i32 [ 3000000, %2 ], [ %8, %4 ]
  br label %12

12:                                               ; preds = %10, %12
  %13 = phi i32 [ %14, %12 ], [ %11, %10 ]
  %14 = add nsw i32 %13, -1
  %15 = tail call i32 @test_lists()
  %16 = icmp eq i32 %14, 0
  br i1 %16, label %17, label %12, !llvm.loop !26

17:                                               ; preds = %12, %4
  %18 = phi i32 [ 0, %4 ], [ %15, %12 ]
  %19 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.12, i32 noundef %18)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #13

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smax.i32(i32, i32) #14

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smin.i32(i32, i32) #14

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #15

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(read, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nofree nounwind willreturn memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree nounwind memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nofree nounwind memory(readwrite, argmem: read, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #11 = { nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #12 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #13 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #14 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #15 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #16 = { nounwind allocsize(0) }
attributes #17 = { cold noreturn nounwind }
attributes #18 = { nounwind }

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
!9 = !{!10, !11, i64 16}
!10 = !{!"DLL", !6, i64 0, !11, i64 8, !11, i64 16}
!11 = !{!"p1 _ZTS3DLL", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!10, !11, i64 8}
!14 = !{!10, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = distinct !{!18, !16}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16}
!21 = distinct !{!21, !16}
!22 = distinct !{!22, !16}
!23 = !{!24, !24, i64 0}
!24 = !{!"p1 omnipotent char", !12, i64 0}
!25 = distinct !{null}
!26 = distinct !{!26, !16}
