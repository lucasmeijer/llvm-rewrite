; @source: tests/e2e/src/intrinsics/struct_copy_memset.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/intrinsics/struct_copy_memset.c'
source_filename = "tests/e2e/src/intrinsics/struct_copy_memset.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.big = type { [20 x i64], [13 x i8] }

@.str = private unnamed_addr constant [19 x i8] c"%ld %ld %s %zu %c\0A\00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"made\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.big, align 8
  %3 = alloca %struct.big, align 8
  %4 = alloca [100 x i8], align 16
  store i32 0, ptr %1, align 4
  call void @make(ptr dead_on_unwind writable sret(%struct.big) align 8 %2, i32 noundef 3)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 %2, i64 176, i1 false)
  %5 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %6 = getelementptr inbounds [20 x i64], ptr %5, i64 0, i64 5
  store i64 -1, ptr %6, align 8
  %7 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  call void @llvm.memset.p0.i64(ptr align 16 %7, i8 97, i64 100, i1 false)
  %8 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  %9 = getelementptr inbounds i8, ptr %8, i64 10
  %10 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  call void @llvm.memmove.p0.p0.i64(ptr align 2 %9, ptr align 16 %10, i64 50, i1 false)
  %11 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 99
  store i8 0, ptr %11, align 1
  %12 = getelementptr inbounds nuw %struct.big, ptr %2, i32 0, i32 0
  %13 = getelementptr inbounds [20 x i64], ptr %12, i64 0, i64 5
  %14 = load i64, ptr %13, align 8
  %15 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %16 = getelementptr inbounds [20 x i64], ptr %15, i64 0, i64 5
  %17 = load i64, ptr %16, align 8
  %18 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 0
  %19 = getelementptr inbounds [20 x i64], ptr %18, i64 0, i64 19
  %20 = load i64, ptr %19, align 8
  %21 = add nsw i64 %17, %20
  %22 = getelementptr inbounds nuw %struct.big, ptr %3, i32 0, i32 1
  %23 = getelementptr inbounds [13 x i8], ptr %22, i64 0, i64 0
  %24 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 0
  %25 = call i64 @strlen(ptr noundef %24) #6
  %26 = getelementptr inbounds [100 x i8], ptr %4, i64 0, i64 60
  %27 = load i8, ptr %26, align 4
  %28 = sext i8 %27 to i32
  %29 = call i32 (ptr, ...) @printf(ptr noundef @.str, i64 noundef %14, i64 noundef %21, ptr noundef %23, i64 noundef %25, i32 noundef %28)
  ret i32 0
}

; Function Attrs: noinline nounwind uwtable
define internal void @make(ptr dead_on_unwind noalias writable sret(%struct.big) align 8 %0, i32 noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  store i32 %1, ptr %3, align 4
  call void @llvm.memset.p0.i64(ptr align 8 %0, i8 0, i64 176, i1 false)
  store i32 0, ptr %4, align 4
  br label %5

5:                                                ; preds = %18, %2
  %6 = load i32, ptr %4, align 4
  %7 = icmp slt i32 %6, 20
  br i1 %7, label %8, label %21

8:                                                ; preds = %5
  %9 = load i32, ptr %4, align 4
  %10 = sext i32 %9 to i64
  %11 = load i32, ptr %3, align 4
  %12 = sext i32 %11 to i64
  %13 = mul nsw i64 %10, %12
  %14 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 0
  %15 = load i32, ptr %4, align 4
  %16 = sext i32 %15 to i64
  %17 = getelementptr inbounds [20 x i64], ptr %14, i64 0, i64 %16
  store i64 %13, ptr %17, align 8
  br label %18

18:                                               ; preds = %8
  %19 = load i32, ptr %4, align 4
  %20 = add nsw i32 %19, 1
  store i32 %20, ptr %4, align 4
  br label %5, !llvm.loop !5

21:                                               ; preds = %5
  %22 = getelementptr inbounds nuw %struct.big, ptr %0, i32 0, i32 1
  %23 = getelementptr inbounds [13 x i8], ptr %22, i64 0, i64 0
  %24 = call ptr @strcpy(ptr noundef %23, ptr noundef @.str.1) #7
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

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #5

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind willreturn memory(read) }
attributes #7 = { nounwind }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
