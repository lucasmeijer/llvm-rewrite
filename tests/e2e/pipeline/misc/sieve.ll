; @source: tests/e2e/src/misc/sieve.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/sieve.c'
source_filename = "tests/e2e/src/misc/sieve.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.composite = internal global [10001 x i8] zeroinitializer, align 16
@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memset.p0.i64(ptr align 16 @main.composite, i8 0, i64 10001, i1 false)
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 0, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i32 2, ptr %4, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %37, %0
  %8 = load i32, ptr %4, align 4, !tbaa !9
  %9 = icmp sle i32 %8, 10000
  br i1 %9, label %11, label %10

10:                                               ; preds = %7
  store i32 2, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %40

11:                                               ; preds = %7
  %12 = load i32, ptr %4, align 4, !tbaa !9
  %13 = sext i32 %12 to i64
  %14 = getelementptr inbounds [10001 x i8], ptr @main.composite, i64 0, i64 %13
  %15 = load i8, ptr %14, align 1, !tbaa !10
  %16 = icmp ne i8 %15, 0
  br i1 %16, label %17, label %18

17:                                               ; preds = %11
  br label %37

18:                                               ; preds = %11
  %19 = load i32, ptr %2, align 4, !tbaa !9
  %20 = add nsw i32 %19, 1
  store i32 %20, ptr %2, align 4, !tbaa !9
  %21 = load i32, ptr %4, align 4, !tbaa !9
  store i32 %21, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #4
  %22 = load i32, ptr %4, align 4, !tbaa !9
  %23 = mul nsw i32 %22, 2
  store i32 %23, ptr %6, align 4, !tbaa !9
  br label %24

24:                                               ; preds = %32, %18
  %25 = load i32, ptr %6, align 4, !tbaa !9
  %26 = icmp sle i32 %25, 10000
  br i1 %26, label %28, label %27

27:                                               ; preds = %24
  store i32 5, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  br label %36

28:                                               ; preds = %24
  %29 = load i32, ptr %6, align 4, !tbaa !9
  %30 = sext i32 %29 to i64
  %31 = getelementptr inbounds [10001 x i8], ptr @main.composite, i64 0, i64 %30
  store i8 1, ptr %31, align 1, !tbaa !10
  br label %32

32:                                               ; preds = %28
  %33 = load i32, ptr %4, align 4, !tbaa !9
  %34 = load i32, ptr %6, align 4, !tbaa !9
  %35 = add nsw i32 %34, %33
  store i32 %35, ptr %6, align 4, !tbaa !9
  br label %24, !llvm.loop !11

36:                                               ; preds = %27
  br label %37

37:                                               ; preds = %36, %17
  %38 = load i32, ptr %4, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %4, align 4, !tbaa !9
  br label %7, !llvm.loop !13

40:                                               ; preds = %10
  %41 = load i32, ptr %2, align 4, !tbaa !9
  %42 = load i32, ptr %3, align 4, !tbaa !9
  %43 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %41, i32 noundef %42)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %5, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  %44 = load i32, ptr %1, align 4
  ret i32 %44
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!7, !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
