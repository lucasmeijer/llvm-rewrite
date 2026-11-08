; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/2004-03-15-IndirectGoto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.L = internal unnamed_addr constant [5 x ptr] [ptr blockaddress(@main, %2), ptr blockaddress(@main, %5), ptr blockaddress(@main, %8), ptr blockaddress(@main, %15), ptr null], align 16
@str = private unnamed_addr constant [2 x i8] c"A\00", align 1
@str.5 = private unnamed_addr constant [2 x i8] c"B\00", align 1
@str.6 = private unnamed_addr constant [2 x i8] c"C\00", align 1
@str.7 = private unnamed_addr constant [2 x i8] c"D\00", align 1
@str.8 = private unnamed_addr constant [2 x i8] c"E\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str)
  br label %2

2:                                                ; preds = %0, %8
  %3 = phi i32 [ 0, %0 ], [ %11, %8 ]
  %4 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.5)
  br label %5

5:                                                ; preds = %2, %8
  %6 = phi i32 [ %3, %2 ], [ %11, %8 ]
  %7 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.6)
  br label %8

8:                                                ; preds = %5, %8
  %9 = phi i32 [ %6, %5 ], [ %11, %8 ]
  %10 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.7)
  %11 = add i32 %9, 1
  %12 = zext i32 %9 to i64
  %13 = getelementptr inbounds nuw [8 x i8], ptr @main.L, i64 %12
  %14 = load ptr, ptr %13, align 8, !tbaa !9
  indirectbr ptr %14, [label %2, label %5, label %8, label %15]

15:                                               ; preds = %8
  %16 = tail call i32 @puts(ptr nonnull dereferenceable(1) @str.8)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @puts(ptr noundef readonly captures(none)) local_unnamed_addr #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind }

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
!10 = !{!"any pointer", !7, i64 0}
