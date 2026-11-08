; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-23-TransparentUnion.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-23-TransparentUnion.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/2003-05-23-TransparentUnion.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%union.UNION = type { ptr }

@.str = private unnamed_addr constant [3 x i8] c"ok\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @try(ptr %0) #0 {
  %2 = alloca %union.UNION, align 8
  %3 = getelementptr inbounds nuw %union.UNION, ptr %2, i32 0, i32 0
  store ptr %0, ptr %3, align 8
  ret i32 1
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @test() #0 {
  %1 = alloca i32, align 4
  %2 = alloca float, align 4
  %3 = alloca %union.UNION, align 8
  %4 = alloca %union.UNION, align 8
  store ptr %1, ptr %3, align 8
  %5 = getelementptr inbounds nuw %union.UNION, ptr %3, i32 0, i32 0
  %6 = load ptr, ptr %5, align 8
  %7 = call i32 @try(ptr %6)
  store ptr %2, ptr %4, align 8
  %8 = getelementptr inbounds nuw %union.UNION, ptr %4, i32 0, i32 0
  %9 = load ptr, ptr %8, align 8
  %10 = call i32 @try(ptr %9)
  %11 = or i32 %7, %10
  ret i32 %11
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i32 @test()
  %3 = icmp ne i32 %2, 0
  br i1 %3, label %4, label %6

4:                                                ; preds = %0
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  br label %6

6:                                                ; preds = %4, %0
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
