; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Bubblesort.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Bubblesort.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Bubblesort.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@biggest = dso_local local_unnamed_addr global i32 0, align 4
@littlest = dso_local local_unnamed_addr global i32 0, align 4
@sortlist = dso_local local_unnamed_addr global [5001 x i32] zeroinitializer, align 16
@top = dso_local local_unnamed_addr global i32 0, align 4
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
@z = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@w = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@e = dso_local local_unnamed_addr global [130 x %struct.complex] zeroinitializer, align 16
@zr = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@zi = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@str = private unnamed_addr constant [18 x i8] c"Error3 in Bubble.\00", align 1

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

; Function Attrs: nofree norecurse nosync nounwind memory(write, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @bInitarr() local_unnamed_addr #2 {
  store i32 0, ptr @biggest, align 4, !tbaa !11
  store i32 0, ptr @littlest, align 4, !tbaa !11
  br label %1

1:                                                ; preds = %0, %19
  %2 = phi i64 [ 1, %0 ], [ %22, %19 ]
  %3 = phi i64 [ 74755, %0 ], [ %8, %19 ]
  %4 = phi i32 [ 0, %0 ], [ %21, %19 ]
  %5 = phi i32 [ 0, %0 ], [ %20, %19 ]
  %6 = mul nuw nsw i64 %3, 1309
  %7 = add nuw nsw i64 %6, 13849
  %8 = and i64 %7, 65535
  %9 = trunc nuw nsw i64 %8 to i32
  %10 = add nsw i32 %9, -50000
  %11 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %2
  store i32 %10, ptr %11, align 4, !tbaa !11
  %12 = icmp sgt i32 %10, %4
  br i1 %12, label %15, label %13

13:                                               ; preds = %1
  %14 = icmp slt i32 %10, %5
  br i1 %14, label %15, label %19

15:                                               ; preds = %13, %1
  %16 = phi ptr [ @biggest, %1 ], [ @littlest, %13 ]
  %17 = phi i32 [ %5, %1 ], [ %10, %13 ]
  %18 = phi i32 [ %10, %1 ], [ %4, %13 ]
  store i32 %10, ptr %16, align 4, !tbaa !11
  br label %19

19:                                               ; preds = %15, %13
  %20 = phi i32 [ %5, %13 ], [ %17, %15 ]
  %21 = phi i32 [ %4, %13 ], [ %18, %15 ]
  %22 = add nuw nsw i64 %2, 1
  %23 = icmp eq i64 %22, 501
  br i1 %23, label %24, label %1, !llvm.loop !12

24:                                               ; preds = %19
  store i64 %8, ptr @seed, align 8, !tbaa !9
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Bubble(i32 noundef %0) local_unnamed_addr #3 {
  store i32 0, ptr @biggest, align 4, !tbaa !11
  store i32 0, ptr @littlest, align 4, !tbaa !11
  br label %2

2:                                                ; preds = %20, %1
  %3 = phi i64 [ 1, %1 ], [ %23, %20 ]
  %4 = phi i64 [ 74755, %1 ], [ %9, %20 ]
  %5 = phi i32 [ 0, %1 ], [ %22, %20 ]
  %6 = phi i32 [ 0, %1 ], [ %21, %20 ]
  %7 = mul nuw nsw i64 %4, 1309
  %8 = add nuw nsw i64 %7, 13849
  %9 = and i64 %8, 65535
  %10 = trunc nuw nsw i64 %9 to i32
  %11 = add nsw i32 %10, -50000
  %12 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %3
  store i32 %11, ptr %12, align 4, !tbaa !11
  %13 = icmp sgt i32 %11, %5
  br i1 %13, label %16, label %14

14:                                               ; preds = %2
  %15 = icmp slt i32 %11, %6
  br i1 %15, label %16, label %20

16:                                               ; preds = %14, %2
  %17 = phi ptr [ @biggest, %2 ], [ @littlest, %14 ]
  %18 = phi i32 [ %6, %2 ], [ %11, %14 ]
  %19 = phi i32 [ %11, %2 ], [ %5, %14 ]
  store i32 %11, ptr %17, align 4, !tbaa !11
  br label %20

20:                                               ; preds = %16, %14
  %21 = phi i32 [ %6, %14 ], [ %18, %16 ]
  %22 = phi i32 [ %5, %14 ], [ %19, %16 ]
  %23 = add nuw nsw i64 %3, 1
  %24 = icmp eq i64 %23, 501
  br i1 %24, label %25, label %2, !llvm.loop !12

25:                                               ; preds = %20
  store i64 %9, ptr @seed, align 8, !tbaa !9
  br label %26

26:                                               ; preds = %25, %69
  %27 = phi i64 [ 0, %25 ], [ %72, %69 ]
  %28 = phi i64 [ 500, %25 ], [ %70, %69 ]
  %29 = sub i64 499, %27
  %30 = load i32, ptr getelementptr inbounds nuw (i8, ptr @sortlist, i64 4), align 4, !tbaa !11
  %31 = and i64 %29, 1
  %32 = icmp eq i64 %27, 498
  br i1 %32, label %59, label %33

33:                                               ; preds = %26
  %34 = and i64 %29, -2
  br label %35

35:                                               ; preds = %53, %33
  %36 = phi i32 [ %30, %33 ], [ %54, %53 ]
  %37 = phi i64 [ 1, %33 ], [ %47, %53 ]
  %38 = phi i64 [ 0, %33 ], [ %55, %53 ]
  %39 = add nuw nsw i64 %37, 1
  %40 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %39
  %41 = load i32, ptr %40, align 4, !tbaa !11
  %42 = icmp sgt i32 %36, %41
  br i1 %42, label %43, label %45

43:                                               ; preds = %35
  %44 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %37
  store i32 %41, ptr %44, align 4, !tbaa !11
  store i32 %36, ptr %40, align 4, !tbaa !11
  br label %45

45:                                               ; preds = %43, %35
  %46 = phi i32 [ %36, %43 ], [ %41, %35 ]
  %47 = add nuw nsw i64 %37, 2
  %48 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %47
  %49 = load i32, ptr %48, align 4, !tbaa !11
  %50 = icmp sgt i32 %46, %49
  br i1 %50, label %51, label %53

51:                                               ; preds = %45
  %52 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %39
  store i32 %49, ptr %52, align 4, !tbaa !11
  store i32 %46, ptr %48, align 4, !tbaa !11
  br label %53

53:                                               ; preds = %51, %45
  %54 = phi i32 [ %46, %51 ], [ %49, %45 ]
  %55 = add nuw i64 %38, 2
  %56 = icmp eq i64 %55, %34
  br i1 %56, label %57, label %35, !llvm.loop !14

57:                                               ; preds = %53
  %58 = icmp eq i64 %31, 0
  br i1 %58, label %69, label %59

59:                                               ; preds = %57, %26
  %60 = phi i32 [ %30, %26 ], [ %54, %57 ]
  %61 = phi i64 [ 1, %26 ], [ %47, %57 ]
  %62 = trunc i64 %29 to i1
  tail call void @llvm.assume(i1 %62)
  %63 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %61
  %64 = getelementptr inbounds nuw i8, ptr %63, i64 4
  %65 = load i32, ptr %64, align 4, !tbaa !11
  %66 = icmp sgt i32 %60, %65
  br i1 %66, label %67, label %69

67:                                               ; preds = %59
  %68 = getelementptr inbounds nuw [4 x i8], ptr @sortlist, i64 %61
  store i32 %65, ptr %68, align 4, !tbaa !11
  store i32 %60, ptr %64, align 4, !tbaa !11
  br label %69

69:                                               ; preds = %59, %67, %57
  %70 = add nsw i64 %28, -1
  %71 = icmp samesign ugt i64 %28, 2
  %72 = add i64 %27, 1
  br i1 %71, label %26, label %73, !llvm.loop !15

73:                                               ; preds = %69
  store i32 1, ptr @top, align 4, !tbaa !11
  %74 = load i32, ptr getelementptr inbounds nuw (i8, ptr @sortlist, i64 4), align 4, !tbaa !11
  %75 = load i32, ptr @littlest, align 4, !tbaa !11
  %76 = icmp eq i32 %74, %75
  br i1 %76, label %77, label %81

77:                                               ; preds = %73
  %78 = load i32, ptr getelementptr inbounds nuw (i8, ptr @sortlist, i64 2000), align 16, !tbaa !11
  %79 = load i32, ptr @biggest, align 4, !tbaa !11
  %80 = icmp eq i32 %78, %79
  br i1 %80, label %83, label %81

81:                                               ; preds = %77, %73
  %82 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  br label %83

83:                                               ; preds = %81, %77
  %84 = sext i32 %0 to i64
  %85 = getelementptr [4 x i8], ptr @sortlist, i64 %84
  %86 = getelementptr i8, ptr %85, i64 4
  %87 = load i32, ptr %86, align 4, !tbaa !11
  %88 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %87)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #3 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Bubble(i32 noundef %2)
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 100
  br i1 %4, label %5, label %1, !llvm.loop !16

5:                                                ; preds = %1
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #6

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(write, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind }
attributes #6 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }

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
