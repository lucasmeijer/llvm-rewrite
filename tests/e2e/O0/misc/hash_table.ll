; @source: tests/e2e/src/misc/hash_table.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/hash_table.c'
source_filename = "tests/e2e/src/misc/hash_table.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.entry = type { [16 x i8], i32, i32 }

@.str = private unnamed_addr constant [6 x i8] c"key%d\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"key13\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%ld %d %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"nope\00", align 1
@table = internal global [64 x %struct.entry] zeroinitializer, align 16

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [16 x i8], align 16
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  store i32 0, ptr %3, align 4
  br label %6

6:                                                ; preds = %18, %0
  %7 = load i32, ptr %3, align 4
  %8 = icmp slt i32 %7, 40
  br i1 %8, label %9, label %21

9:                                                ; preds = %6
  %10 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %11 = load i32, ptr %3, align 4
  %12 = mul nsw i32 %11, 13
  %13 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %10, i64 noundef 16, ptr noundef @.str, i32 noundef %12) #4
  %14 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %15 = load i32, ptr %3, align 4
  %16 = load i32, ptr %3, align 4
  %17 = mul nsw i32 %15, %16
  call void @put(ptr noundef %14, i32 noundef %17)
  br label %18

18:                                               ; preds = %9
  %19 = load i32, ptr %3, align 4
  %20 = add nsw i32 %19, 1
  store i32 %20, ptr %3, align 4
  br label %6, !llvm.loop !5

21:                                               ; preds = %6
  call void @put(ptr noundef @.str.1, i32 noundef -5)
  store i64 0, ptr %4, align 8
  store i32 0, ptr %5, align 4
  br label %22

22:                                               ; preds = %35, %21
  %23 = load i32, ptr %5, align 4
  %24 = icmp slt i32 %23, 60
  br i1 %24, label %25, label %38

25:                                               ; preds = %22
  %26 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %27 = load i32, ptr %5, align 4
  %28 = mul nsw i32 %27, 13
  %29 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %26, i64 noundef 16, ptr noundef @.str, i32 noundef %28) #4
  %30 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %31 = call i32 @get(ptr noundef %30)
  %32 = sext i32 %31 to i64
  %33 = load i64, ptr %4, align 8
  %34 = add nsw i64 %33, %32
  store i64 %34, ptr %4, align 8
  br label %35

35:                                               ; preds = %25
  %36 = load i32, ptr %5, align 4
  %37 = add nsw i32 %36, 1
  store i32 %37, ptr %5, align 4
  br label %22, !llvm.loop !7

38:                                               ; preds = %22
  %39 = load i64, ptr %4, align 8
  %40 = call i32 @get(ptr noundef @.str.1)
  %41 = call i32 @get(ptr noundef @.str.3)
  %42 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %39, i32 noundef %40, i32 noundef %41)
  ret i32 0
}

; Function Attrs: nounwind
declare i32 @snprintf(ptr noundef, i64 noundef, ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define internal void @put(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store i32 %1, ptr %4, align 4
  %6 = load ptr, ptr %3, align 8
  %7 = call i32 @hash(ptr noundef %6)
  %8 = urem i32 %7, 64
  store i32 %8, ptr %5, align 4
  br label %9

9:                                                ; preds = %27, %2
  %10 = load i32, ptr %5, align 4
  %11 = zext i32 %10 to i64
  %12 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.entry, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %25

16:                                               ; preds = %9
  %17 = load i32, ptr %5, align 4
  %18 = zext i32 %17 to i64
  %19 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %18
  %20 = getelementptr inbounds nuw %struct.entry, ptr %19, i32 0, i32 0
  %21 = getelementptr inbounds [16 x i8], ptr %20, i64 0, i64 0
  %22 = load ptr, ptr %3, align 8
  %23 = call i32 @strcmp(ptr noundef %21, ptr noundef %22) #5
  %24 = icmp ne i32 %23, 0
  br label %25

25:                                               ; preds = %16, %9
  %26 = phi i1 [ false, %9 ], [ %24, %16 ]
  br i1 %26, label %27, label %31

27:                                               ; preds = %25
  %28 = load i32, ptr %5, align 4
  %29 = add i32 %28, 1
  %30 = urem i32 %29, 64
  store i32 %30, ptr %5, align 4
  br label %9, !llvm.loop !8

31:                                               ; preds = %25
  %32 = load i32, ptr %5, align 4
  %33 = zext i32 %32 to i64
  %34 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %33
  %35 = getelementptr inbounds nuw %struct.entry, ptr %34, i32 0, i32 0
  %36 = getelementptr inbounds [16 x i8], ptr %35, i64 0, i64 0
  %37 = load ptr, ptr %3, align 8
  %38 = call ptr @strcpy(ptr noundef %36, ptr noundef %37) #4
  %39 = load i32, ptr %4, align 4
  %40 = load i32, ptr %5, align 4
  %41 = zext i32 %40 to i64
  %42 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %41
  %43 = getelementptr inbounds nuw %struct.entry, ptr %42, i32 0, i32 1
  store i32 %39, ptr %43, align 8
  %44 = load i32, ptr %5, align 4
  %45 = zext i32 %44 to i64
  %46 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %45
  %47 = getelementptr inbounds nuw %struct.entry, ptr %46, i32 0, i32 2
  store i32 1, ptr %47, align 4
  ret void
}

; Function Attrs: noinline nounwind uwtable
define internal i32 @get(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  %5 = load ptr, ptr %3, align 8
  %6 = call i32 @hash(ptr noundef %5)
  %7 = urem i32 %6, 64
  store i32 %7, ptr %4, align 4
  br label %8

8:                                                ; preds = %30, %1
  %9 = load i32, ptr %4, align 4
  %10 = zext i32 %9 to i64
  %11 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %10
  %12 = getelementptr inbounds nuw %struct.entry, ptr %11, i32 0, i32 2
  %13 = load i32, ptr %12, align 4
  %14 = icmp ne i32 %13, 0
  br i1 %14, label %15, label %34

15:                                               ; preds = %8
  %16 = load i32, ptr %4, align 4
  %17 = zext i32 %16 to i64
  %18 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %17
  %19 = getelementptr inbounds nuw %struct.entry, ptr %18, i32 0, i32 0
  %20 = getelementptr inbounds [16 x i8], ptr %19, i64 0, i64 0
  %21 = load ptr, ptr %3, align 8
  %22 = call i32 @strcmp(ptr noundef %20, ptr noundef %21) #5
  %23 = icmp ne i32 %22, 0
  br i1 %23, label %30, label %24

24:                                               ; preds = %15
  %25 = load i32, ptr %4, align 4
  %26 = zext i32 %25 to i64
  %27 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %26
  %28 = getelementptr inbounds nuw %struct.entry, ptr %27, i32 0, i32 1
  %29 = load i32, ptr %28, align 8
  store i32 %29, ptr %2, align 4
  br label %35

30:                                               ; preds = %15
  %31 = load i32, ptr %4, align 4
  %32 = add i32 %31, 1
  %33 = urem i32 %32, 64
  store i32 %33, ptr %4, align 4
  br label %8, !llvm.loop !9

34:                                               ; preds = %8
  store i32 -1, ptr %2, align 4
  br label %35

35:                                               ; preds = %34, %24
  %36 = load i32, ptr %2, align 4
  ret i32 %36
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: noinline nounwind uwtable
define internal i32 @hash(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store ptr %0, ptr %2, align 8
  store i32 5381, ptr %3, align 4
  br label %4

4:                                                ; preds = %8, %1
  %5 = load ptr, ptr %2, align 8
  %6 = load i8, ptr %5, align 1
  %7 = icmp ne i8 %6, 0
  br i1 %7, label %8, label %16

8:                                                ; preds = %4
  %9 = load i32, ptr %3, align 4
  %10 = mul i32 %9, 33
  %11 = load ptr, ptr %2, align 8
  %12 = getelementptr inbounds nuw i8, ptr %11, i32 1
  store ptr %12, ptr %2, align 8
  %13 = load i8, ptr %11, align 1
  %14 = zext i8 %13 to i32
  %15 = add i32 %10, %14
  store i32 %15, ptr %3, align 4
  br label %4, !llvm.loop !10

16:                                               ; preds = %4
  %17 = load i32, ptr %3, align 4
  ret i32 %17
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #3

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #1

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }
attributes #5 = { nounwind willreturn memory(read) }

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
!9 = distinct !{!9, !6}
!10 = distinct !{!10, !6}
