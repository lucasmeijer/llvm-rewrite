; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@alphabet = dso_local local_unnamed_addr global [28 x i8] c"0ABCDEFGHIJKLMNOPQRSTUVWXYZ\00", align 16
@tasktab = dso_local local_unnamed_addr global [11 x ptr] zeroinitializer, align 16
@tasklist = dso_local local_unnamed_addr global ptr null, align 8
@qpktcount = dso_local local_unnamed_addr global i32 0, align 4
@holdcount = dso_local local_unnamed_addr global i32 0, align 4
@tracing = dso_local local_unnamed_addr global i32 1, align 4
@layout = dso_local local_unnamed_addr global i32 0, align 4
@tcb = dso_local local_unnamed_addr global ptr null, align 8
@taskid = dso_local local_unnamed_addr global i64 0, align 8
@v1 = dso_local local_unnamed_addr global i64 0, align 8
@v2 = dso_local local_unnamed_addr global i64 0, align 8
@.str.2 = private unnamed_addr constant [17 x i8] c"\0ABad task id %d\0A\00", align 1
@.str.6 = private unnamed_addr constant [33 x i8] c"qpkt count = %d  holdcount = %d\0A\00", align 1
@.str.7 = private unnamed_addr constant [19 x i8] c"These results are \00", align 1
@.str.8 = private unnamed_addr constant [8 x i8] c"correct\00", align 1
@.str.9 = private unnamed_addr constant [10 x i8] c"incorrect\00", align 1
@str = private unnamed_addr constant [20 x i8] c"Bench mark starting\00", align 1
@str.11 = private unnamed_addr constant [9 x i8] c"Starting\00", align 1
@str.12 = private unnamed_addr constant [9 x i8] c"finished\00", align 1
@str.13 = private unnamed_addr constant [12 x i8] c"\0Aend of run\00", align 1

; Function Attrs: mustprogress nofree nounwind willreturn memory(readwrite, argmem: none, target_mem: none) uwtable
define dso_local void @createtask(i32 noundef %0, i32 noundef %1, ptr noundef %2, i32 noundef %3, ptr noundef %4, i64 noundef %5, i64 noundef %6) local_unnamed_addr #0 {
  %8 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  %9 = sext i32 %0 to i64
  %10 = getelementptr inbounds [8 x i8], ptr @tasktab, i64 %9
  store ptr %8, ptr %10, align 8, !tbaa !9
  %11 = load ptr, ptr @tasklist, align 8, !tbaa !9
  store ptr %11, ptr %8, align 8, !tbaa !12
  %12 = getelementptr inbounds nuw i8, ptr %8, i64 8
  store i32 %0, ptr %12, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw i8, ptr %8, i64 12
  store i32 %1, ptr %13, align 4, !tbaa !17
  %14 = getelementptr inbounds nuw i8, ptr %8, i64 16
  store ptr %2, ptr %14, align 8, !tbaa !18
  %15 = getelementptr inbounds nuw i8, ptr %8, i64 24
  store i32 %3, ptr %15, align 8, !tbaa !19
  %16 = getelementptr inbounds nuw i8, ptr %8, i64 32
  store ptr %4, ptr %16, align 8, !tbaa !20
  %17 = getelementptr inbounds nuw i8, ptr %8, i64 40
  store i64 %5, ptr %17, align 8, !tbaa !21
  %18 = getelementptr inbounds nuw i8, ptr %8, i64 48
  store i64 %6, ptr %18, align 8, !tbaa !22
  store ptr %8, ptr @tasklist, align 8, !tbaa !9
  ret void
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nounwind willreturn memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable
define dso_local noalias noundef ptr @pkt(ptr noundef %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #2 {
  %4 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 20
  store i32 0, ptr %5, align 1
  store ptr %0, ptr %4, align 8, !tbaa !23
  %6 = getelementptr inbounds nuw i8, ptr %4, i64 8
  store i32 %1, ptr %6, align 8, !tbaa !25
  %7 = getelementptr inbounds nuw i8, ptr %4, i64 12
  store i32 %2, ptr %7, align 4, !tbaa !26
  %8 = getelementptr inbounds nuw i8, ptr %4, i64 16
  store i32 0, ptr %8, align 8, !tbaa !27
  ret ptr %4
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @trace(i8 noundef signext %0) local_unnamed_addr #3 {
  %2 = load i32, ptr @layout, align 4, !tbaa !28
  %3 = add nsw i32 %2, -1
  store i32 %3, ptr @layout, align 4, !tbaa !28
  %4 = icmp slt i32 %2, 2
  br i1 %4, label %5, label %7

5:                                                ; preds = %1
  %6 = tail call i32 @putchar(i32 10)
  store i32 50, ptr @layout, align 4, !tbaa !28
  br label %7

7:                                                ; preds = %5, %1
  %8 = sext i8 %0 to i32
  %9 = tail call i32 @putchar(i32 %8)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: nounwind uwtable
define dso_local void @schedule() local_unnamed_addr #5 {
  %1 = load ptr, ptr @tcb, align 8, !tbaa !9
  %2 = icmp eq ptr %1, null
  br i1 %2, label %51, label %3

3:                                                ; preds = %0, %48
  %4 = phi ptr [ %49, %48 ], [ %1, %0 ]
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 24
  %6 = load i32, ptr %5, align 8, !tbaa !19
  switch i32 %6, label %51 [
    i32 3, label %7
    i32 0, label %13
    i32 1, label %13
    i32 2, label %46
    i32 4, label %46
    i32 5, label %46
    i32 6, label %46
    i32 7, label %46
  ]

7:                                                ; preds = %3
  %8 = getelementptr inbounds nuw i8, ptr %4, i64 16
  %9 = load ptr, ptr %8, align 8, !tbaa !18
  %10 = load ptr, ptr %9, align 8, !tbaa !23
  store ptr %10, ptr %8, align 8, !tbaa !18
  %11 = icmp ne ptr %10, null
  %12 = zext i1 %11 to i32
  store i32 %12, ptr %5, align 8, !tbaa !19
  br label %13

13:                                               ; preds = %3, %3, %7
  %14 = phi ptr [ %9, %7 ], [ null, %3 ], [ null, %3 ]
  %15 = getelementptr inbounds nuw i8, ptr %4, i64 8
  %16 = load i32, ptr %15, align 8, !tbaa !16
  %17 = sext i32 %16 to i64
  store i64 %17, ptr @taskid, align 8, !tbaa !29
  %18 = getelementptr inbounds nuw i8, ptr %4, i64 40
  %19 = load i64, ptr %18, align 8, !tbaa !21
  store i64 %19, ptr @v1, align 8, !tbaa !29
  %20 = getelementptr inbounds nuw i8, ptr %4, i64 48
  %21 = load i64, ptr %20, align 8, !tbaa !22
  store i64 %21, ptr @v2, align 8, !tbaa !29
  %22 = load i32, ptr @tracing, align 4, !tbaa !28
  %23 = icmp eq i32 %22, 1
  br i1 %23, label %24, label %36

24:                                               ; preds = %13
  %25 = load i32, ptr @layout, align 4, !tbaa !28
  %26 = add nsw i32 %25, -1
  store i32 %26, ptr @layout, align 4, !tbaa !28
  %27 = icmp slt i32 %25, 2
  br i1 %27, label %28, label %30

28:                                               ; preds = %24
  %29 = tail call i32 @putchar(i32 10)
  store i32 50, ptr @layout, align 4, !tbaa !28
  br label %30

30:                                               ; preds = %24, %28
  %31 = shl i32 %16, 24
  %32 = add i32 %31, 805306368
  %33 = ashr exact i32 %32, 24
  %34 = tail call i32 @putchar(i32 %33)
  %35 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %36

36:                                               ; preds = %30, %13
  %37 = phi ptr [ %35, %30 ], [ %4, %13 ]
  %38 = getelementptr inbounds nuw i8, ptr %37, i64 32
  %39 = load ptr, ptr %38, align 8, !tbaa !20
  %40 = tail call ptr %39(ptr noundef %14) #11
  %41 = load i64, ptr @v1, align 8, !tbaa !29
  %42 = load ptr, ptr @tcb, align 8, !tbaa !9
  %43 = getelementptr inbounds nuw i8, ptr %42, i64 40
  store i64 %41, ptr %43, align 8, !tbaa !21
  %44 = load i64, ptr @v2, align 8, !tbaa !29
  %45 = getelementptr inbounds nuw i8, ptr %42, i64 48
  store i64 %44, ptr %45, align 8, !tbaa !22
  br label %48

46:                                               ; preds = %3, %3, %3, %3, %3
  %47 = load ptr, ptr %4, align 8, !tbaa !12
  br label %48

48:                                               ; preds = %36, %46
  %49 = phi ptr [ %47, %46 ], [ %40, %36 ]
  store ptr %49, ptr @tcb, align 8, !tbaa !9
  %50 = icmp eq ptr %49, null
  br i1 %50, label %51, label %3

51:                                               ; preds = %48, %3, %0
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local ptr @Wait() local_unnamed_addr #6 {
  %1 = load ptr, ptr @tcb, align 8, !tbaa !9
  %2 = getelementptr inbounds nuw i8, ptr %1, i64 24
  %3 = load i32, ptr %2, align 8, !tbaa !19
  %4 = or i32 %3, 2
  store i32 %4, ptr %2, align 8, !tbaa !19
  ret ptr %1
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local ptr @holdself() local_unnamed_addr #6 {
  %1 = load i32, ptr @holdcount, align 4, !tbaa !28
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @holdcount, align 4, !tbaa !28
  %3 = load ptr, ptr @tcb, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw i8, ptr %3, i64 24
  %5 = load i32, ptr %4, align 8, !tbaa !19
  %6 = or i32 %5, 4
  store i32 %6, ptr %4, align 8, !tbaa !19
  %7 = load ptr, ptr %3, align 8, !tbaa !12
  ret ptr %7
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @findtcb(i32 noundef %0) local_unnamed_addr #3 {
  %2 = add i32 %0, -1
  %3 = icmp ult i32 %2, 10
  br i1 %3, label %4, label %9

4:                                                ; preds = %1
  %5 = zext nneg i32 %0 to i64
  %6 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %5
  %7 = load ptr, ptr %6, align 8, !tbaa !9
  %8 = icmp eq ptr %7, null
  br i1 %8, label %9, label %11

9:                                                ; preds = %1, %4
  %10 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %0)
  br label %11

11:                                               ; preds = %9, %4
  %12 = phi ptr [ null, %9 ], [ %7, %4 ]
  ret ptr %12
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @release(i32 noundef %0) local_unnamed_addr #3 {
  %2 = add i32 %0, -1
  %3 = icmp ult i32 %2, 10
  br i1 %3, label %4, label %9

4:                                                ; preds = %1
  %5 = zext nneg i32 %0 to i64
  %6 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %5
  %7 = load ptr, ptr %6, align 8, !tbaa !9
  %8 = icmp eq ptr %7, null
  br i1 %8, label %9, label %11

9:                                                ; preds = %1, %4
  %10 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %0)
  br label %22

11:                                               ; preds = %4
  %12 = getelementptr inbounds nuw i8, ptr %7, i64 24
  %13 = load i32, ptr %12, align 8, !tbaa !19
  %14 = and i32 %13, 65531
  store i32 %14, ptr %12, align 8, !tbaa !19
  %15 = getelementptr inbounds nuw i8, ptr %7, i64 12
  %16 = load i32, ptr %15, align 4, !tbaa !17
  %17 = load ptr, ptr @tcb, align 8, !tbaa !9
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 12
  %19 = load i32, ptr %18, align 4, !tbaa !17
  %20 = icmp sgt i32 %16, %19
  %21 = select i1 %20, ptr %7, ptr %17
  br label %22

22:                                               ; preds = %9, %11
  %23 = phi ptr [ null, %9 ], [ %21, %11 ]
  ret ptr %23
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @qpkt(ptr noundef %0) local_unnamed_addr #3 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %3 = load i32, ptr %2, align 8, !tbaa !25
  %4 = add i32 %3, -1
  %5 = icmp ult i32 %4, 10
  br i1 %5, label %6, label %11

6:                                                ; preds = %1
  %7 = zext nneg i32 %3 to i64
  %8 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %7
  %9 = load ptr, ptr %8, align 8, !tbaa !9
  %10 = icmp eq ptr %9, null
  br i1 %10, label %11, label %13

11:                                               ; preds = %1, %6
  %12 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %3)
  br label %38

13:                                               ; preds = %6
  %14 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %15 = add nsw i32 %14, 1
  store i32 %15, ptr @qpktcount, align 4, !tbaa !28
  store ptr null, ptr %0, align 8, !tbaa !23
  %16 = load i64, ptr @taskid, align 8, !tbaa !29
  %17 = trunc i64 %16 to i32
  store i32 %17, ptr %2, align 8, !tbaa !25
  %18 = getelementptr inbounds nuw i8, ptr %9, i64 16
  %19 = load ptr, ptr %18, align 8, !tbaa !18
  %20 = icmp eq ptr %19, null
  br i1 %20, label %21, label %32

21:                                               ; preds = %13
  store ptr %0, ptr %18, align 8, !tbaa !18
  %22 = getelementptr inbounds nuw i8, ptr %9, i64 24
  %23 = load i32, ptr %22, align 8, !tbaa !19
  %24 = or i32 %23, 1
  store i32 %24, ptr %22, align 8, !tbaa !19
  %25 = getelementptr inbounds nuw i8, ptr %9, i64 12
  %26 = load i32, ptr %25, align 4, !tbaa !17
  %27 = load ptr, ptr @tcb, align 8, !tbaa !9
  %28 = getelementptr inbounds nuw i8, ptr %27, i64 12
  %29 = load i32, ptr %28, align 4, !tbaa !17
  %30 = icmp sgt i32 %26, %29
  %31 = select i1 %30, ptr %9, ptr %27
  br label %38

32:                                               ; preds = %13, %32
  %33 = phi ptr [ %34, %32 ], [ %18, %13 ]
  %34 = load ptr, ptr %33, align 8, !tbaa !23
  %35 = icmp eq ptr %34, null
  br i1 %35, label %36, label %32, !llvm.loop !30

36:                                               ; preds = %32
  store ptr %0, ptr %33, align 8, !tbaa !23
  %37 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %38

38:                                               ; preds = %21, %36, %11
  %39 = phi ptr [ %31, %21 ], [ null, %11 ], [ %37, %36 ]
  ret ptr %39
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @append(ptr noundef initializes((0, 8)) %0, ptr nofree noundef captures(none) %1) local_unnamed_addr #7 {
  store ptr null, ptr %0, align 8, !tbaa !23
  br label %3

3:                                                ; preds = %3, %2
  %4 = phi ptr [ %1, %2 ], [ %5, %3 ]
  %5 = load ptr, ptr %4, align 8, !tbaa !23
  %6 = icmp eq ptr %5, null
  br i1 %6, label %7, label %3, !llvm.loop !30

7:                                                ; preds = %3
  store ptr %0, ptr %4, align 8, !tbaa !23
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @idlefn(ptr nofree readnone captures(none) %0) #3 {
  %2 = load i64, ptr @v2, align 8, !tbaa !29
  %3 = add nsw i64 %2, -1
  store i64 %3, ptr @v2, align 8, !tbaa !29
  %4 = icmp eq i64 %3, 0
  br i1 %4, label %5, label %13

5:                                                ; preds = %1
  %6 = load i32, ptr @holdcount, align 4, !tbaa !28
  %7 = add nsw i32 %6, 1
  store i32 %7, ptr @holdcount, align 4, !tbaa !28
  %8 = load ptr, ptr @tcb, align 8, !tbaa !9
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 24
  %10 = load i32, ptr %9, align 8, !tbaa !19
  %11 = or i32 %10, 4
  store i32 %11, ptr %9, align 8, !tbaa !19
  %12 = load ptr, ptr %8, align 8, !tbaa !12
  br label %52

13:                                               ; preds = %1
  %14 = load i64, ptr @v1, align 8, !tbaa !29
  %15 = and i64 %14, 1
  %16 = icmp eq i64 %15, 0
  %17 = lshr i64 %14, 1
  %18 = and i64 %17, 32767
  br i1 %16, label %19, label %35

19:                                               ; preds = %13
  store i64 %18, ptr @v1, align 8, !tbaa !29
  %20 = load ptr, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 40), align 8, !tbaa !9
  %21 = icmp eq ptr %20, null
  br i1 %21, label %22, label %24

22:                                               ; preds = %19
  %23 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef 5)
  br label %52

24:                                               ; preds = %19
  %25 = getelementptr inbounds nuw i8, ptr %20, i64 24
  %26 = load i32, ptr %25, align 8, !tbaa !19
  %27 = and i32 %26, 65531
  store i32 %27, ptr %25, align 8, !tbaa !19
  %28 = getelementptr inbounds nuw i8, ptr %20, i64 12
  %29 = load i32, ptr %28, align 4, !tbaa !17
  %30 = load ptr, ptr @tcb, align 8, !tbaa !9
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 12
  %32 = load i32, ptr %31, align 4, !tbaa !17
  %33 = icmp sgt i32 %29, %32
  %34 = select i1 %33, ptr %20, ptr %30
  br label %52

35:                                               ; preds = %13
  %36 = xor i64 %18, 53256
  store i64 %36, ptr @v1, align 8, !tbaa !29
  %37 = load ptr, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 48), align 16, !tbaa !9
  %38 = icmp eq ptr %37, null
  br i1 %38, label %39, label %41

39:                                               ; preds = %35
  %40 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef 6)
  br label %52

41:                                               ; preds = %35
  %42 = getelementptr inbounds nuw i8, ptr %37, i64 24
  %43 = load i32, ptr %42, align 8, !tbaa !19
  %44 = and i32 %43, 65531
  store i32 %44, ptr %42, align 8, !tbaa !19
  %45 = getelementptr inbounds nuw i8, ptr %37, i64 12
  %46 = load i32, ptr %45, align 4, !tbaa !17
  %47 = load ptr, ptr @tcb, align 8, !tbaa !9
  %48 = getelementptr inbounds nuw i8, ptr %47, i64 12
  %49 = load i32, ptr %48, align 4, !tbaa !17
  %50 = icmp sgt i32 %46, %49
  %51 = select i1 %50, ptr %37, ptr %47
  br label %52

52:                                               ; preds = %41, %39, %24, %22, %5
  %53 = phi ptr [ %12, %5 ], [ %34, %24 ], [ null, %22 ], [ null, %39 ], [ %51, %41 ]
  ret ptr %53
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @workfn(ptr noundef %0) #3 {
  %2 = icmp eq ptr %0, null
  br i1 %2, label %3, label %8

3:                                                ; preds = %1
  %4 = load ptr, ptr @tcb, align 8, !tbaa !9
  %5 = getelementptr inbounds nuw i8, ptr %4, i64 24
  %6 = load i32, ptr %5, align 8, !tbaa !19
  %7 = or i32 %6, 2
  store i32 %7, ptr %5, align 8, !tbaa !19
  br label %73

8:                                                ; preds = %1
  %9 = load i64, ptr @v1, align 8, !tbaa !29
  %10 = sub nsw i64 7, %9
  store i64 %10, ptr @v1, align 8, !tbaa !29
  %11 = trunc i64 %10 to i32
  %12 = getelementptr inbounds nuw i8, ptr %0, i64 8
  store i32 %11, ptr %12, align 8, !tbaa !25
  %13 = getelementptr inbounds nuw i8, ptr %0, i64 16
  store i32 0, ptr %13, align 8, !tbaa !27
  %14 = getelementptr inbounds nuw i8, ptr %0, i64 20
  %15 = load i64, ptr @v2, align 8, !tbaa !29
  %16 = add nsw i64 %15, 1
  %17 = icmp sgt i64 %15, 25
  %18 = select i1 %17, i64 1, i64 %16
  %19 = getelementptr inbounds i8, ptr @alphabet, i64 %18
  %20 = load i8, ptr %19, align 1, !tbaa !32
  store i8 %20, ptr %14, align 4, !tbaa !32
  %21 = add nsw i64 %18, 1
  %22 = icmp sgt i64 %18, 25
  %23 = select i1 %22, i64 1, i64 %21
  %24 = getelementptr inbounds i8, ptr @alphabet, i64 %23
  %25 = load i8, ptr %24, align 1, !tbaa !32
  %26 = getelementptr inbounds nuw i8, ptr %0, i64 21
  store i8 %25, ptr %26, align 1, !tbaa !32
  %27 = add nsw i64 %23, 1
  %28 = icmp sgt i64 %23, 25
  %29 = select i1 %28, i64 1, i64 %27
  %30 = getelementptr inbounds i8, ptr @alphabet, i64 %29
  %31 = load i8, ptr %30, align 1, !tbaa !32
  %32 = getelementptr inbounds nuw i8, ptr %0, i64 22
  store i8 %31, ptr %32, align 2, !tbaa !32
  %33 = add nsw i64 %29, 1
  %34 = icmp sgt i64 %29, 25
  %35 = select i1 %34, i64 1, i64 %33
  store i64 %35, ptr @v2, align 8
  %36 = getelementptr inbounds i8, ptr @alphabet, i64 %35
  %37 = load i8, ptr %36, align 1, !tbaa !32
  %38 = getelementptr inbounds nuw i8, ptr %0, i64 23
  store i8 %37, ptr %38, align 1, !tbaa !32
  %39 = add i32 %11, -1
  %40 = icmp ult i32 %39, 10
  br i1 %40, label %41, label %46

41:                                               ; preds = %8
  %42 = and i64 %10, 4294967295
  %43 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %42
  %44 = load ptr, ptr %43, align 8, !tbaa !9
  %45 = icmp eq ptr %44, null
  br i1 %45, label %46, label %48

46:                                               ; preds = %41, %8
  %47 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %11)
  br label %73

48:                                               ; preds = %41
  %49 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %50 = add nsw i32 %49, 1
  store i32 %50, ptr @qpktcount, align 4, !tbaa !28
  store ptr null, ptr %0, align 8, !tbaa !23
  %51 = load i64, ptr @taskid, align 8, !tbaa !29
  %52 = trunc i64 %51 to i32
  store i32 %52, ptr %12, align 8, !tbaa !25
  %53 = getelementptr inbounds nuw i8, ptr %44, i64 16
  %54 = load ptr, ptr %53, align 8, !tbaa !33
  %55 = icmp eq ptr %54, null
  br i1 %55, label %56, label %67

56:                                               ; preds = %48
  store ptr %0, ptr %53, align 8, !tbaa !18
  %57 = getelementptr inbounds nuw i8, ptr %44, i64 24
  %58 = load i32, ptr %57, align 8, !tbaa !19
  %59 = or i32 %58, 1
  store i32 %59, ptr %57, align 8, !tbaa !19
  %60 = getelementptr inbounds nuw i8, ptr %44, i64 12
  %61 = load i32, ptr %60, align 4, !tbaa !17
  %62 = load ptr, ptr @tcb, align 8, !tbaa !9
  %63 = getelementptr inbounds nuw i8, ptr %62, i64 12
  %64 = load i32, ptr %63, align 4, !tbaa !17
  %65 = icmp sgt i32 %61, %64
  %66 = select i1 %65, ptr %44, ptr %62
  br label %73

67:                                               ; preds = %48, %67
  %68 = phi ptr [ %69, %67 ], [ %54, %48 ]
  %69 = load ptr, ptr %68, align 8, !tbaa !23
  %70 = icmp eq ptr %69, null
  br i1 %70, label %71, label %67, !llvm.loop !30

71:                                               ; preds = %67
  store ptr %0, ptr %68, align 8, !tbaa !23
  %72 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %73

73:                                               ; preds = %71, %56, %46, %3
  %74 = phi ptr [ %4, %3 ], [ %66, %56 ], [ null, %46 ], [ %72, %71 ]
  ret ptr %74
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @handlerfn(ptr noundef %0) #3 {
  %2 = icmp eq ptr %0, null
  br i1 %2, label %13, label %3

3:                                                ; preds = %1
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 12
  %5 = load i32, ptr %4, align 4, !tbaa !26
  %6 = icmp eq i32 %5, 1001
  %7 = select i1 %6, ptr @v1, ptr @v2
  store ptr null, ptr %0, align 8, !tbaa !23
  br label %8

8:                                                ; preds = %8, %3
  %9 = phi ptr [ %7, %3 ], [ %10, %8 ]
  %10 = load ptr, ptr %9, align 8, !tbaa !23
  %11 = icmp eq ptr %10, null
  br i1 %11, label %12, label %8, !llvm.loop !30

12:                                               ; preds = %8
  store ptr %0, ptr %9, align 8, !tbaa !23
  br label %13

13:                                               ; preds = %12, %1
  %14 = load i64, ptr @v1, align 8, !tbaa !29
  %15 = icmp eq i64 %14, 0
  br i1 %15, label %110, label %16

16:                                               ; preds = %13
  %17 = inttoptr i64 %14 to ptr
  %18 = getelementptr inbounds nuw i8, ptr %17, i64 16
  %19 = load i32, ptr %18, align 8, !tbaa !27
  %20 = icmp sgt i32 %19, 3
  br i1 %20, label %21, label %60

21:                                               ; preds = %16
  %22 = load ptr, ptr %17, align 8, !tbaa !23
  %23 = ptrtoint ptr %22 to i64
  store i64 %23, ptr @v1, align 8, !tbaa !29
  %24 = getelementptr inbounds nuw i8, ptr %17, i64 8
  %25 = load i32, ptr %24, align 8, !tbaa !25
  %26 = add i32 %25, -1
  %27 = icmp ult i32 %26, 10
  br i1 %27, label %28, label %33

28:                                               ; preds = %21
  %29 = zext nneg i32 %25 to i64
  %30 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %29
  %31 = load ptr, ptr %30, align 8, !tbaa !9
  %32 = icmp eq ptr %31, null
  br i1 %32, label %33, label %35

33:                                               ; preds = %28, %21
  %34 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %25)
  br label %115

35:                                               ; preds = %28
  %36 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %37 = add nsw i32 %36, 1
  store i32 %37, ptr @qpktcount, align 4, !tbaa !28
  store ptr null, ptr %17, align 8, !tbaa !23
  %38 = load i64, ptr @taskid, align 8, !tbaa !29
  %39 = trunc i64 %38 to i32
  store i32 %39, ptr %24, align 8, !tbaa !25
  %40 = getelementptr inbounds nuw i8, ptr %31, i64 16
  %41 = load ptr, ptr %40, align 8, !tbaa !33
  %42 = icmp eq ptr %41, null
  br i1 %42, label %43, label %54

43:                                               ; preds = %35
  store ptr %17, ptr %40, align 8, !tbaa !18
  %44 = getelementptr inbounds nuw i8, ptr %31, i64 24
  %45 = load i32, ptr %44, align 8, !tbaa !19
  %46 = or i32 %45, 1
  store i32 %46, ptr %44, align 8, !tbaa !19
  %47 = getelementptr inbounds nuw i8, ptr %31, i64 12
  %48 = load i32, ptr %47, align 4, !tbaa !17
  %49 = load ptr, ptr @tcb, align 8, !tbaa !9
  %50 = getelementptr inbounds nuw i8, ptr %49, i64 12
  %51 = load i32, ptr %50, align 4, !tbaa !17
  %52 = icmp sgt i32 %48, %51
  %53 = select i1 %52, ptr %31, ptr %49
  br label %115

54:                                               ; preds = %35, %54
  %55 = phi ptr [ %56, %54 ], [ %41, %35 ]
  %56 = load ptr, ptr %55, align 8, !tbaa !23
  %57 = icmp eq ptr %56, null
  br i1 %57, label %58, label %54, !llvm.loop !30

58:                                               ; preds = %54
  store ptr %17, ptr %55, align 8, !tbaa !23
  %59 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %115

60:                                               ; preds = %16
  %61 = load i64, ptr @v2, align 8, !tbaa !29
  %62 = icmp eq i64 %61, 0
  br i1 %62, label %110, label %63

63:                                               ; preds = %60
  %64 = inttoptr i64 %61 to ptr
  %65 = load ptr, ptr %64, align 8, !tbaa !23
  %66 = ptrtoint ptr %65 to i64
  store i64 %66, ptr @v2, align 8, !tbaa !29
  %67 = getelementptr inbounds nuw i8, ptr %17, i64 20
  %68 = sext i32 %19 to i64
  %69 = getelementptr inbounds i8, ptr %67, i64 %68
  %70 = load i8, ptr %69, align 1, !tbaa !32
  %71 = sext i8 %70 to i32
  %72 = getelementptr inbounds nuw i8, ptr %64, i64 16
  store i32 %71, ptr %72, align 8, !tbaa !27
  %73 = add nsw i32 %19, 1
  store i32 %73, ptr %18, align 8, !tbaa !27
  %74 = getelementptr inbounds nuw i8, ptr %64, i64 8
  %75 = load i32, ptr %74, align 8, !tbaa !25
  %76 = add i32 %75, -1
  %77 = icmp ult i32 %76, 10
  br i1 %77, label %78, label %83

78:                                               ; preds = %63
  %79 = zext nneg i32 %75 to i64
  %80 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %79
  %81 = load ptr, ptr %80, align 8, !tbaa !9
  %82 = icmp eq ptr %81, null
  br i1 %82, label %83, label %85

83:                                               ; preds = %78, %63
  %84 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %75)
  br label %115

85:                                               ; preds = %78
  %86 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %87 = add nsw i32 %86, 1
  store i32 %87, ptr @qpktcount, align 4, !tbaa !28
  store ptr null, ptr %64, align 8, !tbaa !23
  %88 = load i64, ptr @taskid, align 8, !tbaa !29
  %89 = trunc i64 %88 to i32
  store i32 %89, ptr %74, align 8, !tbaa !25
  %90 = getelementptr inbounds nuw i8, ptr %81, i64 16
  %91 = load ptr, ptr %90, align 8, !tbaa !33
  %92 = icmp eq ptr %91, null
  br i1 %92, label %93, label %104

93:                                               ; preds = %85
  store ptr %64, ptr %90, align 8, !tbaa !18
  %94 = getelementptr inbounds nuw i8, ptr %81, i64 24
  %95 = load i32, ptr %94, align 8, !tbaa !19
  %96 = or i32 %95, 1
  store i32 %96, ptr %94, align 8, !tbaa !19
  %97 = getelementptr inbounds nuw i8, ptr %81, i64 12
  %98 = load i32, ptr %97, align 4, !tbaa !17
  %99 = load ptr, ptr @tcb, align 8, !tbaa !9
  %100 = getelementptr inbounds nuw i8, ptr %99, i64 12
  %101 = load i32, ptr %100, align 4, !tbaa !17
  %102 = icmp sgt i32 %98, %101
  %103 = select i1 %102, ptr %81, ptr %99
  br label %115

104:                                              ; preds = %85, %104
  %105 = phi ptr [ %106, %104 ], [ %91, %85 ]
  %106 = load ptr, ptr %105, align 8, !tbaa !23
  %107 = icmp eq ptr %106, null
  br i1 %107, label %108, label %104, !llvm.loop !30

108:                                              ; preds = %104
  store ptr %64, ptr %105, align 8, !tbaa !23
  %109 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %115

110:                                              ; preds = %60, %13
  %111 = load ptr, ptr @tcb, align 8, !tbaa !9
  %112 = getelementptr inbounds nuw i8, ptr %111, i64 24
  %113 = load i32, ptr %112, align 8, !tbaa !19
  %114 = or i32 %113, 2
  store i32 %114, ptr %112, align 8, !tbaa !19
  br label %115

115:                                              ; preds = %108, %93, %83, %43, %33, %58, %110
  %116 = phi ptr [ %111, %110 ], [ %109, %108 ], [ null, %83 ], [ %103, %93 ], [ null, %33 ], [ %53, %43 ], [ %59, %58 ]
  ret ptr %116
}

; Function Attrs: nofree nounwind uwtable
define dso_local ptr @devfn(ptr noundef %0) #3 {
  %2 = icmp eq ptr %0, null
  br i1 %2, label %3, label %49

3:                                                ; preds = %1
  %4 = load i64, ptr @v1, align 8, !tbaa !29
  %5 = icmp eq i64 %4, 0
  br i1 %5, label %6, label %11

6:                                                ; preds = %3
  %7 = load ptr, ptr @tcb, align 8, !tbaa !9
  %8 = getelementptr inbounds nuw i8, ptr %7, i64 24
  %9 = load i32, ptr %8, align 8, !tbaa !19
  %10 = or i32 %9, 2
  store i32 %10, ptr %8, align 8, !tbaa !19
  br label %73

11:                                               ; preds = %3
  %12 = inttoptr i64 %4 to ptr
  store i64 0, ptr @v1, align 8, !tbaa !29
  %13 = getelementptr inbounds nuw i8, ptr %12, i64 8
  %14 = load i32, ptr %13, align 8, !tbaa !25
  %15 = add i32 %14, -1
  %16 = icmp ult i32 %15, 10
  br i1 %16, label %17, label %22

17:                                               ; preds = %11
  %18 = zext nneg i32 %14 to i64
  %19 = getelementptr inbounds nuw [8 x i8], ptr @tasktab, i64 %18
  %20 = load ptr, ptr %19, align 8, !tbaa !9
  %21 = icmp eq ptr %20, null
  br i1 %21, label %22, label %24

22:                                               ; preds = %17, %11
  %23 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %14)
  br label %73

24:                                               ; preds = %17
  %25 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr @qpktcount, align 4, !tbaa !28
  store ptr null, ptr %12, align 8, !tbaa !23
  %27 = load i64, ptr @taskid, align 8, !tbaa !29
  %28 = trunc i64 %27 to i32
  store i32 %28, ptr %13, align 8, !tbaa !25
  %29 = getelementptr inbounds nuw i8, ptr %20, i64 16
  %30 = load ptr, ptr %29, align 8, !tbaa !33
  %31 = icmp eq ptr %30, null
  br i1 %31, label %32, label %43

32:                                               ; preds = %24
  store ptr %12, ptr %29, align 8, !tbaa !18
  %33 = getelementptr inbounds nuw i8, ptr %20, i64 24
  %34 = load i32, ptr %33, align 8, !tbaa !19
  %35 = or i32 %34, 1
  store i32 %35, ptr %33, align 8, !tbaa !19
  %36 = getelementptr inbounds nuw i8, ptr %20, i64 12
  %37 = load i32, ptr %36, align 4, !tbaa !17
  %38 = load ptr, ptr @tcb, align 8, !tbaa !9
  %39 = getelementptr inbounds nuw i8, ptr %38, i64 12
  %40 = load i32, ptr %39, align 4, !tbaa !17
  %41 = icmp sgt i32 %37, %40
  %42 = select i1 %41, ptr %20, ptr %38
  br label %73

43:                                               ; preds = %24, %43
  %44 = phi ptr [ %45, %43 ], [ %30, %24 ]
  %45 = load ptr, ptr %44, align 8, !tbaa !23
  %46 = icmp eq ptr %45, null
  br i1 %46, label %47, label %43, !llvm.loop !30

47:                                               ; preds = %43
  store ptr %12, ptr %44, align 8, !tbaa !23
  %48 = load ptr, ptr @tcb, align 8, !tbaa !9
  br label %73

49:                                               ; preds = %1
  %50 = ptrtoint ptr %0 to i64
  store i64 %50, ptr @v1, align 8, !tbaa !29
  %51 = load i32, ptr @tracing, align 4, !tbaa !28
  %52 = icmp eq i32 %51, 1
  br i1 %52, label %53, label %65

53:                                               ; preds = %49
  %54 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %55 = load i32, ptr %54, align 8, !tbaa !27
  %56 = load i32, ptr @layout, align 4, !tbaa !28
  %57 = add nsw i32 %56, -1
  store i32 %57, ptr @layout, align 4, !tbaa !28
  %58 = icmp slt i32 %56, 2
  br i1 %58, label %59, label %61

59:                                               ; preds = %53
  %60 = tail call i32 @putchar(i32 10)
  store i32 50, ptr @layout, align 4, !tbaa !28
  br label %61

61:                                               ; preds = %53, %59
  %62 = shl i32 %55, 24
  %63 = ashr exact i32 %62, 24
  %64 = tail call i32 @putchar(i32 %63)
  br label %65

65:                                               ; preds = %61, %49
  %66 = load i32, ptr @holdcount, align 4, !tbaa !28
  %67 = add nsw i32 %66, 1
  store i32 %67, ptr @holdcount, align 4, !tbaa !28
  %68 = load ptr, ptr @tcb, align 8, !tbaa !9
  %69 = getelementptr inbounds nuw i8, ptr %68, i64 24
  %70 = load i32, ptr %69, align 8, !tbaa !19
  %71 = or i32 %70, 4
  store i32 %71, ptr %69, align 8, !tbaa !19
  %72 = load ptr, ptr %68, align 8, !tbaa !12
  br label %73

73:                                               ; preds = %47, %32, %22, %65, %6
  %74 = phi ptr [ %7, %6 ], [ %72, %65 ], [ %42, %32 ], [ null, %22 ], [ %48, %47 ]
  ret ptr %74
}

; Function Attrs: nounwind uwtable
define dso_local range(i32 0, 2) i32 @main() local_unnamed_addr #5 {
  %1 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %2 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %2, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 8), align 8, !tbaa !9
  %3 = load ptr, ptr @tasklist, align 8, !tbaa !9
  store ptr %3, ptr %2, align 8, !tbaa !12
  %4 = getelementptr inbounds nuw i8, ptr %2, i64 8
  store i32 1, ptr %4, align 8, !tbaa !16
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 12
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 32
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(16) %5, i8 0, i64 16, i1 false)
  store ptr @idlefn, ptr %6, align 8, !tbaa !20
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 40
  store i64 1, ptr %7, align 8, !tbaa !21
  %8 = getelementptr inbounds nuw i8, ptr %2, i64 48
  store i64 10000000, ptr %8, align 8, !tbaa !22
  %9 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr null, ptr %9, align 8, !tbaa !23
  %10 = getelementptr inbounds nuw i8, ptr %9, i64 8
  store <4 x i32> <i32 0, i32 1001, i32 0, i32 0>, ptr %10, align 8
  %11 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr %9, ptr %11, align 8, !tbaa !23
  %12 = getelementptr inbounds nuw i8, ptr %11, i64 8
  store <4 x i32> <i32 0, i32 1001, i32 0, i32 0>, ptr %12, align 8
  %13 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %13, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 16), align 16, !tbaa !9
  store ptr %2, ptr %13, align 8, !tbaa !12
  %14 = getelementptr inbounds nuw i8, ptr %13, i64 8
  store i32 2, ptr %14, align 8, !tbaa !16
  %15 = getelementptr inbounds nuw i8, ptr %13, i64 12
  store i32 1000, ptr %15, align 4, !tbaa !17
  %16 = getelementptr inbounds nuw i8, ptr %13, i64 16
  store ptr %11, ptr %16, align 8, !tbaa !18
  %17 = getelementptr inbounds nuw i8, ptr %13, i64 24
  store i32 3, ptr %17, align 8, !tbaa !19
  %18 = getelementptr inbounds nuw i8, ptr %13, i64 32
  store ptr @workfn, ptr %18, align 8, !tbaa !20
  %19 = getelementptr inbounds nuw i8, ptr %13, i64 40
  store i64 3, ptr %19, align 8, !tbaa !21
  %20 = getelementptr inbounds nuw i8, ptr %13, i64 48
  store i64 0, ptr %20, align 8, !tbaa !22
  %21 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr null, ptr %21, align 8, !tbaa !23
  %22 = getelementptr inbounds nuw i8, ptr %21, i64 8
  store <4 x i32> <i32 5, i32 1000, i32 0, i32 0>, ptr %22, align 8
  %23 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr %21, ptr %23, align 8, !tbaa !23
  %24 = getelementptr inbounds nuw i8, ptr %23, i64 8
  store <4 x i32> <i32 5, i32 1000, i32 0, i32 0>, ptr %24, align 8
  %25 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr %23, ptr %25, align 8, !tbaa !23
  %26 = getelementptr inbounds nuw i8, ptr %25, i64 8
  store <4 x i32> <i32 5, i32 1000, i32 0, i32 0>, ptr %26, align 8
  %27 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %27, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 24), align 8, !tbaa !9
  store ptr %13, ptr %27, align 8, !tbaa !12
  %28 = getelementptr inbounds nuw i8, ptr %27, i64 8
  store i32 3, ptr %28, align 8, !tbaa !16
  %29 = getelementptr inbounds nuw i8, ptr %27, i64 12
  store i32 2000, ptr %29, align 4, !tbaa !17
  %30 = getelementptr inbounds nuw i8, ptr %27, i64 16
  store ptr %25, ptr %30, align 8, !tbaa !18
  %31 = getelementptr inbounds nuw i8, ptr %27, i64 24
  store i32 3, ptr %31, align 8, !tbaa !19
  %32 = getelementptr inbounds nuw i8, ptr %27, i64 32
  store ptr @handlerfn, ptr %32, align 8, !tbaa !20
  %33 = getelementptr inbounds nuw i8, ptr %27, i64 40
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16) %33, i8 0, i64 16, i1 false)
  %34 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr null, ptr %34, align 8, !tbaa !23
  %35 = getelementptr inbounds nuw i8, ptr %34, i64 8
  store <4 x i32> <i32 6, i32 1000, i32 0, i32 0>, ptr %35, align 8
  %36 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr %34, ptr %36, align 8, !tbaa !23
  %37 = getelementptr inbounds nuw i8, ptr %36, i64 8
  store <4 x i32> <i32 6, i32 1000, i32 0, i32 0>, ptr %37, align 8
  %38 = tail call noalias dereferenceable_or_null(24) ptr @malloc(i64 noundef 24) #10
  store ptr %36, ptr %38, align 8, !tbaa !23
  %39 = getelementptr inbounds nuw i8, ptr %38, i64 8
  store <4 x i32> <i32 6, i32 1000, i32 0, i32 0>, ptr %39, align 8
  %40 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %40, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 32), align 16, !tbaa !9
  store ptr %27, ptr %40, align 8, !tbaa !12
  %41 = getelementptr inbounds nuw i8, ptr %40, i64 8
  store i32 4, ptr %41, align 8, !tbaa !16
  %42 = getelementptr inbounds nuw i8, ptr %40, i64 12
  store i32 3000, ptr %42, align 4, !tbaa !17
  %43 = getelementptr inbounds nuw i8, ptr %40, i64 16
  store ptr %38, ptr %43, align 8, !tbaa !18
  %44 = getelementptr inbounds nuw i8, ptr %40, i64 24
  store i32 3, ptr %44, align 8, !tbaa !19
  %45 = getelementptr inbounds nuw i8, ptr %40, i64 32
  store ptr @handlerfn, ptr %45, align 8, !tbaa !20
  %46 = getelementptr inbounds nuw i8, ptr %40, i64 40
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16) %46, i8 0, i64 16, i1 false)
  %47 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %47, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 40), align 8, !tbaa !9
  store ptr %40, ptr %47, align 8, !tbaa !12
  %48 = getelementptr inbounds nuw i8, ptr %47, i64 8
  store i32 5, ptr %48, align 8, !tbaa !16
  %49 = getelementptr inbounds nuw i8, ptr %47, i64 12
  store i32 4000, ptr %49, align 4, !tbaa !17
  %50 = getelementptr inbounds nuw i8, ptr %47, i64 16
  store ptr null, ptr %50, align 8, !tbaa !18
  %51 = getelementptr inbounds nuw i8, ptr %47, i64 24
  store i32 2, ptr %51, align 8, !tbaa !19
  %52 = getelementptr inbounds nuw i8, ptr %47, i64 32
  store ptr @devfn, ptr %52, align 8, !tbaa !20
  %53 = getelementptr inbounds nuw i8, ptr %47, i64 40
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16) %53, i8 0, i64 16, i1 false)
  %54 = tail call noalias dereferenceable_or_null(56) ptr @malloc(i64 noundef 56) #10
  store ptr %54, ptr getelementptr inbounds nuw (i8, ptr @tasktab, i64 48), align 16, !tbaa !9
  store ptr %47, ptr %54, align 8, !tbaa !12
  %55 = getelementptr inbounds nuw i8, ptr %54, i64 8
  store i32 6, ptr %55, align 8, !tbaa !16
  %56 = getelementptr inbounds nuw i8, ptr %54, i64 12
  store i32 5000, ptr %56, align 4, !tbaa !17
  %57 = getelementptr inbounds nuw i8, ptr %54, i64 16
  store ptr null, ptr %57, align 8, !tbaa !18
  %58 = getelementptr inbounds nuw i8, ptr %54, i64 24
  store i32 2, ptr %58, align 8, !tbaa !19
  %59 = getelementptr inbounds nuw i8, ptr %54, i64 32
  store ptr @devfn, ptr %59, align 8, !tbaa !20
  %60 = getelementptr inbounds nuw i8, ptr %54, i64 40
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16) %60, i8 0, i64 16, i1 false)
  store ptr %54, ptr @tasklist, align 8, !tbaa !9
  store ptr %54, ptr @tcb, align 8, !tbaa !9
  store i32 0, ptr @holdcount, align 4, !tbaa !28
  store i32 0, ptr @qpktcount, align 4, !tbaa !28
  %61 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.11)
  store i32 0, ptr @tracing, align 4, !tbaa !28
  store i32 0, ptr @layout, align 4, !tbaa !28
  tail call void @schedule()
  %62 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.12)
  %63 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %64 = load i32, ptr @holdcount, align 4, !tbaa !28
  %65 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.6, i32 noundef %63, i32 noundef %64)
  %66 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.7)
  %67 = load i32, ptr @qpktcount, align 4, !tbaa !28
  %68 = icmp ne i32 %67, 23263894
  %69 = load i32, ptr @holdcount, align 4
  %70 = icmp ne i32 %69, 9305557
  %71 = select i1 %68, i1 true, i1 %70
  %72 = select i1 %71, ptr @.str.9, ptr @.str.8
  %73 = zext i1 %71 to i32
  %74 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) %72)
  %75 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.13)
  ret i32 %73
}

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #8

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #8

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #9

attributes #0 = { mustprogress nofree nounwind willreturn memory(readwrite, argmem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree nounwind willreturn memory(write, argmem: none, inaccessiblemem: readwrite, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nofree nounwind }
attributes #9 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #10 = { nounwind allocsize(0) }
attributes #11 = { nounwind }

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
!10 = !{!"p1 _ZTS4task", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!13, !10, i64 0}
!13 = !{!"task", !10, i64 0, !6, i64 8, !6, i64 12, !14, i64 16, !6, i64 24, !11, i64 32, !15, i64 40, !15, i64 48}
!14 = !{!"p1 _ZTS6packet", !11, i64 0}
!15 = !{!"long", !7, i64 0}
!16 = !{!13, !6, i64 8}
!17 = !{!13, !6, i64 12}
!18 = !{!13, !14, i64 16}
!19 = !{!13, !6, i64 24}
!20 = !{!13, !11, i64 32}
!21 = !{!13, !15, i64 40}
!22 = !{!13, !15, i64 48}
!23 = !{!24, !14, i64 0}
!24 = !{!"packet", !14, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !7, i64 20}
!25 = !{!24, !6, i64 8}
!26 = !{!24, !6, i64 12}
!27 = !{!24, !6, i64 16}
!28 = !{!6, !6, i64 0}
!29 = !{!15, !15, i64 0}
!30 = distinct !{!30, !31}
!31 = !{!"llvm.loop.mustprogress"}
!32 = !{!7, !7, i64 0}
!33 = !{!14, !14, i64 0}
