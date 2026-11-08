; @source: tests/e2e/src/libc/qsort_strings.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
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

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [9 x i32], align 16
  %3 = alloca i32, align 4
  %4 = alloca [6 x ptr], align 16
  %5 = alloca i32, align 4
  %6 = alloca [32 x i8], align 16
  %7 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.xs, i64 36, i1 false)
  %8 = getelementptr inbounds [9 x i32], ptr %2, i64 0, i64 0
  call void @qsort(ptr noundef %8, i64 noundef 9, i64 noundef 4, ptr noundef @cmp_int)
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %19, %0
  %10 = load i32, ptr %3, align 4, !tbaa !9
  %11 = icmp slt i32 %10, 9
  br i1 %11, label %13, label %12

12:                                               ; preds = %9
  call void @llvm.lifetime.end.p0(ptr %3) #5
  br label %22

13:                                               ; preds = %9
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = sext i32 %14 to i64
  %16 = getelementptr inbounds [9 x i32], ptr %2, i64 0, i64 %15
  %17 = load i32, ptr %16, align 4, !tbaa !9
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %17)
  br label %19

19:                                               ; preds = %13
  %20 = load i32, ptr %3, align 4, !tbaa !9
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %3, align 4, !tbaa !9
  br label %9, !llvm.loop !10

22:                                               ; preds = %12
  %23 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %4, ptr align 16 @__const.main.words, i64 48, i1 false)
  %24 = getelementptr inbounds [6 x ptr], ptr %4, i64 0, i64 0
  call void @qsort(ptr noundef %24, i64 noundef 6, i64 noundef 8, ptr noundef @cmp_str)
  call void @llvm.lifetime.start.p0(ptr %5) #5
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %25

25:                                               ; preds = %35, %22
  %26 = load i32, ptr %5, align 4, !tbaa !9
  %27 = icmp slt i32 %26, 6
  br i1 %27, label %29, label %28

28:                                               ; preds = %25
  call void @llvm.lifetime.end.p0(ptr %5) #5
  br label %38

29:                                               ; preds = %25
  %30 = load i32, ptr %5, align 4, !tbaa !9
  %31 = sext i32 %30 to i64
  %32 = getelementptr inbounds [6 x ptr], ptr %4, i64 0, i64 %31
  %33 = load ptr, ptr %32, align 8, !tbaa !12
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, ptr noundef %33)
  br label %35

35:                                               ; preds = %29
  %36 = load i32, ptr %5, align 4, !tbaa !9
  %37 = add nsw i32 %36, 1
  store i32 %37, ptr %5, align 4, !tbaa !9
  br label %25, !llvm.loop !15

38:                                               ; preds = %28
  %39 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %6, ptr align 16 @__const.main.s, i64 32, i1 false)
  %40 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %41 = call ptr @strcat(ptr noundef %40, ptr noundef @.str.9) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  %42 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %43 = call ptr @strchr(ptr noundef %42, i32 noundef 119) #6
  store ptr %43, ptr %7, align 8, !tbaa !12
  %44 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %45 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %46 = call i64 @strlen(ptr noundef %45) #6
  %47 = load ptr, ptr %7, align 8, !tbaa !12
  %48 = getelementptr inbounds [32 x i8], ptr %6, i64 0, i64 0
  %49 = ptrtoint ptr %47 to i64
  %50 = ptrtoint ptr %48 to i64
  %51 = sub i64 %49, %50
  %52 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, ptr noundef %44, i64 noundef %46, i64 noundef %51, i32 noundef 1)
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare void @qsort(ptr noundef, i64 noundef, i64 noundef, ptr noundef) #2

; Function Attrs: nounwind uwtable
define internal i32 @cmp_int(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !16
  store ptr %1, ptr %4, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %5) #5
  %7 = load ptr, ptr %3, align 8, !tbaa !16
  %8 = load i32, ptr %7, align 4, !tbaa !9
  store i32 %8, ptr %5, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %9 = load ptr, ptr %4, align 8, !tbaa !16
  %10 = load i32, ptr %9, align 4, !tbaa !9
  store i32 %10, ptr %6, align 4, !tbaa !9
  %11 = load i32, ptr %5, align 4, !tbaa !9
  %12 = load i32, ptr %6, align 4, !tbaa !9
  %13 = icmp sgt i32 %11, %12
  %14 = zext i1 %13 to i32
  %15 = load i32, ptr %5, align 4, !tbaa !9
  %16 = load i32, ptr %6, align 4, !tbaa !9
  %17 = icmp slt i32 %15, %16
  %18 = zext i1 %17 to i32
  %19 = sub nsw i32 %14, %18
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret i32 %19
}

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @cmp_str(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !16
  store ptr %1, ptr %4, align 8, !tbaa !16
  %5 = load ptr, ptr %3, align 8, !tbaa !16
  %6 = load ptr, ptr %5, align 8, !tbaa !12
  %7 = load ptr, ptr %4, align 8, !tbaa !16
  %8 = load ptr, ptr %7, align 8, !tbaa !12
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

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

!llvm.module.flags = !{!0, !1, !2}
!llvm.ident = !{!3}
!llvm.errno.tbaa = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!4 = !{!5, !6, i64 0}
!5 = !{!"__libc_errno", !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{!6, !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 omnipotent char", !14, i64 0}
!14 = !{!"any pointer", !7, i64 0}
!15 = distinct !{!15, !11}
!16 = !{!14, !14, i64 0}
