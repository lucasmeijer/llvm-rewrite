; @source: tests/e2e/src/misc/sieve.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/sieve.c'
source_filename = "tests/e2e/src/misc/sieve.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.composite = internal unnamed_addr global [10001 x i8] zeroinitializer, align 16
@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(10001) @main.composite, i8 0, i64 10001, i1 false)
  br label %3

1:                                                ; preds = %20
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %21, i32 noundef %22)
  ret i32 0

3:                                                ; preds = %0, %20
  %4 = phi i64 [ 2, %0 ], [ %23, %20 ]
  %5 = phi i64 [ 4, %0 ], [ %24, %20 ]
  %6 = phi i32 [ 0, %0 ], [ %22, %20 ]
  %7 = phi i32 [ 0, %0 ], [ %21, %20 ]
  %8 = getelementptr inbounds nuw i8, ptr @main.composite, i64 %4
  %9 = load i8, ptr %8, align 1, !tbaa !9
  %10 = icmp eq i8 %9, 0
  br i1 %10, label %11, label %20

11:                                               ; preds = %3
  %12 = add nsw i32 %7, 1
  %13 = icmp samesign ult i64 %4, 5001
  %14 = trunc nuw nsw i64 %4 to i32
  br i1 %13, label %15, label %20

15:                                               ; preds = %11, %15
  %16 = phi i64 [ %18, %15 ], [ %5, %11 ]
  %17 = getelementptr inbounds nuw i8, ptr @main.composite, i64 %16
  store i8 1, ptr %17, align 1, !tbaa !9
  %18 = add nuw nsw i64 %16, %4
  %19 = icmp samesign ult i64 %18, 10001
  br i1 %19, label %15, label %20, !llvm.loop !10

20:                                               ; preds = %15, %11, %3
  %21 = phi i32 [ %7, %3 ], [ %12, %11 ], [ %12, %15 ]
  %22 = phi i32 [ %6, %3 ], [ %14, %11 ], [ %14, %15 ]
  %23 = add nuw nsw i64 %4, 1
  %24 = add nuw nsw i64 %5, 2
  %25 = icmp eq i64 %23, 10001
  br i1 %25, label %1, label %3, !llvm.loop !12
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!9 = !{!7, !7, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
