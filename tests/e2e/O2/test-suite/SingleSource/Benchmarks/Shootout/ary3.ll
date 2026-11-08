; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/ary3.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = icmp eq i32 %0, 2
  br i1 %3, label %4, label %9

4:                                                ; preds = %2
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %6 = load ptr, ptr %5, align 8, !tbaa !9
  %7 = tail call i64 @strtol(ptr noundef nonnull captures(none) %6, ptr noundef null, i32 noundef 10) #5, !inline_history !12
  %8 = trunc i64 %7 to i32
  br label %9

9:                                                ; preds = %2, %4
  %10 = phi i32 [ %8, %4 ], [ 1500000, %2 ]
  %11 = sext i32 %10 to i64
  %12 = tail call noalias ptr @calloc(i64 noundef %11, i64 noundef 4) #6
  %13 = tail call noalias ptr @calloc(i64 noundef %11, i64 noundef 4) #6
  %14 = icmp sgt i32 %10, 0
  br i1 %14, label %15, label %88

15:                                               ; preds = %9
  %16 = zext nneg i32 %10 to i64
  %17 = icmp ult i32 %10, 8
  br i1 %17, label %34, label %18

18:                                               ; preds = %15
  %19 = and i64 %16, 2147483640
  br label %20

20:                                               ; preds = %20, %18
  %21 = phi i64 [ 0, %18 ], [ %29, %20 ]
  %22 = phi <4 x i64> [ <i64 0, i64 1, i64 2, i64 3>, %18 ], [ %30, %20 ]
  %23 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %21
  %24 = trunc <4 x i64> %22 to <4 x i32>
  %25 = add <4 x i32> %24, splat (i32 1)
  %26 = trunc <4 x i64> %22 to <4 x i32>
  %27 = add <4 x i32> %26, splat (i32 5)
  %28 = getelementptr inbounds nuw i8, ptr %23, i64 16
  store <4 x i32> %25, ptr %23, align 4, !tbaa !13
  store <4 x i32> %27, ptr %28, align 4, !tbaa !13
  %29 = add nuw i64 %21, 8
  %30 = add nuw <4 x i64> %22, splat (i64 8)
  %31 = icmp eq i64 %29, %19
  br i1 %31, label %32, label %20, !llvm.loop !14

32:                                               ; preds = %20
  %33 = icmp eq i64 %19, %16
  br i1 %33, label %36, label %34

34:                                               ; preds = %15, %32
  %35 = phi i64 [ 0, %15 ], [ %19, %32 ]
  br label %42

36:                                               ; preds = %42, %32
  %37 = zext nneg i32 %10 to i64
  %38 = icmp ult i32 %10, 8
  %39 = and i64 %16, 2147483640
  %40 = sub nsw i64 %37, %39
  %41 = icmp eq i64 %39, %16
  br label %48

42:                                               ; preds = %34, %42
  %43 = phi i64 [ %44, %42 ], [ %35, %34 ]
  %44 = add nuw nsw i64 %43, 1
  %45 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %43
  %46 = trunc nuw nsw i64 %44 to i32
  store i32 %46, ptr %45, align 4, !tbaa !13
  %47 = icmp eq i64 %44, %16
  br i1 %47, label %36, label %42, !llvm.loop !18

48:                                               ; preds = %36, %80
  %49 = phi i32 [ %81, %80 ], [ 0, %36 ]
  br i1 %38, label %69, label %50

50:                                               ; preds = %48, %50
  %51 = phi i64 [ %66, %50 ], [ 0, %48 ]
  %52 = xor i64 %51, -1
  %53 = add i64 %52, %37
  %54 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %53
  %55 = getelementptr inbounds i8, ptr %54, i64 -12
  %56 = getelementptr inbounds i8, ptr %54, i64 -28
  %57 = load <4 x i32>, ptr %55, align 4, !tbaa !13
  %58 = load <4 x i32>, ptr %56, align 4, !tbaa !13
  %59 = getelementptr inbounds nuw [4 x i8], ptr %13, i64 %53
  %60 = getelementptr inbounds i8, ptr %59, i64 -12
  %61 = getelementptr inbounds i8, ptr %59, i64 -28
  %62 = load <4 x i32>, ptr %60, align 4, !tbaa !13
  %63 = load <4 x i32>, ptr %61, align 4, !tbaa !13
  %64 = add nsw <4 x i32> %62, %57
  %65 = add nsw <4 x i32> %63, %58
  store <4 x i32> %64, ptr %60, align 4, !tbaa !13
  store <4 x i32> %65, ptr %61, align 4, !tbaa !13
  %66 = add nuw i64 %51, 8
  %67 = icmp eq i64 %66, %39
  br i1 %67, label %68, label %50, !llvm.loop !19

68:                                               ; preds = %50
  br i1 %41, label %80, label %69

69:                                               ; preds = %48, %68
  %70 = phi i64 [ %37, %48 ], [ %40, %68 ]
  br label %71

71:                                               ; preds = %69, %71
  %72 = phi i64 [ %73, %71 ], [ %70, %69 ]
  %73 = add nsw i64 %72, -1
  %74 = getelementptr inbounds nuw [4 x i8], ptr %12, i64 %73
  %75 = load i32, ptr %74, align 4, !tbaa !13
  %76 = getelementptr inbounds nuw [4 x i8], ptr %13, i64 %73
  %77 = load i32, ptr %76, align 4, !tbaa !13
  %78 = add nsw i32 %77, %75
  store i32 %78, ptr %76, align 4, !tbaa !13
  %79 = icmp sgt i64 %72, 1
  br i1 %79, label %71, label %80, !llvm.loop !20

80:                                               ; preds = %71, %68
  %81 = add nuw nsw i32 %49, 1
  %82 = icmp eq i32 %81, 1000
  br i1 %82, label %83, label %48, !llvm.loop !21

83:                                               ; preds = %80
  %84 = load i32, ptr %13, align 4, !tbaa !13
  %85 = getelementptr [4 x i8], ptr %13, i64 %11
  %86 = getelementptr i8, ptr %85, i64 -4
  %87 = load i32, ptr %86, align 4, !tbaa !13
  br label %88

88:                                               ; preds = %9, %83
  %89 = phi i32 [ %87, %83 ], [ 0, %9 ]
  %90 = phi i32 [ %84, %83 ], [ 0, %9 ]
  %91 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %90, i32 noundef %89)
  tail call void @free(ptr noundef %12) #5
  tail call void @free(ptr noundef %13) #5
  ret i32 0
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @calloc(i64 noundef, i64 noundef) local_unnamed_addr #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree nounwind willreturn allockind("alloc,zeroed") allocsize(0,1) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind allocsize(0,1) }

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = distinct !{null}
!13 = !{!6, !6, i64 0}
!14 = distinct !{!14, !15, !16, !17}
!15 = !{!"llvm.loop.mustprogress"}
!16 = !{!"llvm.loop.isvectorized", i32 1}
!17 = !{!"llvm.loop.unroll.runtime.disable"}
!18 = distinct !{!18, !15, !17, !16}
!19 = distinct !{!19, !15, !16, !17}
!20 = distinct !{!20, !15, !17, !16}
!21 = distinct !{!21, !15}
