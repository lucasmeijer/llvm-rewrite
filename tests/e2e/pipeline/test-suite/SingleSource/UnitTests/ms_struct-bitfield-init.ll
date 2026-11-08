; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.anon = type { i8, i8 }
%struct.anon.0 = type { i8, i8, i8, i8, i8, i8, i8, i8, i8 }
%struct.anon.1 = type { i32, i32, i32, i32 }

@t1 = dso_local global %struct.anon { i8 97, i8 98 }, align 1
@t2 = dso_local global %struct.anon.0 { i8 97, i8 98, i8 99, i8 100, i8 101, i8 102, i8 103, i8 104, i8 105 }, align 1
@t3 = dso_local global %struct.anon.1 { i32 1, i32 2, i32 3, i32 4 }, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = load i8, ptr @t1, align 1, !tbaa !9
  %3 = sext i8 %2 to i32
  %4 = icmp ne i32 %3, 97
  br i1 %4, label %5, label %6

5:                                                ; preds = %0
  call void @abort() #2
  unreachable

6:                                                ; preds = %0
  %7 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 1), align 1, !tbaa !11
  %8 = sext i8 %7 to i32
  %9 = icmp ne i32 %8, 98
  br i1 %9, label %10, label %11

10:                                               ; preds = %6
  call void @abort() #2
  unreachable

11:                                               ; preds = %6
  store i8 99, ptr @t1, align 1, !tbaa !9
  store i8 100, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 1), align 1, !tbaa !11
  %12 = load i8, ptr @t1, align 1, !tbaa !9
  %13 = sext i8 %12 to i32
  %14 = icmp ne i32 %13, 99
  br i1 %14, label %15, label %16

15:                                               ; preds = %11
  call void @abort() #2
  unreachable

16:                                               ; preds = %11
  %17 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 1), align 1, !tbaa !11
  %18 = sext i8 %17 to i32
  %19 = icmp ne i32 %18, 100
  br i1 %19, label %20, label %21

20:                                               ; preds = %16
  call void @abort() #2
  unreachable

21:                                               ; preds = %16
  %22 = load i8, ptr @t2, align 1, !tbaa !12
  %23 = sext i8 %22 to i32
  %24 = icmp ne i32 %23, 97
  br i1 %24, label %29, label %25

25:                                               ; preds = %21
  %26 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t2, i64 8), align 1, !tbaa !14
  %27 = sext i8 %26 to i32
  %28 = icmp ne i32 %27, 105
  br i1 %28, label %29, label %30

29:                                               ; preds = %25, %21
  call void @abort() #2
  unreachable

30:                                               ; preds = %25
  %31 = load i32, ptr @t3, align 4, !tbaa !15
  %32 = icmp ne i32 %31, 1
  br i1 %32, label %36, label %33

33:                                               ; preds = %30
  %34 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t3, i64 12), align 4, !tbaa !17
  %35 = icmp ne i32 %34, 4
  br i1 %35, label %36, label %37

36:                                               ; preds = %33, %30
  call void @abort() #2
  unreachable

37:                                               ; preds = %33
  ret i32 0
}

; Function Attrs: cold noreturn nounwind
declare void @abort() #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { cold noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!14 = !{!13, !7, i64 8}
!15 = !{!16, !6, i64 0}
!16 = !{!"", !6, i64 0, !6, i64 4, !6, i64 8, !6, i64 12}
!17 = !{!16, !6, i64 12}
