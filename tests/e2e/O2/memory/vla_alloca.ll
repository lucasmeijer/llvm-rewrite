; @source: tests/e2e/src/memory/vla_alloca.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/vla_alloca.c'
source_filename = "tests/e2e/src/memory/vla_alloca.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local range(i32 0, 256) i32 @main() local_unnamed_addr #0 {
  br label %3

1:                                                ; preds = %3
  %2 = and i32 %7, 255
  ret i32 %2

3:                                                ; preds = %0, %3
  %4 = phi i32 [ 1, %0 ], [ %9, %3 ]
  %5 = phi i32 [ 0, %0 ], [ %7, %3 ]
  %6 = tail call fastcc i32 @f(i32 noundef %4)
  %7 = add nsw i32 %6, %5
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %6)
  %9 = add nuw nsw i32 %4, 5
  %10 = icmp samesign ult i32 %4, 35
  br i1 %10, label %3, label %1, !llvm.loop !9
}

; Function Attrs: nofree norecurse nosync nounwind memory(none) uwtable
define internal fastcc i32 @f(i32 noundef range(i32 -2147483648, 40) %0) unnamed_addr #1 {
  %2 = zext i32 %0 to i64
  %3 = alloca i32, i64 %2, align 16
  %4 = icmp sgt i32 %0, 0
  br i1 %4, label %5, label %67

5:                                                ; preds = %1
  %6 = icmp ult i32 %0, 8
  br i1 %6, label %24, label %7

7:                                                ; preds = %5
  %8 = and i64 %2, 2147483640
  %9 = getelementptr inbounds nuw i8, ptr %3, i64 16
  store <4 x i32> <i32 0, i32 3, i32 6, i32 9>, ptr %3, align 16, !tbaa !11
  store <4 x i32> <i32 12, i32 15, i32 18, i32 21>, ptr %9, align 16, !tbaa !11
  %10 = icmp eq i64 %8, 8
  br i1 %10, label %22, label %11

11:                                               ; preds = %7
  %12 = getelementptr inbounds nuw i8, ptr %3, i64 32
  %13 = getelementptr inbounds nuw i8, ptr %3, i64 48
  store <4 x i32> <i32 24, i32 27, i32 30, i32 33>, ptr %12, align 16, !tbaa !11
  store <4 x i32> <i32 36, i32 39, i32 42, i32 45>, ptr %13, align 16, !tbaa !11
  %14 = icmp eq i64 %8, 16
  br i1 %14, label %22, label %15

15:                                               ; preds = %11
  %16 = getelementptr inbounds nuw i8, ptr %3, i64 64
  %17 = getelementptr inbounds nuw i8, ptr %3, i64 80
  store <4 x i32> <i32 48, i32 51, i32 54, i32 57>, ptr %16, align 16, !tbaa !11
  store <4 x i32> <i32 60, i32 63, i32 66, i32 69>, ptr %17, align 16, !tbaa !11
  %18 = icmp eq i64 %8, 24
  br i1 %18, label %22, label %19

19:                                               ; preds = %15
  %20 = getelementptr inbounds nuw i8, ptr %3, i64 96
  %21 = getelementptr inbounds nuw i8, ptr %3, i64 112
  store <4 x i32> <i32 72, i32 75, i32 78, i32 81>, ptr %20, align 16, !tbaa !11
  store <4 x i32> <i32 84, i32 87, i32 90, i32 93>, ptr %21, align 16, !tbaa !11
  br label %22

22:                                               ; preds = %19, %15, %11, %7
  %23 = icmp eq i64 %8, %2
  br i1 %23, label %26, label %24

24:                                               ; preds = %5, %22
  %25 = phi i64 [ 0, %5 ], [ %8, %22 ]
  br label %60

26:                                               ; preds = %60, %22
  %27 = zext nneg i32 %0 to i64
  %28 = getelementptr [4 x i8], ptr %3, i64 %27
  %29 = icmp ult i32 %0, 8
  br i1 %29, label %57, label %30

30:                                               ; preds = %26
  %31 = and i64 %2, 2147483640
  br label %32

32:                                               ; preds = %32, %30
  %33 = phi i64 [ 0, %30 ], [ %50, %32 ]
  %34 = phi <4 x i32> [ zeroinitializer, %30 ], [ %48, %32 ]
  %35 = phi <4 x i32> [ zeroinitializer, %30 ], [ %49, %32 ]
  %36 = phi <4 x i32> [ <i32 0, i32 1, i32 2, i32 3>, %30 ], [ %51, %32 ]
  %37 = add <4 x i32> %36, splat (i32 4)
  %38 = xor i64 %33, -1
  %39 = getelementptr [4 x i8], ptr %28, i64 %38
  %40 = getelementptr i8, ptr %39, i64 -12
  %41 = getelementptr i8, ptr %39, i64 -28
  %42 = load <4 x i32>, ptr %40, align 4, !tbaa !11
  %43 = load <4 x i32>, ptr %41, align 4, !tbaa !11
  %44 = shufflevector <4 x i32> %42, <4 x i32> poison, <4 x i32> <i32 3, i32 2, i32 1, i32 0>
  %45 = shufflevector <4 x i32> %43, <4 x i32> poison, <4 x i32> <i32 3, i32 2, i32 1, i32 0>
  %46 = mul nsw <4 x i32> %44, %36
  %47 = mul nsw <4 x i32> %45, %37
  %48 = add <4 x i32> %46, %34
  %49 = add <4 x i32> %47, %35
  %50 = add nuw i64 %33, 8
  %51 = add <4 x i32> %36, splat (i32 8)
  %52 = icmp eq i64 %50, %31
  br i1 %52, label %53, label %32, !llvm.loop !12

53:                                               ; preds = %32
  %54 = add <4 x i32> %49, %48
  %55 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %54)
  %56 = icmp eq i64 %31, %2
  br i1 %56, label %67, label %57

57:                                               ; preds = %26, %53
  %58 = phi i64 [ 0, %26 ], [ %31, %53 ]
  %59 = phi i32 [ 0, %26 ], [ %55, %53 ]
  br label %69

60:                                               ; preds = %24, %60
  %61 = phi i64 [ %65, %60 ], [ %25, %24 ]
  %62 = getelementptr inbounds nuw [4 x i8], ptr %3, i64 %61
  %63 = trunc i64 %61 to i32
  %64 = mul i32 %63, 3
  store i32 %64, ptr %62, align 4, !tbaa !11
  %65 = add nuw nsw i64 %61, 1
  %66 = icmp eq i64 %65, %2
  br i1 %66, label %26, label %60, !llvm.loop !15

67:                                               ; preds = %69, %53, %1
  %68 = phi i32 [ 0, %1 ], [ %55, %53 ], [ %77, %69 ]
  ret i32 %68

69:                                               ; preds = %57, %69
  %70 = phi i64 [ %78, %69 ], [ %58, %57 ]
  %71 = phi i32 [ %77, %69 ], [ %59, %57 ]
  %72 = xor i64 %70, -1
  %73 = getelementptr [4 x i8], ptr %28, i64 %72
  %74 = load i32, ptr %73, align 4, !tbaa !11
  %75 = trunc nuw nsw i64 %70 to i32
  %76 = mul nsw i32 %74, %75
  %77 = add nsw i32 %76, %71
  %78 = add nuw nsw i64 %70, 1
  %79 = icmp eq i64 %78, %2
  br i1 %79, label %67, label %69, !llvm.loop !16
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>) #3

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree norecurse nosync nounwind memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !10, !13, !14}
!13 = !{!"llvm.loop.isvectorized", i32 1}
!14 = !{!"llvm.loop.unroll.runtime.disable"}
!15 = distinct !{!15, !10, !14, !13}
!16 = distinct !{!16, !10, !14, !13}
