; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-22-LocalTypeTest.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-22-LocalTypeTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-22-LocalTypeTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.sometimes.1 = type { i16, i16, i16, i16 }
%struct.sometimes = type { i32, i32 }
%struct.sometimes.0 = type { i8 }

@Y = dso_local global %struct.sometimes.1 zeroinitializer, align 2
@.str = private unnamed_addr constant [14 x i8] c"Result is %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca %struct.sometimes, align 4
  %4 = alloca %struct.sometimes.0, align 1
  store i32 0, ptr %1, align 4
  %5 = getelementptr inbounds nuw %struct.sometimes, ptr %3, i32 0, i32 0
  store i32 1, ptr %5, align 4
  %6 = getelementptr inbounds nuw %struct.sometimes, ptr %3, i32 0, i32 0
  %7 = load i32, ptr %6, align 4
  store i32 %7, ptr %2, align 4
  %8 = getelementptr inbounds nuw %struct.sometimes.0, ptr %4, i32 0, i32 0
  store i8 -1, ptr %8, align 1
  %9 = getelementptr inbounds nuw %struct.sometimes.0, ptr %4, i32 0, i32 0
  %10 = load i8, ptr %9, align 1
  %11 = sext i8 %10 to i32
  %12 = load i32, ptr %2, align 4
  %13 = add nsw i32 %12, %11
  store i32 %13, ptr %2, align 4
  %14 = load i16, ptr @Y, align 2
  %15 = sext i16 %14 to i32
  %16 = load i32, ptr %2, align 4
  %17 = add nsw i32 %16, %15
  store i32 %17, ptr %2, align 4
  %18 = load i32, ptr %2, align 4
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %18)
  %20 = load i32, ptr %2, align 4
  ret i32 %20
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
