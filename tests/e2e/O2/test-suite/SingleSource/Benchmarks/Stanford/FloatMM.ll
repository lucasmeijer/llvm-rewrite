; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/FloatMM.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/FloatMM.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/FloatMM.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@rma = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@rmb = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@rmr = dso_local local_unnamed_addr global [41 x [41 x float]] zeroinitializer, align 16
@.str = private unnamed_addr constant [4 x i8] c"%f\0A\00", align 1
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
define dso_local void @rInitmatrix(ptr nofree noundef writeonly captures(none) %0) local_unnamed_addr #2 {
  %2 = load i64, ptr @seed, align 8, !tbaa !9
  %3 = freeze i64 %2
  br label %4

4:                                                ; preds = %1, %23
  %5 = phi i64 [ 1, %1 ], [ %24, %23 ]
  %6 = phi i64 [ %3, %1 ], [ %13, %23 ]
  %7 = getelementptr inbounds nuw [164 x i8], ptr %0, i64 %5
  br label %8

8:                                                ; preds = %4, %8
  %9 = phi i64 [ 1, %4 ], [ %21, %8 ]
  %10 = phi i64 [ %6, %4 ], [ %13, %8 ]
  %11 = mul i64 %10, 1309
  %12 = add i64 %11, 13849
  %13 = and i64 %12, 65535
  %14 = trunc i64 %12 to i16
  %15 = urem i16 %14, 120
  %16 = zext nneg i16 %15 to i32
  %17 = add nsw i32 %16, -60
  %18 = sitofp i32 %17 to float
  %19 = fdiv float %18, 3.000000e+00
  %20 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %9
  store float %19, ptr %20, align 4, !tbaa !11
  %21 = add nuw nsw i64 %9, 1
  %22 = icmp eq i64 %21, 41
  br i1 %22, label %23, label %8, !llvm.loop !13

23:                                               ; preds = %8
  %24 = add nuw nsw i64 %5, 1
  %25 = icmp eq i64 %24, 41
  br i1 %25, label %26, label %4, !llvm.loop !15

26:                                               ; preds = %23
  store i64 %13, ptr @seed, align 8, !tbaa !9
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @rInnerproduct(ptr nofree noundef writeonly captures(none) initializes((0, 4)) %0, ptr nofree noundef readonly captures(none) %1, ptr nofree noundef readonly captures(none) %2, i32 noundef %3, i32 noundef %4) local_unnamed_addr #3 {
  store float 0.000000e+00, ptr %0, align 4, !tbaa !11
  %6 = sext i32 %3 to i64
  %7 = getelementptr inbounds [164 x i8], ptr %1, i64 %6
  %8 = sext i32 %4 to i64
  %9 = getelementptr [4 x i8], ptr %2, i64 %8
  br label %10

10:                                               ; preds = %10, %5
  %11 = phi i64 [ 1, %5 ], [ %24, %10 ]
  %12 = phi float [ 0.000000e+00, %5 ], [ %23, %10 ]
  %13 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %11
  %14 = load float, ptr %13, align 4, !tbaa !11
  %15 = getelementptr [164 x i8], ptr %9, i64 %11
  %16 = load float, ptr %15, align 4, !tbaa !11
  %17 = tail call float @llvm.fmuladd.f32(float %14, float %16, float %12)
  store float %17, ptr %0, align 4, !tbaa !11
  %18 = add nuw nsw i64 %11, 1
  %19 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %18
  %20 = load float, ptr %19, align 4, !tbaa !11
  %21 = getelementptr [164 x i8], ptr %9, i64 %18
  %22 = load float, ptr %21, align 4, !tbaa !11
  %23 = tail call float @llvm.fmuladd.f32(float %20, float %22, float %17)
  store float %23, ptr %0, align 4, !tbaa !11
  %24 = add nuw nsw i64 %11, 2
  %25 = icmp eq i64 %24, 41
  br i1 %25, label %26, label %10, !llvm.loop !16

26:                                               ; preds = %10
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #4

; Function Attrs: nofree nounwind uwtable
define dso_local void @Mm(i32 noundef %0) local_unnamed_addr #5 {
  br label %2

2:                                                ; preds = %21, %1
  %3 = phi i64 [ 1, %1 ], [ %22, %21 ]
  %4 = phi i64 [ 74755, %1 ], [ %11, %21 ]
  %5 = getelementptr inbounds nuw [164 x i8], ptr @rma, i64 %3
  br label %6

6:                                                ; preds = %6, %2
  %7 = phi i64 [ 1, %2 ], [ %19, %6 ]
  %8 = phi i64 [ %4, %2 ], [ %11, %6 ]
  %9 = mul nuw nsw i64 %8, 1309
  %10 = add nuw nsw i64 %9, 13849
  %11 = and i64 %10, 65535
  %12 = trunc i64 %10 to i16
  %13 = urem i16 %12, 120
  %14 = zext nneg i16 %13 to i32
  %15 = add nsw i32 %14, -60
  %16 = sitofp i32 %15 to float
  %17 = fdiv float %16, 3.000000e+00
  %18 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %7
  store float %17, ptr %18, align 4, !tbaa !11
  %19 = add nuw nsw i64 %7, 1
  %20 = icmp eq i64 %19, 41
  br i1 %20, label %21, label %6, !llvm.loop !13

21:                                               ; preds = %6
  %22 = add nuw nsw i64 %3, 1
  %23 = icmp eq i64 %22, 41
  br i1 %23, label %24, label %2, !llvm.loop !15

24:                                               ; preds = %21, %43
  %25 = phi i64 [ %44, %43 ], [ 1, %21 ]
  %26 = phi i64 [ %33, %43 ], [ %11, %21 ]
  %27 = getelementptr inbounds nuw [164 x i8], ptr @rmb, i64 %25
  br label %28

28:                                               ; preds = %28, %24
  %29 = phi i64 [ 1, %24 ], [ %41, %28 ]
  %30 = phi i64 [ %26, %24 ], [ %33, %28 ]
  %31 = mul nuw nsw i64 %30, 1309
  %32 = add nuw nsw i64 %31, 13849
  %33 = and i64 %32, 65535
  %34 = trunc i64 %32 to i16
  %35 = urem i16 %34, 120
  %36 = zext nneg i16 %35 to i32
  %37 = add nsw i32 %36, -60
  %38 = sitofp i32 %37 to float
  %39 = fdiv float %38, 3.000000e+00
  %40 = getelementptr inbounds nuw [4 x i8], ptr %27, i64 %29
  store float %39, ptr %40, align 4, !tbaa !11
  %41 = add nuw nsw i64 %29, 1
  %42 = icmp eq i64 %41, 41
  br i1 %42, label %43, label %28, !llvm.loop !13

43:                                               ; preds = %28
  %44 = add nuw nsw i64 %25, 1
  %45 = icmp eq i64 %44, 41
  br i1 %45, label %46, label %24, !llvm.loop !15

46:                                               ; preds = %43
  store i64 %33, ptr @seed, align 8, !tbaa !9
  br label %47

47:                                               ; preds = %46, %86
  %48 = phi i64 [ 1, %46 ], [ %87, %86 ]
  %49 = getelementptr inbounds nuw [164 x i8], ptr @rmr, i64 %48
  %50 = getelementptr inbounds nuw [164 x i8], ptr @rma, i64 %48
  br label %51

51:                                               ; preds = %47, %83
  %52 = phi i64 [ 1, %47 ], [ %84, %83 ]
  %53 = getelementptr inbounds nuw [4 x i8], ptr %49, i64 %52
  %54 = getelementptr [4 x i8], ptr @rmb, i64 %52
  br label %55

55:                                               ; preds = %55, %51
  %56 = phi i64 [ 1, %51 ], [ %81, %55 ]
  %57 = phi float [ 0.000000e+00, %51 ], [ %80, %55 ]
  %58 = getelementptr inbounds nuw [4 x i8], ptr %50, i64 %56
  %59 = load float, ptr %58, align 4, !tbaa !11
  %60 = getelementptr [164 x i8], ptr %54, i64 %56
  %61 = load float, ptr %60, align 4, !tbaa !11
  %62 = tail call float @llvm.fmuladd.f32(float %59, float %61, float %57)
  %63 = add nuw nsw i64 %56, 1
  %64 = getelementptr inbounds nuw [4 x i8], ptr %50, i64 %63
  %65 = load float, ptr %64, align 4, !tbaa !11
  %66 = getelementptr [164 x i8], ptr %54, i64 %63
  %67 = load float, ptr %66, align 4, !tbaa !11
  %68 = tail call float @llvm.fmuladd.f32(float %65, float %67, float %62)
  %69 = add nuw nsw i64 %56, 2
  %70 = getelementptr inbounds nuw [4 x i8], ptr %50, i64 %69
  %71 = load float, ptr %70, align 4, !tbaa !11
  %72 = getelementptr [164 x i8], ptr %54, i64 %69
  %73 = load float, ptr %72, align 4, !tbaa !11
  %74 = tail call float @llvm.fmuladd.f32(float %71, float %73, float %68)
  %75 = add nuw nsw i64 %56, 3
  %76 = getelementptr inbounds nuw [4 x i8], ptr %50, i64 %75
  %77 = load float, ptr %76, align 4, !tbaa !11
  %78 = getelementptr [164 x i8], ptr %54, i64 %75
  %79 = load float, ptr %78, align 4, !tbaa !11
  %80 = tail call float @llvm.fmuladd.f32(float %77, float %79, float %74)
  %81 = add nuw nsw i64 %56, 4
  %82 = icmp eq i64 %81, 41
  br i1 %82, label %83, label %55, !llvm.loop !16

83:                                               ; preds = %55
  store float %80, ptr %53, align 4, !tbaa !11
  %84 = add nuw nsw i64 %52, 1
  %85 = icmp eq i64 %84, 41
  br i1 %85, label %86, label %51, !llvm.loop !17

86:                                               ; preds = %83
  %87 = add nuw nsw i64 %48, 1
  %88 = icmp eq i64 %87, 41
  br i1 %88, label %89, label %47, !llvm.loop !18

89:                                               ; preds = %86
  %90 = icmp slt i32 %0, 40
  br i1 %90, label %91, label %99

91:                                               ; preds = %89
  %92 = add nsw i32 %0, 1
  %93 = sext i32 %92 to i64
  %94 = getelementptr inbounds [164 x i8], ptr @rmr, i64 %93
  %95 = getelementptr inbounds [4 x i8], ptr %94, i64 %93
  %96 = load float, ptr %95, align 4, !tbaa !11
  %97 = fpext float %96 to double
  %98 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %97)
  br label %99

99:                                               ; preds = %91, %89
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #6

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #5 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Mm(i32 noundef %2)
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 5000
  br i1 %4, label %5, label %1, !llvm.loop !19

5:                                                ; preds = %1
  ret i32 0
}

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(readwrite, argmem: write, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #5 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!11 = !{!12, !12, i64 0}
!12 = !{!"float", !7, i64 0}
!13 = distinct !{!13, !14}
!14 = !{!"llvm.loop.mustprogress"}
!15 = distinct !{!15, !14}
!16 = distinct !{!16, !14}
!17 = distinct !{!17, !14}
!18 = distinct !{!18, !14}
!19 = distinct !{!19, !14}
