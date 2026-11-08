; @source: tests/e2e/src/libc/qsort_strings.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/libc/qsort_strings.c'
source_filename = "tests/e2e/src/libc/qsort_strings.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.xs = private unnamed_addr constant [9 x i32] [i32 42, i32 -7, i32 19, i32 0, i32 1000, i32 3, i32 3, i32 -100, i32 55], align 16
@.str = private unnamed_addr constant [4 x i8] c"%d \00", align 1
@.str.1 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.2 = private unnamed_addr constant [5 x i8] c"pear\00", align 1
@.str.3 = private unnamed_addr constant [6 x i8] c"apple\00", align 1
@.str.4 = private unnamed_addr constant [4 x i8] c"fig\00", align 1
@.str.5 = private unnamed_addr constant [7 x i8] c"banana\00", align 1
@.str.6 = private unnamed_addr constant [7 x i8] c"cherry\00", align 1
@.str.7 = private unnamed_addr constant [5 x i8] c"date\00", align 1
@__const.main.words = private unnamed_addr constant [6 x ptr] [ptr @.str.2, ptr @.str.3, ptr @.str.4, ptr @.str.5, ptr @.str.6, ptr @.str.7], align 16
@.str.8 = private unnamed_addr constant [4 x i8] c"%s \00", align 1
@__const.main.s = private unnamed_addr constant [32 x i8] c"hello\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00", align 16
@.str.9 = private unnamed_addr constant [8 x i8] c", world\00", align 1
@.str.10 = private unnamed_addr constant [15 x i8] c"%s %zu %ld %d\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [9 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca [6 x ptr], align 16
  %5 = alloca i32, align 4
  %6 = alloca [32 x i8], align 16
  %7 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.xs, i64 36, i1 false)
  %8 = getelementptr inbounds [9 x i32], ptr %2, i64 0, i64 0
  call void @qsort(ptr noundef %8, i64 noundef 9, i64 noundef 4, ptr noundef @cmp_int)
  store i32 0, ptr %3, align 4
  br label %9

9:                                                ; preds = %18, %0
  %10 = load i32, ptr %3, align 4
  %11 = icmp slt i32 %10, 9
  br i1 %11, label %12, label %21

12:                                               ; preds = %9
  %13 = load i32, ptr %3, align 4
  %14 = sext i32 %13 to i64
  %15 = getelementptr inbounds [9 x i32], ptr %2, i64 0, i64 %14
  %16 = load i32, ptr %15, align 4
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %16)
  br label %18

18:                                               ; preds = %12
  %19 = load i32, ptr %3, align 4
  %20 = add nsw i32 %19, 1
  store i32 %20, ptr %3, align 4
  br label %9, !llvm.loop !5

21:                                               ; preds = %9
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %4, ptr align 16 @__const.main.words, i64 48, i1 false)
  %23 = getelementptr inbounds [6 x ptr], ptr %4, i64 0, i64 0
  call void @qsort(ptr noundef %23, i64 noundef 6, i64 noundef 8, ptr noundef @cmp_str)
  store i32 0, ptr %5, align 4
  br label %24

24:                                               ; preds = %33, %21
  %25 = load i32, ptr %5, align 4
  %26 = icmp slt i32 %25, 6
  br i1 %26, label %27, label %36

27:                                               ; preds = %24
  %28 = load i32, ptr %5, align 4
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [6 x ptr], ptr %4, i64 0, i64 %29
  %31 = load ptr, ptr %30, align 8
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, ptr noundef %31)
  br label %33

33:                                               ; preds = %27
  %34 = load i32, ptr %5, align 4
  %35 = add nsw i32 %34, 1
  store i32 %35, ptr %5, align 4
  br label %24, !llvm.loop !7

36:                                               ; preds = %24
  %37 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %6, ptr align 16 @__const.main.s, i64 32, i1 false)
  %38 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %39 = call ptr @strcat(ptr noundef %38, ptr noundef @.str.9) #5
  %40 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %41 = call ptr @strchr(ptr noundef %40, i32 noundef 119) #6
  store ptr %41, ptr %7, align 8
  %42 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %43 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %44 = call i64 @strlen(ptr noundef %43) #6
  %45 = load ptr, ptr %7, align 8
  %46 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %47 = ptrtoint ptr %45 to i64
  %48 = ptrtoint ptr %46 to i64
  %49 = sub i64 %47, %48
  %50 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, ptr noundef %42, i64 noundef %44, i64 noundef %49, i32 noundef 1)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare void @qsort(ptr noundef, i64 noundef, i64 noundef, ptr noundef) #2

; Function Attrs: noinline nounwind uwtable
define internal i32 @cmp_int(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %7 = load ptr, ptr %3, align 8
  %8 = load i32, ptr %7, align 4
  store i32 %8, ptr %5, align 4
  %9 = load ptr, ptr %4, align 8
  %10 = load i32, ptr %9, align 4
  store i32 %10, ptr %6, align 4
  %11 = load i32, ptr %5, align 4
  %12 = load i32, ptr %6, align 4
  %13 = icmp sgt i32 %11, %12
  %14 = zext i1 %13 to i32
  %15 = load i32, ptr %5, align 4
  %16 = load i32, ptr %6, align 4
  %17 = icmp slt i32 %15, %16
  %18 = zext i1 %17 to i32
  %19 = sub nsw i32 %14, %18
  ret i32 %19
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: noinline nounwind uwtable
define internal i32 @cmp_str(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %5 = load ptr, ptr %3, align 8
  %6 = load ptr, ptr %5, align 8
  %7 = load ptr, ptr %4, align 8
  %8 = load ptr, ptr %7, align 8
  %9 = call i32 @strcmp(ptr noundef %6, ptr noundef %8) #6
  ret i32 %9
}

; Function Attrs: nounwind
declare ptr @strcat(ptr noundef, ptr noundef) #3

; Function Attrs: nounwind willreturn memory(read)
declare ptr @strchr(ptr noundef, i32 noundef) #4

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #4

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #4

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

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
