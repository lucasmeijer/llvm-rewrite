; @source: tests/e2e/src/memory/globals.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/globals.c'
source_filename = "tests/e2e/src/memory/globals.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@counter = dso_local global i32 5, align 4
@greeting = dso_local constant [6 x i8] c"hello\00", align 1
@table = dso_local global [5 x i32] [i32 10, i32 20, i32 30, i32 0, i32 0], align 16
@big = internal global i64 1234567890123, align 8
@ptr = internal global ptr getelementptr (i8, ptr @table, i64 8), align 8
@.str = private unnamed_addr constant [20 x i8] c"%d %ld %s %d %d %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = load i32, ptr @counter, align 4
  %3 = add nsw i32 %2, 10
  store i32 %3, ptr @counter, align 4
  %4 = load i64, ptr @big, align 8
  %5 = sdiv i64 %4, 3
  store i64 %5, ptr @big, align 8
  %6 = load ptr, ptr @ptr, align 8
  %7 = load i32, ptr %6, align 4
  %8 = add nsw i32 %7, 1
  store i32 %8, ptr %6, align 4
  %9 = load i32, ptr @counter, align 4
  %10 = load i64, ptr @big, align 8
  %11 = load i32, ptr getelementptr inbounds nuw (i8, ptr @table, i64 8), align 8
  %12 = load i32, ptr getelementptr inbounds nuw (i8, ptr @table, i64 16), align 16
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %9, i64 noundef %10, ptr noundef @greeting, i32 noundef %11, i32 noundef %12, i32 noundef 6)
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
