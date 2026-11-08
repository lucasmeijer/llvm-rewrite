; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/himenobmtxpa.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.Mat = type { ptr, i32, i32, i32, i32 }
%struct.timeval = type { i64, i64 }

@omega = dso_local local_unnamed_addr global float 8.000000e-01, align 4
@.str = private unnamed_addr constant [34 x i8] c"mimax = %d mjmax = %d mkmax = %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [30 x i8] c"imax = %d jmax = %d kmax =%d\0A\00", align 1
@p = dso_local global %struct.Mat zeroinitializer, align 8
@bnd = dso_local global %struct.Mat zeroinitializer, align 8
@wrk1 = dso_local global %struct.Mat zeroinitializer, align 8
@wrk2 = dso_local global %struct.Mat zeroinitializer, align 8
@a = dso_local global %struct.Mat zeroinitializer, align 8
@b = dso_local global %struct.Mat zeroinitializer, align 8
@c = dso_local global %struct.Mat zeroinitializer, align 8
@.str.2 = private unnamed_addr constant [29 x i8] c" Loop executed for %d times\0A\00", align 1
@.str.3 = private unnamed_addr constant [13 x i8] c" Gosa : %e \0A\00", align 1
@second.base_sec = internal unnamed_addr global i32 0, align 4
@second.base_usec = internal unnamed_addr global i32 0, align 4
@str = private unnamed_addr constant [27 x i8] c"Invalid input character !!\00", align 1

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #0 {
  %3 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef 64, i32 noundef 64, i32 noundef 128)
  %4 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 63, i32 noundef 63, i32 noundef 127)
  store <4 x i32> <i32 1, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @p, i64 8), align 8, !tbaa !9
  %5 = tail call noalias dereferenceable_or_null(2097152) ptr @malloc(i64 noundef 2097152) #15
  store ptr %5, ptr @p, align 8, !tbaa !10
  store <4 x i32> <i32 1, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @bnd, i64 8), align 8, !tbaa !9
  %6 = tail call noalias dereferenceable_or_null(2097152) ptr @malloc(i64 noundef 2097152) #15
  store ptr %6, ptr @bnd, align 8, !tbaa !10
  store <4 x i32> <i32 1, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @wrk1, i64 8), align 8, !tbaa !9
  %7 = tail call noalias dereferenceable_or_null(2097152) ptr @malloc(i64 noundef 2097152) #15
  store ptr %7, ptr @wrk1, align 8, !tbaa !10
  store <4 x i32> <i32 1, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @wrk2, i64 8), align 8, !tbaa !9
  %8 = tail call noalias dereferenceable_or_null(2097152) ptr @malloc(i64 noundef 2097152) #15
  store ptr %8, ptr @wrk2, align 8, !tbaa !10
  store <4 x i32> <i32 4, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @a, i64 8), align 8, !tbaa !9
  %9 = tail call noalias dereferenceable_or_null(8388608) ptr @malloc(i64 noundef 8388608) #15
  store ptr %9, ptr @a, align 8, !tbaa !10
  store <4 x i32> <i32 3, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @b, i64 8), align 8, !tbaa !9
  %10 = tail call noalias dereferenceable_or_null(6291456) ptr @malloc(i64 noundef 6291456) #15
  store ptr %10, ptr @b, align 8, !tbaa !10
  store <4 x i32> <i32 3, i32 64, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @c, i64 8), align 8, !tbaa !9
  %11 = tail call noalias dereferenceable_or_null(6291456) ptr @malloc(i64 noundef 6291456) #15
  store ptr %11, ptr @c, align 8, !tbaa !10
  br label %12

12:                                               ; preds = %61, %2
  %13 = phi i64 [ 0, %2 ], [ %62, %61 ]
  %14 = mul nuw nsw i64 %13, %13
  %15 = trunc nuw i64 %14 to i32
  %16 = uitofp nneg i32 %15 to float
  %17 = fdiv float %16, 3.969000e+03
  %18 = shl nuw nsw i64 %13, 6
  %19 = insertelement <4 x float> poison, float %17, i64 0
  %20 = shufflevector <4 x float> %19, <4 x float> poison, <4 x i32> zeroinitializer
  br label %21

21:                                               ; preds = %21, %12
  %22 = phi i64 [ 0, %12 ], [ %59, %21 ]
  %23 = add nuw nsw i64 %22, %18
  %24 = trunc nuw i64 %23 to i32
  %25 = shl i32 %24, 7
  %26 = sext i32 %25 to i64
  %27 = getelementptr [4 x i8], ptr %5, i64 %26
  %28 = getelementptr i8, ptr %27, i64 16
  store <4 x float> %20, ptr %27, align 4, !tbaa !14
  store <4 x float> %20, ptr %28, align 4, !tbaa !14
  %29 = getelementptr i8, ptr %27, i64 32
  %30 = getelementptr i8, ptr %27, i64 48
  store <4 x float> %20, ptr %29, align 4, !tbaa !14
  store <4 x float> %20, ptr %30, align 4, !tbaa !14
  %31 = getelementptr i8, ptr %27, i64 64
  %32 = getelementptr i8, ptr %27, i64 80
  store <4 x float> %20, ptr %31, align 4, !tbaa !14
  store <4 x float> %20, ptr %32, align 4, !tbaa !14
  %33 = getelementptr i8, ptr %27, i64 96
  %34 = getelementptr i8, ptr %27, i64 112
  store <4 x float> %20, ptr %33, align 4, !tbaa !14
  store <4 x float> %20, ptr %34, align 4, !tbaa !14
  %35 = getelementptr i8, ptr %27, i64 128
  %36 = getelementptr i8, ptr %27, i64 144
  store <4 x float> %20, ptr %35, align 4, !tbaa !14
  store <4 x float> %20, ptr %36, align 4, !tbaa !14
  %37 = getelementptr i8, ptr %27, i64 160
  %38 = getelementptr i8, ptr %27, i64 176
  store <4 x float> %20, ptr %37, align 4, !tbaa !14
  store <4 x float> %20, ptr %38, align 4, !tbaa !14
  %39 = getelementptr i8, ptr %27, i64 192
  %40 = getelementptr i8, ptr %27, i64 208
  store <4 x float> %20, ptr %39, align 4, !tbaa !14
  store <4 x float> %20, ptr %40, align 4, !tbaa !14
  %41 = getelementptr i8, ptr %27, i64 224
  %42 = getelementptr i8, ptr %27, i64 240
  store <4 x float> %20, ptr %41, align 4, !tbaa !14
  store <4 x float> %20, ptr %42, align 4, !tbaa !14
  %43 = getelementptr i8, ptr %27, i64 256
  %44 = getelementptr i8, ptr %27, i64 272
  store <4 x float> %20, ptr %43, align 4, !tbaa !14
  store <4 x float> %20, ptr %44, align 4, !tbaa !14
  %45 = getelementptr i8, ptr %27, i64 288
  %46 = getelementptr i8, ptr %27, i64 304
  store <4 x float> %20, ptr %45, align 4, !tbaa !14
  store <4 x float> %20, ptr %46, align 4, !tbaa !14
  %47 = getelementptr i8, ptr %27, i64 320
  %48 = getelementptr i8, ptr %27, i64 336
  store <4 x float> %20, ptr %47, align 4, !tbaa !14
  store <4 x float> %20, ptr %48, align 4, !tbaa !14
  %49 = getelementptr i8, ptr %27, i64 352
  %50 = getelementptr i8, ptr %27, i64 368
  store <4 x float> %20, ptr %49, align 4, !tbaa !14
  store <4 x float> %20, ptr %50, align 4, !tbaa !14
  %51 = getelementptr i8, ptr %27, i64 384
  %52 = getelementptr i8, ptr %27, i64 400
  store <4 x float> %20, ptr %51, align 4, !tbaa !14
  store <4 x float> %20, ptr %52, align 4, !tbaa !14
  %53 = getelementptr i8, ptr %27, i64 416
  %54 = getelementptr i8, ptr %27, i64 432
  store <4 x float> %20, ptr %53, align 4, !tbaa !14
  store <4 x float> %20, ptr %54, align 4, !tbaa !14
  %55 = getelementptr i8, ptr %27, i64 448
  %56 = getelementptr i8, ptr %27, i64 464
  store <4 x float> %20, ptr %55, align 4, !tbaa !14
  store <4 x float> %20, ptr %56, align 4, !tbaa !14
  %57 = getelementptr i8, ptr %27, i64 480
  %58 = getelementptr i8, ptr %27, i64 496
  store <4 x float> %20, ptr %57, align 4, !tbaa !14
  store <4 x float> %20, ptr %58, align 4, !tbaa !14
  %59 = add nuw nsw i64 %22, 1
  %60 = icmp eq i64 %59, 64
  br i1 %60, label %61, label %21, !llvm.loop !16

61:                                               ; preds = %21
  %62 = add nuw nsw i64 %13, 1
  %63 = icmp eq i64 %62, 64
  br i1 %63, label %64, label %12, !llvm.loop !18

64:                                               ; preds = %61, %107
  %65 = phi i32 [ %108, %107 ], [ 0, %61 ]
  %66 = shl i32 %65, 13
  br label %67

67:                                               ; preds = %67, %64
  %68 = phi i64 [ 0, %64 ], [ %105, %67 ]
  %69 = trunc nuw nsw i64 %68 to i32
  %70 = shl i32 %69, 7
  %71 = add nuw nsw i32 %70, %66
  %72 = sext i32 %71 to i64
  %73 = getelementptr [4 x i8], ptr %6, i64 %72
  %74 = getelementptr i8, ptr %73, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %73, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %74, align 4, !tbaa !14
  %75 = getelementptr i8, ptr %73, i64 32
  %76 = getelementptr i8, ptr %73, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %75, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %76, align 4, !tbaa !14
  %77 = getelementptr i8, ptr %73, i64 64
  %78 = getelementptr i8, ptr %73, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %77, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %78, align 4, !tbaa !14
  %79 = getelementptr i8, ptr %73, i64 96
  %80 = getelementptr i8, ptr %73, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %79, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %80, align 4, !tbaa !14
  %81 = getelementptr i8, ptr %73, i64 128
  %82 = getelementptr i8, ptr %73, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %81, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %82, align 4, !tbaa !14
  %83 = getelementptr i8, ptr %73, i64 160
  %84 = getelementptr i8, ptr %73, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %83, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %84, align 4, !tbaa !14
  %85 = getelementptr i8, ptr %73, i64 192
  %86 = getelementptr i8, ptr %73, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %85, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %86, align 4, !tbaa !14
  %87 = getelementptr i8, ptr %73, i64 224
  %88 = getelementptr i8, ptr %73, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %87, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %88, align 4, !tbaa !14
  %89 = getelementptr i8, ptr %73, i64 256
  %90 = getelementptr i8, ptr %73, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %89, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %90, align 4, !tbaa !14
  %91 = getelementptr i8, ptr %73, i64 288
  %92 = getelementptr i8, ptr %73, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %91, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %92, align 4, !tbaa !14
  %93 = getelementptr i8, ptr %73, i64 320
  %94 = getelementptr i8, ptr %73, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %93, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %94, align 4, !tbaa !14
  %95 = getelementptr i8, ptr %73, i64 352
  %96 = getelementptr i8, ptr %73, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %95, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %96, align 4, !tbaa !14
  %97 = getelementptr i8, ptr %73, i64 384
  %98 = getelementptr i8, ptr %73, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %97, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %98, align 4, !tbaa !14
  %99 = getelementptr i8, ptr %73, i64 416
  %100 = getelementptr i8, ptr %73, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %99, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %100, align 4, !tbaa !14
  %101 = getelementptr i8, ptr %73, i64 448
  %102 = getelementptr i8, ptr %73, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %101, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %102, align 4, !tbaa !14
  %103 = getelementptr i8, ptr %73, i64 480
  %104 = getelementptr i8, ptr %73, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %103, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %104, align 4, !tbaa !14
  %105 = add nuw nsw i64 %68, 1
  %106 = icmp eq i64 %105, 64
  br i1 %106, label %107, label %67, !llvm.loop !19

107:                                              ; preds = %67
  %108 = add nuw nsw i32 %65, 1
  %109 = icmp eq i32 %108, 64
  br i1 %109, label %110, label %64, !llvm.loop !20

110:                                              ; preds = %107
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(2097152) %7, i8 0, i64 2097152, i1 false), !tbaa !14
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(2097152) %8, i8 0, i64 2097152, i1 false), !tbaa !14
  br label %111

111:                                              ; preds = %110, %154
  %112 = phi i32 [ %155, %154 ], [ 0, %110 ]
  %113 = shl i32 %112, 13
  br label %114

114:                                              ; preds = %114, %111
  %115 = phi i64 [ 0, %111 ], [ %152, %114 ]
  %116 = trunc nuw nsw i64 %115 to i32
  %117 = shl i32 %116, 7
  %118 = add nuw nsw i32 %117, %113
  %119 = sext i32 %118 to i64
  %120 = getelementptr [4 x i8], ptr %9, i64 %119
  %121 = getelementptr i8, ptr %120, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %120, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %121, align 4, !tbaa !14
  %122 = getelementptr i8, ptr %120, i64 32
  %123 = getelementptr i8, ptr %120, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %122, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %123, align 4, !tbaa !14
  %124 = getelementptr i8, ptr %120, i64 64
  %125 = getelementptr i8, ptr %120, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %124, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %125, align 4, !tbaa !14
  %126 = getelementptr i8, ptr %120, i64 96
  %127 = getelementptr i8, ptr %120, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %126, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %127, align 4, !tbaa !14
  %128 = getelementptr i8, ptr %120, i64 128
  %129 = getelementptr i8, ptr %120, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %128, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %129, align 4, !tbaa !14
  %130 = getelementptr i8, ptr %120, i64 160
  %131 = getelementptr i8, ptr %120, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %130, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %131, align 4, !tbaa !14
  %132 = getelementptr i8, ptr %120, i64 192
  %133 = getelementptr i8, ptr %120, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %132, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %133, align 4, !tbaa !14
  %134 = getelementptr i8, ptr %120, i64 224
  %135 = getelementptr i8, ptr %120, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %134, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %135, align 4, !tbaa !14
  %136 = getelementptr i8, ptr %120, i64 256
  %137 = getelementptr i8, ptr %120, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %136, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %137, align 4, !tbaa !14
  %138 = getelementptr i8, ptr %120, i64 288
  %139 = getelementptr i8, ptr %120, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %138, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %139, align 4, !tbaa !14
  %140 = getelementptr i8, ptr %120, i64 320
  %141 = getelementptr i8, ptr %120, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %140, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %141, align 4, !tbaa !14
  %142 = getelementptr i8, ptr %120, i64 352
  %143 = getelementptr i8, ptr %120, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %142, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %143, align 4, !tbaa !14
  %144 = getelementptr i8, ptr %120, i64 384
  %145 = getelementptr i8, ptr %120, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %144, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %145, align 4, !tbaa !14
  %146 = getelementptr i8, ptr %120, i64 416
  %147 = getelementptr i8, ptr %120, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %146, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %147, align 4, !tbaa !14
  %148 = getelementptr i8, ptr %120, i64 448
  %149 = getelementptr i8, ptr %120, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %148, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %149, align 4, !tbaa !14
  %150 = getelementptr i8, ptr %120, i64 480
  %151 = getelementptr i8, ptr %120, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %150, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %151, align 4, !tbaa !14
  %152 = add nuw nsw i64 %115, 1
  %153 = icmp eq i64 %152, 64
  br i1 %153, label %154, label %114, !llvm.loop !19

154:                                              ; preds = %114
  %155 = add nuw nsw i32 %112, 1
  %156 = icmp eq i32 %155, 64
  br i1 %156, label %157, label %111, !llvm.loop !20

157:                                              ; preds = %154, %201
  %158 = phi i32 [ %202, %201 ], [ 0, %154 ]
  %159 = shl i32 %158, 6
  %160 = add nuw nsw i32 %159, 4096
  br label %161

161:                                              ; preds = %161, %157
  %162 = phi i64 [ 0, %157 ], [ %199, %161 ]
  %163 = trunc nuw nsw i64 %162 to i32
  %164 = add nuw nsw i32 %160, %163
  %165 = shl i32 %164, 7
  %166 = sext i32 %165 to i64
  %167 = getelementptr [4 x i8], ptr %9, i64 %166
  %168 = getelementptr i8, ptr %167, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %167, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %168, align 4, !tbaa !14
  %169 = getelementptr i8, ptr %167, i64 32
  %170 = getelementptr i8, ptr %167, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %169, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %170, align 4, !tbaa !14
  %171 = getelementptr i8, ptr %167, i64 64
  %172 = getelementptr i8, ptr %167, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %171, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %172, align 4, !tbaa !14
  %173 = getelementptr i8, ptr %167, i64 96
  %174 = getelementptr i8, ptr %167, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %173, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %174, align 4, !tbaa !14
  %175 = getelementptr i8, ptr %167, i64 128
  %176 = getelementptr i8, ptr %167, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %175, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %176, align 4, !tbaa !14
  %177 = getelementptr i8, ptr %167, i64 160
  %178 = getelementptr i8, ptr %167, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %177, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %178, align 4, !tbaa !14
  %179 = getelementptr i8, ptr %167, i64 192
  %180 = getelementptr i8, ptr %167, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %179, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %180, align 4, !tbaa !14
  %181 = getelementptr i8, ptr %167, i64 224
  %182 = getelementptr i8, ptr %167, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %181, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %182, align 4, !tbaa !14
  %183 = getelementptr i8, ptr %167, i64 256
  %184 = getelementptr i8, ptr %167, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %183, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %184, align 4, !tbaa !14
  %185 = getelementptr i8, ptr %167, i64 288
  %186 = getelementptr i8, ptr %167, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %185, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %186, align 4, !tbaa !14
  %187 = getelementptr i8, ptr %167, i64 320
  %188 = getelementptr i8, ptr %167, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %187, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %188, align 4, !tbaa !14
  %189 = getelementptr i8, ptr %167, i64 352
  %190 = getelementptr i8, ptr %167, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %189, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %190, align 4, !tbaa !14
  %191 = getelementptr i8, ptr %167, i64 384
  %192 = getelementptr i8, ptr %167, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %191, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %192, align 4, !tbaa !14
  %193 = getelementptr i8, ptr %167, i64 416
  %194 = getelementptr i8, ptr %167, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %193, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %194, align 4, !tbaa !14
  %195 = getelementptr i8, ptr %167, i64 448
  %196 = getelementptr i8, ptr %167, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %195, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %196, align 4, !tbaa !14
  %197 = getelementptr i8, ptr %167, i64 480
  %198 = getelementptr i8, ptr %167, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %197, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %198, align 4, !tbaa !14
  %199 = add nuw nsw i64 %162, 1
  %200 = icmp eq i64 %199, 64
  br i1 %200, label %201, label %161, !llvm.loop !19

201:                                              ; preds = %161
  %202 = add nuw nsw i32 %158, 1
  %203 = icmp eq i32 %202, 64
  br i1 %203, label %204, label %157, !llvm.loop !20

204:                                              ; preds = %201, %248
  %205 = phi i32 [ %249, %248 ], [ 0, %201 ]
  %206 = shl i32 %205, 6
  %207 = add nuw nsw i32 %206, 8192
  br label %208

208:                                              ; preds = %208, %204
  %209 = phi i64 [ 0, %204 ], [ %246, %208 ]
  %210 = trunc nuw nsw i64 %209 to i32
  %211 = add nuw nsw i32 %207, %210
  %212 = shl i32 %211, 7
  %213 = sext i32 %212 to i64
  %214 = getelementptr [4 x i8], ptr %9, i64 %213
  %215 = getelementptr i8, ptr %214, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %214, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %215, align 4, !tbaa !14
  %216 = getelementptr i8, ptr %214, i64 32
  %217 = getelementptr i8, ptr %214, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %216, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %217, align 4, !tbaa !14
  %218 = getelementptr i8, ptr %214, i64 64
  %219 = getelementptr i8, ptr %214, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %218, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %219, align 4, !tbaa !14
  %220 = getelementptr i8, ptr %214, i64 96
  %221 = getelementptr i8, ptr %214, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %220, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %221, align 4, !tbaa !14
  %222 = getelementptr i8, ptr %214, i64 128
  %223 = getelementptr i8, ptr %214, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %222, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %223, align 4, !tbaa !14
  %224 = getelementptr i8, ptr %214, i64 160
  %225 = getelementptr i8, ptr %214, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %224, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %225, align 4, !tbaa !14
  %226 = getelementptr i8, ptr %214, i64 192
  %227 = getelementptr i8, ptr %214, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %226, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %227, align 4, !tbaa !14
  %228 = getelementptr i8, ptr %214, i64 224
  %229 = getelementptr i8, ptr %214, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %228, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %229, align 4, !tbaa !14
  %230 = getelementptr i8, ptr %214, i64 256
  %231 = getelementptr i8, ptr %214, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %230, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %231, align 4, !tbaa !14
  %232 = getelementptr i8, ptr %214, i64 288
  %233 = getelementptr i8, ptr %214, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %232, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %233, align 4, !tbaa !14
  %234 = getelementptr i8, ptr %214, i64 320
  %235 = getelementptr i8, ptr %214, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %234, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %235, align 4, !tbaa !14
  %236 = getelementptr i8, ptr %214, i64 352
  %237 = getelementptr i8, ptr %214, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %236, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %237, align 4, !tbaa !14
  %238 = getelementptr i8, ptr %214, i64 384
  %239 = getelementptr i8, ptr %214, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %238, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %239, align 4, !tbaa !14
  %240 = getelementptr i8, ptr %214, i64 416
  %241 = getelementptr i8, ptr %214, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %240, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %241, align 4, !tbaa !14
  %242 = getelementptr i8, ptr %214, i64 448
  %243 = getelementptr i8, ptr %214, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %242, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %243, align 4, !tbaa !14
  %244 = getelementptr i8, ptr %214, i64 480
  %245 = getelementptr i8, ptr %214, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %244, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %245, align 4, !tbaa !14
  %246 = add nuw nsw i64 %209, 1
  %247 = icmp eq i64 %246, 64
  br i1 %247, label %248, label %208, !llvm.loop !19

248:                                              ; preds = %208
  %249 = add nuw nsw i32 %205, 1
  %250 = icmp eq i32 %249, 64
  br i1 %250, label %251, label %204, !llvm.loop !20

251:                                              ; preds = %248, %295
  %252 = phi i32 [ %296, %295 ], [ 0, %248 ]
  %253 = shl i32 %252, 6
  %254 = add nuw nsw i32 %253, 12288
  br label %255

255:                                              ; preds = %255, %251
  %256 = phi i64 [ 0, %251 ], [ %293, %255 ]
  %257 = trunc nuw nsw i64 %256 to i32
  %258 = add nuw nsw i32 %254, %257
  %259 = shl i32 %258, 7
  %260 = sext i32 %259 to i64
  %261 = getelementptr [4 x i8], ptr %9, i64 %260
  %262 = getelementptr i8, ptr %261, i64 16
  store <4 x float> splat (float f0x3E2AAAAB), ptr %261, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %262, align 4, !tbaa !14
  %263 = getelementptr i8, ptr %261, i64 32
  %264 = getelementptr i8, ptr %261, i64 48
  store <4 x float> splat (float f0x3E2AAAAB), ptr %263, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %264, align 4, !tbaa !14
  %265 = getelementptr i8, ptr %261, i64 64
  %266 = getelementptr i8, ptr %261, i64 80
  store <4 x float> splat (float f0x3E2AAAAB), ptr %265, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %266, align 4, !tbaa !14
  %267 = getelementptr i8, ptr %261, i64 96
  %268 = getelementptr i8, ptr %261, i64 112
  store <4 x float> splat (float f0x3E2AAAAB), ptr %267, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %268, align 4, !tbaa !14
  %269 = getelementptr i8, ptr %261, i64 128
  %270 = getelementptr i8, ptr %261, i64 144
  store <4 x float> splat (float f0x3E2AAAAB), ptr %269, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %270, align 4, !tbaa !14
  %271 = getelementptr i8, ptr %261, i64 160
  %272 = getelementptr i8, ptr %261, i64 176
  store <4 x float> splat (float f0x3E2AAAAB), ptr %271, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %272, align 4, !tbaa !14
  %273 = getelementptr i8, ptr %261, i64 192
  %274 = getelementptr i8, ptr %261, i64 208
  store <4 x float> splat (float f0x3E2AAAAB), ptr %273, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %274, align 4, !tbaa !14
  %275 = getelementptr i8, ptr %261, i64 224
  %276 = getelementptr i8, ptr %261, i64 240
  store <4 x float> splat (float f0x3E2AAAAB), ptr %275, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %276, align 4, !tbaa !14
  %277 = getelementptr i8, ptr %261, i64 256
  %278 = getelementptr i8, ptr %261, i64 272
  store <4 x float> splat (float f0x3E2AAAAB), ptr %277, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %278, align 4, !tbaa !14
  %279 = getelementptr i8, ptr %261, i64 288
  %280 = getelementptr i8, ptr %261, i64 304
  store <4 x float> splat (float f0x3E2AAAAB), ptr %279, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %280, align 4, !tbaa !14
  %281 = getelementptr i8, ptr %261, i64 320
  %282 = getelementptr i8, ptr %261, i64 336
  store <4 x float> splat (float f0x3E2AAAAB), ptr %281, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %282, align 4, !tbaa !14
  %283 = getelementptr i8, ptr %261, i64 352
  %284 = getelementptr i8, ptr %261, i64 368
  store <4 x float> splat (float f0x3E2AAAAB), ptr %283, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %284, align 4, !tbaa !14
  %285 = getelementptr i8, ptr %261, i64 384
  %286 = getelementptr i8, ptr %261, i64 400
  store <4 x float> splat (float f0x3E2AAAAB), ptr %285, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %286, align 4, !tbaa !14
  %287 = getelementptr i8, ptr %261, i64 416
  %288 = getelementptr i8, ptr %261, i64 432
  store <4 x float> splat (float f0x3E2AAAAB), ptr %287, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %288, align 4, !tbaa !14
  %289 = getelementptr i8, ptr %261, i64 448
  %290 = getelementptr i8, ptr %261, i64 464
  store <4 x float> splat (float f0x3E2AAAAB), ptr %289, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %290, align 4, !tbaa !14
  %291 = getelementptr i8, ptr %261, i64 480
  %292 = getelementptr i8, ptr %261, i64 496
  store <4 x float> splat (float f0x3E2AAAAB), ptr %291, align 4, !tbaa !14
  store <4 x float> splat (float f0x3E2AAAAB), ptr %292, align 4, !tbaa !14
  %293 = add nuw nsw i64 %256, 1
  %294 = icmp eq i64 %293, 64
  br i1 %294, label %295, label %255, !llvm.loop !19

295:                                              ; preds = %255
  %296 = add nuw nsw i32 %252, 1
  %297 = icmp eq i32 %296, 64
  br i1 %297, label %298, label %251, !llvm.loop !20

298:                                              ; preds = %295
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(6291456) %10, i8 0, i64 6291456, i1 false)
  br label %299

299:                                              ; preds = %298, %342
  %300 = phi i32 [ %343, %342 ], [ 0, %298 ]
  %301 = shl i32 %300, 13
  br label %302

302:                                              ; preds = %302, %299
  %303 = phi i64 [ 0, %299 ], [ %340, %302 ]
  %304 = trunc nuw nsw i64 %303 to i32
  %305 = shl i32 %304, 7
  %306 = add nuw nsw i32 %305, %301
  %307 = sext i32 %306 to i64
  %308 = getelementptr [4 x i8], ptr %11, i64 %307
  %309 = getelementptr i8, ptr %308, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %308, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %309, align 4, !tbaa !14
  %310 = getelementptr i8, ptr %308, i64 32
  %311 = getelementptr i8, ptr %308, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %310, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %311, align 4, !tbaa !14
  %312 = getelementptr i8, ptr %308, i64 64
  %313 = getelementptr i8, ptr %308, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %312, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %313, align 4, !tbaa !14
  %314 = getelementptr i8, ptr %308, i64 96
  %315 = getelementptr i8, ptr %308, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %314, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %315, align 4, !tbaa !14
  %316 = getelementptr i8, ptr %308, i64 128
  %317 = getelementptr i8, ptr %308, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %316, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %317, align 4, !tbaa !14
  %318 = getelementptr i8, ptr %308, i64 160
  %319 = getelementptr i8, ptr %308, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %318, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %319, align 4, !tbaa !14
  %320 = getelementptr i8, ptr %308, i64 192
  %321 = getelementptr i8, ptr %308, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %320, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %321, align 4, !tbaa !14
  %322 = getelementptr i8, ptr %308, i64 224
  %323 = getelementptr i8, ptr %308, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %322, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %323, align 4, !tbaa !14
  %324 = getelementptr i8, ptr %308, i64 256
  %325 = getelementptr i8, ptr %308, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %324, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %325, align 4, !tbaa !14
  %326 = getelementptr i8, ptr %308, i64 288
  %327 = getelementptr i8, ptr %308, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %326, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %327, align 4, !tbaa !14
  %328 = getelementptr i8, ptr %308, i64 320
  %329 = getelementptr i8, ptr %308, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %328, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %329, align 4, !tbaa !14
  %330 = getelementptr i8, ptr %308, i64 352
  %331 = getelementptr i8, ptr %308, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %330, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %331, align 4, !tbaa !14
  %332 = getelementptr i8, ptr %308, i64 384
  %333 = getelementptr i8, ptr %308, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %332, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %333, align 4, !tbaa !14
  %334 = getelementptr i8, ptr %308, i64 416
  %335 = getelementptr i8, ptr %308, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %334, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %335, align 4, !tbaa !14
  %336 = getelementptr i8, ptr %308, i64 448
  %337 = getelementptr i8, ptr %308, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %336, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %337, align 4, !tbaa !14
  %338 = getelementptr i8, ptr %308, i64 480
  %339 = getelementptr i8, ptr %308, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %338, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %339, align 4, !tbaa !14
  %340 = add nuw nsw i64 %303, 1
  %341 = icmp eq i64 %340, 64
  br i1 %341, label %342, label %302, !llvm.loop !19

342:                                              ; preds = %302
  %343 = add nuw nsw i32 %300, 1
  %344 = icmp eq i32 %343, 64
  br i1 %344, label %345, label %299, !llvm.loop !20

345:                                              ; preds = %342, %389
  %346 = phi i32 [ %390, %389 ], [ 0, %342 ]
  %347 = shl i32 %346, 6
  %348 = add nuw nsw i32 %347, 4096
  br label %349

349:                                              ; preds = %349, %345
  %350 = phi i64 [ 0, %345 ], [ %387, %349 ]
  %351 = trunc nuw nsw i64 %350 to i32
  %352 = add nuw nsw i32 %348, %351
  %353 = shl i32 %352, 7
  %354 = sext i32 %353 to i64
  %355 = getelementptr [4 x i8], ptr %11, i64 %354
  %356 = getelementptr i8, ptr %355, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %355, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %356, align 4, !tbaa !14
  %357 = getelementptr i8, ptr %355, i64 32
  %358 = getelementptr i8, ptr %355, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %357, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %358, align 4, !tbaa !14
  %359 = getelementptr i8, ptr %355, i64 64
  %360 = getelementptr i8, ptr %355, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %359, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %360, align 4, !tbaa !14
  %361 = getelementptr i8, ptr %355, i64 96
  %362 = getelementptr i8, ptr %355, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %361, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %362, align 4, !tbaa !14
  %363 = getelementptr i8, ptr %355, i64 128
  %364 = getelementptr i8, ptr %355, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %363, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %364, align 4, !tbaa !14
  %365 = getelementptr i8, ptr %355, i64 160
  %366 = getelementptr i8, ptr %355, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %365, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %366, align 4, !tbaa !14
  %367 = getelementptr i8, ptr %355, i64 192
  %368 = getelementptr i8, ptr %355, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %367, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %368, align 4, !tbaa !14
  %369 = getelementptr i8, ptr %355, i64 224
  %370 = getelementptr i8, ptr %355, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %369, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %370, align 4, !tbaa !14
  %371 = getelementptr i8, ptr %355, i64 256
  %372 = getelementptr i8, ptr %355, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %371, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %372, align 4, !tbaa !14
  %373 = getelementptr i8, ptr %355, i64 288
  %374 = getelementptr i8, ptr %355, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %373, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %374, align 4, !tbaa !14
  %375 = getelementptr i8, ptr %355, i64 320
  %376 = getelementptr i8, ptr %355, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %375, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %376, align 4, !tbaa !14
  %377 = getelementptr i8, ptr %355, i64 352
  %378 = getelementptr i8, ptr %355, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %377, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %378, align 4, !tbaa !14
  %379 = getelementptr i8, ptr %355, i64 384
  %380 = getelementptr i8, ptr %355, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %379, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %380, align 4, !tbaa !14
  %381 = getelementptr i8, ptr %355, i64 416
  %382 = getelementptr i8, ptr %355, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %381, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %382, align 4, !tbaa !14
  %383 = getelementptr i8, ptr %355, i64 448
  %384 = getelementptr i8, ptr %355, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %383, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %384, align 4, !tbaa !14
  %385 = getelementptr i8, ptr %355, i64 480
  %386 = getelementptr i8, ptr %355, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %385, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %386, align 4, !tbaa !14
  %387 = add nuw nsw i64 %350, 1
  %388 = icmp eq i64 %387, 64
  br i1 %388, label %389, label %349, !llvm.loop !19

389:                                              ; preds = %349
  %390 = add nuw nsw i32 %346, 1
  %391 = icmp eq i32 %390, 64
  br i1 %391, label %392, label %345, !llvm.loop !20

392:                                              ; preds = %389, %436
  %393 = phi i32 [ %437, %436 ], [ 0, %389 ]
  %394 = shl i32 %393, 6
  %395 = add nuw nsw i32 %394, 8192
  br label %396

396:                                              ; preds = %396, %392
  %397 = phi i64 [ 0, %392 ], [ %434, %396 ]
  %398 = trunc nuw nsw i64 %397 to i32
  %399 = add nuw nsw i32 %395, %398
  %400 = shl i32 %399, 7
  %401 = sext i32 %400 to i64
  %402 = getelementptr [4 x i8], ptr %11, i64 %401
  %403 = getelementptr i8, ptr %402, i64 16
  store <4 x float> splat (float 1.000000e+00), ptr %402, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %403, align 4, !tbaa !14
  %404 = getelementptr i8, ptr %402, i64 32
  %405 = getelementptr i8, ptr %402, i64 48
  store <4 x float> splat (float 1.000000e+00), ptr %404, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %405, align 4, !tbaa !14
  %406 = getelementptr i8, ptr %402, i64 64
  %407 = getelementptr i8, ptr %402, i64 80
  store <4 x float> splat (float 1.000000e+00), ptr %406, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %407, align 4, !tbaa !14
  %408 = getelementptr i8, ptr %402, i64 96
  %409 = getelementptr i8, ptr %402, i64 112
  store <4 x float> splat (float 1.000000e+00), ptr %408, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %409, align 4, !tbaa !14
  %410 = getelementptr i8, ptr %402, i64 128
  %411 = getelementptr i8, ptr %402, i64 144
  store <4 x float> splat (float 1.000000e+00), ptr %410, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %411, align 4, !tbaa !14
  %412 = getelementptr i8, ptr %402, i64 160
  %413 = getelementptr i8, ptr %402, i64 176
  store <4 x float> splat (float 1.000000e+00), ptr %412, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %413, align 4, !tbaa !14
  %414 = getelementptr i8, ptr %402, i64 192
  %415 = getelementptr i8, ptr %402, i64 208
  store <4 x float> splat (float 1.000000e+00), ptr %414, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %415, align 4, !tbaa !14
  %416 = getelementptr i8, ptr %402, i64 224
  %417 = getelementptr i8, ptr %402, i64 240
  store <4 x float> splat (float 1.000000e+00), ptr %416, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %417, align 4, !tbaa !14
  %418 = getelementptr i8, ptr %402, i64 256
  %419 = getelementptr i8, ptr %402, i64 272
  store <4 x float> splat (float 1.000000e+00), ptr %418, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %419, align 4, !tbaa !14
  %420 = getelementptr i8, ptr %402, i64 288
  %421 = getelementptr i8, ptr %402, i64 304
  store <4 x float> splat (float 1.000000e+00), ptr %420, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %421, align 4, !tbaa !14
  %422 = getelementptr i8, ptr %402, i64 320
  %423 = getelementptr i8, ptr %402, i64 336
  store <4 x float> splat (float 1.000000e+00), ptr %422, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %423, align 4, !tbaa !14
  %424 = getelementptr i8, ptr %402, i64 352
  %425 = getelementptr i8, ptr %402, i64 368
  store <4 x float> splat (float 1.000000e+00), ptr %424, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %425, align 4, !tbaa !14
  %426 = getelementptr i8, ptr %402, i64 384
  %427 = getelementptr i8, ptr %402, i64 400
  store <4 x float> splat (float 1.000000e+00), ptr %426, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %427, align 4, !tbaa !14
  %428 = getelementptr i8, ptr %402, i64 416
  %429 = getelementptr i8, ptr %402, i64 432
  store <4 x float> splat (float 1.000000e+00), ptr %428, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %429, align 4, !tbaa !14
  %430 = getelementptr i8, ptr %402, i64 448
  %431 = getelementptr i8, ptr %402, i64 464
  store <4 x float> splat (float 1.000000e+00), ptr %430, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %431, align 4, !tbaa !14
  %432 = getelementptr i8, ptr %402, i64 480
  %433 = getelementptr i8, ptr %402, i64 496
  store <4 x float> splat (float 1.000000e+00), ptr %432, align 4, !tbaa !14
  store <4 x float> splat (float 1.000000e+00), ptr %433, align 4, !tbaa !14
  %434 = add nuw nsw i64 %397, 1
  %435 = icmp eq i64 %434, 64
  br i1 %435, label %436, label %396, !llvm.loop !19

436:                                              ; preds = %396
  %437 = add nuw nsw i32 %393, 1
  %438 = icmp eq i32 %437, 64
  br i1 %438, label %439, label %392, !llvm.loop !20

439:                                              ; preds = %436
  %440 = tail call float @jacobi(i32 noundef 64, ptr noundef nonnull @a, ptr noundef nonnull @b, ptr noundef nonnull @c, ptr noundef nonnull @p, ptr noundef nonnull @bnd, ptr noundef nonnull @wrk1, ptr noundef nonnull @wrk2)
  %441 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef 64)
  %442 = fpext float %440 to double
  %443 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, double noundef %442)
  %444 = load ptr, ptr @p, align 8, !tbaa !10
  %445 = icmp eq ptr %444, null
  br i1 %445, label %447, label %446

446:                                              ; preds = %439
  tail call void @free(ptr noundef nonnull %444) #16
  br label %447

447:                                              ; preds = %439, %446
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @p, i8 0, i64 24, i1 false)
  %448 = load ptr, ptr @bnd, align 8, !tbaa !10
  %449 = icmp eq ptr %448, null
  br i1 %449, label %451, label %450

450:                                              ; preds = %447
  tail call void @free(ptr noundef nonnull %448) #16
  br label %451

451:                                              ; preds = %447, %450
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @bnd, i8 0, i64 24, i1 false)
  %452 = load ptr, ptr @wrk1, align 8, !tbaa !10
  %453 = icmp eq ptr %452, null
  br i1 %453, label %455, label %454

454:                                              ; preds = %451
  tail call void @free(ptr noundef nonnull %452) #16
  br label %455

455:                                              ; preds = %451, %454
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @wrk1, i8 0, i64 24, i1 false)
  %456 = load ptr, ptr @wrk2, align 8, !tbaa !10
  %457 = icmp eq ptr %456, null
  br i1 %457, label %459, label %458

458:                                              ; preds = %455
  tail call void @free(ptr noundef nonnull %456) #16
  br label %459

459:                                              ; preds = %455, %458
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @wrk2, i8 0, i64 24, i1 false)
  %460 = load ptr, ptr @a, align 8, !tbaa !10
  %461 = icmp eq ptr %460, null
  br i1 %461, label %463, label %462

462:                                              ; preds = %459
  tail call void @free(ptr noundef nonnull %460) #16
  br label %463

463:                                              ; preds = %459, %462
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @a, i8 0, i64 24, i1 false)
  %464 = load ptr, ptr @b, align 8, !tbaa !10
  %465 = icmp eq ptr %464, null
  br i1 %465, label %467, label %466

466:                                              ; preds = %463
  tail call void @free(ptr noundef nonnull %464) #16
  br label %467

467:                                              ; preds = %463, %466
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @b, i8 0, i64 24, i1 false)
  %468 = load ptr, ptr @c, align 8, !tbaa !10
  %469 = icmp eq ptr %468, null
  br i1 %469, label %471, label %470

470:                                              ; preds = %467
  tail call void @free(ptr noundef nonnull %468) #16
  br label %471

471:                                              ; preds = %467, %470
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) @c, i8 0, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nofree nounwind willreturn memory(argmem: write, inaccessiblemem: readwrite, errnomem: write) uwtable
define dso_local range(i32 0, 2) i32 @newMat(ptr nofree noundef writeonly captures(none) initializes((0, 24)) %0, i32 noundef %1, i32 noundef %2, i32 noundef %3, i32 noundef %4) local_unnamed_addr #3 {
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 8
  store i32 %1, ptr %6, align 8, !tbaa !21
  %7 = getelementptr inbounds nuw i8, ptr %0, i64 12
  store i32 %2, ptr %7, align 4, !tbaa !22
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 16
  store i32 %3, ptr %8, align 8, !tbaa !23
  %9 = getelementptr inbounds nuw i8, ptr %0, i64 20
  store i32 %4, ptr %9, align 4, !tbaa !24
  %10 = mul nsw i32 %2, %1
  %11 = mul nsw i32 %10, %3
  %12 = mul nsw i32 %11, %4
  %13 = sext i32 %12 to i64
  %14 = shl nsw i64 %13, 2
  %15 = tail call noalias ptr @malloc(i64 noundef %14) #15
  store ptr %15, ptr %0, align 8, !tbaa !10
  %16 = icmp ne ptr %15, null
  %17 = zext i1 %16 to i32
  ret i32 %17
}

; Function Attrs: nofree norecurse nosync nounwind memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @mat_set_init(ptr nofree noundef readonly captures(none) %0) local_unnamed_addr #4 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 12
  %3 = load i32, ptr %2, align 4, !tbaa !22
  %4 = icmp sgt i32 %3, 0
  br i1 %4, label %5, label %60

5:                                                ; preds = %1
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %7 = load i32, ptr %6, align 8, !tbaa !23
  %8 = icmp sgt i32 %7, 0
  %9 = add nsw i32 %3, -1
  %10 = mul nsw i32 %9, %9
  %11 = uitofp nneg i32 %10 to float
  br i1 %8, label %12, label %60

12:                                               ; preds = %5
  %13 = getelementptr inbounds nuw i8, ptr %0, i64 20
  %14 = load i32, ptr %13, align 4, !tbaa !24
  %15 = icmp sgt i32 %14, 0
  br i1 %15, label %16, label %60

16:                                               ; preds = %12
  %17 = load ptr, ptr %0, align 8, !tbaa !10
  %18 = zext nneg i32 %7 to i64
  %19 = zext nneg i32 %3 to i64
  %20 = zext nneg i32 %14 to i64
  %21 = icmp ult i32 %14, 8
  %22 = and i64 %20, 2147483640
  %23 = icmp eq i64 %22, %20
  br label %24

24:                                               ; preds = %16, %57
  %25 = phi i64 [ 0, %16 ], [ %58, %57 ]
  %26 = mul nuw nsw i64 %25, %25
  %27 = trunc nuw i64 %26 to i32
  %28 = uitofp nneg i32 %27 to float
  %29 = fdiv float %28, %11
  %30 = mul nuw nsw i64 %25, %18
  %31 = insertelement <4 x float> poison, float %29, i64 0
  %32 = shufflevector <4 x float> %31, <4 x float> poison, <4 x i32> zeroinitializer
  br label %33

33:                                               ; preds = %24, %54
  %34 = phi i64 [ 0, %24 ], [ %55, %54 ]
  %35 = add nuw nsw i64 %30, %34
  %36 = trunc nuw i64 %35 to i32
  %37 = mul i32 %14, %36
  %38 = sext i32 %37 to i64
  %39 = getelementptr [4 x i8], ptr %17, i64 %38
  br i1 %21, label %47, label %40

40:                                               ; preds = %33, %40
  %41 = phi i64 [ %44, %40 ], [ 0, %33 ]
  %42 = getelementptr [4 x i8], ptr %39, i64 %41
  %43 = getelementptr i8, ptr %42, i64 16
  store <4 x float> %32, ptr %42, align 4, !tbaa !14
  store <4 x float> %32, ptr %43, align 4, !tbaa !14
  %44 = add nuw i64 %41, 8
  %45 = icmp eq i64 %44, %22
  br i1 %45, label %46, label %40, !llvm.loop !25

46:                                               ; preds = %40
  br i1 %23, label %54, label %47

47:                                               ; preds = %33, %46
  %48 = phi i64 [ 0, %33 ], [ %22, %46 ]
  br label %49

49:                                               ; preds = %47, %49
  %50 = phi i64 [ %52, %49 ], [ %48, %47 ]
  %51 = getelementptr [4 x i8], ptr %39, i64 %50
  store float %29, ptr %51, align 4, !tbaa !14
  %52 = add nuw nsw i64 %50, 1
  %53 = icmp eq i64 %52, %20
  br i1 %53, label %54, label %49, !llvm.loop !28

54:                                               ; preds = %49, %46
  %55 = add nuw nsw i64 %34, 1
  %56 = icmp eq i64 %55, %18
  br i1 %56, label %57, label %33, !llvm.loop !16

57:                                               ; preds = %54
  %58 = add nuw nsw i64 %25, 1
  %59 = icmp eq i64 %58, %19
  br i1 %59, label %60, label %24, !llvm.loop !18

60:                                               ; preds = %57, %5, %12, %1
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @mat_set(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, float noundef %2) local_unnamed_addr #4 {
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 12
  %5 = load i32, ptr %4, align 4, !tbaa !22
  %6 = icmp sgt i32 %5, 0
  br i1 %6, label %7, label %56

7:                                                ; preds = %3
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %9 = load i32, ptr %8, align 8, !tbaa !23
  %10 = icmp sgt i32 %9, 0
  %11 = mul nsw i32 %5, %1
  br i1 %10, label %12, label %56

12:                                               ; preds = %7
  %13 = getelementptr inbounds nuw i8, ptr %0, i64 20
  %14 = load i32, ptr %13, align 4, !tbaa !24
  %15 = icmp sgt i32 %14, 0
  br i1 %15, label %16, label %56

16:                                               ; preds = %12
  %17 = load ptr, ptr %0, align 8, !tbaa !10
  %18 = zext nneg i32 %9 to i64
  %19 = zext nneg i32 %14 to i64
  %20 = icmp ult i32 %14, 8
  %21 = and i64 %19, 2147483640
  %22 = insertelement <4 x float> poison, float %2, i64 0
  %23 = shufflevector <4 x float> %22, <4 x float> poison, <4 x i32> zeroinitializer
  %24 = icmp eq i64 %21, %19
  br label %25

25:                                               ; preds = %16, %53
  %26 = phi i32 [ 0, %16 ], [ %54, %53 ]
  %27 = add i32 %11, %26
  %28 = mul i32 %9, %27
  br label %29

29:                                               ; preds = %25, %50
  %30 = phi i64 [ 0, %25 ], [ %51, %50 ]
  %31 = trunc nuw nsw i64 %30 to i32
  %32 = add i32 %28, %31
  %33 = mul i32 %14, %32
  %34 = sext i32 %33 to i64
  %35 = getelementptr [4 x i8], ptr %17, i64 %34
  br i1 %20, label %43, label %36

36:                                               ; preds = %29, %36
  %37 = phi i64 [ %40, %36 ], [ 0, %29 ]
  %38 = getelementptr [4 x i8], ptr %35, i64 %37
  %39 = getelementptr i8, ptr %38, i64 16
  store <4 x float> %23, ptr %38, align 4, !tbaa !14
  store <4 x float> %23, ptr %39, align 4, !tbaa !14
  %40 = add nuw i64 %37, 8
  %41 = icmp eq i64 %40, %21
  br i1 %41, label %42, label %36, !llvm.loop !29

42:                                               ; preds = %36
  br i1 %24, label %50, label %43

43:                                               ; preds = %29, %42
  %44 = phi i64 [ 0, %29 ], [ %21, %42 ]
  br label %45

45:                                               ; preds = %43, %45
  %46 = phi i64 [ %48, %45 ], [ %44, %43 ]
  %47 = getelementptr [4 x i8], ptr %35, i64 %46
  store float %2, ptr %47, align 4, !tbaa !14
  %48 = add nuw nsw i64 %46, 1
  %49 = icmp eq i64 %48, %19
  br i1 %49, label %50, label %45, !llvm.loop !30

50:                                               ; preds = %45, %42
  %51 = add nuw nsw i64 %30, 1
  %52 = icmp eq i64 %51, %18
  br i1 %52, label %53, label %29, !llvm.loop !19

53:                                               ; preds = %50
  %54 = add nuw nsw i32 %26, 1
  %55 = icmp eq i32 %54, %5
  br i1 %55, label %56, label %25, !llvm.loop !20

56:                                               ; preds = %53, %7, %12, %3
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local float @jacobi(i32 noundef %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef readonly captures(none) %2, ptr nofree noundef readonly captures(none) %3, ptr nofree noundef readonly captures(none) %4, ptr nofree noundef readonly captures(none) %5, ptr nofree noundef readonly captures(none) %6, ptr nofree noundef readonly captures(none) %7) local_unnamed_addr #5 {
  %9 = getelementptr inbounds nuw i8, ptr %4, i64 20
  %10 = load i32, ptr %9, align 4, !tbaa !24
  %11 = icmp sgt i32 %0, 0
  br i1 %11, label %12, label %427

12:                                               ; preds = %8
  %13 = add i32 %10, -1
  %14 = getelementptr inbounds nuw i8, ptr %4, i64 16
  %15 = load i32, ptr %14, align 8, !tbaa !23
  %16 = add i32 %15, -1
  %17 = getelementptr inbounds nuw i8, ptr %4, i64 12
  %18 = load i32, ptr %17, align 4, !tbaa !22
  %19 = add i32 %18, -1
  %20 = icmp sgt i32 %18, 2
  %21 = mul i32 %10, %15
  %22 = icmp sgt i32 %15, 2
  %23 = icmp sgt i32 %10, 2
  %24 = getelementptr inbounds nuw i8, ptr %1, i64 12
  %25 = getelementptr inbounds nuw i8, ptr %1, i64 16
  %26 = getelementptr inbounds nuw i8, ptr %1, i64 20
  %27 = getelementptr inbounds nuw i8, ptr %2, i64 12
  %28 = getelementptr inbounds nuw i8, ptr %2, i64 16
  %29 = getelementptr inbounds nuw i8, ptr %2, i64 20
  %30 = getelementptr inbounds nuw i8, ptr %3, i64 12
  %31 = getelementptr inbounds nuw i8, ptr %3, i64 16
  %32 = getelementptr inbounds nuw i8, ptr %3, i64 20
  %33 = getelementptr inbounds nuw i8, ptr %6, i64 16
  %34 = getelementptr inbounds nuw i8, ptr %6, i64 20
  %35 = getelementptr inbounds nuw i8, ptr %5, i64 16
  %36 = getelementptr inbounds nuw i8, ptr %5, i64 20
  %37 = getelementptr inbounds nuw i8, ptr %7, i64 16
  %38 = getelementptr inbounds nuw i8, ptr %7, i64 20
  %39 = icmp slt i32 %18, 3
  %40 = icmp slt i32 %15, 3
  %41 = icmp slt i32 %10, 3
  %42 = sext i32 %10 to i64
  %43 = zext i32 %15 to i64
  %44 = zext nneg i32 %19 to i64
  %45 = zext nneg i32 %16 to i64
  %46 = zext i32 %13 to i64
  %47 = select i1 %39, i1 true, i1 %40
  %48 = select i1 %47, i1 true, i1 %41
  %49 = zext nneg i32 %19 to i64
  %50 = zext i32 %16 to i64
  %51 = zext i32 %13 to i64
  %52 = add i32 %15, 1
  %53 = mul i32 %10, %52
  %54 = mul i32 %15, %10
  %55 = add nsw i64 %46, -1
  %56 = icmp ult i64 %55, 8
  %57 = and i64 %55, -8
  %58 = or disjoint i64 %57, 1
  %59 = icmp eq i64 %55, %57
  br label %60

60:                                               ; preds = %12, %423
  %61 = phi i32 [ 0, %12 ], [ %425, %423 ]
  br i1 %20, label %73, label %423

62:                                               ; preds = %326
  br i1 %48, label %423, label %63

63:                                               ; preds = %62
  %64 = load ptr, ptr %7, align 8, !tbaa !10
  %65 = ptrtoaddr ptr %64 to i64
  %66 = load i32, ptr %37, align 8, !tbaa !23
  %67 = load i32, ptr %38, align 4, !tbaa !24
  %68 = load ptr, ptr %4, align 8, !tbaa !10
  %69 = ptrtoaddr ptr %68 to i64
  %70 = add i32 %66, 1
  %71 = mul i32 %67, %70
  %72 = mul i32 %66, %67
  br label %330

73:                                               ; preds = %60, %326
  %74 = phi i64 [ %327, %326 ], [ 1, %60 ]
  %75 = phi float [ %328, %326 ], [ 0.000000e+00, %60 ]
  br i1 %22, label %78, label %76

76:                                               ; preds = %73
  %77 = add nuw nsw i64 %74, 1
  br label %326

78:                                               ; preds = %73
  %79 = trunc nuw nsw i64 %74 to i32
  %80 = mul i32 %21, %79
  %81 = add nuw nsw i64 %74, 1
  %82 = trunc nuw nsw i64 %81 to i32
  %83 = mul i32 %21, %82
  %84 = trunc i64 %74 to i32
  %85 = add i32 %84, -1
  %86 = mul i32 %21, %85
  %87 = sext i32 %83 to i64
  %88 = sext i32 %86 to i64
  %89 = sext i32 %80 to i64
  br label %90

90:                                               ; preds = %78, %322
  %91 = phi i64 [ 1, %78 ], [ %323, %322 ]
  %92 = phi float [ %75, %78 ], [ %324, %322 ]
  br i1 %23, label %95, label %93

93:                                               ; preds = %90
  %94 = add nuw nsw i64 %91, 1
  br label %322

95:                                               ; preds = %90
  %96 = load ptr, ptr %1, align 8, !tbaa !10
  %97 = load i32, ptr %24, align 4, !tbaa !22
  %98 = load i32, ptr %25, align 8, !tbaa !23
  %99 = load i32, ptr %26, align 4, !tbaa !24
  %100 = mul nsw i32 %98, %79
  %101 = trunc nuw nsw i64 %91 to i32
  %102 = add i32 %100, %101
  %103 = mul i32 %102, %99
  %104 = load ptr, ptr %4, align 8, !tbaa !10
  %105 = mul nuw nsw i64 %91, %42
  %106 = add nsw i64 %105, %87
  %107 = add i32 %97, %79
  %108 = mul i32 %107, %98
  %109 = add i32 %108, %101
  %110 = mul i32 %109, %99
  %111 = add nuw nsw i64 %91, 1
  %112 = mul nuw nsw i64 %111, %42
  %113 = add nsw i64 %112, %89
  %114 = shl nsw i32 %97, 1
  %115 = add i32 %114, %79
  %116 = mul i32 %115, %98
  %117 = add i32 %116, %101
  %118 = mul i32 %117, %99
  %119 = add nsw i64 %105, %89
  %120 = load ptr, ptr %2, align 8, !tbaa !10
  %121 = load i32, ptr %27, align 4, !tbaa !22
  %122 = load i32, ptr %28, align 8, !tbaa !23
  %123 = load i32, ptr %29, align 4, !tbaa !24
  %124 = mul nsw i32 %122, %79
  %125 = add i32 %124, %101
  %126 = mul i32 %125, %123
  %127 = add nsw i64 %91, -1
  %128 = mul nsw i64 %127, %42
  %129 = add i32 %121, %79
  %130 = mul i32 %129, %122
  %131 = add i32 %130, %101
  %132 = mul i32 %131, %123
  %133 = add nsw i64 %128, %89
  %134 = shl nsw i32 %121, 1
  %135 = add i32 %134, %79
  %136 = mul i32 %135, %122
  %137 = add i32 %136, %101
  %138 = mul i32 %137, %123
  %139 = add nsw i64 %105, %88
  %140 = load ptr, ptr %3, align 8, !tbaa !10
  %141 = load i32, ptr %30, align 4, !tbaa !22
  %142 = load i32, ptr %31, align 8, !tbaa !23
  %143 = load i32, ptr %32, align 4, !tbaa !24
  %144 = mul nsw i32 %142, %79
  %145 = add i32 %144, %101
  %146 = mul i32 %145, %143
  %147 = add i32 %141, %79
  %148 = mul i32 %147, %142
  %149 = add i32 %148, %101
  %150 = mul i32 %149, %143
  %151 = shl nsw i32 %141, 1
  %152 = add i32 %151, %79
  %153 = mul i32 %152, %142
  %154 = add i32 %153, %101
  %155 = mul i32 %154, %143
  %156 = load ptr, ptr %6, align 8, !tbaa !10
  %157 = load i32, ptr %33, align 8, !tbaa !23
  %158 = load i32, ptr %34, align 4, !tbaa !24
  %159 = mul nsw i32 %157, %79
  %160 = add i32 %159, %101
  %161 = mul i32 %160, %158
  %162 = mul nsw i32 %97, 3
  %163 = add i32 %162, %79
  %164 = mul i32 %163, %98
  %165 = add i32 %164, %101
  %166 = mul i32 %165, %99
  %167 = load ptr, ptr %5, align 8, !tbaa !10
  %168 = load i32, ptr %35, align 8, !tbaa !23
  %169 = load i32, ptr %36, align 4, !tbaa !24
  %170 = mul nsw i32 %168, %79
  %171 = add i32 %170, %101
  %172 = mul i32 %171, %169
  %173 = load ptr, ptr %7, align 8, !tbaa !10
  %174 = load i32, ptr %37, align 8, !tbaa !23
  %175 = load i32, ptr %38, align 4, !tbaa !24
  %176 = mul nsw i32 %174, %79
  %177 = add i32 %176, %101
  %178 = mul i32 %177, %175
  %179 = sext i32 %103 to i64
  %180 = sext i32 %110 to i64
  %181 = sext i32 %118 to i64
  %182 = sext i32 %126 to i64
  %183 = sext i32 %132 to i64
  %184 = sext i32 %138 to i64
  %185 = sext i32 %146 to i64
  %186 = sext i32 %150 to i64
  %187 = sext i32 %155 to i64
  %188 = sext i32 %161 to i64
  %189 = sext i32 %166 to i64
  %190 = sext i32 %172 to i64
  %191 = sext i32 %178 to i64
  %192 = getelementptr [4 x i8], ptr %96, i64 %179
  %193 = getelementptr [4 x i8], ptr %104, i64 %106
  %194 = getelementptr [4 x i8], ptr %96, i64 %180
  %195 = getelementptr [4 x i8], ptr %104, i64 %113
  %196 = getelementptr [4 x i8], ptr %96, i64 %181
  %197 = getelementptr [4 x i8], ptr %104, i64 %119
  %198 = getelementptr [4 x i8], ptr %120, i64 %182
  %199 = getelementptr [4 x i8], ptr %104, i64 %112
  %200 = getelementptr [4 x i8], ptr %199, i64 %87
  %201 = getelementptr [4 x i8], ptr %104, i64 %128
  %202 = getelementptr [4 x i8], ptr %201, i64 %87
  %203 = getelementptr [4 x i8], ptr %104, i64 %112
  %204 = getelementptr [4 x i8], ptr %203, i64 %88
  %205 = getelementptr [4 x i8], ptr %104, i64 %128
  %206 = getelementptr [4 x i8], ptr %205, i64 %88
  %207 = getelementptr [4 x i8], ptr %120, i64 %183
  %208 = getelementptr [4 x i8], ptr %104, i64 %113
  %209 = getelementptr [4 x i8], ptr %104, i64 %133
  %210 = getelementptr [4 x i8], ptr %104, i64 %113
  %211 = getelementptr [4 x i8], ptr %104, i64 %133
  %212 = getelementptr [4 x i8], ptr %120, i64 %184
  %213 = getelementptr [4 x i8], ptr %104, i64 %106
  %214 = getelementptr [4 x i8], ptr %104, i64 %139
  %215 = getelementptr [4 x i8], ptr %104, i64 %106
  %216 = getelementptr [4 x i8], ptr %104, i64 %139
  %217 = getelementptr [4 x i8], ptr %140, i64 %185
  %218 = getelementptr [4 x i8], ptr %104, i64 %139
  %219 = getelementptr [4 x i8], ptr %140, i64 %186
  %220 = getelementptr [4 x i8], ptr %104, i64 %133
  %221 = getelementptr [4 x i8], ptr %140, i64 %187
  %222 = getelementptr [4 x i8], ptr %104, i64 %119
  %223 = getelementptr [4 x i8], ptr %156, i64 %188
  %224 = getelementptr [4 x i8], ptr %96, i64 %189
  %225 = getelementptr [4 x i8], ptr %104, i64 %119
  %226 = getelementptr [4 x i8], ptr %167, i64 %190
  %227 = getelementptr [4 x i8], ptr %173, i64 %191
  br label %228

228:                                              ; preds = %95, %228
  %229 = phi i64 [ 1, %95 ], [ %243, %228 ]
  %230 = phi float [ %92, %95 ], [ %317, %228 ]
  %231 = getelementptr [4 x i8], ptr %192, i64 %229
  %232 = load float, ptr %231, align 4, !tbaa !14
  %233 = getelementptr [4 x i8], ptr %193, i64 %229
  %234 = load float, ptr %233, align 4, !tbaa !14
  %235 = getelementptr [4 x i8], ptr %194, i64 %229
  %236 = load float, ptr %235, align 4, !tbaa !14
  %237 = getelementptr [4 x i8], ptr %195, i64 %229
  %238 = load float, ptr %237, align 4, !tbaa !14
  %239 = fmul float %236, %238
  %240 = tail call float @llvm.fmuladd.f32(float %232, float %234, float %239)
  %241 = getelementptr [4 x i8], ptr %196, i64 %229
  %242 = load float, ptr %241, align 4, !tbaa !14
  %243 = add nuw nsw i64 %229, 1
  %244 = getelementptr [4 x i8], ptr %197, i64 %243
  %245 = load float, ptr %244, align 4, !tbaa !14
  %246 = tail call float @llvm.fmuladd.f32(float %242, float %245, float %240)
  %247 = getelementptr [4 x i8], ptr %198, i64 %229
  %248 = load float, ptr %247, align 4, !tbaa !14
  %249 = getelementptr [4 x i8], ptr %200, i64 %229
  %250 = load float, ptr %249, align 4, !tbaa !14
  %251 = getelementptr [4 x i8], ptr %202, i64 %229
  %252 = load float, ptr %251, align 4, !tbaa !14
  %253 = fsub float %250, %252
  %254 = getelementptr [4 x i8], ptr %204, i64 %229
  %255 = load float, ptr %254, align 4, !tbaa !14
  %256 = fsub float %253, %255
  %257 = getelementptr [4 x i8], ptr %206, i64 %229
  %258 = load float, ptr %257, align 4, !tbaa !14
  %259 = fadd float %256, %258
  %260 = tail call float @llvm.fmuladd.f32(float %248, float %259, float %246)
  %261 = getelementptr [4 x i8], ptr %207, i64 %229
  %262 = load float, ptr %261, align 4, !tbaa !14
  %263 = getelementptr [4 x i8], ptr %208, i64 %243
  %264 = load float, ptr %263, align 4, !tbaa !14
  %265 = getelementptr [4 x i8], ptr %209, i64 %243
  %266 = load float, ptr %265, align 4, !tbaa !14
  %267 = fsub float %264, %266
  %268 = add nsw i64 %229, -1
  %269 = getelementptr [4 x i8], ptr %210, i64 %268
  %270 = load float, ptr %269, align 4, !tbaa !14
  %271 = fsub float %267, %270
  %272 = getelementptr [4 x i8], ptr %211, i64 %268
  %273 = load float, ptr %272, align 4, !tbaa !14
  %274 = fadd float %271, %273
  %275 = tail call float @llvm.fmuladd.f32(float %262, float %274, float %260)
  %276 = getelementptr [4 x i8], ptr %212, i64 %229
  %277 = load float, ptr %276, align 4, !tbaa !14
  %278 = getelementptr [4 x i8], ptr %213, i64 %243
  %279 = load float, ptr %278, align 4, !tbaa !14
  %280 = getelementptr [4 x i8], ptr %214, i64 %243
  %281 = load float, ptr %280, align 4, !tbaa !14
  %282 = fsub float %279, %281
  %283 = getelementptr [4 x i8], ptr %215, i64 %268
  %284 = load float, ptr %283, align 4, !tbaa !14
  %285 = fsub float %282, %284
  %286 = getelementptr [4 x i8], ptr %216, i64 %268
  %287 = load float, ptr %286, align 4, !tbaa !14
  %288 = fadd float %285, %287
  %289 = tail call float @llvm.fmuladd.f32(float %277, float %288, float %275)
  %290 = getelementptr [4 x i8], ptr %217, i64 %229
  %291 = load float, ptr %290, align 4, !tbaa !14
  %292 = getelementptr [4 x i8], ptr %218, i64 %229
  %293 = load float, ptr %292, align 4, !tbaa !14
  %294 = tail call float @llvm.fmuladd.f32(float %291, float %293, float %289)
  %295 = getelementptr [4 x i8], ptr %219, i64 %229
  %296 = load float, ptr %295, align 4, !tbaa !14
  %297 = getelementptr [4 x i8], ptr %220, i64 %229
  %298 = load float, ptr %297, align 4, !tbaa !14
  %299 = tail call float @llvm.fmuladd.f32(float %296, float %298, float %294)
  %300 = getelementptr [4 x i8], ptr %221, i64 %229
  %301 = load float, ptr %300, align 4, !tbaa !14
  %302 = getelementptr [4 x i8], ptr %222, i64 %268
  %303 = load float, ptr %302, align 4, !tbaa !14
  %304 = tail call float @llvm.fmuladd.f32(float %301, float %303, float %299)
  %305 = getelementptr [4 x i8], ptr %223, i64 %229
  %306 = load float, ptr %305, align 4, !tbaa !14
  %307 = fadd float %304, %306
  %308 = getelementptr [4 x i8], ptr %224, i64 %229
  %309 = load float, ptr %308, align 4, !tbaa !14
  %310 = getelementptr [4 x i8], ptr %225, i64 %229
  %311 = load float, ptr %310, align 4, !tbaa !14
  %312 = fneg float %311
  %313 = tail call float @llvm.fmuladd.f32(float %307, float %309, float %312)
  %314 = getelementptr [4 x i8], ptr %226, i64 %229
  %315 = load float, ptr %314, align 4, !tbaa !14
  %316 = fmul float %313, %315
  %317 = tail call float @llvm.fmuladd.f32(float %316, float %316, float %230)
  %318 = load float, ptr @omega, align 4, !tbaa !14
  %319 = tail call float @llvm.fmuladd.f32(float %318, float %316, float %311)
  %320 = getelementptr [4 x i8], ptr %227, i64 %229
  store float %319, ptr %320, align 4, !tbaa !14
  %321 = icmp eq i64 %243, %46
  br i1 %321, label %322, label %228, !llvm.loop !31

322:                                              ; preds = %228, %93
  %323 = phi i64 [ %94, %93 ], [ %111, %228 ]
  %324 = phi float [ %92, %93 ], [ %317, %228 ]
  %325 = icmp eq i64 %323, %45
  br i1 %325, label %326, label %90, !llvm.loop !32

326:                                              ; preds = %322, %76
  %327 = phi i64 [ %77, %76 ], [ %81, %322 ]
  %328 = phi float [ %75, %76 ], [ %324, %322 ]
  %329 = icmp eq i64 %327, %44
  br i1 %329, label %62, label %73, !llvm.loop !33

330:                                              ; preds = %63, %419
  %331 = phi i32 [ 0, %63 ], [ %422, %419 ]
  %332 = phi i64 [ 1, %63 ], [ %420, %419 ]
  %333 = mul i32 %54, %331
  %334 = add i32 %53, %333
  %335 = mul i32 %72, %331
  %336 = add i32 %71, %335
  %337 = mul nuw nsw i64 %332, %43
  %338 = trunc i64 %332 to i32
  %339 = mul i32 %66, %338
  br label %340

340:                                              ; preds = %330, %415
  %341 = phi i32 [ 0, %330 ], [ %418, %415 ]
  %342 = phi i64 [ 1, %330 ], [ %416, %415 ]
  %343 = trunc nuw nsw i64 %342 to i32
  %344 = add i32 %339, %343
  %345 = mul i32 %344, %67
  %346 = add nuw nsw i64 %342, %337
  %347 = trunc nuw i64 %346 to i32
  %348 = mul i32 %10, %347
  %349 = sext i32 %345 to i64
  %350 = sext i32 %348 to i64
  %351 = getelementptr [4 x i8], ptr %64, i64 %349
  %352 = getelementptr [4 x i8], ptr %68, i64 %350
  br i1 %56, label %378, label %353

353:                                              ; preds = %340
  %354 = mul i32 %67, %341
  %355 = add i32 %336, %354
  %356 = sext i32 %355 to i64
  %357 = shl nsw i64 %356, 2
  %358 = mul i32 %10, %341
  %359 = add i32 %334, %358
  %360 = sext i32 %359 to i64
  %361 = shl nsw i64 %360, 2
  %362 = add i64 %361, %69
  %363 = add i64 %357, %65
  %364 = sub i64 %363, %362
  %365 = icmp ugt i64 %364, -32
  br i1 %365, label %378, label %366

366:                                              ; preds = %353, %366
  %367 = phi i64 [ %375, %366 ], [ 0, %353 ]
  %368 = or disjoint i64 %367, 1
  %369 = getelementptr [4 x i8], ptr %351, i64 %368
  %370 = getelementptr i8, ptr %369, i64 16
  %371 = load <4 x float>, ptr %369, align 4, !tbaa !14
  %372 = load <4 x float>, ptr %370, align 4, !tbaa !14
  %373 = getelementptr [4 x i8], ptr %352, i64 %368
  %374 = getelementptr i8, ptr %373, i64 16
  store <4 x float> %371, ptr %373, align 4, !tbaa !14
  store <4 x float> %372, ptr %374, align 4, !tbaa !14
  %375 = add nuw i64 %367, 8
  %376 = icmp eq i64 %375, %57
  br i1 %376, label %377, label %366, !llvm.loop !34

377:                                              ; preds = %366
  br i1 %59, label %415, label %378

378:                                              ; preds = %353, %340, %377
  %379 = phi i64 [ 1, %353 ], [ 1, %340 ], [ %58, %377 ]
  %380 = sub nsw i64 %46, %379
  %381 = and i64 %380, 3
  %382 = icmp eq i64 %381, 0
  br i1 %382, label %392, label %383

383:                                              ; preds = %378, %383
  %384 = phi i64 [ %389, %383 ], [ %379, %378 ]
  %385 = phi i64 [ %390, %383 ], [ 0, %378 ]
  %386 = getelementptr [4 x i8], ptr %351, i64 %384
  %387 = load float, ptr %386, align 4, !tbaa !14
  %388 = getelementptr [4 x i8], ptr %352, i64 %384
  store float %387, ptr %388, align 4, !tbaa !14
  %389 = add nuw nsw i64 %384, 1
  %390 = add i64 %385, 1
  %391 = icmp eq i64 %390, %381
  br i1 %391, label %392, label %383, !llvm.loop !35

392:                                              ; preds = %383, %378
  %393 = phi i64 [ %379, %378 ], [ %389, %383 ]
  %394 = sub nsw i64 %379, %46
  %395 = icmp ugt i64 %394, -4
  br i1 %395, label %415, label %396

396:                                              ; preds = %392, %396
  %397 = phi i64 [ %413, %396 ], [ %393, %392 ]
  %398 = getelementptr [4 x i8], ptr %351, i64 %397
  %399 = load float, ptr %398, align 4, !tbaa !14
  %400 = getelementptr [4 x i8], ptr %352, i64 %397
  store float %399, ptr %400, align 4, !tbaa !14
  %401 = add nuw nsw i64 %397, 1
  %402 = getelementptr [4 x i8], ptr %351, i64 %401
  %403 = load float, ptr %402, align 4, !tbaa !14
  %404 = getelementptr [4 x i8], ptr %352, i64 %401
  store float %403, ptr %404, align 4, !tbaa !14
  %405 = add nuw nsw i64 %397, 2
  %406 = getelementptr [4 x i8], ptr %351, i64 %405
  %407 = load float, ptr %406, align 4, !tbaa !14
  %408 = getelementptr [4 x i8], ptr %352, i64 %405
  store float %407, ptr %408, align 4, !tbaa !14
  %409 = add nuw nsw i64 %397, 3
  %410 = getelementptr [4 x i8], ptr %351, i64 %409
  %411 = load float, ptr %410, align 4, !tbaa !14
  %412 = getelementptr [4 x i8], ptr %352, i64 %409
  store float %411, ptr %412, align 4, !tbaa !14
  %413 = add nuw nsw i64 %397, 4
  %414 = icmp eq i64 %413, %51
  br i1 %414, label %415, label %396, !llvm.loop !37

415:                                              ; preds = %392, %396, %377
  %416 = add nuw nsw i64 %342, 1
  %417 = icmp eq i64 %416, %50
  %418 = add i32 %341, 1
  br i1 %417, label %419, label %340, !llvm.loop !38

419:                                              ; preds = %415
  %420 = add nuw nsw i64 %332, 1
  %421 = icmp eq i64 %420, %49
  %422 = add i32 %331, 1
  br i1 %421, label %423, label %330, !llvm.loop !39

423:                                              ; preds = %419, %60, %62
  %424 = phi float [ 0.000000e+00, %60 ], [ %328, %62 ], [ %328, %419 ]
  %425 = add nuw nsw i32 %61, 1
  %426 = icmp eq i32 %425, %0
  br i1 %426, label %427, label %60, !llvm.loop !40

427:                                              ; preds = %423, %8
  %428 = phi float [ undef, %8 ], [ %424, %423 ]
  ret float %428
}

; Function Attrs: mustprogress nounwind willreturn memory(readwrite, target_mem: none) uwtable
define dso_local void @clearMat(ptr nofree noundef captures(none) initializes((8, 24)) %0) local_unnamed_addr #6 {
  %2 = load ptr, ptr %0, align 8, !tbaa !10
  %3 = icmp eq ptr %2, null
  br i1 %3, label %5, label %4

4:                                                ; preds = %1
  tail call void @free(ptr noundef nonnull %2) #16
  br label %5

5:                                                ; preds = %4, %1
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(24) %0, i8 0, i64 24, i1 false)
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local double @fflop(i32 noundef %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #7 {
  %4 = add nsw i32 %2, -2
  %5 = sitofp i32 %4 to double
  %6 = add nsw i32 %1, -2
  %7 = sitofp i32 %6 to double
  %8 = fmul nnan double %7, %5
  %9 = add nsw i32 %0, -2
  %10 = sitofp i32 %9 to double
  %11 = fmul double %8, %10
  %12 = fmul double %11, 3.400000e+01
  ret double %12
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef double @mflops(i32 noundef %0, double noundef %1, double noundef %2) local_unnamed_addr #7 {
  %4 = fdiv double %2, %1
  %5 = fmul double %4, f0x3EB0C6F7A0B5ED8D
  %6 = sitofp i32 %0 to double
  %7 = fmul double %5, %6
  ret double %7
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @set_param(ptr nofree noundef writeonly captures(none) %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #8 {
  %3 = load i8, ptr %1, align 1
  switch i8 %3, label %60 [
    i8 88, label %4
    i8 120, label %12
    i8 83, label %20
    i8 115, label %24
    i8 77, label %28
    i8 109, label %32
    i8 76, label %36
    i8 108, label %40
  ]

4:                                                ; preds = %2
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %6 = load i8, ptr %5, align 1
  %7 = icmp eq i8 %6, 83
  br i1 %7, label %8, label %44

8:                                                ; preds = %4
  %9 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %10 = load i8, ptr %9, align 1
  %11 = icmp eq i8 %10, 0
  br i1 %11, label %62, label %44

12:                                               ; preds = %2
  %13 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %14 = load i8, ptr %13, align 1
  %15 = icmp eq i8 %14, 115
  br i1 %15, label %16, label %52

16:                                               ; preds = %12
  %17 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %18 = load i8, ptr %17, align 1
  %19 = icmp eq i8 %18, 0
  br i1 %19, label %62, label %52

20:                                               ; preds = %2
  %21 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %22 = load i8, ptr %21, align 1
  %23 = icmp eq i8 %22, 0
  br i1 %23, label %62, label %60

24:                                               ; preds = %2
  %25 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %26 = load i8, ptr %25, align 1
  %27 = icmp eq i8 %26, 0
  br i1 %27, label %62, label %60

28:                                               ; preds = %2
  %29 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %30 = load i8, ptr %29, align 1
  %31 = icmp eq i8 %30, 0
  br i1 %31, label %62, label %60

32:                                               ; preds = %2
  %33 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %34 = load i8, ptr %33, align 1
  %35 = icmp eq i8 %34, 0
  br i1 %35, label %62, label %60

36:                                               ; preds = %2
  %37 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %38 = load i8, ptr %37, align 1
  %39 = icmp eq i8 %38, 0
  br i1 %39, label %62, label %60

40:                                               ; preds = %2
  %41 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %42 = load i8, ptr %41, align 1
  %43 = icmp eq i8 %42, 0
  br i1 %43, label %62, label %60

44:                                               ; preds = %8, %4
  %45 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %46 = load i8, ptr %45, align 1
  %47 = icmp eq i8 %46, 76
  br i1 %47, label %48, label %60

48:                                               ; preds = %44
  %49 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %50 = load i8, ptr %49, align 1
  %51 = icmp eq i8 %50, 0
  br i1 %51, label %62, label %60

52:                                               ; preds = %12, %16
  %53 = getelementptr inbounds nuw i8, ptr %1, i64 1
  %54 = load i8, ptr %53, align 1
  %55 = icmp eq i8 %54, 108
  br i1 %55, label %56, label %60

56:                                               ; preds = %52
  %57 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %58 = load i8, ptr %57, align 1
  %59 = icmp eq i8 %58, 0
  br i1 %59, label %62, label %60

60:                                               ; preds = %48, %44, %2, %40, %36, %32, %20, %24, %28, %52, %56
  %61 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  tail call void @exit(i32 noundef 6) #17
  unreachable

62:                                               ; preds = %48, %56, %36, %40, %28, %32, %20, %24, %8, %16
  %63 = phi i32 [ 256, %36 ], [ 128, %28 ], [ 64, %20 ], [ 32, %8 ], [ 32, %16 ], [ 64, %24 ], [ 128, %32 ], [ 256, %40 ], [ 512, %56 ], [ 512, %48 ]
  %64 = phi <2 x i32> [ <i32 256, i32 512>, %36 ], [ <i32 128, i32 256>, %28 ], [ <i32 64, i32 128>, %20 ], [ <i32 32, i32 64>, %8 ], [ <i32 32, i32 64>, %16 ], [ <i32 64, i32 128>, %24 ], [ <i32 128, i32 256>, %32 ], [ <i32 256, i32 512>, %40 ], [ <i32 512, i32 1024>, %56 ], [ <i32 512, i32 1024>, %48 ]
  store i32 %63, ptr %0, align 4, !tbaa !9
  %65 = getelementptr inbounds nuw i8, ptr %0, i64 4
  store <2 x i32> %64, ptr %65, align 4, !tbaa !9
  ret void
}

; Function Attrs: nofree noreturn nounwind
declare void @exit(i32 noundef) local_unnamed_addr #9

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #10

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #11

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #12

; Function Attrs: nofree nounwind uwtable
define dso_local double @second() local_unnamed_addr #8 {
  %1 = alloca %struct.timeval, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #16
  %2 = call i32 @gettimeofday(ptr noundef nonnull %1, ptr noundef null) #16
  %3 = load i32, ptr @second.base_sec, align 4, !tbaa !9
  %4 = icmp eq i32 %3, 0
  %5 = load i32, ptr @second.base_usec, align 4
  %6 = icmp eq i32 %5, 0
  %7 = select i1 %4, i1 %6, i1 false
  %8 = load i64, ptr %1, align 8, !tbaa !41
  br i1 %7, label %9, label %14

9:                                                ; preds = %0
  %10 = trunc i64 %8 to i32
  store i32 %10, ptr @second.base_sec, align 4, !tbaa !9
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %12 = load i64, ptr %11, align 8, !tbaa !44
  %13 = trunc i64 %12 to i32
  store i32 %13, ptr @second.base_usec, align 4, !tbaa !9
  br label %25

14:                                               ; preds = %0
  %15 = sext i32 %3 to i64
  %16 = sub nsw i64 %8, %15
  %17 = sitofp i64 %16 to double
  %18 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %19 = load i64, ptr %18, align 8, !tbaa !44
  %20 = sext i32 %5 to i64
  %21 = sub nsw i64 %19, %20
  %22 = sitofp i64 %21 to double
  %23 = fdiv double %22, 1.000000e+06
  %24 = fadd double %23, %17
  br label %25

25:                                               ; preds = %14, %9
  %26 = phi double [ 0.000000e+00, %9 ], [ %24, %14 ]
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #16
  ret double %26
}

; Function Attrs: nofree nounwind
declare noundef i32 @gettimeofday(ptr noundef captures(none), ptr noundef captures(none)) local_unnamed_addr #2

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #13

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #14

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nofree nounwind willreturn memory(argmem: write, inaccessiblemem: readwrite, errnomem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree norecurse nosync nounwind memory(write, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { mustprogress nounwind willreturn memory(readwrite, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #11 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #12 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #13 = { nofree nounwind }
attributes #14 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #15 = { nounwind allocsize(0) }
attributes #16 = { nounwind }
attributes #17 = { cold noreturn nounwind }

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
!10 = !{!11, !12, i64 0}
!11 = !{!"Mat", !12, i64 0, !6, i64 8, !6, i64 12, !6, i64 16, !6, i64 20}
!12 = !{!"p1 float", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"float", !7, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
!19 = distinct !{!19, !17}
!20 = distinct !{!20, !17}
!21 = !{!11, !6, i64 8}
!22 = !{!11, !6, i64 12}
!23 = !{!11, !6, i64 16}
!24 = !{!11, !6, i64 20}
!25 = distinct !{!25, !17, !26, !27}
!26 = !{!"llvm.loop.isvectorized", i32 1}
!27 = !{!"llvm.loop.unroll.runtime.disable"}
!28 = distinct !{!28, !17, !27, !26}
!29 = distinct !{!29, !17, !26, !27}
!30 = distinct !{!30, !17, !27, !26}
!31 = distinct !{!31, !17}
!32 = distinct !{!32, !17}
!33 = distinct !{!33, !17}
!34 = distinct !{!34, !17, !26, !27}
!35 = distinct !{!35, !36}
!36 = !{!"llvm.loop.unroll.disable"}
!37 = distinct !{!37, !17, !26}
!38 = distinct !{!38, !17}
!39 = distinct !{!39, !17}
!40 = distinct !{!40, !17}
!41 = !{!42, !43, i64 0}
!42 = !{!"timeval", !43, i64 0, !43, i64 8}
!43 = !{!"long", !7, i64 0}
!44 = !{!42, !43, i64 8}
