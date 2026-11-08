; @source: tests/e2e/src/control/nested_loops.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/nested_loops.c'
source_filename = "tests/e2e/src/control/nested_loops.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i64 0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %8

8:                                                ; preds = %41, %0
  %9 = load i32, ptr %3, align 4, !tbaa !11
  %10 = icmp slt i32 %9, 20
  br i1 %10, label %12, label %11

11:                                               ; preds = %8
  store i32 2, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %44

12:                                               ; preds = %8
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %13 = load i32, ptr %3, align 4, !tbaa !11
  store i32 %13, ptr %5, align 4, !tbaa !11
  br label %14

14:                                               ; preds = %37, %12
  %15 = load i32, ptr %5, align 4, !tbaa !11
  %16 = icmp slt i32 %15, 20
  br i1 %16, label %18, label %17

17:                                               ; preds = %14
  store i32 5, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %5) #3
  br label %40

18:                                               ; preds = %14
  call void @llvm.lifetime.start.p0(ptr %6) #3
  store i32 0, ptr %6, align 4, !tbaa !11
  br label %19

19:                                               ; preds = %33, %18
  %20 = load i32, ptr %6, align 4, !tbaa !11
  %21 = load i32, ptr %5, align 4, !tbaa !11
  %22 = icmp slt i32 %20, %21
  br i1 %22, label %24, label %23

23:                                               ; preds = %19
  store i32 8, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %6) #3
  br label %36

24:                                               ; preds = %19
  %25 = load i32, ptr %3, align 4, !tbaa !11
  %26 = load i32, ptr %5, align 4, !tbaa !11
  %27 = mul nsw i32 %25, %26
  %28 = load i32, ptr %6, align 4, !tbaa !11
  %29 = sub nsw i32 %27, %28
  %30 = sext i32 %29 to i64
  %31 = load i64, ptr %2, align 8, !tbaa !9
  %32 = add nsw i64 %31, %30
  store i64 %32, ptr %2, align 8, !tbaa !9
  br label %33

33:                                               ; preds = %24
  %34 = load i32, ptr %6, align 4, !tbaa !11
  %35 = add nsw i32 %34, 2
  store i32 %35, ptr %6, align 4, !tbaa !11
  br label %19, !llvm.loop !12

36:                                               ; preds = %23
  br label %37

37:                                               ; preds = %36
  %38 = load i32, ptr %5, align 4, !tbaa !11
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %5, align 4, !tbaa !11
  br label %14, !llvm.loop !14

40:                                               ; preds = %17
  br label %41

41:                                               ; preds = %40
  %42 = load i32, ptr %3, align 4, !tbaa !11
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %3, align 4, !tbaa !11
  br label %8, !llvm.loop !15

44:                                               ; preds = %11
  %45 = load i64, ptr %2, align 8, !tbaa !9
  %46 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %45)
  call void @llvm.lifetime.start.p0(ptr %7) #3
  store i32 0, ptr %7, align 4, !tbaa !11
  br label %47

47:                                               ; preds = %50, %44
  %48 = load i32, ptr %7, align 4, !tbaa !11
  %49 = add nsw i32 %48, 3
  store i32 %49, ptr %7, align 4, !tbaa !11
  br label %50

50:                                               ; preds = %47
  %51 = load i32, ptr %7, align 4, !tbaa !11
  %52 = icmp slt i32 %51, 100
  br i1 %52, label %47, label %53, !llvm.loop !16

53:                                               ; preds = %50
  %54 = load i32, ptr %7, align 4, !tbaa !11
  %55 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %54)
  store i32 0, ptr %1, align 4
  store i32 1, ptr %4, align 4
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  %56 = load i32, ptr %1, align 4
  ret i32 %56
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

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
!9 = !{!10, !10, i64 0}
!10 = !{!"long", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = distinct !{!14, !13}
!15 = distinct !{!15, !13}
!16 = distinct !{!16, !13}
