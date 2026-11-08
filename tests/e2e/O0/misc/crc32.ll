; @source: tests/e2e/src/misc/crc32.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/crc32.c'
source_filename = "tests/e2e/src/misc/crc32.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [44 x i8] c"The quick brown fox jumps over the lazy dog\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%08x\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca [256 x i8], align 16
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store ptr @.str, ptr %2, align 8
  %5 = load ptr, ptr %2, align 8
  %6 = load ptr, ptr %2, align 8
  %7 = call i64 @strlen(ptr noundef %6) #3
  %8 = call i32 @crc32(ptr noundef %5, i64 noundef %7)
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %8)
  store i32 0, ptr %4, align 4
  br label %10

10:                                               ; preds = %21, %0
  %11 = load i32, ptr %4, align 4
  %12 = icmp slt i32 %11, 256
  br i1 %12, label %13, label %24

13:                                               ; preds = %10
  %14 = load i32, ptr %4, align 4
  %15 = mul nsw i32 %14, 37
  %16 = add nsw i32 %15, 11
  %17 = trunc i32 %16 to i8
  %18 = load i32, ptr %4, align 4
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 %19
  store i8 %17, ptr %20, align 1
  br label %21

21:                                               ; preds = %13
  %22 = load i32, ptr %4, align 4
  %23 = add nsw i32 %22, 1
  store i32 %23, ptr %4, align 4
  br label %10, !llvm.loop !5

24:                                               ; preds = %10
  %25 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 0
  %26 = call i32 @crc32(ptr noundef %25, i64 noundef 256)
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %26)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal i32 @crc32(ptr noundef %0, i64 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i64, align 8
  %7 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store i64 %1, ptr %4, align 8
  store i32 -1, ptr %5, align 4
  store i64 0, ptr %6, align 8
  br label %8

8:                                                ; preds = %35, %2
  %9 = load i64, ptr %6, align 8
  %10 = load i64, ptr %4, align 8
  %11 = icmp ult i64 %9, %10
  br i1 %11, label %12, label %38

12:                                               ; preds = %8
  %13 = load ptr, ptr %3, align 8
  %14 = load i64, ptr %6, align 8
  %15 = getelementptr inbounds nuw i8, ptr %13, i64 %14
  %16 = load i8, ptr %15, align 1
  %17 = zext i8 %16 to i32
  %18 = load i32, ptr %5, align 4
  %19 = xor i32 %18, %17
  store i32 %19, ptr %5, align 4
  store i32 0, ptr %7, align 4
  br label %20

20:                                               ; preds = %31, %12
  %21 = load i32, ptr %7, align 4
  %22 = icmp slt i32 %21, 8
  br i1 %22, label %23, label %34

23:                                               ; preds = %20
  %24 = load i32, ptr %5, align 4
  %25 = lshr i32 %24, 1
  %26 = load i32, ptr %5, align 4
  %27 = and i32 %26, 1
  %28 = sub i32 0, %27
  %29 = and i32 -306674912, %28
  %30 = xor i32 %25, %29
  store i32 %30, ptr %5, align 4
  br label %31

31:                                               ; preds = %23
  %32 = load i32, ptr %7, align 4
  %33 = add nsw i32 %32, 1
  store i32 %33, ptr %7, align 4
  br label %20, !llvm.loop !7

34:                                               ; preds = %20
  br label %35

35:                                               ; preds = %34
  %36 = load i64, ptr %6, align 8
  %37 = add i64 %36, 1
  store i64 %37, ptr %6, align 8
  br label %8, !llvm.loop !8

38:                                               ; preds = %8
  %39 = load i32, ptr %5, align 4
  %40 = xor i32 %39, -1
  ret i32 %40
}

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) }

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
!8 = distinct !{!8, !6}
