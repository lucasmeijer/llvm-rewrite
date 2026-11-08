; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/testtrace.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.DummyStruct = type { ptr, i32 }

@.str = private unnamed_addr constant [28 x i8] c"&S1 = %p\09&S2 = %p\09&S3 = %p\0A\00", align 1
@testAllocaOrder.count = internal global i32 0, align 4
@.str.1 = private unnamed_addr constant [10 x i8] c"sum = %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"-d\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @AddCounts(ptr noundef %0, ptr noundef %1, ptr noundef %2, i32 noundef %3) #0 {
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca ptr, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %5, align 8
  store ptr %1, ptr %6, align 8
  store ptr %2, ptr %7, align 8
  store i32 %3, ptr %8, align 4
  %9 = load i32, ptr %8, align 4
  %10 = icmp ne i32 %9, 0
  br i1 %10, label %16, label %11

11:                                               ; preds = %4
  %12 = load ptr, ptr %5, align 8
  %13 = load ptr, ptr %6, align 8
  %14 = load ptr, ptr %7, align 8
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %12, ptr noundef %13, ptr noundef %14)
  br label %16

16:                                               ; preds = %11, %4
  %17 = load ptr, ptr %5, align 8
  %18 = getelementptr inbounds nuw %struct.DummyStruct, ptr %17, i32 0, i32 1
  %19 = load i32, ptr %18, align 8
  %20 = load ptr, ptr %6, align 8
  %21 = getelementptr inbounds nuw %struct.DummyStruct, ptr %20, i32 0, i32 1
  %22 = load i32, ptr %21, align 8
  %23 = add nsw i32 %19, %22
  %24 = load ptr, ptr %7, align 8
  %25 = getelementptr inbounds nuw %struct.DummyStruct, ptr %24, i32 0, i32 1
  %26 = load i32, ptr %25, align 8
  %27 = add nsw i32 %23, %26
  ret i32 %27
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local void @testAllocaOrder(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca %struct.DummyStruct, align 8
  %4 = alloca %struct.DummyStruct, align 8
  %5 = alloca %struct.DummyStruct, align 8
  store i32 %0, ptr %2, align 4
  %6 = load i32, ptr @testAllocaOrder.count, align 4
  %7 = add nsw i32 %6, 1
  store i32 %7, ptr @testAllocaOrder.count, align 4
  %8 = getelementptr inbounds nuw %struct.DummyStruct, ptr %3, i32 0, i32 1
  store i32 %7, ptr %8, align 8
  %9 = load i32, ptr @testAllocaOrder.count, align 4
  %10 = add nsw i32 %9, 1
  store i32 %10, ptr @testAllocaOrder.count, align 4
  %11 = getelementptr inbounds nuw %struct.DummyStruct, ptr %4, i32 0, i32 1
  store i32 %10, ptr %11, align 8
  %12 = load i32, ptr @testAllocaOrder.count, align 4
  %13 = add nsw i32 %12, 1
  store i32 %13, ptr @testAllocaOrder.count, align 4
  %14 = getelementptr inbounds nuw %struct.DummyStruct, ptr %5, i32 0, i32 1
  store i32 %13, ptr %14, align 8
  %15 = load i32, ptr %2, align 4
  %16 = call i32 @AddCounts(ptr noundef %3, ptr noundef %4, ptr noundef %5, i32 noundef %15)
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %16)
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  store i32 1, ptr %7, align 4
  %8 = load i32, ptr %4, align 4
  %9 = icmp sgt i32 %8, 1
  br i1 %9, label %10, label %17

10:                                               ; preds = %2
  %11 = load ptr, ptr %5, align 8
  %12 = getelementptr inbounds ptr, ptr %11, i64 1
  %13 = load ptr, ptr %12, align 8
  %14 = call i32 @strcmp(ptr noundef %13, ptr noundef @.str.2) #3
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %17, label %16

16:                                               ; preds = %10
  store i32 0, ptr %7, align 4
  br label %17

17:                                               ; preds = %16, %10, %2
  store i32 0, ptr %6, align 4
  br label %18

18:                                               ; preds = %23, %17
  %19 = load i32, ptr %6, align 4
  %20 = icmp ult i32 %19, 10
  br i1 %20, label %21, label %26

21:                                               ; preds = %18
  %22 = load i32, ptr %7, align 4
  call void @testAllocaOrder(i32 noundef %22)
  br label %23

23:                                               ; preds = %21
  %24 = load i32, ptr %6, align 4
  %25 = add i32 %24, 1
  store i32 %25, ptr %6, align 4
  br label %18, !llvm.loop !5

26:                                               ; preds = %18
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #2

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
