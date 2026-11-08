; @source: tests/e2e/src/misc/computed_goto.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/computed_goto.c'
source_filename = "tests/e2e/src/misc/computed_goto.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.prog = private unnamed_addr constant [10 x i8] c"\00\00\01\01\00\02\01\00\01\03", align 1
@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
@run.ops = internal global [4 x ptr] [ptr blockaddress(@run, %14), ptr blockaddress(@run, %26), ptr blockaddress(@run, %38), ptr blockaddress(@run, %50)], align 16

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [10 x i8], align 1
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %2, ptr align 1 @__const.main.prog, i64 10, i1 false)
  %3 = getelementptr inbounds [10 x i8], ptr %2, i64 0, i64 0
  %4 = call i32 @run(ptr noundef %3)
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4)
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal i32 @run(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !9
  store i32 0, ptr %3, align 4, !tbaa !12
  store i32 0, ptr %4, align 4, !tbaa !12
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  %6 = load i32, ptr %4, align 4, !tbaa !12
  %7 = add nsw i32 %6, 1
  store i32 %7, ptr %4, align 4, !tbaa !12
  %8 = sext i32 %6 to i64
  %9 = getelementptr inbounds i8, ptr %5, i64 %8
  %10 = load i8, ptr %9, align 1, !tbaa !13
  %11 = zext i8 %10 to i64
  %12 = getelementptr inbounds nuw [4 x ptr], ptr @run.ops, i64 0, i64 %11
  %13 = load ptr, ptr %12, align 8, !tbaa !14
  br label %52

14:                                               ; preds = %52
  %15 = load i32, ptr %3, align 4, !tbaa !12
  %16 = add nsw i32 %15, 1
  store i32 %16, ptr %3, align 4, !tbaa !12
  %17 = load ptr, ptr %2, align 8, !tbaa !9
  %18 = load i32, ptr %4, align 4, !tbaa !12
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %4, align 4, !tbaa !12
  %20 = sext i32 %18 to i64
  %21 = getelementptr inbounds i8, ptr %17, i64 %20
  %22 = load i8, ptr %21, align 1, !tbaa !13
  %23 = zext i8 %22 to i64
  %24 = getelementptr inbounds nuw [4 x ptr], ptr @run.ops, i64 0, i64 %23
  %25 = load ptr, ptr %24, align 8, !tbaa !14
  br label %52

26:                                               ; preds = %52
  %27 = load i32, ptr %3, align 4, !tbaa !12
  %28 = mul nsw i32 %27, 2
  store i32 %28, ptr %3, align 4, !tbaa !12
  %29 = load ptr, ptr %2, align 8, !tbaa !9
  %30 = load i32, ptr %4, align 4, !tbaa !12
  %31 = add nsw i32 %30, 1
  store i32 %31, ptr %4, align 4, !tbaa !12
  %32 = sext i32 %30 to i64
  %33 = getelementptr inbounds i8, ptr %29, i64 %32
  %34 = load i8, ptr %33, align 1, !tbaa !13
  %35 = zext i8 %34 to i64
  %36 = getelementptr inbounds nuw [4 x ptr], ptr @run.ops, i64 0, i64 %35
  %37 = load ptr, ptr %36, align 8, !tbaa !14
  br label %52

38:                                               ; preds = %52
  %39 = load i32, ptr %3, align 4, !tbaa !12
  %40 = sub nsw i32 %39, 3
  store i32 %40, ptr %3, align 4, !tbaa !12
  %41 = load ptr, ptr %2, align 8, !tbaa !9
  %42 = load i32, ptr %4, align 4, !tbaa !12
  %43 = add nsw i32 %42, 1
  store i32 %43, ptr %4, align 4, !tbaa !12
  %44 = sext i32 %42 to i64
  %45 = getelementptr inbounds i8, ptr %41, i64 %44
  %46 = load i8, ptr %45, align 1, !tbaa !13
  %47 = zext i8 %46 to i64
  %48 = getelementptr inbounds nuw [4 x ptr], ptr @run.ops, i64 0, i64 %47
  %49 = load ptr, ptr %48, align 8, !tbaa !14
  br label %52

50:                                               ; preds = %52
  %51 = load i32, ptr %3, align 4, !tbaa !12
  ret i32 %51

52:                                               ; preds = %38, %26, %14, %1
  %53 = phi ptr [ %13, %1 ], [ %25, %14 ], [ %37, %26 ], [ %49, %38 ]
  indirectbr ptr %53, [label %14, label %26, label %38, label %50]
}

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = !{!6, !6, i64 0}
!13 = !{!7, !7, i64 0}
!14 = !{!11, !11, i64 0}
