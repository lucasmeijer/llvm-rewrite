; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/uint64_to_float.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [28 x i8] c"Error detected @ 0x%016llx\0A\00", align 1
@.str.1 = private unnamed_addr constant [31 x i8] c"\09Expected result: %a (0x%08x)\0A\00", align 1
@.str.2 = private unnamed_addr constant [31 x i8] c"\09Observed result: %a (0x%08x)\0A\00", align 1
@.str.3 = private unnamed_addr constant [11 x i8] c"to nearest\00", align 1
@.str.4 = private unnamed_addr constant [5 x i8] c"down\00", align 1
@.str.5 = private unnamed_addr constant [3 x i8] c"up\00", align 1
@.str.6 = private unnamed_addr constant [13 x i8] c"towards zero\00", align 1
@__const.main.modeNames.rel = private unnamed_addr constant [4 x i32] [i32 trunc (i64 sub (i64 ptrtoint (ptr @.str.3 to i64), i64 ptrtoint (ptr @__const.main.modeNames.rel to i64)) to i32), i32 trunc (i64 sub (i64 ptrtoint (ptr @.str.4 to i64), i64 ptrtoint (ptr @__const.main.modeNames.rel to i64)) to i32), i32 trunc (i64 sub (i64 ptrtoint (ptr @.str.5 to i64), i64 ptrtoint (ptr @__const.main.modeNames.rel to i64)) to i32), i32 trunc (i64 sub (i64 ptrtoint (ptr @.str.6 to i64), i64 ptrtoint (ptr @__const.main.modeNames.rel to i64)) to i32)], align 4
@.str.7 = private unnamed_addr constant [55 x i8] c"Testing uint64_t --> float conversions in round %s...\0A\00", align 1
@str = private unnamed_addr constant [18 x i8] c"Finished Testing.\00", align 1

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable
define dso_local float @floatundisf(i64 noundef %0) local_unnamed_addr #0 {
  %2 = icmp eq i64 %0, 0
  br i1 %2, label %45, label %3

3:                                                ; preds = %1
  %4 = tail call range(i64 0, 65) i64 @llvm.ctlz.i64(i64 %0, i1 true)
  %5 = trunc nuw nsw i64 %4 to i32
  %6 = sub nuw nsw i32 64, %5
  %7 = xor i32 %5, 63
  %8 = icmp ugt i64 %0, 16777215
  br i1 %8, label %9, label %32

9:                                                ; preds = %3
  switch i32 %6, label %12 [
    i32 25, label %10
    i32 26, label %21
  ]

10:                                               ; preds = %9
  %11 = shl i64 %0, 1
  br label %21

12:                                               ; preds = %9
  %13 = sub nsw i64 38, %4
  %14 = and i64 %13, 4294967295
  %15 = lshr i64 %0, %14
  %16 = lshr i64 274877906943, %4
  %17 = and i64 %16, %0
  %18 = icmp ne i64 %17, 0
  %19 = zext i1 %18 to i64
  %20 = or i64 %15, %19
  br label %21

21:                                               ; preds = %12, %9, %10
  %22 = phi i64 [ %20, %12 ], [ %11, %10 ], [ %0, %9 ]
  %23 = lshr i64 %22, 2
  %24 = and i64 %23, 1
  %25 = or i64 %24, %22
  %26 = add i64 %25, 1
  %27 = and i64 %26, 67108864
  %28 = icmp eq i64 %27, 0
  %29 = select i1 %28, i64 2, i64 3
  %30 = lshr i64 %26, %29
  %31 = select i1 %28, i32 %7, i32 %6
  br label %36

32:                                               ; preds = %3
  %33 = add nuw nsw i64 %4, 4294967256
  %34 = and i64 %33, 4294967295
  %35 = shl i64 %0, %34
  br label %36

36:                                               ; preds = %21, %32
  %37 = phi i64 [ %35, %32 ], [ %30, %21 ]
  %38 = phi i32 [ %7, %32 ], [ %31, %21 ]
  %39 = shl nuw nsw i32 %38, 23
  %40 = add nuw nsw i32 %39, 1065353216
  %41 = trunc i64 %37 to i32
  %42 = and i32 %41, 8388607
  %43 = or disjoint i32 %40, %42
  %44 = bitcast i32 %43 to float
  br label %45

45:                                               ; preds = %1, %36
  %46 = phi float [ %44, %36 ], [ 0.000000e+00, %1 ]
  ret float %46
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #1

; Function Attrs: nofree nounwind uwtable
define dso_local void @test(i64 noundef %0) local_unnamed_addr #2 {
  %2 = icmp eq i64 %0, 0
  br i1 %2, label %45, label %3

3:                                                ; preds = %1
  %4 = tail call range(i64 0, 65) i64 @llvm.ctlz.i64(i64 %0, i1 true)
  %5 = trunc nuw nsw i64 %4 to i32
  %6 = sub nuw nsw i32 64, %5
  %7 = xor i32 %5, 63
  %8 = icmp ugt i64 %0, 16777215
  br i1 %8, label %9, label %32

9:                                                ; preds = %3
  switch i32 %6, label %12 [
    i32 25, label %10
    i32 26, label %21
  ]

10:                                               ; preds = %9
  %11 = shl i64 %0, 1
  br label %21

12:                                               ; preds = %9
  %13 = sub nsw i64 38, %4
  %14 = and i64 %13, 4294967295
  %15 = lshr i64 %0, %14
  %16 = lshr i64 274877906943, %4
  %17 = and i64 %16, %0
  %18 = icmp ne i64 %17, 0
  %19 = zext i1 %18 to i64
  %20 = or i64 %15, %19
  br label %21

21:                                               ; preds = %12, %10, %9
  %22 = phi i64 [ %20, %12 ], [ %11, %10 ], [ %0, %9 ]
  %23 = lshr i64 %22, 2
  %24 = and i64 %23, 1
  %25 = or i64 %24, %22
  %26 = add i64 %25, 1
  %27 = and i64 %26, 67108864
  %28 = icmp eq i64 %27, 0
  %29 = select i1 %28, i64 2, i64 3
  %30 = lshr i64 %26, %29
  %31 = select i1 %28, i32 %7, i32 %6
  br label %36

32:                                               ; preds = %3
  %33 = add nuw nsw i64 %4, 4294967256
  %34 = and i64 %33, 4294967295
  %35 = shl i64 %0, %34
  br label %36

36:                                               ; preds = %32, %21
  %37 = phi i64 [ %35, %32 ], [ %30, %21 ]
  %38 = phi i32 [ %7, %32 ], [ %31, %21 ]
  %39 = shl nuw nsw i32 %38, 23
  %40 = add nuw nsw i32 %39, 1065353216
  %41 = trunc i64 %37 to i32
  %42 = and i32 %41, 8388607
  %43 = or disjoint i32 %40, %42
  %44 = bitcast i32 %43 to float
  br label %45

45:                                               ; preds = %1, %36
  %46 = phi float [ %44, %36 ], [ 0.000000e+00, %1 ]
  %47 = bitcast float %46 to i32
  %48 = uitofp i64 %0 to float
  %49 = bitcast float %48 to i32
  %50 = icmp eq i32 %47, %49
  br i1 %50, label %57, label %51

51:                                               ; preds = %45
  %52 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef %0)
  %53 = fpext float %46 to double
  %54 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %53, i32 noundef %47)
  %55 = fpext float %48 to double
  %56 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, double noundef %55, i32 noundef %49)
  br label %57

57:                                               ; preds = %51, %45
  ret void
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readnone captures(none) %1) local_unnamed_addr #4 {
  br label %3

3:                                                ; preds = %2, %67
  %4 = phi i64 [ 0, %2 ], [ %68, %67 ]
  %5 = tail call i32 @fesetround(i32 noundef 0) #8
  %6 = shl i64 %4, 2
  %7 = call ptr @llvm.load.relative.i64(ptr @__const.main.modeNames.rel, i64 %6)
  %8 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.7, ptr noundef %7)
  br label %9

9:                                                ; preds = %3, %64
  %10 = phi i64 [ 0, %3 ], [ %65, %64 ]
  %11 = shl nuw i64 1, %10
  tail call void @test(i64 noundef %11)
  %12 = shl nsw i64 -1, %10
  tail call void @test(i64 noundef %12)
  %13 = icmp eq i64 %10, 0
  br i1 %13, label %64, label %14

14:                                               ; preds = %9, %61
  %15 = phi i64 [ %62, %61 ], [ 0, %9 ]
  %16 = shl nuw i64 1, %15
  %17 = add i64 %16, %11
  tail call void @test(i64 noundef %17)
  %18 = shl nsw i64 -1, %15
  %19 = add i64 %18, %11
  tail call void @test(i64 noundef %19)
  %20 = add i64 %16, %12
  tail call void @test(i64 noundef %20)
  %21 = add i64 %18, %12
  tail call void @test(i64 noundef %21)
  %22 = icmp eq i64 %15, 0
  br i1 %22, label %61, label %23

23:                                               ; preds = %14, %58
  %24 = phi i64 [ %59, %58 ], [ 0, %14 ]
  %25 = shl nuw i64 1, %24
  %26 = add i64 %25, %17
  tail call void @test(i64 noundef %26)
  %27 = shl nsw i64 -1, %24
  %28 = add i64 %27, %17
  tail call void @test(i64 noundef %28)
  %29 = add i64 %25, %19
  tail call void @test(i64 noundef %29)
  %30 = add i64 %27, %19
  tail call void @test(i64 noundef %30)
  %31 = add i64 %25, %20
  tail call void @test(i64 noundef %31)
  %32 = add i64 %27, %20
  tail call void @test(i64 noundef %32)
  %33 = add i64 %25, %21
  tail call void @test(i64 noundef %33)
  %34 = add i64 %27, %21
  tail call void @test(i64 noundef %34)
  %35 = icmp eq i64 %24, 0
  br i1 %35, label %58, label %36

36:                                               ; preds = %23, %36
  %37 = phi i64 [ %56, %36 ], [ 0, %23 ]
  %38 = shl nuw i64 1, %37
  %39 = add i64 %38, %26
  tail call void @test(i64 noundef %39)
  %40 = shl nsw i64 -1, %37
  %41 = add i64 %40, %26
  tail call void @test(i64 noundef %41)
  %42 = add i64 %38, %28
  tail call void @test(i64 noundef %42)
  %43 = add i64 %40, %28
  tail call void @test(i64 noundef %43)
  %44 = add i64 %38, %29
  tail call void @test(i64 noundef %44)
  %45 = add i64 %40, %29
  tail call void @test(i64 noundef %45)
  %46 = add i64 %38, %30
  tail call void @test(i64 noundef %46)
  %47 = add i64 %40, %30
  tail call void @test(i64 noundef %47)
  %48 = add i64 %38, %31
  tail call void @test(i64 noundef %48)
  %49 = add i64 %40, %31
  tail call void @test(i64 noundef %49)
  %50 = add i64 %38, %32
  tail call void @test(i64 noundef %50)
  %51 = add i64 %40, %32
  tail call void @test(i64 noundef %51)
  %52 = add i64 %38, %33
  tail call void @test(i64 noundef %52)
  %53 = add i64 %40, %33
  tail call void @test(i64 noundef %53)
  %54 = add i64 %38, %34
  tail call void @test(i64 noundef %54)
  %55 = add i64 %40, %34
  tail call void @test(i64 noundef %55)
  %56 = add nuw nsw i64 %37, 1
  %57 = icmp eq i64 %56, %24
  br i1 %57, label %58, label %36, !llvm.loop !9

58:                                               ; preds = %36, %23
  %59 = add nuw nsw i64 %24, 1
  %60 = icmp eq i64 %59, %15
  br i1 %60, label %61, label %23, !llvm.loop !11

61:                                               ; preds = %58, %14
  %62 = add nuw nsw i64 %15, 1
  %63 = icmp eq i64 %62, %10
  br i1 %63, label %64, label %14, !llvm.loop !12

64:                                               ; preds = %61, %9
  %65 = add nuw nsw i64 %10, 1
  %66 = icmp eq i64 %65, 64
  br i1 %66, label %67, label %9, !llvm.loop !13

67:                                               ; preds = %64
  %68 = add nuw nsw i64 %4, 1
  %69 = icmp eq i64 %68, 4
  br i1 %69, label %70, label %3, !llvm.loop !14

70:                                               ; preds = %67
  %71 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  ret i32 0
}

; Function Attrs: nounwind
declare i32 @fesetround(i32 noundef) local_unnamed_addr #5

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #6

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare ptr @llvm.load.relative.i64(ptr, i64) #7

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind }
attributes #7 = { nocallback nofree nosync nounwind willreturn memory(argmem: read) }
attributes #8 = { nounwind }

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
!11 = distinct !{!11, !10}
!12 = distinct !{!12, !10}
!13 = distinct !{!13, !10}
!14 = distinct !{!14, !10}
