; @source: tests/e2e/src/memory/pointers.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/pointers.c'
source_filename = "tests/e2e/src/memory/pointers.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.arr = private unnamed_addr constant [8 x i32] [i32 5, i32 3, i32 8, i32 1, i32 9, i32 2, i32 7, i32 4], align 16
@.str = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca [8 x i32], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #4
  call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(32) %1, ptr noundef nonnull align 16 dereferenceable(32) @__const.main.arr, i64 32, i1 false)
  br label %2

2:                                                ; preds = %0, %24
  %3 = phi i64 [ 0, %0 ], [ %28, %24 ]
  %4 = phi i64 [ 7, %0 ], [ %26, %24 ]
  %5 = phi i32 [ 0, %0 ], [ %25, %24 ]
  %6 = icmp samesign ult i32 %5, 7
  br i1 %6, label %7, label %24

7:                                                ; preds = %2
  %8 = and i64 %4, 1
  %9 = icmp eq i64 %3, 6
  br i1 %9, label %14, label %10

10:                                               ; preds = %7
  %11 = and i64 %4, -2
  br label %55

12:                                               ; preds = %74
  %13 = icmp eq i64 %8, 0
  br i1 %13, label %24, label %14

14:                                               ; preds = %12, %7
  %15 = phi i64 [ 0, %7 ], [ %76, %12 ]
  %16 = phi i64 [ 1, %7 ], [ %75, %12 ]
  %17 = trunc i64 %4 to i1
  tail call void @llvm.assume(i1 %17)
  %18 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %15
  %19 = load i32, ptr %18, align 4, !tbaa !9
  %20 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %16
  %21 = load i32, ptr %20, align 4, !tbaa !9
  %22 = icmp sgt i32 %19, %21
  br i1 %22, label %23, label %24

23:                                               ; preds = %14
  store i32 %21, ptr %18, align 4, !tbaa !9
  store i32 %19, ptr %20, align 4, !tbaa !9
  br label %24

24:                                               ; preds = %12, %23, %14, %2
  %25 = add nuw nsw i32 %5, 1
  %26 = add nsw i64 %4, -1
  %27 = icmp eq i32 %25, 8
  %28 = add i64 %3, 1
  br i1 %27, label %29, label %2, !llvm.loop !10

29:                                               ; preds = %24
  %30 = load i32, ptr %1, align 16, !tbaa !9
  %31 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %30)
  %32 = getelementptr inbounds nuw i8, ptr %1, i64 4
  %33 = load i32, ptr %32, align 4, !tbaa !9
  %34 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %33)
  %35 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %36 = load i32, ptr %35, align 8, !tbaa !9
  %37 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %36)
  %38 = getelementptr inbounds nuw i8, ptr %1, i64 12
  %39 = load i32, ptr %38, align 4, !tbaa !9
  %40 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %39)
  %41 = getelementptr inbounds nuw i8, ptr %1, i64 16
  %42 = load i32, ptr %41, align 16, !tbaa !9
  %43 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %42)
  %44 = getelementptr inbounds nuw i8, ptr %1, i64 20
  %45 = load i32, ptr %44, align 4, !tbaa !9
  %46 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %45)
  %47 = getelementptr inbounds nuw i8, ptr %1, i64 24
  %48 = load i32, ptr %47, align 8, !tbaa !9
  %49 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %48)
  %50 = getelementptr inbounds nuw i8, ptr %1, i64 28
  %51 = load i32, ptr %50, align 4, !tbaa !9
  %52 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %51)
  %53 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i64 noundef 8)
  %54 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %39)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #4
  ret i32 0

55:                                               ; preds = %74, %10
  %56 = phi i64 [ 0, %10 ], [ %76, %74 ]
  %57 = phi i64 [ 1, %10 ], [ %75, %74 ]
  %58 = phi i64 [ 0, %10 ], [ %77, %74 ]
  %59 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %56
  %60 = load i32, ptr %59, align 8, !tbaa !9
  %61 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %57
  %62 = load i32, ptr %61, align 4, !tbaa !9
  %63 = icmp sgt i32 %60, %62
  br i1 %63, label %64, label %65

64:                                               ; preds = %55
  store i32 %62, ptr %59, align 8, !tbaa !9
  store i32 %60, ptr %61, align 4, !tbaa !9
  br label %65

65:                                               ; preds = %55, %64
  %66 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %56
  %67 = getelementptr inbounds nuw i8, ptr %66, i64 4
  %68 = load i32, ptr %67, align 4, !tbaa !9
  %69 = getelementptr inbounds nuw [4 x i8], ptr %1, i64 %57
  %70 = getelementptr inbounds nuw i8, ptr %69, i64 4
  %71 = load i32, ptr %70, align 4, !tbaa !9
  %72 = icmp sgt i32 %68, %71
  br i1 %72, label %73, label %74

73:                                               ; preds = %65
  store i32 %71, ptr %67, align 4, !tbaa !9
  store i32 %68, ptr %70, align 4, !tbaa !9
  br label %74

74:                                               ; preds = %73, %65
  %75 = add nuw nsw i64 %57, 2
  %76 = add nuw nsw i64 %56, 2
  %77 = add i64 %58, 2
  %78 = icmp eq i64 %77, %11
  br i1 %78, label %12, label %55, !llvm.loop !12
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #3

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #4 = { nounwind }

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
!12 = distinct !{!12, !11}
