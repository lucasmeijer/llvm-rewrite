; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2005-05-11-Popcount-ffs-fls.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@nlz10b.table = internal global [64 x i8] c" \14\13cc\12c\07\0A\11cc\0Ec\06cc\09c\10cc\01\1Ac\0Dcc\18\05ccc\15c\08\0Bc\0Fcccc\02\1B\00\19c\16c\0Ccc\03\1Cc\17c\04\1Dcc\1E\1F", align 16
@ntz8.table = internal global [64 x i8] c" \00\01\0C\02\06c\0D\03c\07cccc\0E\0A\04cc\08cc\19ccccc\15\1B\0F\1F\0B\05ccccc\09cc\18cc\14\1A\1Ecccc\17c\13\1Dc\16\12\1C\11\10c", align 16
@i = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [54 x i8] c"LLVM: n: %d, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [54 x i8] c"REF : n: %d, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [9 x i8] c"  ***  \0A\00", align 1
@.str.3 = private unnamed_addr constant [56 x i8] c"LLVM: n: %lld, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.4 = private unnamed_addr constant [64 x i8] c"REF LO BITS : n: %lld, clz(n): %d, popcount(n): %d, ctz(n): %d\0A\00", align 1
@.str.5 = private unnamed_addr constant [58 x i8] c"FFS: 0:%d, 1:%d, 2:%d, 7:%d, 1024:%d, 1234:%d i:%d, l:%d\0A\00", align 1
@.str.6 = private unnamed_addr constant [67 x i8] c"__builtin_ffs: 0:%d, 1:%d, 2:%d, 7:%d, 1024:%d, 1234:%d i:%d l:%d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @nlz10b(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = load i32, ptr %2, align 4
  %5 = lshr i32 %4, 1
  %6 = or i32 %3, %5
  store i32 %6, ptr %2, align 4
  %7 = load i32, ptr %2, align 4
  %8 = load i32, ptr %2, align 4
  %9 = lshr i32 %8, 2
  %10 = or i32 %7, %9
  store i32 %10, ptr %2, align 4
  %11 = load i32, ptr %2, align 4
  %12 = load i32, ptr %2, align 4
  %13 = lshr i32 %12, 4
  %14 = or i32 %11, %13
  store i32 %14, ptr %2, align 4
  %15 = load i32, ptr %2, align 4
  %16 = load i32, ptr %2, align 4
  %17 = lshr i32 %16, 8
  %18 = or i32 %15, %17
  store i32 %18, ptr %2, align 4
  %19 = load i32, ptr %2, align 4
  %20 = load i32, ptr %2, align 4
  %21 = lshr i32 %20, 16
  %22 = xor i32 %21, -1
  %23 = and i32 %19, %22
  store i32 %23, ptr %2, align 4
  %24 = load i32, ptr %2, align 4
  %25 = shl i32 %24, 9
  %26 = load i32, ptr %2, align 4
  %27 = sub i32 %25, %26
  store i32 %27, ptr %2, align 4
  %28 = load i32, ptr %2, align 4
  %29 = shl i32 %28, 11
  %30 = load i32, ptr %2, align 4
  %31 = sub i32 %29, %30
  store i32 %31, ptr %2, align 4
  %32 = load i32, ptr %2, align 4
  %33 = shl i32 %32, 14
  %34 = load i32, ptr %2, align 4
  %35 = sub i32 %33, %34
  store i32 %35, ptr %2, align 4
  %36 = load i32, ptr %2, align 4
  %37 = lshr i32 %36, 26
  %38 = zext i32 %37 to i64
  %39 = getelementptr inbounds nuw [64 x i8], ptr @nlz10b.table, i64 0, i64 %38
  %40 = load i8, ptr %39, align 1
  %41 = sext i8 %40 to i32
  ret i32 %41
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @nlzll(i64 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i64, align 8
  store i64 %0, ptr %3, align 8
  %4 = load i64, ptr %3, align 8
  %5 = lshr i64 %4, 32
  %6 = icmp eq i64 %5, 0
  br i1 %6, label %7, label %12

7:                                                ; preds = %1
  %8 = load i64, ptr %3, align 8
  %9 = trunc i64 %8 to i32
  %10 = call i32 @nlz10b(i32 noundef %9)
  %11 = add nsw i32 %10, 32
  store i32 %11, ptr %2, align 4
  br label %17

12:                                               ; preds = %1
  %13 = load i64, ptr %3, align 8
  %14 = lshr i64 %13, 32
  %15 = trunc i64 %14 to i32
  %16 = call i32 @nlz10b(i32 noundef %15)
  store i32 %16, ptr %2, align 4
  br label %17

17:                                               ; preds = %12, %7
  %18 = load i32, ptr %2, align 4
  ret i32 %18
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @pop(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = load i32, ptr %2, align 4
  %5 = lshr i32 %4, 1
  %6 = and i32 %5, 1431655765
  %7 = sub i32 %3, %6
  store i32 %7, ptr %2, align 4
  %8 = load i32, ptr %2, align 4
  %9 = and i32 %8, 858993459
  %10 = load i32, ptr %2, align 4
  %11 = lshr i32 %10, 2
  %12 = and i32 %11, 858993459
  %13 = add i32 %9, %12
  store i32 %13, ptr %2, align 4
  %14 = load i32, ptr %2, align 4
  %15 = load i32, ptr %2, align 4
  %16 = lshr i32 %15, 4
  %17 = add i32 %14, %16
  %18 = and i32 %17, 252645135
  store i32 %18, ptr %2, align 4
  %19 = load i32, ptr %2, align 4
  %20 = load i32, ptr %2, align 4
  %21 = shl i32 %20, 8
  %22 = add i32 %19, %21
  store i32 %22, ptr %2, align 4
  %23 = load i32, ptr %2, align 4
  %24 = load i32, ptr %2, align 4
  %25 = shl i32 %24, 16
  %26 = add i32 %23, %25
  store i32 %26, ptr %2, align 4
  %27 = load i32, ptr %2, align 4
  %28 = lshr i32 %27, 24
  ret i32 %28
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @popll(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = trunc i64 %3 to i32
  %5 = call i32 @pop(i32 noundef %4)
  %6 = load i64, ptr %2, align 8
  %7 = lshr i64 %6, 32
  %8 = trunc i64 %7 to i32
  %9 = call i32 @pop(i32 noundef %8)
  %10 = add nsw i32 %5, %9
  ret i32 %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @ntz8(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = load i32, ptr %2, align 4
  %5 = sub i32 0, %4
  %6 = and i32 %3, %5
  %7 = mul i32 %6, 72416175
  store i32 %7, ptr %2, align 4
  %8 = load i32, ptr %2, align 4
  %9 = lshr i32 %8, 26
  %10 = zext i32 %9 to i64
  %11 = getelementptr inbounds nuw [64 x i8], ptr @ntz8.table, i64 0, i64 %10
  %12 = load i8, ptr %11, align 1
  %13 = sext i8 %12 to i32
  ret i32 %13
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  store i32 0, ptr %1, align 4
  store i32 10, ptr @i, align 4
  br label %3

3:                                                ; preds = %26, %0
  %4 = load i32, ptr @i, align 4
  %5 = icmp slt i32 %4, 139045193
  br i1 %5, label %6, label %29

6:                                                ; preds = %3
  %7 = load i32, ptr @i, align 4
  %8 = load i32, ptr @i, align 4
  %9 = call i32 @llvm.ctlz.i32(i32 %8, i1 true)
  %10 = load i32, ptr @i, align 4
  %11 = call i32 @llvm.ctpop.i32(i32 %10)
  %12 = load i32, ptr @i, align 4
  %13 = call i32 @llvm.cttz.i32(i32 %12, i1 true)
  %14 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %7, i32 noundef %9, i32 noundef %11, i32 noundef %13)
  %15 = load i32, ptr @i, align 4
  %16 = load i32, ptr @i, align 4
  %17 = call i32 @nlz10b(i32 noundef %16)
  %18 = load i32, ptr @i, align 4
  %19 = call i32 @pop(i32 noundef %18)
  %20 = load i32, ptr @i, align 4
  %21 = call i32 @ntz8(i32 noundef %20)
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %15, i32 noundef %17, i32 noundef %19, i32 noundef %21)
  %23 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %24 = load i32, ptr @i, align 4
  %25 = add nsw i32 %24, 1
  store i32 %25, ptr @i, align 4
  br label %26

26:                                               ; preds = %6
  %27 = load i32, ptr @i, align 4
  %28 = mul nsw i32 %27, -3
  store i32 %28, ptr @i, align 4
  br label %3, !llvm.loop !5

29:                                               ; preds = %3
  store i64 -10000, ptr %2, align 8
  br label %30

30:                                               ; preds = %57, %29
  %31 = load i64, ptr %2, align 8
  %32 = icmp slt i64 %31, 1390451930000
  br i1 %32, label %33, label %60

33:                                               ; preds = %30
  %34 = load i64, ptr %2, align 8
  %35 = load i64, ptr %2, align 8
  %36 = call i64 @llvm.ctlz.i64(i64 %35, i1 true)
  %37 = trunc i64 %36 to i32
  %38 = load i64, ptr %2, align 8
  %39 = call i64 @llvm.ctpop.i64(i64 %38)
  %40 = trunc i64 %39 to i32
  %41 = load i64, ptr %2, align 8
  %42 = trunc i64 %41 to i32
  %43 = call i32 @llvm.cttz.i32(i32 %42, i1 true)
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %34, i32 noundef %37, i32 noundef %40, i32 noundef %43)
  %45 = load i64, ptr %2, align 8
  %46 = load i64, ptr %2, align 8
  %47 = call i32 @nlzll(i64 noundef %46)
  %48 = load i64, ptr %2, align 8
  %49 = call i32 @popll(i64 noundef %48)
  %50 = load i64, ptr %2, align 8
  %51 = trunc i64 %50 to i32
  %52 = call i32 @ntz8(i32 noundef %51)
  %53 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i64 noundef %45, i32 noundef %47, i32 noundef %49, i32 noundef %52)
  %54 = call i32 (ptr, ...) @printf(ptr noundef @.str.2)
  %55 = load i64, ptr %2, align 8
  %56 = add nsw i64 %55, 1
  store i64 %56, ptr %2, align 8
  br label %57

57:                                               ; preds = %33
  %58 = load i64, ptr %2, align 8
  %59 = mul nsw i64 %58, -3
  store i64 %59, ptr %2, align 8
  br label %30, !llvm.loop !7

60:                                               ; preds = %30
  %61 = call i32 @ffs(i32 noundef 0) #5
  %62 = call i32 @ffs(i32 noundef 1) #5
  %63 = call i32 @ffs(i32 noundef 2) #5
  %64 = call i32 @ffs(i32 noundef 7) #5
  %65 = call i32 @ffs(i32 noundef 1024) #5
  %66 = call i32 @ffs(i32 noundef 1234) #5
  %67 = load i32, ptr @i, align 4
  %68 = call i32 @ffs(i32 noundef %67) #5
  %69 = load i64, ptr %2, align 8
  %70 = call i32 @ffsl(i64 noundef %69) #5
  %71 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %61, i32 noundef %62, i32 noundef %63, i32 noundef %64, i32 noundef %65, i32 noundef %66, i32 noundef %68, i32 noundef %70)
  %72 = load i32, ptr @i, align 4
  %73 = call i32 @llvm.cttz.i32(i32 %72, i1 true)
  %74 = add i32 %73, 1
  %75 = icmp eq i32 %72, 0
  %76 = select i1 %75, i32 0, i32 %74
  %77 = load i64, ptr %2, align 8
  %78 = call i64 @llvm.cttz.i64(i64 %77, i1 true)
  %79 = add i64 %78, 1
  %80 = icmp eq i64 %77, 0
  %81 = select i1 %80, i64 0, i64 %79
  %82 = trunc i64 %81 to i32
  %83 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef 0, i32 noundef 1, i32 noundef 2, i32 noundef 1, i32 noundef 11, i32 noundef 2, i32 noundef %76, i32 noundef %82)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctlz.i32(i32, i1 immarg) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.ctpop.i32(i32) #3

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.cttz.i32(i32, i1 immarg) #2

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctlz.i64(i64, i1 immarg) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.ctpop.i64(i64) #3

; Function Attrs: nounwind willreturn memory(none)
declare i32 @ffs(i32 noundef) #4

; Function Attrs: nounwind willreturn memory(none)
declare i32 @ffsl(i64 noundef) #4

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i64 @llvm.cttz.i64(i64, i1 immarg) #2

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind willreturn memory(none) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind willreturn memory(none) }

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
