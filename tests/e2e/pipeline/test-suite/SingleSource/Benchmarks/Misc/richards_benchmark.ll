; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/richards_benchmark.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.task = type { ptr, i32, i32, ptr, i32, ptr, i64, i64 }
%struct.packet = type { ptr, i32, i32, i32, [4 x i8] }

@alphabet = dso_local global [28 x i8] c"0ABCDEFGHIJKLMNOPQRSTUVWXYZ\00", align 16
@tasktab = dso_local global [11 x ptr] zeroinitializer, align 16
@tasklist = dso_local global ptr null, align 8
@qpktcount = dso_local global i32 0, align 4
@holdcount = dso_local global i32 0, align 4
@tracing = dso_local global i32 1, align 4
@layout = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.1 = private unnamed_addr constant [3 x i8] c"%c\00", align 1
@tcb = dso_local global ptr null, align 8
@taskid = dso_local global i64 0, align 8
@v1 = dso_local global i64 0, align 8
@v2 = dso_local global i64 0, align 8
@.str.2 = private unnamed_addr constant [17 x i8] c"\0ABad task id %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [21 x i8] c"Bench mark starting\0A\00", align 1
@.str.4 = private unnamed_addr constant [10 x i8] c"Starting\0A\00", align 1
@.str.5 = private unnamed_addr constant [10 x i8] c"finished\0A\00", align 1
@.str.6 = private unnamed_addr constant [33 x i8] c"qpkt count = %d  holdcount = %d\0A\00", align 1
@.str.7 = private unnamed_addr constant [19 x i8] c"These results are \00", align 1
@.str.8 = private unnamed_addr constant [8 x i8] c"correct\00", align 1
@.str.9 = private unnamed_addr constant [10 x i8] c"incorrect\00", align 1
@.str.10 = private unnamed_addr constant [13 x i8] c"\0Aend of run\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @createtask(i32 noundef %0, i32 noundef %1, ptr noundef %2, i32 noundef %3, ptr noundef %4, i64 noundef %5, i64 noundef %6) #0 {
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca ptr, align 8
  %11 = alloca i32, align 4
  %12 = alloca ptr, align 8
  %13 = alloca i64, align 8
  %14 = alloca i64, align 8
  %15 = alloca ptr, align 8
  store i32 %0, ptr %8, align 4, !tbaa !9
  store i32 %1, ptr %9, align 4, !tbaa !9
  store ptr %2, ptr %10, align 8, !tbaa !10
  store i32 %3, ptr %11, align 4, !tbaa !9
  store ptr %4, ptr %12, align 8, !tbaa !13
  store i64 %5, ptr %13, align 8, !tbaa !14
  store i64 %6, ptr %14, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %15) #4
  %16 = call noalias ptr @malloc(i64 noundef 56) #5
  store ptr %16, ptr %15, align 8, !tbaa !16
  %17 = load ptr, ptr %15, align 8, !tbaa !16
  %18 = load i32, ptr %8, align 4, !tbaa !9
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds [11 x ptr], ptr @tasktab, i64 0, i64 %19
  store ptr %17, ptr %20, align 8, !tbaa !16
  %21 = load ptr, ptr @tasklist, align 8, !tbaa !16
  %22 = load ptr, ptr %15, align 8, !tbaa !16
  %23 = getelementptr inbounds nuw %struct.task, ptr %22, i32 0, i32 0
  store ptr %21, ptr %23, align 8, !tbaa !18
  %24 = load i32, ptr %8, align 4, !tbaa !9
  %25 = load ptr, ptr %15, align 8, !tbaa !16
  %26 = getelementptr inbounds nuw %struct.task, ptr %25, i32 0, i32 1
  store i32 %24, ptr %26, align 8, !tbaa !20
  %27 = load i32, ptr %9, align 4, !tbaa !9
  %28 = load ptr, ptr %15, align 8, !tbaa !16
  %29 = getelementptr inbounds nuw %struct.task, ptr %28, i32 0, i32 2
  store i32 %27, ptr %29, align 4, !tbaa !21
  %30 = load ptr, ptr %10, align 8, !tbaa !10
  %31 = load ptr, ptr %15, align 8, !tbaa !16
  %32 = getelementptr inbounds nuw %struct.task, ptr %31, i32 0, i32 3
  store ptr %30, ptr %32, align 8, !tbaa !22
  %33 = load i32, ptr %11, align 4, !tbaa !9
  %34 = load ptr, ptr %15, align 8, !tbaa !16
  %35 = getelementptr inbounds nuw %struct.task, ptr %34, i32 0, i32 4
  store i32 %33, ptr %35, align 8, !tbaa !23
  %36 = load ptr, ptr %12, align 8, !tbaa !13
  %37 = load ptr, ptr %15, align 8, !tbaa !16
  %38 = getelementptr inbounds nuw %struct.task, ptr %37, i32 0, i32 5
  store ptr %36, ptr %38, align 8, !tbaa !24
  %39 = load i64, ptr %13, align 8, !tbaa !14
  %40 = load ptr, ptr %15, align 8, !tbaa !16
  %41 = getelementptr inbounds nuw %struct.task, ptr %40, i32 0, i32 6
  store i64 %39, ptr %41, align 8, !tbaa !25
  %42 = load i64, ptr %14, align 8, !tbaa !14
  %43 = load ptr, ptr %15, align 8, !tbaa !16
  %44 = getelementptr inbounds nuw %struct.task, ptr %43, i32 0, i32 7
  store i64 %42, ptr %44, align 8, !tbaa !26
  %45 = load ptr, ptr %15, align 8, !tbaa !16
  store ptr %45, ptr @tasklist, align 8, !tbaa !16
  call void @llvm.lifetime.end.p0(ptr %15) #4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local ptr @pkt(ptr noundef %0, i32 noundef %1, i32 noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca ptr, align 8
  store ptr %0, ptr %4, align 8, !tbaa !10
  store i32 %1, ptr %5, align 4, !tbaa !9
  store i32 %2, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #4
  call void @llvm.lifetime.start.p0(ptr %8) #4
  %9 = call noalias ptr @malloc(i64 noundef 24) #5
  store ptr %9, ptr %8, align 8, !tbaa !10
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %10

10:                                               ; preds = %19, %3
  %11 = load i32, ptr %7, align 4, !tbaa !9
  %12 = icmp sle i32 %11, 3
  br i1 %12, label %13, label %22

13:                                               ; preds = %10
  %14 = load ptr, ptr %8, align 8, !tbaa !10
  %15 = getelementptr inbounds nuw %struct.packet, ptr %14, i32 0, i32 4
  %16 = load i32, ptr %7, align 4, !tbaa !9
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [4 x i8], ptr %15, i64 0, i64 %17
  store i8 0, ptr %18, align 1, !tbaa !27
  br label %19

19:                                               ; preds = %13
  %20 = load i32, ptr %7, align 4, !tbaa !9
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %7, align 4, !tbaa !9
  br label %10, !llvm.loop !28

22:                                               ; preds = %10
  %23 = load ptr, ptr %4, align 8, !tbaa !10
  %24 = load ptr, ptr %8, align 8, !tbaa !10
  %25 = getelementptr inbounds nuw %struct.packet, ptr %24, i32 0, i32 0
  store ptr %23, ptr %25, align 8, !tbaa !30
  %26 = load i32, ptr %5, align 4, !tbaa !9
  %27 = load ptr, ptr %8, align 8, !tbaa !10
  %28 = getelementptr inbounds nuw %struct.packet, ptr %27, i32 0, i32 1
  store i32 %26, ptr %28, align 8, !tbaa !32
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = load ptr, ptr %8, align 8, !tbaa !10
  %31 = getelementptr inbounds nuw %struct.packet, ptr %30, i32 0, i32 2
  store i32 %29, ptr %31, align 4, !tbaa !33
  %32 = load ptr, ptr %8, align 8, !tbaa !10
  %33 = getelementptr inbounds nuw %struct.packet, ptr %32, i32 0, i32 3
  store i32 0, ptr %33, align 8, !tbaa !34
  %34 = load ptr, ptr %8, align 8, !tbaa !10
  call void @llvm.lifetime.end.p0(ptr %8) #4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  ret ptr %34
}

; Function Attrs: nounwind uwtable
define dso_local void @trace(i8 noundef signext %0) #0 {
  %2 = alloca i8, align 1
  store i8 %0, ptr %2, align 1, !tbaa !27
  %3 = load i32, ptr @layout, align 4, !tbaa !9
  %4 = add nsw i32 %3, -1
  store i32 %4, ptr @layout, align 4, !tbaa !9
  %5 = icmp sle i32 %4, 0
  br i1 %5, label %6, label %8

6:                                                ; preds = %1
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  store i32 50, ptr @layout, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %6, %1
  %9 = load i8, ptr %2, align 1, !tbaa !27
  %10 = sext i8 %9 to i32
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %10)
  ret void
}

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nounwind uwtable
define dso_local void @schedule() #0 {
  %1 = alloca ptr, align 8
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  br label %4

4:                                                ; preds = %66, %0
  %5 = load ptr, ptr @tcb, align 8, !tbaa !16
  %6 = icmp ne ptr %5, null
  br i1 %6, label %7, label %67

7:                                                ; preds = %4
  call void @llvm.lifetime.start.p0(ptr %1) #4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store ptr null, ptr %1, align 8, !tbaa !10
  %8 = load ptr, ptr @tcb, align 8, !tbaa !16
  %9 = getelementptr inbounds nuw %struct.task, ptr %8, i32 0, i32 4
  %10 = load i32, ptr %9, align 8, !tbaa !23
  switch i32 %10, label %62 [
    i32 3, label %11
    i32 0, label %28
    i32 1, label %28
    i32 2, label %58
    i32 4, label %58
    i32 5, label %58
    i32 6, label %58
    i32 7, label %58
  ]

11:                                               ; preds = %7
  %12 = load ptr, ptr @tcb, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw %struct.task, ptr %12, i32 0, i32 3
  %14 = load ptr, ptr %13, align 8, !tbaa !22
  store ptr %14, ptr %1, align 8, !tbaa !10
  %15 = load ptr, ptr %1, align 8, !tbaa !10
  %16 = getelementptr inbounds nuw %struct.packet, ptr %15, i32 0, i32 0
  %17 = load ptr, ptr %16, align 8, !tbaa !30
  %18 = load ptr, ptr @tcb, align 8, !tbaa !16
  %19 = getelementptr inbounds nuw %struct.task, ptr %18, i32 0, i32 3
  store ptr %17, ptr %19, align 8, !tbaa !22
  %20 = load ptr, ptr @tcb, align 8, !tbaa !16
  %21 = getelementptr inbounds nuw %struct.task, ptr %20, i32 0, i32 3
  %22 = load ptr, ptr %21, align 8, !tbaa !22
  %23 = icmp eq ptr %22, null
  %24 = zext i1 %23 to i64
  %25 = select i1 %23, i32 0, i32 1
  %26 = load ptr, ptr @tcb, align 8, !tbaa !16
  %27 = getelementptr inbounds nuw %struct.task, ptr %26, i32 0, i32 4
  store i32 %25, ptr %27, align 8, !tbaa !23
  br label %28

28:                                               ; preds = %7, %7, %11
  %29 = load ptr, ptr @tcb, align 8, !tbaa !16
  %30 = getelementptr inbounds nuw %struct.task, ptr %29, i32 0, i32 1
  %31 = load i32, ptr %30, align 8, !tbaa !20
  %32 = sext i32 %31 to i64
  store i64 %32, ptr @taskid, align 8, !tbaa !14
  %33 = load ptr, ptr @tcb, align 8, !tbaa !16
  %34 = getelementptr inbounds nuw %struct.task, ptr %33, i32 0, i32 6
  %35 = load i64, ptr %34, align 8, !tbaa !25
  store i64 %35, ptr @v1, align 8, !tbaa !14
  %36 = load ptr, ptr @tcb, align 8, !tbaa !16
  %37 = getelementptr inbounds nuw %struct.task, ptr %36, i32 0, i32 7
  %38 = load i64, ptr %37, align 8, !tbaa !26
  store i64 %38, ptr @v2, align 8, !tbaa !14
  %39 = load i32, ptr @tracing, align 4, !tbaa !9
  %40 = icmp eq i32 %39, 1
  br i1 %40, label %41, label %45

41:                                               ; preds = %28
  %42 = load i64, ptr @taskid, align 8, !tbaa !14
  %43 = add nsw i64 %42, 48
  %44 = trunc i64 %43 to i8
  call void @trace(i8 noundef signext %44)
  br label %45

45:                                               ; preds = %41, %28
  %46 = load ptr, ptr @tcb, align 8, !tbaa !16
  %47 = getelementptr inbounds nuw %struct.task, ptr %46, i32 0, i32 5
  %48 = load ptr, ptr %47, align 8, !tbaa !24
  %49 = load ptr, ptr %1, align 8, !tbaa !10
  %50 = call ptr %48(ptr noundef %49)
  store ptr %50, ptr %2, align 8, !tbaa !16
  %51 = load i64, ptr @v1, align 8, !tbaa !14
  %52 = load ptr, ptr @tcb, align 8, !tbaa !16
  %53 = getelementptr inbounds nuw %struct.task, ptr %52, i32 0, i32 6
  store i64 %51, ptr %53, align 8, !tbaa !25
  %54 = load i64, ptr @v2, align 8, !tbaa !14
  %55 = load ptr, ptr @tcb, align 8, !tbaa !16
  %56 = getelementptr inbounds nuw %struct.task, ptr %55, i32 0, i32 7
  store i64 %54, ptr %56, align 8, !tbaa !26
  %57 = load ptr, ptr %2, align 8, !tbaa !16
  store ptr %57, ptr @tcb, align 8, !tbaa !16
  br label %63

58:                                               ; preds = %7, %7, %7, %7, %7
  %59 = load ptr, ptr @tcb, align 8, !tbaa !16
  %60 = getelementptr inbounds nuw %struct.task, ptr %59, i32 0, i32 0
  %61 = load ptr, ptr %60, align 8, !tbaa !18
  store ptr %61, ptr @tcb, align 8, !tbaa !16
  br label %63

62:                                               ; preds = %7
  store i32 1, ptr %3, align 4
  br label %64

63:                                               ; preds = %58, %45
  store i32 0, ptr %3, align 4
  br label %64

64:                                               ; preds = %63, %62
  call void @llvm.lifetime.end.p0(ptr %2) #4
  call void @llvm.lifetime.end.p0(ptr %1) #4
  %65 = load i32, ptr %3, align 4
  switch i32 %65, label %68 [
    i32 0, label %66
    i32 1, label %67
  ]

66:                                               ; preds = %64
  br label %4, !llvm.loop !35

67:                                               ; preds = %64, %4
  ret void

68:                                               ; preds = %64
  unreachable
}

; Function Attrs: nounwind uwtable
define dso_local ptr @Wait() #0 {
  %1 = load ptr, ptr @tcb, align 8, !tbaa !16
  %2 = getelementptr inbounds nuw %struct.task, ptr %1, i32 0, i32 4
  %3 = load i32, ptr %2, align 8, !tbaa !23
  %4 = or i32 %3, 2
  store i32 %4, ptr %2, align 8, !tbaa !23
  %5 = load ptr, ptr @tcb, align 8, !tbaa !16
  ret ptr %5
}

; Function Attrs: nounwind uwtable
define dso_local ptr @holdself() #0 {
  %1 = load i32, ptr @holdcount, align 4, !tbaa !9
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @holdcount, align 4, !tbaa !9
  %3 = load ptr, ptr @tcb, align 8, !tbaa !16
  %4 = getelementptr inbounds nuw %struct.task, ptr %3, i32 0, i32 4
  %5 = load i32, ptr %4, align 8, !tbaa !23
  %6 = or i32 %5, 4
  store i32 %6, ptr %4, align 8, !tbaa !23
  %7 = load ptr, ptr @tcb, align 8, !tbaa !16
  %8 = getelementptr inbounds nuw %struct.task, ptr %7, i32 0, i32 0
  %9 = load ptr, ptr %8, align 8, !tbaa !18
  ret ptr %9
}

; Function Attrs: nounwind uwtable
define dso_local ptr @findtcb(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store ptr null, ptr %3, align 8, !tbaa !16
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = icmp sle i32 1, %4
  br i1 %5, label %6, label %15

6:                                                ; preds = %1
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = sext i32 %7 to i64
  %9 = icmp sle i64 %8, 10
  br i1 %9, label %10, label %15

10:                                               ; preds = %6
  %11 = load i32, ptr %2, align 4, !tbaa !9
  %12 = sext i32 %11 to i64
  %13 = getelementptr inbounds [11 x ptr], ptr @tasktab, i64 0, i64 %12
  %14 = load ptr, ptr %13, align 8, !tbaa !16
  store ptr %14, ptr %3, align 8, !tbaa !16
  br label %15

15:                                               ; preds = %10, %6, %1
  %16 = load ptr, ptr %3, align 8, !tbaa !16
  %17 = icmp eq ptr %16, null
  br i1 %17, label %18, label %21

18:                                               ; preds = %15
  %19 = load i32, ptr %2, align 4, !tbaa !9
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %19)
  br label %21

21:                                               ; preds = %18, %15
  %22 = load ptr, ptr %3, align 8, !tbaa !16
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret ptr %22
}

; Function Attrs: nounwind uwtable
define dso_local ptr @release(i32 noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %6 = load i32, ptr %3, align 4, !tbaa !9
  %7 = call ptr @findtcb(i32 noundef %6)
  store ptr %7, ptr %4, align 8, !tbaa !16
  %8 = load ptr, ptr %4, align 8, !tbaa !16
  %9 = icmp eq ptr %8, null
  br i1 %9, label %10, label %11

10:                                               ; preds = %1
  store ptr null, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %27

11:                                               ; preds = %1
  %12 = load ptr, ptr %4, align 8, !tbaa !16
  %13 = getelementptr inbounds nuw %struct.task, ptr %12, i32 0, i32 4
  %14 = load i32, ptr %13, align 8, !tbaa !23
  %15 = and i32 %14, 65531
  store i32 %15, ptr %13, align 8, !tbaa !23
  %16 = load ptr, ptr %4, align 8, !tbaa !16
  %17 = getelementptr inbounds nuw %struct.task, ptr %16, i32 0, i32 2
  %18 = load i32, ptr %17, align 4, !tbaa !21
  %19 = load ptr, ptr @tcb, align 8, !tbaa !16
  %20 = getelementptr inbounds nuw %struct.task, ptr %19, i32 0, i32 2
  %21 = load i32, ptr %20, align 4, !tbaa !21
  %22 = icmp sgt i32 %18, %21
  br i1 %22, label %23, label %25

23:                                               ; preds = %11
  %24 = load ptr, ptr %4, align 8, !tbaa !16
  store ptr %24, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %27

25:                                               ; preds = %11
  %26 = load ptr, ptr @tcb, align 8, !tbaa !16
  store ptr %26, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %27

27:                                               ; preds = %25, %23, %10
  call void @llvm.lifetime.end.p0(ptr %4) #4
  %28 = load ptr, ptr %2, align 8
  ret ptr %28
}

; Function Attrs: nounwind uwtable
define dso_local ptr @qpkt(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %6 = load ptr, ptr %3, align 8, !tbaa !10
  %7 = getelementptr inbounds nuw %struct.packet, ptr %6, i32 0, i32 1
  %8 = load i32, ptr %7, align 8, !tbaa !32
  %9 = call ptr @findtcb(i32 noundef %8)
  store ptr %9, ptr %4, align 8, !tbaa !16
  %10 = load ptr, ptr %4, align 8, !tbaa !16
  %11 = icmp eq ptr %10, null
  br i1 %11, label %12, label %14

12:                                               ; preds = %1
  %13 = load ptr, ptr %4, align 8, !tbaa !16
  store ptr %13, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %51

14:                                               ; preds = %1
  %15 = load i32, ptr @qpktcount, align 4, !tbaa !9
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr @qpktcount, align 4, !tbaa !9
  %17 = load ptr, ptr %3, align 8, !tbaa !10
  %18 = getelementptr inbounds nuw %struct.packet, ptr %17, i32 0, i32 0
  store ptr null, ptr %18, align 8, !tbaa !30
  %19 = load i64, ptr @taskid, align 8, !tbaa !14
  %20 = trunc i64 %19 to i32
  %21 = load ptr, ptr %3, align 8, !tbaa !10
  %22 = getelementptr inbounds nuw %struct.packet, ptr %21, i32 0, i32 1
  store i32 %20, ptr %22, align 8, !tbaa !32
  %23 = load ptr, ptr %4, align 8, !tbaa !16
  %24 = getelementptr inbounds nuw %struct.task, ptr %23, i32 0, i32 3
  %25 = load ptr, ptr %24, align 8, !tbaa !22
  %26 = icmp eq ptr %25, null
  br i1 %26, label %27, label %45

27:                                               ; preds = %14
  %28 = load ptr, ptr %3, align 8, !tbaa !10
  %29 = load ptr, ptr %4, align 8, !tbaa !16
  %30 = getelementptr inbounds nuw %struct.task, ptr %29, i32 0, i32 3
  store ptr %28, ptr %30, align 8, !tbaa !22
  %31 = load ptr, ptr %4, align 8, !tbaa !16
  %32 = getelementptr inbounds nuw %struct.task, ptr %31, i32 0, i32 4
  %33 = load i32, ptr %32, align 8, !tbaa !23
  %34 = or i32 %33, 1
  store i32 %34, ptr %32, align 8, !tbaa !23
  %35 = load ptr, ptr %4, align 8, !tbaa !16
  %36 = getelementptr inbounds nuw %struct.task, ptr %35, i32 0, i32 2
  %37 = load i32, ptr %36, align 4, !tbaa !21
  %38 = load ptr, ptr @tcb, align 8, !tbaa !16
  %39 = getelementptr inbounds nuw %struct.task, ptr %38, i32 0, i32 2
  %40 = load i32, ptr %39, align 4, !tbaa !21
  %41 = icmp sgt i32 %37, %40
  br i1 %41, label %42, label %44

42:                                               ; preds = %27
  %43 = load ptr, ptr %4, align 8, !tbaa !16
  store ptr %43, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %51

44:                                               ; preds = %27
  br label %49

45:                                               ; preds = %14
  %46 = load ptr, ptr %3, align 8, !tbaa !10
  %47 = load ptr, ptr %4, align 8, !tbaa !16
  %48 = getelementptr inbounds nuw %struct.task, ptr %47, i32 0, i32 3
  call void @append(ptr noundef %46, ptr noundef %48)
  br label %49

49:                                               ; preds = %45, %44
  %50 = load ptr, ptr @tcb, align 8, !tbaa !16
  store ptr %50, ptr %2, align 8
  store i32 1, ptr %5, align 4
  br label %51

51:                                               ; preds = %49, %42, %12
  call void @llvm.lifetime.end.p0(ptr %4) #4
  %52 = load ptr, ptr %2, align 8
  ret ptr %52
}

; Function Attrs: nounwind uwtable
define dso_local void @append(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !10
  store ptr %1, ptr %4, align 8, !tbaa !10
  %5 = load ptr, ptr %3, align 8, !tbaa !10
  %6 = getelementptr inbounds nuw %struct.packet, ptr %5, i32 0, i32 0
  store ptr null, ptr %6, align 8, !tbaa !30
  br label %7

7:                                                ; preds = %12, %2
  %8 = load ptr, ptr %4, align 8, !tbaa !10
  %9 = getelementptr inbounds nuw %struct.packet, ptr %8, i32 0, i32 0
  %10 = load ptr, ptr %9, align 8, !tbaa !30
  %11 = icmp ne ptr %10, null
  br i1 %11, label %12, label %16

12:                                               ; preds = %7
  %13 = load ptr, ptr %4, align 8, !tbaa !10
  %14 = getelementptr inbounds nuw %struct.packet, ptr %13, i32 0, i32 0
  %15 = load ptr, ptr %14, align 8, !tbaa !30
  store ptr %15, ptr %4, align 8, !tbaa !10
  br label %7, !llvm.loop !36

16:                                               ; preds = %7
  %17 = load ptr, ptr %3, align 8, !tbaa !10
  %18 = load ptr, ptr %4, align 8, !tbaa !10
  %19 = getelementptr inbounds nuw %struct.packet, ptr %18, i32 0, i32 0
  store ptr %17, ptr %19, align 8, !tbaa !30
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local ptr @idlefn(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !10
  %4 = load i64, ptr @v2, align 8, !tbaa !14
  %5 = add nsw i64 %4, -1
  store i64 %5, ptr @v2, align 8, !tbaa !14
  %6 = load i64, ptr @v2, align 8, !tbaa !14
  %7 = icmp eq i64 %6, 0
  br i1 %7, label %8, label %10

8:                                                ; preds = %1
  %9 = call ptr @holdself()
  store ptr %9, ptr %2, align 8
  br label %25

10:                                               ; preds = %1
  %11 = load i64, ptr @v1, align 8, !tbaa !14
  %12 = and i64 %11, 1
  %13 = icmp eq i64 %12, 0
  br i1 %13, label %14, label %19

14:                                               ; preds = %10
  %15 = load i64, ptr @v1, align 8, !tbaa !14
  %16 = ashr i64 %15, 1
  %17 = and i64 %16, 32767
  store i64 %17, ptr @v1, align 8, !tbaa !14
  %18 = call ptr @release(i32 noundef 5)
  store ptr %18, ptr %2, align 8
  br label %25

19:                                               ; preds = %10
  %20 = load i64, ptr @v1, align 8, !tbaa !14
  %21 = ashr i64 %20, 1
  %22 = and i64 %21, 32767
  %23 = xor i64 %22, 53256
  store i64 %23, ptr @v1, align 8, !tbaa !14
  %24 = call ptr @release(i32 noundef 6)
  store ptr %24, ptr %2, align 8
  br label %25

25:                                               ; preds = %19, %14, %8
  %26 = load ptr, ptr %2, align 8
  ret ptr %26
}

; Function Attrs: nounwind uwtable
define dso_local ptr @workfn(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !10
  %5 = load ptr, ptr %3, align 8, !tbaa !10
  %6 = icmp eq ptr %5, null
  br i1 %6, label %7, label %9

7:                                                ; preds = %1
  %8 = call ptr @Wait()
  store ptr %8, ptr %2, align 8
  br label %42

9:                                                ; preds = %1
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %10 = load i64, ptr @v1, align 8, !tbaa !14
  %11 = sub nsw i64 7, %10
  store i64 %11, ptr @v1, align 8, !tbaa !14
  %12 = load i64, ptr @v1, align 8, !tbaa !14
  %13 = trunc i64 %12 to i32
  %14 = load ptr, ptr %3, align 8, !tbaa !10
  %15 = getelementptr inbounds nuw %struct.packet, ptr %14, i32 0, i32 1
  store i32 %13, ptr %15, align 8, !tbaa !32
  %16 = load ptr, ptr %3, align 8, !tbaa !10
  %17 = getelementptr inbounds nuw %struct.packet, ptr %16, i32 0, i32 3
  store i32 0, ptr %17, align 8, !tbaa !34
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %18

18:                                               ; preds = %36, %9
  %19 = load i32, ptr %4, align 4, !tbaa !9
  %20 = icmp sle i32 %19, 3
  br i1 %20, label %21, label %39

21:                                               ; preds = %18
  %22 = load i64, ptr @v2, align 8, !tbaa !14
  %23 = add nsw i64 %22, 1
  store i64 %23, ptr @v2, align 8, !tbaa !14
  %24 = load i64, ptr @v2, align 8, !tbaa !14
  %25 = icmp sgt i64 %24, 26
  br i1 %25, label %26, label %27

26:                                               ; preds = %21
  store i64 1, ptr @v2, align 8, !tbaa !14
  br label %27

27:                                               ; preds = %26, %21
  %28 = load i64, ptr @v2, align 8, !tbaa !14
  %29 = getelementptr inbounds [28 x i8], ptr @alphabet, i64 0, i64 %28
  %30 = load i8, ptr %29, align 1, !tbaa !27
  %31 = load ptr, ptr %3, align 8, !tbaa !10
  %32 = getelementptr inbounds nuw %struct.packet, ptr %31, i32 0, i32 4
  %33 = load i32, ptr %4, align 4, !tbaa !9
  %34 = sext i32 %33 to i64
  %35 = getelementptr inbounds [4 x i8], ptr %32, i64 0, i64 %34
  store i8 %30, ptr %35, align 1, !tbaa !27
  br label %36

36:                                               ; preds = %27
  %37 = load i32, ptr %4, align 4, !tbaa !9
  %38 = add nsw i32 %37, 1
  store i32 %38, ptr %4, align 4, !tbaa !9
  br label %18, !llvm.loop !37

39:                                               ; preds = %18
  %40 = load ptr, ptr %3, align 8, !tbaa !10
  %41 = call ptr @qpkt(ptr noundef %40)
  store ptr %41, ptr %2, align 8
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %42

42:                                               ; preds = %39, %7
  %43 = load ptr, ptr %2, align 8
  ret ptr %43
}

; Function Attrs: nounwind uwtable
define dso_local ptr @handlerfn(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !10
  %8 = load ptr, ptr %3, align 8, !tbaa !10
  %9 = icmp ne ptr %8, null
  br i1 %9, label %10, label %18

10:                                               ; preds = %1
  %11 = load ptr, ptr %3, align 8, !tbaa !10
  %12 = load ptr, ptr %3, align 8, !tbaa !10
  %13 = getelementptr inbounds nuw %struct.packet, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !33
  %15 = icmp eq i32 %14, 1001
  %16 = zext i1 %15 to i64
  %17 = select i1 %15, ptr @v1, ptr @v2
  call void @append(ptr noundef %11, ptr noundef %17)
  br label %18

18:                                               ; preds = %10, %1
  %19 = load i64, ptr @v1, align 8, !tbaa !14
  %20 = icmp ne i64 %19, 0
  br i1 %20, label %21, label %67

21:                                               ; preds = %18
  call void @llvm.lifetime.start.p0(ptr %4) #4
  call void @llvm.lifetime.start.p0(ptr %5) #4
  %22 = load i64, ptr @v1, align 8, !tbaa !14
  %23 = inttoptr i64 %22 to ptr
  store ptr %23, ptr %5, align 8, !tbaa !10
  %24 = load ptr, ptr %5, align 8, !tbaa !10
  %25 = getelementptr inbounds nuw %struct.packet, ptr %24, i32 0, i32 3
  %26 = load i32, ptr %25, align 8, !tbaa !34
  store i32 %26, ptr %4, align 4, !tbaa !9
  %27 = load i32, ptr %4, align 4, !tbaa !9
  %28 = icmp sgt i32 %27, 3
  br i1 %28, label %29, label %37

29:                                               ; preds = %21
  %30 = load i64, ptr @v1, align 8, !tbaa !14
  %31 = inttoptr i64 %30 to ptr
  %32 = getelementptr inbounds nuw %struct.packet, ptr %31, i32 0, i32 0
  %33 = load ptr, ptr %32, align 8, !tbaa !30
  %34 = ptrtoint ptr %33 to i64
  store i64 %34, ptr @v1, align 8, !tbaa !14
  %35 = load ptr, ptr %5, align 8, !tbaa !10
  %36 = call ptr @qpkt(ptr noundef %35)
  store ptr %36, ptr %2, align 8
  store i32 1, ptr %6, align 4
  br label %64

37:                                               ; preds = %21
  %38 = load i64, ptr @v2, align 8, !tbaa !14
  %39 = icmp ne i64 %38, 0
  br i1 %39, label %40, label %63

40:                                               ; preds = %37
  call void @llvm.lifetime.start.p0(ptr %7) #4
  %41 = load i64, ptr @v2, align 8, !tbaa !14
  %42 = inttoptr i64 %41 to ptr
  store ptr %42, ptr %7, align 8, !tbaa !10
  %43 = load i64, ptr @v2, align 8, !tbaa !14
  %44 = inttoptr i64 %43 to ptr
  %45 = getelementptr inbounds nuw %struct.packet, ptr %44, i32 0, i32 0
  %46 = load ptr, ptr %45, align 8, !tbaa !30
  %47 = ptrtoint ptr %46 to i64
  store i64 %47, ptr @v2, align 8, !tbaa !14
  %48 = load ptr, ptr %5, align 8, !tbaa !10
  %49 = getelementptr inbounds nuw %struct.packet, ptr %48, i32 0, i32 4
  %50 = load i32, ptr %4, align 4, !tbaa !9
  %51 = sext i32 %50 to i64
  %52 = getelementptr inbounds [4 x i8], ptr %49, i64 0, i64 %51
  %53 = load i8, ptr %52, align 1, !tbaa !27
  %54 = sext i8 %53 to i32
  %55 = load ptr, ptr %7, align 8, !tbaa !10
  %56 = getelementptr inbounds nuw %struct.packet, ptr %55, i32 0, i32 3
  store i32 %54, ptr %56, align 8, !tbaa !34
  %57 = load i32, ptr %4, align 4, !tbaa !9
  %58 = add nsw i32 %57, 1
  %59 = load ptr, ptr %5, align 8, !tbaa !10
  %60 = getelementptr inbounds nuw %struct.packet, ptr %59, i32 0, i32 3
  store i32 %58, ptr %60, align 8, !tbaa !34
  %61 = load ptr, ptr %7, align 8, !tbaa !10
  %62 = call ptr @qpkt(ptr noundef %61)
  store ptr %62, ptr %2, align 8
  store i32 1, ptr %6, align 4
  call void @llvm.lifetime.end.p0(ptr %7) #4
  br label %64

63:                                               ; preds = %37
  store i32 0, ptr %6, align 4
  br label %64

64:                                               ; preds = %63, %40, %29
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  %65 = load i32, ptr %6, align 4
  switch i32 %65, label %71 [
    i32 0, label %66
    i32 1, label %69
  ]

66:                                               ; preds = %64
  br label %67

67:                                               ; preds = %66, %18
  %68 = call ptr @Wait()
  store ptr %68, ptr %2, align 8
  br label %69

69:                                               ; preds = %67, %64
  %70 = load ptr, ptr %2, align 8
  ret ptr %70

71:                                               ; preds = %64
  unreachable
}

; Function Attrs: nounwind uwtable
define dso_local ptr @devfn(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !10
  %4 = load ptr, ptr %3, align 8, !tbaa !10
  %5 = icmp eq ptr %4, null
  br i1 %5, label %6, label %16

6:                                                ; preds = %1
  %7 = load i64, ptr @v1, align 8, !tbaa !14
  %8 = icmp eq i64 %7, 0
  br i1 %8, label %9, label %11

9:                                                ; preds = %6
  %10 = call ptr @Wait()
  store ptr %10, ptr %2, align 8
  br label %28

11:                                               ; preds = %6
  %12 = load i64, ptr @v1, align 8, !tbaa !14
  %13 = inttoptr i64 %12 to ptr
  store ptr %13, ptr %3, align 8, !tbaa !10
  store i64 0, ptr @v1, align 8, !tbaa !14
  %14 = load ptr, ptr %3, align 8, !tbaa !10
  %15 = call ptr @qpkt(ptr noundef %14)
  store ptr %15, ptr %2, align 8
  br label %28

16:                                               ; preds = %1
  %17 = load ptr, ptr %3, align 8, !tbaa !10
  %18 = ptrtoint ptr %17 to i64
  store i64 %18, ptr @v1, align 8, !tbaa !14
  %19 = load i32, ptr @tracing, align 4, !tbaa !9
  %20 = icmp eq i32 %19, 1
  br i1 %20, label %21, label %26

21:                                               ; preds = %16
  %22 = load ptr, ptr %3, align 8, !tbaa !10
  %23 = getelementptr inbounds nuw %struct.packet, ptr %22, i32 0, i32 3
  %24 = load i32, ptr %23, align 8, !tbaa !34
  %25 = trunc i32 %24 to i8
  call void @trace(i8 noundef signext %25)
  br label %26

26:                                               ; preds = %21, %16
  %27 = call ptr @holdself()
  store ptr %27, ptr %2, align 8
  br label %28

28:                                               ; preds = %26, %11, %9
  %29 = load ptr, ptr %2, align 8
  ret ptr %29
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store ptr null, ptr %2, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str.3)
  %5 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 1, i32 noundef 0, ptr noundef %5, i32 noundef 0, ptr noundef @idlefn, i64 noundef 1, i64 noundef 10000000)
  %6 = call ptr @pkt(ptr noundef null, i32 noundef 0, i32 noundef 1001)
  store ptr %6, ptr %2, align 8, !tbaa !10
  %7 = load ptr, ptr %2, align 8, !tbaa !10
  %8 = call ptr @pkt(ptr noundef %7, i32 noundef 0, i32 noundef 1001)
  store ptr %8, ptr %2, align 8, !tbaa !10
  %9 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 2, i32 noundef 1000, ptr noundef %9, i32 noundef 3, ptr noundef @workfn, i64 noundef 3, i64 noundef 0)
  %10 = call ptr @pkt(ptr noundef null, i32 noundef 5, i32 noundef 1000)
  store ptr %10, ptr %2, align 8, !tbaa !10
  %11 = load ptr, ptr %2, align 8, !tbaa !10
  %12 = call ptr @pkt(ptr noundef %11, i32 noundef 5, i32 noundef 1000)
  store ptr %12, ptr %2, align 8, !tbaa !10
  %13 = load ptr, ptr %2, align 8, !tbaa !10
  %14 = call ptr @pkt(ptr noundef %13, i32 noundef 5, i32 noundef 1000)
  store ptr %14, ptr %2, align 8, !tbaa !10
  %15 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 3, i32 noundef 2000, ptr noundef %15, i32 noundef 3, ptr noundef @handlerfn, i64 noundef 0, i64 noundef 0)
  %16 = call ptr @pkt(ptr noundef null, i32 noundef 6, i32 noundef 1000)
  store ptr %16, ptr %2, align 8, !tbaa !10
  %17 = load ptr, ptr %2, align 8, !tbaa !10
  %18 = call ptr @pkt(ptr noundef %17, i32 noundef 6, i32 noundef 1000)
  store ptr %18, ptr %2, align 8, !tbaa !10
  %19 = load ptr, ptr %2, align 8, !tbaa !10
  %20 = call ptr @pkt(ptr noundef %19, i32 noundef 6, i32 noundef 1000)
  store ptr %20, ptr %2, align 8, !tbaa !10
  %21 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 4, i32 noundef 3000, ptr noundef %21, i32 noundef 3, ptr noundef @handlerfn, i64 noundef 0, i64 noundef 0)
  store ptr null, ptr %2, align 8, !tbaa !10
  %22 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 5, i32 noundef 4000, ptr noundef %22, i32 noundef 2, ptr noundef @devfn, i64 noundef 0, i64 noundef 0)
  %23 = load ptr, ptr %2, align 8, !tbaa !10
  call void @createtask(i32 noundef 6, i32 noundef 5000, ptr noundef %23, i32 noundef 2, ptr noundef @devfn, i64 noundef 0, i64 noundef 0)
  %24 = load ptr, ptr @tasklist, align 8, !tbaa !16
  store ptr %24, ptr @tcb, align 8, !tbaa !16
  store i32 0, ptr @holdcount, align 4, !tbaa !9
  store i32 0, ptr @qpktcount, align 4, !tbaa !9
  %25 = call i32 (ptr, ...) @printf(ptr noundef @.str.4)
  store i32 0, ptr @tracing, align 4, !tbaa !9
  store i32 0, ptr @layout, align 4, !tbaa !9
  call void @schedule()
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.5)
  %27 = load i32, ptr @qpktcount, align 4, !tbaa !9
  %28 = load i32, ptr @holdcount, align 4, !tbaa !9
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %27, i32 noundef %28)
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.7)
  %31 = load i32, ptr @qpktcount, align 4, !tbaa !9
  %32 = icmp eq i32 %31, 23263894
  br i1 %32, label %33, label %38

33:                                               ; preds = %0
  %34 = load i32, ptr @holdcount, align 4, !tbaa !9
  %35 = icmp eq i32 %34, 9305557
  br i1 %35, label %36, label %38

36:                                               ; preds = %33
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str.8)
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %40

38:                                               ; preds = %33, %0
  %39 = call i32 (ptr, ...) @printf(ptr noundef @.str.9)
  store i32 1, ptr %3, align 4, !tbaa !9
  br label %40

40:                                               ; preds = %38, %36
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.10)
  %42 = load i32, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 %42
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }
attributes #5 = { nounwind allocsize(0) }

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
!11 = !{!"p1 _ZTS6packet", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!12, !12, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"long", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"p1 _ZTS4task", !12, i64 0}
!18 = !{!19, !17, i64 0}
!19 = !{!"task", !17, i64 0, !6, i64 8, !6, i64 12, !11, i64 16, !6, i64 24, !12, i64 32, !15, i64 40, !15, i64 48}
!20 = !{!19, !6, i64 8}
!21 = !{!19, !6, i64 12}
!22 = !{!19, !11, i64 16}
!23 = !{!19, !6, i64 24}
!24 = !{!19, !12, i64 32}
!25 = !{!19, !15, i64 40}
!26 = !{!19, !15, i64 48}
!27 = !{!7, !7, i64 0}
!28 = distinct !{!28, !29}
!29 = !{!"llvm.loop.mustprogress"}
!30 = !{!31, !11, i64 0}
!31 = !{!"packet", !11, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !7, i64 20}
!32 = !{!31, !6, i64 8}
!33 = !{!31, !6, i64 12}
!34 = !{!31, !6, i64 16}
!35 = distinct !{!35, !29}
!36 = distinct !{!36, !29}
!37 = distinct !{!37, !29}
