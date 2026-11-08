; @source: tests/function/src/memory/buffers.c
; @llc: -O2
; @driver: tests/function/src/memory/buffers.driver.c
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/memory/buffers.c'
source_filename = "tests/function/src/memory/buffers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @reverse(ptr nofree noundef captures(none) %0, i64 noundef %1) local_unnamed_addr #0 {
  %3 = icmp ult i64 %1, 2
  br i1 %3, label %6, label %4

4:                                                ; preds = %2
  %5 = add i64 %1, -1
  br label %7

6:                                                ; preds = %7, %2
  ret void

7:                                                ; preds = %4, %7
  %8 = phi i64 [ %14, %7 ], [ 0, %4 ]
  %9 = phi i64 [ %15, %7 ], [ %5, %4 ]
  %10 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %8
  %11 = load i32, ptr %10, align 4, !tbaa !9
  %12 = getelementptr inbounds nuw [4 x i8], ptr %0, i64 %9
  %13 = load i32, ptr %12, align 4, !tbaa !9
  store i32 %13, ptr %10, align 4, !tbaa !9
  store i32 %11, ptr %12, align 4, !tbaa !9
  %14 = add nuw i64 %8, 1
  %15 = add i64 %9, -1
  %16 = icmp ult i64 %14, %15
  br i1 %16, label %7, label %6, !llvm.loop !10
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i64 @dot(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #1 {
  %4 = icmp sgt i32 %2, 0
  br i1 %4, label %5, label %32

5:                                                ; preds = %3
  %6 = zext nneg i32 %2 to i64
  %7 = and i64 %6, 3
  %8 = icmp ult i32 %2, 4
  br i1 %8, label %13, label %9

9:                                                ; preds = %5
  %10 = and i64 %6, 2147483644
  br label %34

11:                                               ; preds = %34
  %12 = icmp eq i64 %7, 0
  br i1 %12, label %32, label %13

13:                                               ; preds = %11, %5
  %14 = phi i64 [ 0, %5 ], [ %73, %11 ]
  %15 = phi i64 [ 0, %5 ], [ %72, %11 ]
  %16 = icmp ne i64 %7, 0
  tail call void @llvm.assume(i1 %16)
  br label %17

17:                                               ; preds = %17, %13
  %18 = phi i64 [ %14, %13 ], [ %29, %17 ]
  %19 = phi i64 [ %15, %13 ], [ %28, %17 ]
  %20 = phi i64 [ 0, %13 ], [ %30, %17 ]
  %21 = getelementptr inbounds nuw [2 x i8], ptr %0, i64 %18
  %22 = load i16, ptr %21, align 2, !tbaa !12
  %23 = sext i16 %22 to i64
  %24 = getelementptr inbounds nuw [2 x i8], ptr %1, i64 %18
  %25 = load i16, ptr %24, align 2, !tbaa !12
  %26 = sext i16 %25 to i64
  %27 = mul nsw i64 %26, %23
  %28 = add nsw i64 %27, %19
  %29 = add nuw nsw i64 %18, 1
  %30 = add i64 %20, 1
  %31 = icmp eq i64 %30, %7
  br i1 %31, label %32, label %17, !llvm.loop !14

32:                                               ; preds = %11, %17, %3
  %33 = phi i64 [ 0, %3 ], [ %72, %11 ], [ %28, %17 ]
  ret i64 %33

34:                                               ; preds = %34, %9
  %35 = phi i64 [ 0, %9 ], [ %73, %34 ]
  %36 = phi i64 [ 0, %9 ], [ %72, %34 ]
  %37 = phi i64 [ 0, %9 ], [ %74, %34 ]
  %38 = getelementptr inbounds nuw [2 x i8], ptr %0, i64 %35
  %39 = load i16, ptr %38, align 2, !tbaa !12
  %40 = sext i16 %39 to i64
  %41 = getelementptr inbounds nuw [2 x i8], ptr %1, i64 %35
  %42 = load i16, ptr %41, align 2, !tbaa !12
  %43 = sext i16 %42 to i64
  %44 = mul nsw i64 %43, %40
  %45 = add nsw i64 %44, %36
  %46 = or disjoint i64 %35, 1
  %47 = getelementptr inbounds nuw [2 x i8], ptr %0, i64 %46
  %48 = load i16, ptr %47, align 2, !tbaa !12
  %49 = sext i16 %48 to i64
  %50 = getelementptr inbounds nuw [2 x i8], ptr %1, i64 %46
  %51 = load i16, ptr %50, align 2, !tbaa !12
  %52 = sext i16 %51 to i64
  %53 = mul nsw i64 %52, %49
  %54 = add nsw i64 %53, %45
  %55 = or disjoint i64 %35, 2
  %56 = getelementptr inbounds nuw [2 x i8], ptr %0, i64 %55
  %57 = load i16, ptr %56, align 2, !tbaa !12
  %58 = sext i16 %57 to i64
  %59 = getelementptr inbounds nuw [2 x i8], ptr %1, i64 %55
  %60 = load i16, ptr %59, align 2, !tbaa !12
  %61 = sext i16 %60 to i64
  %62 = mul nsw i64 %61, %58
  %63 = add nsw i64 %62, %54
  %64 = or disjoint i64 %35, 3
  %65 = getelementptr inbounds nuw [2 x i8], ptr %0, i64 %64
  %66 = load i16, ptr %65, align 2, !tbaa !12
  %67 = sext i16 %66 to i64
  %68 = getelementptr inbounds nuw [2 x i8], ptr %1, i64 %64
  %69 = load i16, ptr %68, align 2, !tbaa !12
  %70 = sext i16 %69 to i64
  %71 = mul nsw i64 %70, %67
  %72 = add nsw i64 %71, %63
  %73 = add nuw nsw i64 %35, 4
  %74 = add i64 %37, 4
  %75 = icmp eq i64 %74, %10
  br i1 %75, label %11, label %34, !llvm.loop !16
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local void @prefix_sum(ptr nofree noundef captures(none) %0, i32 noundef %1) local_unnamed_addr #0 {
  %3 = icmp sgt i32 %1, 1
  br i1 %3, label %4, label %29

4:                                                ; preds = %2
  %5 = zext nneg i32 %1 to i64
  %6 = load double, ptr %0, align 8
  %7 = add nsw i64 %5, -1
  %8 = and i64 %7, 3
  %9 = add nsw i32 %1, -2
  %10 = icmp ult i32 %9, 3
  br i1 %10, label %15, label %11

11:                                               ; preds = %4
  %12 = and i64 %7, -4
  br label %30

13:                                               ; preds = %30
  %14 = icmp eq i64 %8, 0
  br i1 %14, label %29, label %15

15:                                               ; preds = %13, %4
  %16 = phi double [ %6, %4 ], [ %48, %13 ]
  %17 = phi i64 [ 1, %4 ], [ %49, %13 ]
  %18 = icmp ne i64 %8, 0
  tail call void @llvm.assume(i1 %18)
  br label %19

19:                                               ; preds = %19, %15
  %20 = phi double [ %16, %15 ], [ %25, %19 ]
  %21 = phi i64 [ %17, %15 ], [ %26, %19 ]
  %22 = phi i64 [ 0, %15 ], [ %27, %19 ]
  %23 = getelementptr [8 x i8], ptr %0, i64 %21
  %24 = load double, ptr %23, align 8, !tbaa !17
  %25 = fadd double %20, %24
  store double %25, ptr %23, align 8, !tbaa !17
  %26 = add nuw nsw i64 %21, 1
  %27 = add i64 %22, 1
  %28 = icmp eq i64 %27, %8
  br i1 %28, label %29, label %19, !llvm.loop !19

29:                                               ; preds = %13, %19, %2
  ret void

30:                                               ; preds = %30, %11
  %31 = phi double [ %6, %11 ], [ %48, %30 ]
  %32 = phi i64 [ 1, %11 ], [ %49, %30 ]
  %33 = phi i64 [ 0, %11 ], [ %50, %30 ]
  %34 = getelementptr [8 x i8], ptr %0, i64 %32
  %35 = load double, ptr %34, align 8, !tbaa !17
  %36 = fadd double %31, %35
  store double %36, ptr %34, align 8, !tbaa !17
  %37 = getelementptr [8 x i8], ptr %0, i64 %32
  %38 = getelementptr i8, ptr %37, i64 8
  %39 = load double, ptr %38, align 8, !tbaa !17
  %40 = fadd double %36, %39
  store double %40, ptr %38, align 8, !tbaa !17
  %41 = getelementptr [8 x i8], ptr %0, i64 %32
  %42 = getelementptr i8, ptr %41, i64 16
  %43 = load double, ptr %42, align 8, !tbaa !17
  %44 = fadd double %40, %43
  store double %44, ptr %42, align 8, !tbaa !17
  %45 = getelementptr [8 x i8], ptr %0, i64 %32
  %46 = getelementptr i8, ptr %45, i64 24
  %47 = load double, ptr %46, align 8, !tbaa !17
  %48 = fadd double %44, %47
  store double %48, ptr %46, align 8, !tbaa !17
  %49 = add nuw nsw i64 %32, 4
  %50 = add nuw i64 %33, 4
  %51 = icmp eq i64 %50, %12
  br i1 %51, label %13, label %30, !llvm.loop !20
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i64 @count_byte(ptr nofree noundef readonly captures(none) %0, i64 noundef %1, i8 noundef zeroext %2) local_unnamed_addr #1 {
  %4 = icmp eq i64 %1, 0
  br i1 %4, label %48, label %5

5:                                                ; preds = %3
  %6 = icmp ult i64 %1, 4
  br i1 %6, label %33, label %7

7:                                                ; preds = %5
  %8 = and i64 %1, -4
  %9 = getelementptr i8, ptr %0, i64 %8
  %10 = and i64 %1, 3
  %11 = insertelement <2 x i8> poison, i8 %2, i64 0
  %12 = shufflevector <2 x i8> %11, <2 x i8> poison, <2 x i32> zeroinitializer
  br label %13

13:                                               ; preds = %13, %7
  %14 = phi i64 [ 0, %7 ], [ %27, %13 ]
  %15 = phi <2 x i64> [ zeroinitializer, %7 ], [ %25, %13 ]
  %16 = phi <2 x i64> [ zeroinitializer, %7 ], [ %26, %13 ]
  %17 = getelementptr i8, ptr %0, i64 %14
  %18 = getelementptr i8, ptr %17, i64 2
  %19 = load <2 x i8>, ptr %17, align 1, !tbaa !21
  %20 = load <2 x i8>, ptr %18, align 1, !tbaa !21
  %21 = icmp eq <2 x i8> %19, %12
  %22 = icmp eq <2 x i8> %20, %12
  %23 = zext <2 x i1> %21 to <2 x i64>
  %24 = zext <2 x i1> %22 to <2 x i64>
  %25 = add <2 x i64> %15, %23
  %26 = add <2 x i64> %16, %24
  %27 = add nuw i64 %14, 4
  %28 = icmp eq i64 %27, %8
  br i1 %28, label %29, label %13, !llvm.loop !22

29:                                               ; preds = %13
  %30 = add <2 x i64> %26, %25
  %31 = tail call i64 @llvm.vector.reduce.add.v2i64(<2 x i64> %30)
  %32 = icmp eq i64 %1, %8
  br i1 %32, label %48, label %33

33:                                               ; preds = %5, %29
  %34 = phi i64 [ 0, %5 ], [ %31, %29 ]
  %35 = phi ptr [ %0, %5 ], [ %9, %29 ]
  %36 = phi i64 [ %1, %5 ], [ %10, %29 ]
  br label %37

37:                                               ; preds = %33, %37
  %38 = phi i64 [ %46, %37 ], [ %34, %33 ]
  %39 = phi ptr [ %42, %37 ], [ %35, %33 ]
  %40 = phi i64 [ %41, %37 ], [ %36, %33 ]
  %41 = add i64 %40, -1
  %42 = getelementptr inbounds nuw i8, ptr %39, i64 1
  %43 = load i8, ptr %39, align 1, !tbaa !21
  %44 = icmp eq i8 %43, %2
  %45 = zext i1 %44 to i64
  %46 = add i64 %38, %45
  %47 = icmp eq i64 %41, 0
  br i1 %47, label %48, label %37, !llvm.loop !25

48:                                               ; preds = %37, %29, %3
  %49 = phi i64 [ 0, %3 ], [ %31, %29 ], [ %46, %37 ]
  ret i64 %49
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable
define dso_local void @transpose4(ptr nofree noundef captures(none) %0) local_unnamed_addr #2 {
  %2 = getelementptr inbounds nuw i8, ptr %0, i64 4
  %3 = load float, ptr %2, align 4, !tbaa !26
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %5 = load float, ptr %4, align 4, !tbaa !26
  store float %5, ptr %2, align 4, !tbaa !26
  store float %3, ptr %4, align 4, !tbaa !26
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %7 = load float, ptr %6, align 4, !tbaa !26
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 32
  %9 = load float, ptr %8, align 4, !tbaa !26
  store float %9, ptr %6, align 4, !tbaa !26
  store float %7, ptr %8, align 4, !tbaa !26
  %10 = getelementptr inbounds nuw i8, ptr %0, i64 12
  %11 = load float, ptr %10, align 4, !tbaa !26
  %12 = getelementptr inbounds nuw i8, ptr %0, i64 48
  %13 = load float, ptr %12, align 4, !tbaa !26
  store float %13, ptr %10, align 4, !tbaa !26
  store float %11, ptr %12, align 4, !tbaa !26
  %14 = getelementptr inbounds nuw i8, ptr %0, i64 24
  %15 = load float, ptr %14, align 4, !tbaa !26
  %16 = getelementptr inbounds nuw i8, ptr %0, i64 36
  %17 = load float, ptr %16, align 4, !tbaa !26
  store float %17, ptr %14, align 4, !tbaa !26
  store float %15, ptr %16, align 4, !tbaa !26
  %18 = getelementptr inbounds nuw i8, ptr %0, i64 28
  %19 = load float, ptr %18, align 4, !tbaa !26
  %20 = getelementptr inbounds nuw i8, ptr %0, i64 52
  %21 = load float, ptr %20, align 4, !tbaa !26
  store float %21, ptr %18, align 4, !tbaa !26
  store float %19, ptr %20, align 4, !tbaa !26
  %22 = getelementptr inbounds nuw i8, ptr %0, i64 44
  %23 = load float, ptr %22, align 4, !tbaa !26
  %24 = getelementptr inbounds nuw i8, ptr %0, i64 56
  %25 = load float, ptr %24, align 4, !tbaa !26
  store float %25, ptr %22, align 4, !tbaa !26
  store float %23, ptr %24, align 4, !tbaa !26
  ret void
}

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define dso_local i64 @find(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, i32 noundef %2) local_unnamed_addr #1 {
  %4 = icmp sgt i32 %1, 0
  br i1 %4, label %5, label %18

5:                                                ; preds = %3
  %6 = zext nneg i32 %1 to i64
  br label %10

7:                                                ; preds = %10
  %8 = add nuw nsw i64 %11, 1
  %9 = icmp eq i64 %8, %6
  br i1 %9, label %18, label %10, !llvm.loop !28

10:                                               ; preds = %5, %7
  %11 = phi i64 [ 0, %5 ], [ %8, %7 ]
  %12 = getelementptr inbounds nuw [16 x i8], ptr %0, i64 %11
  %13 = load i32, ptr %12, align 8, !tbaa !29
  %14 = icmp eq i32 %13, %2
  br i1 %14, label %15, label %7

15:                                               ; preds = %10
  %16 = getelementptr inbounds nuw i8, ptr %12, i64 8
  %17 = load i64, ptr %16, align 8, !tbaa !32
  br label %18

18:                                               ; preds = %7, %3, %15
  %19 = phi i64 [ %17, %15 ], [ -1, %3 ], [ -1, %7 ]
  ret i64 %19
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.vector.reduce.add.v2i64(<2 x i64>) #4

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!13, !13, i64 0}
!13 = !{!"short", !7, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.unroll.disable"}
!16 = distinct !{!16, !11}
!17 = !{!18, !18, i64 0}
!18 = !{!"double", !7, i64 0}
!19 = distinct !{!19, !15}
!20 = distinct !{!20, !11}
!21 = !{!7, !7, i64 0}
!22 = distinct !{!22, !11, !23, !24}
!23 = !{!"llvm.loop.isvectorized", i32 1}
!24 = !{!"llvm.loop.unroll.runtime.disable"}
!25 = distinct !{!25, !11, !24, !23}
!26 = !{!27, !27, i64 0}
!27 = !{!"float", !7, i64 0}
!28 = distinct !{!28, !11}
!29 = !{!30, !6, i64 0}
!30 = !{!"pair", !6, i64 0, !31, i64 8}
!31 = !{!"long", !7, i64 0}
!32 = !{!30, !31, i64 8}
