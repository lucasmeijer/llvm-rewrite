; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Towers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@.str = private unnamed_addr constant [22 x i8] c" Error in Towers: %s\0A\00", align 1
@stack = dso_local local_unnamed_addr global [4 x i32] zeroinitializer, align 16
@freelist = dso_local local_unnamed_addr global i32 0, align 4
@cellspace = dso_local local_unnamed_addr global [19 x %struct.element] zeroinitializer, align 16
@.str.1 = private unnamed_addr constant [16 x i8] c"out of space   \00", align 1
@.str.2 = private unnamed_addr constant [16 x i8] c"disc size error\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"nothing to pop \00", align 1
@movesdone = dso_local local_unnamed_addr global i32 0, align 4
@.str.5 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@value = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@fixed = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@floated = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@permarray = dso_local local_unnamed_addr global [11 x i32] zeroinitializer, align 16
@pctr = dso_local local_unnamed_addr global i32 0, align 4
@tree = dso_local local_unnamed_addr global ptr null, align 8
@ima = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@imb = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@imr = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@rma = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@rmb = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@rmr = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@piececount = dso_local local_unnamed_addr global [4 x i32] zeroinitializer, align 16
@class = dso_local local_unnamed_addr global [13 x i32] zeroinitializer, align 16
@piecemax = dso_local local_unnamed_addr global [13 x i32] zeroinitializer, align 16
@puzzl = dso_local local_unnamed_addr global [512 x i32] zeroinitializer, align 16
@p = dso_local local_unnamed_addr global [13 x [512 x i32]] zeroinitializer, align 16
@n = dso_local local_unnamed_addr global i32 0, align 4
@kount = dso_local local_unnamed_addr global i32 0, align 4
@sortlist = dso_local local_unnamed_addr global [5001 x i32] zeroinitializer, align 16
@biggest = dso_local local_unnamed_addr global i32 0, align 4
@littlest = dso_local local_unnamed_addr global i32 0, align 4
@top = dso_local local_unnamed_addr global i32 0, align 4
@z = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@w = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@e = dso_local local_unnamed_addr global [130 x %struct.complex] zeroinitializer, align 16
@zr = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@zi = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@str = private unnamed_addr constant [18 x i8] c" Error in Towers.\00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Initrand() local_unnamed_addr #0 {
  store i64 74755, ptr @seed, align 8, !tbaa !9
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local range(i32 0, 65536) i32 @Rand() local_unnamed_addr #1 {
  %1 = load i64, ptr @seed, align 8, !tbaa !9
  %2 = mul nsw i64 %1, 1309
  %3 = add nsw i64 %2, 13849
  %4 = and i64 %3, 65535
  store i64 %4, ptr @seed, align 8, !tbaa !9
  %5 = trunc nuw nsw i64 %4 to i32
  ret i32 %5
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Error(ptr noundef %0) local_unnamed_addr #2 {
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef %0)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Makenull(i32 noundef %0) local_unnamed_addr #0 {
  %2 = sext i32 %0 to i64
  %3 = getelementptr inbounds [4 x i8], ptr @stack, i64 %2
  store i32 0, ptr %3, align 4, !tbaa !11
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local range(i32 0, -2147483648) i32 @Getelement() local_unnamed_addr #2 {
  %1 = load i32, ptr @freelist, align 4, !tbaa !11
  %2 = icmp sgt i32 %1, 0
  br i1 %2, label %3, label %8

3:                                                ; preds = %0
  %4 = zext nneg i32 %1 to i64
  %5 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %4
  %6 = getelementptr inbounds nuw i8, ptr %5, i64 4
  %7 = load i32, ptr %6, align 4, !tbaa !12
  store i32 %7, ptr @freelist, align 4, !tbaa !11
  br label %10

8:                                                ; preds = %0
  %9 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.1)
  br label %10

10:                                               ; preds = %8, %3
  %11 = phi i32 [ %1, %3 ], [ 0, %8 ]
  ret i32 %11
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Push(i32 noundef %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = sext i32 %1 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @stack, i64 %3
  %5 = load i32, ptr %4, align 4, !tbaa !11
  %6 = icmp sgt i32 %5, 0
  br i1 %6, label %7, label %14

7:                                                ; preds = %2
  %8 = zext nneg i32 %5 to i64
  %9 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %8
  %10 = load i32, ptr %9, align 8, !tbaa !14
  %11 = icmp sgt i32 %10, %0
  br i1 %11, label %14, label %12

12:                                               ; preds = %7
  %13 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.2)
  br label %31

14:                                               ; preds = %2, %7
  %15 = load i32, ptr @freelist, align 4, !tbaa !11
  %16 = icmp sgt i32 %15, 0
  br i1 %16, label %17, label %22

17:                                               ; preds = %14
  %18 = zext nneg i32 %15 to i64
  %19 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %18
  %20 = getelementptr inbounds nuw i8, ptr %19, i64 4
  %21 = load i32, ptr %20, align 4, !tbaa !12
  store i32 %21, ptr @freelist, align 4, !tbaa !11
  br label %25

22:                                               ; preds = %14
  %23 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.1)
  %24 = load i32, ptr %4, align 4, !tbaa !11
  br label %25

25:                                               ; preds = %17, %22
  %26 = phi i32 [ %5, %17 ], [ %24, %22 ]
  %27 = phi i32 [ %15, %17 ], [ 0, %22 ]
  %28 = zext nneg i32 %27 to i64
  %29 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %28
  %30 = getelementptr inbounds nuw i8, ptr %29, i64 4
  store i32 %26, ptr %30, align 4, !tbaa !12
  store i32 %27, ptr %4, align 4, !tbaa !11
  store i32 %0, ptr %29, align 8, !tbaa !14
  br label %31

31:                                               ; preds = %12, %25
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Init(i32 noundef %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = sext i32 %0 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @stack, i64 %3
  store i32 0, ptr %4, align 4, !tbaa !11
  %5 = icmp sgt i32 %1, 0
  br i1 %5, label %9, label %39

6:                                                ; preds = %37
  %7 = add nsw i32 %11, -1
  %8 = load i32, ptr %4, align 4, !tbaa !11
  br label %9

9:                                                ; preds = %2, %6
  %10 = phi i32 [ %8, %6 ], [ 0, %2 ]
  %11 = phi i32 [ %7, %6 ], [ %1, %2 ]
  %12 = icmp sgt i32 %10, 0
  br i1 %12, label %13, label %20

13:                                               ; preds = %9
  %14 = zext nneg i32 %10 to i64
  %15 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %14
  %16 = load i32, ptr %15, align 8, !tbaa !14
  %17 = icmp sgt i32 %16, %11
  br i1 %17, label %20, label %18

18:                                               ; preds = %13
  %19 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.2)
  br label %37

20:                                               ; preds = %13, %9
  %21 = load i32, ptr @freelist, align 4, !tbaa !11
  %22 = icmp sgt i32 %21, 0
  br i1 %22, label %23, label %28

23:                                               ; preds = %20
  %24 = zext nneg i32 %21 to i64
  %25 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %24
  %26 = getelementptr inbounds nuw i8, ptr %25, i64 4
  %27 = load i32, ptr %26, align 4, !tbaa !12
  store i32 %27, ptr @freelist, align 4, !tbaa !11
  br label %31

28:                                               ; preds = %20
  %29 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.1)
  %30 = load i32, ptr %4, align 4, !tbaa !11
  br label %31

31:                                               ; preds = %28, %23
  %32 = phi i32 [ %10, %23 ], [ %30, %28 ]
  %33 = phi i32 [ %21, %23 ], [ 0, %28 ]
  %34 = zext nneg i32 %33 to i64
  %35 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %34
  %36 = getelementptr inbounds nuw i8, ptr %35, i64 4
  store i32 %32, ptr %36, align 4, !tbaa !12
  store i32 %33, ptr %4, align 4, !tbaa !11
  store i32 %11, ptr %35, align 8, !tbaa !14
  br label %37

37:                                               ; preds = %18, %31
  %38 = icmp sgt i32 %11, 1
  br i1 %38, label %6, label %39, !llvm.loop !15

39:                                               ; preds = %37, %2
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local i32 @Pop(i32 noundef %0) local_unnamed_addr #2 {
  %2 = sext i32 %0 to i64
  %3 = getelementptr inbounds [4 x i8], ptr @stack, i64 %2
  %4 = load i32, ptr %3, align 4, !tbaa !11
  %5 = icmp sgt i32 %4, 0
  br i1 %5, label %6, label %13

6:                                                ; preds = %1
  %7 = zext nneg i32 %4 to i64
  %8 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %7
  %9 = load i32, ptr %8, align 8, !tbaa !14
  %10 = getelementptr inbounds nuw i8, ptr %8, i64 4
  %11 = load i32, ptr %10, align 4, !tbaa !12
  %12 = load i32, ptr @freelist, align 4, !tbaa !11
  store i32 %12, ptr %10, align 4, !tbaa !12
  store i32 %4, ptr @freelist, align 4, !tbaa !11
  store i32 %11, ptr %3, align 4, !tbaa !11
  br label %15

13:                                               ; preds = %1
  %14 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.3)
  br label %15

15:                                               ; preds = %13, %6
  %16 = phi i32 [ %9, %6 ], [ 0, %13 ]
  ret i32 %16
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Move(i32 noundef %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = sext i32 %0 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @stack, i64 %3
  %5 = load i32, ptr %4, align 4, !tbaa !11
  %6 = icmp sgt i32 %5, 0
  br i1 %6, label %7, label %14

7:                                                ; preds = %2
  %8 = zext nneg i32 %5 to i64
  %9 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %8
  %10 = load i32, ptr %9, align 8, !tbaa !14
  %11 = getelementptr inbounds nuw i8, ptr %9, i64 4
  %12 = load i32, ptr %11, align 4, !tbaa !12
  %13 = load i32, ptr @freelist, align 4, !tbaa !11
  store i32 %13, ptr %11, align 4, !tbaa !12
  store i32 %5, ptr @freelist, align 4, !tbaa !11
  store i32 %12, ptr %4, align 4, !tbaa !11
  br label %16

14:                                               ; preds = %2
  %15 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.3)
  br label %16

16:                                               ; preds = %7, %14
  %17 = phi i32 [ %10, %7 ], [ 0, %14 ]
  %18 = sext i32 %1 to i64
  %19 = getelementptr inbounds [4 x i8], ptr @stack, i64 %18
  %20 = load i32, ptr %19, align 4, !tbaa !11
  %21 = icmp sgt i32 %20, 0
  br i1 %21, label %22, label %29

22:                                               ; preds = %16
  %23 = zext nneg i32 %20 to i64
  %24 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %23
  %25 = load i32, ptr %24, align 8, !tbaa !14
  %26 = icmp sgt i32 %25, %17
  br i1 %26, label %29, label %27

27:                                               ; preds = %22
  %28 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.2)
  br label %46

29:                                               ; preds = %22, %16
  %30 = load i32, ptr @freelist, align 4, !tbaa !11
  %31 = icmp sgt i32 %30, 0
  br i1 %31, label %32, label %37

32:                                               ; preds = %29
  %33 = zext nneg i32 %30 to i64
  %34 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %33
  %35 = getelementptr inbounds nuw i8, ptr %34, i64 4
  %36 = load i32, ptr %35, align 4, !tbaa !12
  store i32 %36, ptr @freelist, align 4, !tbaa !11
  br label %40

37:                                               ; preds = %29
  %38 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.1)
  %39 = load i32, ptr %19, align 4, !tbaa !11
  br label %40

40:                                               ; preds = %37, %32
  %41 = phi i32 [ %20, %32 ], [ %39, %37 ]
  %42 = phi i32 [ %30, %32 ], [ 0, %37 ]
  %43 = zext nneg i32 %42 to i64
  %44 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %43
  %45 = getelementptr inbounds nuw i8, ptr %44, i64 4
  store i32 %41, ptr %45, align 4, !tbaa !12
  store i32 %42, ptr %19, align 4, !tbaa !11
  store i32 %17, ptr %44, align 8, !tbaa !14
  br label %46

46:                                               ; preds = %27, %40
  %47 = load i32, ptr @movesdone, align 4, !tbaa !11
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr @movesdone, align 4, !tbaa !11
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @tower(i32 noundef %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #2 {
  %4 = icmp eq i32 %2, 1
  br i1 %4, label %5, label %7

5:                                                ; preds = %7, %3
  %6 = phi i32 [ %0, %3 ], [ %11, %7 ]
  tail call void @Move(i32 noundef %6, i32 noundef %1)
  ret void

7:                                                ; preds = %3, %7
  %8 = phi i32 [ %12, %7 ], [ %2, %3 ]
  %9 = phi i32 [ %11, %7 ], [ %0, %3 ]
  %10 = add i32 %1, %9
  %11 = sub i32 6, %10
  %12 = add nsw i32 %8, -1
  tail call void @tower(i32 noundef %9, i32 noundef %11, i32 noundef %12)
  tail call void @Move(i32 noundef %9, i32 noundef %1)
  %13 = icmp eq i32 %12, 1
  br i1 %13, label %5, label %7
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Towers() local_unnamed_addr #2 {
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 12), align 4, !tbaa !12
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 20), align 4, !tbaa !12
  store i32 2, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 28), align 4, !tbaa !12
  store i32 3, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 36), align 4, !tbaa !12
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 44), align 4, !tbaa !12
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 52), align 4, !tbaa !12
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 60), align 4, !tbaa !12
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 68), align 4, !tbaa !12
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 76), align 4, !tbaa !12
  store i32 9, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 84), align 4, !tbaa !12
  store i32 10, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 92), align 4, !tbaa !12
  store i32 11, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 100), align 4, !tbaa !12
  store i32 12, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 108), align 4, !tbaa !12
  store i32 13, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 116), align 4, !tbaa !12
  store i32 14, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 124), align 4, !tbaa !12
  store i32 15, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 132), align 4, !tbaa !12
  store i32 16, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 140), align 4, !tbaa !12
  store i32 17, ptr getelementptr inbounds nuw (i8, ptr @cellspace, i64 148), align 4, !tbaa !12
  store i32 18, ptr @freelist, align 4, !tbaa !11
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 4), align 4, !tbaa !11
  br label %4

1:                                                ; preds = %32
  %2 = add nsw i32 %6, -1
  %3 = load i32, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 4), align 4, !tbaa !11
  br label %4

4:                                                ; preds = %1, %0
  %5 = phi i32 [ %3, %1 ], [ 0, %0 ]
  %6 = phi i32 [ %2, %1 ], [ 14, %0 ]
  %7 = icmp sgt i32 %5, 0
  br i1 %7, label %8, label %15

8:                                                ; preds = %4
  %9 = zext nneg i32 %5 to i64
  %10 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %9
  %11 = load i32, ptr %10, align 8, !tbaa !14
  %12 = icmp sgt i32 %11, %6
  br i1 %12, label %15, label %13

13:                                               ; preds = %8
  %14 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.2)
  br label %32

15:                                               ; preds = %8, %4
  %16 = load i32, ptr @freelist, align 4, !tbaa !11
  %17 = icmp sgt i32 %16, 0
  br i1 %17, label %18, label %23

18:                                               ; preds = %15
  %19 = zext nneg i32 %16 to i64
  %20 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %19
  %21 = getelementptr inbounds nuw i8, ptr %20, i64 4
  %22 = load i32, ptr %21, align 4, !tbaa !12
  store i32 %22, ptr @freelist, align 4, !tbaa !11
  br label %26

23:                                               ; preds = %15
  %24 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef nonnull @.str.1)
  %25 = load i32, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 4), align 4, !tbaa !11
  br label %26

26:                                               ; preds = %23, %18
  %27 = phi i32 [ %5, %18 ], [ %25, %23 ]
  %28 = phi i32 [ %16, %18 ], [ 0, %23 ]
  %29 = zext nneg i32 %28 to i64
  %30 = getelementptr inbounds nuw [8 x i8], ptr @cellspace, i64 %29
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 4
  store i32 %27, ptr %31, align 4, !tbaa !12
  store i32 %28, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 4), align 4, !tbaa !11
  store i32 %6, ptr %30, align 8, !tbaa !14
  br label %32

32:                                               ; preds = %26, %13
  %33 = icmp samesign ugt i32 %6, 1
  br i1 %33, label %1, label %34, !llvm.loop !15

34:                                               ; preds = %32
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 8), align 8, !tbaa !11
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @stack, i64 12), align 4, !tbaa !11
  store i32 0, ptr @movesdone, align 4, !tbaa !11
  tail call void @tower(i32 noundef 1, i32 noundef 2, i32 noundef 14)
  %35 = load i32, ptr @movesdone, align 4, !tbaa !11
  %36 = icmp eq i32 %35, 16383
  br i1 %36, label %40, label %37

37:                                               ; preds = %34
  %38 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %39 = load i32, ptr @movesdone, align 4, !tbaa !11
  br label %40

40:                                               ; preds = %37, %34
  %41 = phi i32 [ %39, %37 ], [ 16383, %34 ]
  %42 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.5, i32 noundef %41)
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Towers()
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 100
  br i1 %4, label %5, label %1, !llvm.loop !17

5:                                                ; preds = %1
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #4

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind }

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
!11 = !{!6, !6, i64 0}
!12 = !{!13, !6, i64 4}
!13 = !{!"element", !6, i64 0, !6, i64 4}
!14 = !{!13, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
