; @source: tests/e2e/src/memory/local_array.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/local_array.c'
source_filename = "tests/e2e/src/memory/local_array.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [16 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #2
  call void @llvm.lifetime.start.p0(ptr %3) #2
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %17, %0
  %7 = load i32, ptr %3, align 4, !tbaa !9
  %8 = icmp slt i32 %7, 16
  br i1 %8, label %10, label %9

9:                                                ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %3) #2
  br label %20

10:                                               ; preds = %6
  %11 = load i32, ptr %3, align 4, !tbaa !9
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = mul nsw i32 %11, %12
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [16 x i32], ptr %2, i64 0, i64 %15
  store i32 %13, ptr %16, align 4, !tbaa !9
  br label %17

17:                                               ; preds = %10
  %18 = load i32, ptr %3, align 4, !tbaa !9
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %3, align 4, !tbaa !9
  br label %6, !llvm.loop !10

20:                                               ; preds = %9
  call void @llvm.lifetime.start.p0(ptr %4) #2
  store i32 0, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #2
  store i32 15, ptr %5, align 4, !tbaa !9
  br label %21

21:                                               ; preds = %32, %20
  %22 = load i32, ptr %5, align 4, !tbaa !9
  %23 = icmp sge i32 %22, 0
  br i1 %23, label %25, label %24

24:                                               ; preds = %21
  call void @llvm.lifetime.end.p0(ptr %5) #2
  br label %35

25:                                               ; preds = %21
  %26 = load i32, ptr %5, align 4, !tbaa !9
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [16 x i32], ptr %2, i64 0, i64 %27
  %29 = load i32, ptr %28, align 4, !tbaa !9
  %30 = load i32, ptr %4, align 4, !tbaa !9
  %31 = add nsw i32 %30, %29
  store i32 %31, ptr %4, align 4, !tbaa !9
  br label %32

32:                                               ; preds = %25
  %33 = load i32, ptr %5, align 4, !tbaa !9
  %34 = sub nsw i32 %33, 2
  store i32 %34, ptr %5, align 4, !tbaa !9
  br label %21, !llvm.loop !12

35:                                               ; preds = %24
  %36 = load i32, ptr %4, align 4, !tbaa !9
  %37 = srem i32 %36, 256
  call void @llvm.lifetime.end.p0(ptr %4) #2
  call void @llvm.lifetime.end.p0(ptr %2) #2
  ret i32 %37
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind }

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
