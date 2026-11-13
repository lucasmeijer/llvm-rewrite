; @source: tests/lto/src/split/crc32/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/crc32/main.c'
source_filename = "tests/lto/src/split/crc32/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [44 x i8] c"The quick brown fox jumps over the lazy dog\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"%08x\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca [256 x i8], align 16
  %4 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  store ptr @.str, ptr %2, align 8, !tbaa !9
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  %6 = load ptr, ptr %2, align 8, !tbaa !9
  %7 = call i64 @strlen(ptr noundef %6) #5
  %8 = call i32 @crc32(ptr noundef %5, i64 noundef %7)
  %9 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %8)
  call void @llvm.lifetime.start.p0(ptr %3) #4
  call void @llvm.lifetime.start.p0(ptr %4) #4
  store i32 0, ptr %4, align 4, !tbaa !12
  br label %10

10:                                               ; preds = %22, %0
  %11 = load i32, ptr %4, align 4, !tbaa !12
  %12 = icmp slt i32 %11, 256
  br i1 %12, label %14, label %13

13:                                               ; preds = %10
  call void @llvm.lifetime.end.p0(ptr %4) #4
  br label %25

14:                                               ; preds = %10
  %15 = load i32, ptr %4, align 4, !tbaa !12
  %16 = mul nsw i32 %15, 37
  %17 = add nsw i32 %16, 11
  %18 = trunc i32 %17 to i8
  %19 = load i32, ptr %4, align 4, !tbaa !12
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 %20
  store i8 %18, ptr %21, align 1, !tbaa !13
  br label %22

22:                                               ; preds = %14
  %23 = load i32, ptr %4, align 4, !tbaa !12
  %24 = add nsw i32 %23, 1
  store i32 %24, ptr %4, align 4, !tbaa !12
  br label %10, !llvm.loop !14

25:                                               ; preds = %13
  %26 = getelementptr inbounds [256 x i8], ptr %3, i64 0, i64 0
  %27 = call i32 @crc32(ptr noundef %26, i64 noundef 256)
  %28 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %27)
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

declare i32 @crc32(ptr noundef, i64 noundef) #2

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }
attributes #5 = { nounwind willreturn memory(read) }

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
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
