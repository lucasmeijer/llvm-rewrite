; @source: tests/e2e/src/misc/thread_local_atomics.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/thread_local_atomics.c'
source_filename = "tests/e2e/src/misc/thread_local_atomics.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@tls_counter = internal thread_local unnamed_addr global i32 7, align 4
@shared = internal global i32 0, align 4
@big = internal global i64 1, align 8
@.str = private unnamed_addr constant [14 x i8] c"%d %d %d %ld\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call align 4 ptr @llvm.threadlocal.address.p0(ptr align 4 @tls_counter)
  %2 = atomicrmw or ptr @shared, i32 0 seq_cst, align 4
  %3 = load atomic i64, ptr @big seq_cst, align 8
  br label %4

4:                                                ; preds = %4, %0
  %5 = phi i64 [ %3, %0 ], [ %9, %4 ]
  %6 = mul nsw i64 %5, 3
  %7 = cmpxchg weak ptr @big, i64 %5, i64 %6 seq_cst seq_cst, align 8
  %8 = extractvalue { i64, i1 } %7, 1
  %9 = extractvalue { i64, i1 } %7, 0
  br i1 %8, label %10, label %4, !llvm.loop !9

10:                                               ; preds = %4
  %11 = load i32, ptr %1, align 4, !tbaa !11
  %12 = add nsw i32 %11, 1
  store i32 %12, ptr %1, align 4, !tbaa !11
  %13 = atomicrmw add ptr @shared, i32 2 seq_cst, align 4
  %14 = load atomic i64, ptr @big seq_cst, align 8
  br label %15

15:                                               ; preds = %15, %10
  %16 = phi i64 [ %14, %10 ], [ %20, %15 ]
  %17 = mul nsw i64 %16, 3
  %18 = cmpxchg weak ptr @big, i64 %16, i64 %17 seq_cst seq_cst, align 8
  %19 = extractvalue { i64, i1 } %18, 1
  %20 = extractvalue { i64, i1 } %18, 0
  br i1 %19, label %21, label %15, !llvm.loop !9

21:                                               ; preds = %15
  %22 = load i32, ptr %1, align 4, !tbaa !11
  %23 = add nsw i32 %22, 2
  store i32 %23, ptr %1, align 4, !tbaa !11
  %24 = atomicrmw add ptr @shared, i32 4 seq_cst, align 4
  %25 = load atomic i64, ptr @big seq_cst, align 8
  br label %26

26:                                               ; preds = %26, %21
  %27 = phi i64 [ %25, %21 ], [ %31, %26 ]
  %28 = mul nsw i64 %27, 3
  %29 = cmpxchg weak ptr @big, i64 %27, i64 %28 seq_cst seq_cst, align 8
  %30 = extractvalue { i64, i1 } %29, 1
  %31 = extractvalue { i64, i1 } %29, 0
  br i1 %30, label %32, label %26, !llvm.loop !9

32:                                               ; preds = %26
  %33 = load i32, ptr %1, align 4, !tbaa !11
  %34 = add nsw i32 %33, 3
  store i32 %34, ptr %1, align 4, !tbaa !11
  %35 = atomicrmw add ptr @shared, i32 6 seq_cst, align 4
  %36 = load atomic i64, ptr @big seq_cst, align 8
  br label %37

37:                                               ; preds = %37, %32
  %38 = phi i64 [ %36, %32 ], [ %42, %37 ]
  %39 = mul nsw i64 %38, 3
  %40 = cmpxchg weak ptr @big, i64 %38, i64 %39 seq_cst seq_cst, align 8
  %41 = extractvalue { i64, i1 } %40, 1
  %42 = extractvalue { i64, i1 } %40, 0
  br i1 %41, label %43, label %37, !llvm.loop !9

43:                                               ; preds = %37
  %44 = load i32, ptr %1, align 4, !tbaa !11
  %45 = add nsw i32 %44, 4
  store i32 %45, ptr %1, align 4, !tbaa !11
  %46 = atomicrmw add ptr @shared, i32 8 seq_cst, align 4
  %47 = load atomic i64, ptr @big seq_cst, align 8
  br label %48

48:                                               ; preds = %48, %43
  %49 = phi i64 [ %47, %43 ], [ %53, %48 ]
  %50 = mul nsw i64 %49, 3
  %51 = cmpxchg weak ptr @big, i64 %49, i64 %50 seq_cst seq_cst, align 8
  %52 = extractvalue { i64, i1 } %51, 1
  %53 = extractvalue { i64, i1 } %51, 0
  br i1 %52, label %54, label %48, !llvm.loop !9

54:                                               ; preds = %48
  %55 = load i32, ptr %1, align 4, !tbaa !11
  %56 = add nsw i32 %55, 5
  store i32 %56, ptr %1, align 4, !tbaa !11
  %57 = atomicrmw add ptr @shared, i32 10 seq_cst, align 4
  %58 = load atomic i64, ptr @big seq_cst, align 8
  br label %59

59:                                               ; preds = %59, %54
  %60 = phi i64 [ %58, %54 ], [ %64, %59 ]
  %61 = mul nsw i64 %60, 3
  %62 = cmpxchg weak ptr @big, i64 %60, i64 %61 seq_cst seq_cst, align 8
  %63 = extractvalue { i64, i1 } %62, 1
  %64 = extractvalue { i64, i1 } %62, 0
  br i1 %63, label %65, label %59, !llvm.loop !9

65:                                               ; preds = %59
  %66 = load i32, ptr %1, align 4, !tbaa !11
  %67 = add nsw i32 %66, 6
  store i32 %67, ptr %1, align 4, !tbaa !11
  %68 = atomicrmw add ptr @shared, i32 12 seq_cst, align 4
  %69 = load atomic i64, ptr @big seq_cst, align 8
  br label %70

70:                                               ; preds = %70, %65
  %71 = phi i64 [ %69, %65 ], [ %75, %70 ]
  %72 = mul nsw i64 %71, 3
  %73 = cmpxchg weak ptr @big, i64 %71, i64 %72 seq_cst seq_cst, align 8
  %74 = extractvalue { i64, i1 } %73, 1
  %75 = extractvalue { i64, i1 } %73, 0
  br i1 %74, label %76, label %70, !llvm.loop !9

76:                                               ; preds = %70
  %77 = load i32, ptr %1, align 4, !tbaa !11
  %78 = add nsw i32 %77, 7
  store i32 %78, ptr %1, align 4, !tbaa !11
  %79 = atomicrmw add ptr @shared, i32 14 seq_cst, align 4
  %80 = load atomic i64, ptr @big seq_cst, align 8
  br label %81

81:                                               ; preds = %81, %76
  %82 = phi i64 [ %80, %76 ], [ %86, %81 ]
  %83 = mul nsw i64 %82, 3
  %84 = cmpxchg weak ptr @big, i64 %82, i64 %83 seq_cst seq_cst, align 8
  %85 = extractvalue { i64, i1 } %84, 1
  %86 = extractvalue { i64, i1 } %84, 0
  br i1 %85, label %87, label %81, !llvm.loop !9

87:                                               ; preds = %81
  %88 = load i32, ptr %1, align 4, !tbaa !11
  %89 = add nsw i32 %88, 8
  store i32 %89, ptr %1, align 4, !tbaa !11
  %90 = atomicrmw add ptr @shared, i32 16 seq_cst, align 4
  %91 = load atomic i64, ptr @big seq_cst, align 8
  br label %92

92:                                               ; preds = %92, %87
  %93 = phi i64 [ %91, %87 ], [ %97, %92 ]
  %94 = mul nsw i64 %93, 3
  %95 = cmpxchg weak ptr @big, i64 %93, i64 %94 seq_cst seq_cst, align 8
  %96 = extractvalue { i64, i1 } %95, 1
  %97 = extractvalue { i64, i1 } %95, 0
  br i1 %96, label %98, label %92, !llvm.loop !9

98:                                               ; preds = %92
  %99 = load i32, ptr %1, align 4, !tbaa !11
  %100 = add nsw i32 %99, 9
  store i32 %100, ptr %1, align 4, !tbaa !11
  %101 = atomicrmw add ptr @shared, i32 18 seq_cst, align 4
  %102 = load atomic i64, ptr @big seq_cst, align 8
  br label %103

103:                                              ; preds = %103, %98
  %104 = phi i64 [ %102, %98 ], [ %108, %103 ]
  %105 = mul nsw i64 %104, 3
  %106 = cmpxchg weak ptr @big, i64 %104, i64 %105 seq_cst seq_cst, align 8
  %107 = extractvalue { i64, i1 } %106, 1
  %108 = extractvalue { i64, i1 } %106, 0
  br i1 %107, label %109, label %103, !llvm.loop !9

109:                                              ; preds = %103
  %110 = atomicrmw xchg ptr @shared, i32 -1 seq_cst, align 4
  %111 = load i32, ptr %1, align 4, !tbaa !11
  %112 = load atomic i32, ptr @shared seq_cst, align 4
  %113 = load atomic i64, ptr @big seq_cst, align 8
  %114 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %111, i32 noundef %110, i32 noundef %112, i64 noundef %113)
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare nonnull ptr @llvm.threadlocal.address.p0(ptr nonnull) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.mustprogress"}
!11 = !{!6, !6, i64 0}
