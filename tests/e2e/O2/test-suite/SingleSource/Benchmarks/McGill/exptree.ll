; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/exptree.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@stderr = external local_unnamed_addr global ptr, align 8
@.str = private unnamed_addr constant [29 x i8] c"Out of memory for work list\0A\00", align 1
@.str.1 = private unnamed_addr constant [36 x i8] c"Out of memory for combination list\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"%d\00", align 1
@.str.8 = private unnamed_addr constant [6 x i8] c" d%d \00", align 1
@.str.9 = private unnamed_addr constant [6 x i8] c"%d=%d\00", align 1
@.str.10 = private unnamed_addr constant [3 x i8] c"; \00", align 1
@.str.13 = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@stopSearch = internal unnamed_addr global i1 false, align 4
@nbNodes = internal unnamed_addr global i32 0, align 4
@dmax = internal unnamed_addr global i32 0, align 4
@workList = internal unnamed_addr global ptr null, align 8
@listLength = internal unnamed_addr global i32 0, align 4
@goal = internal unnamed_addr global i32 0, align 4
@best = internal unnamed_addr global i32 0, align 4
@bestDepth = internal unnamed_addr global i32 0, align 4
@solution = internal unnamed_addr global ptr null, align 8
@combList = internal unnamed_addr global ptr null, align 8
@stdin = external local_unnamed_addr global ptr, align 8
@str.14 = private unnamed_addr constant [2 x i8] c".\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local nonnull ptr @newWorkList(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sext i32 %0 to i64
  %3 = tail call noalias ptr @calloc(i64 noundef %2, i64 noundef 4) #15
  %4 = icmp eq ptr %3, null
  br i1 %4, label %6, label %5

5:                                                ; preds = %1
  ret ptr %3

6:                                                ; preds = %1
  %7 = load ptr, ptr @stderr, align 8, !tbaa !9
  %8 = tail call i64 @fwrite(ptr nonnull @.str, i64 28, i64 1, ptr %7) #16
  tail call void @exit(i32 noundef 1) #17
  unreachable
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @calloc(i64 noundef, i64 noundef) local_unnamed_addr #2

; Function Attrs: nofree noreturn nounwind
declare void @exit(i32 noundef) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local nonnull ptr @newCombList(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sext i32 %0 to i64
  %3 = tail call noalias ptr @calloc(i64 noundef %2, i64 noundef 12) #15
  %4 = icmp eq ptr %3, null
  br i1 %4, label %6, label %5

5:                                                ; preds = %1
  ret ptr %3

6:                                                ; preds = %1
  %7 = load ptr, ptr @stderr, align 8, !tbaa !9
  %8 = tail call i64 @fwrite(ptr nonnull @.str.1, i64 35, i64 1, ptr %7) #16
  tail call void @exit(i32 noundef 1) #17
  unreachable
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @initWorkList(ptr nofree noundef writeonly captures(none) %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #4 {
  %4 = icmp sgt i32 %2, 0
  br i1 %4, label %5, label %63

5:                                                ; preds = %3
  %6 = ptrtoaddr ptr %0 to i64
  %7 = ptrtoaddr ptr %1 to i64
  %8 = zext nneg i32 %2 to i64
  %9 = icmp ult i32 %2, 8
  %10 = sub i64 %7, %6
  %11 = icmp ugt i64 %10, -32
  %12 = or i1 %9, %11
  br i1 %12, label %27, label %13

13:                                               ; preds = %5
  %14 = and i64 %8, 2147483640
  br label %15

15:                                               ; preds = %15, %13
  %16 = phi i64 [ 0, %13 ], [ %23, %15 ]
  %17 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %16
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 16
  %19 = load <4 x i32>, ptr %17, align 4, !tbaa !12
  %20 = load <4 x i32>, ptr %18, align 4, !tbaa !12
  %21 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %16
  %22 = getelementptr inbounds nuw i8, ptr %21, i64 16
  store <4 x i32> %19, ptr %21, align 4, !tbaa !12
  store <4 x i32> %20, ptr %22, align 4, !tbaa !12
  %23 = add nuw i64 %16, 8
  %24 = icmp eq i64 %23, %14
  br i1 %24, label %25, label %15, !llvm.loop !13

25:                                               ; preds = %15
  %26 = icmp eq i64 %14, %8
  br i1 %26, label %63, label %27

27:                                               ; preds = %5, %25
  %28 = phi i64 [ 0, %5 ], [ %14, %25 ]
  %29 = and i64 %8, 3
  %30 = icmp eq i64 %29, 0
  br i1 %30, label %40, label %31

31:                                               ; preds = %27, %31
  %32 = phi i64 [ %37, %31 ], [ %28, %27 ]
  %33 = phi i64 [ %38, %31 ], [ 0, %27 ]
  %34 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %32
  %35 = load i32, ptr %34, align 4, !tbaa !12
  %36 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %32
  store i32 %35, ptr %36, align 4, !tbaa !12
  %37 = add nuw nsw i64 %32, 1
  %38 = add i64 %33, 1
  %39 = icmp eq i64 %38, %29
  br i1 %39, label %40, label %31, !llvm.loop !17

40:                                               ; preds = %31, %27
  %41 = phi i64 [ %28, %27 ], [ %37, %31 ]
  %42 = sub nsw i64 %28, %8
  %43 = icmp ugt i64 %42, -4
  br i1 %43, label %63, label %44

44:                                               ; preds = %40, %44
  %45 = phi i64 [ %61, %44 ], [ %41, %40 ]
  %46 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %45
  %47 = load i32, ptr %46, align 4, !tbaa !12
  %48 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %45
  store i32 %47, ptr %48, align 4, !tbaa !12
  %49 = add nuw nsw i64 %45, 1
  %50 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %49
  %51 = load i32, ptr %50, align 4, !tbaa !12
  %52 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %49
  store i32 %51, ptr %52, align 4, !tbaa !12
  %53 = add nuw nsw i64 %45, 2
  %54 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %53
  %55 = load i32, ptr %54, align 4, !tbaa !12
  %56 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %53
  store i32 %55, ptr %56, align 4, !tbaa !12
  %57 = add nuw nsw i64 %45, 3
  %58 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %57
  %59 = load i32, ptr %58, align 4, !tbaa !12
  %60 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %57
  store i32 %59, ptr %60, align 4, !tbaa !12
  %61 = add nuw nsw i64 %45, 4
  %62 = icmp eq i64 %61, %8
  br i1 %62, label %63, label %44, !llvm.loop !19

63:                                               ; preds = %40, %44, %25, %3
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: write) uwtable
define dso_local void @initCombList(ptr nofree noundef writeonly captures(none) %0, i32 noundef %1) local_unnamed_addr #5 {
  %3 = icmp sgt i32 %1, 0
  br i1 %3, label %4, label %45

4:                                                ; preds = %2
  %5 = zext nneg i32 %1 to i64
  %6 = and i64 %5, 7
  %7 = icmp ult i32 %1, 8
  br i1 %7, label %34, label %8

8:                                                ; preds = %4
  %9 = and i64 %5, 2147483640
  br label %10

10:                                               ; preds = %10, %8
  %11 = phi i64 [ 0, %8 ], [ %29, %10 ]
  %12 = phi i64 [ 0, %8 ], [ %30, %10 ]
  %13 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %14 = getelementptr inbounds nuw i8, ptr %13, i64 8
  store i32 0, ptr %14, align 4, !tbaa !20
  %15 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %16 = getelementptr inbounds nuw i8, ptr %15, i64 20
  store i32 0, ptr %16, align 4, !tbaa !20
  %17 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 32
  store i32 0, ptr %18, align 4, !tbaa !20
  %19 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %20 = getelementptr inbounds nuw i8, ptr %19, i64 44
  store i32 0, ptr %20, align 4, !tbaa !20
  %21 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %22 = getelementptr inbounds nuw i8, ptr %21, i64 56
  store i32 0, ptr %22, align 4, !tbaa !20
  %23 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %24 = getelementptr inbounds nuw i8, ptr %23, i64 68
  store i32 0, ptr %24, align 4, !tbaa !20
  %25 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %26 = getelementptr inbounds nuw i8, ptr %25, i64 80
  store i32 0, ptr %26, align 4, !tbaa !20
  %27 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %11
  %28 = getelementptr inbounds nuw i8, ptr %27, i64 92
  store i32 0, ptr %28, align 4, !tbaa !20
  %29 = add nuw nsw i64 %11, 8
  %30 = add i64 %12, 8
  %31 = icmp eq i64 %30, %9
  br i1 %31, label %32, label %10, !llvm.loop !22

32:                                               ; preds = %10
  %33 = icmp eq i64 %6, 0
  br i1 %33, label %45, label %34

34:                                               ; preds = %32, %4
  %35 = phi i64 [ 0, %4 ], [ %29, %32 ]
  %36 = icmp ne i64 %6, 0
  tail call void @llvm.assume(i1 %36)
  br label %37

37:                                               ; preds = %37, %34
  %38 = phi i64 [ %35, %34 ], [ %42, %37 ]
  %39 = phi i64 [ 0, %34 ], [ %43, %37 ]
  %40 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %38
  %41 = getelementptr inbounds nuw i8, ptr %40, i64 8
  store i32 0, ptr %41, align 4, !tbaa !20
  %42 = add nuw nsw i64 %38, 1
  %43 = add i64 %39, 1
  %44 = icmp eq i64 %43, %6
  br i1 %44, label %45, label %37, !llvm.loop !23

45:                                               ; preds = %32, %37, %2
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @saveSolution(ptr nofree noundef writeonly captures(none) %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #4 {
  %4 = icmp sgt i32 %2, 0
  br i1 %4, label %5, label %41

5:                                                ; preds = %3
  %6 = zext nneg i32 %2 to i64
  %7 = and i64 %6, 1
  %8 = icmp eq i32 %2, 1
  br i1 %8, label %32, label %9

9:                                                ; preds = %5
  %10 = and i64 %6, 2147483646
  br label %11

11:                                               ; preds = %11, %9
  %12 = phi i64 [ 0, %9 ], [ %27, %11 ]
  %13 = phi i64 [ 0, %9 ], [ %28, %11 ]
  %14 = getelementptr inbounds nuw [12 x i8], ptr %1, i64 %12
  %15 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %12
  %16 = load <2 x i32>, ptr %14, align 4, !tbaa !12
  store <2 x i32> %16, ptr %15, align 4, !tbaa !12
  %17 = getelementptr inbounds nuw i8, ptr %14, i64 8
  %18 = load i32, ptr %17, align 4, !tbaa !20
  %19 = getelementptr inbounds nuw i8, ptr %15, i64 8
  store i32 %18, ptr %19, align 4, !tbaa !20
  %20 = or disjoint i64 %12, 1
  %21 = getelementptr inbounds nuw [12 x i8], ptr %1, i64 %20
  %22 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %20
  %23 = load <2 x i32>, ptr %21, align 4, !tbaa !12
  store <2 x i32> %23, ptr %22, align 4, !tbaa !12
  %24 = getelementptr inbounds nuw i8, ptr %21, i64 8
  %25 = load i32, ptr %24, align 4, !tbaa !20
  %26 = getelementptr inbounds nuw i8, ptr %22, i64 8
  store i32 %25, ptr %26, align 4, !tbaa !20
  %27 = add nuw nsw i64 %12, 2
  %28 = add i64 %13, 2
  %29 = icmp eq i64 %28, %10
  br i1 %29, label %30, label %11, !llvm.loop !24

30:                                               ; preds = %11
  %31 = icmp eq i64 %7, 0
  br i1 %31, label %41, label %32

32:                                               ; preds = %30, %5
  %33 = phi i64 [ 0, %5 ], [ %27, %30 ]
  %34 = trunc i32 %2 to i1
  tail call void @llvm.assume(i1 %34)
  %35 = getelementptr inbounds nuw [12 x i8], ptr %1, i64 %33
  %36 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %33
  %37 = load <2 x i32>, ptr %35, align 4, !tbaa !12
  store <2 x i32> %37, ptr %36, align 4, !tbaa !12
  %38 = getelementptr inbounds nuw i8, ptr %35, i64 8
  %39 = load i32, ptr %38, align 4, !tbaa !20
  %40 = getelementptr inbounds nuw i8, ptr %36, i64 8
  store i32 %39, ptr %40, align 4, !tbaa !20
  br label %41

41:                                               ; preds = %32, %30, %3
  %42 = sext i32 %2 to i64
  %43 = getelementptr inbounds [12 x i8], ptr %0, i64 %42
  %44 = getelementptr inbounds nuw i8, ptr %43, i64 8
  store i32 0, ptr %44, align 4, !tbaa !20
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable
define dso_local i32 @calculate(ptr nofree noundef readonly captures(none) %0) local_unnamed_addr #6 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %3 = load i32, ptr %2, align 4, !tbaa !20
  switch i32 %3, label %24 [
    i32 1, label %4
    i32 2, label %9
    i32 3, label %14
    i32 4, label %19
  ]

4:                                                ; preds = %1
  %5 = load i32, ptr %0, align 4, !tbaa !25
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %7 = load i32, ptr %6, align 4, !tbaa !26
  %8 = add nsw i32 %7, %5
  br label %24

9:                                                ; preds = %1
  %10 = load i32, ptr %0, align 4, !tbaa !25
  %11 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %12 = load i32, ptr %11, align 4, !tbaa !26
  %13 = sub nsw i32 %10, %12
  br label %24

14:                                               ; preds = %1
  %15 = load i32, ptr %0, align 4, !tbaa !25
  %16 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %17 = load i32, ptr %16, align 4, !tbaa !26
  %18 = mul nsw i32 %17, %15
  br label %24

19:                                               ; preds = %1
  %20 = load i32, ptr %0, align 4, !tbaa !25
  %21 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %22 = load i32, ptr %21, align 4, !tbaa !26
  %23 = sdiv i32 %20, %22
  br label %24

24:                                               ; preds = %1, %19, %14, %9, %4
  %25 = phi i32 [ %23, %19 ], [ %8, %4 ], [ %13, %9 ], [ %18, %14 ], [ 0, %1 ]
  ret i32 %25
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @printSolution(ptr nofree noundef readonly captures(none) %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = icmp sgt i32 %1, 0
  br i1 %3, label %4, label %54

4:                                                ; preds = %2
  %5 = add nsw i32 %1, -1
  %6 = zext nneg i32 %5 to i64
  %7 = zext nneg i32 %1 to i64
  br label %8

8:                                                ; preds = %4, %51
  %9 = phi i64 [ 0, %4 ], [ %52, %51 ]
  %10 = getelementptr inbounds nuw [12 x i8], ptr %0, i64 %9
  %11 = load i32, ptr %10, align 4, !tbaa !25
  %12 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %11)
  %13 = getelementptr inbounds nuw i8, ptr %10, i64 8
  %14 = load i32, ptr %13, align 4, !tbaa !20
  switch i32 %14, label %25 [
    i32 0, label %15
    i32 1, label %17
    i32 2, label %19
    i32 3, label %21
    i32 4, label %23
  ]

15:                                               ; preds = %8
  %16 = tail call i32 @putchar(i32 32)
  br label %27

17:                                               ; preds = %8
  %18 = tail call i32 @putchar(i32 43)
  br label %27

19:                                               ; preds = %8
  %20 = tail call i32 @putchar(i32 45)
  br label %27

21:                                               ; preds = %8
  %22 = tail call i32 @putchar(i32 42)
  br label %27

23:                                               ; preds = %8
  %24 = tail call i32 @putchar(i32 58)
  br label %27

25:                                               ; preds = %8
  %26 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.8, i32 noundef %14)
  br label %27

27:                                               ; preds = %25, %23, %21, %19, %17, %15
  %28 = getelementptr inbounds nuw i8, ptr %10, i64 4
  %29 = load i32, ptr %28, align 4, !tbaa !26
  %30 = load i32, ptr %13, align 4, !tbaa !20
  switch i32 %30, label %43 [
    i32 1, label %31
    i32 2, label %34
    i32 3, label %37
    i32 4, label %40
  ]

31:                                               ; preds = %27
  %32 = load i32, ptr %10, align 4, !tbaa !25
  %33 = add nsw i32 %32, %29
  br label %43

34:                                               ; preds = %27
  %35 = load i32, ptr %10, align 4, !tbaa !25
  %36 = sub nsw i32 %35, %29
  br label %43

37:                                               ; preds = %27
  %38 = load i32, ptr %10, align 4, !tbaa !25
  %39 = mul nsw i32 %38, %29
  br label %43

40:                                               ; preds = %27
  %41 = load i32, ptr %10, align 4, !tbaa !25
  %42 = sdiv i32 %41, %29
  br label %43

43:                                               ; preds = %27, %31, %34, %37, %40
  %44 = phi i32 [ %42, %40 ], [ %33, %31 ], [ %36, %34 ], [ %39, %37 ], [ 0, %27 ]
  %45 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.9, i32 noundef %29, i32 noundef %44)
  %46 = icmp samesign ult i64 %9, %6
  br i1 %46, label %47, label %49

47:                                               ; preds = %43
  %48 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.10)
  br label %51

49:                                               ; preds = %43
  %50 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.14)
  br label %51

51:                                               ; preds = %47, %49
  %52 = add nuw nsw i64 %9, 1
  %53 = icmp eq i64 %52, %7
  br i1 %53, label %54, label %8, !llvm.loop !27

54:                                               ; preds = %51, %2
  %55 = tail call i32 @putchar(i32 10)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #7

; Function Attrs: nofree nounwind uwtable
define dso_local void @printList(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = icmp sgt i32 %1, 0
  br i1 %4, label %5, label %20

5:                                                ; preds = %3
  %6 = zext nneg i32 %1 to i64
  br label %7

7:                                                ; preds = %5, %17
  %8 = phi i64 [ 0, %5 ], [ %18, %17 ]
  %9 = trunc nuw nsw i64 %8 to i32
  %10 = shl nuw i32 1, %9
  %11 = and i32 %10, %2
  %12 = icmp eq i32 %11, 0
  br i1 %12, label %13, label %17

13:                                               ; preds = %7
  %14 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %8
  %15 = load i32, ptr %14, align 4, !tbaa !12
  %16 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.13, i32 noundef %15)
  br label %17

17:                                               ; preds = %7, %13
  %18 = add nuw nsw i64 %8, 1
  %19 = icmp eq i64 %18, %6
  br i1 %19, label %20, label %7, !llvm.loop !28

20:                                               ; preds = %17, %3
  %21 = tail call i32 @putchar(i32 10)
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @recSearch(i32 noundef %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = load i1, ptr @stopSearch, align 4
  br i1 %3, label %159, label %4

4:                                                ; preds = %2
  %5 = load i32, ptr @nbNodes, align 4, !tbaa !12
  %6 = add nsw i32 %5, 1
  store i32 %6, ptr @nbNodes, align 4, !tbaa !12
  %7 = load i32, ptr @dmax, align 4, !tbaa !12
  %8 = icmp eq i32 %0, %7
  br i1 %8, label %13, label %9

9:                                                ; preds = %4
  %10 = sext i32 %0 to i64
  %11 = add nsw i32 %0, 1
  %12 = load i32, ptr @listLength, align 4, !tbaa !12
  br label %74

13:                                               ; preds = %4
  %14 = load ptr, ptr @workList, align 8, !tbaa !29
  %15 = load i32, ptr @listLength, align 4, !tbaa !12
  %16 = add nsw i32 %15, %0
  %17 = sext i32 %16 to i64
  %18 = getelementptr [4 x i8], ptr %14, i64 %17
  %19 = getelementptr i8, ptr %18, i64 -4
  %20 = load i32, ptr %19, align 4, !tbaa !12
  %21 = load i32, ptr @goal, align 4, !tbaa !12
  %22 = sub nsw i32 %20, %21
  %23 = tail call i32 @llvm.abs.i32(i32 %22, i1 true)
  %24 = load i32, ptr @best, align 4, !tbaa !12
  %25 = sub nsw i32 %24, %21
  %26 = tail call i32 @llvm.abs.i32(i32 %25, i1 true)
  %27 = icmp samesign ult i32 %23, %26
  br i1 %27, label %28, label %159

28:                                               ; preds = %13
  store i32 %20, ptr @best, align 4, !tbaa !12
  store i32 %0, ptr @bestDepth, align 4, !tbaa !12
  %29 = load ptr, ptr @solution, align 8, !tbaa !31
  %30 = load ptr, ptr @combList, align 8, !tbaa !31
  %31 = icmp sgt i32 %0, 0
  br i1 %31, label %32, label %68

32:                                               ; preds = %28
  %33 = zext nneg i32 %0 to i64
  %34 = and i64 %33, 1
  %35 = icmp eq i32 %0, 1
  br i1 %35, label %59, label %36

36:                                               ; preds = %32
  %37 = and i64 %33, 2147483646
  br label %38

38:                                               ; preds = %38, %36
  %39 = phi i64 [ 0, %36 ], [ %54, %38 ]
  %40 = phi i64 [ 0, %36 ], [ %55, %38 ]
  %41 = getelementptr inbounds nuw [12 x i8], ptr %30, i64 %39
  %42 = getelementptr inbounds nuw [12 x i8], ptr %29, i64 %39
  %43 = load <2 x i32>, ptr %41, align 4, !tbaa !12
  store <2 x i32> %43, ptr %42, align 4, !tbaa !12
  %44 = getelementptr inbounds nuw i8, ptr %41, i64 8
  %45 = load i32, ptr %44, align 4, !tbaa !20
  %46 = getelementptr inbounds nuw i8, ptr %42, i64 8
  store i32 %45, ptr %46, align 4, !tbaa !20
  %47 = or disjoint i64 %39, 1
  %48 = getelementptr inbounds nuw [12 x i8], ptr %30, i64 %47
  %49 = getelementptr inbounds nuw [12 x i8], ptr %29, i64 %47
  %50 = load <2 x i32>, ptr %48, align 4, !tbaa !12
  store <2 x i32> %50, ptr %49, align 4, !tbaa !12
  %51 = getelementptr inbounds nuw i8, ptr %48, i64 8
  %52 = load i32, ptr %51, align 4, !tbaa !20
  %53 = getelementptr inbounds nuw i8, ptr %49, i64 8
  store i32 %52, ptr %53, align 4, !tbaa !20
  %54 = add nuw nsw i64 %39, 2
  %55 = add i64 %40, 2
  %56 = icmp eq i64 %55, %37
  br i1 %56, label %57, label %38, !llvm.loop !24

57:                                               ; preds = %38
  %58 = icmp eq i64 %34, 0
  br i1 %58, label %68, label %59

59:                                               ; preds = %57, %32
  %60 = phi i64 [ 0, %32 ], [ %54, %57 ]
  %61 = trunc i32 %0 to i1
  tail call void @llvm.assume(i1 %61)
  %62 = getelementptr inbounds nuw [12 x i8], ptr %30, i64 %60
  %63 = getelementptr inbounds nuw [12 x i8], ptr %29, i64 %60
  %64 = load <2 x i32>, ptr %62, align 4, !tbaa !12
  store <2 x i32> %64, ptr %63, align 4, !tbaa !12
  %65 = getelementptr inbounds nuw i8, ptr %62, i64 8
  %66 = load i32, ptr %65, align 4, !tbaa !20
  %67 = getelementptr inbounds nuw i8, ptr %63, i64 8
  store i32 %66, ptr %67, align 4, !tbaa !20
  br label %68

68:                                               ; preds = %59, %57, %28
  %69 = sext i32 %0 to i64
  %70 = getelementptr inbounds [12 x i8], ptr %29, i64 %69
  %71 = getelementptr inbounds nuw i8, ptr %70, i64 8
  store i32 0, ptr %71, align 4, !tbaa !20
  %72 = icmp eq i32 %20, %21
  br i1 %72, label %73, label %159

73:                                               ; preds = %68
  tail call void @printSolution(ptr noundef %30, i32 noundef %0)
  store i1 true, ptr @stopSearch, align 4
  br label %159

74:                                               ; preds = %9, %154
  %75 = phi i32 [ %12, %9 ], [ %155, %154 ]
  %76 = phi i32 [ %12, %9 ], [ %156, %154 ]
  %77 = phi i32 [ 1, %9 ], [ %157, %154 ]
  %78 = add nsw i32 %76, %0
  %79 = icmp sgt i32 %78, 0
  br i1 %79, label %80, label %154

80:                                               ; preds = %74
  %81 = add nsw i32 %77, -3
  %82 = icmp ult i32 %81, 2
  br label %83

83:                                               ; preds = %80, %148
  %84 = phi i32 [ %75, %80 ], [ %149, %148 ]
  %85 = phi i64 [ 0, %80 ], [ %150, %148 ]
  %86 = trunc nuw nsw i64 %85 to i32
  %87 = shl nuw i32 1, %86
  %88 = and i32 %87, %1
  %89 = icmp eq i32 %88, 0
  %90 = icmp ne i64 %85, 0
  %91 = and i1 %89, %90
  br i1 %91, label %92, label %148

92:                                               ; preds = %83
  %93 = or i32 %87, %1
  br label %94

94:                                               ; preds = %92, %143
  %95 = phi i64 [ 0, %92 ], [ %144, %143 ]
  %96 = trunc nuw nsw i64 %95 to i32
  %97 = shl nuw i32 1, %96
  %98 = and i32 %97, %1
  %99 = icmp eq i32 %98, 0
  br i1 %99, label %100, label %143

100:                                              ; preds = %94
  %101 = load ptr, ptr @workList, align 8, !tbaa !29
  %102 = getelementptr inbounds nuw [4 x i8], ptr %101, i64 %85
  %103 = load i32, ptr %102, align 4, !tbaa !12
  %104 = getelementptr inbounds nuw [4 x i8], ptr %101, i64 %95
  %105 = load i32, ptr %104, align 4, !tbaa !12
  br i1 %82, label %106, label %110

106:                                              ; preds = %100
  %107 = icmp eq i32 %103, 1
  %108 = icmp eq i32 %105, 1
  %109 = select i1 %107, i1 true, i1 %108
  br i1 %109, label %143, label %110

110:                                              ; preds = %106, %100
  %111 = icmp eq i32 %103, 0
  %112 = icmp eq i32 %105, 0
  %113 = select i1 %111, i1 true, i1 %112
  br i1 %113, label %143, label %114

114:                                              ; preds = %110
  switch i32 %77, label %121 [
    i32 4, label %115
    i32 2, label %118
  ]

115:                                              ; preds = %114
  %116 = srem i32 %103, %105
  %117 = icmp eq i32 %116, 0
  br i1 %117, label %118, label %143

118:                                              ; preds = %115, %114
  %119 = tail call i32 @llvm.smax.i32(i32 %103, i32 %105)
  %120 = tail call i32 @llvm.smin.i32(i32 %103, i32 %105)
  br label %121

121:                                              ; preds = %118, %114
  %122 = phi i32 [ %119, %118 ], [ %103, %114 ]
  %123 = phi i32 [ %120, %118 ], [ %105, %114 ]
  %124 = or i32 %93, %97
  %125 = load ptr, ptr @combList, align 8, !tbaa !31
  %126 = getelementptr inbounds [12 x i8], ptr %125, i64 %10
  store i32 %122, ptr %126, align 4, !tbaa !25
  %127 = getelementptr inbounds nuw i8, ptr %126, i64 4
  store i32 %123, ptr %127, align 4, !tbaa !26
  %128 = getelementptr inbounds nuw i8, ptr %126, i64 8
  store i32 %77, ptr %128, align 4, !tbaa !20
  switch i32 %77, label %137 [
    i32 1, label %129
    i32 2, label %131
    i32 3, label %133
    i32 4, label %135
  ]

129:                                              ; preds = %121
  %130 = add nsw i32 %123, %122
  br label %137

131:                                              ; preds = %121
  %132 = sub nsw i32 %122, %123
  br label %137

133:                                              ; preds = %121
  %134 = mul nsw i32 %123, %122
  br label %137

135:                                              ; preds = %121
  %136 = sdiv i32 %122, %123
  br label %137

137:                                              ; preds = %121, %129, %131, %133, %135
  %138 = phi i32 [ %136, %135 ], [ %130, %129 ], [ %132, %131 ], [ %134, %133 ], [ 0, %121 ]
  %139 = load i32, ptr @listLength, align 4, !tbaa !12
  %140 = add nsw i32 %139, %0
  %141 = sext i32 %140 to i64
  %142 = getelementptr inbounds [4 x i8], ptr %101, i64 %141
  store i32 %138, ptr %142, align 4, !tbaa !12
  tail call void @recSearch(i32 noundef %11, i32 noundef %124)
  br label %143

143:                                              ; preds = %115, %110, %106, %94, %137
  %144 = add nuw nsw i64 %95, 1
  %145 = icmp eq i64 %144, %85
  br i1 %145, label %146, label %94, !llvm.loop !32

146:                                              ; preds = %143
  %147 = load i32, ptr @listLength, align 4, !tbaa !12
  br label %148

148:                                              ; preds = %146, %83
  %149 = phi i32 [ %147, %146 ], [ %84, %83 ]
  %150 = add nuw nsw i64 %85, 1
  %151 = add nsw i32 %149, %0
  %152 = sext i32 %151 to i64
  %153 = icmp slt i64 %150, %152
  br i1 %153, label %83, label %154, !llvm.loop !33

154:                                              ; preds = %148, %74
  %155 = phi i32 [ %75, %74 ], [ %149, %148 ]
  %156 = phi i32 [ %76, %74 ], [ %149, %148 ]
  %157 = add nuw nsw i32 %77, 1
  %158 = icmp eq i32 %157, 5
  br i1 %158, label %159, label %74, !llvm.loop !34

159:                                              ; preds = %154, %68, %73, %13, %2
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.abs.i32(i32, i1 immarg) #8

; Function Attrs: nofree nounwind uwtable
define dso_local void @doSearch() local_unnamed_addr #0 {
  %1 = load i32, ptr @listLength, align 4, !tbaa !12
  %2 = icmp sgt i32 %1, 0
  %3 = load i32, ptr @best, align 4
  br i1 %2, label %6, label %4

4:                                                ; preds = %0
  %5 = load i32, ptr @goal, align 4, !tbaa !12
  br label %25

6:                                                ; preds = %0
  %7 = load ptr, ptr @workList, align 8, !tbaa !29
  %8 = load i32, ptr @goal, align 4, !tbaa !12
  %9 = zext nneg i32 %1 to i64
  br label %10

10:                                               ; preds = %6, %21
  %11 = phi i64 [ 0, %6 ], [ %23, %21 ]
  %12 = phi i32 [ %3, %6 ], [ %22, %21 ]
  %13 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %11
  %14 = load i32, ptr %13, align 4, !tbaa !12
  %15 = sub nsw i32 %14, %8
  %16 = tail call i32 @llvm.abs.i32(i32 %15, i1 true)
  %17 = sub nsw i32 %12, %8
  %18 = tail call i32 @llvm.abs.i32(i32 %17, i1 true)
  %19 = icmp samesign ult i32 %16, %18
  br i1 %19, label %20, label %21

20:                                               ; preds = %10
  store i32 %14, ptr @best, align 4, !tbaa !12
  br label %21

21:                                               ; preds = %10, %20
  %22 = phi i32 [ %12, %10 ], [ %14, %20 ]
  %23 = add nuw nsw i64 %11, 1
  %24 = icmp eq i64 %23, %9
  br i1 %24, label %25, label %10, !llvm.loop !35

25:                                               ; preds = %21, %4
  %26 = phi i32 [ %5, %4 ], [ %8, %21 ]
  %27 = phi i32 [ %3, %4 ], [ %22, %21 ]
  %28 = icmp eq i32 %27, %26
  br i1 %28, label %31, label %29

29:                                               ; preds = %25
  store i32 1, ptr @dmax, align 4, !tbaa !12
  %30 = icmp sgt i32 %1, 1
  br i1 %30, label %33, label %40

31:                                               ; preds = %25
  %32 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.14)
  br label %45

33:                                               ; preds = %29, %35
  tail call void @recSearch(i32 noundef 0, i32 noundef 0)
  %34 = load i1, ptr @stopSearch, align 4
  br i1 %34, label %45, label %35

35:                                               ; preds = %33
  %36 = load i32, ptr @dmax, align 4, !tbaa !12
  %37 = add nsw i32 %36, 1
  store i32 %37, ptr @dmax, align 4, !tbaa !12
  %38 = load i32, ptr @listLength, align 4, !tbaa !12
  %39 = icmp slt i32 %37, %38
  br i1 %39, label %33, label %42, !llvm.loop !36

40:                                               ; preds = %29
  %41 = load i1, ptr @stopSearch, align 4
  br i1 %41, label %45, label %42

42:                                               ; preds = %35, %40
  %43 = load ptr, ptr @solution, align 8, !tbaa !31
  %44 = load i32, ptr @bestDepth, align 4, !tbaa !12
  tail call void @printSolution(ptr noundef %43, i32 noundef %44)
  br label %45

45:                                               ; preds = %33, %40, %42, %31
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local range(i32 -2147483648, 2147483647) i32 @getInput() local_unnamed_addr #9 {
  %1 = alloca [16 x i32], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #18
  store <4 x i32> <i32 13, i32 32, i32 14, i32 1412>, ptr %1, align 16, !tbaa !12
  br label %2

2:                                                ; preds = %6, %0
  %3 = phi i64 [ %12, %6 ], [ 0, %0 ]
  %4 = load ptr, ptr @stdin, align 8, !tbaa !9
  %5 = call i32 @getc(ptr noundef %4), !inline_history !37
  switch i32 %5, label %6 [
    i32 -1, label %13
    i32 10, label %13
  ]

6:                                                ; preds = %2
  %7 = load ptr, ptr @stdin, align 8, !tbaa !9
  %8 = call i32 @ungetc(i32 noundef %5, ptr noundef %7)
  %9 = load ptr, ptr @stdin, align 8, !tbaa !9
  %10 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %3
  %11 = call i32 (ptr, ptr, ...) @__isoc99_fscanf(ptr noundef %9, ptr noundef nonnull @.str.2, ptr noundef nonnull %10) #18
  %12 = add nuw nsw i64 %3, 1
  br label %2, !llvm.loop !38

13:                                               ; preds = %2, %2
  %14 = trunc nuw nsw i64 %3 to i32
  %15 = icmp eq i64 %3, 0
  %16 = add nsw i32 %14, -1
  %17 = select i1 %15, i32 3, i32 %16
  store i32 %17, ptr @listLength, align 4, !tbaa !12
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [4 x i8], ptr %1, i64 %18
  %20 = load i32, ptr %19, align 4, !tbaa !12
  store i32 %20, ptr @goal, align 4, !tbaa !12
  %21 = shl nsw i32 %17, 1
  %22 = sext i32 %21 to i64
  %23 = call noalias ptr @calloc(i64 noundef %22, i64 noundef 4) #15
  %24 = icmp eq ptr %23, null
  br i1 %24, label %25, label %28

25:                                               ; preds = %13
  %26 = load ptr, ptr @stderr, align 8, !tbaa !9
  %27 = call i64 @fwrite(ptr nonnull @.str, i64 28, i64 1, ptr %26) #16
  call void @exit(i32 noundef 1) #17
  unreachable

28:                                               ; preds = %13
  store ptr %23, ptr @workList, align 8, !tbaa !29
  %29 = load i32, ptr @listLength, align 4, !tbaa !12
  %30 = sext i32 %29 to i64
  %31 = call noalias ptr @calloc(i64 noundef %30, i64 noundef 12) #15
  %32 = icmp eq ptr %31, null
  br i1 %32, label %33, label %36

33:                                               ; preds = %28
  %34 = load ptr, ptr @stderr, align 8, !tbaa !9
  %35 = call i64 @fwrite(ptr nonnull @.str.1, i64 35, i64 1, ptr %34) #16
  call void @exit(i32 noundef 1) #17
  unreachable

36:                                               ; preds = %28
  store ptr %31, ptr @combList, align 8, !tbaa !31
  %37 = load i32, ptr @listLength, align 4, !tbaa !12
  %38 = sext i32 %37 to i64
  %39 = call noalias ptr @calloc(i64 noundef %38, i64 noundef 12) #15
  %40 = icmp eq ptr %39, null
  br i1 %40, label %41, label %44

41:                                               ; preds = %36
  %42 = load ptr, ptr @stderr, align 8, !tbaa !9
  %43 = call i64 @fwrite(ptr nonnull @.str.1, i64 35, i64 1, ptr %42) #16
  call void @exit(i32 noundef 1) #17
  unreachable

44:                                               ; preds = %36
  store ptr %39, ptr @solution, align 8, !tbaa !31
  %45 = load i32, ptr @listLength, align 4, !tbaa !12
  %46 = icmp sgt i32 %45, 0
  br i1 %46, label %47, label %129

47:                                               ; preds = %44
  %48 = zext nneg i32 %45 to i64
  %49 = shl nuw nsw i64 %48, 2
  call void @llvm.memcpy.p0.p0.i64(ptr nonnull align 4 %23, ptr nonnull align 16 %1, i64 %49, i1 false), !tbaa !12
  %50 = and i64 %48, 7
  %51 = icmp ult i32 %45, 8
  br i1 %51, label %78, label %52

52:                                               ; preds = %47
  %53 = and i64 %48, 2147483640
  br label %54

54:                                               ; preds = %54, %52
  %55 = phi i64 [ 0, %52 ], [ %73, %54 ]
  %56 = phi i64 [ 0, %52 ], [ %74, %54 ]
  %57 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %58 = getelementptr inbounds nuw i8, ptr %57, i64 8
  store i32 0, ptr %58, align 4, !tbaa !20
  %59 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %60 = getelementptr inbounds nuw i8, ptr %59, i64 20
  store i32 0, ptr %60, align 4, !tbaa !20
  %61 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %62 = getelementptr inbounds nuw i8, ptr %61, i64 32
  store i32 0, ptr %62, align 4, !tbaa !20
  %63 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %64 = getelementptr inbounds nuw i8, ptr %63, i64 44
  store i32 0, ptr %64, align 4, !tbaa !20
  %65 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %66 = getelementptr inbounds nuw i8, ptr %65, i64 56
  store i32 0, ptr %66, align 4, !tbaa !20
  %67 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %68 = getelementptr inbounds nuw i8, ptr %67, i64 68
  store i32 0, ptr %68, align 4, !tbaa !20
  %69 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %70 = getelementptr inbounds nuw i8, ptr %69, i64 80
  store i32 0, ptr %70, align 4, !tbaa !20
  %71 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %55
  %72 = getelementptr inbounds nuw i8, ptr %71, i64 92
  store i32 0, ptr %72, align 4, !tbaa !20
  %73 = add nuw nsw i64 %55, 8
  %74 = add i64 %56, 8
  %75 = icmp eq i64 %74, %53
  br i1 %75, label %76, label %54, !llvm.loop !22

76:                                               ; preds = %54
  %77 = icmp eq i64 %50, 0
  br i1 %77, label %89, label %78

78:                                               ; preds = %76, %47
  %79 = phi i64 [ 0, %47 ], [ %73, %76 ]
  %80 = icmp ne i64 %50, 0
  call void @llvm.assume(i1 %80)
  br label %81

81:                                               ; preds = %81, %78
  %82 = phi i64 [ %79, %78 ], [ %86, %81 ]
  %83 = phi i64 [ 0, %78 ], [ %87, %81 ]
  %84 = getelementptr inbounds nuw [12 x i8], ptr %31, i64 %82
  %85 = getelementptr inbounds nuw i8, ptr %84, i64 8
  store i32 0, ptr %85, align 4, !tbaa !20
  %86 = add nuw nsw i64 %82, 1
  %87 = add i64 %83, 1
  %88 = icmp eq i64 %87, %50
  br i1 %88, label %89, label %81, !llvm.loop !39

89:                                               ; preds = %81, %76
  %90 = and i64 %48, 7
  %91 = icmp ult i32 %45, 8
  br i1 %91, label %118, label %92

92:                                               ; preds = %89
  %93 = and i64 %48, 2147483640
  br label %94

94:                                               ; preds = %94, %92
  %95 = phi i64 [ 0, %92 ], [ %113, %94 ]
  %96 = phi i64 [ 0, %92 ], [ %114, %94 ]
  %97 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %98 = getelementptr inbounds nuw i8, ptr %97, i64 8
  store i32 0, ptr %98, align 4, !tbaa !20
  %99 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %100 = getelementptr inbounds nuw i8, ptr %99, i64 20
  store i32 0, ptr %100, align 4, !tbaa !20
  %101 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %102 = getelementptr inbounds nuw i8, ptr %101, i64 32
  store i32 0, ptr %102, align 4, !tbaa !20
  %103 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %104 = getelementptr inbounds nuw i8, ptr %103, i64 44
  store i32 0, ptr %104, align 4, !tbaa !20
  %105 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %106 = getelementptr inbounds nuw i8, ptr %105, i64 56
  store i32 0, ptr %106, align 4, !tbaa !20
  %107 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %108 = getelementptr inbounds nuw i8, ptr %107, i64 68
  store i32 0, ptr %108, align 4, !tbaa !20
  %109 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %110 = getelementptr inbounds nuw i8, ptr %109, i64 80
  store i32 0, ptr %110, align 4, !tbaa !20
  %111 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %95
  %112 = getelementptr inbounds nuw i8, ptr %111, i64 92
  store i32 0, ptr %112, align 4, !tbaa !20
  %113 = add nuw nsw i64 %95, 8
  %114 = add i64 %96, 8
  %115 = icmp eq i64 %114, %93
  br i1 %115, label %116, label %94, !llvm.loop !22

116:                                              ; preds = %94
  %117 = icmp eq i64 %90, 0
  br i1 %117, label %129, label %118

118:                                              ; preds = %116, %89
  %119 = phi i64 [ 0, %89 ], [ %113, %116 ]
  %120 = icmp ne i64 %90, 0
  call void @llvm.assume(i1 %120)
  br label %121

121:                                              ; preds = %121, %118
  %122 = phi i64 [ %126, %121 ], [ %119, %118 ]
  %123 = phi i64 [ %127, %121 ], [ 0, %118 ]
  %124 = getelementptr inbounds nuw [12 x i8], ptr %39, i64 %122
  %125 = getelementptr inbounds nuw i8, ptr %124, i64 8
  store i32 0, ptr %125, align 4, !tbaa !20
  %126 = add nuw nsw i64 %122, 1
  %127 = add i64 %123, 1
  %128 = icmp eq i64 %127, %90
  br i1 %128, label %129, label %121, !llvm.loop !40

129:                                              ; preds = %116, %121, %44
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #18
  ret i32 %45
}

; Function Attrs: nofree nounwind
declare noundef i32 @ungetc(i32 noundef, ptr noundef captures(none)) local_unnamed_addr #7

declare i32 @__isoc99_fscanf(ptr noundef, ptr noundef, ...) local_unnamed_addr #10

; Function Attrs: nofree nounwind uwtable
define dso_local void @search() local_unnamed_addr #0 {
  store i1 false, ptr @stopSearch, align 4
  store i32 0, ptr @nbNodes, align 4, !tbaa !12
  tail call void @doSearch()
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #9 {
  %3 = tail call i32 @getInput()
  %4 = icmp eq i32 %3, 0
  br i1 %4, label %6, label %5

5:                                                ; preds = %2
  store i1 false, ptr @stopSearch, align 4
  store i32 0, ptr @nbNodes, align 4, !tbaa !12
  tail call void @doSearch()
  br label %6

6:                                                ; preds = %5, %2
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @getc(ptr noundef captures(none)) local_unnamed_addr #7

; Function Attrs: nofree nounwind
declare noundef i64 @fwrite(ptr noundef readonly captures(none), i64 noundef, i64 noundef, ptr noundef captures(none)) local_unnamed_addr #11

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #11

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #11

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smax.i32(i32, i32) #12

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smin.i32(i32, i32) #12

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #13

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #14

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree norecurse nosync nounwind memory(argmem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #9 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #11 = { nofree nounwind }
attributes #12 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #13 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #14 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #15 = { nounwind allocsize(0,1) }
attributes #16 = { cold }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 _ZTS8_IO_FILE", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = distinct !{!13, !14, !15, !16}
!14 = !{!"llvm.loop.mustprogress"}
!15 = !{!"llvm.loop.isvectorized", i32 1}
!16 = !{!"llvm.loop.unroll.runtime.disable"}
!17 = distinct !{!17, !18}
!18 = !{!"llvm.loop.unroll.disable"}
!19 = distinct !{!19, !14, !15}
!20 = !{!21, !6, i64 8}
!21 = !{!"", !6, i64 0, !6, i64 4, !6, i64 8}
!22 = distinct !{!22, !14}
!23 = distinct !{!23, !18}
!24 = distinct !{!24, !14}
!25 = !{!21, !6, i64 0}
!26 = !{!21, !6, i64 4}
!27 = distinct !{!27, !14}
!28 = distinct !{!28, !14}
!29 = !{!30, !30, i64 0}
!30 = !{!"p1 int", !11, i64 0}
!31 = !{!11, !11, i64 0}
!32 = distinct !{!32, !14}
!33 = distinct !{!33, !14}
!34 = distinct !{!34, !14}
!35 = distinct !{!35, !14}
!36 = distinct !{!36, !14}
!37 = distinct !{null}
!38 = distinct !{!38, !14}
!39 = distinct !{!39, !18}
!40 = distinct !{!40, !18}
