; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S = type { [9 x i8] }

@f = dso_local local_unnamed_addr global i32 0, align 4
@__const.main.m = private unnamed_addr constant { i8, i8, i8, i8, i8, i8, i8, i8, i8 } { i8 5, i8 0, i8 -40, i8 -1, i8 -1, i8 79, i8 0, i8 20, i8 0 }, align 1
@h = dso_local local_unnamed_addr global %struct.S zeroinitializer, align 16

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = load i32, ptr @f, align 4, !tbaa !9
  %2 = icmp eq i32 %1, 0
  br i1 %2, label %16, label %3

3:                                                ; preds = %0
  %4 = sub i32 0, %1
  %5 = and i32 %4, 3
  %6 = icmp eq i32 %5, 0
  br i1 %6, label %13, label %7

7:                                                ; preds = %3, %7
  %8 = phi i32 [ %10, %7 ], [ %1, %3 ]
  %9 = phi i32 [ %11, %7 ], [ 0, %3 ]
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(9) @h, ptr noundef nonnull align 1 dereferenceable(9) @__const.main.m, i64 9, i1 false), !tbaa.struct !10
  %10 = add nsw i32 %8, 1
  %11 = add i32 %9, 1
  %12 = icmp eq i32 %11, %5
  br i1 %12, label %13, label %7, !llvm.loop !12

13:                                               ; preds = %7, %3
  %14 = phi i32 [ %1, %3 ], [ %10, %7 ]
  %15 = icmp ugt i32 %1, -4
  br i1 %15, label %28, label %24

16:                                               ; preds = %0
  %17 = load i72, ptr @h, align 16
  %18 = shl i72 %17, 14
  %19 = ashr i72 %18, 57
  %20 = trunc nsw i72 %19 to i32
  %21 = trunc nsw i72 %19 to i64
  %22 = mul nsw i32 %20, %20
  %23 = zext nneg i32 %22 to i64
  br label %29

24:                                               ; preds = %13, %24
  %25 = phi i32 [ %26, %24 ], [ %14, %13 ]
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(9) @h, ptr noundef nonnull align 1 dereferenceable(9) @__const.main.m, i64 9, i1 false), !tbaa.struct !10
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(9) @h, ptr noundef nonnull align 1 dereferenceable(9) @__const.main.m, i64 9, i1 false), !tbaa.struct !10
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(9) @h, ptr noundef nonnull align 1 dereferenceable(9) @__const.main.m, i64 9, i1 false), !tbaa.struct !10
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(9) @h, ptr noundef nonnull align 1 dereferenceable(9) @__const.main.m, i64 9, i1 false), !tbaa.struct !10
  %26 = add nsw i32 %25, 4
  %27 = icmp eq i32 %26, 0
  br i1 %27, label %28, label %24, !llvm.loop !14

28:                                               ; preds = %24, %13
  store i32 0, ptr @f, align 4, !tbaa !9
  br label %29

29:                                               ; preds = %16, %28
  %30 = phi i64 [ %23, %16 ], [ 81, %28 ]
  %31 = phi i64 [ %21, %16 ], [ 9, %28 ]
  %32 = sub nsw i64 0, %30
  %33 = icmp eq i64 %31, %32
  br i1 %33, label %36, label %34

34:                                               ; preds = %29
  %35 = tail call i32 @putchar(i32 49)
  br label %36

36:                                               ; preds = %34, %29
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nofree nounwind
declare noundef i32 @putchar(i32 noundef) local_unnamed_addr #2

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind }

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
!10 = !{i64 0, i64 9, !11}
!11 = !{!7, !7, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.unroll.disable"}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
