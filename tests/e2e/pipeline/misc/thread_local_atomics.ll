; @source: tests/e2e/src/misc/thread_local_atomics.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/thread_local_atomics.c'
source_filename = "tests/e2e/src/misc/thread_local_atomics.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@tls_counter = internal thread_local global i32 7, align 4
@shared = internal global i32 0, align 4
@big = internal global i64 1, align 8
@.str = private unnamed_addr constant [14 x i8] c"%d %d %d %ld\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i8, align 1
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %14

14:                                               ; preds = %46, %0
  %15 = load i32, ptr %2, align 4, !tbaa !9
  %16 = icmp slt i32 %15, 10
  br i1 %16, label %18, label %17

17:                                               ; preds = %14
  call void @llvm.lifetime.end.p0(ptr %2) #4
  br label %49

18:                                               ; preds = %14
  %19 = load i32, ptr %2, align 4, !tbaa !9
  %20 = call align 4 ptr @llvm.threadlocal.address.p0(ptr align 4 @tls_counter)
  %21 = load i32, ptr %20, align 4, !tbaa !9
  %22 = add nsw i32 %21, %19
  store i32 %22, ptr %20, align 4, !tbaa !9
  %23 = load i32, ptr %2, align 4, !tbaa !9
  %24 = mul nsw i32 %23, 2
  store i32 %24, ptr %3, align 4, !tbaa !9
  %25 = load i32, ptr %3, align 4
  %26 = atomicrmw add ptr @shared, i32 %25 seq_cst, align 4
  store i32 %26, ptr %4, align 4
  %27 = load i32, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #4
  %28 = load atomic i64, ptr @big seq_cst, align 8
  store i64 %28, ptr %6, align 8
  %29 = load i64, ptr %6, align 8, !tbaa !10
  store i64 %29, ptr %5, align 8, !tbaa !10
  br label %30

30:                                               ; preds = %44, %18
  %31 = load i64, ptr %5, align 8, !tbaa !10
  %32 = mul nsw i64 %31, 3
  store i64 %32, ptr %7, align 8, !tbaa !10
  %33 = load i64, ptr %5, align 8
  %34 = load i64, ptr %7, align 8
  %35 = cmpxchg weak ptr @big, i64 %33, i64 %34 seq_cst seq_cst, align 8
  %36 = extractvalue { i64, i1 } %35, 0
  %37 = extractvalue { i64, i1 } %35, 1
  br i1 %37, label %39, label %38

38:                                               ; preds = %30
  store i64 %36, ptr %5, align 8
  br label %39

39:                                               ; preds = %38, %30
  %40 = zext i1 %37 to i8
  store i8 %40, ptr %8, align 1, !tbaa !12
  %41 = load i8, ptr %8, align 1, !tbaa !12, !range !14, !noundef !15
  %42 = trunc i8 %41 to i1
  %43 = xor i1 %42, true
  br i1 %43, label %44, label %45

44:                                               ; preds = %39
  br label %30, !llvm.loop !16

45:                                               ; preds = %39
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %46

46:                                               ; preds = %45
  %47 = load i32, ptr %2, align 4, !tbaa !9
  %48 = add nsw i32 %47, 1
  store i32 %48, ptr %2, align 4, !tbaa !9
  br label %14, !llvm.loop !18

49:                                               ; preds = %17
  call void @llvm.lifetime.start.p0(ptr %9) #4
  store i32 -1, ptr %10, align 4, !tbaa !9
  %50 = load i32, ptr %10, align 4
  %51 = atomicrmw xchg ptr @shared, i32 %50 seq_cst, align 4
  store i32 %51, ptr %11, align 4
  %52 = load i32, ptr %11, align 4, !tbaa !9
  store i32 %52, ptr %9, align 4, !tbaa !9
  %53 = call align 4 ptr @llvm.threadlocal.address.p0(ptr align 4 @tls_counter)
  %54 = load i32, ptr %53, align 4, !tbaa !9
  %55 = load i32, ptr %9, align 4, !tbaa !9
  %56 = load atomic i32, ptr @shared seq_cst, align 4
  store i32 %56, ptr %12, align 4
  %57 = load i32, ptr %12, align 4, !tbaa !9
  %58 = load atomic i64, ptr @big seq_cst, align 8
  store i64 %58, ptr %13, align 8
  %59 = load i64, ptr %13, align 8, !tbaa !10
  %60 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %54, i32 noundef %55, i32 noundef %57, i64 noundef %59)
  call void @llvm.lifetime.end.p0(ptr %9) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare nonnull ptr @llvm.threadlocal.address.p0(ptr nonnull) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
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
!10 = !{!11, !11, i64 0}
!11 = !{!"long", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"_Bool", !7, i64 0}
!14 = !{i8 0, i8 2}
!15 = !{}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
