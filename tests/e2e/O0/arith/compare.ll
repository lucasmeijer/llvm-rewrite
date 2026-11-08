; @source: tests/e2e/src/arith/compare.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/compare.c'
source_filename = "tests/e2e/src/arith/compare.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.vals = private unnamed_addr constant [6 x i32] [i32 -3, i32 -1, i32 0, i32 1, i32 2, i32 2147483647], align 16
@.str = private unnamed_addr constant [23 x i8] c"%d%d%d%d%d%d %d%d%d%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [6 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.vals, i64 24, i1 false)
  store i32 0, ptr %3, align 4
  br label %9

9:                                                ; preds = %72, %0
  %10 = load i32, ptr %3, align 4
  %11 = icmp slt i32 %10, 6
  br i1 %11, label %12, label %75

12:                                               ; preds = %9
  store i32 0, ptr %4, align 4
  br label %13

13:                                               ; preds = %68, %12
  %14 = load i32, ptr %4, align 4
  %15 = icmp slt i32 %14, 6
  br i1 %15, label %16, label %71

16:                                               ; preds = %13
  %17 = load i32, ptr %3, align 4
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [6 x i32], ptr %2, i64 0, i64 %18
  %20 = load i32, ptr %19, align 4
  store i32 %20, ptr %5, align 4
  %21 = load i32, ptr %4, align 4
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [6 x i32], ptr %2, i64 0, i64 %22
  %24 = load i32, ptr %23, align 4
  store i32 %24, ptr %6, align 4
  %25 = load i32, ptr %5, align 4
  store i32 %25, ptr %7, align 4
  %26 = load i32, ptr %6, align 4
  store i32 %26, ptr %8, align 4
  %27 = load i32, ptr %5, align 4
  %28 = load i32, ptr %6, align 4
  %29 = icmp slt i32 %27, %28
  %30 = zext i1 %29 to i32
  %31 = load i32, ptr %5, align 4
  %32 = load i32, ptr %6, align 4
  %33 = icmp sle i32 %31, %32
  %34 = zext i1 %33 to i32
  %35 = load i32, ptr %5, align 4
  %36 = load i32, ptr %6, align 4
  %37 = icmp sgt i32 %35, %36
  %38 = zext i1 %37 to i32
  %39 = load i32, ptr %5, align 4
  %40 = load i32, ptr %6, align 4
  %41 = icmp sge i32 %39, %40
  %42 = zext i1 %41 to i32
  %43 = load i32, ptr %5, align 4
  %44 = load i32, ptr %6, align 4
  %45 = icmp eq i32 %43, %44
  %46 = zext i1 %45 to i32
  %47 = load i32, ptr %5, align 4
  %48 = load i32, ptr %6, align 4
  %49 = icmp ne i32 %47, %48
  %50 = zext i1 %49 to i32
  %51 = load i32, ptr %7, align 4
  %52 = load i32, ptr %8, align 4
  %53 = icmp ult i32 %51, %52
  %54 = zext i1 %53 to i32
  %55 = load i32, ptr %7, align 4
  %56 = load i32, ptr %8, align 4
  %57 = icmp ule i32 %55, %56
  %58 = zext i1 %57 to i32
  %59 = load i32, ptr %7, align 4
  %60 = load i32, ptr %8, align 4
  %61 = icmp ugt i32 %59, %60
  %62 = zext i1 %61 to i32
  %63 = load i32, ptr %7, align 4
  %64 = load i32, ptr %8, align 4
  %65 = icmp uge i32 %63, %64
  %66 = zext i1 %65 to i32
  %67 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %30, i32 noundef %34, i32 noundef %38, i32 noundef %42, i32 noundef %46, i32 noundef %50, i32 noundef %54, i32 noundef %58, i32 noundef %62, i32 noundef %66)
  br label %68

68:                                               ; preds = %16
  %69 = load i32, ptr %4, align 4
  %70 = add nsw i32 %69, 1
  store i32 %70, ptr %4, align 4
  br label %13, !llvm.loop !5

71:                                               ; preds = %13
  br label %72

72:                                               ; preds = %71
  %73 = load i32, ptr %3, align 4
  %74 = add nsw i32 %73, 1
  store i32 %74, ptr %3, align 4
  br label %9, !llvm.loop !7

75:                                               ; preds = %9
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
