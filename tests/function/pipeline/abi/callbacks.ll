; @source: tests/function/src/abi/callbacks.c
; @opt: -O2
; @llc: -O2
; @driver: tests/function/src/abi/callbacks.driver.c
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/function/src/abi/callbacks.c'
source_filename = "tests/function/src/abi/callbacks.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i64 @fold(ptr noundef %0, i32 noundef %1, i64 noundef %2, ptr noundef %3) #0 {
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i64, align 8
  %8 = alloca ptr, align 8
  %9 = alloca i64, align 8
  %10 = alloca i32, align 4
  store ptr %0, ptr %5, align 8, !tbaa !9
  store i32 %1, ptr %6, align 4, !tbaa !12
  store i64 %2, ptr %7, align 8, !tbaa !13
  store ptr %3, ptr %8, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %9) #2
  %11 = load i64, ptr %7, align 8, !tbaa !13
  store i64 %11, ptr %9, align 8, !tbaa !13
  call void @llvm.lifetime.start.p0(ptr %10) #2
  store i32 0, ptr %10, align 4, !tbaa !12
  br label %12

12:                                               ; preds = %26, %4
  %13 = load i32, ptr %10, align 4, !tbaa !12
  %14 = load i32, ptr %6, align 4, !tbaa !12
  %15 = icmp slt i32 %13, %14
  br i1 %15, label %17, label %16

16:                                               ; preds = %12
  call void @llvm.lifetime.end.p0(ptr %10) #2
  br label %29

17:                                               ; preds = %12
  %18 = load ptr, ptr %8, align 8, !tbaa !15
  %19 = load i64, ptr %9, align 8, !tbaa !13
  %20 = load ptr, ptr %5, align 8, !tbaa !9
  %21 = load i32, ptr %10, align 4, !tbaa !12
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds i64, ptr %20, i64 %22
  %24 = load i64, ptr %23, align 8, !tbaa !13
  %25 = call i64 %18(i64 noundef %19, i64 noundef %24)
  store i64 %25, ptr %9, align 8, !tbaa !13
  br label %26

26:                                               ; preds = %17
  %27 = load i32, ptr %10, align 4, !tbaa !12
  %28 = add nsw i32 %27, 1
  store i32 %28, ptr %10, align 4, !tbaa !12
  br label %12, !llvm.loop !16

29:                                               ; preds = %16
  %30 = load i64, ptr %9, align 8, !tbaa !13
  call void @llvm.lifetime.end.p0(ptr %9) #2
  ret i64 %30
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local double @map_sum(ptr noundef %0, i32 noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca double, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !18
  store i32 %1, ptr %5, align 4, !tbaa !12
  store ptr %2, ptr %6, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %7) #2
  store double 0.000000e+00, ptr %7, align 8, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %8) #2
  store i32 0, ptr %8, align 4, !tbaa !12
  br label %9

9:                                                ; preds = %24, %3
  %10 = load i32, ptr %8, align 4, !tbaa !12
  %11 = load i32, ptr %5, align 4, !tbaa !12
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %14, label %13

13:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %8) #2
  br label %27

14:                                               ; preds = %9
  %15 = load ptr, ptr %6, align 8, !tbaa !15
  %16 = load ptr, ptr %4, align 8, !tbaa !18
  %17 = load i32, ptr %8, align 4, !tbaa !12
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds double, ptr %16, i64 %18
  %20 = load double, ptr %19, align 8, !tbaa !20
  %21 = call double %15(double noundef %20)
  %22 = load double, ptr %7, align 8, !tbaa !20
  %23 = fadd double %22, %21
  store double %23, ptr %7, align 8, !tbaa !20
  br label %24

24:                                               ; preds = %14
  %25 = load i32, ptr %8, align 4, !tbaa !12
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %8, align 4, !tbaa !12
  br label %9, !llvm.loop !22

27:                                               ; preds = %13
  %28 = load double, ptr %7, align 8, !tbaa !20
  call void @llvm.lifetime.end.p0(ptr %7) #2
  ret double %28
}

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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 long", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"long", !7, i64 0}
!15 = !{!11, !11, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = !{!19, !19, i64 0}
!19 = !{!"p1 double", !11, i64 0}
!20 = !{!21, !21, i64 0}
!21 = !{!"double", !7, i64 0}
!22 = distinct !{!22, !17}
