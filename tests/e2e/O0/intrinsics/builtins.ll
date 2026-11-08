; @source: tests/e2e/src/intrinsics/builtins.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/intrinsics/builtins.c'
source_filename = "tests/e2e/src/intrinsics/builtins.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.vals = private unnamed_addr constant [5 x i32] [i32 1, i32 -2147483648, i32 -252645136, i32 12345, i32 -1], align 16
@.str = private unnamed_addr constant [18 x i8] c"%d %d %d %08x %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"%d %d %016llx\0A\00", align 1
@.str.2 = private unnamed_addr constant [14 x i8] c"%d %d %d %ld\0A\00", align 1
@.str.3 = private unnamed_addr constant [10 x i8] c"%d %d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [5 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i64, align 8
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.vals, i64 20, i1 false)
  store i32 0, ptr %3, align 4
  br label %11

11:                                               ; preds = %31, %0
  %12 = load i32, ptr %3, align 4
  %13 = icmp slt i32 %12, 5
  br i1 %13, label %14, label %34

14:                                               ; preds = %11
  %15 = load i32, ptr %3, align 4
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds [5 x i32], ptr %2, i64 0, i64 %16
  %18 = load i32, ptr %17, align 4
  store i32 %18, ptr %4, align 4
  %19 = load i32, ptr %4, align 4
  %20 = call i32 @llvm.ctpop.i32(i32 %19)
  %21 = load i32, ptr %4, align 4
  %22 = call i32 @llvm.ctlz.i32(i32 %21, i1 true)
  %23 = load i32, ptr %4, align 4
  %24 = call i32 @llvm.cttz.i32(i32 %23, i1 true)
  %25 = load i32, ptr %4, align 4
  %26 = call i32 @llvm.bswap.i32(i32 %25)
  %27 = load i32, ptr %4, align 4
  %28 = call i32 @llvm.ctpop.i32(i32 %27)
  %29 = and i32 %28, 1
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %20, i32 noundef %22, i32 noundef %24, i32 noundef %26, i32 noundef %29)
  br label %31

31:                                               ; preds = %14
  %32 = load i32, ptr %3, align 4
  %33 = add nsw i32 %32, 1
  store i32 %33, ptr %3, align 4
  br label %11, !llvm.loop !5

34:                                               ; preds = %11
  store i64 81985529216486895, ptr %5, align 8
  %35 = load i64, ptr %5, align 8
  %36 = call i64 @llvm.ctpop.i64(i64 %35)
  %37 = trunc i64 %36 to i32
  %38 = load i64, ptr %5, align 8
  %39 = call i64 @llvm.ctlz.i64(i64 %38, i1 true)
  %40 = trunc i64 %39 to i32
  %41 = load i64, ptr %5, align 8
  %42 = call i64 @llvm.bswap.i64(i64 %41)
  %43 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %37, i32 noundef %40, i64 noundef %42)
  %44 = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 2147483600, i32 100)
  %45 = extractvalue { i32, i1 } %44, 1
  %46 = extractvalue { i32, i1 } %44, 0
  store i32 %46, ptr %6, align 4
  %47 = zext i1 %45 to i32
  store i32 %47, ptr %7, align 4
  %48 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 3037000500, i64 3037000500)
  %49 = extractvalue { i64, i1 } %48, 1
  %50 = extractvalue { i64, i1 } %48, 0
  store i64 %50, ptr %8, align 8
  %51 = zext i1 %49 to i32
  store i32 %51, ptr %9, align 4
  %52 = load i32, ptr %7, align 4
  %53 = load i32, ptr %6, align 4
  %54 = load i32, ptr %9, align 4
  %55 = load i64, ptr %8, align 8
  %56 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %52, i32 noundef %53, i32 noundef %54, i64 noundef %55)
  store i32 -17, ptr %10, align 4
  %57 = load i32, ptr %10, align 4
  %58 = call i32 @llvm.abs.i32(i32 %57, i1 true)
  %59 = load i32, ptr %10, align 4
  %60 = sext i32 %59 to i64
  %61 = icmp slt i64 %60, 0
  %62 = zext i1 %61 to i32
  %63 = load i32, ptr %10, align 4
  %64 = icmp slt i32 %63, 0
  br i1 %64, label %65, label %68

65:                                               ; preds = %34
  %66 = load i32, ptr %10, align 4
  %67 = sub nsw i32 0, %66
  br label %70

68:                                               ; preds = %34
  %69 = load i32, ptr %10, align 4
  br label %70

70:                                               ; preds = %68, %65
  %71 = phi i32 [ %67, %65 ], [ %69, %68 ]
  %72 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %58, i32 noundef %62, i32 noundef %71)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctpop.i32(i32) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctlz.i32(i32, i1 immarg) #4

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.cttz.i32(i32, i1 immarg) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.bswap.i32(i32) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctpop.i64(i64) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.bswap.i64(i64) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.abs.i32(i32, i1 immarg) #4

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
