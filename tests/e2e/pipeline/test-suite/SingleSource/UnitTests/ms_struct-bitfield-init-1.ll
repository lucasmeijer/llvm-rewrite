; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init-1.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct-bitfield-init-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.anon.0 = type { i8, i8, i8, i8 }
%struct.anon.1 = type { i8, i8, i8, i8 }
%struct.anon.2 = type { i8, i8, i8, i8 }
%struct.anon.3 = type { i8, i8, i8, i8 }
%struct.anon.4 = type { i8, [3 x i8], i8, [3 x i8] }
%struct.anon.5 = type { i8, i8, i8, i8 }
%struct.anon.6 = type { i8, i8 }
%struct.anon.7 = type { i8, [3 x i8] }

@t1 = dso_local global { i8, i8, [2 x i8], i8, i8, [2 x i8] } { i8 1, i8 0, [2 x i8] zeroinitializer, i8 2, i8 0, [2 x i8] zeroinitializer }, align 4
@t2 = dso_local global %struct.anon.0 { i8 3, i8 0, i8 4, i8 0 }, align 2
@t3 = dso_local global %struct.anon.1 { i8 5, i8 0, i8 6, i8 0 }, align 2
@t5 = dso_local global %struct.anon.2 { i8 7, i8 0, i8 8, i8 0 }, align 2
@t6 = dso_local global %struct.anon.3 { i8 5, i8 0, i8 10, i8 0 }, align 2
@t7 = dso_local global %struct.anon.4 { i8 5, [3 x i8] zeroinitializer, i8 10, [3 x i8] zeroinitializer }, align 4
@t8 = dso_local global %struct.anon.5 { i8 5, i8 0, i8 10, i8 0 }, align 2
@t10 = dso_local global %struct.anon.6 { i8 5, i8 10 }, align 1
@t4 = dso_local global %struct.anon.7 zeroinitializer, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = load i32, ptr @t1, align 4
  %3 = and i32 %2, 4095
  %4 = icmp ne i32 %3, 1
  br i1 %4, label %9, label %5

5:                                                ; preds = %0
  %6 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 4), align 4
  %7 = and i32 %6, 4095
  %8 = icmp ne i32 %7, 2
  br i1 %8, label %9, label %10

9:                                                ; preds = %5, %0
  call void @abort() #2
  unreachable

10:                                               ; preds = %5
  %11 = load i8, ptr @t2, align 2
  %12 = shl i8 %11, 4
  %13 = ashr i8 %12, 4
  %14 = sext i8 %13 to i32
  %15 = icmp ne i32 %14, 3
  br i1 %15, label %20, label %16

16:                                               ; preds = %10
  %17 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t2, i64 2), align 2, !tbaa !9
  %18 = sext i8 %17 to i32
  %19 = icmp ne i32 %18, 4
  br i1 %19, label %20, label %21

20:                                               ; preds = %16, %10
  call void @abort() #2
  unreachable

21:                                               ; preds = %16
  %22 = load i8, ptr @t3, align 2
  %23 = shl i8 %22, 4
  %24 = ashr i8 %23, 4
  %25 = sext i8 %24 to i32
  %26 = icmp ne i32 %25, 5
  br i1 %26, label %31, label %27

27:                                               ; preds = %21
  %28 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t3, i64 2), align 2, !tbaa !9
  %29 = sext i8 %28 to i32
  %30 = icmp ne i32 %29, 6
  br i1 %30, label %31, label %32

31:                                               ; preds = %27, %21
  call void @abort() #2
  unreachable

32:                                               ; preds = %27
  %33 = load i8, ptr @t5, align 2
  %34 = shl i8 %33, 4
  %35 = ashr i8 %34, 4
  %36 = sext i8 %35 to i32
  %37 = icmp ne i32 %36, 7
  br i1 %37, label %42, label %38

38:                                               ; preds = %32
  %39 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t5, i64 2), align 2
  %40 = sext i8 %39 to i32
  %41 = icmp ne i32 %40, 8
  br i1 %41, label %42, label %43

42:                                               ; preds = %38, %32
  call void @abort() #2
  unreachable

43:                                               ; preds = %38
  %44 = load i8, ptr @t6, align 2
  %45 = shl i8 %44, 4
  %46 = ashr i8 %45, 4
  %47 = sext i8 %46 to i32
  %48 = icmp ne i32 %47, 5
  br i1 %48, label %53, label %49

49:                                               ; preds = %43
  %50 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t6, i64 2), align 2, !tbaa !9
  %51 = sext i8 %50 to i32
  %52 = icmp ne i32 %51, 10
  br i1 %52, label %53, label %54

53:                                               ; preds = %49, %43
  call void @abort() #2
  unreachable

54:                                               ; preds = %49
  %55 = load i8, ptr @t7, align 4
  %56 = shl i8 %55, 4
  %57 = ashr i8 %56, 4
  %58 = sext i8 %57 to i32
  %59 = icmp ne i32 %58, 5
  br i1 %59, label %64, label %60

60:                                               ; preds = %54
  %61 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t7, i64 4), align 4, !tbaa !11
  %62 = sext i8 %61 to i32
  %63 = icmp ne i32 %62, 10
  br i1 %63, label %64, label %65

64:                                               ; preds = %60, %54
  call void @abort() #2
  unreachable

65:                                               ; preds = %60
  %66 = load i8, ptr @t8, align 2
  %67 = shl i8 %66, 4
  %68 = ashr i8 %67, 4
  %69 = sext i8 %68 to i32
  %70 = icmp ne i32 %69, 5
  br i1 %70, label %77, label %71

71:                                               ; preds = %65
  %72 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t8, i64 2), align 2
  %73 = shl i8 %72, 1
  %74 = ashr i8 %73, 1
  %75 = sext i8 %74 to i32
  %76 = icmp ne i32 %75, 10
  br i1 %76, label %77, label %78

77:                                               ; preds = %71, %65
  call void @abort() #2
  unreachable

78:                                               ; preds = %71
  %79 = load i8, ptr @t10, align 1
  %80 = shl i8 %79, 4
  %81 = ashr i8 %80, 4
  %82 = sext i8 %81 to i32
  %83 = icmp ne i32 %82, 5
  br i1 %83, label %88, label %84

84:                                               ; preds = %78
  %85 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t10, i64 1), align 1, !tbaa !13
  %86 = sext i8 %85 to i32
  %87 = icmp ne i32 %86, 10
  br i1 %87, label %88, label %89

88:                                               ; preds = %84, %78
  call void @abort() #2
  unreachable

89:                                               ; preds = %84
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
!9 = !{!10, !7, i64 2}
!10 = !{!"", !7, i64 0, !7, i64 2}
!11 = !{!12, !7, i64 4}
!12 = !{!"", !7, i64 0, !7, i64 4}
!13 = !{!14, !7, i64 1}
!14 = !{!"", !7, i64 0, !7, i64 1}
