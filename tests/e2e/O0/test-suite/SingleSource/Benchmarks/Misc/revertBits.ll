; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/revertBits.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"0x12345678\00", align 1
@.str.1 = private unnamed_addr constant [19 x i8] c"0x0123456789012345\00", align 1
@.str.2 = private unnamed_addr constant [14 x i8] c"0x%x -> 0x%x\0A\00", align 1
@.str.3 = private unnamed_addr constant [18 x i8] c"0x%llx -> 0x%llx\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @ReverseBits32(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = lshr i32 %3, 1
  %5 = and i32 %4, 1431655765
  %6 = load i32, ptr %2, align 4
  %7 = and i32 %6, 1431655765
  %8 = shl i32 %7, 1
  %9 = or i32 %5, %8
  store i32 %9, ptr %2, align 4
  %10 = load i32, ptr %2, align 4
  %11 = lshr i32 %10, 2
  %12 = and i32 %11, 858993459
  %13 = load i32, ptr %2, align 4
  %14 = and i32 %13, 858993459
  %15 = shl i32 %14, 2
  %16 = or i32 %12, %15
  store i32 %16, ptr %2, align 4
  %17 = load i32, ptr %2, align 4
  %18 = lshr i32 %17, 4
  %19 = and i32 %18, 252645135
  %20 = load i32, ptr %2, align 4
  %21 = and i32 %20, 252645135
  %22 = shl i32 %21, 4
  %23 = or i32 %19, %22
  store i32 %23, ptr %2, align 4
  %24 = load i32, ptr %2, align 4
  %25 = and i32 %24, -16777216
  %26 = lshr i32 %25, 24
  %27 = load i32, ptr %2, align 4
  %28 = and i32 %27, 16711680
  %29 = lshr i32 %28, 8
  %30 = or i32 %26, %29
  %31 = load i32, ptr %2, align 4
  %32 = and i32 %31, 65280
  %33 = shl i32 %32, 8
  %34 = or i32 %30, %33
  %35 = load i32, ptr %2, align 4
  %36 = and i32 %35, 255
  %37 = shl i32 %36, 24
  %38 = or i32 %34, %37
  ret i32 %38
}

; Function Attrs: noinline nounwind uwtable
define dso_local i64 @ReverseBits64(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = lshr i64 %3, 1
  %5 = and i64 %4, 6148914691236517205
  %6 = load i64, ptr %2, align 8
  %7 = and i64 %6, 6148914691236517205
  %8 = shl i64 %7, 1
  %9 = or i64 %5, %8
  store i64 %9, ptr %2, align 8
  %10 = load i64, ptr %2, align 8
  %11 = lshr i64 %10, 2
  %12 = and i64 %11, 3689348814741910323
  %13 = load i64, ptr %2, align 8
  %14 = and i64 %13, 3689348814741910323
  %15 = shl i64 %14, 2
  %16 = or i64 %12, %15
  store i64 %16, ptr %2, align 8
  %17 = load i64, ptr %2, align 8
  %18 = lshr i64 %17, 4
  %19 = and i64 %18, 1085102592571150095
  %20 = load i64, ptr %2, align 8
  %21 = and i64 %20, 1085102592571150095
  %22 = shl i64 %21, 4
  %23 = or i64 %19, %22
  store i64 %23, ptr %2, align 8
  %24 = load i64, ptr %2, align 8
  %25 = and i64 %24, -72057594037927936
  %26 = lshr i64 %25, 56
  %27 = load i64, ptr %2, align 8
  %28 = and i64 %27, 71776119061217280
  %29 = lshr i64 %28, 40
  %30 = or i64 %26, %29
  %31 = load i64, ptr %2, align 8
  %32 = and i64 %31, 280375465082880
  %33 = lshr i64 %32, 24
  %34 = or i64 %30, %33
  %35 = load i64, ptr %2, align 8
  %36 = and i64 %35, 1095216660480
  %37 = lshr i64 %36, 8
  %38 = or i64 %34, %37
  %39 = load i64, ptr %2, align 8
  %40 = and i64 %39, 255
  %41 = shl i64 %40, 56
  %42 = or i64 %38, %41
  %43 = load i64, ptr %2, align 8
  %44 = and i64 %43, 65280
  %45 = shl i64 %44, 40
  %46 = or i64 %42, %45
  %47 = load i64, ptr %2, align 8
  %48 = and i64 %47, 16711680
  %49 = shl i64 %48, 24
  %50 = or i64 %46, %49
  %51 = load i64, ptr %2, align 8
  %52 = and i64 %51, 4278190080
  %53 = shl i64 %52, 8
  %54 = or i64 %50, %53
  ret i64 %54
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i64, align 8
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i64 0, ptr %2, align 8
  store i64 0, ptr %3, align 8
  %8 = call i64 @strtoll(ptr noundef @.str, ptr noundef null, i32 noundef 16) #4
  %9 = trunc i64 %8 to i32
  store i32 %9, ptr %4, align 4
  %10 = call i64 @strtoll(ptr noundef @.str.1, ptr noundef null, i32 noundef 16) #4
  store i64 %10, ptr %5, align 8
  store i32 0, ptr %6, align 4
  br label %11

11:                                               ; preds = %25, %0
  %12 = load i32, ptr %6, align 4
  %13 = icmp slt i32 %12, 16777216
  br i1 %13, label %14, label %28

14:                                               ; preds = %11
  %15 = load i32, ptr %6, align 4
  %16 = call i32 @ReverseBits32(i32 noundef %15)
  %17 = zext i32 %16 to i64
  %18 = load i64, ptr %2, align 8
  %19 = add i64 %18, %17
  store i64 %19, ptr %2, align 8
  %20 = load i32, ptr %6, align 4
  %21 = sext i32 %20 to i64
  %22 = call i64 @ReverseBits64(i64 noundef %21)
  %23 = load i64, ptr %3, align 8
  %24 = add i64 %23, %22
  store i64 %24, ptr %3, align 8
  br label %25

25:                                               ; preds = %14
  %26 = load i32, ptr %6, align 4
  %27 = add nsw i32 %26, 1
  store i32 %27, ptr %6, align 4
  br label %11, !llvm.loop !5

28:                                               ; preds = %11
  store i32 0, ptr %7, align 4
  br label %29

29:                                               ; preds = %43, %28
  %30 = load i32, ptr %7, align 4
  %31 = icmp slt i32 %30, 16777216
  br i1 %31, label %32, label %46

32:                                               ; preds = %29
  %33 = load i32, ptr %7, align 4
  %34 = call i32 @llvm.bitreverse.i32(i32 %33)
  %35 = zext i32 %34 to i64
  %36 = load i64, ptr %2, align 8
  %37 = sub i64 %36, %35
  store i64 %37, ptr %2, align 8
  %38 = load i32, ptr %7, align 4
  %39 = sext i32 %38 to i64
  %40 = call i64 @llvm.bitreverse.i64(i64 %39)
  %41 = load i64, ptr %3, align 8
  %42 = sub i64 %41, %40
  store i64 %42, ptr %3, align 8
  br label %43

43:                                               ; preds = %32
  %44 = load i32, ptr %7, align 4
  %45 = add nsw i32 %44, 1
  store i32 %45, ptr %7, align 4
  br label %29, !llvm.loop !7

46:                                               ; preds = %29
  %47 = load i32, ptr %4, align 4
  %48 = load i32, ptr %4, align 4
  %49 = call i32 @llvm.bitreverse.i32(i32 %48)
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %47, i32 noundef %49)
  %51 = load i64, ptr %5, align 8
  %52 = load i64, ptr %5, align 8
  %53 = call i64 @llvm.bitreverse.i64(i64 %52)
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %51, i64 noundef %53)
  %55 = load i64, ptr %2, align 8
  %56 = icmp eq i64 %55, 0
  br i1 %56, label %57, label %60

57:                                               ; preds = %46
  %58 = load i64, ptr %3, align 8
  %59 = icmp eq i64 %58, 0
  br label %60

60:                                               ; preds = %57, %46
  %61 = phi i1 [ false, %46 ], [ %59, %57 ]
  %62 = zext i1 %61 to i64
  %63 = select i1 %61, i32 0, i32 1
  ret i32 %63
}

; Function Attrs: nounwind
declare i64 @strtoll(ptr noundef, ptr noundef, i32 noundef) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.bitreverse.i32(i32) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.bitreverse.i64(i64) #2

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }

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
