; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-31-CastToBool.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-31-CastToBool.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-31-CastToBool.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [34 x i8] c"y = %d, (y == 2 || y == 0) == %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [32 x i8] c"y = %d, (y > 2 || y < 5) == %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [28 x i8] c"y = %d, (y ^ 2 ^ ~y) == %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@.str.5 = private unnamed_addr constant [6 x i8] c"%lld \00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @testCastOps(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = load i32, ptr %2, align 4
  %5 = icmp eq i32 %4, 2
  br i1 %5, label %9, label %6

6:                                                ; preds = %1
  %7 = load i32, ptr %2, align 4
  %8 = icmp eq i32 %7, 0
  br label %9

9:                                                ; preds = %6, %1
  %10 = phi i1 [ true, %1 ], [ %8, %6 ]
  %11 = zext i1 %10 to i32
  %12 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %3, i32 noundef %11)
  %13 = load i32, ptr %2, align 4
  %14 = load i32, ptr %2, align 4
  %15 = icmp slt i32 %14, 2
  br i1 %15, label %16, label %19

16:                                               ; preds = %9
  %17 = load i32, ptr %2, align 4
  %18 = icmp sgt i32 %17, -10
  br label %19

19:                                               ; preds = %16, %9
  %20 = phi i1 [ false, %9 ], [ %18, %16 ]
  %21 = zext i1 %20 to i32
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %13, i32 noundef %21)
  %23 = load i32, ptr %2, align 4
  %24 = load i32, ptr %2, align 4
  %25 = xor i32 %24, 2
  %26 = xor i32 %25, -6
  %27 = icmp ne i32 %26, 0
  %28 = zext i1 %27 to i32
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %23, i32 noundef %28)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @testBool(i1 noundef zeroext %0) #0 {
  %2 = alloca i8, align 1
  %3 = zext i1 %0 to i8
  store i8 %3, ptr %2, align 1
  %4 = load i8, ptr %2, align 1
  %5 = icmp ne i8 %4, 0
  %6 = zext i1 %5 to i32
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %6)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @testByte(i8 noundef signext %0) #0 {
  %2 = alloca i8, align 1
  store i8 %0, ptr %2, align 1
  %3 = load i8, ptr %2, align 1
  %4 = sext i8 %3 to i32
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %4)
  %6 = load i8, ptr %2, align 1
  %7 = sext i8 %6 to i32
  %8 = icmp ne i32 %7, 0
  call void @testBool(i1 noundef zeroext %8)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @testShort(i16 noundef signext %0) #0 {
  %2 = alloca i16, align 2
  store i16 %0, ptr %2, align 2
  %3 = load i16, ptr %2, align 2
  %4 = sext i16 %3 to i32
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %4)
  %6 = load i16, ptr %2, align 2
  %7 = sext i16 %6 to i32
  %8 = icmp ne i32 %7, 0
  call void @testBool(i1 noundef zeroext %8)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @testInt(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %3 = load i32, ptr %2, align 4
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %3)
  %5 = load i32, ptr %2, align 4
  %6 = icmp ne i32 %5, 0
  call void @testBool(i1 noundef zeroext %6)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @testLong(i64 noundef %0) #0 {
  %2 = alloca i64, align 8
  store i64 %0, ptr %2, align 8
  %3 = load i64, ptr %2, align 8
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i64 noundef %3)
  %5 = load i64, ptr %2, align 8
  %6 = icmp ne i64 %5, 0
  call void @testBool(i1 noundef zeroext %6)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @testByte(i8 noundef signext 0)
  call void @testByte(i8 noundef signext 123)
  call void @testShort(i16 noundef signext 0)
  call void @testShort(i16 noundef signext 1234)
  call void @testInt(i32 noundef 0)
  call void @testInt(i32 noundef 1234)
  call void @testLong(i64 noundef 0)
  call void @testLong(i64 noundef 123121231231231)
  call void @testLong(i64 noundef 1230098424783699968)
  call void @testLong(i64 noundef 69920)
  call void @testCastOps(i32 noundef 2)
  ret i32 0
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
