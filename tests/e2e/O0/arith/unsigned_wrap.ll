; @source: tests/e2e/src/arith/unsigned_wrap.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/unsigned_wrap.c'
source_filename = "tests/e2e/src/arith/unsigned_wrap.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [12 x i8] c"%u %llu %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [4 x i8] c"%u\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i64, align 8
  %4 = alloca i8, align 1
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %2, align 4
  %7 = load i32, ptr %2, align 4
  %8 = sub i32 %7, 1
  store i32 %8, ptr %2, align 4
  store i64 -1, ptr %3, align 8
  %9 = load i64, ptr %3, align 8
  %10 = add i64 %9, 2
  store i64 %10, ptr %3, align 8
  store i8 -6, ptr %4, align 1
  %11 = load i8, ptr %4, align 1
  %12 = zext i8 %11 to i32
  %13 = add nsw i32 %12, 10
  %14 = trunc i32 %13 to i8
  store i8 %14, ptr %4, align 1
  %15 = load i32, ptr %2, align 4
  %16 = load i64, ptr %3, align 8
  %17 = load i8, ptr %4, align 1
  %18 = zext i8 %17 to i32
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %15, i64 noundef %16, i32 noundef %18)
  store i32 -2128831035, ptr %5, align 4
  store i32 0, ptr %6, align 4
  br label %20

20:                                               ; preds = %28, %0
  %21 = load i32, ptr %6, align 4
  %22 = icmp slt i32 %21, 100
  br i1 %22, label %23, label %31

23:                                               ; preds = %20
  %24 = load i32, ptr %5, align 4
  %25 = load i32, ptr %6, align 4
  %26 = xor i32 %24, %25
  %27 = mul i32 %26, 16777619
  store i32 %27, ptr %5, align 4
  br label %28

28:                                               ; preds = %23
  %29 = load i32, ptr %6, align 4
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %6, align 4
  br label %20, !llvm.loop !5

31:                                               ; preds = %20
  %32 = load i32, ptr %5, align 4
  %33 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %32)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
