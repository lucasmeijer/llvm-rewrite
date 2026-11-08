; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/fp-convert.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"Total is %g\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local double @loop(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef readonly captures(none) %1, i64 noundef %2) local_unnamed_addr #0 {
  %4 = icmp sgt i64 %2, 0
  br i1 %4, label %5, label %45

5:                                                ; preds = %3
  %6 = and i64 %2, 1
  %7 = icmp eq i64 %2, 1
  br i1 %7, label %34, label %8

8:                                                ; preds = %5
  %9 = and i64 %2, 9223372036854775806
  br label %10

10:                                               ; preds = %10, %8
  %11 = phi double [ 0.000000e+00, %8 ], [ %28, %10 ]
  %12 = phi i64 [ 0, %8 ], [ %29, %10 ]
  %13 = phi i64 [ 0, %8 ], [ %30, %10 ]
  %14 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %12
  %15 = load float, ptr %14, align 4, !tbaa !9
  %16 = fpext float %15 to double
  %17 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %12
  %18 = load float, ptr %17, align 4, !tbaa !9
  %19 = fpext float %18 to double
  %20 = tail call double @llvm.fmuladd.f64(double %16, double %19, double %11)
  %21 = or disjoint i64 %12, 1
  %22 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %21
  %23 = load float, ptr %22, align 4, !tbaa !9
  %24 = fpext float %23 to double
  %25 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %21
  %26 = load float, ptr %25, align 4, !tbaa !9
  %27 = fpext float %26 to double
  %28 = tail call double @llvm.fmuladd.f64(double %24, double %27, double %20)
  %29 = add nuw nsw i64 %12, 2
  %30 = add i64 %13, 2
  %31 = icmp eq i64 %30, %9
  br i1 %31, label %32, label %10, !llvm.loop !11

32:                                               ; preds = %10
  %33 = icmp eq i64 %6, 0
  br i1 %33, label %45, label %34

34:                                               ; preds = %32, %5
  %35 = phi double [ 0.000000e+00, %5 ], [ %28, %32 ]
  %36 = phi i64 [ 0, %5 ], [ %29, %32 ]
  %37 = trunc i64 %2 to i1
  tail call void @llvm.assume(i1 %37)
  %38 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %36
  %39 = load float, ptr %38, align 4, !tbaa !9
  %40 = fpext float %39 to double
  %41 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %36
  %42 = load float, ptr %41, align 4, !tbaa !9
  %43 = fpext float %42 to double
  %44 = tail call double @llvm.fmuladd.f64(double %40, double %43, double %35)
  br label %45

45:                                               ; preds = %34, %32, %3
  %46 = phi double [ 0.000000e+00, %3 ], [ %28, %32 ], [ %44, %34 ]
  ret double %46
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #3 {
  %3 = alloca [2048 x float], align 16
  %4 = alloca [2048 x float], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #6
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #6
  br label %5

5:                                                ; preds = %2, %54
  %6 = phi double [ 0.000000e+00, %2 ], [ %55, %54 ]
  %7 = phi i32 [ 0, %2 ], [ %56, %54 ]
  %8 = phi <2 x float> [ <float 1.000000e+00, float 0.000000e+00>, %2 ], [ %14, %54 ]
  %9 = urem i32 %7, 10
  %10 = icmp eq i32 %9, 0
  %11 = fadd <2 x float> %8, <float 2.000000e-01, float 1.000000e-01>
  %12 = insertelement <2 x i1> poison, i1 %10, i64 0
  %13 = shufflevector <2 x i1> %12, <2 x i1> poison, <2 x i32> zeroinitializer
  %14 = select <2 x i1> %13, <2 x float> %11, <2 x float> <float 1.000000e+00, float 0.000000e+00>
  %15 = shufflevector <2 x float> %14, <2 x float> poison, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %16 = shufflevector <2 x float> %14, <2 x float> poison, <4 x i32> zeroinitializer
  br label %17

17:                                               ; preds = %17, %5
  %18 = phi i64 [ 0, %5 ], [ %31, %17 ]
  %19 = phi <4 x i32> [ <i32 0, i32 1, i32 2, i32 3>, %5 ], [ %32, %17 ]
  %20 = add <4 x i32> %19, splat (i32 4)
  %21 = uitofp nneg <4 x i32> %19 to <4 x float>
  %22 = uitofp nneg <4 x i32> %20 to <4 x float>
  %23 = fadd <4 x float> %15, %21
  %24 = fadd <4 x float> %15, %22
  %25 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %18
  %26 = getelementptr inbounds nuw i8, ptr %25, i64 16
  store <4 x float> %23, ptr %25, align 16, !tbaa !9
  store <4 x float> %24, ptr %26, align 16, !tbaa !9
  %27 = fadd <4 x float> %16, %21
  %28 = fadd <4 x float> %16, %22
  %29 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %18
  %30 = getelementptr inbounds nuw i8, ptr %29, i64 16
  store <4 x float> %27, ptr %29, align 16, !tbaa !9
  store <4 x float> %28, ptr %30, align 16, !tbaa !9
  %31 = add nuw i64 %18, 8
  %32 = add <4 x i32> %19, splat (i32 8)
  %33 = icmp eq i64 %31, 2048
  br i1 %33, label %34, label %17, !llvm.loop !13

34:                                               ; preds = %17, %34
  %35 = phi double [ %51, %34 ], [ 0.000000e+00, %17 ]
  %36 = phi i64 [ %52, %34 ], [ 0, %17 ]
  %37 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %36
  %38 = load float, ptr %37, align 8, !tbaa !9
  %39 = fpext float %38 to double
  %40 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %36
  %41 = load float, ptr %40, align 8, !tbaa !9
  %42 = fpext float %41 to double
  %43 = tail call double @llvm.fmuladd.f64(double %39, double %42, double %35)
  %44 = or disjoint i64 %36, 1
  %45 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %44
  %46 = load float, ptr %45, align 4, !tbaa !9
  %47 = fpext float %46 to double
  %48 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %44
  %49 = load float, ptr %48, align 4, !tbaa !9
  %50 = fpext float %49 to double
  %51 = tail call double @llvm.fmuladd.f64(double %47, double %50, double %43)
  %52 = add nuw nsw i64 %36, 2
  %53 = icmp eq i64 %52, 2048
  br i1 %53, label %54, label %34, !llvm.loop !11

54:                                               ; preds = %34
  %55 = fadd double %6, %51
  %56 = add nuw nsw i32 %7, 1
  %57 = icmp eq i32 %56, 500000
  br i1 %57, label %58, label %5, !llvm.loop !16

58:                                               ; preds = %54
  %59 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %55)
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #6
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #6
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #5

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #6 = { nounwind }

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
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12, !14, !15}
!14 = !{!"llvm.loop.isvectorized", i32 1}
!15 = !{!"llvm.loop.unroll.runtime.disable"}
!16 = distinct !{!16, !12}
