; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/queens.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/queens.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/McGill/queens.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@printing = dso_local global i32 1, align 4
@findall = dso_local global i32 0, align 4
@solutions = dso_local global i64 0, align 8
@progname = dso_local global ptr null, align 8
@.str = private unnamed_addr constant [168 x i8] c"Usage:  %s [-ac] n\0A\09n\09Number of queens (rows and columns). An integer from 1 to 100.\0A\09-a\09Find and print all solutions.\0A\09-c\09Count all solutions, but do not print them.\0A\00", align 1
@queens = dso_local global i32 0, align 4
@stderr = external global ptr, align 8
@.str.1 = private unnamed_addr constant [25 x i8] c"%s: Illegal option '%s'\0A\00", align 1
@.str.2 = private unnamed_addr constant [3 x i8] c"%d\00", align 1
@.str.3 = private unnamed_addr constant [31 x i8] c"%s: Non-integer argument '%s'\0A\00", align 1
@.str.4 = private unnamed_addr constant [32 x i8] c"%s: n must be positive integer\0A\00", align 1
@.str.5 = private unnamed_addr constant [36 x i8] c"%s: Can't have more than %d queens\0A\00", align 1
@.str.6 = private unnamed_addr constant [24 x i8] c"%s: Missing n argument\0A\00", align 1
@files = dso_local global i32 0, align 4
@ranks = dso_local global i32 0, align 4
@.str.7 = private unnamed_addr constant [32 x i8] c"%d queen%s on a %dx%d board...\0A\00", align 1
@.str.8 = private unnamed_addr constant [2 x i8] c"s\00", align 1
@.str.9 = private unnamed_addr constant [1 x i8] zeroinitializer, align 1
@stdout = external global ptr, align 8
@file = dso_local global [100 x i32] zeroinitializer, align 16
@bakdiag = dso_local global [199 x i32] zeroinitializer, align 16
@fordiag = dso_local global [199 x i32] zeroinitializer, align 16
@.str.10 = private unnamed_addr constant [24 x i8] c"...there is 1 solution\0A\00", align 1
@.str.11 = private unnamed_addr constant [28 x i8] c"...there are %ld solutions\0A\00", align 1
@.str.12 = private unnamed_addr constant [17 x i8] c"\0ASolution #%lu:\0A\00", align 1
@queen = dso_local global [100 x i32] zeroinitializer, align 16

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  %8 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  store ptr @.str, ptr %8, align 8
  %9 = load ptr, ptr %5, align 8
  %10 = getelementptr inbounds ptr, ptr %9, i64 0
  %11 = load ptr, ptr %10, align 8
  store ptr %11, ptr @progname, align 8
  store i32 0, ptr @printing, align 4
  store i32 14, ptr @queens, align 4
  store i32 1, ptr @findall, align 4
  store i32 1, ptr %6, align 4
  br label %12

12:                                               ; preds = %78, %2
  %13 = load i32, ptr %6, align 4
  %14 = load i32, ptr %4, align 4
  %15 = icmp slt i32 %13, %14
  br i1 %15, label %16, label %81

16:                                               ; preds = %12
  %17 = load ptr, ptr %5, align 8
  %18 = load i32, ptr %6, align 4
  %19 = sext i32 %18 to i64
  %20 = getelementptr inbounds ptr, ptr %17, i64 %19
  %21 = load ptr, ptr %20, align 8
  store ptr %21, ptr %7, align 8
  %22 = load ptr, ptr %7, align 8
  %23 = load i8, ptr %22, align 1
  %24 = sext i8 %23 to i32
  %25 = icmp eq i32 %24, 45
  br i1 %25, label %26, label %53

26:                                               ; preds = %16
  br label %27

27:                                               ; preds = %51, %26
  %28 = load ptr, ptr %7, align 8
  %29 = getelementptr inbounds nuw i8, ptr %28, i32 1
  store ptr %29, ptr %7, align 8
  %30 = load i8, ptr %29, align 1
  %31 = icmp ne i8 %30, 0
  br i1 %31, label %32, label %52

32:                                               ; preds = %27
  %33 = load ptr, ptr %7, align 8
  %34 = load i8, ptr %33, align 1
  %35 = sext i8 %34 to i32
  switch i32 %35, label %38 [
    i32 99, label %36
    i32 97, label %37
  ]

36:                                               ; preds = %32
  store i32 0, ptr @printing, align 4
  br label %37

37:                                               ; preds = %32, %36
  store i32 1, ptr @findall, align 4
  br label %51

38:                                               ; preds = %32
  %39 = load ptr, ptr @stderr, align 8
  %40 = load ptr, ptr @progname, align 8
  %41 = load ptr, ptr %5, align 8
  %42 = load i32, ptr %6, align 4
  %43 = sext i32 %42 to i64
  %44 = getelementptr inbounds ptr, ptr %41, i64 %43
  %45 = load ptr, ptr %44, align 8
  %46 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %39, ptr noundef @.str.1, ptr noundef %40, ptr noundef %45) #4
  %47 = load ptr, ptr @stderr, align 8
  %48 = load ptr, ptr %8, align 8
  %49 = load ptr, ptr @progname, align 8
  %50 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %47, ptr noundef %48, ptr noundef %49) #4
  call void @exit(i32 noundef -1) #5
  unreachable

51:                                               ; preds = %37
  br label %27, !llvm.loop !5

52:                                               ; preds = %27
  br label %77

53:                                               ; preds = %16
  %54 = load ptr, ptr %7, align 8
  %55 = call i32 (ptr, ptr, ...) @__isoc99_sscanf(ptr noundef %54, ptr noundef @.str.2, ptr noundef @queens) #4
  %56 = icmp ne i32 %55, 1
  br i1 %56, label %57, label %62

57:                                               ; preds = %53
  %58 = load ptr, ptr @stderr, align 8
  %59 = load ptr, ptr @progname, align 8
  %60 = load ptr, ptr %7, align 8
  %61 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %58, ptr noundef @.str.3, ptr noundef %59, ptr noundef %60) #4
  call void @exit(i32 noundef -1) #5
  unreachable

62:                                               ; preds = %53
  %63 = load i32, ptr @queens, align 4
  %64 = icmp sle i32 %63, 0
  br i1 %64, label %65, label %69

65:                                               ; preds = %62
  %66 = load ptr, ptr @stderr, align 8
  %67 = load ptr, ptr @progname, align 8
  %68 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %66, ptr noundef @.str.4, ptr noundef %67) #4
  call void @exit(i32 noundef -1) #5
  unreachable

69:                                               ; preds = %62
  %70 = load i32, ptr @queens, align 4
  %71 = icmp sgt i32 %70, 100
  br i1 %71, label %72, label %76

72:                                               ; preds = %69
  %73 = load ptr, ptr @stderr, align 8
  %74 = load ptr, ptr @progname, align 8
  %75 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %73, ptr noundef @.str.5, ptr noundef %74, i32 noundef 100) #4
  call void @exit(i32 noundef -1) #5
  unreachable

76:                                               ; preds = %69
  br label %77

77:                                               ; preds = %76, %52
  br label %78

78:                                               ; preds = %77
  %79 = load i32, ptr %6, align 4
  %80 = add nsw i32 %79, 1
  store i32 %80, ptr %6, align 4
  br label %12, !llvm.loop !7

81:                                               ; preds = %12
  %82 = load i32, ptr @queens, align 4
  %83 = icmp ne i32 %82, 0
  br i1 %83, label %92, label %84

84:                                               ; preds = %81
  %85 = load ptr, ptr @stderr, align 8
  %86 = load ptr, ptr @progname, align 8
  %87 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %85, ptr noundef @.str.6, ptr noundef %86) #4
  %88 = load ptr, ptr @stderr, align 8
  %89 = load ptr, ptr %8, align 8
  %90 = load ptr, ptr @progname, align 8
  %91 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %88, ptr noundef %89, ptr noundef %90) #4
  call void @exit(i32 noundef -1) #5
  unreachable

92:                                               ; preds = %81
  %93 = load i32, ptr @queens, align 4
  store i32 %93, ptr @files, align 4
  store i32 %93, ptr @ranks, align 4
  %94 = load i32, ptr @queens, align 4
  %95 = load i32, ptr @queens, align 4
  %96 = icmp sgt i32 %95, 1
  %97 = zext i1 %96 to i64
  %98 = select i1 %96, ptr @.str.8, ptr @.str.9
  %99 = load i32, ptr @ranks, align 4
  %100 = load i32, ptr @files, align 4
  %101 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %94, ptr noundef %98, i32 noundef %99, i32 noundef %100)
  %102 = load ptr, ptr @stdout, align 8
  %103 = call i32 @fflush(ptr noundef %102)
  store i64 0, ptr @solutions, align 8
  store i32 0, ptr %6, align 4
  br label %104

104:                                              ; preds = %111, %92
  %105 = load i32, ptr %6, align 4
  %106 = icmp slt i32 %105, 100
  br i1 %106, label %107, label %114

107:                                              ; preds = %104
  %108 = load i32, ptr %6, align 4
  %109 = sext i32 %108 to i64
  %110 = getelementptr inbounds [100 x i32], ptr @file, i64 0, i64 %109
  store i32 101, ptr %110, align 4
  br label %111

111:                                              ; preds = %107
  %112 = load i32, ptr %6, align 4
  %113 = add nsw i32 %112, 1
  store i32 %113, ptr %6, align 4
  br label %104, !llvm.loop !8

114:                                              ; preds = %104
  store i32 0, ptr %6, align 4
  br label %115

115:                                              ; preds = %125, %114
  %116 = load i32, ptr %6, align 4
  %117 = icmp slt i32 %116, 199
  br i1 %117, label %118, label %128

118:                                              ; preds = %115
  %119 = load i32, ptr %6, align 4
  %120 = sext i32 %119 to i64
  %121 = getelementptr inbounds [199 x i32], ptr @bakdiag, i64 0, i64 %120
  store i32 101, ptr %121, align 4
  %122 = load i32, ptr %6, align 4
  %123 = sext i32 %122 to i64
  %124 = getelementptr inbounds [199 x i32], ptr @fordiag, i64 0, i64 %123
  store i32 101, ptr %124, align 4
  br label %125

125:                                              ; preds = %118
  %126 = load i32, ptr %6, align 4
  %127 = add nsw i32 %126, 1
  store i32 %127, ptr %6, align 4
  br label %115, !llvm.loop !9

128:                                              ; preds = %115
  call void @find(i32 noundef 0)
  %129 = load i32, ptr @printing, align 4
  %130 = icmp ne i32 %129, 0
  br i1 %130, label %131, label %136

131:                                              ; preds = %128
  %132 = load i64, ptr @solutions, align 8
  %133 = icmp ne i64 %132, 0
  br i1 %133, label %134, label %136

134:                                              ; preds = %131
  %135 = call i32 @putchar(i32 noundef 10)
  br label %136

136:                                              ; preds = %134, %131, %128
  %137 = load i64, ptr @solutions, align 8
  %138 = icmp eq i64 %137, 1
  br i1 %138, label %139, label %141

139:                                              ; preds = %136
  %140 = call i32 (ptr, ...) @printf(ptr noundef @.str.10)
  br label %144

141:                                              ; preds = %136
  %142 = load i64, ptr @solutions, align 8
  %143 = call i32 (ptr, ...) @printf(ptr noundef @.str.11, i64 noundef %142)
  br label %144

144:                                              ; preds = %141, %139
  call void @exit(i32 noundef 0) #5
  unreachable
}

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #1

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #2

; Function Attrs: nounwind
declare i32 @__isoc99_sscanf(ptr noundef, ptr noundef, ...) #1

declare i32 @printf(ptr noundef, ...) #3

declare i32 @fflush(ptr noundef) #3

; Function Attrs: noinline nounwind uwtable
define dso_local void @find(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  store i32 %0, ptr %2, align 4
  %7 = load i32, ptr %2, align 4
  %8 = load i32, ptr @queens, align 4
  %9 = icmp eq i32 %7, %8
  br i1 %9, label %10, label %21

10:                                               ; preds = %1
  %11 = load i64, ptr @solutions, align 8
  %12 = add i64 %11, 1
  store i64 %12, ptr @solutions, align 8
  %13 = load i32, ptr @printing, align 4
  %14 = icmp ne i32 %13, 0
  br i1 %14, label %15, label %16

15:                                               ; preds = %10
  call void @pboard()
  br label %16

16:                                               ; preds = %15, %10
  %17 = load i32, ptr @findall, align 4
  %18 = icmp ne i32 %17, 0
  br i1 %18, label %20, label %19

19:                                               ; preds = %16
  call void @exit(i32 noundef 0) #5
  unreachable

20:                                               ; preds = %16
  br label %75

21:                                               ; preds = %1
  store i32 0, ptr %3, align 4
  store ptr @file, ptr %4, align 8
  %22 = load i32, ptr %2, align 4
  %23 = sext i32 %22 to i64
  %24 = getelementptr inbounds [199 x i32], ptr @fordiag, i64 0, i64 %23
  store ptr %24, ptr %5, align 8
  %25 = load i32, ptr %2, align 4
  %26 = load i32, ptr @files, align 4
  %27 = add nsw i32 %25, %26
  %28 = sub nsw i32 %27, 1
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [199 x i32], ptr @bakdiag, i64 0, i64 %29
  store ptr %30, ptr %6, align 8
  br label %31

31:                                               ; preds = %65, %21
  %32 = load i32, ptr %3, align 4
  %33 = load i32, ptr @files, align 4
  %34 = icmp slt i32 %32, %33
  br i1 %34, label %35, label %74

35:                                               ; preds = %31
  %36 = load ptr, ptr %4, align 8
  %37 = load i32, ptr %36, align 4
  %38 = load i32, ptr %2, align 4
  %39 = icmp sge i32 %37, %38
  br i1 %39, label %40, label %64

40:                                               ; preds = %35
  %41 = load ptr, ptr %5, align 8
  %42 = load i32, ptr %41, align 4
  %43 = load i32, ptr %2, align 4
  %44 = icmp sge i32 %42, %43
  br i1 %44, label %45, label %64

45:                                               ; preds = %40
  %46 = load ptr, ptr %6, align 8
  %47 = load i32, ptr %46, align 4
  %48 = load i32, ptr %2, align 4
  %49 = icmp sge i32 %47, %48
  br i1 %49, label %50, label %64

50:                                               ; preds = %45
  %51 = load i32, ptr %3, align 4
  %52 = load i32, ptr %2, align 4
  %53 = sext i32 %52 to i64
  %54 = getelementptr inbounds [100 x i32], ptr @queen, i64 0, i64 %53
  store i32 %51, ptr %54, align 4
  %55 = load i32, ptr %2, align 4
  %56 = load ptr, ptr %6, align 8
  store i32 %55, ptr %56, align 4
  %57 = load ptr, ptr %5, align 8
  store i32 %55, ptr %57, align 4
  %58 = load ptr, ptr %4, align 8
  store i32 %55, ptr %58, align 4
  %59 = load i32, ptr %2, align 4
  %60 = add nsw i32 %59, 1
  call void @find(i32 noundef %60)
  %61 = load ptr, ptr %6, align 8
  store i32 101, ptr %61, align 4
  %62 = load ptr, ptr %5, align 8
  store i32 101, ptr %62, align 4
  %63 = load ptr, ptr %4, align 8
  store i32 101, ptr %63, align 4
  br label %64

64:                                               ; preds = %50, %45, %40, %35
  br label %65

65:                                               ; preds = %64
  %66 = load i32, ptr %3, align 4
  %67 = add nsw i32 %66, 1
  store i32 %67, ptr %3, align 4
  %68 = load ptr, ptr %4, align 8
  %69 = getelementptr inbounds nuw i32, ptr %68, i32 1
  store ptr %69, ptr %4, align 8
  %70 = load ptr, ptr %5, align 8
  %71 = getelementptr inbounds nuw i32, ptr %70, i32 1
  store ptr %71, ptr %5, align 8
  %72 = load ptr, ptr %6, align 8
  %73 = getelementptr inbounds i32, ptr %72, i32 -1
  store ptr %73, ptr %6, align 8
  br label %31, !llvm.loop !10

74:                                               ; preds = %31
  br label %75

75:                                               ; preds = %74, %20
  ret void
}

declare i32 @putchar(i32 noundef) #3

; Function Attrs: noinline nounwind uwtable
define dso_local void @pboard() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = load i32, ptr @findall, align 4
  %4 = icmp ne i32 %3, 0
  br i1 %4, label %5, label %8

5:                                                ; preds = %0
  %6 = load i64, ptr @solutions, align 8
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i64 noundef %6)
  br label %8

8:                                                ; preds = %5, %0
  store i32 0, ptr %1, align 4
  br label %9

9:                                                ; preds = %36, %8
  %10 = load i32, ptr %1, align 4
  %11 = load i32, ptr @ranks, align 4
  %12 = icmp slt i32 %10, %11
  br i1 %12, label %13, label %39

13:                                               ; preds = %9
  store i32 0, ptr %2, align 4
  br label %14

14:                                               ; preds = %31, %13
  %15 = load i32, ptr %2, align 4
  %16 = load i32, ptr @files, align 4
  %17 = icmp slt i32 %15, %16
  br i1 %17, label %18, label %34

18:                                               ; preds = %14
  %19 = call i32 @putchar(i32 noundef 32)
  %20 = load i32, ptr %2, align 4
  %21 = load i32, ptr %1, align 4
  %22 = sext i32 %21 to i64
  %23 = getelementptr inbounds [100 x i32], ptr @queen, i64 0, i64 %22
  %24 = load i32, ptr %23, align 4
  %25 = icmp eq i32 %20, %24
  br i1 %25, label %26, label %28

26:                                               ; preds = %18
  %27 = call i32 @putchar(i32 noundef 81)
  br label %30

28:                                               ; preds = %18
  %29 = call i32 @putchar(i32 noundef 45)
  br label %30

30:                                               ; preds = %28, %26
  br label %31

31:                                               ; preds = %30
  %32 = load i32, ptr %2, align 4
  %33 = add nsw i32 %32, 1
  store i32 %33, ptr %2, align 4
  br label %14, !llvm.loop !11

34:                                               ; preds = %14
  %35 = call i32 @putchar(i32 noundef 10)
  br label %36

36:                                               ; preds = %34
  %37 = load i32, ptr %1, align 4
  %38 = add nsw i32 %37, 1
  store i32 %38, ptr %1, align 4
  br label %9, !llvm.loop !12

39:                                               ; preds = %9
  %40 = load ptr, ptr @stdout, align 8
  %41 = call i32 @fflush(ptr noundef %40)
  ret void
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { noreturn nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }
attributes #5 = { noreturn nounwind }

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
!11 = distinct !{!11, !6}
!12 = distinct !{!12, !6}
