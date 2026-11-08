; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-009.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-009.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-009.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@d = dso_local global i8 8, align 1
@e = dso_local constant ptr @d, align 8
@c = dso_local global i16 0, align 2
@g = dso_local global i16 0, align 2
@b = dso_local global i32 0, align 4
@a = dso_local global i32 0, align 4
@h = dso_local global i32 0, align 4
@f = dso_local global ptr null, align 8
@.str = private unnamed_addr constant [8 x i8] c"a = %u\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"b = %u\0A\00", align 1
@.str.2 = private unnamed_addr constant [9 x i8] c"c = %hi\0A\00", align 1
@.str.3 = private unnamed_addr constant [10 x i8] c"d = %hhu\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"g = %hi\0A\00", align 1
@.str.5 = private unnamed_addr constant [8 x i8] c"h = %u\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @i() #0 {
  br label %1

1:                                                ; preds = %34, %0
  %2 = load i16, ptr @c, align 2, !tbaa !9
  %3 = icmp ne i16 %2, 0
  br i1 %3, label %4, label %37

4:                                                ; preds = %1
  store i16 0, ptr @g, align 2, !tbaa !9
  br label %5

5:                                                ; preds = %30, %4
  %6 = load i16, ptr @g, align 2, !tbaa !9
  %7 = sext i16 %6 to i32
  %8 = icmp sle i32 %7, 8
  br i1 %8, label %9, label %33

9:                                                ; preds = %5
  %10 = load i32, ptr @b, align 4, !tbaa !11
  %11 = load i32, ptr @a, align 4, !tbaa !11
  %12 = and i32 %10, %11
  %13 = load i32, ptr @a, align 4, !tbaa !11
  %14 = xor i32 %12, %13
  %15 = load i32, ptr @b, align 4, !tbaa !11
  %16 = load i32, ptr @a, align 4, !tbaa !11
  %17 = and i32 %15, %16
  %18 = xor i32 %14, %17
  %19 = load i32, ptr @b, align 4, !tbaa !11
  %20 = xor i32 %18, %19
  %21 = load i32, ptr @b, align 4, !tbaa !11
  %22 = icmp ult i32 %20, %21
  %23 = zext i1 %22 to i32
  store i32 %23, ptr @h, align 4, !tbaa !11
  %24 = load i32, ptr @h, align 4, !tbaa !11
  %25 = load i8, ptr @d, align 1, !tbaa !12
  %26 = zext i8 %25 to i32
  %27 = xor i32 %26, %24
  %28 = trunc i32 %27 to i8
  store i8 %28, ptr @d, align 1, !tbaa !12
  %29 = load ptr, ptr @f, align 8, !tbaa !13
  store i32 0, ptr %29, align 4, !tbaa !11
  br label %30

30:                                               ; preds = %9
  %31 = load i16, ptr @g, align 2, !tbaa !9
  %32 = add i16 %31, 1
  store i16 %32, ptr @g, align 2, !tbaa !9
  br label %5, !llvm.loop !16

33:                                               ; preds = %5
  br label %34

34:                                               ; preds = %33
  %35 = load i16, ptr @c, align 2, !tbaa !9
  %36 = add i16 %35, -1
  store i16 %36, ptr @c, align 2, !tbaa !9
  br label %1, !llvm.loop !18

37:                                               ; preds = %1
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i16, align 2
  %5 = alloca i16, align 2
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  store i32 0, ptr %8, align 4, !tbaa !11
  store i32 1, ptr %7, align 4, !tbaa !11
  store i32 -1, ptr %6, align 4, !tbaa !11
  store i16 -32767, ptr %5, align 2, !tbaa !9
  store i16 -32767, ptr %4, align 2, !tbaa !9
  store i32 -2130706432, ptr %2, align 4, !tbaa !11
  %9 = load i32, ptr %2, align 4, !tbaa !11
  store i32 %9, ptr %3, align 4, !tbaa !11
  store ptr %3, ptr @f, align 8, !tbaa !13
  %10 = load i16, ptr %4, align 2, !tbaa !9
  store i16 %10, ptr @g, align 2, !tbaa !9
  %11 = load i16, ptr %5, align 2, !tbaa !9
  store i16 %11, ptr @c, align 2, !tbaa !9
  %12 = load i32, ptr %6, align 4, !tbaa !11
  store i32 %12, ptr @h, align 4, !tbaa !11
  %13 = load i32, ptr %7, align 4, !tbaa !11
  store i32 %13, ptr @b, align 4, !tbaa !11
  %14 = load i32, ptr %8, align 4, !tbaa !11
  store i32 %14, ptr @a, align 4, !tbaa !11
  call void @i()
  %15 = load i32, ptr @a, align 4, !tbaa !11
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %15)
  %17 = load i32, ptr @b, align 4, !tbaa !11
  %18 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %17)
  %19 = load i16, ptr @c, align 2, !tbaa !9
  %20 = sext i16 %19 to i32
  %21 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %20)
  %22 = load i8, ptr @d, align 1, !tbaa !12
  %23 = zext i8 %22 to i32
  %24 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %23)
  %25 = load i16, ptr @g, align 2, !tbaa !9
  %26 = sext i16 %25 to i32
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %26)
  %28 = load i32, ptr @h, align 4, !tbaa !11
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %28)
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
!9 = !{!10, !10, i64 0}
!10 = !{!"short", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = !{!7, !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p1 int", !15, i64 0}
!15 = !{!"any pointer", !7, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
!18 = distinct !{!18, !17}
