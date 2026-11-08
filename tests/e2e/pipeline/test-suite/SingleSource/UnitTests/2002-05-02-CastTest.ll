; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-CastTest.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-CastTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-05-02-CastTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [23 x i8] c"ubc0 = '%c'\09   [0x%x]\0A\00", align 1
@.str.1 = private unnamed_addr constant [21 x i8] c"ubs0 = %u\09   [0x%x]\0A\00", align 1
@.str.2 = private unnamed_addr constant [21 x i8] c"ubs1 = %u\09   [0x%x]\0A\00", align 1
@.str.3 = private unnamed_addr constant [21 x i8] c"bs0  = %d\09   [0x%x]\0A\00", align 1
@.str.4 = private unnamed_addr constant [21 x i8] c"bs1  = %d\09   [0x%x]\0A\00", align 1
@.str.5 = private unnamed_addr constant [23 x i8] c"c1   = '%c'\09   [0x%x]\0A\00", align 1
@.str.6 = private unnamed_addr constant [21 x i8] c"s1   = %d\09   [0x%x]\0A\00", align 1
@.str.7 = private unnamed_addr constant [23 x i8] c"uc2  = '%c'\09   [0x%x]\0A\00", align 1
@.str.8 = private unnamed_addr constant [21 x i8] c"us2  = %u\09   [0x%x]\0A\00", align 1
@.str.9 = private unnamed_addr constant [23 x i8] c"ic3  = '%c'\09   [0x%x]\0A\00", align 1
@.str.10 = private unnamed_addr constant [21 x i8] c"is3  = %d\09   [0x%x]\0A\00", align 1
@.str.11 = private unnamed_addr constant [21 x i8] c"is4  = %d\09   [0x%x]\0A\00", align 1
@.str.12 = private unnamed_addr constant [21 x i8] c"is5  = %d\09   [0x%x]\0A\00", align 1
@.str.13 = private unnamed_addr constant [23 x i8] c"uic4 = '%c'\09   [0x%x]\0A\00", align 1
@.str.14 = private unnamed_addr constant [19 x i8] c"uis4 = %u  [0x%x]\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i8, align 1
  %7 = alloca i16, align 2
  %8 = alloca i8, align 1
  %9 = alloca i8, align 1
  %10 = alloca i8, align 1
  %11 = alloca i8, align 1
  %12 = alloca i8, align 1
  %13 = alloca i8, align 1
  %14 = alloca i16, align 2
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  %18 = alloca i32, align 4
  %19 = alloca i32, align 4
  %20 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %21 = load i32, ptr %4, align 4, !tbaa !9
  %22 = icmp sge i32 %21, 2
  br i1 %22, label %23, label %28

23:                                               ; preds = %2
  %24 = load ptr, ptr %5, align 8, !tbaa !10
  %25 = getelementptr inbounds ptr, ptr %24, i64 1
  %26 = load ptr, ptr %25, align 8, !tbaa !14
  %27 = call i32 @atoi(ptr noundef %26) #6
  br label %29

28:                                               ; preds = %2
  br label %29

29:                                               ; preds = %28, %23
  %30 = phi i32 [ %27, %23 ], [ 100, %28 ]
  %31 = trunc i32 %30 to i8
  store i8 %31, ptr %6, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %7) #5
  %32 = load i32, ptr %4, align 4, !tbaa !9
  %33 = icmp sge i32 %32, 3
  br i1 %33, label %34, label %39

34:                                               ; preds = %29
  %35 = load ptr, ptr %5, align 8, !tbaa !10
  %36 = getelementptr inbounds ptr, ptr %35, i64 2
  %37 = load ptr, ptr %36, align 8, !tbaa !14
  %38 = call i32 @atoi(ptr noundef %37) #6
  br label %40

39:                                               ; preds = %29
  br label %40

40:                                               ; preds = %39, %34
  %41 = phi i32 [ %38, %34 ], [ -769, %39 ]
  %42 = trunc i32 %41 to i16
  store i16 %42, ptr %7, align 2, !tbaa !17
  call void @llvm.lifetime.start.p0(ptr %8) #5
  %43 = load i8, ptr %6, align 1, !tbaa !16
  store i8 %43, ptr %8, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %9) #5
  %44 = load i16, ptr %7, align 2, !tbaa !17
  %45 = trunc i16 %44 to i8
  store i8 %45, ptr %9, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %10) #5
  %46 = load i8, ptr %9, align 1, !tbaa !16
  %47 = zext i8 %46 to i32
  %48 = add nsw i32 %47, 1
  %49 = trunc i32 %48 to i8
  store i8 %49, ptr %10, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %11) #5
  %50 = load i8, ptr %9, align 1, !tbaa !16
  store i8 %50, ptr %11, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %12) #5
  %51 = load i8, ptr %9, align 1, !tbaa !16
  %52 = zext i8 %51 to i32
  %53 = add i32 %52, 1
  %54 = trunc i32 %53 to i8
  store i8 %54, ptr %12, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %13) #5
  %55 = load i8, ptr %6, align 1, !tbaa !16
  store i8 %55, ptr %13, align 1, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %14) #5
  %56 = load i16, ptr %7, align 2, !tbaa !17
  store i16 %56, ptr %14, align 2, !tbaa !17
  call void @llvm.lifetime.start.p0(ptr %15) #5
  %57 = load i8, ptr %6, align 1, !tbaa !16
  %58 = sext i8 %57 to i32
  store i32 %58, ptr %15, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %16) #5
  %59 = load i16, ptr %7, align 2, !tbaa !17
  %60 = sext i16 %59 to i32
  store i32 %60, ptr %16, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %17) #5
  %61 = load i8, ptr %9, align 1, !tbaa !16
  %62 = zext i8 %61 to i32
  %63 = add nsw i32 %62, 1
  store i32 %63, ptr %17, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %18) #5
  %64 = load i8, ptr %11, align 1, !tbaa !16
  %65 = sext i8 %64 to i32
  %66 = add nsw i32 %65, 1
  store i32 %66, ptr %18, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %19) #5
  %67 = load i8, ptr %6, align 1, !tbaa !16
  %68 = sext i8 %67 to i32
  store i32 %68, ptr %19, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %20) #5
  %69 = load i16, ptr %7, align 2, !tbaa !17
  %70 = sext i16 %69 to i32
  store i32 %70, ptr %20, align 4, !tbaa !9
  %71 = load i8, ptr %8, align 1, !tbaa !16
  %72 = zext i8 %71 to i32
  %73 = load i8, ptr %8, align 1, !tbaa !16
  %74 = zext i8 %73 to i32
  %75 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %72, i32 noundef %74)
  %76 = load i8, ptr %9, align 1, !tbaa !16
  %77 = zext i8 %76 to i32
  %78 = load i8, ptr %9, align 1, !tbaa !16
  %79 = zext i8 %78 to i32
  %80 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %77, i32 noundef %79)
  %81 = load i8, ptr %10, align 1, !tbaa !16
  %82 = zext i8 %81 to i32
  %83 = load i8, ptr %10, align 1, !tbaa !16
  %84 = zext i8 %83 to i32
  %85 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %82, i32 noundef %84)
  %86 = load i8, ptr %11, align 1, !tbaa !16
  %87 = sext i8 %86 to i32
  %88 = load i8, ptr %11, align 1, !tbaa !16
  %89 = sext i8 %88 to i32
  %90 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %87, i32 noundef %89)
  %91 = load i8, ptr %12, align 1, !tbaa !16
  %92 = sext i8 %91 to i32
  %93 = load i8, ptr %12, align 1, !tbaa !16
  %94 = sext i8 %93 to i32
  %95 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %92, i32 noundef %94)
  %96 = load i8, ptr %6, align 1, !tbaa !16
  %97 = sext i8 %96 to i32
  %98 = load i8, ptr %6, align 1, !tbaa !16
  %99 = sext i8 %98 to i32
  %100 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %97, i32 noundef %99)
  %101 = load i16, ptr %7, align 2, !tbaa !17
  %102 = sext i16 %101 to i32
  %103 = load i16, ptr %7, align 2, !tbaa !17
  %104 = sext i16 %103 to i32
  %105 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %102, i32 noundef %104)
  %106 = load i8, ptr %13, align 1, !tbaa !16
  %107 = zext i8 %106 to i32
  %108 = load i8, ptr %13, align 1, !tbaa !16
  %109 = zext i8 %108 to i32
  %110 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %107, i32 noundef %109)
  %111 = load i16, ptr %14, align 2, !tbaa !17
  %112 = zext i16 %111 to i32
  %113 = load i16, ptr %14, align 2, !tbaa !17
  %114 = zext i16 %113 to i32
  %115 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef %112, i32 noundef %114)
  %116 = load i32, ptr %15, align 4, !tbaa !9
  %117 = load i32, ptr %15, align 4, !tbaa !9
  %118 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef %116, i32 noundef %117)
  %119 = load i32, ptr %16, align 4, !tbaa !9
  %120 = load i32, ptr %16, align 4, !tbaa !9
  %121 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, i32 noundef %119, i32 noundef %120)
  %122 = load i32, ptr %17, align 4, !tbaa !9
  %123 = load i32, ptr %17, align 4, !tbaa !9
  %124 = call i32 (ptr, ...) @printf(ptr noundef @.str.11, i32 noundef %122, i32 noundef %123)
  %125 = load i32, ptr %18, align 4, !tbaa !9
  %126 = load i32, ptr %18, align 4, !tbaa !9
  %127 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %125, i32 noundef %126)
  %128 = load i32, ptr %19, align 4, !tbaa !9
  %129 = load i32, ptr %19, align 4, !tbaa !9
  %130 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, i32 noundef %128, i32 noundef %129)
  %131 = load i32, ptr %20, align 4, !tbaa !9
  %132 = load i32, ptr %20, align 4, !tbaa !9
  %133 = call i32 (ptr, ...) @printf(ptr noundef @.str.14, i32 noundef %131, i32 noundef %132)
  call void @llvm.lifetime.end.p0(ptr %20) #5
  call void @llvm.lifetime.end.p0(ptr %19) #5
  call void @llvm.lifetime.end.p0(ptr %18) #5
  call void @llvm.lifetime.end.p0(ptr %17) #5
  call void @llvm.lifetime.end.p0(ptr %16) #5
  call void @llvm.lifetime.end.p0(ptr %15) #5
  call void @llvm.lifetime.end.p0(ptr %14) #5
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #5
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = !{!11, !11, i64 0}
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 omnipotent char", !13, i64 0}
!16 = !{!7, !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"short", !7, i64 0}
