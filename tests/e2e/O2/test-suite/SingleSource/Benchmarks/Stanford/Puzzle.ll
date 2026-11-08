; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Puzzle.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Puzzle.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Puzzle.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@piecemax = dso_local local_unnamed_addr global [13 x i32] zeroinitializer, align 16
@p = dso_local local_unnamed_addr global [13 x [512 x i32]] zeroinitializer, align 16
@puzzl = dso_local local_unnamed_addr global [512 x i32] zeroinitializer, align 16
@piececount = dso_local local_unnamed_addr global [4 x i32] zeroinitializer, align 16
@class = dso_local local_unnamed_addr global [13 x i32] zeroinitializer, align 16
@kount = dso_local local_unnamed_addr global i32 0, align 4
@n = dso_local local_unnamed_addr global i32 0, align 4
@.str.3 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
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
@sortlist = dso_local local_unnamed_addr global [5001 x i32] zeroinitializer, align 16
@biggest = dso_local local_unnamed_addr global i32 0, align 4
@littlest = dso_local local_unnamed_addr global i32 0, align 4
@top = dso_local local_unnamed_addr global i32 0, align 4
@z = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@w = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@e = dso_local local_unnamed_addr global [130 x %struct.complex] zeroinitializer, align 16
@zr = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@zi = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@str = private unnamed_addr constant [17 x i8] c"Error1 in Puzzle\00", align 1
@str.4 = private unnamed_addr constant [18 x i8] c"Error2 in Puzzle.\00", align 1
@str.5 = private unnamed_addr constant [18 x i8] c"Error3 in Puzzle.\00", align 1

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

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local range(i32 0, 2) i32 @Fit(i32 noundef %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = sext i32 %0 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @piecemax, i64 %3
  %5 = load i32, ptr %4, align 4, !tbaa !11
  %6 = icmp slt i32 %5, 0
  br i1 %6, label %25, label %7

7:                                                ; preds = %2
  %8 = getelementptr inbounds [2048 x i8], ptr @p, i64 %3
  %9 = sext i32 %1 to i64
  %10 = add nuw i32 %5, 1
  %11 = zext i32 %10 to i64
  %12 = getelementptr [4 x i8], ptr @puzzl, i64 %9
  br label %13

13:                                               ; preds = %7, %22
  %14 = phi i64 [ 0, %7 ], [ %23, %22 ]
  %15 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %14
  %16 = load i32, ptr %15, align 4, !tbaa !11
  %17 = icmp eq i32 %16, 0
  br i1 %17, label %22, label %18

18:                                               ; preds = %13
  %19 = getelementptr [4 x i8], ptr %12, i64 %14
  %20 = load i32, ptr %19, align 4, !tbaa !11
  %21 = icmp eq i32 %20, 0
  br i1 %21, label %22, label %25

22:                                               ; preds = %13, %18
  %23 = add nuw nsw i64 %14, 1
  %24 = icmp eq i64 %23, %11
  br i1 %24, label %25, label %13, !llvm.loop !12

25:                                               ; preds = %18, %22, %2
  %26 = phi i32 [ 1, %2 ], [ 1, %22 ], [ 0, %18 ]
  ret i32 %26
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local range(i32 -2147483648, 512) i32 @Place(i32 noundef %0, i32 noundef %1) local_unnamed_addr #3 {
  %3 = sext i32 %0 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @piecemax, i64 %3
  %5 = load i32, ptr %4, align 4, !tbaa !11
  %6 = icmp slt i32 %5, 0
  br i1 %6, label %79, label %7

7:                                                ; preds = %2
  %8 = getelementptr inbounds [2048 x i8], ptr @p, i64 %3
  %9 = sext i32 %1 to i64
  %10 = add nuw i32 %5, 1
  %11 = zext i32 %10 to i64
  %12 = getelementptr [4 x i8], ptr @puzzl, i64 %9
  %13 = icmp ult i32 %5, 7
  br i1 %13, label %67, label %14

14:                                               ; preds = %7
  %15 = and i64 %11, 4294967288
  br label %16

16:                                               ; preds = %62, %14
  %17 = phi i64 [ 0, %14 ], [ %63, %62 ]
  %18 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %17
  %19 = getelementptr inbounds nuw i8, ptr %18, i64 16
  %20 = load <4 x i32>, ptr %18, align 16, !tbaa !11
  %21 = load <4 x i32>, ptr %19, align 16, !tbaa !11
  %22 = icmp ne <4 x i32> %20, zeroinitializer
  %23 = icmp ne <4 x i32> %21, zeroinitializer
  %24 = extractelement <4 x i1> %22, i64 0
  br i1 %24, label %25, label %27

25:                                               ; preds = %16
  %26 = getelementptr [4 x i8], ptr %12, i64 %17
  store i32 1, ptr %26, align 4, !tbaa !11
  br label %27

27:                                               ; preds = %25, %16
  %28 = extractelement <4 x i1> %22, i64 1
  br i1 %28, label %29, label %32

29:                                               ; preds = %27
  %30 = getelementptr [4 x i8], ptr %12, i64 %17
  %31 = getelementptr i8, ptr %30, i64 4
  store i32 1, ptr %31, align 4, !tbaa !11
  br label %32

32:                                               ; preds = %29, %27
  %33 = extractelement <4 x i1> %22, i64 2
  br i1 %33, label %34, label %37

34:                                               ; preds = %32
  %35 = getelementptr [4 x i8], ptr %12, i64 %17
  %36 = getelementptr i8, ptr %35, i64 8
  store i32 1, ptr %36, align 4, !tbaa !11
  br label %37

37:                                               ; preds = %34, %32
  %38 = extractelement <4 x i1> %22, i64 3
  br i1 %38, label %39, label %42

39:                                               ; preds = %37
  %40 = getelementptr [4 x i8], ptr %12, i64 %17
  %41 = getelementptr i8, ptr %40, i64 12
  store i32 1, ptr %41, align 4, !tbaa !11
  br label %42

42:                                               ; preds = %39, %37
  %43 = extractelement <4 x i1> %23, i64 0
  br i1 %43, label %44, label %47

44:                                               ; preds = %42
  %45 = getelementptr [4 x i8], ptr %12, i64 %17
  %46 = getelementptr i8, ptr %45, i64 16
  store i32 1, ptr %46, align 4, !tbaa !11
  br label %47

47:                                               ; preds = %44, %42
  %48 = extractelement <4 x i1> %23, i64 1
  br i1 %48, label %49, label %52

49:                                               ; preds = %47
  %50 = getelementptr [4 x i8], ptr %12, i64 %17
  %51 = getelementptr i8, ptr %50, i64 20
  store i32 1, ptr %51, align 4, !tbaa !11
  br label %52

52:                                               ; preds = %49, %47
  %53 = extractelement <4 x i1> %23, i64 2
  br i1 %53, label %54, label %57

54:                                               ; preds = %52
  %55 = getelementptr [4 x i8], ptr %12, i64 %17
  %56 = getelementptr i8, ptr %55, i64 24
  store i32 1, ptr %56, align 4, !tbaa !11
  br label %57

57:                                               ; preds = %54, %52
  %58 = extractelement <4 x i1> %23, i64 3
  br i1 %58, label %59, label %62

59:                                               ; preds = %57
  %60 = getelementptr [4 x i8], ptr %12, i64 %17
  %61 = getelementptr i8, ptr %60, i64 28
  store i32 1, ptr %61, align 4, !tbaa !11
  br label %62

62:                                               ; preds = %59, %57
  %63 = add nuw i64 %17, 8
  %64 = icmp eq i64 %63, %15
  br i1 %64, label %65, label %16, !llvm.loop !14

65:                                               ; preds = %62
  %66 = icmp eq i64 %15, %11
  br i1 %66, label %79, label %67

67:                                               ; preds = %7, %65
  %68 = phi i64 [ 0, %7 ], [ %15, %65 ]
  br label %69

69:                                               ; preds = %67, %76
  %70 = phi i64 [ %77, %76 ], [ %68, %67 ]
  %71 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %70
  %72 = load i32, ptr %71, align 4, !tbaa !11
  %73 = icmp eq i32 %72, 0
  br i1 %73, label %76, label %74

74:                                               ; preds = %69
  %75 = getelementptr [4 x i8], ptr %12, i64 %70
  store i32 1, ptr %75, align 4, !tbaa !11
  br label %76

76:                                               ; preds = %69, %74
  %77 = add nuw nsw i64 %70, 1
  %78 = icmp eq i64 %77, %11
  br i1 %78, label %79, label %69, !llvm.loop !17

79:                                               ; preds = %76, %65, %2
  %80 = getelementptr inbounds [4 x i8], ptr @class, i64 %3
  %81 = load i32, ptr %80, align 4, !tbaa !11
  %82 = sext i32 %81 to i64
  %83 = getelementptr inbounds [4 x i8], ptr @piececount, i64 %82
  %84 = load i32, ptr %83, align 4, !tbaa !11
  %85 = add nsw i32 %84, -1
  store i32 %85, ptr %83, align 4, !tbaa !11
  %86 = icmp slt i32 %1, 512
  br i1 %86, label %87, label %100

87:                                               ; preds = %79
  %88 = sext i32 %1 to i64
  br label %89

89:                                               ; preds = %87, %94
  %90 = phi i64 [ %88, %87 ], [ %95, %94 ]
  %91 = getelementptr inbounds [4 x i8], ptr @puzzl, i64 %90
  %92 = load i32, ptr %91, align 4, !tbaa !11
  %93 = icmp eq i32 %92, 0
  br i1 %93, label %98, label %94

94:                                               ; preds = %89
  %95 = add nsw i64 %90, 1
  %96 = and i64 %95, 4294967295
  %97 = icmp eq i64 %96, 512
  br i1 %97, label %100, label %89, !llvm.loop !18

98:                                               ; preds = %89
  %99 = trunc nsw i64 %90 to i32
  br label %100

100:                                              ; preds = %94, %98, %79
  %101 = phi i32 [ 0, %79 ], [ %99, %98 ], [ 0, %94 ]
  ret i32 %101
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Remove(i32 noundef %0, i32 noundef %1) local_unnamed_addr #3 {
  %3 = sext i32 %0 to i64
  %4 = getelementptr inbounds [4 x i8], ptr @piecemax, i64 %3
  %5 = load i32, ptr %4, align 4, !tbaa !11
  %6 = icmp slt i32 %5, 0
  br i1 %6, label %79, label %7

7:                                                ; preds = %2
  %8 = getelementptr inbounds [2048 x i8], ptr @p, i64 %3
  %9 = sext i32 %1 to i64
  %10 = add nuw i32 %5, 1
  %11 = zext i32 %10 to i64
  %12 = getelementptr [4 x i8], ptr @puzzl, i64 %9
  %13 = icmp ult i32 %5, 7
  br i1 %13, label %67, label %14

14:                                               ; preds = %7
  %15 = and i64 %11, 4294967288
  br label %16

16:                                               ; preds = %62, %14
  %17 = phi i64 [ 0, %14 ], [ %63, %62 ]
  %18 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %17
  %19 = getelementptr inbounds nuw i8, ptr %18, i64 16
  %20 = load <4 x i32>, ptr %18, align 16, !tbaa !11
  %21 = load <4 x i32>, ptr %19, align 16, !tbaa !11
  %22 = icmp ne <4 x i32> %20, zeroinitializer
  %23 = icmp ne <4 x i32> %21, zeroinitializer
  %24 = extractelement <4 x i1> %22, i64 0
  br i1 %24, label %25, label %27

25:                                               ; preds = %16
  %26 = getelementptr [4 x i8], ptr %12, i64 %17
  store i32 0, ptr %26, align 4, !tbaa !11
  br label %27

27:                                               ; preds = %25, %16
  %28 = extractelement <4 x i1> %22, i64 1
  br i1 %28, label %29, label %32

29:                                               ; preds = %27
  %30 = getelementptr [4 x i8], ptr %12, i64 %17
  %31 = getelementptr i8, ptr %30, i64 4
  store i32 0, ptr %31, align 4, !tbaa !11
  br label %32

32:                                               ; preds = %29, %27
  %33 = extractelement <4 x i1> %22, i64 2
  br i1 %33, label %34, label %37

34:                                               ; preds = %32
  %35 = getelementptr [4 x i8], ptr %12, i64 %17
  %36 = getelementptr i8, ptr %35, i64 8
  store i32 0, ptr %36, align 4, !tbaa !11
  br label %37

37:                                               ; preds = %34, %32
  %38 = extractelement <4 x i1> %22, i64 3
  br i1 %38, label %39, label %42

39:                                               ; preds = %37
  %40 = getelementptr [4 x i8], ptr %12, i64 %17
  %41 = getelementptr i8, ptr %40, i64 12
  store i32 0, ptr %41, align 4, !tbaa !11
  br label %42

42:                                               ; preds = %39, %37
  %43 = extractelement <4 x i1> %23, i64 0
  br i1 %43, label %44, label %47

44:                                               ; preds = %42
  %45 = getelementptr [4 x i8], ptr %12, i64 %17
  %46 = getelementptr i8, ptr %45, i64 16
  store i32 0, ptr %46, align 4, !tbaa !11
  br label %47

47:                                               ; preds = %44, %42
  %48 = extractelement <4 x i1> %23, i64 1
  br i1 %48, label %49, label %52

49:                                               ; preds = %47
  %50 = getelementptr [4 x i8], ptr %12, i64 %17
  %51 = getelementptr i8, ptr %50, i64 20
  store i32 0, ptr %51, align 4, !tbaa !11
  br label %52

52:                                               ; preds = %49, %47
  %53 = extractelement <4 x i1> %23, i64 2
  br i1 %53, label %54, label %57

54:                                               ; preds = %52
  %55 = getelementptr [4 x i8], ptr %12, i64 %17
  %56 = getelementptr i8, ptr %55, i64 24
  store i32 0, ptr %56, align 4, !tbaa !11
  br label %57

57:                                               ; preds = %54, %52
  %58 = extractelement <4 x i1> %23, i64 3
  br i1 %58, label %59, label %62

59:                                               ; preds = %57
  %60 = getelementptr [4 x i8], ptr %12, i64 %17
  %61 = getelementptr i8, ptr %60, i64 28
  store i32 0, ptr %61, align 4, !tbaa !11
  br label %62

62:                                               ; preds = %59, %57
  %63 = add nuw i64 %17, 8
  %64 = icmp eq i64 %63, %15
  br i1 %64, label %65, label %16, !llvm.loop !19

65:                                               ; preds = %62
  %66 = icmp eq i64 %15, %11
  br i1 %66, label %79, label %67

67:                                               ; preds = %7, %65
  %68 = phi i64 [ 0, %7 ], [ %15, %65 ]
  br label %69

69:                                               ; preds = %67, %76
  %70 = phi i64 [ %77, %76 ], [ %68, %67 ]
  %71 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %70
  %72 = load i32, ptr %71, align 4, !tbaa !11
  %73 = icmp eq i32 %72, 0
  br i1 %73, label %76, label %74

74:                                               ; preds = %69
  %75 = getelementptr [4 x i8], ptr %12, i64 %70
  store i32 0, ptr %75, align 4, !tbaa !11
  br label %76

76:                                               ; preds = %69, %74
  %77 = add nuw nsw i64 %70, 1
  %78 = icmp eq i64 %77, %11
  br i1 %78, label %79, label %69, !llvm.loop !20

79:                                               ; preds = %76, %65, %2
  %80 = getelementptr inbounds [4 x i8], ptr @class, i64 %3
  %81 = load i32, ptr %80, align 4, !tbaa !11
  %82 = sext i32 %81 to i64
  %83 = getelementptr inbounds [4 x i8], ptr @piececount, i64 %82
  %84 = load i32, ptr %83, align 4, !tbaa !11
  %85 = add nsw i32 %84, 1
  store i32 %85, ptr %83, align 4, !tbaa !11
  ret void
}

; Function Attrs: nofree nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local range(i32 0, 2) i32 @Trial(i32 noundef %0) local_unnamed_addr #4 {
  %2 = load i32, ptr @kount, align 4, !tbaa !11
  %3 = add nsw i32 %2, 1
  store i32 %3, ptr @kount, align 4, !tbaa !11
  %4 = sext i32 %0 to i64
  %5 = getelementptr [4 x i8], ptr @puzzl, i64 %4
  %6 = icmp slt i32 %0, 512
  br label %7

7:                                                ; preds = %1, %200
  %8 = phi i64 [ 0, %1 ], [ %201, %200 ]
  %9 = getelementptr inbounds nuw [4 x i8], ptr @class, i64 %8
  %10 = load i32, ptr %9, align 4, !tbaa !11
  %11 = sext i32 %10 to i64
  %12 = getelementptr inbounds [4 x i8], ptr @piececount, i64 %11
  %13 = load i32, ptr %12, align 4, !tbaa !11
  %14 = icmp eq i32 %13, 0
  br i1 %14, label %200, label %15

15:                                               ; preds = %7
  %16 = getelementptr inbounds nuw [4 x i8], ptr @piecemax, i64 %8
  %17 = load i32, ptr %16, align 4, !tbaa !11
  %18 = icmp slt i32 %17, 0
  br i1 %18, label %102, label %19

19:                                               ; preds = %15
  %20 = getelementptr inbounds nuw [2048 x i8], ptr @p, i64 %8
  %21 = add nuw i32 %17, 1
  %22 = zext i32 %21 to i64
  br label %23

23:                                               ; preds = %32, %19
  %24 = phi i64 [ 0, %19 ], [ %33, %32 ]
  %25 = getelementptr inbounds nuw [4 x i8], ptr %20, i64 %24
  %26 = load i32, ptr %25, align 4, !tbaa !11
  %27 = icmp eq i32 %26, 0
  br i1 %27, label %32, label %28

28:                                               ; preds = %23
  %29 = getelementptr [4 x i8], ptr %5, i64 %24
  %30 = load i32, ptr %29, align 4, !tbaa !11
  %31 = icmp eq i32 %30, 0
  br i1 %31, label %32, label %200

32:                                               ; preds = %28, %23
  %33 = add nuw nsw i64 %24, 1
  %34 = icmp eq i64 %33, %22
  br i1 %34, label %35, label %23, !llvm.loop !12

35:                                               ; preds = %32
  %36 = icmp ult i32 %17, 7
  br i1 %36, label %90, label %37

37:                                               ; preds = %35
  %38 = and i64 %22, 4294967288
  br label %39

39:                                               ; preds = %85, %37
  %40 = phi i64 [ 0, %37 ], [ %86, %85 ]
  %41 = getelementptr inbounds nuw [4 x i8], ptr %20, i64 %40
  %42 = getelementptr inbounds nuw i8, ptr %41, i64 16
  %43 = load <4 x i32>, ptr %41, align 16, !tbaa !11
  %44 = load <4 x i32>, ptr %42, align 16, !tbaa !11
  %45 = icmp ne <4 x i32> %43, zeroinitializer
  %46 = icmp ne <4 x i32> %44, zeroinitializer
  %47 = extractelement <4 x i1> %45, i64 0
  br i1 %47, label %48, label %50

48:                                               ; preds = %39
  %49 = getelementptr [4 x i8], ptr %5, i64 %40
  store i32 1, ptr %49, align 4, !tbaa !11
  br label %50

50:                                               ; preds = %48, %39
  %51 = extractelement <4 x i1> %45, i64 1
  br i1 %51, label %52, label %55

52:                                               ; preds = %50
  %53 = getelementptr [4 x i8], ptr %5, i64 %40
  %54 = getelementptr i8, ptr %53, i64 4
  store i32 1, ptr %54, align 4, !tbaa !11
  br label %55

55:                                               ; preds = %52, %50
  %56 = extractelement <4 x i1> %45, i64 2
  br i1 %56, label %57, label %60

57:                                               ; preds = %55
  %58 = getelementptr [4 x i8], ptr %5, i64 %40
  %59 = getelementptr i8, ptr %58, i64 8
  store i32 1, ptr %59, align 4, !tbaa !11
  br label %60

60:                                               ; preds = %57, %55
  %61 = extractelement <4 x i1> %45, i64 3
  br i1 %61, label %62, label %65

62:                                               ; preds = %60
  %63 = getelementptr [4 x i8], ptr %5, i64 %40
  %64 = getelementptr i8, ptr %63, i64 12
  store i32 1, ptr %64, align 4, !tbaa !11
  br label %65

65:                                               ; preds = %62, %60
  %66 = extractelement <4 x i1> %46, i64 0
  br i1 %66, label %67, label %70

67:                                               ; preds = %65
  %68 = getelementptr [4 x i8], ptr %5, i64 %40
  %69 = getelementptr i8, ptr %68, i64 16
  store i32 1, ptr %69, align 4, !tbaa !11
  br label %70

70:                                               ; preds = %67, %65
  %71 = extractelement <4 x i1> %46, i64 1
  br i1 %71, label %72, label %75

72:                                               ; preds = %70
  %73 = getelementptr [4 x i8], ptr %5, i64 %40
  %74 = getelementptr i8, ptr %73, i64 20
  store i32 1, ptr %74, align 4, !tbaa !11
  br label %75

75:                                               ; preds = %72, %70
  %76 = extractelement <4 x i1> %46, i64 2
  br i1 %76, label %77, label %80

77:                                               ; preds = %75
  %78 = getelementptr [4 x i8], ptr %5, i64 %40
  %79 = getelementptr i8, ptr %78, i64 24
  store i32 1, ptr %79, align 4, !tbaa !11
  br label %80

80:                                               ; preds = %77, %75
  %81 = extractelement <4 x i1> %46, i64 3
  br i1 %81, label %82, label %85

82:                                               ; preds = %80
  %83 = getelementptr [4 x i8], ptr %5, i64 %40
  %84 = getelementptr i8, ptr %83, i64 28
  store i32 1, ptr %84, align 4, !tbaa !11
  br label %85

85:                                               ; preds = %82, %80
  %86 = add nuw i64 %40, 8
  %87 = icmp eq i64 %86, %38
  br i1 %87, label %88, label %39, !llvm.loop !21

88:                                               ; preds = %85
  %89 = icmp eq i64 %38, %22
  br i1 %89, label %102, label %90

90:                                               ; preds = %35, %88
  %91 = phi i64 [ 0, %35 ], [ %38, %88 ]
  br label %92

92:                                               ; preds = %90, %99
  %93 = phi i64 [ %100, %99 ], [ %91, %90 ]
  %94 = getelementptr inbounds nuw [4 x i8], ptr %20, i64 %93
  %95 = load i32, ptr %94, align 4, !tbaa !11
  %96 = icmp eq i32 %95, 0
  br i1 %96, label %99, label %97

97:                                               ; preds = %92
  %98 = getelementptr [4 x i8], ptr %5, i64 %93
  store i32 1, ptr %98, align 4, !tbaa !11
  br label %99

99:                                               ; preds = %97, %92
  %100 = add nuw nsw i64 %93, 1
  %101 = icmp eq i64 %100, %22
  br i1 %101, label %102, label %92, !llvm.loop !22

102:                                              ; preds = %99, %88, %15
  %103 = add nsw i32 %13, -1
  store i32 %103, ptr %12, align 4, !tbaa !11
  br i1 %6, label %104, label %115

104:                                              ; preds = %102, %109
  %105 = phi i64 [ %110, %109 ], [ %4, %102 ]
  %106 = getelementptr inbounds [4 x i8], ptr @puzzl, i64 %105
  %107 = load i32, ptr %106, align 4, !tbaa !11
  %108 = icmp eq i32 %107, 0
  br i1 %108, label %113, label %109

109:                                              ; preds = %104
  %110 = add nsw i64 %105, 1
  %111 = and i64 %110, 4294967295
  %112 = icmp eq i64 %111, 512
  br i1 %112, label %115, label %104, !llvm.loop !18

113:                                              ; preds = %104
  %114 = trunc nsw i64 %105 to i32
  br label %115

115:                                              ; preds = %109, %102, %113
  %116 = phi i32 [ 0, %102 ], [ %114, %113 ], [ 0, %109 ]
  %117 = tail call i32 @Trial(i32 noundef %116)
  %118 = icmp ne i32 %117, 0
  %119 = icmp eq i32 %116, 0
  %120 = or i1 %119, %118
  br i1 %120, label %203, label %121

121:                                              ; preds = %115
  %122 = load i32, ptr %16, align 4, !tbaa !11
  %123 = icmp slt i32 %122, 0
  br i1 %123, label %194, label %124

124:                                              ; preds = %121
  %125 = getelementptr inbounds nuw [2048 x i8], ptr @p, i64 %8
  %126 = add nuw i32 %122, 1
  %127 = zext i32 %126 to i64
  %128 = icmp ult i32 %122, 7
  br i1 %128, label %182, label %129

129:                                              ; preds = %124
  %130 = and i64 %127, 4294967288
  br label %131

131:                                              ; preds = %177, %129
  %132 = phi i64 [ 0, %129 ], [ %178, %177 ]
  %133 = getelementptr inbounds nuw [4 x i8], ptr %125, i64 %132
  %134 = getelementptr inbounds nuw i8, ptr %133, i64 16
  %135 = load <4 x i32>, ptr %133, align 16, !tbaa !11
  %136 = load <4 x i32>, ptr %134, align 16, !tbaa !11
  %137 = icmp ne <4 x i32> %135, zeroinitializer
  %138 = icmp ne <4 x i32> %136, zeroinitializer
  %139 = extractelement <4 x i1> %137, i64 0
  br i1 %139, label %140, label %142

140:                                              ; preds = %131
  %141 = getelementptr [4 x i8], ptr %5, i64 %132
  store i32 0, ptr %141, align 4, !tbaa !11
  br label %142

142:                                              ; preds = %140, %131
  %143 = extractelement <4 x i1> %137, i64 1
  br i1 %143, label %144, label %147

144:                                              ; preds = %142
  %145 = getelementptr [4 x i8], ptr %5, i64 %132
  %146 = getelementptr i8, ptr %145, i64 4
  store i32 0, ptr %146, align 4, !tbaa !11
  br label %147

147:                                              ; preds = %144, %142
  %148 = extractelement <4 x i1> %137, i64 2
  br i1 %148, label %149, label %152

149:                                              ; preds = %147
  %150 = getelementptr [4 x i8], ptr %5, i64 %132
  %151 = getelementptr i8, ptr %150, i64 8
  store i32 0, ptr %151, align 4, !tbaa !11
  br label %152

152:                                              ; preds = %149, %147
  %153 = extractelement <4 x i1> %137, i64 3
  br i1 %153, label %154, label %157

154:                                              ; preds = %152
  %155 = getelementptr [4 x i8], ptr %5, i64 %132
  %156 = getelementptr i8, ptr %155, i64 12
  store i32 0, ptr %156, align 4, !tbaa !11
  br label %157

157:                                              ; preds = %154, %152
  %158 = extractelement <4 x i1> %138, i64 0
  br i1 %158, label %159, label %162

159:                                              ; preds = %157
  %160 = getelementptr [4 x i8], ptr %5, i64 %132
  %161 = getelementptr i8, ptr %160, i64 16
  store i32 0, ptr %161, align 4, !tbaa !11
  br label %162

162:                                              ; preds = %159, %157
  %163 = extractelement <4 x i1> %138, i64 1
  br i1 %163, label %164, label %167

164:                                              ; preds = %162
  %165 = getelementptr [4 x i8], ptr %5, i64 %132
  %166 = getelementptr i8, ptr %165, i64 20
  store i32 0, ptr %166, align 4, !tbaa !11
  br label %167

167:                                              ; preds = %164, %162
  %168 = extractelement <4 x i1> %138, i64 2
  br i1 %168, label %169, label %172

169:                                              ; preds = %167
  %170 = getelementptr [4 x i8], ptr %5, i64 %132
  %171 = getelementptr i8, ptr %170, i64 24
  store i32 0, ptr %171, align 4, !tbaa !11
  br label %172

172:                                              ; preds = %169, %167
  %173 = extractelement <4 x i1> %138, i64 3
  br i1 %173, label %174, label %177

174:                                              ; preds = %172
  %175 = getelementptr [4 x i8], ptr %5, i64 %132
  %176 = getelementptr i8, ptr %175, i64 28
  store i32 0, ptr %176, align 4, !tbaa !11
  br label %177

177:                                              ; preds = %174, %172
  %178 = add nuw i64 %132, 8
  %179 = icmp eq i64 %178, %130
  br i1 %179, label %180, label %131, !llvm.loop !23

180:                                              ; preds = %177
  %181 = icmp eq i64 %130, %127
  br i1 %181, label %194, label %182

182:                                              ; preds = %124, %180
  %183 = phi i64 [ 0, %124 ], [ %130, %180 ]
  br label %184

184:                                              ; preds = %182, %191
  %185 = phi i64 [ %192, %191 ], [ %183, %182 ]
  %186 = getelementptr inbounds nuw [4 x i8], ptr %125, i64 %185
  %187 = load i32, ptr %186, align 4, !tbaa !11
  %188 = icmp eq i32 %187, 0
  br i1 %188, label %191, label %189

189:                                              ; preds = %184
  %190 = getelementptr [4 x i8], ptr %5, i64 %185
  store i32 0, ptr %190, align 4, !tbaa !11
  br label %191

191:                                              ; preds = %189, %184
  %192 = add nuw nsw i64 %185, 1
  %193 = icmp eq i64 %192, %127
  br i1 %193, label %194, label %184, !llvm.loop !24

194:                                              ; preds = %191, %180, %121
  %195 = load i32, ptr %9, align 4, !tbaa !11
  %196 = sext i32 %195 to i64
  %197 = getelementptr inbounds [4 x i8], ptr @piececount, i64 %196
  %198 = load i32, ptr %197, align 4, !tbaa !11
  %199 = add nsw i32 %198, 1
  store i32 %199, ptr %197, align 4, !tbaa !11
  br label %200

200:                                              ; preds = %28, %7, %194
  %201 = add nuw nsw i64 %8, 1
  %202 = icmp eq i64 %201, 13
  br i1 %202, label %203, label %7, !llvm.loop !25

203:                                              ; preds = %200, %115
  %204 = phi i32 [ 1, %115 ], [ 0, %200 ]
  ret i32 %204
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Puzzle() local_unnamed_addr #5 {
  br label %1

1:                                                ; preds = %1, %0
  %2 = phi i64 [ 0, %0 ], [ %14, %1 ]
  %3 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %2
  %4 = getelementptr inbounds nuw i8, ptr %3, i64 16
  store <4 x i32> splat (i32 1), ptr %3, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr %4, align 16, !tbaa !11
  %5 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %2
  %6 = getelementptr inbounds nuw i8, ptr %5, i64 32
  %7 = getelementptr inbounds nuw i8, ptr %5, i64 48
  store <4 x i32> splat (i32 1), ptr %6, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr %7, align 16, !tbaa !11
  %8 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %2
  %9 = getelementptr inbounds nuw i8, ptr %8, i64 64
  %10 = getelementptr inbounds nuw i8, ptr %8, i64 80
  store <4 x i32> splat (i32 1), ptr %9, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr %10, align 16, !tbaa !11
  %11 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %2
  %12 = getelementptr inbounds nuw i8, ptr %11, i64 96
  %13 = getelementptr inbounds nuw i8, ptr %11, i64 112
  store <4 x i32> splat (i32 1), ptr %12, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr %13, align 16, !tbaa !11
  %14 = add nuw nsw i64 %2, 32
  %15 = icmp eq i64 %14, 512
  br i1 %15, label %16, label %1, !llvm.loop !26

16:                                               ; preds = %1, %16
  %17 = phi i64 [ %68, %16 ], [ 1, %1 ]
  %18 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %19 = getelementptr inbounds nuw i8, ptr %18, i64 288
  store i32 0, ptr %19, align 4, !tbaa !11
  %20 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %21 = getelementptr inbounds nuw i8, ptr %20, i64 544
  store i32 0, ptr %21, align 4, !tbaa !11
  %22 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %23 = getelementptr inbounds nuw i8, ptr %22, i64 800
  store i32 0, ptr %23, align 4, !tbaa !11
  %24 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %25 = getelementptr inbounds nuw i8, ptr %24, i64 1056
  store i32 0, ptr %25, align 4, !tbaa !11
  %26 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 1312
  store i32 0, ptr %27, align 4, !tbaa !11
  %28 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %29 = getelementptr inbounds nuw i8, ptr %28, i64 320
  store i32 0, ptr %29, align 4, !tbaa !11
  %30 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 576
  store i32 0, ptr %31, align 4, !tbaa !11
  %32 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %33 = getelementptr inbounds nuw i8, ptr %32, i64 832
  store i32 0, ptr %33, align 4, !tbaa !11
  %34 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %35 = getelementptr inbounds nuw i8, ptr %34, i64 1088
  store i32 0, ptr %35, align 4, !tbaa !11
  %36 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %37 = getelementptr inbounds nuw i8, ptr %36, i64 1344
  store i32 0, ptr %37, align 4, !tbaa !11
  %38 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %39 = getelementptr inbounds nuw i8, ptr %38, i64 352
  store i32 0, ptr %39, align 4, !tbaa !11
  %40 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %41 = getelementptr inbounds nuw i8, ptr %40, i64 608
  store i32 0, ptr %41, align 4, !tbaa !11
  %42 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %43 = getelementptr inbounds nuw i8, ptr %42, i64 864
  store i32 0, ptr %43, align 4, !tbaa !11
  %44 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %45 = getelementptr inbounds nuw i8, ptr %44, i64 1120
  store i32 0, ptr %45, align 4, !tbaa !11
  %46 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %47 = getelementptr inbounds nuw i8, ptr %46, i64 1376
  store i32 0, ptr %47, align 4, !tbaa !11
  %48 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %49 = getelementptr inbounds nuw i8, ptr %48, i64 384
  store i32 0, ptr %49, align 4, !tbaa !11
  %50 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %51 = getelementptr inbounds nuw i8, ptr %50, i64 640
  store i32 0, ptr %51, align 4, !tbaa !11
  %52 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %53 = getelementptr inbounds nuw i8, ptr %52, i64 896
  store i32 0, ptr %53, align 4, !tbaa !11
  %54 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %55 = getelementptr inbounds nuw i8, ptr %54, i64 1152
  store i32 0, ptr %55, align 4, !tbaa !11
  %56 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %57 = getelementptr inbounds nuw i8, ptr %56, i64 1408
  store i32 0, ptr %57, align 4, !tbaa !11
  %58 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %59 = getelementptr inbounds nuw i8, ptr %58, i64 416
  store i32 0, ptr %59, align 4, !tbaa !11
  %60 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %61 = getelementptr inbounds nuw i8, ptr %60, i64 672
  store i32 0, ptr %61, align 4, !tbaa !11
  %62 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %63 = getelementptr inbounds nuw i8, ptr %62, i64 928
  store i32 0, ptr %63, align 4, !tbaa !11
  %64 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %65 = getelementptr inbounds nuw i8, ptr %64, i64 1184
  store i32 0, ptr %65, align 4, !tbaa !11
  %66 = getelementptr inbounds nuw [4 x i8], ptr @puzzl, i64 %17
  %67 = getelementptr inbounds nuw i8, ptr %66, i64 1440
  store i32 0, ptr %67, align 4, !tbaa !11
  %68 = add nuw nsw i64 %17, 1
  %69 = icmp eq i64 %68, 6
  br i1 %69, label %70, label %16, !llvm.loop !27

70:                                               ; preds = %16
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(26608) getelementptr inbounds nuw (i8, ptr @p, i64 16), i8 0, i64 26608, i1 false), !tbaa !11
  store <4 x i32> splat (i32 1), ptr @p, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr getelementptr inbounds nuw (i8, ptr @p, i64 32), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2048), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2304), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2560), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2816), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2052), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2308), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2564), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 2820), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4096), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4352), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4128), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4384), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4160), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4416), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4192), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4448), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6144), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6176), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6208), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6240), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6148), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6180), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6212), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 6244), align 4, !tbaa !11
  store <4 x i32> zeroinitializer, ptr @class, align 16, !tbaa !11
  store <4 x i32> <i32 11, i32 193, i32 88, i32 25>, ptr @piecemax, align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr getelementptr inbounds nuw (i8, ptr @p, i64 8192), align 16, !tbaa !11
  store <4 x i32> splat (i32 1), ptr getelementptr inbounds nuw (i8, ptr @p, i64 8448), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10240), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10496), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10752), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 11008), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10272), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10528), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 10784), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 11040), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 12288), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 12292), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 12296), align 8, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 14336), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 14368), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 14400), align 16, !tbaa !11
  store <4 x i32> <i32 0, i32 0, i32 1, i32 1>, ptr getelementptr inbounds nuw (i8, ptr @class, i64 16), align 16, !tbaa !11
  store <4 x i32> <i32 67, i32 200, i32 2, i32 16>, ptr getelementptr inbounds nuw (i8, ptr @piecemax, i64 16), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 16384), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 16640), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 16896), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 18432), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 18464), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 18436), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 18468), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 20480), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 20736), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 20484), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 20740), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 22528), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 22784), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 22560), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 22816), align 16, !tbaa !11
  store <4 x i32> <i32 1, i32 2, i32 2, i32 2>, ptr getelementptr inbounds nuw (i8, ptr @class, i64 32), align 16, !tbaa !11
  store <4 x i32> <i32 128, i32 9, i32 65, i32 72>, ptr getelementptr inbounds nuw (i8, ptr @piecemax, i64 32), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24576), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24832), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24608), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24864), align 16, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24580), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24836), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24612), align 4, !tbaa !11
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24868), align 4, !tbaa !11
  store i32 3, ptr getelementptr inbounds nuw (i8, ptr @class, i64 48), align 16, !tbaa !11
  store i32 73, ptr getelementptr inbounds nuw (i8, ptr @piecemax, i64 48), align 16, !tbaa !11
  store <4 x i32> <i32 13, i32 3, i32 1, i32 1>, ptr @piececount, align 16, !tbaa !11
  store i32 0, ptr @kount, align 4, !tbaa !11
  %71 = load i32, ptr @p, align 16, !tbaa !11
  %72 = icmp eq i32 %71, 0
  %73 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 292), align 4
  %74 = icmp eq i32 %73, 0
  %75 = select i1 %72, i1 true, i1 %74
  br i1 %75, label %76, label %209

76:                                               ; preds = %70
  %77 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 4), align 4, !tbaa !11
  %78 = icmp eq i32 %77, 0
  %79 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 296), align 8
  %80 = icmp eq i32 %79, 0
  %81 = select i1 %78, i1 true, i1 %80
  br i1 %81, label %82, label %209

82:                                               ; preds = %76
  %83 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 8), align 8, !tbaa !11
  %84 = icmp eq i32 %83, 0
  %85 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 300), align 4
  %86 = icmp eq i32 %85, 0
  %87 = select i1 %84, i1 true, i1 %86
  br i1 %87, label %88, label %209

88:                                               ; preds = %82
  %89 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 12), align 4, !tbaa !11
  %90 = icmp eq i32 %89, 0
  %91 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 304), align 16
  %92 = icmp eq i32 %91, 0
  %93 = select i1 %90, i1 true, i1 %92
  br i1 %93, label %94, label %209

94:                                               ; preds = %88
  %95 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 16), align 16, !tbaa !11
  %96 = icmp eq i32 %95, 0
  %97 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 308), align 4
  %98 = icmp eq i32 %97, 0
  %99 = select i1 %96, i1 true, i1 %98
  br i1 %99, label %100, label %209

100:                                              ; preds = %94
  %101 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 20), align 4, !tbaa !11
  %102 = icmp eq i32 %101, 0
  %103 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 312), align 8
  %104 = icmp eq i32 %103, 0
  %105 = select i1 %102, i1 true, i1 %104
  br i1 %105, label %106, label %209

106:                                              ; preds = %100
  %107 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 24), align 8, !tbaa !11
  %108 = icmp eq i32 %107, 0
  %109 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 316), align 4
  %110 = icmp eq i32 %109, 0
  %111 = select i1 %108, i1 true, i1 %110
  br i1 %111, label %112, label %209

112:                                              ; preds = %106
  %113 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 28), align 4, !tbaa !11
  %114 = icmp eq i32 %113, 0
  %115 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 320), align 16
  %116 = icmp eq i32 %115, 0
  %117 = select i1 %114, i1 true, i1 %116
  br i1 %117, label %118, label %209

118:                                              ; preds = %112
  %119 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 32), align 16, !tbaa !11
  %120 = icmp eq i32 %119, 0
  %121 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 324), align 4
  %122 = icmp eq i32 %121, 0
  %123 = select i1 %120, i1 true, i1 %122
  br i1 %123, label %124, label %209

124:                                              ; preds = %118
  %125 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 36), align 4, !tbaa !11
  %126 = icmp eq i32 %125, 0
  %127 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 328), align 8
  %128 = icmp eq i32 %127, 0
  %129 = select i1 %126, i1 true, i1 %128
  br i1 %129, label %130, label %209

130:                                              ; preds = %124
  %131 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 40), align 8, !tbaa !11
  %132 = icmp eq i32 %131, 0
  %133 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 332), align 4
  %134 = icmp eq i32 %133, 0
  %135 = select i1 %132, i1 true, i1 %134
  br i1 %135, label %136, label %209

136:                                              ; preds = %130
  %137 = load i32, ptr getelementptr inbounds nuw (i8, ptr @p, i64 44), align 4, !tbaa !11
  %138 = icmp eq i32 %137, 0
  %139 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 336), align 16
  %140 = icmp eq i32 %139, 0
  %141 = select i1 %138, i1 true, i1 %140
  br i1 %141, label %142, label %209

142:                                              ; preds = %136
  br i1 %72, label %144, label %143

143:                                              ; preds = %142
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 292), align 4, !tbaa !11
  br label %144

144:                                              ; preds = %143, %142
  br i1 %78, label %146, label %145

145:                                              ; preds = %144
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 296), align 8, !tbaa !11
  br label %146

146:                                              ; preds = %145, %144
  br i1 %84, label %148, label %147

147:                                              ; preds = %146
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 300), align 4, !tbaa !11
  br label %148

148:                                              ; preds = %147, %146
  br i1 %90, label %150, label %149

149:                                              ; preds = %148
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 304), align 16, !tbaa !11
  br label %150

150:                                              ; preds = %149, %148
  br i1 %96, label %152, label %151

151:                                              ; preds = %150
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 308), align 4, !tbaa !11
  br label %152

152:                                              ; preds = %151, %150
  br i1 %102, label %154, label %153

153:                                              ; preds = %152
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 312), align 8, !tbaa !11
  br label %154

154:                                              ; preds = %153, %152
  br i1 %108, label %156, label %155

155:                                              ; preds = %154
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 316), align 4, !tbaa !11
  br label %156

156:                                              ; preds = %155, %154
  br i1 %114, label %158, label %157

157:                                              ; preds = %156
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 320), align 16, !tbaa !11
  br label %158

158:                                              ; preds = %157, %156
  br i1 %120, label %160, label %159

159:                                              ; preds = %158
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 324), align 4, !tbaa !11
  br label %160

160:                                              ; preds = %159, %158
  br i1 %126, label %162, label %161

161:                                              ; preds = %160
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 328), align 8, !tbaa !11
  br label %162

162:                                              ; preds = %161, %160
  br i1 %132, label %164, label %163

163:                                              ; preds = %162
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 332), align 4, !tbaa !11
  br label %164

164:                                              ; preds = %163, %162
  br i1 %138, label %166, label %165

165:                                              ; preds = %164
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 336), align 16, !tbaa !11
  br label %166

166:                                              ; preds = %165, %164
  store i32 12, ptr @piececount, align 16, !tbaa !11
  br label %167

167:                                              ; preds = %187, %166
  %168 = phi i64 [ 0, %166 ], [ %188, %187 ]
  %169 = getelementptr [4 x i8], ptr @puzzl, i64 %168
  %170 = getelementptr i8, ptr %169, i64 292
  %171 = load <4 x i32>, ptr %170, align 4, !tbaa !11
  %172 = freeze <4 x i32> %171
  %173 = icmp eq <4 x i32> %172, zeroinitializer
  %174 = bitcast <4 x i1> %173 to i4
  %175 = icmp eq i4 %174, 0
  br i1 %175, label %176, label %189

176:                                              ; preds = %167
  %177 = icmp eq i64 %168, 432
  br i1 %177, label %195, label %178

178:                                              ; preds = %176
  %179 = or disjoint i64 %168, 4
  %180 = getelementptr [4 x i8], ptr @puzzl, i64 %179
  %181 = getelementptr i8, ptr %180, i64 292
  %182 = load <4 x i32>, ptr %181, align 4, !tbaa !11
  %183 = freeze <4 x i32> %182
  %184 = icmp eq <4 x i32> %183, zeroinitializer
  %185 = bitcast <4 x i1> %184 to i4
  %186 = icmp eq i4 %185, 0
  br i1 %186, label %187, label %189

187:                                              ; preds = %178
  %188 = add nuw nsw i64 %168, 8
  br label %167

189:                                              ; preds = %178, %167
  %190 = phi i64 [ %168, %167 ], [ %179, %178 ]
  %191 = phi <4 x i1> [ %173, %167 ], [ %184, %178 ]
  %192 = tail call i64 @llvm.experimental.cttz.elts.i64.v4i1(<4 x i1> %191, i1 false)
  %193 = add i64 %190, %192
  %194 = add i64 %193, 73
  br label %204

195:                                              ; preds = %176
  %196 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 2036), align 4, !tbaa !11
  %197 = icmp eq i32 %196, 0
  br i1 %197, label %204, label %198

198:                                              ; preds = %195
  %199 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 2040), align 8, !tbaa !11
  %200 = icmp eq i32 %199, 0
  br i1 %200, label %204, label %201

201:                                              ; preds = %198
  %202 = load i32, ptr getelementptr inbounds nuw (i8, ptr @puzzl, i64 2044), align 4, !tbaa !11
  %203 = icmp eq i32 %202, 0
  br i1 %203, label %204, label %207

204:                                              ; preds = %195, %198, %201, %189
  %205 = phi i64 [ %194, %189 ], [ 509, %195 ], [ 510, %198 ], [ 511, %201 ]
  %206 = trunc nsw i64 %205 to i32
  br label %207

207:                                              ; preds = %201, %204
  %208 = phi i32 [ %206, %204 ], [ 0, %201 ]
  store i32 %208, ptr @n, align 4, !tbaa !11
  br label %212

209:                                              ; preds = %136, %130, %124, %118, %112, %106, %100, %94, %88, %82, %76, %70
  %210 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %211 = load i32, ptr @n, align 4, !tbaa !11
  br label %212

212:                                              ; preds = %209, %207
  %213 = phi i32 [ %211, %209 ], [ %208, %207 ]
  %214 = tail call i32 @Trial(i32 noundef %213)
  %215 = icmp eq i32 %214, 0
  br i1 %215, label %219, label %216

216:                                              ; preds = %212
  %217 = load i32, ptr @kount, align 4, !tbaa !11
  %218 = icmp eq i32 %217, 2005
  br i1 %218, label %222, label %219

219:                                              ; preds = %216, %212
  %220 = phi ptr [ @str.4, %212 ], [ @str.5, %216 ]
  %221 = tail call i32 @puts(ptr nonnull dereferenceable(1) %220)
  br label %222

222:                                              ; preds = %219, %216
  %223 = load i32, ptr @n, align 4, !tbaa !11
  %224 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i32 noundef %223)
  %225 = load i32, ptr @kount, align 4, !tbaa !11
  %226 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i32 noundef %225)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #6

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #5 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Puzzle()
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 100
  br i1 %4, label %5, label %1, !llvm.loop !28

5:                                                ; preds = %1
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #7

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #8

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.experimental.cttz.elts.i64.v4i1(<4 x i1>, i1 immarg) #9

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(read, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree nounwind }
attributes #8 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #9 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }

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
!14 = distinct !{!14, !13, !15, !16}
!15 = !{!"llvm.loop.isvectorized", i32 1}
!16 = !{!"llvm.loop.unroll.runtime.disable"}
!17 = distinct !{!17, !13, !16, !15}
!18 = distinct !{!18, !13}
!19 = distinct !{!19, !13, !15, !16}
!20 = distinct !{!20, !13, !16, !15}
!21 = distinct !{!21, !13, !15, !16}
!22 = distinct !{!22, !13, !16, !15}
!23 = distinct !{!23, !13, !15, !16}
!24 = distinct !{!24, !13, !16, !15}
!25 = distinct !{!25, !13}
!26 = distinct !{!26, !13, !15, !16}
!27 = distinct !{!27, !13}
!28 = distinct !{!28, !13}
