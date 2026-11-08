; @source: tests/e2e/src/structs/union_bitfields.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/union_bitfields.c'
source_filename = "tests/e2e/src/structs/union_bitfields.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%union.u = type { i32 }
%struct.flags = type { i32 }

@.str = private unnamed_addr constant [12 x i8] c"%08x %d %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [17 x i8] c"%u %u %d %u %zu\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %union.u, align 4
  %3 = alloca %struct.flags, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store float 1.000000e+00, ptr %2, align 4, !tbaa !9
  %4 = load i32, ptr %2, align 4, !tbaa !9
  %5 = getelementptr inbounds [4 x i8], ptr %2, i64 0, i64 0
  %6 = load i8, ptr %5, align 4, !tbaa !9
  %7 = zext i8 %6 to i32
  %8 = getelementptr inbounds [4 x i8], ptr %2, i64 0, i64 3
  %9 = load i8, ptr %8, align 1, !tbaa !9
  %10 = zext i8 %9 to i32
  %11 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4, i32 noundef %7, i32 noundef %10)
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.memset.p0.i64(ptr align 4 %3, i8 0, i64 4, i1 false)
  %12 = load i32, ptr %3, align 4
  %13 = and i32 %12, -8
  %14 = or i32 %13, 5
  store i32 %14, ptr %3, align 4
  %15 = load i32, ptr %3, align 4
  %16 = and i32 %15, -249
  %17 = or i32 %16, 248
  store i32 %17, ptr %3, align 4
  %18 = load i32, ptr %3, align 4
  %19 = and i32 %18, -3841
  %20 = or i32 %19, 3328
  store i32 %20, ptr %3, align 4
  %21 = load i32, ptr %3, align 4
  %22 = and i32 %21, 4095
  %23 = or i32 %22, -198967296
  store i32 %23, ptr %3, align 4
  %24 = load i32, ptr %3, align 4
  %25 = and i32 %24, 7
  %26 = add nsw i32 %25, 4
  %27 = load i32, ptr %3, align 4
  %28 = and i32 %26, 7
  %29 = and i32 %27, -8
  %30 = or i32 %29, %28
  store i32 %30, ptr %3, align 4
  %31 = load i32, ptr %3, align 4
  %32 = and i32 %31, 7
  %33 = load i32, ptr %3, align 4
  %34 = lshr i32 %33, 3
  %35 = and i32 %34, 31
  %36 = load i32, ptr %3, align 4
  %37 = shl i32 %36, 20
  %38 = ashr i32 %37, 28
  %39 = load i32, ptr %3, align 4
  %40 = lshr i32 %39, 12
  %41 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %32, i32 noundef %35, i32 noundef %38, i32 noundef %40, i64 noundef 4)
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
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
!9 = !{!7, !7, i64 0}
