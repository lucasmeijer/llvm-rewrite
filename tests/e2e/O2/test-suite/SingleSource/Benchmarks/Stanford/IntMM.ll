; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/IntMM.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@ima = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@imb = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@imr = dso_local local_unnamed_addr global [41 x [41 x i32]] zeroinitializer, align 16
@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
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

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: write, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Initmatrix(ptr nofree noundef writeonly captures(none) %0) local_unnamed_addr #2 {
  %2 = load i64, ptr @seed, align 8, !tbaa !9
  %3 = freeze i64 %2
  br label %4

4:                                                ; preds = %1, %30
  %5 = phi i64 [ 1, %1 ], [ %31, %30 ]
  %6 = phi i64 [ %3, %1 ], [ %21, %30 ]
  %7 = getelementptr inbounds nuw [164 x i8], ptr %0, i64 %5
  br label %8

8:                                                ; preds = %8, %4
  %9 = phi i64 [ 1, %4 ], [ %28, %8 ]
  %10 = phi i64 [ %6, %4 ], [ %21, %8 ]
  %11 = mul i64 %10, 1309
  %12 = add i64 %11, 13849
  %13 = and i64 %12, 65535
  %14 = trunc i64 %12 to i16
  %15 = urem i16 %14, 120
  %16 = zext nneg i16 %15 to i32
  %17 = add nsw i32 %16, -60
  %18 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %9
  store i32 %17, ptr %18, align 4, !tbaa !11
  %19 = mul nuw nsw i64 %13, 1309
  %20 = add nuw nsw i64 %19, 13849
  %21 = and i64 %20, 65535
  %22 = trunc i64 %20 to i16
  %23 = urem i16 %22, 120
  %24 = zext nneg i16 %23 to i32
  %25 = add nsw i32 %24, -60
  %26 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %9
  %27 = getelementptr inbounds nuw i8, ptr %26, i64 4
  store i32 %25, ptr %27, align 4, !tbaa !11
  %28 = add nuw nsw i64 %9, 2
  %29 = icmp eq i64 %28, 41
  br i1 %29, label %30, label %8, !llvm.loop !12

30:                                               ; preds = %8
  %31 = add nuw nsw i64 %5, 1
  %32 = icmp eq i64 %31, 41
  br i1 %32, label %33, label %4, !llvm.loop !14

33:                                               ; preds = %30
  store i64 %21, ptr @seed, align 8, !tbaa !9
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @Innerproduct(ptr nofree noundef writeonly captures(none) initializes((0, 4)) %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef readonly captures(none) %2, i32 noundef %3, i32 noundef %4) local_unnamed_addr #3 {
  store i32 0, ptr %0, align 4, !tbaa !11
  %6 = sext i32 %3 to i64
  %7 = getelementptr inbounds [164 x i8], ptr %1, i64 %6
  %8 = sext i32 %4 to i64
  %9 = getelementptr [4 x i8], ptr %2, i64 %8
  %10 = getelementptr i8, ptr %0, i64 4
  %11 = mul nsw i64 %6, 164
  %12 = getelementptr i8, ptr %1, i64 %11
  %13 = getelementptr i8, ptr %12, i64 4
  %14 = getelementptr i8, ptr %1, i64 %11
  %15 = getelementptr i8, ptr %14, i64 164
  %16 = shl nsw i64 %8, 2
  %17 = getelementptr i8, ptr %2, i64 %16
  %18 = getelementptr i8, ptr %17, i64 164
  %19 = getelementptr i8, ptr %2, i64 %16
  %20 = getelementptr i8, ptr %19, i64 6564
  %21 = icmp ult ptr %0, %15
  %22 = icmp ult ptr %13, %10
  %23 = and i1 %21, %22
  %24 = icmp ult ptr %0, %20
  %25 = icmp ult ptr %18, %10
  %26 = and i1 %24, %25
  %27 = or i1 %23, %26
  br i1 %27, label %77, label %28

28:                                               ; preds = %5, %28
  %29 = phi i64 [ %72, %28 ], [ 0, %5 ]
  %30 = phi <4 x i32> [ %70, %28 ], [ zeroinitializer, %5 ]
  %31 = phi <4 x i32> [ %71, %28 ], [ zeroinitializer, %5 ]
  %32 = or disjoint i64 %29, 1
  %33 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %32
  %34 = getelementptr inbounds nuw i8, ptr %33, i64 16
  %35 = load <4 x i32>, ptr %33, align 4, !tbaa !11, !alias.scope !15
  %36 = load <4 x i32>, ptr %34, align 4, !tbaa !11, !alias.scope !15
  %37 = getelementptr [164 x i8], ptr %9, i64 %32
  %38 = getelementptr [164 x i8], ptr %9, i64 %29
  %39 = getelementptr i8, ptr %38, i64 328
  %40 = getelementptr [164 x i8], ptr %9, i64 %29
  %41 = getelementptr i8, ptr %40, i64 492
  %42 = getelementptr [164 x i8], ptr %9, i64 %29
  %43 = getelementptr i8, ptr %42, i64 656
  %44 = getelementptr [164 x i8], ptr %9, i64 %29
  %45 = getelementptr i8, ptr %44, i64 820
  %46 = getelementptr [164 x i8], ptr %9, i64 %29
  %47 = getelementptr i8, ptr %46, i64 984
  %48 = getelementptr [164 x i8], ptr %9, i64 %29
  %49 = getelementptr i8, ptr %48, i64 1148
  %50 = getelementptr [164 x i8], ptr %9, i64 %29
  %51 = getelementptr i8, ptr %50, i64 1312
  %52 = load i32, ptr %37, align 4, !tbaa !11, !alias.scope !18
  %53 = load i32, ptr %39, align 4, !tbaa !11, !alias.scope !18
  %54 = load i32, ptr %41, align 4, !tbaa !11, !alias.scope !18
  %55 = load i32, ptr %43, align 4, !tbaa !11, !alias.scope !18
  %56 = insertelement <4 x i32> poison, i32 %52, i64 0
  %57 = insertelement <4 x i32> %56, i32 %53, i64 1
  %58 = insertelement <4 x i32> %57, i32 %54, i64 2
  %59 = insertelement <4 x i32> %58, i32 %55, i64 3
  %60 = load i32, ptr %45, align 4, !tbaa !11, !alias.scope !18
  %61 = load i32, ptr %47, align 4, !tbaa !11, !alias.scope !18
  %62 = load i32, ptr %49, align 4, !tbaa !11, !alias.scope !18
  %63 = load i32, ptr %51, align 4, !tbaa !11, !alias.scope !18
  %64 = insertelement <4 x i32> poison, i32 %60, i64 0
  %65 = insertelement <4 x i32> %64, i32 %61, i64 1
  %66 = insertelement <4 x i32> %65, i32 %62, i64 2
  %67 = insertelement <4 x i32> %66, i32 %63, i64 3
  %68 = mul nsw <4 x i32> %59, %35
  %69 = mul nsw <4 x i32> %67, %36
  %70 = add <4 x i32> %68, %30
  %71 = add <4 x i32> %69, %31
  %72 = add nuw i64 %29, 8
  %73 = icmp eq i64 %72, 40
  br i1 %73, label %74, label %28, !llvm.loop !20

74:                                               ; preds = %28
  %75 = add <4 x i32> %71, %70
  %76 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %75)
  store i32 %76, ptr %0, align 4, !tbaa !11, !alias.scope !23, !noalias !25
  br label %95

77:                                               ; preds = %5, %77
  %78 = phi i64 [ %93, %77 ], [ 1, %5 ]
  %79 = phi i32 [ %92, %77 ], [ 0, %5 ]
  %80 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %78
  %81 = load i32, ptr %80, align 4, !tbaa !11
  %82 = getelementptr [164 x i8], ptr %9, i64 %78
  %83 = load i32, ptr %82, align 4, !tbaa !11
  %84 = mul nsw i32 %83, %81
  %85 = add nsw i32 %84, %79
  store i32 %85, ptr %0, align 4, !tbaa !11
  %86 = add nuw nsw i64 %78, 1
  %87 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %86
  %88 = load i32, ptr %87, align 4, !tbaa !11
  %89 = getelementptr [164 x i8], ptr %9, i64 %86
  %90 = load i32, ptr %89, align 4, !tbaa !11
  %91 = mul nsw i32 %90, %88
  %92 = add nsw i32 %91, %85
  store i32 %92, ptr %0, align 4, !tbaa !11
  %93 = add nuw nsw i64 %78, 2
  %94 = icmp eq i64 %93, 41
  br i1 %94, label %95, label %77, !llvm.loop !26

95:                                               ; preds = %77, %74
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Intmm(i32 noundef %0) local_unnamed_addr #4 {
  br label %2

2:                                                ; preds = %28, %1
  %3 = phi i64 [ 1, %1 ], [ %29, %28 ]
  %4 = phi i64 [ 74755, %1 ], [ %19, %28 ]
  %5 = getelementptr inbounds nuw [164 x i8], ptr @ima, i64 %3
  br label %6

6:                                                ; preds = %6, %2
  %7 = phi i64 [ 1, %2 ], [ %26, %6 ]
  %8 = phi i64 [ %4, %2 ], [ %19, %6 ]
  %9 = mul nuw nsw i64 %8, 1309
  %10 = add nuw nsw i64 %9, 13849
  %11 = and i64 %10, 65535
  %12 = trunc i64 %10 to i16
  %13 = urem i16 %12, 120
  %14 = zext nneg i16 %13 to i32
  %15 = add nsw i32 %14, -60
  %16 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %7
  store i32 %15, ptr %16, align 4, !tbaa !11
  %17 = mul nuw nsw i64 %11, 1309
  %18 = add nuw nsw i64 %17, 13849
  %19 = and i64 %18, 65535
  %20 = trunc i64 %18 to i16
  %21 = urem i16 %20, 120
  %22 = zext nneg i16 %21 to i32
  %23 = add nsw i32 %22, -60
  %24 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %7
  %25 = getelementptr inbounds nuw i8, ptr %24, i64 4
  store i32 %23, ptr %25, align 4, !tbaa !11
  %26 = add nuw nsw i64 %7, 2
  %27 = icmp eq i64 %26, 41
  br i1 %27, label %28, label %6, !llvm.loop !12

28:                                               ; preds = %6
  %29 = add nuw nsw i64 %3, 1
  %30 = icmp eq i64 %29, 41
  br i1 %30, label %31, label %2, !llvm.loop !14

31:                                               ; preds = %28, %57
  %32 = phi i64 [ %58, %57 ], [ 1, %28 ]
  %33 = phi i64 [ %48, %57 ], [ %19, %28 ]
  %34 = getelementptr inbounds nuw [164 x i8], ptr @imb, i64 %32
  br label %35

35:                                               ; preds = %35, %31
  %36 = phi i64 [ 1, %31 ], [ %55, %35 ]
  %37 = phi i64 [ %33, %31 ], [ %48, %35 ]
  %38 = mul nuw nsw i64 %37, 1309
  %39 = add nuw nsw i64 %38, 13849
  %40 = and i64 %39, 65535
  %41 = trunc i64 %39 to i16
  %42 = urem i16 %41, 120
  %43 = zext nneg i16 %42 to i32
  %44 = add nsw i32 %43, -60
  %45 = getelementptr inbounds nuw [4 x i8], ptr %34, i64 %36
  store i32 %44, ptr %45, align 4, !tbaa !11
  %46 = mul nuw nsw i64 %40, 1309
  %47 = add nuw nsw i64 %46, 13849
  %48 = and i64 %47, 65535
  %49 = trunc i64 %47 to i16
  %50 = urem i16 %49, 120
  %51 = zext nneg i16 %50 to i32
  %52 = add nsw i32 %51, -60
  %53 = getelementptr inbounds nuw [4 x i8], ptr %34, i64 %36
  %54 = getelementptr inbounds nuw i8, ptr %53, i64 4
  store i32 %52, ptr %54, align 4, !tbaa !11
  %55 = add nuw nsw i64 %36, 2
  %56 = icmp eq i64 %55, 41
  br i1 %56, label %57, label %35, !llvm.loop !12

57:                                               ; preds = %35
  %58 = add nuw nsw i64 %32, 1
  %59 = icmp eq i64 %58, 41
  br i1 %59, label %60, label %31, !llvm.loop !14

60:                                               ; preds = %57
  store i64 %48, ptr @seed, align 8, !tbaa !9
  br label %61

61:                                               ; preds = %60, %120
  %62 = phi i64 [ 1, %60 ], [ %121, %120 ]
  %63 = getelementptr inbounds nuw [164 x i8], ptr @imr, i64 %62
  %64 = getelementptr inbounds nuw [164 x i8], ptr @ima, i64 %62
  br label %65

65:                                               ; preds = %61, %115
  %66 = phi i64 [ 1, %61 ], [ %118, %115 ]
  %67 = getelementptr inbounds nuw [4 x i8], ptr %63, i64 %66
  %68 = getelementptr [4 x i8], ptr @imb, i64 %66
  br label %69

69:                                               ; preds = %69, %65
  %70 = phi i64 [ 0, %65 ], [ %113, %69 ]
  %71 = phi <4 x i32> [ zeroinitializer, %65 ], [ %111, %69 ]
  %72 = phi <4 x i32> [ zeroinitializer, %65 ], [ %112, %69 ]
  %73 = or disjoint i64 %70, 1
  %74 = getelementptr inbounds nuw [4 x i8], ptr %64, i64 %73
  %75 = getelementptr inbounds nuw i8, ptr %74, i64 16
  %76 = load <4 x i32>, ptr %74, align 4, !tbaa !11
  %77 = load <4 x i32>, ptr %75, align 4, !tbaa !11
  %78 = getelementptr [164 x i8], ptr %68, i64 %73
  %79 = getelementptr [164 x i8], ptr %68, i64 %70
  %80 = getelementptr i8, ptr %79, i64 328
  %81 = getelementptr [164 x i8], ptr %68, i64 %70
  %82 = getelementptr i8, ptr %81, i64 492
  %83 = getelementptr [164 x i8], ptr %68, i64 %70
  %84 = getelementptr i8, ptr %83, i64 656
  %85 = getelementptr [164 x i8], ptr %68, i64 %70
  %86 = getelementptr i8, ptr %85, i64 820
  %87 = getelementptr [164 x i8], ptr %68, i64 %70
  %88 = getelementptr i8, ptr %87, i64 984
  %89 = getelementptr [164 x i8], ptr %68, i64 %70
  %90 = getelementptr i8, ptr %89, i64 1148
  %91 = getelementptr [164 x i8], ptr %68, i64 %70
  %92 = getelementptr i8, ptr %91, i64 1312
  %93 = load i32, ptr %78, align 4, !tbaa !11
  %94 = load i32, ptr %80, align 4, !tbaa !11
  %95 = load i32, ptr %82, align 4, !tbaa !11
  %96 = load i32, ptr %84, align 4, !tbaa !11
  %97 = insertelement <4 x i32> poison, i32 %93, i64 0
  %98 = insertelement <4 x i32> %97, i32 %94, i64 1
  %99 = insertelement <4 x i32> %98, i32 %95, i64 2
  %100 = insertelement <4 x i32> %99, i32 %96, i64 3
  %101 = load i32, ptr %86, align 4, !tbaa !11
  %102 = load i32, ptr %88, align 4, !tbaa !11
  %103 = load i32, ptr %90, align 4, !tbaa !11
  %104 = load i32, ptr %92, align 4, !tbaa !11
  %105 = insertelement <4 x i32> poison, i32 %101, i64 0
  %106 = insertelement <4 x i32> %105, i32 %102, i64 1
  %107 = insertelement <4 x i32> %106, i32 %103, i64 2
  %108 = insertelement <4 x i32> %107, i32 %104, i64 3
  %109 = mul nsw <4 x i32> %100, %76
  %110 = mul nsw <4 x i32> %108, %77
  %111 = add <4 x i32> %109, %71
  %112 = add <4 x i32> %110, %72
  %113 = add nuw i64 %70, 8
  %114 = icmp eq i64 %113, 40
  br i1 %114, label %115, label %69, !llvm.loop !27

115:                                              ; preds = %69
  %116 = add <4 x i32> %112, %111
  %117 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %116)
  store i32 %117, ptr %67, align 4, !tbaa !11
  %118 = add nuw nsw i64 %66, 1
  %119 = icmp eq i64 %118, 41
  br i1 %119, label %120, label %65, !llvm.loop !28

120:                                              ; preds = %115
  %121 = add nuw nsw i64 %62, 1
  %122 = icmp eq i64 %121, 41
  br i1 %122, label %123, label %61, !llvm.loop !29

123:                                              ; preds = %120
  %124 = add nsw i32 %0, 1
  %125 = sext i32 %124 to i64
  %126 = getelementptr inbounds [164 x i8], ptr @imr, i64 %125
  %127 = getelementptr inbounds [4 x i8], ptr %126, i64 %125
  %128 = load i32, ptr %127, align 4, !tbaa !11
  %129 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %128)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #5

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #4 {
  tail call void @Intmm(i32 noundef 0)
  tail call void @Intmm(i32 noundef 1)
  tail call void @Intmm(i32 noundef 2)
  tail call void @Intmm(i32 noundef 3)
  tail call void @Intmm(i32 noundef 4)
  tail call void @Intmm(i32 noundef 5)
  tail call void @Intmm(i32 noundef 6)
  tail call void @Intmm(i32 noundef 7)
  tail call void @Intmm(i32 noundef 8)
  tail call void @Intmm(i32 noundef 9)
  ret i32 0
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>) #6

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(readwrite, argmem: write, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!15 = !{!16}
!16 = distinct !{!16, !17}
!17 = distinct !{!17, !"LVerDomain"}
!18 = !{!19}
!19 = distinct !{!19, !17}
!20 = distinct !{!20, !13, !21, !22}
!21 = !{!"llvm.loop.isvectorized", i32 1}
!22 = !{!"llvm.loop.unroll.runtime.disable"}
!23 = !{!24}
!24 = distinct !{!24, !17}
!25 = !{!16, !19}
!26 = distinct !{!26, !13, !21}
!27 = distinct !{!27, !13, !21, !22}
!28 = distinct !{!28, !13}
!29 = distinct !{!29, !13}
