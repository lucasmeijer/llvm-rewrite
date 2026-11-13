; @source: tests/lto/src/ipo/const_global/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/const_global/main.c'
source_filename = "tests/lto/src/ipo/const_global/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [8 x i8] c"%ld %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i64, align 8
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i64 0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !11
  br label %4

4:                                                ; preds = %21, %0
  %5 = load i32, ptr %3, align 4, !tbaa !11
  %6 = icmp slt i32 %5, 1000
  br i1 %6, label %8, label %7

7:                                                ; preds = %4
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %24

8:                                                ; preds = %4
  %9 = call i32 @get_mode()
  %10 = icmp eq i32 %9, 2
  br i1 %10, label %11, label %13

11:                                               ; preds = %8
  %12 = load i32, ptr %3, align 4, !tbaa !11
  br label %16

13:                                               ; preds = %8
  %14 = load i32, ptr %3, align 4, !tbaa !11
  %15 = sub nsw i32 0, %14
  br label %16

16:                                               ; preds = %13, %11
  %17 = phi i32 [ %12, %11 ], [ %15, %13 ]
  %18 = sext i32 %17 to i64
  %19 = load i64, ptr %2, align 8, !tbaa !9
  %20 = add nsw i64 %19, %18
  store i64 %20, ptr %2, align 8, !tbaa !9
  br label %21

21:                                               ; preds = %16
  %22 = load i32, ptr %3, align 4, !tbaa !11
  %23 = add nsw i32 %22, 1
  store i32 %23, ptr %3, align 4, !tbaa !11
  br label %4, !llvm.loop !12

24:                                               ; preds = %7
  %25 = load i64, ptr %2, align 8, !tbaa !9
  %26 = call i32 @get_calls()
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %25, i32 noundef %26)
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @get_mode() #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

declare i32 @get_calls() #2

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
!10 = !{!"long", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
