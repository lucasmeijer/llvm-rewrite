; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/matrixTranspose.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@A = dso_local local_unnamed_addr global [2048 x float] zeroinitializer, align 16
@.str = private unnamed_addr constant [23 x i8] c"Checksum before = %lf\0A\00", align 1
@.str.1 = private unnamed_addr constant [23 x i8] c"Checksum  after = %lf\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @complex_transpose(ptr nofree noundef captures(none) %0, ptr nofree noundef captures(none) %1, i32 noundef %2, i32 noundef %3, i32 noundef %4) local_unnamed_addr #0 {
  %6 = icmp sgt i32 %2, 1
  br i1 %6, label %7, label %73

7:                                                ; preds = %5
  %8 = sext i32 %4 to i64
  %9 = sext i32 %3 to i64
  %10 = zext nneg i32 %2 to i64
  %11 = icmp ne i32 %4, 1
  %12 = icmp ne i32 %3, 1
  %13 = or i1 %11, %12
  br label %14

14:                                               ; preds = %7, %69
  %15 = phi i64 [ 0, %7 ], [ %72, %69 ]
  %16 = phi i64 [ 1, %7 ], [ %70, %69 ]
  %17 = shl nuw nsw i64 %15, 2
  %18 = add nuw i64 %17, 4
  %19 = getelementptr i8, ptr %0, i64 %18
  %20 = shl nuw nsw i64 %15, 3
  %21 = add nuw i64 %20, 8
  %22 = getelementptr i8, ptr %0, i64 %21
  %23 = getelementptr i8, ptr %1, i64 %18
  %24 = getelementptr i8, ptr %1, i64 %21
  %25 = mul nsw i64 %16, %9
  %26 = mul nsw i64 %16, %8
  %27 = icmp samesign ult i64 %16, 4
  %28 = or i1 %27, %13
  br i1 %28, label %51, label %29

29:                                               ; preds = %14
  %30 = icmp ult ptr %19, %24
  %31 = icmp ult ptr %23, %22
  %32 = and i1 %30, %31
  br i1 %32, label %51, label %33

33:                                               ; preds = %29
  %34 = and i64 %16, 9223372036854775804
  br label %35

35:                                               ; preds = %35, %33
  %36 = phi i64 [ 0, %33 ], [ %47, %35 ]
  %37 = add nsw i64 %36, %25
  %38 = getelementptr inbounds [4 x i8], ptr %0, i64 %37
  %39 = load <4 x float>, ptr %38, align 4, !tbaa !9, !alias.scope !11, !noalias !14
  %40 = getelementptr inbounds [4 x i8], ptr %1, i64 %37
  %41 = load <4 x float>, ptr %40, align 4, !tbaa !9, !alias.scope !14
  %42 = add nsw i64 %36, %26
  %43 = getelementptr inbounds [4 x i8], ptr %0, i64 %42
  %44 = load <4 x float>, ptr %43, align 4, !tbaa !9, !alias.scope !11, !noalias !14
  %45 = getelementptr inbounds [4 x i8], ptr %1, i64 %42
  %46 = load <4 x float>, ptr %45, align 4, !tbaa !9, !alias.scope !14
  store <4 x float> %39, ptr %43, align 4, !tbaa !9, !alias.scope !11, !noalias !14
  store <4 x float> %41, ptr %45, align 4, !tbaa !9, !alias.scope !14
  store <4 x float> %44, ptr %38, align 4, !tbaa !9, !alias.scope !11, !noalias !14
  store <4 x float> %46, ptr %40, align 4, !tbaa !9, !alias.scope !14
  %47 = add nuw i64 %36, 4
  %48 = icmp eq i64 %47, %34
  br i1 %48, label %49, label %35, !llvm.loop !16

49:                                               ; preds = %35
  %50 = icmp eq i64 %16, %34
  br i1 %50, label %69, label %51

51:                                               ; preds = %14, %29, %49
  %52 = phi i64 [ 0, %29 ], [ %34, %49 ], [ 0, %14 ]
  br label %53

53:                                               ; preds = %51, %53
  %54 = phi i64 [ %67, %53 ], [ %52, %51 ]
  %55 = mul nsw i64 %54, %8
  %56 = add nsw i64 %55, %25
  %57 = getelementptr inbounds [4 x i8], ptr %0, i64 %56
  %58 = load float, ptr %57, align 4, !tbaa !9
  %59 = getelementptr inbounds [4 x i8], ptr %1, i64 %56
  %60 = load float, ptr %59, align 4, !tbaa !9
  %61 = mul nsw i64 %54, %9
  %62 = add nsw i64 %61, %26
  %63 = getelementptr inbounds [4 x i8], ptr %0, i64 %62
  %64 = load float, ptr %63, align 4, !tbaa !9
  %65 = getelementptr inbounds [4 x i8], ptr %1, i64 %62
  %66 = load float, ptr %65, align 4, !tbaa !9
  store float %58, ptr %63, align 4, !tbaa !9
  store float %60, ptr %65, align 4, !tbaa !9
  store float %64, ptr %57, align 4, !tbaa !9
  store float %66, ptr %59, align 4, !tbaa !9
  %67 = add nuw nsw i64 %54, 1
  %68 = icmp eq i64 %67, %16
  br i1 %68, label %69, label %53, !llvm.loop !20

69:                                               ; preds = %53, %49
  %70 = add nuw nsw i64 %16, 1
  %71 = icmp eq i64 %70, %10
  %72 = add i64 %15, 1
  br i1 %71, label %73, label %14, !llvm.loop !21

73:                                               ; preds = %69, %5
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #1 {
  br label %3

3:                                                ; preds = %3, %2
  %4 = phi i64 [ 0, %2 ], [ %25, %3 ]
  %5 = phi float [ 0.000000e+00, %2 ], [ %24, %3 ]
  %6 = trunc nuw nsw i64 %4 to i32
  %7 = uitofp nneg i32 %6 to float
  %8 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %4
  store float %7, ptr %8, align 16, !tbaa !9
  %9 = fadd float %5, %7
  %10 = or disjoint i64 %4, 1
  %11 = trunc nuw nsw i64 %10 to i32
  %12 = uitofp nneg i32 %11 to float
  %13 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %10
  store float %12, ptr %13, align 4, !tbaa !9
  %14 = fadd float %9, %12
  %15 = or disjoint i64 %4, 2
  %16 = trunc nuw nsw i64 %15 to i32
  %17 = uitofp nneg i32 %16 to float
  %18 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %15
  store float %17, ptr %18, align 8, !tbaa !9
  %19 = fadd float %14, %17
  %20 = or disjoint i64 %4, 3
  %21 = trunc nuw nsw i64 %20 to i32
  %22 = uitofp nneg i32 %21 to float
  %23 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %20
  store float %22, ptr %23, align 4, !tbaa !9
  %24 = fadd float %19, %22
  %25 = add nuw nsw i64 %4, 4
  %26 = icmp eq i64 %25, 2048
  br i1 %26, label %27, label %3, !llvm.loop !22

27:                                               ; preds = %3
  %28 = fpext float %24 to double
  %29 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %28)
  br label %30

30:                                               ; preds = %27, %85
  %31 = phi i32 [ 0, %27 ], [ %86, %85 ]
  br label %32

32:                                               ; preds = %30, %81
  %33 = phi i64 [ 0, %30 ], [ %84, %81 ]
  %34 = phi i64 [ 1, %30 ], [ %82, %81 ]
  %35 = and i64 %34, 1
  %36 = icmp eq i64 %33, 0
  br i1 %36, label %68, label %37

37:                                               ; preds = %32
  %38 = and i64 %34, 9223372036854775806
  %39 = shl nuw nsw i64 %34, 3
  %40 = getelementptr inbounds i8, ptr @A, i64 %39
  %41 = shl nsw i64 %34, 8
  %42 = getelementptr inbounds i8, ptr @A, i64 %41
  %43 = shl nuw nsw i64 %34, 3
  %44 = getelementptr inbounds i8, ptr @A, i64 %43
  %45 = shl nsw i64 %34, 8
  %46 = getelementptr inbounds i8, ptr @A, i64 %45
  br label %47

47:                                               ; preds = %47, %37
  %48 = phi i64 [ 0, %37 ], [ %63, %47 ]
  %49 = phi i64 [ 0, %37 ], [ %64, %47 ]
  %50 = shl nsw i64 %48, 8
  %51 = getelementptr inbounds i8, ptr %40, i64 %50
  %52 = shl nuw nsw i64 %48, 3
  %53 = getelementptr inbounds i8, ptr %42, i64 %52
  %54 = load <2 x float>, ptr %53, align 16, !tbaa !9
  %55 = load <2 x float>, ptr %51, align 8, !tbaa !9
  store <2 x float> %55, ptr %53, align 16, !tbaa !9
  store <2 x float> %54, ptr %51, align 8, !tbaa !9
  %56 = or disjoint i64 %48, 1
  %57 = shl nsw i64 %56, 8
  %58 = getelementptr inbounds i8, ptr %44, i64 %57
  %59 = shl nuw nsw i64 %56, 3
  %60 = getelementptr inbounds i8, ptr %46, i64 %59
  %61 = load <2 x float>, ptr %60, align 8, !tbaa !9
  %62 = load <2 x float>, ptr %58, align 8, !tbaa !9
  store <2 x float> %62, ptr %60, align 8, !tbaa !9
  store <2 x float> %61, ptr %58, align 8, !tbaa !9
  %63 = add nuw nsw i64 %48, 2
  %64 = add i64 %49, 2
  %65 = icmp eq i64 %64, %38
  br i1 %65, label %66, label %47, !llvm.loop !23

66:                                               ; preds = %47
  %67 = icmp eq i64 %35, 0
  br i1 %67, label %81, label %68

68:                                               ; preds = %66, %32
  %69 = phi i64 [ 0, %32 ], [ %63, %66 ]
  %70 = trunc i64 %34 to i1
  tail call void @llvm.assume(i1 %70)
  %71 = shl nsw i64 %69, 8
  %72 = getelementptr inbounds nuw i8, ptr @A, i64 %71
  %73 = shl nuw nsw i64 %34, 3
  %74 = getelementptr inbounds nuw i8, ptr %72, i64 %73
  %75 = shl nuw nsw i64 %69, 3
  %76 = getelementptr inbounds nuw i8, ptr @A, i64 %75
  %77 = shl nsw i64 %34, 8
  %78 = getelementptr inbounds nuw i8, ptr %76, i64 %77
  %79 = load <2 x float>, ptr %78, align 8, !tbaa !9
  %80 = load <2 x float>, ptr %74, align 8, !tbaa !9
  store <2 x float> %80, ptr %78, align 8, !tbaa !9
  store <2 x float> %79, ptr %74, align 8, !tbaa !9
  br label %81

81:                                               ; preds = %66, %68
  %82 = add nuw nsw i64 %34, 1
  %83 = icmp eq i64 %82, 32
  %84 = add i64 %33, 1
  br i1 %83, label %85, label %32, !llvm.loop !21

85:                                               ; preds = %81
  %86 = add nuw nsw i32 %31, 1
  %87 = icmp eq i32 %86, 10
  br i1 %87, label %88, label %30, !llvm.loop !24

88:                                               ; preds = %85, %88
  %89 = phi i64 [ %106, %88 ], [ 0, %85 ]
  %90 = phi float [ %105, %88 ], [ 0.000000e+00, %85 ]
  %91 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %89
  %92 = load float, ptr %91, align 16, !tbaa !9
  %93 = fadd float %90, %92
  %94 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %89
  %95 = getelementptr inbounds nuw i8, ptr %94, i64 4
  %96 = load float, ptr %95, align 4, !tbaa !9
  %97 = fadd float %93, %96
  %98 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %89
  %99 = getelementptr inbounds nuw i8, ptr %98, i64 8
  %100 = load float, ptr %99, align 8, !tbaa !9
  %101 = fadd float %97, %100
  %102 = getelementptr inbounds nuw [4 x i8], ptr @A, i64 %89
  %103 = getelementptr inbounds nuw i8, ptr %102, i64 12
  %104 = load float, ptr %103, align 4, !tbaa !9
  %105 = fadd float %101, %104
  %106 = add nuw nsw i64 %89, 4
  %107 = icmp eq i64 %106, 2048
  br i1 %107, label %108, label %88, !llvm.loop !25

108:                                              ; preds = %88
  %109 = fpext float %105 to double
  %110 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %109)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #3

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }

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
!10 = !{!"float", !7, i64 0}
!11 = !{!12}
!12 = distinct !{!12, !13}
!13 = distinct !{!13, !"LVerDomain"}
!14 = !{!15}
!15 = distinct !{!15, !13}
!16 = distinct !{!16, !17, !18, !19}
!17 = !{!"llvm.loop.mustprogress"}
!18 = !{!"llvm.loop.isvectorized", i32 1}
!19 = !{!"llvm.loop.unroll.runtime.disable"}
!20 = distinct !{!20, !17, !18}
!21 = distinct !{!21, !17}
!22 = distinct !{!22, !17}
!23 = distinct !{!23, !17}
!24 = distinct !{!24, !17}
!25 = distinct !{!25, !17}
