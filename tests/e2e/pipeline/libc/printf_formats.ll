; @source: tests/e2e/src/libc/printf_formats.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/libc/printf_formats.c'
source_filename = "tests/e2e/src/libc/printf_formats.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [48 x i8] c"[%5d] [%-5d] [%05d] [%+d] [%x] [%X] [%o] [%#x]\0A\00", align 1
@.str.1 = private unnamed_addr constant [33 x i8] c"[%c] [%s] [%10s] [%-10s] [%.3s]\0A\00", align 1
@.str.2 = private unnamed_addr constant [4 x i8] c"str\00", align 1
@.str.3 = private unnamed_addr constant [6 x i8] c"right\00", align 1
@.str.4 = private unnamed_addr constant [5 x i8] c"left\00", align 1
@.str.5 = private unnamed_addr constant [9 x i8] c"truncate\00", align 1
@.str.6 = private unnamed_addr constant [28 x i8] c"[%f] [%.2f] [%e] [%g] [%g]\0A\00", align 1
@.str.7 = private unnamed_addr constant [44 x i8] c"[%ld] [%lu] [%lld] [%hhd] [%hd] [%zu] [%%]\0A\00", align 1
@.str.8 = private unnamed_addr constant [11 x i8] c"%d-%s-%.1f\00", align 1
@.str.9 = private unnamed_addr constant [2 x i8] c"x\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [64 x i8], align 16
  %3 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %4 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef 42, i32 noundef 42, i32 noundef 42, i32 noundef 42, i32 noundef 255, i32 noundef 255, i32 noundef 8, i32 noundef 255)
  %5 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef 122, ptr noundef @.str.2, ptr noundef @.str.3, ptr noundef @.str.4, ptr noundef @.str.5)
  %6 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, double noundef 3.141590e+00, double noundef 2.718280e+00, double noundef f0x40C81CD6C8B43958, double noundef 1.000000e-04, double noundef 1.000000e+20)
  %7 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i64 noundef -1, i64 noundef 1099511627776, i64 noundef -4611686018427387904, i32 noundef 44, i32 noundef 4464, i64 noundef 8)
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %8 = getelementptr inbounds [64 x i8], ptr %2, i64 0, i64 0
  %9 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %8, i64 noundef 64, ptr noundef @.str.8, i32 noundef 7, ptr noundef @.str.9, double noundef 2.500000e-01) #4
  store i32 %9, ptr %3, align 4, !tbaa !9
  %10 = getelementptr inbounds [64 x i8], ptr %2, i64 0, i64 0
  %11 = call i32 @puts(ptr noundef %10)
  %12 = load i32, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 %12
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nounwind
declare i32 @snprintf(ptr noundef, i64 noundef, ptr noundef, ...) #3

declare i32 @puts(ptr noundef) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
