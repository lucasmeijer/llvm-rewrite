; @source: tests/e2e/src/arith/logic_ternary.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/logic_ternary.c'
source_filename = "tests/e2e/src/arith/logic_ternary.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [13 x i8] c"%d %d %d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 -5, ptr %3, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %51, %0
  %8 = load i32, ptr %3, align 4, !tbaa !9
  %9 = icmp sle i32 %8, 5
  br i1 %9, label %11, label %10

10:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %54

11:                                               ; preds = %7
  call void @llvm.lifetime.start.p0(ptr %4) #3
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = icmp sgt i32 %12, 0
  br i1 %13, label %14, label %18

14:                                               ; preds = %11
  %15 = load i32, ptr %3, align 4, !tbaa !9
  %16 = srem i32 %15, 2
  %17 = icmp eq i32 %16, 0
  br label %18

18:                                               ; preds = %14, %11
  %19 = phi i1 [ false, %11 ], [ %17, %14 ]
  %20 = zext i1 %19 to i32
  store i32 %20, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %21 = load i32, ptr %3, align 4, !tbaa !9
  %22 = icmp slt i32 %21, -2
  br i1 %22, label %26, label %23

23:                                               ; preds = %18
  %24 = load i32, ptr %3, align 4, !tbaa !9
  %25 = icmp eq i32 %24, 3
  br label %26

26:                                               ; preds = %23, %18
  %27 = phi i1 [ true, %18 ], [ %25, %23 ]
  %28 = zext i1 %27 to i32
  store i32 %28, ptr %5, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %29 = load i32, ptr %3, align 4, !tbaa !9
  %30 = icmp ne i32 %29, 0
  %31 = xor i1 %30, true
  %32 = zext i1 %31 to i32
  store i32 %32, ptr %6, align 4, !tbaa !9
  %33 = load i32, ptr %4, align 4, !tbaa !9
  %34 = mul nsw i32 %33, 100
  %35 = load i32, ptr %5, align 4, !tbaa !9
  %36 = mul nsw i32 %35, 10
  %37 = add nsw i32 %34, %36
  %38 = load i32, ptr %6, align 4, !tbaa !9
  %39 = add nsw i32 %37, %38
  %40 = load i32, ptr %3, align 4, !tbaa !9
  %41 = call i32 @pick(i32 noundef %40, i32 noundef 2)
  %42 = add nsw i32 %39, %41
  %43 = load i32, ptr %2, align 4, !tbaa !9
  %44 = add nsw i32 %43, %42
  store i32 %44, ptr %2, align 4, !tbaa !9
  %45 = load i32, ptr %4, align 4, !tbaa !9
  %46 = load i32, ptr %5, align 4, !tbaa !9
  %47 = load i32, ptr %6, align 4, !tbaa !9
  %48 = load i32, ptr %3, align 4, !tbaa !9
  %49 = call i32 @pick(i32 noundef %48, i32 noundef 2)
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %45, i32 noundef %46, i32 noundef %47, i32 noundef %49)
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  br label %51

51:                                               ; preds = %26
  %52 = load i32, ptr %3, align 4, !tbaa !9
  %53 = add nsw i32 %52, 1
  store i32 %53, ptr %3, align 4, !tbaa !9
  br label %7, !llvm.loop !10

54:                                               ; preds = %10
  %55 = load i32, ptr %2, align 4, !tbaa !9
  %56 = and i32 %55, 127
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 %56
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @pick(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !9
  %5 = load i32, ptr %3, align 4, !tbaa !9
  %6 = load i32, ptr %4, align 4, !tbaa !9
  %7 = icmp sgt i32 %5, %6
  br i1 %7, label %8, label %12

8:                                                ; preds = %2
  %9 = load i32, ptr %3, align 4, !tbaa !9
  %10 = load i32, ptr %4, align 4, !tbaa !9
  %11 = sub nsw i32 %9, %10
  br label %16

12:                                               ; preds = %2
  %13 = load i32, ptr %4, align 4, !tbaa !9
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = sub nsw i32 %13, %14
  br label %16

16:                                               ; preds = %12, %8
  %17 = phi i32 [ %11, %8 ], [ %15, %12 ]
  ret i32 %17
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
