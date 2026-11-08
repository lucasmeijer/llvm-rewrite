; @source: tests/e2e/src/memory/vla_alloca.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/vla_alloca.c'
source_filename = "tests/e2e/src/memory/vla_alloca.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 1, ptr %3, align 4, !tbaa !9
  br label %4

4:                                                ; preds = %16, %0
  %5 = load i32, ptr %3, align 4, !tbaa !9
  %6 = icmp slt i32 %5, 40
  br i1 %6, label %8, label %7

7:                                                ; preds = %4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  br label %19

8:                                                ; preds = %4
  %9 = load i32, ptr %3, align 4, !tbaa !9
  %10 = call i32 @f(i32 noundef %9)
  %11 = load i32, ptr %2, align 4, !tbaa !9
  %12 = add nsw i32 %11, %10
  store i32 %12, ptr %2, align 4, !tbaa !9
  %13 = load i32, ptr %3, align 4, !tbaa !9
  %14 = call i32 @f(i32 noundef %13)
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %14)
  br label %16

16:                                               ; preds = %8
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = add nsw i32 %17, 5
  store i32 %18, ptr %3, align 4, !tbaa !9
  br label %4, !llvm.loop !10

19:                                               ; preds = %7
  %20 = load i32, ptr %2, align 4, !tbaa !9
  %21 = and i32 %20, 255
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 %21
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @f(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %8 = load i32, ptr %2, align 4, !tbaa !9
  %9 = zext i32 %8 to i64
  %10 = call ptr @llvm.stacksave.p0()
  store ptr %10, ptr %3, align 8
  %11 = alloca i32, i64 %9, align 16
  store i64 %9, ptr %4, align 8
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %12

12:                                               ; preds = %23, %1
  %13 = load i32, ptr %5, align 4, !tbaa !9
  %14 = load i32, ptr %2, align 4, !tbaa !9
  %15 = icmp slt i32 %13, %14
  br i1 %15, label %17, label %16

16:                                               ; preds = %12
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %26

17:                                               ; preds = %12
  %18 = load i32, ptr %5, align 4, !tbaa !9
  %19 = mul nsw i32 %18, 3
  %20 = load i32, ptr %5, align 4, !tbaa !9
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds i32, ptr %11, i64 %21
  store i32 %19, ptr %22, align 4, !tbaa !9
  br label %23

23:                                               ; preds = %17
  %24 = load i32, ptr %5, align 4, !tbaa !9
  %25 = add nsw i32 %24, 1
  store i32 %25, ptr %5, align 4, !tbaa !9
  br label %12, !llvm.loop !12

26:                                               ; preds = %16
  call void @llvm.lifetime.start.p0(ptr %6) #4
  store i32 0, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #4
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %27

27:                                               ; preds = %44, %26
  %28 = load i32, ptr %7, align 4, !tbaa !9
  %29 = load i32, ptr %2, align 4, !tbaa !9
  %30 = icmp slt i32 %28, %29
  br i1 %30, label %32, label %31

31:                                               ; preds = %27
  call void @llvm.lifetime.end.p0(ptr %7) #4
  br label %47

32:                                               ; preds = %27
  %33 = load i32, ptr %2, align 4, !tbaa !9
  %34 = sub nsw i32 %33, 1
  %35 = load i32, ptr %7, align 4, !tbaa !9
  %36 = sub nsw i32 %34, %35
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds i32, ptr %11, i64 %37
  %39 = load i32, ptr %38, align 4, !tbaa !9
  %40 = load i32, ptr %7, align 4, !tbaa !9
  %41 = mul nsw i32 %39, %40
  %42 = load i32, ptr %6, align 4, !tbaa !9
  %43 = add nsw i32 %42, %41
  store i32 %43, ptr %6, align 4, !tbaa !9
  br label %44

44:                                               ; preds = %32
  %45 = load i32, ptr %7, align 4, !tbaa !9
  %46 = add nsw i32 %45, 1
  store i32 %46, ptr %7, align 4, !tbaa !9
  br label %27, !llvm.loop !13

47:                                               ; preds = %31
  %48 = load i32, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %6) #4
  %49 = load ptr, ptr %3, align 8
  call void @llvm.stackrestore.p0(ptr %49)
  ret i32 %48
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare ptr @llvm.stacksave.p0() #3

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.stackrestore.p0(ptr) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
!13 = distinct !{!13, !11}
