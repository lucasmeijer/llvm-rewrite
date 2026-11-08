; @source: tests/e2e/src/memory/static_local_volatile.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/memory/static_local_volatile.c'
source_filename = "tests/e2e/src/memory/static_local_volatile.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1
@next_id.id = internal global i32 100, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store volatile i32 3, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #3
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %5

5:                                                ; preds = %17, %0
  %6 = load i32, ptr %4, align 4, !tbaa !9
  %7 = icmp slt i32 %6, 5
  br i1 %7, label %9, label %8

8:                                                ; preds = %5
  call void @llvm.lifetime.end.p0(ptr %4) #3
  br label %20

9:                                                ; preds = %5
  %10 = load volatile i32, ptr %2, align 4, !tbaa !9
  %11 = mul nsw i32 %10, 2
  store volatile i32 %11, ptr %2, align 4, !tbaa !9
  %12 = call i32 @next_id()
  %13 = load volatile i32, ptr %2, align 4, !tbaa !9
  %14 = add nsw i32 %12, %13
  %15 = load i32, ptr %3, align 4, !tbaa !9
  %16 = add nsw i32 %15, %14
  store i32 %16, ptr %3, align 4, !tbaa !9
  br label %17

17:                                               ; preds = %9
  %18 = load i32, ptr %4, align 4, !tbaa !9
  %19 = add nsw i32 %18, 1
  store i32 %19, ptr %4, align 4, !tbaa !9
  br label %5, !llvm.loop !10

20:                                               ; preds = %8
  %21 = load i32, ptr %3, align 4, !tbaa !9
  %22 = load volatile i32, ptr %2, align 4, !tbaa !9
  %23 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %21, i32 noundef %22)
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @next_id() #0 {
  %1 = load i32, ptr @next_id.id, align 4, !tbaa !9
  %2 = add nsw i32 %1, 1
  store i32 %2, ptr @next_id.id, align 4, !tbaa !9
  ret i32 %1
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
