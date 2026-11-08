; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-002.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-002.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-002.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@x = dso_local global i32 0, align 4
@a = dso_local global i32 0, align 4
@d = dso_local global i16 0, align 2
@e = dso_local global i32 0, align 4
@c = dso_local global i32 0, align 4
@b = dso_local global i8 0, align 1
@y = dso_local global i64 0, align 8
@z = dso_local global i64 0, align 8
@.str = private unnamed_addr constant [8 x i8] c"a = %i\0A\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"b = %hhi\0A\00", align 1
@.str.2 = private unnamed_addr constant [8 x i8] c"c = %i\0A\00", align 1
@.str.3 = private unnamed_addr constant [9 x i8] c"d = %hi\0A\00", align 1
@.str.4 = private unnamed_addr constant [8 x i8] c"x = %i\0A\00", align 1
@.str.5 = private unnamed_addr constant [8 x i8] c"e = %i\0A\00", align 1
@.str.6 = private unnamed_addr constant [9 x i8] c"z = %li\0A\00", align 1
@.str.7 = private unnamed_addr constant [9 x i8] c"y = %li\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i64 @f() #0 {
  %1 = alloca i64, align 8
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !9
  %5 = load i32, ptr %2, align 4, !tbaa !9
  store i32 %5, ptr @x, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %10, %0
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = icmp slt i32 %7, 5
  br i1 %8, label %9, label %13

9:                                                ; preds = %6
  br label %10

10:                                               ; preds = %9
  %11 = load i32, ptr %2, align 4, !tbaa !9
  %12 = add nsw i32 %11, 1
  store i32 %12, ptr %2, align 4, !tbaa !9
  br label %6, !llvm.loop !10

13:                                               ; preds = %6
  br label %14

14:                                               ; preds = %22, %13
  %15 = load i32, ptr %2, align 4, !tbaa !9
  %16 = icmp slt i32 %15, 3
  br i1 %16, label %17, label %24

17:                                               ; preds = %14
  br label %18

18:                                               ; preds = %42, %17
  br label %19

19:                                               ; preds = %20, %18
  br label %20

20:                                               ; preds = %19
  %21 = load i32, ptr @a, align 4, !tbaa !9
  br label %19

22:                                               ; No predecessors!
  %23 = load i32, ptr %2, align 4, !tbaa !9
  br label %14, !llvm.loop !12

24:                                               ; preds = %14
  br label %25

25:                                               ; preds = %45, %24
  call void @llvm.lifetime.start.p0(ptr %3) #3
  %26 = load i32, ptr @a, align 4, !tbaa !9
  %27 = icmp ne i32 %26, 0
  br i1 %27, label %28, label %29

28:                                               ; preds = %25
  store i32 8, ptr %4, align 4
  br label %42

29:                                               ; preds = %25
  %30 = load i16, ptr @d, align 2, !tbaa !13
  %31 = icmp ne i16 %30, 0
  br i1 %31, label %32, label %37

32:                                               ; preds = %29
  %33 = load i32, ptr @e, align 4, !tbaa !9
  %34 = icmp ne i32 %33, 0
  br i1 %34, label %35, label %36

35:                                               ; preds = %32
  store i64 0, ptr %1, align 8
  store i32 1, ptr %4, align 4
  br label %42

36:                                               ; preds = %32
  store i32 12, ptr %4, align 4
  br label %42

37:                                               ; preds = %29
  %38 = load i32, ptr @c, align 4, !tbaa !9
  %39 = icmp ne i32 %38, 0
  br i1 %39, label %40, label %41

40:                                               ; preds = %37
  store i32 14, ptr %4, align 4
  br label %42

41:                                               ; preds = %37
  store i32 0, ptr %4, align 4
  br label %42

42:                                               ; preds = %41, %40, %36, %35, %28
  call void @llvm.lifetime.end.p0(ptr %3) #3
  %43 = load i32, ptr %4, align 4
  switch i32 %43, label %49 [
    i32 0, label %44
    i32 8, label %18
    i32 12, label %47
    i32 14, label %45
  ]

44:                                               ; preds = %42
  br label %45

45:                                               ; preds = %44, %42
  %46 = load i8, ptr @b, align 1, !tbaa !15
  br label %25

47:                                               ; preds = %42
  store i64 0, ptr @y, align 8, !tbaa !16
  %48 = load i64, ptr @y, align 8, !tbaa !16
  store i64 %48, ptr %1, align 8
  store i32 1, ptr %4, align 4
  br label %49

49:                                               ; preds = %47, %42
  call void @llvm.lifetime.end.p0(ptr %2) #3
  %50 = load i64, ptr %1, align 8
  ret i64 %50
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i64, align 8
  %4 = alloca i32, align 4
  %5 = alloca i16, align 2
  %6 = alloca i8, align 1
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  call void @llvm.lifetime.start.p0(ptr %9) #3
  store i32 0, ptr %9, align 4, !tbaa !9
  store i32 -2, ptr %8, align 4, !tbaa !9
  store i32 0, ptr %7, align 4, !tbaa !9
  store i8 0, ptr %6, align 1, !tbaa !15
  store i16 10, ptr %5, align 2, !tbaa !13
  store i32 4, ptr %4, align 4, !tbaa !9
  store i64 0, ptr %3, align 8, !tbaa !16
  store i64 0, ptr %2, align 8, !tbaa !16
  %10 = load i64, ptr %2, align 8, !tbaa !16
  store i64 %10, ptr @z, align 8, !tbaa !16
  %11 = load i64, ptr %3, align 8, !tbaa !16
  store i64 %11, ptr @y, align 8, !tbaa !16
  %12 = load i32, ptr %4, align 4, !tbaa !9
  store i32 %12, ptr @x, align 4, !tbaa !9
  %13 = load i16, ptr %5, align 2, !tbaa !13
  store i16 %13, ptr @d, align 2, !tbaa !13
  %14 = load i8, ptr %6, align 1, !tbaa !15
  store i8 %14, ptr @b, align 1, !tbaa !15
  %15 = load i32, ptr %7, align 4, !tbaa !9
  store i32 %15, ptr @e, align 4, !tbaa !9
  %16 = load i32, ptr %8, align 4, !tbaa !9
  store i32 %16, ptr @c, align 4, !tbaa !9
  %17 = load i32, ptr %9, align 4, !tbaa !9
  store i32 %17, ptr @a, align 4, !tbaa !9
  %18 = call i64 @f()
  store i64 %18, ptr @z, align 8, !tbaa !16
  %19 = load i32, ptr @a, align 4, !tbaa !9
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %19)
  %21 = load i8, ptr @b, align 1, !tbaa !15
  %22 = sext i8 %21 to i32
  %23 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %22)
  %24 = load i32, ptr @c, align 4, !tbaa !9
  %25 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %24)
  %26 = load i16, ptr @d, align 2, !tbaa !13
  %27 = sext i16 %26 to i32
  %28 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %27)
  %29 = load i32, ptr @x, align 4, !tbaa !9
  %30 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %29)
  %31 = load i32, ptr @e, align 4, !tbaa !9
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %31)
  %33 = load i64, ptr @z, align 8, !tbaa !16
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i64 noundef %33)
  %35 = load i64, ptr @y, align 8, !tbaa !16
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i64 noundef %35)
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }

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
!12 = distinct !{!12, !11}
!13 = !{!14, !14, i64 0}
!14 = !{!"short", !7, i64 0}
!15 = !{!7, !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
