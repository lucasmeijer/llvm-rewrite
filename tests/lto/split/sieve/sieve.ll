; @source: tests/lto/src/split/sieve/sieve.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/sieve/sieve.c'
source_filename = "tests/lto/src/split/sieve/sieve.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; Function Attrs: nounwind uwtable
define dso_local i32 @sieve(ptr noundef %0, i32 noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  store ptr %0, ptr %4, align 8, !tbaa !9
  store i32 %1, ptr %5, align 4, !tbaa !12
  store ptr %2, ptr %6, align 8, !tbaa !13
  %11 = load ptr, ptr %4, align 8, !tbaa !9
  %12 = load i32, ptr %5, align 4, !tbaa !12
  %13 = sext i32 %12 to i64
  %14 = add i64 %13, 1
  call void @llvm.memset.p0.i64(ptr align 1 %11, i8 0, i64 %14, i1 false)
  call void @llvm.lifetime.start.p0(ptr %7) #3
  store i32 0, ptr %7, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %8) #3
  store i32 2, ptr %8, align 4, !tbaa !12
  br label %15

15:                                               ; preds = %50, %3
  %16 = load i32, ptr %8, align 4, !tbaa !12
  %17 = load i32, ptr %5, align 4, !tbaa !12
  %18 = icmp sle i32 %16, %17
  br i1 %18, label %20, label %19

19:                                               ; preds = %15
  store i32 2, ptr %9, align 4
  call void @llvm.lifetime.end.p0(ptr %8) #3
  br label %53

20:                                               ; preds = %15
  %21 = load ptr, ptr %4, align 8, !tbaa !9
  %22 = load i32, ptr %8, align 4, !tbaa !12
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds i8, ptr %21, i64 %23
  %25 = load i8, ptr %24, align 1, !tbaa !15
  %26 = icmp ne i8 %25, 0
  br i1 %26, label %27, label %28

27:                                               ; preds = %20
  br label %50

28:                                               ; preds = %20
  %29 = load i32, ptr %7, align 4, !tbaa !12
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %7, align 4, !tbaa !12
  %31 = load i32, ptr %8, align 4, !tbaa !12
  %32 = load ptr, ptr %6, align 8, !tbaa !13
  store i32 %31, ptr %32, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %10) #3
  %33 = load i32, ptr %8, align 4, !tbaa !12
  %34 = mul nsw i32 %33, 2
  store i32 %34, ptr %10, align 4, !tbaa !12
  br label %35

35:                                               ; preds = %45, %28
  %36 = load i32, ptr %10, align 4, !tbaa !12
  %37 = load i32, ptr %5, align 4, !tbaa !12
  %38 = icmp sle i32 %36, %37
  br i1 %38, label %40, label %39

39:                                               ; preds = %35
  store i32 5, ptr %9, align 4
  call void @llvm.lifetime.end.p0(ptr %10) #3
  br label %49

40:                                               ; preds = %35
  %41 = load ptr, ptr %4, align 8, !tbaa !9
  %42 = load i32, ptr %10, align 4, !tbaa !12
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds i8, ptr %41, i64 %43
  store i8 1, ptr %44, align 1, !tbaa !15
  br label %45

45:                                               ; preds = %40
  %46 = load i32, ptr %8, align 4, !tbaa !12
  %47 = load i32, ptr %10, align 4, !tbaa !12
  %48 = add nsw i32 %47, %46
  store i32 %48, ptr %10, align 4, !tbaa !12
  br label %35, !llvm.loop !16

49:                                               ; preds = %39
  br label %50

50:                                               ; preds = %49, %27
  %51 = load i32, ptr %8, align 4, !tbaa !12
  %52 = add nsw i32 %51, 1
  store i32 %52, ptr %8, align 4, !tbaa !12
  br label %15, !llvm.loop !18

53:                                               ; preds = %19
  %54 = load i32, ptr %7, align 4, !tbaa !12
  store i32 1, ptr %9, align 4
  call void @llvm.lifetime.end.p0(ptr %7) #3
  ret i32 %54
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 int", !11, i64 0}
!15 = !{!7, !7, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
