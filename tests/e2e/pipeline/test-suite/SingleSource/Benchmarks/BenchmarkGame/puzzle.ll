; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/puzzle.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/puzzle.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/BenchmarkGame/puzzle.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@next = internal global i64 1, align 8
@.str = private unnamed_addr constant [21 x i8] c"Found duplicate: %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @rand() #0 {
  %1 = load i64, ptr @next, align 8, !tbaa !9
  %2 = mul i64 %1, 1103515245
  %3 = add i64 %2, 12345
  store i64 %3, ptr @next, align 8, !tbaa !9
  %4 = load i64, ptr @next, align 8, !tbaa !9
  %5 = udiv i64 %4, 65536
  %6 = trunc i64 %5 to i32
  %7 = urem i32 %6, 32767
  %8 = add i32 %7, 1
  ret i32 %8
}

; Function Attrs: nounwind uwtable
define dso_local void @srand(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !11
  %3 = load i32, ptr %2, align 4, !tbaa !11
  %4 = zext i32 %3 to i64
  store i64 %4, ptr @next, align 8, !tbaa !9
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @randInt(i32 noundef %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !11
  store i32 %1, ptr %4, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %7 = load i32, ptr %4, align 4, !tbaa !11
  %8 = load i32, ptr %3, align 4, !tbaa !11
  %9 = sub nsw i32 %7, %8
  %10 = add nsw i32 %9, 1
  store i32 %10, ptr %6, align 4, !tbaa !11
  %11 = load i32, ptr %6, align 4, !tbaa !11
  %12 = sitofp i32 %11 to double
  %13 = call i32 @rand() #5
  %14 = sitofp i32 %13 to double
  %15 = fdiv double %14, 3.276800e+04
  %16 = fmul double %12, %15
  %17 = fptosi double %16 to i32
  store i32 %17, ptr %5, align 4, !tbaa !11
  %18 = load i32, ptr %5, align 4, !tbaa !11
  %19 = load i32, ptr %6, align 4, !tbaa !11
  %20 = icmp eq i32 %18, %19
  br i1 %20, label %21, label %26

21:                                               ; preds = %2
  %22 = load i32, ptr %5, align 4, !tbaa !11
  %23 = load i32, ptr %3, align 4, !tbaa !11
  %24 = add nsw i32 %22, %23
  %25 = sub nsw i32 %24, 1
  br label %30

26:                                               ; preds = %2
  %27 = load i32, ptr %5, align 4, !tbaa !11
  %28 = load i32, ptr %3, align 4, !tbaa !11
  %29 = add nsw i32 %27, %28
  br label %30

30:                                               ; preds = %26, %21
  %31 = phi i32 [ %25, %21 ], [ %29, %26 ]
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret i32 %31
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @shuffle(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %9 = load i32, ptr %4, align 4, !tbaa !11
  %10 = sub nsw i32 %9, 1
  %11 = sext i32 %10 to i64
  store i64 %11, ptr %7, align 8, !tbaa !15
  br label %12

12:                                               ; preds = %51, %2
  %13 = load i64, ptr %7, align 8, !tbaa !15
  %14 = icmp ugt i64 %13, 0
  br i1 %14, label %15, label %54

15:                                               ; preds = %12
  %16 = load i64, ptr %7, align 8, !tbaa !15
  %17 = add i64 %16, 1
  %18 = uitofp i64 %17 to double
  %19 = call i32 @rand() #5
  %20 = sitofp i32 %19 to double
  %21 = fdiv double %20, 3.276800e+04
  %22 = fmul double %18, %21
  %23 = fptosi double %22 to i32
  %24 = sext i32 %23 to i64
  store i64 %24, ptr %6, align 8, !tbaa !15
  %25 = load i64, ptr %6, align 8, !tbaa !15
  %26 = load i64, ptr %7, align 8, !tbaa !15
  %27 = add i64 %26, 1
  %28 = icmp eq i64 %25, %27
  br i1 %28, label %29, label %32

29:                                               ; preds = %15
  %30 = load i64, ptr %6, align 8, !tbaa !15
  %31 = sub i64 %30, 1
  br label %34

32:                                               ; preds = %15
  %33 = load i64, ptr %6, align 8, !tbaa !15
  br label %34

34:                                               ; preds = %32, %29
  %35 = phi i64 [ %31, %29 ], [ %33, %32 ]
  store i64 %35, ptr %5, align 8, !tbaa !15
  %36 = load ptr, ptr %3, align 8, !tbaa !12
  %37 = load i64, ptr %7, align 8, !tbaa !15
  %38 = getelementptr inbounds nuw i32, ptr %36, i64 %37
  %39 = load i32, ptr %38, align 4, !tbaa !11
  store i32 %39, ptr %8, align 4, !tbaa !11
  %40 = load ptr, ptr %3, align 8, !tbaa !12
  %41 = load i64, ptr %5, align 8, !tbaa !15
  %42 = getelementptr inbounds nuw i32, ptr %40, i64 %41
  %43 = load i32, ptr %42, align 4, !tbaa !11
  %44 = load ptr, ptr %3, align 8, !tbaa !12
  %45 = load i64, ptr %7, align 8, !tbaa !15
  %46 = getelementptr inbounds nuw i32, ptr %44, i64 %45
  store i32 %43, ptr %46, align 4, !tbaa !11
  %47 = load i32, ptr %8, align 4, !tbaa !11
  %48 = load ptr, ptr %3, align 8, !tbaa !12
  %49 = load i64, ptr %5, align 8, !tbaa !15
  %50 = getelementptr inbounds nuw i32, ptr %48, i64 %49
  store i32 %47, ptr %50, align 4, !tbaa !11
  br label %51

51:                                               ; preds = %34
  %52 = load i64, ptr %7, align 8, !tbaa !15
  %53 = add i64 %52, -1
  store i64 %53, ptr %7, align 8, !tbaa !15
  br label %12, !llvm.loop !17

54:                                               ; preds = %12
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local ptr @createRandomArray(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.lifetime.start.p0(ptr %5) #5
  %6 = load i32, ptr %2, align 4, !tbaa !11
  %7 = add nsw i32 %6, 1
  store i32 %7, ptr %4, align 4, !tbaa !11
  %8 = load i32, ptr %4, align 4, !tbaa !11
  %9 = sext i32 %8 to i64
  %10 = mul i64 %9, 4
  %11 = call noalias ptr @malloc(i64 noundef %10) #6
  store ptr %11, ptr %5, align 8, !tbaa !12
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %12

12:                                               ; preds = %22, %1
  %13 = load i32, ptr %3, align 4, !tbaa !11
  %14 = load i32, ptr %4, align 4, !tbaa !11
  %15 = icmp slt i32 %13, %14
  br i1 %15, label %16, label %25

16:                                               ; preds = %12
  %17 = load i32, ptr %3, align 4, !tbaa !11
  %18 = load ptr, ptr %5, align 8, !tbaa !12
  %19 = load i32, ptr %3, align 4, !tbaa !11
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds i32, ptr %18, i64 %20
  store i32 %17, ptr %21, align 4, !tbaa !11
  br label %22

22:                                               ; preds = %16
  %23 = load i32, ptr %3, align 4, !tbaa !11
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %3, align 4, !tbaa !11
  br label %12, !llvm.loop !19

25:                                               ; preds = %12
  %26 = load i32, ptr %2, align 4, !tbaa !11
  %27 = call i32 @randInt(i32 noundef 1, i32 noundef %26)
  %28 = load ptr, ptr %5, align 8, !tbaa !12
  %29 = getelementptr inbounds i32, ptr %28, i64 0
  store i32 %27, ptr %29, align 4, !tbaa !11
  %30 = load ptr, ptr %5, align 8, !tbaa !12
  %31 = load i32, ptr %4, align 4, !tbaa !11
  call void @shuffle(ptr noundef %30, i32 noundef %31)
  %32 = load ptr, ptr %5, align 8, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %5) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  ret ptr %32
}

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @findDuplicate(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !12
  store i32 %1, ptr %4, align 4, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  store i32 0, ptr %6, align 4, !tbaa !11
  store i32 0, ptr %5, align 4, !tbaa !11
  br label %7

7:                                                ; preds = %22, %2
  %8 = load i32, ptr %5, align 4, !tbaa !11
  %9 = load i32, ptr %4, align 4, !tbaa !11
  %10 = icmp slt i32 %8, %9
  br i1 %10, label %11, label %25

11:                                               ; preds = %7
  %12 = load i32, ptr %6, align 4, !tbaa !11
  %13 = load i32, ptr %5, align 4, !tbaa !11
  %14 = add nsw i32 %13, 1
  %15 = xor i32 %12, %14
  %16 = load ptr, ptr %3, align 8, !tbaa !12
  %17 = load i32, ptr %5, align 4, !tbaa !11
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds i32, ptr %16, i64 %18
  %20 = load i32, ptr %19, align 4, !tbaa !11
  %21 = xor i32 %15, %20
  store i32 %21, ptr %6, align 4, !tbaa !11
  br label %22

22:                                               ; preds = %11
  %23 = load i32, ptr %5, align 4, !tbaa !11
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %5, align 4, !tbaa !11
  br label %7, !llvm.loop !20

25:                                               ; preds = %7
  %26 = load i32, ptr %4, align 4, !tbaa !11
  %27 = load i32, ptr %6, align 4, !tbaa !11
  %28 = xor i32 %27, %26
  store i32 %28, ptr %6, align 4, !tbaa !11
  %29 = load i32, ptr %6, align 4, !tbaa !11
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret i32 %29
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.lifetime.start.p0(ptr %4) #5
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @srand(i32 noundef 1) #5
  store i32 0, ptr %2, align 4, !tbaa !11
  br label %6

6:                                                ; preds = %24, %0
  %7 = load i32, ptr %2, align 4, !tbaa !11
  %8 = icmp slt i32 %7, 5
  br i1 %8, label %9, label %27

9:                                                ; preds = %6
  %10 = call ptr @createRandomArray(i32 noundef 500000)
  store ptr %10, ptr %5, align 8, !tbaa !12
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %11

11:                                               ; preds = %17, %9
  %12 = load i32, ptr %3, align 4, !tbaa !11
  %13 = icmp slt i32 %12, 200
  br i1 %13, label %14, label %20

14:                                               ; preds = %11
  %15 = load ptr, ptr %5, align 8, !tbaa !12
  %16 = call i32 @findDuplicate(ptr noundef %15, i32 noundef 500001)
  store i32 %16, ptr %4, align 4, !tbaa !11
  br label %17

17:                                               ; preds = %14
  %18 = load i32, ptr %3, align 4, !tbaa !11
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %3, align 4, !tbaa !11
  br label %11, !llvm.loop !21

20:                                               ; preds = %11
  %21 = load ptr, ptr %5, align 8, !tbaa !12
  call void @free(ptr noundef %21) #5
  %22 = load i32, ptr %4, align 4, !tbaa !11
  %23 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %22)
  br label %24

24:                                               ; preds = %20
  %25 = load i32, ptr %2, align 4, !tbaa !11
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr %2, align 4, !tbaa !11
  br label %6, !llvm.loop !22

27:                                               ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %5) #5
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i32 0
}

; Function Attrs: nounwind
declare void @free(ptr noundef) #3

declare i32 @printf(ptr noundef, ...) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind allocsize(0) }

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
!9 = !{!10, !10, i64 0}
!10 = !{!"long long", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 int", !14, i64 0}
!14 = !{!"any pointer", !7, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"long", !7, i64 0}
!17 = distinct !{!17, !18}
!18 = !{!"llvm.loop.mustprogress"}
!19 = distinct !{!19, !18}
!20 = distinct !{!20, !18}
!21 = distinct !{!21, !18}
!22 = distinct !{!22, !18}
