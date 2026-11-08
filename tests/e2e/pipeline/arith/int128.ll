; @source: tests/e2e/src/arith/int128.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/arith/int128.c'
source_filename = "tests/e2e/src/arith/int128.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"%llu %llu\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"%lld %lld\0A\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i128, align 16
  %3 = alloca i128, align 16
  %4 = alloca i128, align 16
  %5 = alloca i128, align 16
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i128 1234567890123456789000, ptr %2, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i128 79228162495817593515539431425, ptr %3, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #3
  %6 = load i128, ptr %2, align 16, !tbaa !9
  %7 = sdiv i128 %6, 77
  store i128 %7, ptr %4, align 16, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %8 = load i128, ptr %2, align 16, !tbaa !9
  %9 = srem i128 %8, 77
  store i128 %9, ptr %5, align 16, !tbaa !9
  %10 = load i128, ptr %2, align 16, !tbaa !9
  %11 = ashr i128 %10, 64
  %12 = trunc i128 %11 to i64
  %13 = load i128, ptr %2, align 16, !tbaa !9
  %14 = trunc i128 %13 to i64
  %15 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %12, i64 noundef %14)
  %16 = load i128, ptr %3, align 16, !tbaa !9
  %17 = lshr i128 %16, 64
  %18 = trunc i128 %17 to i64
  %19 = load i128, ptr %3, align 16, !tbaa !9
  %20 = trunc i128 %19 to i64
  %21 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %18, i64 noundef %20)
  %22 = load i128, ptr %4, align 16, !tbaa !9
  %23 = trunc i128 %22 to i64
  %24 = load i128, ptr %5, align 16, !tbaa !9
  %25 = trunc i128 %24 to i64
  %26 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i64 noundef %23, i64 noundef %25)
  %27 = load i128, ptr %2, align 16, !tbaa !9
  %28 = load i128, ptr %3, align 16, !tbaa !9
  %29 = icmp sgt i128 %27, %28
  %30 = zext i1 %29 to i32
  %31 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %30)
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
!10 = !{!"__int128", !7, i64 0}
