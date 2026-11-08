; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-12-13-MishaTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"Sum is %d\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable
define dso_local i32 @sum(ptr nofree noundef captures(none) %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = shl i32 %2, 16
  %5 = ashr exact i32 %4, 16
  %6 = icmp eq i32 %4, 0
  br i1 %6, label %111, label %7

7:                                                ; preds = %3
  %8 = load i16, ptr %0, align 2, !tbaa !9
  %9 = zext i32 %5 to i64
  %10 = icmp ult i32 %5, 4
  br i1 %10, label %69, label %11

11:                                               ; preds = %7
  %12 = getelementptr i8, ptr %0, i64 2
  %13 = add nsw i32 %5, -1
  %14 = zext i32 %13 to i64
  %15 = shl nuw nsw i64 %14, 1
  %16 = getelementptr i8, ptr %1, i64 %15
  %17 = getelementptr i8, ptr %16, i64 2
  %18 = icmp ult ptr %0, %17
  %19 = icmp ult ptr %1, %12
  %20 = and i1 %18, %19
  br i1 %20, label %69, label %21

21:                                               ; preds = %11
  %22 = icmp ult i32 %5, 16
  br i1 %22, label %49, label %23

23:                                               ; preds = %21
  %24 = and i64 %9, 12
  %25 = and i64 %9, 4294967280
  %26 = trunc nuw i64 %25 to i32
  %27 = shl nuw nsw i64 %25, 1
  %28 = getelementptr i8, ptr %1, i64 %27
  %29 = insertelement <8 x i16> <i16 poison, i16 0, i16 0, i16 0, i16 0, i16 0, i16 0, i16 0>, i16 %8, i64 0
  br label %30

30:                                               ; preds = %30, %23
  %31 = phi i64 [ 0, %23 ], [ %41, %30 ]
  %32 = phi <8 x i16> [ %29, %23 ], [ %39, %30 ]
  %33 = phi <8 x i16> [ zeroinitializer, %23 ], [ %40, %30 ]
  %34 = shl i64 %31, 1
  %35 = getelementptr i8, ptr %1, i64 %34
  %36 = getelementptr i8, ptr %35, i64 16
  %37 = load <8 x i16>, ptr %35, align 2, !tbaa !9, !alias.scope !11
  %38 = load <8 x i16>, ptr %36, align 2, !tbaa !9, !alias.scope !11
  %39 = add <8 x i16> %32, %37
  %40 = add <8 x i16> %33, %38
  %41 = add nuw i64 %31, 16
  %42 = icmp eq i64 %41, %25
  br i1 %42, label %43, label %30, !llvm.loop !14

43:                                               ; preds = %30
  %44 = add <8 x i16> %40, %39
  %45 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %44)
  store i16 %45, ptr %0, align 2, !tbaa !9, !alias.scope !18, !noalias !11
  %46 = icmp eq i64 %25, %9
  br i1 %46, label %111, label %47

47:                                               ; preds = %43
  %48 = icmp eq i64 %24, 0
  br i1 %48, label %69, label %49, !prof !20

49:                                               ; preds = %21, %47
  %50 = phi i64 [ %25, %47 ], [ 0, %21 ]
  %51 = phi i16 [ %45, %47 ], [ %8, %21 ]
  %52 = and i64 %9, 4294967292
  %53 = trunc nuw i64 %52 to i32
  %54 = shl nuw nsw i64 %52, 1
  %55 = getelementptr i8, ptr %1, i64 %54
  %56 = insertelement <4 x i16> <i16 poison, i16 0, i16 0, i16 0>, i16 %51, i64 0
  br label %57

57:                                               ; preds = %57, %49
  %58 = phi i64 [ %50, %49 ], [ %64, %57 ]
  %59 = phi <4 x i16> [ %56, %49 ], [ %63, %57 ]
  %60 = shl i64 %58, 1
  %61 = getelementptr i8, ptr %1, i64 %60
  %62 = load <4 x i16>, ptr %61, align 2, !tbaa !9, !alias.scope !11
  %63 = add <4 x i16> %59, %62
  %64 = add nuw i64 %58, 4
  %65 = icmp eq i64 %64, %52
  br i1 %65, label %66, label %57, !llvm.loop !21

66:                                               ; preds = %57
  %67 = tail call i16 @llvm.vector.reduce.add.v4i16(<4 x i16> %63)
  store i16 %67, ptr %0, align 2, !tbaa !9, !alias.scope !18, !noalias !11
  %68 = icmp eq i64 %52, %9
  br i1 %68, label %111, label %69

69:                                               ; preds = %11, %7, %47, %66
  %70 = phi i16 [ %8, %7 ], [ %8, %11 ], [ %45, %47 ], [ %67, %66 ]
  %71 = phi i32 [ 0, %7 ], [ 0, %11 ], [ %26, %47 ], [ %53, %66 ]
  %72 = phi ptr [ %1, %7 ], [ %1, %11 ], [ %28, %47 ], [ %55, %66 ]
  %73 = sub i32 %2, %71
  %74 = and i32 %73, 3
  %75 = icmp eq i32 %74, 0
  br i1 %75, label %87, label %76

76:                                               ; preds = %69, %76
  %77 = phi i16 [ %83, %76 ], [ %70, %69 ]
  %78 = phi i32 [ %84, %76 ], [ %71, %69 ]
  %79 = phi ptr [ %81, %76 ], [ %72, %69 ]
  %80 = phi i32 [ %85, %76 ], [ 0, %69 ]
  %81 = getelementptr inbounds nuw i8, ptr %79, i64 2
  %82 = load i16, ptr %79, align 2, !tbaa !9
  %83 = add i16 %77, %82
  store i16 %83, ptr %0, align 2, !tbaa !9
  %84 = add nuw nsw i32 %78, 1
  %85 = add i32 %80, 1
  %86 = icmp eq i32 %85, %74
  br i1 %86, label %87, label %76, !llvm.loop !22

87:                                               ; preds = %76, %69
  %88 = phi i16 [ %70, %69 ], [ %83, %76 ]
  %89 = phi i32 [ %71, %69 ], [ %84, %76 ]
  %90 = phi ptr [ %72, %69 ], [ %81, %76 ]
  %91 = sub i32 %71, %5
  %92 = icmp ugt i32 %91, -4
  br i1 %92, label %111, label %93

93:                                               ; preds = %87, %93
  %94 = phi i16 [ %108, %93 ], [ %88, %87 ]
  %95 = phi i32 [ %109, %93 ], [ %89, %87 ]
  %96 = phi ptr [ %106, %93 ], [ %90, %87 ]
  %97 = getelementptr inbounds nuw i8, ptr %96, i64 2
  %98 = load i16, ptr %96, align 2, !tbaa !9
  %99 = add i16 %94, %98
  store i16 %99, ptr %0, align 2, !tbaa !9
  %100 = getelementptr inbounds nuw i8, ptr %96, i64 4
  %101 = load i16, ptr %97, align 2, !tbaa !9
  %102 = add i16 %99, %101
  store i16 %102, ptr %0, align 2, !tbaa !9
  %103 = getelementptr inbounds nuw i8, ptr %96, i64 6
  %104 = load i16, ptr %100, align 2, !tbaa !9
  %105 = add i16 %102, %104
  store i16 %105, ptr %0, align 2, !tbaa !9
  %106 = getelementptr inbounds nuw i8, ptr %96, i64 8
  %107 = load i16, ptr %103, align 2, !tbaa !9
  %108 = add i16 %105, %107
  store i16 %108, ptr %0, align 2, !tbaa !9
  %109 = add nuw nsw i32 %95, 4
  %110 = icmp eq i32 %109, %5
  br i1 %110, label %111, label %93, !llvm.loop !24

111:                                              ; preds = %87, %93, %43, %66, %3
  ret i32 undef
}

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #1 {
  %1 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef 1)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i16 @llvm.vector.reduce.add.v8i16(<8 x i16>) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i16 @llvm.vector.reduce.add.v4i16(<4 x i16>) #3

attributes #0 = { nofree norecurse nosync nounwind memory(argmem: readwrite) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"short", !7, i64 0}
!11 = !{!12}
!12 = distinct !{!12, !13}
!13 = distinct !{!13, !"LVerDomain"}
!14 = distinct !{!14, !15, !16, !17}
!15 = !{!"llvm.loop.mustprogress"}
!16 = !{!"llvm.loop.isvectorized", i32 1}
!17 = !{!"llvm.loop.unroll.runtime.disable"}
!18 = !{!19}
!19 = distinct !{!19, !13}
!20 = !{!"branch_weights", i32 4, i32 12}
!21 = distinct !{!21, !15, !16, !17}
!22 = distinct !{!22, !23}
!23 = !{!"llvm.loop.unroll.disable"}
!24 = distinct !{!24, !15, !16}
