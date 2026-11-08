; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/vla.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@bork = dso_local local_unnamed_addr global [4 x [3 x i32]] [[3 x i32] [i32 1, i32 2, i32 3], [3 x i32] [i32 4, i32 5, i32 6], [3 x i32] [i32 7, i32 8, i32 9], [3 x i32] [i32 10, i32 11, i32 12]], align 16
@bork2 = dso_local local_unnamed_addr global [2 x [3 x [4 x i32]]] [[3 x [4 x i32]] [[4 x i32] [i32 1, i32 2, i32 3, i32 4], [4 x i32] [i32 5, i32 6, i32 7, i32 8], [4 x i32] [i32 9, i32 10, i32 11, i32 12]], [3 x [4 x i32]] [[4 x i32] [i32 13, i32 14, i32 15, i32 16], [4 x i32] [i32 17, i32 18, i32 19, i32 20], [4 x i32] [i32 21, i32 22, i32 23, i32 24]]], align 16

; Function Attrs: nofree nounwind uwtable
define dso_local void @function(i16 noundef signext %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = zext i16 %0 to i64
  %4 = icmp sgt i16 %0, 0
  br i1 %4, label %5, label %56

5:                                                ; preds = %2
  %6 = zext nneg i16 %0 to i64
  br label %10

7:                                                ; preds = %10
  %8 = add nuw nsw i64 %11, 1
  %9 = icmp eq i64 %8, %6
  br i1 %9, label %18, label %10, !llvm.loop !9

10:                                               ; preds = %5, %7
  %11 = phi i64 [ 0, %5 ], [ %8, %7 ]
  %12 = getelementptr inbounds nuw [4 x i8], ptr @bork, i64 %11
  %13 = load i32, ptr %12, align 4, !tbaa !11
  %14 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %11
  %15 = load i32, ptr %14, align 4, !tbaa !11
  %16 = icmp eq i32 %13, %15
  br i1 %16, label %7, label %17

17:                                               ; preds = %10, %20, %33, %46
  tail call void @abort() #3
  unreachable

18:                                               ; preds = %7
  %19 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %3
  br label %20

20:                                               ; preds = %27, %18
  %21 = phi i64 [ 0, %18 ], [ %28, %27 ]
  %22 = getelementptr inbounds nuw [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @bork, i64 12), i64 %21
  %23 = load i32, ptr %22, align 4, !tbaa !11
  %24 = getelementptr inbounds nuw [4 x i8], ptr %19, i64 %21
  %25 = load i32, ptr %24, align 4, !tbaa !11
  %26 = icmp eq i32 %23, %25
  br i1 %26, label %27, label %17

27:                                               ; preds = %20
  %28 = add nuw nsw i64 %21, 1
  %29 = icmp eq i64 %28, %6
  br i1 %29, label %30, label %20, !llvm.loop !9

30:                                               ; preds = %27
  %31 = shl nuw nsw i64 %3, 3
  %32 = getelementptr inbounds nuw i8, ptr %1, i64 %31
  br label %33

33:                                               ; preds = %40, %30
  %34 = phi i64 [ 0, %30 ], [ %41, %40 ]
  %35 = getelementptr inbounds nuw [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @bork, i64 24), i64 %34
  %36 = load i32, ptr %35, align 4, !tbaa !11
  %37 = getelementptr inbounds nuw [4 x i8], ptr %32, i64 %34
  %38 = load i32, ptr %37, align 4, !tbaa !11
  %39 = icmp eq i32 %36, %38
  br i1 %39, label %40, label %17

40:                                               ; preds = %33
  %41 = add nuw nsw i64 %34, 1
  %42 = icmp eq i64 %41, %6
  br i1 %42, label %43, label %33, !llvm.loop !9

43:                                               ; preds = %40
  %44 = mul nuw nsw i64 %3, 12
  %45 = getelementptr inbounds nuw i8, ptr %1, i64 %44
  br label %46

46:                                               ; preds = %53, %43
  %47 = phi i64 [ 0, %43 ], [ %54, %53 ]
  %48 = getelementptr inbounds nuw [4 x i8], ptr getelementptr inbounds nuw (i8, ptr @bork, i64 36), i64 %47
  %49 = load i32, ptr %48, align 4, !tbaa !11
  %50 = getelementptr inbounds nuw [4 x i8], ptr %45, i64 %47
  %51 = load i32, ptr %50, align 4, !tbaa !11
  %52 = icmp eq i32 %49, %51
  br i1 %52, label %53, label %17

53:                                               ; preds = %46
  %54 = add nuw nsw i64 %47, 1
  %55 = icmp eq i64 %54, %6
  br i1 %55, label %56, label %46, !llvm.loop !9

56:                                               ; preds = %53, %2
  ret void
}

; Function Attrs: cold nofree noreturn nounwind
declare void @abort() local_unnamed_addr #1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local void @test() local_unnamed_addr #2 {
  ret void
}

; Function Attrs: nofree nounwind uwtable
define dso_local void @function2(i16 noundef signext %0, i16 noundef signext %1, ptr nofree noundef readonly captures(none) %2) local_unnamed_addr #0 {
  %4 = zext i16 %0 to i64
  %5 = zext i16 %1 to i64
  %6 = icmp slt i16 %0, 1
  %7 = sext i16 %1 to i64
  %8 = icmp slt i16 %1, 1
  %9 = mul nuw nsw i64 %5, %4
  %10 = or i1 %6, %8
  br i1 %10, label %52, label %11

11:                                               ; preds = %3
  %12 = zext nneg i16 %0 to i64
  br label %13

13:                                               ; preds = %11, %29
  %14 = phi i64 [ 0, %11 ], [ %30, %29 ]
  %15 = getelementptr inbounds nuw [16 x i8], ptr @bork2, i64 %14
  %16 = mul nuw nsw i64 %14, %5
  %17 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %16
  br label %21

18:                                               ; preds = %21
  %19 = add nuw nsw i64 %22, 1
  %20 = icmp eq i64 %19, %7
  br i1 %20, label %29, label %21, !llvm.loop !12

21:                                               ; preds = %13, %18
  %22 = phi i64 [ 0, %13 ], [ %19, %18 ]
  %23 = getelementptr inbounds nuw [4 x i8], ptr %15, i64 %22
  %24 = load i32, ptr %23, align 4, !tbaa !11
  %25 = getelementptr inbounds nuw [4 x i8], ptr %17, i64 %22
  %26 = load i32, ptr %25, align 4, !tbaa !11
  %27 = icmp eq i32 %24, %26
  br i1 %27, label %18, label %28

28:                                               ; preds = %21, %39
  tail call void @abort() #3
  unreachable

29:                                               ; preds = %18
  %30 = add nuw nsw i64 %14, 1
  %31 = icmp eq i64 %30, %12
  br i1 %31, label %32, label %13, !llvm.loop !13

32:                                               ; preds = %29
  %33 = getelementptr inbounds nuw [4 x i8], ptr %2, i64 %9
  br label %34

34:                                               ; preds = %49, %32
  %35 = phi i64 [ 0, %32 ], [ %50, %49 ]
  %36 = getelementptr inbounds nuw [16 x i8], ptr getelementptr inbounds nuw (i8, ptr @bork2, i64 48), i64 %35
  %37 = mul nuw nsw i64 %35, %5
  %38 = getelementptr inbounds nuw [4 x i8], ptr %33, i64 %37
  br label %39

39:                                               ; preds = %46, %34
  %40 = phi i64 [ 0, %34 ], [ %47, %46 ]
  %41 = getelementptr inbounds nuw [4 x i8], ptr %36, i64 %40
  %42 = load i32, ptr %41, align 4, !tbaa !11
  %43 = getelementptr inbounds nuw [4 x i8], ptr %38, i64 %40
  %44 = load i32, ptr %43, align 4, !tbaa !11
  %45 = icmp eq i32 %42, %44
  br i1 %45, label %46, label %28

46:                                               ; preds = %39
  %47 = add nuw nsw i64 %40, 1
  %48 = icmp eq i64 %47, %7
  br i1 %48, label %49, label %39, !llvm.loop !12

49:                                               ; preds = %46
  %50 = add nuw nsw i64 %35, 1
  %51 = icmp eq i64 %50, %12
  br i1 %51, label %52, label %34, !llvm.loop !13

52:                                               ; preds = %49, %3
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local void @test2() local_unnamed_addr #2 {
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  ret i32 0
}

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { cold nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { noreturn nounwind }

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
!12 = distinct !{!12, !10}
!13 = distinct !{!13, !10}
