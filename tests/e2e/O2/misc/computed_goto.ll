; @source: tests/e2e/src/misc/computed_goto.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/computed_goto.c'
source_filename = "tests/e2e/src/misc/computed_goto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.prog = private unnamed_addr constant [10 x i8] c"\00\00\01\01\00\02\01\00\01\03", align 1
@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@run.ops = internal unnamed_addr constant [4 x ptr] [ptr blockaddress(@run, %2), ptr blockaddress(@run, %8), ptr blockaddress(@run, %10), ptr blockaddress(@run, %12)], align 16

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call fastcc i32 @run(ptr noundef @__const.main.prog)
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %1)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read) uwtable
define internal fastcc i32 @run(ptr nofree noundef nonnull readonly captures(none) %0) unnamed_addr #2 {
  br label %13

2:                                                ; preds = %13
  %3 = add nsw i32 %15, 1
  br label %4

4:                                                ; preds = %2, %8, %10
  %5 = phi i32 [ %3, %2 ], [ %9, %8 ], [ %11, %10 ]
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 %14
  %7 = add nuw nsw i64 %14, 1
  br label %13

8:                                                ; preds = %13
  %9 = shl nsw i32 %15, 1
  br label %4

10:                                               ; preds = %13
  %11 = add nsw i32 %15, -3
  br label %4

12:                                               ; preds = %13
  ret i32 %15

13:                                               ; preds = %4, %1
  %14 = phi i64 [ %7, %4 ], [ 1, %1 ]
  %15 = phi i32 [ %5, %4 ], [ 0, %1 ]
  %16 = phi ptr [ %6, %4 ], [ %0, %1 ]
  %17 = load i8, ptr %16, align 1, !tbaa !9
  %18 = zext i8 %17 to i64
  %19 = getelementptr inbounds nuw [8 x i8], ptr @run.ops, i64 %18
  %20 = load ptr, ptr %19, align 8, !tbaa !10
  indirectbr ptr %20, [label %2, label %8, label %10, label %12]
}

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree norecurse nosync nounwind memory(argmem: read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
