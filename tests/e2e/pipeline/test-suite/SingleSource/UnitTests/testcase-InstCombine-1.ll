; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/testcase-InstCombine-1.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S = type { [9 x i8] }

@f = dso_local global i32 0, align 4
@__const.main.m = private unnamed_addr constant { i8, i8, i8, i8, i8, i8, i8, i8, i8 } { i8 5, i8 0, i8 -40, i8 -1, i8 -1, i8 79, i8 0, i8 20, i8 0 }, align 1
@h = dso_local global %struct.S zeroinitializer, align 1
@.str = private unnamed_addr constant [2 x i8] c"1\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.S, align 1
  store i32 0, ptr %1, align 4
  br label %3

3:                                                ; preds = %7, %0
  %4 = load i32, ptr @f, align 4, !tbaa !9
  %5 = icmp ne i32 %4, 0
  br i1 %5, label %6, label %10

6:                                                ; preds = %3
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %2, ptr align 1 @__const.main.m, i64 9, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 @h, ptr align 1 %2, i64 9, i1 false), !tbaa.struct !10
  call void @llvm.lifetime.end.p0(ptr %2) #3
  br label %7

7:                                                ; preds = %6
  %8 = load i32, ptr @f, align 4, !tbaa !9
  %9 = add nsw i32 %8, 1
  store i32 %9, ptr @f, align 4, !tbaa !9
  br label %3, !llvm.loop !12

10:                                               ; preds = %3
  %11 = load i72, ptr @h, align 1
  %12 = shl i72 %11, 14
  %13 = ashr i72 %12, 57
  %14 = trunc i72 %13 to i32
  %15 = sext i32 %14 to i64
  %16 = load i72, ptr @h, align 1
  %17 = shl i72 %16, 14
  %18 = ashr i72 %17, 57
  %19 = trunc i72 %18 to i32
  %20 = load i72, ptr @h, align 1
  %21 = shl i72 %20, 14
  %22 = ashr i72 %21, 57
  %23 = trunc i72 %22 to i32
  %24 = mul nsw i32 %19, %23
  %25 = sext i32 %24 to i64
  %26 = sub nsw i64 0, %25
  %27 = icmp ne i64 %15, %26
  br i1 %27, label %28, label %30

28:                                               ; preds = %10
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  br label %30

30:                                               ; preds = %28, %10
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!13 = !{!"llvm.loop.mustprogress"}
