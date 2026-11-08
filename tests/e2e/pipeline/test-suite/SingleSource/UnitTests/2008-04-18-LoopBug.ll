; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-18-LoopBug.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-18-LoopBug.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2008-04-18-LoopBug.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [16 x i8] c"%d %d %d %d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @foo(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 3, ptr %5, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %21, %2
  %7 = load i32, ptr %5, align 4, !tbaa !9
  %8 = load i32, ptr %3, align 4, !tbaa !9
  %9 = icmp ugt i32 %7, %8
  br i1 %9, label %10, label %24

10:                                               ; preds = %6
  %11 = load ptr, ptr %4, align 8, !tbaa !10
  %12 = load i32, ptr %5, align 4, !tbaa !9
  %13 = sub i32 %12, 1
  %14 = zext i32 %13 to i64
  %15 = getelementptr inbounds nuw i32, ptr %11, i64 %14
  %16 = load i32, ptr %15, align 4, !tbaa !9
  %17 = load ptr, ptr %4, align 8, !tbaa !10
  %18 = load i32, ptr %5, align 4, !tbaa !9
  %19 = zext i32 %18 to i64
  %20 = getelementptr inbounds nuw i32, ptr %17, i64 %19
  store i32 %16, ptr %20, align 4, !tbaa !9
  br label %21

21:                                               ; preds = %10
  %22 = load i32, ptr %5, align 4, !tbaa !9
  %23 = add i32 %22, -1
  store i32 %23, ptr %5, align 4, !tbaa !9
  br label %6, !llvm.loop !13

24:                                               ; preds = %6
  %25 = load i32, ptr %3, align 4, !tbaa !9
  %26 = load ptr, ptr %4, align 8, !tbaa !10
  %27 = getelementptr inbounds i32, ptr %26, i64 0
  %28 = load i32, ptr %27, align 4, !tbaa !9
  %29 = load ptr, ptr %4, align 8, !tbaa !10
  %30 = getelementptr inbounds i32, ptr %29, i64 1
  %31 = load i32, ptr %30, align 4, !tbaa !9
  %32 = load ptr, ptr %4, align 8, !tbaa !10
  %33 = getelementptr inbounds i32, ptr %32, i64 2
  %34 = load i32, ptr %33, align 4, !tbaa !9
  %35 = load ptr, ptr %4, align 8, !tbaa !10
  %36 = getelementptr inbounds i32, ptr %35, i64 3
  %37 = load i32, ptr %36, align 4, !tbaa !9
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %25, i32 noundef %28, i32 noundef %31, i32 noundef %34, i32 noundef %37)
  call void @llvm.lifetime.end.p0(ptr %5) #4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #3 {
  %1 = alloca i32, align 4
  %2 = alloca [4 x i32], align 16
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %4

4:                                                ; preds = %14, %0
  %5 = load i32, ptr %3, align 4, !tbaa !9
  %6 = icmp slt i32 %5, 5
  br i1 %6, label %7, label %17

7:                                                ; preds = %4
  %8 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  store i32 5, ptr %8, align 16, !tbaa !9
  %9 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 1
  store i32 6, ptr %9, align 4, !tbaa !9
  %10 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 2
  store i32 7, ptr %10, align 8, !tbaa !9
  %11 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 3
  store i32 8, ptr %11, align 4, !tbaa !9
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  call void @foo(i32 noundef %12, ptr noundef %13)
  br label %14

14:                                               ; preds = %7
  %15 = load i32, ptr %3, align 4, !tbaa !9
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %3, align 4, !tbaa !9
  br label %4, !llvm.loop !15

17:                                               ; preds = %4
  %18 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  store i32 5, ptr %18, align 16, !tbaa !9
  %19 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 1
  store i32 6, ptr %19, align 4, !tbaa !9
  %20 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 2
  store i32 7, ptr %20, align 8, !tbaa !9
  %21 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 3
  store i32 8, ptr %21, align 4, !tbaa !9
  %22 = getelementptr inbounds [4 x i32], ptr %2, i64 0, i64 0
  call void @foo(i32 noundef -1, ptr noundef %22)
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

attributes #0 = { noinline nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"p1 int", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = distinct !{!13, !14}
!14 = !{!"llvm.loop.mustprogress"}
!15 = distinct !{!15, !14}
