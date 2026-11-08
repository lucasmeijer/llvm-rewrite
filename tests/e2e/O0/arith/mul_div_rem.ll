; @source: tests/e2e/src/arith/mul_div_rem.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/mul_div_rem.c'
source_filename = "tests/e2e/src/arith/mul_div_rem.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.xs = private unnamed_addr constant [6 x i32] [i32 17, i32 -17, i32 1000003, i32 -5, i32 0, i32 2147483647], align 16
@__const.main.ds = private unnamed_addr constant [6 x i32] [i32 3, i32 -3, i32 7, i32 1, i32 -1, i32 100], align 16
@.str = private unnamed_addr constant [19 x i8] c"%d %d: %lld %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"%u %u %u\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [6 x i32], align 16
  %3 = alloca [6 x i32], align 16
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.xs, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %3, ptr align 16 @__const.main.ds, i64 24, i1 false)
  store i32 0, ptr %4, align 4
  br label %9

9:                                                ; preds = %51, %0
  %10 = load i32, ptr %4, align 4
  %11 = icmp slt i32 %10, 6
  br i1 %11, label %12, label %54

12:                                               ; preds = %9
  store i32 0, ptr %5, align 4
  br label %13

13:                                               ; preds = %47, %12
  %14 = load i32, ptr %5, align 4
  %15 = icmp slt i32 %14, 6
  br i1 %15, label %16, label %50

16:                                               ; preds = %13
  %17 = load i32, ptr %4, align 4
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [6 x i32], ptr %2, i64 0, i64 %18
  %20 = load i32, ptr %19, align 4
  store i32 %20, ptr %6, align 4
  %21 = load i32, ptr %5, align 4
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [6 x i32], ptr %3, i64 0, i64 %22
  %24 = load i32, ptr %23, align 4
  store i32 %24, ptr %7, align 4
  %25 = load i32, ptr %6, align 4
  %26 = icmp eq i32 %25, -2147483648
  br i1 %26, label %27, label %31

27:                                               ; preds = %16
  %28 = load i32, ptr %7, align 4
  %29 = icmp eq i32 %28, -1
  br i1 %29, label %30, label %31

30:                                               ; preds = %27
  br label %47

31:                                               ; preds = %27, %16
  %32 = load i32, ptr %6, align 4
  %33 = load i32, ptr %7, align 4
  %34 = load i32, ptr %6, align 4
  %35 = sext i32 %34 to i64
  %36 = load i32, ptr %7, align 4
  %37 = sext i32 %36 to i64
  %38 = mul nsw i64 %35, %37
  %39 = sdiv i64 %38, 3
  %40 = load i32, ptr %6, align 4
  %41 = load i32, ptr %7, align 4
  %42 = sdiv i32 %40, %41
  %43 = load i32, ptr %6, align 4
  %44 = load i32, ptr %7, align 4
  %45 = srem i32 %43, %44
  %46 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %32, i32 noundef %33, i64 noundef %39, i32 noundef %42, i32 noundef %45)
  br label %47

47:                                               ; preds = %31, %30
  %48 = load i32, ptr %5, align 4
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %5, align 4
  br label %13, !llvm.loop !5

50:                                               ; preds = %13
  br label %51

51:                                               ; preds = %50
  %52 = load i32, ptr %4, align 4
  %53 = add nsw i32 %52, 1
  store i32 %53, ptr %4, align 4
  br label %9, !llvm.loop !7

54:                                               ; preds = %9
  store i32 -294967296, ptr %8, align 4
  %55 = load i32, ptr %8, align 4
  %56 = udiv i32 %55, 7
  %57 = load i32, ptr %8, align 4
  %58 = urem i32 %57, 7
  %59 = load i32, ptr %8, align 4
  %60 = mul i32 %59, 3
  %61 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %56, i32 noundef %58, i32 noundef %60)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
