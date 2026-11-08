; @source: tests/e2e/src/misc/thread_local_atomics.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/thread_local_atomics.c'
source_filename = "tests/e2e/src/misc/thread_local_atomics.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@tls_counter = internal thread_local global i32 7, align 4
@shared = internal global i32 0, align 4
@big = internal global i64 1, align 8
@.str = private unnamed_addr constant [14 x i8] c"%d %d %d %ld\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
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
  store i32 0, ptr %2, align 4
  br label %14

14:                                               ; preds = %45, %0
  %15 = load i32, ptr %2, align 4
  %16 = icmp slt i32 %15, 10
  br i1 %16, label %17, label %48

17:                                               ; preds = %14
  %18 = load i32, ptr %2, align 4
  %19 = call align 4 ptr @llvm.threadlocal.address.p0(ptr align 4 @tls_counter)
  %20 = load i32, ptr %19, align 4
  %21 = add nsw i32 %20, %18
  store i32 %21, ptr %19, align 4
  %22 = load i32, ptr %2, align 4
  %23 = mul nsw i32 %22, 2
  store i32 %23, ptr %3, align 4
  %24 = load i32, ptr %3, align 4
  %25 = atomicrmw add ptr @shared, i32 %24 seq_cst, align 4
  store i32 %25, ptr %4, align 4
  %26 = load i32, ptr %4, align 4
  %27 = load atomic i64, ptr @big seq_cst, align 8
  store i64 %27, ptr %6, align 8
  %28 = load i64, ptr %6, align 8
  store i64 %28, ptr %5, align 8
  br label %29

29:                                               ; preds = %43, %17
  %30 = load i64, ptr %5, align 8
  %31 = mul nsw i64 %30, 3
  store i64 %31, ptr %7, align 8
  %32 = load i64, ptr %5, align 8
  %33 = load i64, ptr %7, align 8
  %34 = cmpxchg weak ptr @big, i64 %32, i64 %33 seq_cst seq_cst, align 8
  %35 = extractvalue { i64, i1 } %34, 0
  %36 = extractvalue { i64, i1 } %34, 1
  br i1 %36, label %38, label %37

37:                                               ; preds = %29
  store i64 %35, ptr %5, align 8
  br label %38

38:                                               ; preds = %37, %29
  %39 = zext i1 %36 to i8
  store i8 %39, ptr %8, align 1
  %40 = load i8, ptr %8, align 1
  %41 = icmp ne i8 %40, 0
  %42 = xor i1 %41, true
  br i1 %42, label %43, label %44

43:                                               ; preds = %38
  br label %29, !llvm.loop !5

44:                                               ; preds = %38
  br label %45

45:                                               ; preds = %44
  %46 = load i32, ptr %2, align 4
  %47 = add nsw i32 %46, 1
  store i32 %47, ptr %2, align 4
  br label %14, !llvm.loop !7

48:                                               ; preds = %14
  store i32 -1, ptr %10, align 4
  %49 = load i32, ptr %10, align 4
  %50 = atomicrmw xchg ptr @shared, i32 %49 seq_cst, align 4
  store i32 %50, ptr %11, align 4
  %51 = load i32, ptr %11, align 4
  store i32 %51, ptr %9, align 4
  %52 = call align 4 ptr @llvm.threadlocal.address.p0(ptr align 4 @tls_counter)
  %53 = load i32, ptr %52, align 4
  %54 = load i32, ptr %9, align 4
  %55 = load atomic i32, ptr @shared seq_cst, align 4
  store i32 %55, ptr %12, align 4
  %56 = load i32, ptr %12, align 4
  %57 = load atomic i64, ptr @big seq_cst, align 8
  store i64 %57, ptr %13, align 8
  %58 = load i64, ptr %13, align 8
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %53, i32 noundef %54, i32 noundef %56, i64 noundef %58)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare nonnull ptr @llvm.threadlocal.address.p0(ptr nonnull) #1

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
!7 = distinct !{!7, !6}
