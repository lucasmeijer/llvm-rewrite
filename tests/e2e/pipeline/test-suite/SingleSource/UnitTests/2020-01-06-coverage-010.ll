; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-010.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-010.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-010.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@v = dso_local global i32 0, align 4
@w = dso_local global i32 0, align 4
@z = dso_local global i32 0, align 4
@y = dso_local global i32 0, align 4
@p = dso_local global ptr null, align 8
@x = dso_local global i32 0, align 4
@e = dso_local global i32 0, align 4
@c = dso_local global i8 0, align 1
@f = dso_local global i32 0, align 4
@d = dso_local global i32 0, align 4
@b = dso_local global i32 0, align 4
@a = dso_local global ptr null, align 8
@.str = private unnamed_addr constant [8 x i8] c"b = %i\0A\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"c = %hhi\0A\00", align 1
@.str.2 = private unnamed_addr constant [8 x i8] c"d = %i\0A\00", align 1
@.str.3 = private unnamed_addr constant [8 x i8] c"x = %i\0A\00", align 1
@.str.4 = private unnamed_addr constant [8 x i8] c"e = %i\0A\00", align 1
@.str.5 = private unnamed_addr constant [8 x i8] c"y = %i\0A\00", align 1
@.str.6 = private unnamed_addr constant [8 x i8] c"z = %i\0A\00", align 1
@.str.7 = private unnamed_addr constant [8 x i8] c"v = %i\0A\00", align 1
@.str.8 = private unnamed_addr constant [8 x i8] c"f = %i\0A\00", align 1
@.str.9 = private unnamed_addr constant [8 x i8] c"w = %i\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @k() #0 {
  %1 = call i32 @j()
  store i32 %1, ptr @v, align 4, !tbaa !9
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i8, align 1
  %7 = alloca i8, align 1
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i8, align 1
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  call void @llvm.lifetime.start.p0(ptr %9) #3
  call void @llvm.lifetime.start.p0(ptr %10) #3
  call void @llvm.lifetime.start.p0(ptr %11) #3
  call void @llvm.lifetime.start.p0(ptr %12) #3
  call void @llvm.lifetime.start.p0(ptr %13) #3
  call void @llvm.lifetime.start.p0(ptr %14) #3
  call void @llvm.lifetime.start.p0(ptr %15) #3
  store i32 0, ptr %14, align 4, !tbaa !9
  store i32 0, ptr %13, align 4, !tbaa !9
  store i32 0, ptr %12, align 4, !tbaa !9
  store i32 0, ptr %11, align 4, !tbaa !9
  store i8 0, ptr %10, align 1, !tbaa !10
  store i32 0, ptr %9, align 4, !tbaa !9
  store i32 0, ptr %8, align 4, !tbaa !9
  store i8 5, ptr %6, align 1, !tbaa !10
  store i32 0, ptr %5, align 4, !tbaa !9
  store i32 0, ptr %4, align 4, !tbaa !9
  store i32 0, ptr %3, align 4, !tbaa !9
  store i32 0, ptr %2, align 4, !tbaa !9
  %16 = load i32, ptr %14, align 4, !tbaa !9
  store i32 %16, ptr %15, align 4, !tbaa !9
  %17 = load i8, ptr %6, align 1, !tbaa !10
  store i8 %17, ptr %7, align 1, !tbaa !10
  %18 = load i32, ptr %2, align 4, !tbaa !9
  store i32 %18, ptr @v, align 4, !tbaa !9
  %19 = load i32, ptr %3, align 4, !tbaa !9
  store i32 %19, ptr @w, align 4, !tbaa !9
  %20 = load i32, ptr %4, align 4, !tbaa !9
  store i32 %20, ptr @z, align 4, !tbaa !9
  %21 = load i32, ptr %5, align 4, !tbaa !9
  store i32 %21, ptr @y, align 4, !tbaa !9
  store ptr %7, ptr @p, align 8, !tbaa !11
  %22 = load i32, ptr %8, align 4, !tbaa !9
  store i32 %22, ptr @x, align 4, !tbaa !9
  %23 = load i32, ptr %9, align 4, !tbaa !9
  store volatile i32 %23, ptr @e, align 4, !tbaa !9
  %24 = load i8, ptr %10, align 1, !tbaa !10
  store i8 %24, ptr @c, align 1, !tbaa !10
  %25 = load i32, ptr %11, align 4, !tbaa !9
  store i32 %25, ptr @f, align 4, !tbaa !9
  %26 = load i32, ptr %12, align 4, !tbaa !9
  store i32 %26, ptr @d, align 4, !tbaa !9
  %27 = load i32, ptr %13, align 4, !tbaa !9
  store i32 %27, ptr @b, align 4, !tbaa !9
  store ptr %15, ptr @a, align 8, !tbaa !14
  call void @k()
  %28 = load i32, ptr @b, align 4, !tbaa !9
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %28)
  %30 = load i8, ptr @c, align 1, !tbaa !10
  %31 = sext i8 %30 to i32
  %32 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %31)
  %33 = load i32, ptr @d, align 4, !tbaa !9
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %33)
  %35 = load i32, ptr @x, align 4, !tbaa !9
  %36 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %35)
  %37 = load volatile i32, ptr @e, align 4, !tbaa !9
  %38 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %37)
  %39 = load i32, ptr @y, align 4, !tbaa !9
  %40 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %39)
  %41 = load i32, ptr @z, align 4, !tbaa !9
  %42 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %41)
  %43 = load i32, ptr @v, align 4, !tbaa !9
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %43)
  %45 = load i32, ptr @f, align 4, !tbaa !9
  %46 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef %45)
  %47 = load i32, ptr @w, align 4, !tbaa !9
  %48 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef %47)
  call void @llvm.lifetime.end.p0(ptr %15) #3
  call void @llvm.lifetime.end.p0(ptr %14) #3
  call void @llvm.lifetime.end.p0(ptr %13) #3
  call void @llvm.lifetime.end.p0(ptr %12) #3
  call void @llvm.lifetime.end.p0(ptr %11) #3
  call void @llvm.lifetime.end.p0(ptr %10) #3
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

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @j() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  call void @llvm.lifetime.start.p0(ptr %1) #3
  store i32 5, ptr %1, align 4, !tbaa !9
  %4 = load i32, ptr %1, align 4, !tbaa !9
  store i32 %4, ptr @x, align 4, !tbaa !9
  br label %5

5:                                                ; preds = %27, %0
  %6 = load i32, ptr @b, align 4, !tbaa !9
  %7 = icmp ne i32 %6, 0
  br i1 %7, label %8, label %29

8:                                                ; preds = %5
  store i32 0, ptr @f, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %24, %8
  %10 = load i32, ptr @f, align 4, !tbaa !9
  %11 = icmp sle i32 %10, 9
  br i1 %11, label %12, label %27

12:                                               ; preds = %9
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store ptr %1, ptr %2, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store ptr @c, ptr %3, align 8, !tbaa !11
  %13 = load ptr, ptr %3, align 8, !tbaa !11
  store ptr %13, ptr @p, align 8, !tbaa !11
  %14 = load ptr, ptr %2, align 8, !tbaa !14
  %15 = load i32, ptr %14, align 4, !tbaa !9
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %14, align 4, !tbaa !9
  %17 = icmp ne i32 %15, 0
  br i1 %17, label %18, label %20

18:                                               ; preds = %12
  %19 = load ptr, ptr %3, align 8, !tbaa !11
  store i8 0, ptr %19, align 1, !tbaa !10
  br label %20

20:                                               ; preds = %18, %12
  %21 = phi i1 [ false, %12 ], [ false, %18 ]
  %22 = zext i1 %21 to i32
  store i32 %22, ptr @y, align 4, !tbaa !9
  %23 = load volatile i32, ptr @e, align 4, !tbaa !9
  store i32 %23, ptr @z, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  br label %24

24:                                               ; preds = %20
  %25 = load i32, ptr @f, align 4, !tbaa !9
  %26 = add nsw i32 %25, 1
  store i32 %26, ptr @f, align 4, !tbaa !9
  br label %9, !llvm.loop !16

27:                                               ; preds = %9
  %28 = load ptr, ptr @a, align 8, !tbaa !14
  store i32 0, ptr %28, align 4, !tbaa !9
  br label %5, !llvm.loop !18

29:                                               ; preds = %5
  %30 = load i32, ptr @d, align 4, !tbaa !9
  store i32 %30, ptr @w, align 4, !tbaa !9
  %31 = load i32, ptr @w, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %1) #3
  ret i32 %31
}

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
!10 = !{!7, !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 omnipotent char", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 int", !13, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
