; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/TestLoop.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/TestLoop.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/TestLoop.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @foo(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !9
  %5 = load i32, ptr %4, align 4, !tbaa !9
  %6 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %5)
  %7 = load i32, ptr %4, align 4, !tbaa !9
  ret i32 %7
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca [4 x i32], align 16
  store i32 0, ptr %2, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  store i32 3, ptr %4, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %21, %1
  %7 = load i32, ptr %4, align 4, !tbaa !9
  %8 = icmp sge i32 %7, 0
  br i1 %8, label %9, label %24

9:                                                ; preds = %6
  %10 = load i32, ptr %3, align 4, !tbaa !9
  %11 = sub nsw i32 %10, 1
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = mul nsw i32 %12, 4
  %14 = load i32, ptr %4, align 4, !tbaa !9
  %15 = add nsw i32 %13, %14
  %16 = add nsw i32 %15, 1
  %17 = call i32 @foo(i32 noundef %11, i32 noundef %16)
  %18 = load i32, ptr %4, align 4, !tbaa !9
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds [4 x i32], ptr %5, i64 0, i64 %19
  store i32 %17, ptr %20, align 4, !tbaa !9
  br label %21

21:                                               ; preds = %9
  %22 = load i32, ptr %4, align 4, !tbaa !9
  %23 = add nsw i32 %22, -1
  store i32 %23, ptr %4, align 4, !tbaa !9
  br label %6, !llvm.loop !10

24:                                               ; preds = %6
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %25

25:                                               ; preds = %34, %24
  %26 = load i32, ptr %4, align 4, !tbaa !9
  %27 = icmp slt i32 %26, 4
  br i1 %27, label %28, label %37

28:                                               ; preds = %25
  %29 = load i32, ptr %4, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [4 x i32], ptr %5, i64 0, i64 %30
  %32 = load i32, ptr %31, align 4, !tbaa !9
  %33 = call i32 @foo(i32 noundef 0, i32 noundef %32)
  br label %34

34:                                               ; preds = %28
  %35 = load i32, ptr %4, align 4, !tbaa !9
  %36 = add nsw i32 %35, 1
  store i32 %36, ptr %4, align 4, !tbaa !9
  br label %25, !llvm.loop !12

37:                                               ; preds = %25
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
