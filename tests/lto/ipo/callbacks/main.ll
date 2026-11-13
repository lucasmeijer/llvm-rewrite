; @source: tests/lto/src/ipo/callbacks/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/callbacks/main.c'
source_filename = "tests/lto/src/ipo/callbacks/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@__const.main.xs = private unnamed_addr constant [11 x i32] [i32 3, i32 1, i32 4, i32 1, i32 5, i32 9, i32 2, i32 6, i32 5, i32 3, i32 5], align 16
@.str = private unnamed_addr constant [8 x i8] c"%ld %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [11 x i32], align 16
  %3 = alloca i64, align 8
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 %2, ptr align 16 @__const.main.xs, i64 44, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i64 0, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #3
  store i32 -1, ptr %4, align 4, !tbaa !11
  %5 = getelementptr inbounds [11 x i32], ptr %2, i64 0, i64 0
  call void @for_each(ptr noundef %5, i32 noundef 11, ptr noundef @sum, ptr noundef %3)
  %6 = getelementptr inbounds [11 x i32], ptr %2, i64 0, i64 0
  call void @for_each(ptr noundef %6, i32 noundef 11, ptr noundef @maxv, ptr noundef %4)
  %7 = load i64, ptr %3, align 8, !tbaa !9
  %8 = load i32, ptr %4, align 4, !tbaa !11
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %7, i32 noundef %8)
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare void @for_each(ptr noundef, i32 noundef, ptr noundef, ptr noundef) #2

; Function Attrs: nounwind uwtable
define internal void @sum(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  store i32 %0, ptr %3, align 4, !tbaa !11
  store ptr %1, ptr %4, align 8, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !11
  %6 = sext i32 %5 to i64
  %7 = load ptr, ptr %4, align 8, !tbaa !12
  %8 = load i64, ptr %7, align 8, !tbaa !9
  %9 = add nsw i64 %8, %6
  store i64 %9, ptr %7, align 8, !tbaa !9
  ret void
}

; Function Attrs: nounwind uwtable
define internal void @maxv(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca ptr, align 8
  store i32 %0, ptr %3, align 4, !tbaa !11
  store ptr %1, ptr %4, align 8, !tbaa !12
  %5 = load i32, ptr %3, align 4, !tbaa !11
  %6 = load ptr, ptr %4, align 8, !tbaa !12
  %7 = load i32, ptr %6, align 4, !tbaa !11
  %8 = icmp sgt i32 %5, %7
  br i1 %8, label %9, label %12

9:                                                ; preds = %2
  %10 = load i32, ptr %3, align 4, !tbaa !11
  %11 = load ptr, ptr %4, align 8, !tbaa !12
  store i32 %10, ptr %11, align 4, !tbaa !11
  br label %12

12:                                               ; preds = %9, %2
  ret void
}

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
!10 = !{!"long", !7, i64 0}
!11 = !{!6, !6, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
