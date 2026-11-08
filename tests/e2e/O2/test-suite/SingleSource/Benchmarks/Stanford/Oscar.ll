; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Oscar.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Oscar.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Oscar.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.complex = type { float, float }
%struct.element = type { i32, i32 }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@.str.1 = private unnamed_addr constant [15 x i8] c"  %15.3f%15.3f\00", align 1
@e = dso_local global [130 x %struct.complex] zeroinitializer, align 16
@zr = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@zi = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@z = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
@w = dso_local local_unnamed_addr global [257 x %struct.complex] zeroinitializer, align 16
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

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local float @Cos(float noundef %0) local_unnamed_addr #2 {
  %2 = fmul float %0, %0
  %3 = fmul float %2, 5.000000e-01
  %4 = fsub float 1.000000e+00, %3
  %5 = fmul float %0, %2
  %6 = fmul float %0, %5
  %7 = fmul float %0, %6
  %8 = fmul float %0, %7
  %9 = insertelement <2 x float> poison, float %6, i64 0
  %10 = insertelement <2 x float> %9, float %8, i64 1
  %11 = fdiv <2 x float> %10, <float 2.400000e+01, float 7.200000e+02>
  %12 = extractelement <2 x float> %11, i64 0
  %13 = fadd float %4, %12
  %14 = extractelement <2 x float> %11, i64 1
  %15 = fsub float %13, %14
  %16 = fmul float %0, %8
  %17 = fmul float %0, %16
  %18 = fmul float %0, %17
  %19 = fmul float %0, %18
  %20 = insertelement <2 x float> poison, float %17, i64 0
  %21 = insertelement <2 x float> %20, float %19, i64 1
  %22 = fdiv <2 x float> %21, <float 4.032000e+04, float 3.628800e+06>
  %23 = extractelement <2 x float> %22, i64 0
  %24 = fadd float %15, %23
  %25 = extractelement <2 x float> %22, i64 1
  %26 = fsub float %24, %25
  ret float %26
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #3

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @Min0(i32 noundef %0, i32 noundef %1) local_unnamed_addr #2 {
  %3 = tail call i32 @llvm.smin.i32(i32 %0, i32 %1)
  ret i32 %3
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Printcomplex(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i32 noundef %2, i32 noundef %3) local_unnamed_addr #4 {
  %5 = tail call i32 @putchar(i32 10)
  br label %6

6:                                                ; preds = %6, %4
  %7 = phi i32 [ %1, %4 ], [ %26, %6 ]
  %8 = sext i32 %7 to i64
  %9 = getelementptr inbounds [8 x i8], ptr %0, i64 %8
  %10 = load float, ptr %9, align 4, !tbaa !11
  %11 = fpext float %10 to double
  %12 = getelementptr inbounds nuw i8, ptr %9, i64 4
  %13 = load float, ptr %12, align 4, !tbaa !14
  %14 = fpext float %13 to double
  %15 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %11, double noundef %14)
  %16 = add nsw i32 %7, %3
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [8 x i8], ptr %0, i64 %17
  %19 = load float, ptr %18, align 4, !tbaa !11
  %20 = fpext float %19 to double
  %21 = getelementptr inbounds nuw i8, ptr %18, i64 4
  %22 = load float, ptr %21, align 4, !tbaa !14
  %23 = fpext float %22 to double
  %24 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %20, double noundef %23)
  %25 = tail call i32 @putchar(i32 10)
  %26 = add nsw i32 %16, %3
  %27 = icmp sgt i32 %26, %2
  br i1 %27, label %28, label %6, !llvm.loop !15

28:                                               ; preds = %6
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #5

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable
define dso_local void @Uniform11(ptr nofree noundef captures(none) %0, ptr nofree noundef writeonly captures(none) initializes((0, 4)) %1) local_unnamed_addr #6 {
  %3 = load i32, ptr %0, align 4, !tbaa !17
  %4 = mul nsw i32 %3, 4855
  %5 = add nsw i32 %4, 1731
  %6 = and i32 %5, 8191
  store i32 %6, ptr %0, align 4, !tbaa !17
  %7 = uitofp nneg i32 %6 to float
  %8 = fmul nnan float %7, f0x39000000
  store float %8, ptr %1, align 4, !tbaa !18
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @Exptab(i32 noundef %0, ptr nofree noundef captures(none) %1) local_unnamed_addr #7 {
  %3 = alloca [26 x float], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #11
  br label %4

4:                                                ; preds = %2, %4
  %5 = phi i64 [ 1, %2 ], [ %37, %4 ]
  %6 = phi float [ 4.000000e+00, %2 ], [ %36, %4 ]
  %7 = fdiv float f0x40490FDB, %6
  %8 = fmul float %7, %7
  %9 = fmul float %8, 5.000000e-01
  %10 = fsub float 1.000000e+00, %9
  %11 = fmul float %7, %8
  %12 = fmul float %7, %11
  %13 = fmul float %7, %12
  %14 = fmul float %7, %13
  %15 = insertelement <2 x float> poison, float %12, i64 0
  %16 = insertelement <2 x float> %15, float %14, i64 1
  %17 = fdiv <2 x float> %16, <float 2.400000e+01, float 7.200000e+02>
  %18 = extractelement <2 x float> %17, i64 0
  %19 = fadd float %10, %18
  %20 = extractelement <2 x float> %17, i64 1
  %21 = fsub float %19, %20
  %22 = fmul float %7, %14
  %23 = fmul float %7, %22
  %24 = fmul float %7, %23
  %25 = fmul float %7, %24
  %26 = insertelement <2 x float> poison, float %23, i64 0
  %27 = insertelement <2 x float> %26, float %25, i64 1
  %28 = fdiv <2 x float> %27, <float 4.032000e+04, float 3.628800e+06>
  %29 = extractelement <2 x float> %28, i64 0
  %30 = fadd float %21, %29
  %31 = extractelement <2 x float> %28, i64 1
  %32 = fsub float %30, %31
  %33 = fmul float %32, 2.000000e+00
  %34 = fdiv float 1.000000e+00, %33
  %35 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %5
  store float %34, ptr %35, align 4, !tbaa !18
  %36 = fadd float %6, %6
  %37 = add nuw nsw i64 %5, 1
  %38 = icmp eq i64 %37, 26
  br i1 %38, label %39, label %4, !llvm.loop !19

39:                                               ; preds = %4
  %40 = sdiv i32 %0, 2
  %41 = sdiv i32 %0, 4
  %42 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store <2 x float> <float 1.000000e+00, float 0.000000e+00>, ptr %42, align 4, !tbaa !18
  %43 = sext i32 %41 to i64
  %44 = getelementptr [8 x i8], ptr %1, i64 %43
  %45 = getelementptr i8, ptr %44, i64 8
  store <2 x float> <float 0.000000e+00, float 1.000000e+00>, ptr %45, align 4, !tbaa !18
  %46 = sext i32 %40 to i64
  %47 = getelementptr [8 x i8], ptr %1, i64 %46
  %48 = getelementptr i8, ptr %47, i64 8
  store <2 x float> <float -1.000000e+00, float 0.000000e+00>, ptr %48, align 4, !tbaa !18
  %49 = getelementptr i8, ptr %1, i64 8
  %50 = getelementptr i8, ptr %1, i64 12
  %51 = add nsw i64 %46, 1
  %52 = getelementptr i8, ptr %1, i64 8
  %53 = getelementptr i8, ptr %1, i64 12
  %54 = getelementptr i8, ptr %1, i64 12
  %55 = getelementptr i8, ptr %1, i64 12
  %56 = getelementptr i8, ptr %1, i64 16
  %57 = getelementptr i8, ptr %1, i64 12
  %58 = getelementptr i8, ptr %1, i64 16
  %59 = getelementptr i8, ptr %1, i64 16
  br label %60

60:                                               ; preds = %146, %39
  %61 = phi i32 [ 1, %39 ], [ %148, %146 ]
  %62 = phi i32 [ %41, %39 ], [ %63, %146 ]
  %63 = sdiv i32 %62, 2
  %64 = sext i32 %61 to i64
  %65 = getelementptr inbounds [4 x i8], ptr %3, i64 %64
  %66 = load float, ptr %65, align 4, !tbaa !18
  %67 = sext i32 %63 to i64
  %68 = sext i32 %62 to i64
  %69 = getelementptr [8 x i8], ptr %1, i64 %67
  %70 = tail call i64 @llvm.smax.i64(i64 %67, i64 %46)
  %71 = add nsw i64 %70, 1
  %72 = sub i64 %71, %67
  %73 = icmp ugt i64 %72, 11
  %74 = icmp eq i32 %62, 1
  %75 = and i1 %73, %74
  br i1 %75, label %76, label %127

76:                                               ; preds = %60
  %77 = tail call i64 @llvm.smax.i64(i64 %68, i64 %51)
  %78 = icmp sge i32 %40, %62
  %79 = zext i1 %78 to i64
  %80 = select i1 %78, i64 2305843009213693950, i64 2305843009213693951
  %81 = add nuw i64 %80, %77
  %82 = add i64 %81, %79
  %83 = shl i64 %82, 3
  %84 = getelementptr i8, ptr %50, i64 %83
  %85 = getelementptr i8, ptr %53, i64 %83
  %86 = getelementptr i8, ptr %54, i64 %83
  %87 = getelementptr i8, ptr %56, i64 %83
  %88 = getelementptr i8, ptr %58, i64 %83
  %89 = getelementptr i8, ptr %59, i64 %83
  %90 = icmp ult ptr %49, %85
  %91 = icmp ult ptr %52, %84
  %92 = and i1 %90, %91
  %93 = icmp ult ptr %49, %86
  %94 = icmp ult ptr %52, %84
  %95 = and i1 %93, %94
  %96 = or i1 %92, %95
  %97 = icmp ult ptr %55, %88
  %98 = icmp ult ptr %57, %87
  %99 = and i1 %97, %98
  %100 = or i1 %96, %99
  %101 = icmp ult ptr %55, %89
  %102 = icmp ult ptr %57, %87
  %103 = and i1 %101, %102
  %104 = or i1 %100, %103
  br i1 %104, label %127, label %105

105:                                              ; preds = %76
  %106 = and i64 %71, 3
  %107 = sub nsw i64 %72, %106
  %108 = insertelement <4 x float> poison, float %66, i64 0
  %109 = shufflevector <4 x float> %108, <4 x float> poison, <8 x i32> zeroinitializer
  br label %110

110:                                              ; preds = %110, %105
  %111 = phi i64 [ 0, %105 ], [ %123, %110 ]
  %112 = getelementptr [8 x i8], ptr %69, i64 %111
  %113 = getelementptr i8, ptr %112, i64 8
  %114 = load <8 x float>, ptr %113, align 4, !tbaa !18
  %115 = sub nuw nsw i64 %111, %67
  %116 = getelementptr [8 x i8], ptr %1, i64 %115
  %117 = getelementptr i8, ptr %116, i64 8
  %118 = load <8 x float>, ptr %117, align 4, !tbaa !18
  %119 = getelementptr [8 x i8], ptr %1, i64 %111
  %120 = getelementptr i8, ptr %119, i64 8
  %121 = fadd <8 x float> %114, %118
  %122 = fmul <8 x float> %109, %121
  store <8 x float> %122, ptr %120, align 4, !tbaa !18
  %123 = add nuw i64 %111, 4
  %124 = icmp eq i64 %123, %107
  br i1 %124, label %125, label %110, !llvm.loop !20

125:                                              ; preds = %110
  %126 = icmp eq i64 %106, 0
  br i1 %126, label %146, label %127

127:                                              ; preds = %76, %60, %125
  %128 = phi i64 [ %67, %76 ], [ %67, %60 ], [ %107, %125 ]
  %129 = insertelement <2 x float> poison, float %66, i64 0
  %130 = shufflevector <2 x float> %129, <2 x float> poison, <2 x i32> zeroinitializer
  br label %131

131:                                              ; preds = %127, %131
  %132 = phi i64 [ %144, %131 ], [ %128, %127 ]
  %133 = getelementptr [8 x i8], ptr %69, i64 %132
  %134 = getelementptr i8, ptr %133, i64 8
  %135 = sub nsw i64 %132, %67
  %136 = getelementptr [8 x i8], ptr %1, i64 %135
  %137 = getelementptr i8, ptr %136, i64 8
  %138 = getelementptr [8 x i8], ptr %1, i64 %132
  %139 = getelementptr i8, ptr %138, i64 8
  %140 = load <2 x float>, ptr %134, align 4, !tbaa !18
  %141 = load <2 x float>, ptr %137, align 4, !tbaa !18
  %142 = fadd <2 x float> %140, %141
  %143 = fmul <2 x float> %130, %142
  store <2 x float> %143, ptr %139, align 4, !tbaa !18
  %144 = add nsw i64 %132, %68
  %145 = icmp sgt i64 %144, %46
  br i1 %145, label %146, label %131, !llvm.loop !23

146:                                              ; preds = %131, %125
  %147 = tail call i32 @llvm.smin.i32(i32 %61, i32 24)
  %148 = add nsw i32 %147, 1
  %149 = icmp sgt i32 %62, 3
  br i1 %149, label %60, label %150, !llvm.loop !24

150:                                              ; preds = %146
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #11
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @Fft(i32 noundef %0, ptr nofree noundef captures(none) %1, ptr nofree noundef captures(none) %2, ptr nofree noundef readonly captures(none) %3, float noundef %4) local_unnamed_addr #7 {
  %6 = ptrtoaddr ptr %2 to i64
  %7 = ptrtoaddr ptr %1 to i64
  %8 = sdiv i32 %0, 2
  %9 = sext i32 %8 to i64
  %10 = tail call i32 @llvm.smax.i32(i32 %0, i32 1)
  %11 = add nuw i32 %10, 1
  %12 = getelementptr [8 x i8], ptr %1, i64 %9
  %13 = zext i32 %11 to i64
  %14 = shl nsw i64 %9, 3
  %15 = getelementptr i8, ptr %1, i64 %14
  %16 = getelementptr i8, ptr %1, i64 %14
  %17 = getelementptr i8, ptr %1, i64 4
  %18 = getelementptr i8, ptr %1, i64 4
  %19 = getelementptr i8, ptr %1, i64 %14
  %20 = getelementptr i8, ptr %19, i64 4
  %21 = getelementptr i8, ptr %1, i64 8
  %22 = getelementptr i8, ptr %1, i64 4
  %23 = getelementptr i8, ptr %1, i64 8
  %24 = zext nneg i32 %10 to i64
  %25 = add nuw nsw i64 %24, 1
  %26 = zext nneg i32 %10 to i64
  %27 = icmp slt i32 %0, 4
  %28 = sub i64 %6, %7
  %29 = icmp ugt i64 %28, -32
  %30 = or i1 %27, %29
  %31 = and i64 %26, 2147483644
  %32 = or disjoint i64 %31, 1
  %33 = icmp eq i64 %31, %26
  br label %34

34:                                               ; preds = %321, %5
  %35 = phi i32 [ 1, %5 ], [ %322, %321 ]
  %36 = sext i32 %35 to i64
  %37 = shl nsw i64 %36, 3
  %38 = shl nsw i64 %36, 3
  %39 = shl nsw i64 %36, 3
  %40 = getelementptr i8, ptr %2, i64 %38
  %41 = getelementptr i8, ptr %2, i64 %38
  %42 = getelementptr i8, ptr %41, i64 4
  %43 = getelementptr i8, ptr %2, i64 %38
  %44 = getelementptr i8, ptr %43, i64 8
  %45 = getelementptr i8, ptr %2, i64 %38
  br label %46

46:                                               ; preds = %267, %34
  %47 = phi i64 [ %270, %267 ], [ 0, %34 ]
  %48 = phi i64 [ %268, %267 ], [ %36, %34 ]
  %49 = phi i64 [ %48, %267 ], [ 0, %34 ]
  %50 = phi i64 [ %265, %267 ], [ 1, %34 ]
  %51 = mul i64 %39, %47
  %52 = getelementptr i8, ptr %2, i64 %51
  %53 = getelementptr i8, ptr %2, i64 %51
  %54 = getelementptr i8, ptr %53, i64 4
  %55 = getelementptr i8, ptr %40, i64 %51
  %56 = getelementptr i8, ptr %42, i64 %51
  %57 = add i64 %51, 8
  %58 = getelementptr i8, ptr %3, i64 %57
  %59 = getelementptr i8, ptr %3, i64 %51
  %60 = getelementptr i8, ptr %59, i64 12
  %61 = getelementptr i8, ptr %2, i64 %57
  %62 = getelementptr i8, ptr %44, i64 %51
  %63 = getelementptr i8, ptr %3, i64 %51
  %64 = getelementptr i8, ptr %63, i64 16
  %65 = getelementptr [8 x i8], ptr %3, i64 %49
  %66 = getelementptr i8, ptr %65, i64 8
  %67 = getelementptr i8, ptr %65, i64 12
  %68 = getelementptr [8 x i8], ptr %2, i64 %49
  %69 = getelementptr [8 x i8], ptr %2, i64 %48
  %70 = tail call i64 @llvm.smax.i64(i64 %50, i64 %48)
  %71 = sub i64 %70, %50
  %72 = add i64 %71, 1
  %73 = icmp ult i64 %72, 17
  br i1 %73, label %234, label %74

74:                                               ; preds = %46
  %75 = mul i64 %37, %47
  %76 = getelementptr i8, ptr %45, i64 %75
  %77 = getelementptr i8, ptr %2, i64 %75
  %78 = tail call i64 @llvm.smax.i64(i64 %50, i64 %48)
  %79 = sub i64 %78, %50
  %80 = shl i64 %50, 3
  %81 = getelementptr i8, ptr %77, i64 %80
  %82 = shl i64 %79, 3
  %83 = getelementptr i8, ptr %81, i64 %82
  %84 = icmp ult ptr %83, %81
  %85 = getelementptr i8, ptr %76, i64 %80
  %86 = shl i64 %79, 3
  %87 = icmp ugt i64 %79, 2305843009213693951
  %88 = getelementptr i8, ptr %85, i64 %86
  %89 = icmp ult ptr %88, %85
  %90 = or i1 %89, %87
  %91 = getelementptr i8, ptr %15, i64 %80
  %92 = shl i64 %79, 3
  %93 = getelementptr i8, ptr %91, i64 %92
  %94 = icmp ult ptr %93, %91
  %95 = or i1 %84, %90
  %96 = or i1 %94, %95
  br i1 %96, label %234, label %97

97:                                               ; preds = %74
  %98 = shl i64 %50, 3
  %99 = getelementptr i8, ptr %16, i64 %98
  %100 = tail call i64 @llvm.smax.i64(i64 %50, i64 %48)
  %101 = add i64 %100, %9
  %102 = shl i64 %101, 3
  %103 = getelementptr i8, ptr %17, i64 %102
  %104 = getelementptr i8, ptr %52, i64 %98
  %105 = shl i64 %100, 3
  %106 = getelementptr i8, ptr %54, i64 %105
  %107 = getelementptr i8, ptr %55, i64 %98
  %108 = getelementptr i8, ptr %56, i64 %105
  %109 = getelementptr i8, ptr %1, i64 %98
  %110 = getelementptr i8, ptr %18, i64 %105
  %111 = getelementptr i8, ptr %54, i64 %98
  %112 = getelementptr i8, ptr %61, i64 %105
  %113 = getelementptr i8, ptr %56, i64 %98
  %114 = getelementptr i8, ptr %62, i64 %105
  %115 = getelementptr i8, ptr %20, i64 %98
  %116 = getelementptr i8, ptr %21, i64 %102
  %117 = getelementptr i8, ptr %22, i64 %98
  %118 = getelementptr i8, ptr %23, i64 %105
  %119 = icmp ult ptr %99, %106
  %120 = icmp ult ptr %104, %103
  %121 = and i1 %119, %120
  %122 = icmp ult ptr %99, %108
  %123 = icmp ult ptr %107, %103
  %124 = and i1 %122, %123
  %125 = or i1 %121, %124
  %126 = icmp ult ptr %109, %106
  %127 = icmp ult ptr %104, %110
  %128 = and i1 %126, %127
  %129 = or i1 %125, %128
  %130 = icmp ult ptr %109, %108
  %131 = icmp ult ptr %107, %110
  %132 = and i1 %130, %131
  %133 = or i1 %129, %132
  %134 = icmp ult ptr %58, %106
  %135 = icmp ult ptr %104, %60
  %136 = and i1 %134, %135
  %137 = or i1 %133, %136
  %138 = icmp ult ptr %58, %108
  %139 = icmp ult ptr %107, %60
  %140 = and i1 %138, %139
  %141 = or i1 %137, %140
  %142 = icmp ult ptr %104, %108
  %143 = icmp ult ptr %107, %106
  %144 = and i1 %142, %143
  %145 = or i1 %141, %144
  %146 = icmp ult ptr %111, %114
  %147 = icmp ult ptr %113, %112
  %148 = and i1 %146, %147
  %149 = or i1 %145, %148
  %150 = icmp ult ptr %111, %116
  %151 = icmp ult ptr %115, %112
  %152 = and i1 %150, %151
  %153 = or i1 %149, %152
  %154 = icmp ult ptr %111, %118
  %155 = icmp ult ptr %117, %112
  %156 = and i1 %154, %155
  %157 = or i1 %153, %156
  %158 = icmp ult ptr %111, %64
  %159 = icmp ult ptr %60, %112
  %160 = and i1 %158, %159
  %161 = or i1 %157, %160
  %162 = icmp ult ptr %113, %116
  %163 = icmp ult ptr %115, %114
  %164 = and i1 %162, %163
  %165 = or i1 %161, %164
  %166 = icmp ult ptr %113, %118
  %167 = icmp ult ptr %117, %114
  %168 = and i1 %166, %167
  %169 = or i1 %165, %168
  %170 = icmp ult ptr %113, %64
  %171 = icmp ult ptr %60, %114
  %172 = and i1 %170, %171
  %173 = or i1 %169, %172
  br i1 %173, label %234, label %174

174:                                              ; preds = %97
  %175 = and i64 %72, 3
  %176 = icmp eq i64 %175, 0
  %177 = select i1 %176, i64 4, i64 %175
  %178 = sub i64 %72, %177
  %179 = add i64 %50, %178
  br label %180

180:                                              ; preds = %180, %174
  %181 = phi i64 [ 0, %174 ], [ %232, %180 ]
  %182 = add i64 %50, %181
  %183 = getelementptr inbounds [8 x i8], ptr %1, i64 %182
  %184 = load <8 x float>, ptr %183, align 4, !tbaa !11, !alias.scope !25, !noalias !28
  %185 = shufflevector <8 x float> %184, <8 x float> poison, <4 x i32> <i32 0, i32 2, i32 4, i32 6>
  %186 = getelementptr [8 x i8], ptr %12, i64 %182
  %187 = getelementptr [8 x i8], ptr %12, i64 %182
  %188 = getelementptr i8, ptr %187, i64 8
  %189 = getelementptr [8 x i8], ptr %12, i64 %182
  %190 = getelementptr i8, ptr %189, i64 16
  %191 = getelementptr [8 x i8], ptr %12, i64 %182
  %192 = getelementptr i8, ptr %191, i64 24
  %193 = load float, ptr %186, align 4, !tbaa !11, !alias.scope !31, !noalias !28
  %194 = load float, ptr %188, align 4, !tbaa !11, !alias.scope !31, !noalias !28
  %195 = load float, ptr %190, align 4, !tbaa !11, !alias.scope !31, !noalias !28
  %196 = load float, ptr %192, align 4, !tbaa !11, !alias.scope !31, !noalias !28
  %197 = insertelement <4 x float> poison, float %193, i64 0
  %198 = insertelement <4 x float> %197, float %194, i64 1
  %199 = insertelement <4 x float> %198, float %195, i64 2
  %200 = insertelement <4 x float> %199, float %196, i64 3
  %201 = fadd <4 x float> %185, %200
  %202 = getelementptr [8 x i8], ptr %68, i64 %182
  %203 = load <8 x float>, ptr %183, align 4, !tbaa !18
  %204 = load <8 x float>, ptr %186, align 4, !tbaa !18
  %205 = fadd <8 x float> %203, %204
  %206 = shufflevector <8 x float> %205, <8 x float> poison, <4 x i32> <i32 1, i32 3, i32 5, i32 7>
  %207 = shufflevector <4 x float> %201, <4 x float> %206, <8 x i32> <i32 0, i32 4, i32 1, i32 5, i32 2, i32 6, i32 3, i32 7>
  store <8 x float> %207, ptr %202, align 4, !tbaa !18
  %208 = load float, ptr %66, align 4, !tbaa !11, !alias.scope !33, !noalias !28
  %209 = insertelement <4 x float> poison, float %208, i64 0
  %210 = shufflevector <4 x float> %209, <4 x float> poison, <4 x i32> zeroinitializer
  %211 = fsub <8 x float> %203, %204
  %212 = shufflevector <8 x float> %211, <8 x float> poison, <4 x i32> <i32 0, i32 2, i32 4, i32 6>
  %213 = load float, ptr %67, align 4, !tbaa !14, !alias.scope !35
  %214 = insertelement <4 x float> poison, float %213, i64 0
  %215 = shufflevector <4 x float> %214, <4 x float> poison, <4 x i32> zeroinitializer
  %216 = load <8 x float>, ptr %183, align 4, !tbaa !18
  %217 = load <8 x float>, ptr %186, align 4, !tbaa !18
  %218 = fsub <8 x float> %216, %217
  %219 = shufflevector <8 x float> %218, <8 x float> poison, <4 x i32> <i32 1, i32 3, i32 5, i32 7>
  %220 = fneg <4 x float> %219
  %221 = fmul <4 x float> %215, %220
  %222 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %210, <4 x float> %212, <4 x float> %221)
  %223 = getelementptr [8 x i8], ptr %69, i64 %182
  %224 = load float, ptr %66, align 4, !tbaa !11, !alias.scope !33, !noalias !28
  %225 = insertelement <4 x float> poison, float %224, i64 0
  %226 = shufflevector <4 x float> %225, <4 x float> poison, <4 x i32> zeroinitializer
  %227 = fsub <8 x float> %216, %217
  %228 = shufflevector <8 x float> %227, <8 x float> poison, <4 x i32> <i32 0, i32 2, i32 4, i32 6>
  %229 = fmul <4 x float> %215, %228
  %230 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %226, <4 x float> %219, <4 x float> %229)
  %231 = shufflevector <4 x float> %222, <4 x float> %230, <8 x i32> <i32 0, i32 4, i32 1, i32 5, i32 2, i32 6, i32 3, i32 7>
  store <8 x float> %231, ptr %223, align 4, !tbaa !18
  %232 = add nuw i64 %181, 4
  %233 = icmp eq i64 %232, %178
  br i1 %233, label %234, label %180, !llvm.loop !37

234:                                              ; preds = %180, %97, %74, %46
  %235 = phi i64 [ %50, %97 ], [ %50, %74 ], [ %50, %46 ], [ %179, %180 ]
  br label %236

236:                                              ; preds = %234, %236
  %237 = phi i64 [ %265, %236 ], [ %235, %234 ]
  %238 = getelementptr inbounds [8 x i8], ptr %1, i64 %237
  %239 = getelementptr [8 x i8], ptr %12, i64 %237
  %240 = getelementptr [8 x i8], ptr %68, i64 %237
  %241 = getelementptr inbounds nuw i8, ptr %238, i64 4
  %242 = getelementptr inbounds nuw i8, ptr %239, i64 4
  %243 = load <2 x float>, ptr %238, align 4, !tbaa !18
  %244 = load <2 x float>, ptr %239, align 4, !tbaa !18
  %245 = fadd <2 x float> %243, %244
  store <2 x float> %245, ptr %240, align 4, !tbaa !18
  %246 = load float, ptr %66, align 4, !tbaa !11
  %247 = load float, ptr %238, align 4, !tbaa !11
  %248 = load float, ptr %239, align 4, !tbaa !11
  %249 = fsub float %247, %248
  %250 = load float, ptr %67, align 4, !tbaa !14
  %251 = load float, ptr %241, align 4, !tbaa !14
  %252 = load float, ptr %242, align 4, !tbaa !14
  %253 = fsub float %251, %252
  %254 = fneg float %253
  %255 = fmul float %250, %254
  %256 = tail call float @llvm.fmuladd.f32(float %246, float %249, float %255)
  %257 = getelementptr [8 x i8], ptr %69, i64 %237
  store float %256, ptr %257, align 4, !tbaa !11
  %258 = load float, ptr %66, align 4, !tbaa !11
  %259 = load float, ptr %238, align 4, !tbaa !11
  %260 = load float, ptr %239, align 4, !tbaa !11
  %261 = fsub float %259, %260
  %262 = fmul float %250, %261
  %263 = tail call float @llvm.fmuladd.f32(float %258, float %253, float %262)
  %264 = getelementptr inbounds nuw i8, ptr %257, i64 4
  store float %263, ptr %264, align 4, !tbaa !14
  %265 = add nsw i64 %237, 1
  %266 = icmp slt i64 %237, %48
  br i1 %266, label %236, label %267, !llvm.loop !38

267:                                              ; preds = %236
  %268 = add nsw i64 %48, %36
  %269 = icmp sgt i64 %268, %9
  %270 = add i64 %47, 1
  br i1 %269, label %271, label %46, !llvm.loop !39

271:                                              ; preds = %267
  br i1 %30, label %284, label %272

272:                                              ; preds = %271, %272
  %273 = phi i64 [ %281, %272 ], [ 0, %271 ]
  %274 = or disjoint i64 %273, 1
  %275 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %274
  %276 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %274
  %277 = getelementptr inbounds nuw i8, ptr %276, i64 16
  %278 = load <2 x i64>, ptr %276, align 4
  %279 = load <2 x i64>, ptr %277, align 4
  %280 = getelementptr inbounds nuw i8, ptr %275, i64 16
  store <2 x i64> %278, ptr %275, align 4
  store <2 x i64> %279, ptr %280, align 4
  %281 = add nuw i64 %273, 4
  %282 = icmp eq i64 %281, %31
  br i1 %282, label %283, label %272, !llvm.loop !40

283:                                              ; preds = %272
  br i1 %33, label %321, label %284

284:                                              ; preds = %271, %283
  %285 = phi i64 [ 1, %271 ], [ %32, %283 ]
  %286 = sub nsw i64 %25, %285
  %287 = sub nsw i64 %24, %285
  %288 = and i64 %286, 3
  %289 = icmp eq i64 %288, 0
  br i1 %289, label %299, label %290

290:                                              ; preds = %284, %290
  %291 = phi i64 [ %296, %290 ], [ %285, %284 ]
  %292 = phi i64 [ %297, %290 ], [ 0, %284 ]
  %293 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %291
  %294 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %291
  %295 = load i64, ptr %294, align 4
  store i64 %295, ptr %293, align 4
  %296 = add nuw nsw i64 %291, 1
  %297 = add i64 %292, 1
  %298 = icmp eq i64 %297, %288
  br i1 %298, label %299, label %290, !llvm.loop !41

299:                                              ; preds = %290, %284
  %300 = phi i64 [ %285, %284 ], [ %296, %290 ]
  %301 = icmp ult i64 %287, 3
  br i1 %301, label %321, label %302

302:                                              ; preds = %299, %302
  %303 = phi i64 [ %319, %302 ], [ %300, %299 ]
  %304 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %303
  %305 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %303
  %306 = load i64, ptr %305, align 4
  store i64 %306, ptr %304, align 4
  %307 = add nuw nsw i64 %303, 1
  %308 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %307
  %309 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %307
  %310 = load i64, ptr %309, align 4
  store i64 %310, ptr %308, align 4
  %311 = add nuw nsw i64 %303, 2
  %312 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %311
  %313 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %311
  %314 = load i64, ptr %313, align 4
  store i64 %314, ptr %312, align 4
  %315 = add nuw nsw i64 %303, 3
  %316 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %315
  %317 = getelementptr inbounds nuw [8 x i8], ptr %2, i64 %315
  %318 = load i64, ptr %317, align 4
  store i64 %318, ptr %316, align 4
  %319 = add nuw nsw i64 %303, 4
  %320 = icmp eq i64 %319, %13
  br i1 %320, label %321, label %302, !llvm.loop !43

321:                                              ; preds = %299, %302, %283
  %322 = shl nsw i32 %35, 1
  %323 = icmp sgt i32 %322, %8
  br i1 %323, label %324, label %34, !llvm.loop !44

324:                                              ; preds = %321
  %325 = icmp slt i32 %0, 1
  br i1 %325, label %362, label %326

326:                                              ; preds = %324
  %327 = fneg float %4
  %328 = add nuw i32 %0, 1
  %329 = zext i32 %328 to i64
  %330 = zext nneg i32 %0 to i64
  %331 = icmp eq i32 %0, 1
  br i1 %331, label %351, label %332

332:                                              ; preds = %326
  %333 = and i64 %330, 2147483646
  %334 = or i64 %330, 1
  %335 = insertelement <2 x float> poison, float %327, i64 0
  %336 = insertelement <2 x float> poison, float %4, i64 0
  br label %337

337:                                              ; preds = %337, %332
  %338 = phi i64 [ 0, %332 ], [ %347, %337 ]
  %339 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %338
  %340 = getelementptr inbounds nuw i8, ptr %339, i64 8
  %341 = load <4 x float>, ptr %340, align 4, !tbaa !18
  %342 = shufflevector <4 x float> %341, <4 x float> poison, <2 x i32> <i32 0, i32 2>
  %343 = shufflevector <4 x float> %341, <4 x float> poison, <2 x i32> <i32 1, i32 3>
  %344 = shufflevector <2 x float> %336, <2 x float> %343, <4 x i32> <i32 0, i32 2, i32 0, i32 3>
  %345 = shufflevector <2 x float> %342, <2 x float> %335, <4 x i32> <i32 0, i32 2, i32 1, i32 2>
  %346 = fmul <4 x float> %344, %345
  store <4 x float> %346, ptr %340, align 4, !tbaa !18
  %347 = add nuw i64 %338, 2
  %348 = icmp eq i64 %347, %333
  br i1 %348, label %349, label %337, !llvm.loop !45

349:                                              ; preds = %337
  %350 = icmp eq i64 %333, %330
  br i1 %350, label %362, label %351

351:                                              ; preds = %326, %349
  %352 = phi i64 [ 1, %326 ], [ %334, %349 ]
  %353 = insertelement <2 x float> poison, float %4, i64 0
  %354 = insertelement <2 x float> %353, float %327, i64 1
  br label %355

355:                                              ; preds = %351, %355
  %356 = phi i64 [ %360, %355 ], [ %352, %351 ]
  %357 = getelementptr inbounds nuw [8 x i8], ptr %1, i64 %356
  %358 = load <2 x float>, ptr %357, align 4, !tbaa !18
  %359 = fmul <2 x float> %358, %354
  store <2 x float> %359, ptr %357, align 4, !tbaa !18
  %360 = add nuw nsw i64 %356, 1
  %361 = icmp eq i64 %360, %329
  br i1 %361, label %362, label %355, !llvm.loop !46

362:                                              ; preds = %355, %349, %324
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #8

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #3

; Function Attrs: nofree nounwind uwtable
define dso_local void @Oscar() local_unnamed_addr #4 {
  tail call void @Exptab(i32 noundef 256, ptr noundef nonnull @e)
  br label %5

1:                                                ; preds = %5
  %2 = zext nneg i32 %13 to i64
  store i64 %2, ptr @seed, align 8, !tbaa !9
  %3 = extractelement <2 x float> %19, i64 0
  store float %3, ptr @zr, align 4, !tbaa !18
  %4 = extractelement <2 x float> %19, i64 1
  store float %4, ptr @zi, align 4, !tbaa !18
  br label %23

5:                                                ; preds = %0, %5
  %6 = phi i64 [ 1, %0 ], [ %21, %5 ]
  %7 = phi i32 [ 5767, %0 ], [ %13, %5 ]
  %8 = mul nuw nsw i32 %7, 4855
  %9 = getelementptr inbounds nuw [8 x i8], ptr @z, i64 %6
  %10 = add nuw nsw i32 %8, 1731
  %11 = mul i32 %10, 4855
  %12 = add i32 %11, 1731
  %13 = and i32 %12, 8191
  %14 = and i32 %10, 8191
  %15 = uitofp nneg i32 %13 to float
  %16 = uitofp nneg i32 %14 to float
  %17 = insertelement <2 x float> poison, float %16, i64 0
  %18 = insertelement <2 x float> %17, float %15, i64 1
  %19 = fmul nnan <2 x float> %18, splat (float f0x39000000)
  %20 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %19, <2 x float> splat (float 2.000000e+01), <2 x float> splat (float -1.000000e+01))
  store <2 x float> %20, ptr %9, align 8, !tbaa !18
  %21 = add nuw nsw i64 %6, 1
  %22 = icmp eq i64 %21, 257
  br i1 %22, label %1, label %5, !llvm.loop !47

23:                                               ; preds = %1, %178
  %24 = phi i32 [ 1, %1 ], [ %179, %178 ]
  br label %25

25:                                               ; preds = %23, %155
  %26 = phi i32 [ %156, %155 ], [ 1, %23 ]
  %27 = zext nneg i32 %26 to i64
  %28 = shl nuw nsw i64 %27, 3
  %29 = shl nuw nsw i64 %27, 3
  %30 = shl nuw nsw i64 %27, 3
  %31 = getelementptr i8, ptr @w, i64 %28
  %32 = getelementptr i8, ptr @w, i64 %28
  %33 = getelementptr i8, ptr %32, i64 4
  %34 = getelementptr i8, ptr @w, i64 %28
  %35 = getelementptr i8, ptr %34, i64 8
  %36 = getelementptr i8, ptr @w, i64 %28
  br label %37

37:                                               ; preds = %151, %25
  %38 = phi i64 [ %154, %151 ], [ 0, %25 ]
  %39 = phi i64 [ %152, %151 ], [ %27, %25 ]
  %40 = phi i64 [ %39, %151 ], [ 0, %25 ]
  %41 = phi i64 [ %54, %151 ], [ 1, %25 ]
  %42 = mul i64 %30, %38
  %43 = getelementptr i8, ptr %31, i64 %42
  %44 = getelementptr i8, ptr %33, i64 %42
  %45 = getelementptr i8, ptr %35, i64 %42
  %46 = getelementptr [8 x i8], ptr @e, i64 %40
  %47 = getelementptr i8, ptr %46, i64 8
  %48 = getelementptr i8, ptr %46, i64 12
  %49 = getelementptr [8 x i8], ptr @w, i64 %40
  %50 = getelementptr [8 x i8], ptr @w, i64 %39
  %51 = load float, ptr %47, align 8, !tbaa !11
  %52 = load float, ptr %48, align 4, !tbaa !14
  %53 = tail call i64 @llvm.smax.i64(i64 %41, i64 %39)
  %54 = add nuw i64 %53, 1
  %55 = sub i64 %53, %41
  %56 = add i64 %55, 1
  %57 = icmp ult i64 %56, 12
  br i1 %57, label %129, label %58

58:                                               ; preds = %37
  %59 = mul i64 %29, %38
  %60 = getelementptr i8, ptr %36, i64 %59
  %61 = sub i64 %53, %41
  %62 = shl i64 %41, 3
  %63 = add i64 %40, %41
  %64 = shl i64 %63, 3
  %65 = getelementptr i8, ptr @w, i64 %64
  %66 = shl i64 %61, 3
  %67 = getelementptr i8, ptr %65, i64 %66
  %68 = icmp ult ptr %67, %65
  %69 = getelementptr i8, ptr %60, i64 %62
  %70 = shl i64 %61, 3
  %71 = icmp ugt i64 %61, 2305843009213693951
  %72 = getelementptr i8, ptr %69, i64 %70
  %73 = icmp ult ptr %72, %69
  %74 = or i1 %73, %71
  %75 = or i1 %68, %74
  br i1 %75, label %129, label %76

76:                                               ; preds = %58
  %77 = shl i64 %41, 3
  %78 = add i64 %40, %41
  %79 = shl i64 %78, 3
  %80 = getelementptr i8, ptr @w, i64 %79
  %81 = add i64 %40, %53
  %82 = shl i64 %81, 3
  %83 = getelementptr i8, ptr getelementptr inbounds nuw (i8, ptr @w, i64 4), i64 %82
  %84 = getelementptr i8, ptr %43, i64 %77
  %85 = shl i64 %53, 3
  %86 = getelementptr i8, ptr %44, i64 %85
  %87 = getelementptr i8, ptr getelementptr inbounds nuw (i8, ptr @w, i64 4), i64 %79
  %88 = getelementptr i8, ptr getelementptr inbounds nuw (i8, ptr @w, i64 8), i64 %82
  %89 = getelementptr i8, ptr %44, i64 %77
  %90 = getelementptr i8, ptr %45, i64 %85
  %91 = icmp ult ptr %80, %86
  %92 = icmp ult ptr %84, %83
  %93 = and i1 %91, %92
  %94 = icmp ult ptr %87, %90
  %95 = icmp ult ptr %89, %88
  %96 = and i1 %94, %95
  %97 = or i1 %93, %96
  br i1 %97, label %129, label %98

98:                                               ; preds = %76
  %99 = and i64 %56, -4
  %100 = add i64 %41, %99
  %101 = insertelement <4 x float> poison, float %51, i64 0
  %102 = shufflevector <4 x float> %101, <4 x float> poison, <4 x i32> zeroinitializer
  %103 = insertelement <4 x float> poison, float %52, i64 0
  %104 = shufflevector <4 x float> %103, <4 x float> poison, <4 x i32> zeroinitializer
  br label %105

105:                                              ; preds = %105, %98
  %106 = phi i64 [ 0, %98 ], [ %125, %105 ]
  %107 = add i64 %41, %106
  %108 = getelementptr inbounds [8 x i8], ptr @z, i64 %107
  %109 = load <8 x float>, ptr %108, align 8, !tbaa !18
  %110 = getelementptr [8 x i8], ptr getelementptr inbounds nuw (i8, ptr @z, i64 1024), i64 %107
  %111 = load <8 x float>, ptr %110, align 8, !tbaa !18
  %112 = getelementptr [8 x i8], ptr %49, i64 %107
  %113 = fadd <8 x float> %109, %111
  store <8 x float> %113, ptr %112, align 8, !tbaa !18
  %114 = fsub <8 x float> %109, %111
  %115 = shufflevector <8 x float> %114, <8 x float> poison, <4 x i32> <i32 0, i32 2, i32 4, i32 6>
  %116 = fsub <8 x float> %109, %111
  %117 = shufflevector <8 x float> %116, <8 x float> poison, <4 x i32> <i32 1, i32 3, i32 5, i32 7>
  %118 = fneg <4 x float> %117
  %119 = fmul <4 x float> %104, %118
  %120 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %102, <4 x float> %115, <4 x float> %119)
  %121 = getelementptr [8 x i8], ptr %50, i64 %107
  %122 = fmul <4 x float> %115, %104
  %123 = tail call <4 x float> @llvm.fmuladd.v4f32(<4 x float> %102, <4 x float> %117, <4 x float> %122)
  %124 = shufflevector <4 x float> %120, <4 x float> %123, <8 x i32> <i32 0, i32 4, i32 1, i32 5, i32 2, i32 6, i32 3, i32 7>
  store <8 x float> %124, ptr %121, align 8, !tbaa !18
  %125 = add nuw i64 %106, 4
  %126 = icmp eq i64 %125, %99
  br i1 %126, label %127, label %105, !llvm.loop !48

127:                                              ; preds = %105
  %128 = icmp eq i64 %56, %99
  br i1 %128, label %151, label %129

129:                                              ; preds = %76, %58, %37, %127
  %130 = phi i64 [ %41, %76 ], [ %41, %58 ], [ %41, %37 ], [ %100, %127 ]
  %131 = insertelement <2 x float> poison, float %52, i64 0
  %132 = shufflevector <2 x float> %131, <2 x float> poison, <2 x i32> zeroinitializer
  %133 = insertelement <2 x float> poison, float %51, i64 0
  %134 = shufflevector <2 x float> %133, <2 x float> poison, <2 x i32> zeroinitializer
  br label %135

135:                                              ; preds = %129, %135
  %136 = phi i64 [ %149, %135 ], [ %130, %129 ]
  %137 = getelementptr inbounds [8 x i8], ptr @z, i64 %136
  %138 = getelementptr [8 x i8], ptr getelementptr inbounds nuw (i8, ptr @z, i64 1024), i64 %136
  %139 = getelementptr [8 x i8], ptr %49, i64 %136
  %140 = load <2 x float>, ptr %137, align 8, !tbaa !18
  %141 = load <2 x float>, ptr %138, align 8, !tbaa !18
  %142 = fadd <2 x float> %140, %141
  store <2 x float> %142, ptr %139, align 8, !tbaa !18
  %143 = getelementptr [8 x i8], ptr %50, i64 %136
  %144 = fsub <2 x float> %140, %141
  %145 = fneg <2 x float> %144
  %146 = shufflevector <2 x float> %145, <2 x float> %144, <2 x i32> <i32 1, i32 2>
  %147 = fmul <2 x float> %132, %146
  %148 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %134, <2 x float> %144, <2 x float> %147)
  store <2 x float> %148, ptr %143, align 8, !tbaa !18
  %149 = add i64 %136, 1
  %150 = icmp eq i64 %136, %53
  br i1 %150, label %151, label %135, !llvm.loop !49

151:                                              ; preds = %135, %127
  %152 = add nuw nsw i64 %39, %27
  %153 = icmp samesign ugt i64 %152, 128
  %154 = add i64 %38, 1
  br i1 %153, label %155, label %37, !llvm.loop !39

155:                                              ; preds = %151
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(2048) getelementptr inbounds nuw (i8, ptr @z, i64 8), ptr noundef nonnull align 8 dereferenceable(2048) getelementptr inbounds nuw (i8, ptr @w, i64 8), i64 2048, i1 false)
  %156 = shl nuw nsw i32 %26, 1
  %157 = icmp samesign ugt i32 %26, 64
  br i1 %157, label %158, label %25, !llvm.loop !44

158:                                              ; preds = %155, %158
  %159 = phi i64 [ %176, %158 ], [ 0, %155 ]
  %160 = getelementptr inbounds nuw [8 x i8], ptr @z, i64 %159
  %161 = getelementptr inbounds nuw i8, ptr %160, i64 8
  %162 = load <4 x float>, ptr %161, align 8, !tbaa !18
  %163 = fmul <4 x float> %162, <float 6.250000e-02, float -6.250000e-02, float 6.250000e-02, float -6.250000e-02>
  store <4 x float> %163, ptr %161, align 8, !tbaa !18
  %164 = getelementptr inbounds nuw [8 x i8], ptr @z, i64 %159
  %165 = getelementptr inbounds nuw i8, ptr %164, i64 24
  %166 = load <4 x float>, ptr %165, align 8, !tbaa !18
  %167 = fmul <4 x float> %166, <float 6.250000e-02, float -6.250000e-02, float 6.250000e-02, float -6.250000e-02>
  store <4 x float> %167, ptr %165, align 8, !tbaa !18
  %168 = getelementptr inbounds nuw [8 x i8], ptr @z, i64 %159
  %169 = getelementptr inbounds nuw i8, ptr %168, i64 40
  %170 = load <4 x float>, ptr %169, align 8, !tbaa !18
  %171 = fmul <4 x float> %170, <float 6.250000e-02, float -6.250000e-02, float 6.250000e-02, float -6.250000e-02>
  store <4 x float> %171, ptr %169, align 8, !tbaa !18
  %172 = getelementptr inbounds nuw [8 x i8], ptr @z, i64 %159
  %173 = getelementptr inbounds nuw i8, ptr %172, i64 56
  %174 = load <4 x float>, ptr %173, align 8, !tbaa !18
  %175 = fmul <4 x float> %174, <float 6.250000e-02, float -6.250000e-02, float 6.250000e-02, float -6.250000e-02>
  store <4 x float> %175, ptr %173, align 8, !tbaa !18
  %176 = add nuw nsw i64 %159, 8
  %177 = icmp eq i64 %176, 256
  br i1 %177, label %178, label %158, !llvm.loop !50

178:                                              ; preds = %158
  %179 = add nuw nsw i32 %24, 1
  %180 = icmp eq i32 %179, 21
  br i1 %180, label %181, label %23, !llvm.loop !51

181:                                              ; preds = %178
  %182 = tail call i32 @putchar(i32 10)
  %183 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 8), align 8, !tbaa !11
  %184 = fpext float %183 to double
  %185 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 12), align 4, !tbaa !14
  %186 = fpext float %185 to double
  %187 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %184, double noundef %186)
  %188 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 144), align 16, !tbaa !11
  %189 = fpext float %188 to double
  %190 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 148), align 4, !tbaa !14
  %191 = fpext float %190 to double
  %192 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %189, double noundef %191)
  %193 = tail call i32 @putchar(i32 10)
  %194 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 280), align 8, !tbaa !11
  %195 = fpext float %194 to double
  %196 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 284), align 4, !tbaa !14
  %197 = fpext float %196 to double
  %198 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %195, double noundef %197)
  %199 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 416), align 16, !tbaa !11
  %200 = fpext float %199 to double
  %201 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 420), align 4, !tbaa !14
  %202 = fpext float %201 to double
  %203 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %200, double noundef %202)
  %204 = tail call i32 @putchar(i32 10)
  %205 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 552), align 8, !tbaa !11
  %206 = fpext float %205 to double
  %207 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 556), align 4, !tbaa !14
  %208 = fpext float %207 to double
  %209 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %206, double noundef %208)
  %210 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 688), align 16, !tbaa !11
  %211 = fpext float %210 to double
  %212 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 692), align 4, !tbaa !14
  %213 = fpext float %212 to double
  %214 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %211, double noundef %213)
  %215 = tail call i32 @putchar(i32 10)
  %216 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 824), align 8, !tbaa !11
  %217 = fpext float %216 to double
  %218 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 828), align 4, !tbaa !14
  %219 = fpext float %218 to double
  %220 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %217, double noundef %219)
  %221 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 960), align 16, !tbaa !11
  %222 = fpext float %221 to double
  %223 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 964), align 4, !tbaa !14
  %224 = fpext float %223 to double
  %225 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %222, double noundef %224)
  %226 = tail call i32 @putchar(i32 10)
  %227 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1096), align 8, !tbaa !11
  %228 = fpext float %227 to double
  %229 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1100), align 4, !tbaa !14
  %230 = fpext float %229 to double
  %231 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %228, double noundef %230)
  %232 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1232), align 16, !tbaa !11
  %233 = fpext float %232 to double
  %234 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1236), align 4, !tbaa !14
  %235 = fpext float %234 to double
  %236 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %233, double noundef %235)
  %237 = tail call i32 @putchar(i32 10)
  %238 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1368), align 8, !tbaa !11
  %239 = fpext float %238 to double
  %240 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1372), align 4, !tbaa !14
  %241 = fpext float %240 to double
  %242 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %239, double noundef %241)
  %243 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1504), align 16, !tbaa !11
  %244 = fpext float %243 to double
  %245 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1508), align 4, !tbaa !14
  %246 = fpext float %245 to double
  %247 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %244, double noundef %246)
  %248 = tail call i32 @putchar(i32 10)
  %249 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1640), align 8, !tbaa !11
  %250 = fpext float %249 to double
  %251 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1644), align 4, !tbaa !14
  %252 = fpext float %251 to double
  %253 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %250, double noundef %252)
  %254 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1776), align 16, !tbaa !11
  %255 = fpext float %254 to double
  %256 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1780), align 4, !tbaa !14
  %257 = fpext float %256 to double
  %258 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %255, double noundef %257)
  %259 = tail call i32 @putchar(i32 10)
  %260 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1912), align 8, !tbaa !11
  %261 = fpext float %260 to double
  %262 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 1916), align 4, !tbaa !14
  %263 = fpext float %262 to double
  %264 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %261, double noundef %263)
  %265 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 2048), align 16, !tbaa !11
  %266 = fpext float %265 to double
  %267 = load float, ptr getelementptr inbounds nuw (i8, ptr @z, i64 2052), align 4, !tbaa !14
  %268 = fpext float %267 to double
  %269 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %266, double noundef %268)
  %270 = tail call i32 @putchar(i32 10)
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #4 {
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  tail call void @Oscar()
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #9

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smin.i32(i32, i32) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smax.i32(i32, i32) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.smax.i64(i64, i64) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <4 x float> @llvm.fmuladd.v4f32(<4 x float>, <4 x float>, <4 x float>) #10

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x float> @llvm.fmuladd.v2f32(<2 x float>, <2 x float>, <2 x float>) #10

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #9 = { nofree nounwind }
attributes #10 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!10 = !{!"long", !7, i64 0}
!11 = !{!12, !13, i64 0}
!12 = !{!"complex", !13, i64 0, !13, i64 4}
!13 = !{!"float", !7, i64 0}
!14 = !{!12, !13, i64 4}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{!6, !6, i64 0}
!18 = !{!13, !13, i64 0}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16, !21, !22}
!21 = !{!"llvm.loop.isvectorized", i32 1}
!22 = !{!"llvm.loop.unroll.runtime.disable"}
!23 = distinct !{!23, !16, !21}
!24 = distinct !{!24, !16}
!25 = !{!26}
!26 = distinct !{!26, !27}
!27 = distinct !{!27, !"LVerDomain"}
!28 = !{!29, !30}
!29 = distinct !{!29, !27}
!30 = distinct !{!30, !27}
!31 = !{!32}
!32 = distinct !{!32, !27}
!33 = !{!34}
!34 = distinct !{!34, !27}
!35 = !{!36}
!36 = distinct !{!36, !27}
!37 = distinct !{!37, !16, !21, !22}
!38 = distinct !{!38, !16, !21}
!39 = distinct !{!39, !16}
!40 = distinct !{!40, !16, !21, !22}
!41 = distinct !{!41, !42}
!42 = !{!"llvm.loop.unroll.disable"}
!43 = distinct !{!43, !16, !21}
!44 = distinct !{!44, !16}
!45 = distinct !{!45, !16, !21, !22}
!46 = distinct !{!46, !16, !22, !21}
!47 = distinct !{!47, !16}
!48 = distinct !{!48, !16, !21, !22}
!49 = distinct !{!49, !16, !21}
!50 = distinct !{!50, !16, !21, !22}
!51 = distinct !{!51, !16}
