; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str.2 = private unnamed_addr constant [14 x i8] c"0x%x -> 0x%x\0A\00", align 1
@.str.3 = private unnamed_addr constant [18 x i8] c"0x%llx -> 0x%llx\0A\00", align 1

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i32 @ReverseBits32(i32 noundef %0) local_unnamed_addr #0 {
  %2 = tail call i32 @llvm.bitreverse.i32(i32 %0)
  ret i32 %2
}

; Function Attrs: mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local noundef i64 @ReverseBits64(i64 noundef %0) local_unnamed_addr #0 {
  %2 = tail call i64 @llvm.bitreverse.i64(i64 %0)
  ret i64 %2
}

; Function Attrs: nofree nounwind uwtable
define dso_local range(i32 0, 2) i32 @main() local_unnamed_addr #1 {
  br label %1

1:                                                ; preds = %0, %1
  %2 = phi i64 [ 0, %0 ], [ %11, %1 ]
  %3 = phi i64 [ 0, %0 ], [ %8, %1 ]
  %4 = phi i64 [ 0, %0 ], [ %10, %1 ]
  %5 = trunc nuw nsw i64 %2 to i32
  %6 = tail call i32 @ReverseBits32(i32 noundef %5)
  %7 = zext i32 %6 to i64
  %8 = add i64 %3, %7
  %9 = tail call i64 @ReverseBits64(i64 noundef %2)
  %10 = add i64 %9, %4
  %11 = add nuw nsw i64 %2, 1
  %12 = icmp eq i64 %11, 16777216
  br i1 %12, label %13, label %1, !llvm.loop !9

13:                                               ; preds = %1
  %14 = insertelement <2 x i64> <i64 poison, i64 0>, i64 %8, i64 0
  %15 = insertelement <2 x i64> <i64 poison, i64 0>, i64 %10, i64 0
  br label %16

16:                                               ; preds = %16, %13
  %17 = phi i64 [ 0, %13 ], [ %36, %16 ]
  %18 = phi <2 x i64> [ <i64 0, i64 1>, %13 ], [ %37, %16 ]
  %19 = phi <2 x i64> [ %14, %13 ], [ %30, %16 ]
  %20 = phi <2 x i64> [ zeroinitializer, %13 ], [ %31, %16 ]
  %21 = phi <2 x i64> [ %15, %13 ], [ %34, %16 ]
  %22 = phi <2 x i64> [ zeroinitializer, %13 ], [ %35, %16 ]
  %23 = phi <2 x i32> [ <i32 0, i32 1>, %13 ], [ %38, %16 ]
  %24 = add nuw <2 x i64> %18, splat (i64 2)
  %25 = add <2 x i32> %23, splat (i32 2)
  %26 = tail call <2 x i32> @llvm.bitreverse.v2i32(<2 x i32> %23)
  %27 = tail call <2 x i32> @llvm.bitreverse.v2i32(<2 x i32> %25)
  %28 = zext <2 x i32> %26 to <2 x i64>
  %29 = zext <2 x i32> %27 to <2 x i64>
  %30 = sub <2 x i64> %19, %28
  %31 = sub <2 x i64> %20, %29
  %32 = tail call <2 x i64> @llvm.bitreverse.v2i64(<2 x i64> %18)
  %33 = tail call <2 x i64> @llvm.bitreverse.v2i64(<2 x i64> %24)
  %34 = sub <2 x i64> %21, %32
  %35 = sub <2 x i64> %22, %33
  %36 = add nuw i64 %17, 4
  %37 = add nuw <2 x i64> %18, splat (i64 4)
  %38 = add <2 x i32> %23, splat (i32 4)
  %39 = icmp eq i64 %36, 16777216
  br i1 %39, label %40, label %16, !llvm.loop !11

40:                                               ; preds = %16
  %41 = add <2 x i64> %35, %34
  %42 = tail call i64 @llvm.vector.reduce.add.v2i64(<2 x i64> %41)
  %43 = add <2 x i64> %31, %30
  %44 = tail call i64 @llvm.vector.reduce.add.v2i64(<2 x i64> %43)
  %45 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef 305419896, i32 noundef 510274632)
  %46 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef 81985529205302085, i64 noundef -6718103380001897344)
  %47 = icmp ne i64 %44, 0
  %48 = icmp ne i64 %42, 0
  %49 = select i1 %47, i1 true, i1 %48
  %50 = zext i1 %49 to i32
  ret i32 %50
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.bitreverse.i32(i32) #2

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.bitreverse.i64(i64) #2

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x i32> @llvm.bitreverse.v2i32(<2 x i32>) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x i64> @llvm.bitreverse.v2i64(<2 x i64>) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.vector.reduce.add.v2i64(<2 x i64>) #4

attributes #0 = { mustprogress nofree noinline norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
!11 = distinct !{!11, !10, !12, !13}
!12 = !{!"llvm.loop.isvectorized", i32 1}
!13 = !{!"llvm.loop.unroll.runtime.disable"}
