; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-004.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-004.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2020-01-06-coverage-004.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%union.u = type { i16 }

@a = dso_local global i32 0, align 4
@x = dso_local global i64 0, align 8
@d = dso_local global %union.u zeroinitializer, align 2
@g = internal global ptr @f, align 8
@e = internal global ptr @b, align 8
@y = dso_local global i64 0, align 8
@h_call_argument_1 = dso_local global i32 0, align 4
@f = dso_local global ptr null, align 8
@b = dso_local global i32 0, align 4
@.str = private unnamed_addr constant [8 x i8] c"a = %i\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"b = %i\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"d.c = %hu\0A\00", align 1
@.str.3 = private unnamed_addr constant [9 x i8] c"y = %li\0A\00", align 1
@.str.4 = private unnamed_addr constant [24 x i8] c"h_call_argument_1 = %i\0A\00", align 1
@.str.5 = private unnamed_addr constant [9 x i8] c"x = %li\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i64 @h(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = icmp ne i32 %3, 0
  br i1 %4, label %5, label %13

5:                                                ; preds = %1
  %6 = load i32, ptr @a, align 4, !tbaa !9
  %7 = sext i32 %6 to i64
  %8 = sdiv i64 2036854775807, %7
  %9 = icmp ne i64 %8, 0
  br i1 %9, label %10, label %13

10:                                               ; preds = %5
  %11 = load i32, ptr %2, align 4, !tbaa !9
  %12 = icmp ne i32 %11, 0
  br label %13

13:                                               ; preds = %10, %5, %1
  %14 = phi i1 [ false, %5 ], [ false, %1 ], [ %12, %10 ]
  %15 = zext i1 %14 to i32
  %16 = sext i32 %15 to i64
  store i64 %16, ptr @x, align 8, !tbaa !10
  %17 = load i64, ptr @x, align 8, !tbaa !10
  ret i64 %17
}

; Function Attrs: nounwind uwtable
define dso_local void @j() #0 {
  br label %1

1:                                                ; preds = %12, %0
  %2 = load i16, ptr @d, align 2, !tbaa !12
  %3 = icmp ne i16 %2, 0
  br i1 %3, label %4, label %15

4:                                                ; preds = %1
  %5 = load ptr, ptr @g, align 8, !tbaa !13
  %6 = load ptr, ptr %5, align 8, !tbaa !17
  %7 = load i64, ptr %6, align 8, !tbaa !10
  %8 = trunc i64 %7 to i32
  %9 = call i64 @h(i32 noundef %8)
  %10 = trunc i64 %9 to i32
  %11 = load ptr, ptr @e, align 8, !tbaa !19
  store i32 %10, ptr %11, align 4, !tbaa !9
  br label %12

12:                                               ; preds = %4
  %13 = load i16, ptr @d, align 2, !tbaa !12
  %14 = add i16 %13, 1
  store i16 %14, ptr @d, align 2, !tbaa !12
  br label %1, !llvm.loop !21

15:                                               ; preds = %1
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i16, align 2
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
  store i32 251, ptr %9, align 4, !tbaa !9
  store i32 -2113601536, ptr %8, align 4, !tbaa !9
  store i16 12027, ptr %7, align 2, !tbaa !23
  store i64 0, ptr %5, align 8, !tbaa !10
  store i64 70651297207679744, ptr %4, align 8, !tbaa !10
  store i32 -7, ptr %3, align 4, !tbaa !9
  store i64 2089739496336261183, ptr %2, align 8, !tbaa !10
  %10 = load i64, ptr %5, align 8, !tbaa !10
  store i64 %10, ptr %6, align 8, !tbaa !10
  %11 = load i64, ptr %2, align 8, !tbaa !10
  store i64 %11, ptr @y, align 8, !tbaa !10
  %12 = load i32, ptr %3, align 4, !tbaa !9
  store i32 %12, ptr @h_call_argument_1, align 4, !tbaa !9
  %13 = load i64, ptr %4, align 8, !tbaa !10
  store i64 %13, ptr @x, align 8, !tbaa !10
  store ptr %6, ptr @f, align 8, !tbaa !17
  %14 = load i16, ptr %7, align 2, !tbaa !23
  store i16 %14, ptr @d, align 2, !tbaa !12
  %15 = load i32, ptr %8, align 4, !tbaa !9
  store i32 %15, ptr @b, align 4, !tbaa !9
  %16 = load i32, ptr %9, align 4, !tbaa !9
  store i32 %16, ptr @a, align 4, !tbaa !9
  call void @j()
  %17 = load i32, ptr @h_call_argument_1, align 4, !tbaa !9
  %18 = call i64 @h(i32 noundef %17)
  store i64 %18, ptr @y, align 8, !tbaa !10
  %19 = load i32, ptr @a, align 4, !tbaa !9
  %20 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %19)
  %21 = load i32, ptr @b, align 4, !tbaa !9
  %22 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %21)
  %23 = load i16, ptr @d, align 2, !tbaa !12
  %24 = zext i16 %23 to i32
  %25 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %24)
  %26 = load i64, ptr @y, align 8, !tbaa !10
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %26)
  %28 = load i32, ptr @h_call_argument_1, align 4, !tbaa !9
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %28)
  %30 = load i64, ptr @x, align 8, !tbaa !10
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i64 noundef %30)
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
!10 = !{!11, !11, i64 0}
!11 = !{!"long", !7, i64 0}
!12 = !{!7, !7, i64 0}
!13 = !{!14, !14, i64 0}
!14 = !{!"p2 long", !15, i64 0}
!15 = !{!"any p2 pointer", !16, i64 0}
!16 = !{!"any pointer", !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"p1 long", !16, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"p1 int", !16, i64 0}
!21 = distinct !{!21, !22}
!22 = !{!"llvm.loop.mustprogress"}
!23 = !{!24, !24, i64 0}
!24 = !{!"short", !7, i64 0}
