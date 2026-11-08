; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.anon = type { i8, i8 }
%struct.anon.0 = type { i8, i8, i8, i8, i8, i8, i8, i8, i8 }
%struct.anon.1 = type { i32, i32, i32, i32 }

@t1 = dso_local local_unnamed_addr global %struct.anon { i8 97, i8 98 }, align 1
@t2 = dso_local local_unnamed_addr global %struct.anon.0 { i8 97, i8 98, i8 99, i8 100, i8 101, i8 102, i8 103, i8 104, i8 105 }, align 1
@t3 = dso_local local_unnamed_addr global %struct.anon.1 { i32 1, i32 2, i32 3, i32 4 }, align 4

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = load i8, ptr @t1, align 1, !tbaa !9
  %2 = icmp eq i8 %1, 97
  br i1 %2, label %4, label %3

3:                                                ; preds = %0
  tail call void @abort() #2
  unreachable

4:                                                ; preds = %0
  %5 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 1), align 1, !tbaa !11
  %6 = icmp eq i8 %5, 98
  br i1 %6, label %8, label %7

7:                                                ; preds = %4
  tail call void @abort() #2
  unreachable

8:                                                ; preds = %4
  store i8 99, ptr @t1, align 1, !tbaa !9
  store i8 100, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 1), align 1, !tbaa !11
  %9 = load i8, ptr @t2, align 1, !tbaa !12
  %10 = icmp ne i8 %9, 97
  %11 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t2, i64 8), align 1
  %12 = icmp ne i8 %11, 105
  %13 = select i1 %10, i1 true, i1 %12
  br i1 %13, label %14, label %15

14:                                               ; preds = %8
  tail call void @abort() #2
  unreachable

15:                                               ; preds = %8
  %16 = load i32, ptr @t3, align 4, !tbaa !14
  %17 = icmp ne i32 %16, 1
  %18 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t3, i64 12), align 4
  %19 = icmp ne i32 %18, 4
  %20 = select i1 %17, i1 true, i1 %19
  br i1 %20, label %21, label %22

21:                                               ; preds = %15
  tail call void @abort() #2
  unreachable

22:                                               ; preds = %15
  ret i32 0
}

; Function Attrs: cold nofree noreturn nounwind
declare void @abort() local_unnamed_addr #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { cold nofree noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { cold noreturn nounwind }

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
!9 = !{!10, !7, i64 0}
!10 = !{!"", !7, i64 0, !7, i64 1}
!11 = !{!10, !7, i64 1}
!12 = !{!13, !7, i64 0}
!13 = !{!"", !7, i64 0, !7, i64 1, !7, i64 2, !7, i64 3, !7, i64 4, !7, i64 5, !7, i64 6, !7, i64 7, !7, i64 8}
!14 = !{!15, !6, i64 0}
!15 = !{!"", !6, i64 0, !6, i64 4, !6, i64 8, !6, i64 12}
