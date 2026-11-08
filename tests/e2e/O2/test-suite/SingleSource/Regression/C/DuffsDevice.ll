; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/DuffsDevice.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/DuffsDevice.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/DuffsDevice.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"Sum is %d\0A\00", align 1

; Function Attrs: nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local i32 @sum(ptr nofree noundef captures(none) %0, ptr nofree noundef readonly captures(none) %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = add nsw i32 %2, 7
  %5 = sdiv i32 %4, 8
  %6 = srem i32 %2, 8
  switch i32 %6, label %81 [
    i32 0, label %21
    i32 7, label %19
    i32 6, label %17
    i32 5, label %15
    i32 4, label %13
    i32 3, label %11
    i32 2, label %9
    i32 1, label %7
  ]

7:                                                ; preds = %3
  %8 = load i16, ptr %0, align 2, !tbaa !9
  br label %72

9:                                                ; preds = %3
  %10 = load i16, ptr %0, align 2, !tbaa !9
  br label %65

11:                                               ; preds = %3
  %12 = load i16, ptr %0, align 2, !tbaa !9
  br label %58

13:                                               ; preds = %3
  %14 = load i16, ptr %0, align 2, !tbaa !9
  br label %51

15:                                               ; preds = %3
  %16 = load i16, ptr %0, align 2, !tbaa !9
  br label %44

17:                                               ; preds = %3
  %18 = load i16, ptr %0, align 2, !tbaa !9
  br label %37

19:                                               ; preds = %3
  %20 = load i16, ptr %0, align 2, !tbaa !9
  br label %30

21:                                               ; preds = %3
  %22 = load i16, ptr %0, align 2, !tbaa !9
  br label %23

23:                                               ; preds = %21, %72
  %24 = phi i16 [ %22, %21 ], [ %78, %72 ]
  %25 = phi ptr [ %1, %21 ], [ %76, %72 ]
  %26 = phi i32 [ %5, %21 ], [ %79, %72 ]
  %27 = getelementptr inbounds nuw i8, ptr %25, i64 2
  %28 = load i16, ptr %25, align 2, !tbaa !9
  %29 = add i16 %24, %28
  store i16 %29, ptr %0, align 2, !tbaa !9
  br label %30

30:                                               ; preds = %19, %23
  %31 = phi i16 [ %29, %23 ], [ %20, %19 ]
  %32 = phi ptr [ %27, %23 ], [ %1, %19 ]
  %33 = phi i32 [ %26, %23 ], [ %5, %19 ]
  %34 = getelementptr inbounds nuw i8, ptr %32, i64 2
  %35 = load i16, ptr %32, align 2, !tbaa !9
  %36 = add i16 %31, %35
  store i16 %36, ptr %0, align 2, !tbaa !9
  br label %37

37:                                               ; preds = %17, %30
  %38 = phi i16 [ %36, %30 ], [ %18, %17 ]
  %39 = phi ptr [ %34, %30 ], [ %1, %17 ]
  %40 = phi i32 [ %33, %30 ], [ %5, %17 ]
  %41 = getelementptr inbounds nuw i8, ptr %39, i64 2
  %42 = load i16, ptr %39, align 2, !tbaa !9
  %43 = add i16 %38, %42
  store i16 %43, ptr %0, align 2, !tbaa !9
  br label %44

44:                                               ; preds = %15, %37
  %45 = phi i16 [ %43, %37 ], [ %16, %15 ]
  %46 = phi ptr [ %41, %37 ], [ %1, %15 ]
  %47 = phi i32 [ %40, %37 ], [ %5, %15 ]
  %48 = getelementptr inbounds nuw i8, ptr %46, i64 2
  %49 = load i16, ptr %46, align 2, !tbaa !9
  %50 = add i16 %45, %49
  store i16 %50, ptr %0, align 2, !tbaa !9
  br label %51

51:                                               ; preds = %13, %44
  %52 = phi i16 [ %50, %44 ], [ %14, %13 ]
  %53 = phi ptr [ %48, %44 ], [ %1, %13 ]
  %54 = phi i32 [ %47, %44 ], [ %5, %13 ]
  %55 = getelementptr inbounds nuw i8, ptr %53, i64 2
  %56 = load i16, ptr %53, align 2, !tbaa !9
  %57 = add i16 %52, %56
  store i16 %57, ptr %0, align 2, !tbaa !9
  br label %58

58:                                               ; preds = %11, %51
  %59 = phi i16 [ %57, %51 ], [ %12, %11 ]
  %60 = phi ptr [ %55, %51 ], [ %1, %11 ]
  %61 = phi i32 [ %54, %51 ], [ %5, %11 ]
  %62 = getelementptr inbounds nuw i8, ptr %60, i64 2
  %63 = load i16, ptr %60, align 2, !tbaa !9
  %64 = add i16 %59, %63
  store i16 %64, ptr %0, align 2, !tbaa !9
  br label %65

65:                                               ; preds = %9, %58
  %66 = phi i16 [ %64, %58 ], [ %10, %9 ]
  %67 = phi ptr [ %62, %58 ], [ %1, %9 ]
  %68 = phi i32 [ %61, %58 ], [ %5, %9 ]
  %69 = getelementptr inbounds nuw i8, ptr %67, i64 2
  %70 = load i16, ptr %67, align 2, !tbaa !9
  %71 = add i16 %66, %70
  store i16 %71, ptr %0, align 2, !tbaa !9
  br label %72

72:                                               ; preds = %7, %65
  %73 = phi i16 [ %71, %65 ], [ %8, %7 ]
  %74 = phi ptr [ %69, %65 ], [ %1, %7 ]
  %75 = phi i32 [ %68, %65 ], [ %5, %7 ]
  %76 = getelementptr inbounds nuw i8, ptr %74, i64 2
  %77 = load i16, ptr %74, align 2, !tbaa !9
  %78 = add i16 %73, %77
  store i16 %78, ptr %0, align 2, !tbaa !9
  %79 = add nsw i32 %75, -1
  %80 = icmp sgt i32 %75, 1
  br i1 %80, label %23, label %81, !llvm.loop !11

81:                                               ; preds = %72, %3
  ret i32 undef
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  %1 = alloca [100 x i16], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1)
  store <8 x i16> <i16 0, i16 1, i16 2, i16 3, i16 4, i16 5, i16 6, i16 7>, ptr %1, align 16, !tbaa !9
  %2 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store <8 x i16> <i16 8, i16 9, i16 10, i16 11, i16 12, i16 13, i16 14, i16 15>, ptr %2, align 16, !tbaa !9
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 32
  store <8 x i16> <i16 16, i16 17, i16 18, i16 19, i16 20, i16 21, i16 22, i16 23>, ptr %3, align 16, !tbaa !9
  %4 = getelementptr inbounds nuw i8, ptr %1, i64 48
  store <8 x i16> <i16 24, i16 25, i16 26, i16 27, i16 28, i16 29, i16 30, i16 31>, ptr %4, align 16, !tbaa !9
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 64
  store <8 x i16> <i16 32, i16 33, i16 34, i16 35, i16 36, i16 37, i16 38, i16 39>, ptr %5, align 16, !tbaa !9
  %6 = getelementptr inbounds nuw i8, ptr %1, i64 80
  store <8 x i16> <i16 40, i16 41, i16 42, i16 43, i16 44, i16 45, i16 46, i16 47>, ptr %6, align 16, !tbaa !9
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 96
  store <8 x i16> <i16 48, i16 49, i16 50, i16 51, i16 52, i16 53, i16 54, i16 55>, ptr %7, align 16, !tbaa !9
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 112
  store <8 x i16> <i16 56, i16 57, i16 58, i16 59, i16 60, i16 61, i16 62, i16 63>, ptr %8, align 16, !tbaa !9
  %9 = getelementptr inbounds nuw i8, ptr %1, i64 128
  store <8 x i16> <i16 64, i16 65, i16 66, i16 67, i16 68, i16 69, i16 70, i16 71>, ptr %9, align 16, !tbaa !9
  %10 = getelementptr inbounds nuw i8, ptr %1, i64 144
  store <8 x i16> <i16 72, i16 73, i16 74, i16 75, i16 76, i16 77, i16 78, i16 79>, ptr %10, align 16, !tbaa !9
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 160
  store <8 x i16> <i16 80, i16 81, i16 82, i16 83, i16 84, i16 85, i16 86, i16 87>, ptr %11, align 16, !tbaa !9
  %12 = getelementptr inbounds nuw i8, ptr %1, i64 176
  store <8 x i16> <i16 88, i16 89, i16 90, i16 91, i16 92, i16 93, i16 94, i16 95>, ptr %12, align 16, !tbaa !9
  %13 = getelementptr inbounds nuw i8, ptr %1, i64 192
  store <4 x i16> <i16 96, i16 97, i16 98, i16 99>, ptr %13, align 16, !tbaa !9
  %14 = load i16, ptr %1, align 16, !tbaa !9
  %15 = getelementptr inbounds nuw i8, ptr %1, i64 2
  %16 = load i16, ptr %15, align 2, !tbaa !9
  %17 = add i16 %14, %16
  %18 = getelementptr inbounds nuw i8, ptr %1, i64 4
  %19 = load i16, ptr %18, align 4, !tbaa !9
  %20 = add i16 %17, %19
  %21 = getelementptr inbounds nuw i8, ptr %1, i64 6
  %22 = load i16, ptr %21, align 2, !tbaa !9
  %23 = add i16 %20, %22
  %24 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %25 = load <8 x i16>, ptr %24, align 8, !tbaa !9
  %26 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %25)
  %27 = add i16 %26, %23
  %28 = getelementptr inbounds nuw i8, ptr %1, i64 24
  %29 = load <8 x i16>, ptr %28, align 8, !tbaa !9
  %30 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %29)
  %31 = add i16 %30, %27
  %32 = getelementptr inbounds nuw i8, ptr %1, i64 40
  %33 = load <8 x i16>, ptr %32, align 8, !tbaa !9
  %34 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %33)
  %35 = add i16 %34, %31
  %36 = getelementptr inbounds nuw i8, ptr %1, i64 56
  %37 = load <8 x i16>, ptr %36, align 8, !tbaa !9
  %38 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %37)
  %39 = add i16 %38, %35
  %40 = getelementptr inbounds nuw i8, ptr %1, i64 72
  %41 = load <8 x i16>, ptr %40, align 8, !tbaa !9
  %42 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %41)
  %43 = add i16 %42, %39
  %44 = getelementptr inbounds nuw i8, ptr %1, i64 88
  %45 = load <8 x i16>, ptr %44, align 8, !tbaa !9
  %46 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %45)
  %47 = add i16 %46, %43
  %48 = getelementptr inbounds nuw i8, ptr %1, i64 104
  %49 = load <8 x i16>, ptr %48, align 8, !tbaa !9
  %50 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %49)
  %51 = add i16 %50, %47
  %52 = getelementptr inbounds nuw i8, ptr %1, i64 120
  %53 = load <8 x i16>, ptr %52, align 8, !tbaa !9
  %54 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %53)
  %55 = add i16 %54, %51
  %56 = getelementptr inbounds nuw i8, ptr %1, i64 136
  %57 = load <8 x i16>, ptr %56, align 8, !tbaa !9
  %58 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %57)
  %59 = add i16 %58, %55
  %60 = getelementptr inbounds nuw i8, ptr %1, i64 152
  %61 = load <8 x i16>, ptr %60, align 8, !tbaa !9
  %62 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %61)
  %63 = add i16 %62, %59
  %64 = getelementptr inbounds nuw i8, ptr %1, i64 168
  %65 = load <8 x i16>, ptr %64, align 8, !tbaa !9
  %66 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %65)
  %67 = add i16 %66, %63
  %68 = getelementptr inbounds nuw i8, ptr %1, i64 184
  %69 = load <8 x i16>, ptr %68, align 8, !tbaa !9
  %70 = tail call i16 @llvm.vector.reduce.add.v8i16(<8 x i16> %69)
  %71 = add i16 %70, %67
  %72 = sext i16 %71 to i32
  %73 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %72)
  call void @llvm.lifetime.end.p0(ptr nonnull %1)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i16 @llvm.vector.reduce.add.v8i16(<8 x i16>) #4

attributes #0 = { nofree norecurse nosync nounwind memory(read, argmem: readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"short", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
