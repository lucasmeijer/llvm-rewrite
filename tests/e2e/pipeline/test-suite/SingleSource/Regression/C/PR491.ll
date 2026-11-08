; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/PR491.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/PR491.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/PR491.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%union.anon = type { i64 }

@.str = private unnamed_addr constant [11 x i8] c"u.l == 128\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"u.l < 0\00", align 1
@stderr = external global ptr, align 8
@.str.2 = private unnamed_addr constant [35 x i8] c"assertion failed in line %u: '%s'\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @test(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca %union.anon, align 8
  store i32 %0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i64 0, ptr %3, align 8, !tbaa !10
  %4 = getelementptr inbounds [8 x i8], ptr %3, i64 0, i64 0
  store i8 -128, ptr %4, align 8, !tbaa !10
  %5 = load i64, ptr %3, align 8, !tbaa !10
  %6 = icmp eq i64 %5, 128
  br i1 %6, label %7, label %8

7:                                                ; preds = %1
  br label %10

8:                                                ; preds = %1
  %9 = call i32 @assert_fail(ptr noundef @.str, i32 noundef 22)
  br label %10

10:                                               ; preds = %8, %7
  %11 = phi i32 [ 1, %7 ], [ %9, %8 ]
  %12 = load i32, ptr %2, align 4, !tbaa !9
  %13 = and i32 %12, %11
  store i32 %13, ptr %2, align 4, !tbaa !9
  store i64 0, ptr %3, align 8, !tbaa !10
  %14 = getelementptr inbounds nuw [8 x i8], ptr %3, i64 0, i64 7
  store i8 -128, ptr %14, align 1, !tbaa !10
  %15 = load i64, ptr %3, align 8, !tbaa !10
  %16 = icmp slt i64 %15, 0
  br i1 %16, label %17, label %18

17:                                               ; preds = %10
  br label %20

18:                                               ; preds = %10
  %19 = call i32 @assert_fail(ptr noundef @.str.1, i32 noundef 24)
  br label %20

20:                                               ; preds = %18, %17
  %21 = phi i32 [ 1, %17 ], [ %19, %18 ]
  %22 = load i32, ptr %2, align 4, !tbaa !9
  %23 = and i32 %22, %21
  store i32 %23, ptr %2, align 4, !tbaa !9
  %24 = load i32, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #3
  ret i32 %24
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @assert_fail(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !11
  store i32 %1, ptr %4, align 4, !tbaa !9
  %5 = load ptr, ptr @stderr, align 8, !tbaa !14
  %6 = load i32, ptr %4, align 4, !tbaa !9
  %7 = load ptr, ptr %3, align 8, !tbaa !11
  %8 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %5, ptr noundef @.str.2, i32 noundef %6, ptr noundef %7) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = call i32 @test(i32 noundef 1)
  %3 = icmp ne i32 %2, 1
  %4 = zext i1 %3 to i32
  ret i32 %4
}

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!15 = !{!"p1 _ZTS8_IO_FILE", !13, i64 0}
