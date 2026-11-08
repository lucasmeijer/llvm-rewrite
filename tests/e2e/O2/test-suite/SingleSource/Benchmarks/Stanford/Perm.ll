; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Perm.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Perm.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Stanford/Perm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.element = type { i32, i32 }
%struct.complex = type { float, float }

@seed = dso_local local_unnamed_addr global i64 0, align 8
@permarray = dso_local local_unnamed_addr global [11 x i32] zeroinitializer, align 16
@pctr = dso_local local_unnamed_addr global i32 0, align 4
@.str.1 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@value = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@fixed = dso_local local_unnamed_addr global float 0.000000e+00, align 4
@floated = dso_local local_unnamed_addr global float 0.000000e+00, align 4
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
@str = private unnamed_addr constant [16 x i8] c" Error in Perm.\00", align 1

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

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable
define dso_local void @Swap(ptr nofree noundef captures(none) %0, ptr nofree noundef captures(none) %1) local_unnamed_addr #2 {
  %3 = load i32, ptr %0, align 4, !tbaa !11
  %4 = load i32, ptr %1, align 4, !tbaa !11
  store i32 %4, ptr %0, align 4, !tbaa !11
  store i32 %3, ptr %1, align 4, !tbaa !11
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Initialize() local_unnamed_addr #0 {
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  ret void
}

; Function Attrs: nofree nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @Permute(i32 noundef %0) local_unnamed_addr #3 {
  %2 = load i32, ptr @pctr, align 4, !tbaa !11
  %3 = add i32 %2, 1
  store i32 %3, ptr @pctr, align 4, !tbaa !11
  %4 = icmp eq i32 %0, 1
  br i1 %4, label %21, label %5

5:                                                ; preds = %1
  %6 = add nsw i32 %0, -1
  tail call void @Permute(i32 noundef %6)
  %7 = icmp sgt i32 %0, 1
  br i1 %7, label %8, label %21

8:                                                ; preds = %5
  %9 = zext nneg i32 %0 to i64
  %10 = getelementptr inbounds nuw [4 x i8], ptr @permarray, i64 %9
  %11 = zext nneg i32 %6 to i64
  br label %12

12:                                               ; preds = %8, %12
  %13 = phi i64 [ %11, %8 ], [ %19, %12 ]
  %14 = getelementptr inbounds nuw [4 x i8], ptr @permarray, i64 %13
  %15 = load i32, ptr %10, align 4, !tbaa !11
  %16 = load i32, ptr %14, align 4, !tbaa !11
  store i32 %16, ptr %10, align 4, !tbaa !11
  store i32 %15, ptr %14, align 4, !tbaa !11
  tail call void @Permute(i32 noundef %6)
  %17 = load i32, ptr %10, align 4, !tbaa !11
  %18 = load i32, ptr %14, align 4, !tbaa !11
  store i32 %18, ptr %10, align 4, !tbaa !11
  store i32 %17, ptr %14, align 4, !tbaa !11
  %19 = add nsw i64 %13, -1
  %20 = icmp samesign ugt i64 %13, 1
  br i1 %20, label %12, label %21, !llvm.loop !12

21:                                               ; preds = %12, %5, %1
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @Perm() local_unnamed_addr #4 {
  store i32 0, ptr @pctr, align 4, !tbaa !11
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  tail call void @Permute(i32 noundef 7)
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  tail call void @Permute(i32 noundef 7)
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  tail call void @Permute(i32 noundef 7)
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  tail call void @Permute(i32 noundef 7)
  store <4 x i32> <i32 0, i32 1, i32 2, i32 3>, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 4), align 4, !tbaa !11
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 20), align 4, !tbaa !11
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 24), align 8, !tbaa !11
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @permarray, i64 28), align 4, !tbaa !11
  tail call void @Permute(i32 noundef 7)
  %1 = load i32, ptr @pctr, align 4, !tbaa !11
  %2 = icmp eq i32 %1, 43300
  br i1 %2, label %6, label %3

3:                                                ; preds = %0
  %4 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  %5 = load i32, ptr @pctr, align 4, !tbaa !11
  br label %6

6:                                                ; preds = %3, %0
  %7 = phi i32 [ %5, %3 ], [ 43300, %0 ]
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %7)
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #5

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #4 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i32 [ 0, %0 ], [ %3, %1 ]
  tail call void @Perm()
  %3 = add nuw nsw i32 %2, 1
  %4 = icmp eq i32 %3, 100
  br i1 %4, label %5, label %1, !llvm.loop !14

5:                                                ; preds = %1
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #6

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(write, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind }

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
