; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Queens.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Queens.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Queens.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@.str.1 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@value = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@fixed = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@floated = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@permarray = dso_local local_unnamed_addr global [11 x i32] zeroinitializer, align 16
@pctr = dso_local local_unnamed_addr global i32 0, align 4
@tree = dso_local local_unnamed_addr global ptr null, align 8
@stack = dso_local local_unnamed_addr global [4 x i32] zeroinitializer, align 16
@cellspace = dso_local local_unnamed_addr global [19 x %struct.element] zeroinitializer, align 16
@freelist = dso_local local_unnamed_addr global i32 0, align 4
@movesdone = dso_local local_unnamed_addr global i32 0, align 4
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
@str = private unnamed_addr constant [18 x i8] c" Error in Queens.\00", align 1

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

; Function Attrs: nofree nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @Try(i32 noundef %0, ptr nofree noundef captures(none) initializes((0, 4)) %1, ptr nofree noundef captures(none) %2, ptr nofree noundef captures(none) %3, ptr nofree noundef captures(none) %4, ptr nofree noundef writeonly captures(none) %5) local_unnamed_addr #2 {
  %7 = sext i32 %0 to i64
  %8 = getelementptr inbounds [4 x i8], ptr %5, i64 %7
  %9 = icmp slt i32 %0, 8
  %10 = add nsw i32 %0, 1
  %11 = getelementptr [4 x i8], ptr %2, i64 %7
  br label %12

12:                                               ; preds = %6, %37
  %13 = phi i64 [ 0, %6 ], [ %14, %37 ]
  %14 = add nuw nsw i64 %13, 1
  store i32 0, ptr %1, align 4, !tbaa !11
  %15 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %14
  %16 = load i32, ptr %15, align 4, !tbaa !11
  %17 = icmp eq i32 %16, 0
  br i1 %17, label %37, label %18

18:                                               ; preds = %12
  %19 = getelementptr [4 x i8], ptr %11, i64 %14
  %20 = load i32, ptr %19, align 4, !tbaa !11
  %21 = icmp eq i32 %20, 0
  br i1 %21, label %37, label %22

22:                                               ; preds = %18
  %23 = sub nsw i64 %7, %14
  %24 = getelementptr [4 x i8], ptr %4, i64 %23
  %25 = getelementptr i8, ptr %24, i64 28
  %26 = load i32, ptr %25, align 4, !tbaa !11
  %27 = icmp eq i32 %26, 0
  br i1 %27, label %37, label %28

28:                                               ; preds = %22
  %29 = trunc nuw nsw i64 %14 to i32
  store i32 %29, ptr %8, align 4, !tbaa !11
  store i32 0, ptr %15, align 4, !tbaa !11
  store i32 0, ptr %19, align 4, !tbaa !11
  store i32 0, ptr %25, align 4, !tbaa !11
  br i1 %9, label %30, label %36

30:                                               ; preds = %28
  tail call void @Try(i32 noundef %10, ptr noundef nonnull %1, ptr noundef nonnull %2, ptr noundef nonnull %3, ptr noundef nonnull %4, ptr noundef nonnull %5)
  %31 = load i32, ptr %1, align 4, !tbaa !11
  %32 = icmp eq i32 %31, 0
  br i1 %32, label %33, label %41

33:                                               ; preds = %30
  store i32 1, ptr %15, align 4, !tbaa !11
  store i32 1, ptr %19, align 4, !tbaa !11
  store i32 1, ptr %25, align 4, !tbaa !11
  %34 = load i32, ptr %1, align 4, !tbaa !11
  %35 = icmp eq i32 %34, 0
  br label %37

36:                                               ; preds = %28
  store i32 1, ptr %1, align 4, !tbaa !11
  br label %41

37:                                               ; preds = %33, %22, %18, %12
  %38 = phi i1 [ true, %18 ], [ %35, %33 ], [ true, %12 ], [ true, %22 ]
  %39 = icmp ne i64 %14, 8
  %40 = and i1 %39, %38
  br i1 %40, label %12, label %41, !llvm.loop !12

41:                                               ; preds = %30, %37, %36
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #3

; Function Attrs: nofree nounwind uwtable
define dso_local void @Doit() local_unnamed_addr #4 {
  %1 = alloca i32, align 4
  %2 = alloca [9 x i32], align 16
  %3 = alloca [17 x i32], align 16
  %4 = alloca [15 x i32], align 16
  %5 = alloca [9 x i32], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %5) #7
  br label %6

6:                                                ; preds = %0, %21
  %7 = phi i64 [ -7, %0 ], [ %22, %21 ]
  %8 = trunc i64 %7 to i32
  %9 = add i32 %8, -1
  %10 = icmp ult i32 %9, 8
  br i1 %10, label %11, label %13

11:                                               ; preds = %6
  %12 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %7
  store i32 1, ptr %12, align 4, !tbaa !11
  br label %13

13:                                               ; preds = %11, %6
  %14 = icmp sgt i64 %7, 1
  br i1 %14, label %15, label %18

15:                                               ; preds = %13
  %16 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %7
  store i32 1, ptr %16, align 4, !tbaa !11
  %17 = icmp samesign ult i64 %7, 8
  br i1 %17, label %18, label %21

18:                                               ; preds = %13, %15
  %19 = getelementptr [4 x i8], ptr %4, i64 %7
  %20 = getelementptr i8, ptr %19, i64 28
  store i32 1, ptr %20, align 4, !tbaa !11
  br label %21

21:                                               ; preds = %18, %15
  %22 = add nsw i64 %7, 1
  %23 = icmp eq i64 %22, 17
  br i1 %23, label %24, label %6, !llvm.loop !14

24:                                               ; preds = %21
  call void @Try(i32 noundef 1, ptr noundef nonnull %1, ptr noundef nonnull %3, ptr noundef nonnull %2, ptr noundef nonnull %4, ptr noundef nonnull %5)
  %25 = load i32, ptr %1, align 4, !tbaa !11
  %26 = icmp eq i32 %25, 0
  br i1 %26, label %27, label %29

27:                                               ; preds = %24
  %28 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  br label %29

29:                                               ; preds = %27, %24
  call void @llvm.lifetime.end.p0(ptr nonnull %5) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #7
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #5

; Function Attrs: nofree nounwind uwtable
define dso_local void @Queens(i32 noundef %0) local_unnamed_addr #4 {
  %2 = alloca i32, align 4
  %3 = alloca [9 x i32], align 16
  %4 = alloca [17 x i32], align 16
  %5 = alloca [15 x i32], align 16
  %6 = alloca [9 x i32], align 16
  br label %7

7:                                                ; preds = %1, %32
  %8 = phi i32 [ 1, %1 ], [ %33, %32 ]
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %5) #7
  call void @llvm.lifetime.start.p0(ptr nonnull %6) #7
  br label %9

9:                                                ; preds = %24, %7
  %10 = phi i64 [ -7, %7 ], [ %25, %24 ]
  %11 = trunc i64 %10 to i32
  %12 = add i32 %11, -1
  %13 = icmp ult i32 %12, 8
  br i1 %13, label %14, label %16

14:                                               ; preds = %9
  %15 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %10
  store i32 1, ptr %15, align 4, !tbaa !11
  br label %16

16:                                               ; preds = %14, %9
  %17 = icmp sgt i64 %10, 1
  br i1 %17, label %18, label %21

18:                                               ; preds = %16
  %19 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %10
  store i32 1, ptr %19, align 4, !tbaa !11
  %20 = icmp samesign ult i64 %10, 8
  br i1 %20, label %21, label %24

21:                                               ; preds = %18, %16
  %22 = getelementptr [4 x i8], ptr %5, i64 %10
  %23 = getelementptr i8, ptr %22, i64 28
  store i32 1, ptr %23, align 4, !tbaa !11
  br label %24

24:                                               ; preds = %21, %18
  %25 = add nsw i64 %10, 1
  %26 = icmp eq i64 %25, 17
  br i1 %26, label %27, label %9, !llvm.loop !14

27:                                               ; preds = %24
  call void @Try(i32 noundef 1, ptr noundef nonnull %2, ptr noundef nonnull %4, ptr noundef nonnull %3, ptr noundef nonnull %5, ptr noundef nonnull %6)
  %28 = load i32, ptr %2, align 4, !tbaa !11
  %29 = icmp eq i32 %28, 0
  br i1 %29, label %30, label %32

30:                                               ; preds = %27
  %31 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  br label %32

32:                                               ; preds = %27, %30
  call void @llvm.lifetime.end.p0(ptr nonnull %6) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %5) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #7
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #7
  %33 = add nuw nsw i32 %8, 1
  %34 = icmp eq i32 %33, 51
  br i1 %34, label %35, label %7, !llvm.loop !15

35:                                               ; preds = %32
  %36 = add nsw i32 %0, 1
  %37 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %36)
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #4 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Queens(i32 noundef %2)
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 100
  br i1 %4, label %5, label %1, !llvm.loop !16

5:                                                ; preds = %1
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #6

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind }
attributes #7 = { nounwind }

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
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = distinct !{!14, !13}
!15 = distinct !{!15, !13}
!16 = distinct !{!16, !13}
