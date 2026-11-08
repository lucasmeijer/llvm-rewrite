; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/globalrefs.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/globalrefs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/globalrefs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.test = type { i32, %struct.anon, i32, ptr }
%struct.anon = type { i32, i32 }

@TestArray = dso_local global [10 x %struct.test] zeroinitializer, align 16
@TestArrayPtr = dso_local global ptr getelementptr (i8, ptr @TestArray, i64 72), align 8
@Test1 = dso_local global %struct.test zeroinitializer, align 8
@Aptr = dso_local global ptr @Test1, align 8
@Yptr = dso_local global ptr getelementptr (i8, ptr @Test1, i64 8), align 8
@NextPtr = dso_local global ptr getelementptr (i8, ptr @Test1, i64 16), align 8
@.str = private unnamed_addr constant [4 x i8] c" %d\00", align 1
@.str.1 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str.2 = private unnamed_addr constant [35 x i8] c"&TestArray[3] - TestArray = 0x%lx\0A\00", align 1
@.str.3 = private unnamed_addr constant [30 x i8] c"Xptr - Aptr          = 0x%lx\0A\00", align 1
@.str.4 = private unnamed_addr constant [31 x i8] c"NextPtr - Xptr       = 0x%lx\0A\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @printdiff(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8
  store ptr %1, ptr %4, align 8
  %5 = load ptr, ptr %3, align 8
  %6 = ptrtoint ptr %5 to i64
  %7 = load ptr, ptr %4, align 8
  %8 = ptrtoint ptr %7 to i64
  %9 = sub i64 %6, %8
  %10 = trunc i64 %9 to i32
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %10)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca i64, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4
  store ptr %1, ptr %5, align 8
  call void @printdiff(ptr noundef getelementptr inbounds nuw (i8, ptr @Test1, i64 8), ptr noundef @Test1)
  call void @printdiff(ptr noundef getelementptr inbounds nuw (i8, ptr @Test1, i64 16), ptr noundef getelementptr inbounds nuw (i8, ptr @Test1, i64 8))
  %10 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  store i64 72, ptr %6, align 8
  store i64 8, ptr %8, align 8
  store i64 8, ptr %9, align 8
  %11 = load i64, ptr %6, align 8
  %12 = load i64, ptr %6, align 8
  %13 = udiv i64 %12, 24
  %14 = mul i64 %13, 24
  %15 = icmp ne i64 %11, %14
  br i1 %15, label %16, label %17

16:                                               ; preds = %2
  store i32 1, ptr %3, align 4
  br label %52

17:                                               ; preds = %2
  %18 = load i64, ptr %6, align 8
  %19 = udiv i64 %18, 24
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %19)
  %21 = load i64, ptr %8, align 8
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %21)
  %23 = load i64, ptr %9, align 8
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i64 noundef %23)
  %25 = load ptr, ptr @TestArrayPtr, align 8
  %26 = ptrtoint ptr %25 to i64
  %27 = sub i64 %26, ptrtoint (ptr @TestArray to i64)
  store i64 %27, ptr %6, align 8
  %28 = load ptr, ptr @Yptr, align 8
  %29 = ptrtoint ptr %28 to i64
  %30 = load ptr, ptr @Aptr, align 8
  %31 = ptrtoint ptr %30 to i64
  %32 = sub i64 %29, %31
  store i64 %32, ptr %8, align 8
  %33 = load ptr, ptr @NextPtr, align 8
  %34 = ptrtoint ptr %33 to i64
  %35 = load ptr, ptr @Yptr, align 8
  %36 = ptrtoint ptr %35 to i64
  %37 = sub i64 %34, %36
  store i64 %37, ptr %9, align 8
  %38 = load i64, ptr %6, align 8
  %39 = load i64, ptr %6, align 8
  %40 = udiv i64 %39, 24
  %41 = mul i64 %40, 24
  %42 = icmp ne i64 %38, %41
  br i1 %42, label %43, label %44

43:                                               ; preds = %17
  store i32 1, ptr %3, align 4
  br label %52

44:                                               ; preds = %17
  %45 = load i64, ptr %6, align 8
  %46 = udiv i64 %45, 24
  %47 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %46)
  %48 = load i64, ptr %8, align 8
  %49 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %48)
  %50 = load i64, ptr %9, align 8
  %51 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i64 noundef %50)
  store i32 0, ptr %3, align 4
  br label %52

52:                                               ; preds = %44, %43, %16
  %53 = load i32, ptr %3, align 4
  ret i32 %53
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
