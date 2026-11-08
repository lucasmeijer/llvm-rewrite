; @source: tests/e2e/src/intrinsics/struct_copy_memset.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/intrinsics/struct_copy_memset.c'
source_filename = "tests/e2e/src/intrinsics/struct_copy_memset.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.big = type { [20 x i64], [13 x i8] }

@.str = private unnamed_addr constant [19 x i8] c"%ld %ld %s %zu %c\0A\00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"made\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.big, align 8
  %3 = alloca %struct.big, align 8
  %4 = alloca [100 x i8], align 16
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #6
  call void @make(ptr dead_on_unwind writable sret(%struct.big) align 8 %2, i32 noundef 3)
  call void @llvm.lifetime.start.p0(ptr %3) #6
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 %2, i64 176, i1 false), !tbaa.struct !9
  %5 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %6 = getelementptr inbounds [20 x i64], ptr %5, i64 0, i64 5
  store i64 -1, ptr %6, align 8, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %4) #6
  %7 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  call void @llvm.memset.p0.i64(ptr align 16 %7, i8 97, i64 100, i1 false)
  %8 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  %9 = getelementptr inbounds i8, ptr %8, i64 10
  %10 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  call void @llvm.memmove.p0.p0.i64(ptr align 2 %9, ptr align 16 %10, i64 50, i1 false)
  %11 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 99
  store i8 0, ptr %11, align 1, !tbaa !10
  %12 = getelementptr inbounds nuw %struct.big, ptr %2, i32 0, i32 0
  %13 = getelementptr inbounds [20 x i64], ptr %12, i64 0, i64 5
  %14 = load i64, ptr %13, align 8, !tbaa !11
  %15 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %16 = getelementptr inbounds [20 x i64], ptr %15, i64 0, i64 5
  %17 = load i64, ptr %16, align 8, !tbaa !11
  %18 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %19 = getelementptr inbounds [20 x i64], ptr %18, i64 0, i64 19
  %20 = load i64, ptr %19, align 8, !tbaa !11
  %21 = add nsw i64 %17, %20
  %22 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 1
  %23 = getelementptr inbounds [13 x i8], ptr %22, i64 0, i64 0
  %24 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  %25 = call i64 @strlen(ptr noundef %24) #7
  %26 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 60
  %27 = load i8, ptr %26, align 4, !tbaa !10
  %28 = sext i8 %27 to i32
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %14, i64 noundef %21, ptr noundef %23, i64 noundef %25, i32 noundef %28)
  call void @llvm.lifetime.end.p0(ptr %4) #6
  call void @llvm.lifetime.end.p0(ptr %3) #6
  call void @llvm.lifetime.end.p0(ptr %2) #6
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal void @make(ptr dead_on_unwind noalias writable sret(%struct.big) align 8 %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %1, ptr %3, align 4, !tbaa !13
  call void @llvm.memset.p0.i64(ptr align 8 %0, i8 0, i64 176, i1 false)
  call void @llvm.lifetime.start.p0(ptr %4) #6
  store i32 0, ptr %4, align 4, !tbaa !13
  br label %5

5:                                                ; preds = %19, %2
  %6 = load i32, ptr %4, align 4, !tbaa !13
  %7 = icmp slt i32 %6, 20
  br i1 %7, label %9, label %8

8:                                                ; preds = %5
  call void @llvm.lifetime.end.p0(ptr %4) #6
  br label %22

9:                                                ; preds = %5
  %10 = load i32, ptr %4, align 4, !tbaa !13
  %11 = sext i32 %10 to i64
  %12 = load i32, ptr %3, align 4, !tbaa !13
  %13 = sext i32 %12 to i64
  %14 = mul nsw i64 %11, %13
  %15 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %16 = load i32, ptr %4, align 4, !tbaa !13
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds [20 x i64], ptr %15, i64 0, i64 %17
  store i64 %14, ptr %18, align 8, !tbaa !11
  br label %19

19:                                               ; preds = %9
  %20 = load i32, ptr %4, align 4, !tbaa !13
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %4, align 4, !tbaa !13
  br label %5, !llvm.loop !14

22:                                               ; preds = %8
  %23 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 1
  %24 = getelementptr inbounds [13 x i8], ptr %23, i64 0, i64 0
  %25 = call ptr @strcpy(ptr noundef %24, ptr noundef @.str.1) #6
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memmove.p0.p0.i64(ptr writeonly captures(none), ptr readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind }
attributes #7 = { nounwind willreturn memory(read) }

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
!9 = !{i64 0, i64 160, !10, i64 160, i64 13, !10}
!10 = !{!7, !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"long", !7, i64 0}
!13 = !{!6, !6, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
