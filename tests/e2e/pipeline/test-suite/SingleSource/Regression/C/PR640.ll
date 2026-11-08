; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/PR640.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@.str = private unnamed_addr constant [7 x i8] c"ERROR\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"All done.\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  %6 = call i32 @test_stdarg(i32 noundef 1)
  %7 = icmp ne i32 %6, 1
  br i1 %7, label %8, label %10

8:                                                ; preds = %2
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  store i32 1, ptr %3, align 4
  br label %12

10:                                               ; preds = %2
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str.1)
  store i32 0, ptr %3, align 4
  br label %12

12:                                               ; preds = %10, %8
  %13 = load i32, ptr %3, align 4
  ret i32 %13
}

; Function Attrs: nounwind uwtable
define internal i32 @test_stdarg(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i8, align 1
  %5 = alloca i8, align 1
  %6 = alloca i32, align 4
  store i32 %0, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i8 1, ptr %4, align 1, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i8 2, ptr %5, align 1, !tbaa !14
  %7 = load i8, ptr %4, align 1, !tbaa !14
  %8 = sext i8 %7 to i32
  %9 = load i8, ptr %5, align 1, !tbaa !14
  %10 = sext i8 %9 to i32
  %11 = call i32 (ptr, ...) @test_stdarg_va(ptr noundef %3, i32 noundef %8, i64 noundef 1981891429, i32 noundef %10, ptr noundef %3)
  %12 = icmp ne i32 %11, 1
  br i1 %12, label %13, label %14

13:                                               ; preds = %1
  store i32 0, ptr %2, align 4
  store i32 1, ptr %6, align 4
  br label %25

14:                                               ; preds = %1
  %15 = load i8, ptr %4, align 1, !tbaa !14
  %16 = sext i8 %15 to i32
  %17 = load i8, ptr %5, align 1, !tbaa !14
  %18 = sext i8 %17 to i32
  %19 = call i32 (ptr, ...) @test_stdarg_builtin_va(ptr noundef %3, i32 noundef %16, i64 noundef 1981891433, i32 noundef %18, ptr noundef %3)
  %20 = icmp ne i32 %19, 1
  br i1 %20, label %21, label %22

21:                                               ; preds = %14
  store i32 0, ptr %2, align 4
  store i32 1, ptr %6, align 4
  br label %25

22:                                               ; preds = %14
  %23 = load i32, ptr %3, align 4, !tbaa !9
  %24 = and i32 %23, 1
  store i32 %24, ptr %2, align 4
  store i32 1, ptr %6, align 4
  br label %25

25:                                               ; preds = %22, %21, %13
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  %26 = load i32, ptr %2, align 4
  ret i32 %26
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nounwind uwtable
define internal i32 @test_stdarg_va(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  call void @llvm.lifetime.start.p0(ptr %5) #4
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  %8 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %8)
  %9 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %10 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 0
  %11 = load i32, ptr %10, align 16
  %12 = icmp ule i32 %11, 40
  br i1 %12, label %13, label %18

13:                                               ; preds = %1
  %14 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 3
  %15 = load ptr, ptr %14, align 16
  %16 = getelementptr i8, ptr %15, i32 %11
  %17 = add i32 %11, 8
  store i32 %17, ptr %10, align 16
  br label %22

18:                                               ; preds = %1
  %19 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 2
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr i8, ptr %20, i32 8
  store ptr %21, ptr %19, align 8
  br label %22

22:                                               ; preds = %18, %13
  %23 = phi ptr [ %16, %13 ], [ %20, %18 ]
  %24 = load i32, ptr %23, align 4, !tbaa !9
  store i32 %24, ptr %5, align 4, !tbaa !9
  %25 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %26 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 0
  %27 = load i32, ptr %26, align 16
  %28 = icmp ule i32 %27, 40
  br i1 %28, label %29, label %34

29:                                               ; preds = %22
  %30 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 3
  %31 = load ptr, ptr %30, align 16
  %32 = getelementptr i8, ptr %31, i32 %27
  %33 = add i32 %27, 8
  store i32 %33, ptr %26, align 16
  br label %38

34:                                               ; preds = %22
  %35 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 2
  %36 = load ptr, ptr %35, align 8
  %37 = getelementptr i8, ptr %36, i32 8
  store ptr %37, ptr %35, align 8
  br label %38

38:                                               ; preds = %34, %29
  %39 = phi ptr [ %32, %29 ], [ %36, %34 ]
  %40 = load i64, ptr %39, align 8, !tbaa !16
  store i64 %40, ptr %4, align 8, !tbaa !16
  %41 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %42 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 0
  %43 = load i32, ptr %42, align 16
  %44 = icmp ule i32 %43, 40
  br i1 %44, label %45, label %50

45:                                               ; preds = %38
  %46 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 3
  %47 = load ptr, ptr %46, align 16
  %48 = getelementptr i8, ptr %47, i32 %43
  %49 = add i32 %43, 8
  store i32 %49, ptr %42, align 16
  br label %54

50:                                               ; preds = %38
  %51 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 2
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr i8, ptr %52, i32 8
  store ptr %53, ptr %51, align 8
  br label %54

54:                                               ; preds = %50, %45
  %55 = phi ptr [ %48, %45 ], [ %52, %50 ]
  %56 = load i32, ptr %55, align 4, !tbaa !9
  store i32 %56, ptr %6, align 4, !tbaa !9
  %57 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %58 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 0
  %59 = load i32, ptr %58, align 16
  %60 = icmp ule i32 %59, 40
  br i1 %60, label %61, label %66

61:                                               ; preds = %54
  %62 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 3
  %63 = load ptr, ptr %62, align 16
  %64 = getelementptr i8, ptr %63, i32 %59
  %65 = add i32 %59, 8
  store i32 %65, ptr %58, align 16
  br label %70

66:                                               ; preds = %54
  %67 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 2
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr i8, ptr %68, i32 8
  store ptr %69, ptr %67, align 8
  br label %70

70:                                               ; preds = %66, %61
  %71 = phi ptr [ %64, %61 ], [ %68, %66 ]
  %72 = load ptr, ptr %71, align 8, !tbaa !15
  store ptr %72, ptr %7, align 8, !tbaa !15
  %73 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %73)
  %74 = load ptr, ptr %2, align 8, !tbaa !15
  %75 = load ptr, ptr %7, align 8, !tbaa !15
  %76 = icmp eq ptr %74, %75
  br i1 %76, label %77, label %86

77:                                               ; preds = %70
  %78 = load i32, ptr %5, align 4, !tbaa !9
  %79 = icmp eq i32 %78, 1
  br i1 %79, label %80, label %86

80:                                               ; preds = %77
  %81 = load i64, ptr %4, align 8, !tbaa !16
  %82 = icmp eq i64 %81, 1981891429
  br i1 %82, label %83, label %86

83:                                               ; preds = %80
  %84 = load i32, ptr %6, align 4, !tbaa !9
  %85 = icmp eq i32 %84, 2
  br label %86

86:                                               ; preds = %83, %80, %77, %70
  %87 = phi i1 [ false, %80 ], [ false, %77 ], [ false, %70 ], [ %85, %83 ]
  %88 = zext i1 %87 to i32
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret i32 %88
}

; Function Attrs: nounwind uwtable
define internal i32 @test_stdarg_builtin_va(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  call void @llvm.lifetime.start.p0(ptr %5) #4
  call void @llvm.lifetime.start.p0(ptr %6) #4
  call void @llvm.lifetime.start.p0(ptr %7) #4
  %8 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %8)
  %9 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %10 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 0
  %11 = load i32, ptr %10, align 16
  %12 = icmp ule i32 %11, 40
  br i1 %12, label %13, label %18

13:                                               ; preds = %1
  %14 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 3
  %15 = load ptr, ptr %14, align 16
  %16 = getelementptr i8, ptr %15, i32 %11
  %17 = add i32 %11, 8
  store i32 %17, ptr %10, align 16
  br label %22

18:                                               ; preds = %1
  %19 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %9, i32 0, i32 2
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr i8, ptr %20, i32 8
  store ptr %21, ptr %19, align 8
  br label %22

22:                                               ; preds = %18, %13
  %23 = phi ptr [ %16, %13 ], [ %20, %18 ]
  %24 = load i32, ptr %23, align 4, !tbaa !9
  store i32 %24, ptr %5, align 4, !tbaa !9
  %25 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %26 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 0
  %27 = load i32, ptr %26, align 16
  %28 = icmp ule i32 %27, 40
  br i1 %28, label %29, label %34

29:                                               ; preds = %22
  %30 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 3
  %31 = load ptr, ptr %30, align 16
  %32 = getelementptr i8, ptr %31, i32 %27
  %33 = add i32 %27, 8
  store i32 %33, ptr %26, align 16
  br label %38

34:                                               ; preds = %22
  %35 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %25, i32 0, i32 2
  %36 = load ptr, ptr %35, align 8
  %37 = getelementptr i8, ptr %36, i32 8
  store ptr %37, ptr %35, align 8
  br label %38

38:                                               ; preds = %34, %29
  %39 = phi ptr [ %32, %29 ], [ %36, %34 ]
  %40 = load i64, ptr %39, align 8, !tbaa !16
  store i64 %40, ptr %4, align 8, !tbaa !16
  %41 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %42 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 0
  %43 = load i32, ptr %42, align 16
  %44 = icmp ule i32 %43, 40
  br i1 %44, label %45, label %50

45:                                               ; preds = %38
  %46 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 3
  %47 = load ptr, ptr %46, align 16
  %48 = getelementptr i8, ptr %47, i32 %43
  %49 = add i32 %43, 8
  store i32 %49, ptr %42, align 16
  br label %54

50:                                               ; preds = %38
  %51 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 2
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr i8, ptr %52, i32 8
  store ptr %53, ptr %51, align 8
  br label %54

54:                                               ; preds = %50, %45
  %55 = phi ptr [ %48, %45 ], [ %52, %50 ]
  %56 = load i32, ptr %55, align 4, !tbaa !9
  store i32 %56, ptr %6, align 4, !tbaa !9
  %57 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %58 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 0
  %59 = load i32, ptr %58, align 16
  %60 = icmp ule i32 %59, 40
  br i1 %60, label %61, label %66

61:                                               ; preds = %54
  %62 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 3
  %63 = load ptr, ptr %62, align 16
  %64 = getelementptr i8, ptr %63, i32 %59
  %65 = add i32 %59, 8
  store i32 %65, ptr %58, align 16
  br label %70

66:                                               ; preds = %54
  %67 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %57, i32 0, i32 2
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr i8, ptr %68, i32 8
  store ptr %69, ptr %67, align 8
  br label %70

70:                                               ; preds = %66, %61
  %71 = phi ptr [ %64, %61 ], [ %68, %66 ]
  %72 = load ptr, ptr %71, align 8, !tbaa !15
  store ptr %72, ptr %7, align 8, !tbaa !15
  %73 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %73)
  %74 = load ptr, ptr %2, align 8, !tbaa !15
  %75 = load ptr, ptr %7, align 8, !tbaa !15
  %76 = icmp eq ptr %74, %75
  br i1 %76, label %77, label %86

77:                                               ; preds = %70
  %78 = load i32, ptr %5, align 4, !tbaa !9
  %79 = icmp eq i32 %78, 1
  br i1 %79, label %80, label %86

80:                                               ; preds = %77
  %81 = load i64, ptr %4, align 8, !tbaa !16
  %82 = icmp eq i64 %81, 1981891433
  br i1 %82, label %83, label %86

83:                                               ; preds = %80
  %84 = load i32, ptr %6, align 4, !tbaa !9
  %85 = icmp eq i32 %84, 2
  br label %86

86:                                               ; preds = %83, %80, %77, %70
  %87 = phi i1 [ false, %80 ], [ false, %77 ], [ false, %70 ], [ %85, %83 ]
  %88 = zext i1 %87 to i32
  call void @llvm.lifetime.end.p0(ptr %7) #4
  call void @llvm.lifetime.end.p0(ptr %6) #4
  call void @llvm.lifetime.end.p0(ptr %5) #4
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret i32 %88
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
attributes #4 = { nounwind }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!7, !7, i64 0}
!15 = !{!13, !13, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long", !7, i64 0}
