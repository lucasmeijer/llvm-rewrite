; @source: tests/lto/src/split/hash_table/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/hash_table/main.c'
source_filename = "tests/lto/src/split/hash_table/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [6 x i8] c"key%d\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"key13\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%ld %d %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"nope\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [16 x i8], align 16
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %19, %0
  %7 = load i32, ptr %3, align 4, !tbaa !9
  %8 = icmp slt i32 %7, 40
  br i1 %8, label %10, label %9

9:                                                ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %3) #4
  br label %22

10:                                               ; preds = %6
  %11 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = mul nsw i32 %12, 13
  %14 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %11, i64 noundef 16, ptr noundef @.str, i32 noundef %13) #4
  %15 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %16 = load i32, ptr %3, align 4, !tbaa !9
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = mul nsw i32 %16, %17
  call void @put(ptr noundef %15, i32 noundef %18)
  br label %19

19:                                               ; preds = %10
  %20 = load i32, ptr %3, align 4, !tbaa !9
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %3, align 4, !tbaa !9
  br label %6, !llvm.loop !10

22:                                               ; preds = %9
  call void @put(ptr noundef @.str.1, i32 noundef -5)
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i64 0, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #4
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %23

23:                                               ; preds = %37, %22
  %24 = load i32, ptr %5, align 4, !tbaa !9
  %25 = icmp slt i32 %24, 60
  br i1 %25, label %27, label %26

26:                                               ; preds = %23
  call void @llvm.lifetime.end.p0(ptr %5) #4
  br label %40

27:                                               ; preds = %23
  %28 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %29 = load i32, ptr %5, align 4, !tbaa !9
  %30 = mul nsw i32 %29, 13
  %31 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %28, i64 noundef 16, ptr noundef @.str, i32 noundef %30) #4
  %32 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %33 = call i32 @get(ptr noundef %32)
  %34 = sext i32 %33 to i64
  %35 = load i64, ptr %4, align 8, !tbaa !12
  %36 = add nsw i64 %35, %34
  store i64 %36, ptr %4, align 8, !tbaa !12
  br label %37

37:                                               ; preds = %27
  %38 = load i32, ptr %5, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %5, align 4, !tbaa !9
  br label %23, !llvm.loop !14

40:                                               ; preds = %26
  %41 = load i64, ptr %4, align 8, !tbaa !12
  %42 = call i32 @get(ptr noundef @.str.1)
  %43 = call i32 @get(ptr noundef @.str.3)
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %41, i32 noundef %42, i32 noundef %43)
  call void @llvm.lifetime.end.p0(ptr %4) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i32 @snprintf(ptr noundef, i64 noundef, ptr noundef, ...) #2

declare void @put(ptr noundef, i32 noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @get(ptr noundef) #3

declare i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!13, !13, i64 0}
!13 = !{!"long", !7, i64 0}
!14 = distinct !{!14, !11}
