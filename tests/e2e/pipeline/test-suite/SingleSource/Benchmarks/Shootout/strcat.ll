; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/strcat.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/strcat.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Shootout/strcat.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [14 x i8] c"calloc strbuf\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"realloc strbuf\00", align 1
@.str.2 = private unnamed_addr constant [7 x i8] c"hello\0A\00", align 1
@.str.3 = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca ptr, align 8
  %11 = alloca i32, align 4
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #10
  %12 = load i32, ptr %4, align 4, !tbaa !9
  %13 = icmp eq i32 %12, 2
  br i1 %13, label %14, label %19

14:                                               ; preds = %2
  %15 = load ptr, ptr %5, align 8, !tbaa !10
  %16 = getelementptr inbounds ptr, ptr %15, i64 1
  %17 = load ptr, ptr %16, align 8, !tbaa !14
  %18 = call i32 @atoi(ptr noundef %17) #11
  br label %20

19:                                               ; preds = %2
  br label %20

20:                                               ; preds = %19, %14
  %21 = phi i32 [ %18, %14 ], [ 10000000, %19 ]
  store i32 %21, ptr %6, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %7) #10
  call void @llvm.lifetime.start.p0(ptr %8) #10
  store i32 32, ptr %8, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %9) #10
  %22 = load i32, ptr %8, align 4, !tbaa !9
  %23 = sext i32 %22 to i64
  %24 = call noalias ptr @calloc(i64 noundef 1, i64 noundef %23) #12
  store ptr %24, ptr %9, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %10) #10
  %25 = load ptr, ptr %9, align 8, !tbaa !14
  store ptr %25, ptr %10, align 8, !tbaa !14
  call void @llvm.lifetime.start.p0(ptr %11) #10
  store i32 6, ptr %11, align 4, !tbaa !9
  %26 = load ptr, ptr %9, align 8, !tbaa !14
  %27 = icmp ne ptr %26, null
  br i1 %27, label %29, label %28

28:                                               ; preds = %20
  call void @perror(ptr noundef @.str) #13
  call void @exit(i32 noundef 1) #14
  unreachable

29:                                               ; preds = %20
  store i32 0, ptr %7, align 4, !tbaa !9
  br label %30

30:                                               ; preds = %69, %29
  %31 = load i32, ptr %7, align 4, !tbaa !9
  %32 = load i32, ptr %6, align 4, !tbaa !9
  %33 = icmp slt i32 %31, %32
  br i1 %33, label %34, label %72

34:                                               ; preds = %30
  %35 = load ptr, ptr %9, align 8, !tbaa !14
  %36 = load i32, ptr %8, align 4, !tbaa !9
  %37 = sext i32 %36 to i64
  %38 = getelementptr inbounds i8, ptr %35, i64 %37
  %39 = load ptr, ptr %10, align 8, !tbaa !14
  %40 = ptrtoint ptr %38 to i64
  %41 = ptrtoint ptr %39 to i64
  %42 = sub i64 %40, %41
  %43 = load i32, ptr %11, align 4, !tbaa !9
  %44 = add nsw i32 %43, 1
  %45 = sext i32 %44 to i64
  %46 = icmp slt i64 %42, %45
  br i1 %46, label %47, label %62

47:                                               ; preds = %34
  %48 = load i32, ptr %8, align 4, !tbaa !9
  %49 = mul nsw i32 2, %48
  store i32 %49, ptr %8, align 4, !tbaa !9
  %50 = load ptr, ptr %9, align 8, !tbaa !14
  %51 = load i32, ptr %8, align 4, !tbaa !9
  %52 = sext i32 %51 to i64
  %53 = call ptr @realloc(ptr noundef %50, i64 noundef %52) #15
  store ptr %53, ptr %9, align 8, !tbaa !14
  %54 = load ptr, ptr %9, align 8, !tbaa !14
  %55 = icmp ne ptr %54, null
  br i1 %55, label %57, label %56

56:                                               ; preds = %47
  call void @perror(ptr noundef @.str.1) #13
  call void @exit(i32 noundef 1) #14
  unreachable

57:                                               ; preds = %47
  %58 = load ptr, ptr %9, align 8, !tbaa !14
  %59 = load ptr, ptr %9, align 8, !tbaa !14
  %60 = call i64 @strlen(ptr noundef %59) #11
  %61 = getelementptr inbounds nuw i8, ptr %58, i64 %60
  store ptr %61, ptr %10, align 8, !tbaa !14
  br label %62

62:                                               ; preds = %57, %34
  %63 = load ptr, ptr %10, align 8, !tbaa !14
  %64 = call ptr @strcat(ptr noundef %63, ptr noundef @.str.2) #10
  %65 = load i32, ptr %11, align 4, !tbaa !9
  %66 = load ptr, ptr %10, align 8, !tbaa !14
  %67 = sext i32 %65 to i64
  %68 = getelementptr inbounds i8, ptr %66, i64 %67
  store ptr %68, ptr %10, align 8, !tbaa !14
  br label %69

69:                                               ; preds = %62
  %70 = load i32, ptr %7, align 4, !tbaa !9
  %71 = add nsw i32 %70, 1
  store i32 %71, ptr %7, align 4, !tbaa !9
  br label %30, !llvm.loop !16

72:                                               ; preds = %30
  %73 = load ptr, ptr %9, align 8, !tbaa !14
  %74 = call i64 @strlen(ptr noundef %73) #11
  %75 = trunc i64 %74 to i32
  %76 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i32 noundef %75)
  %77 = load ptr, ptr %9, align 8, !tbaa !14
  call void @free(ptr noundef %77) #10
  call void @llvm.lifetime.end.p0(ptr %11) #10
  call void @llvm.lifetime.end.p0(ptr %10) #10
  call void @llvm.lifetime.end.p0(ptr %9) #10
  call void @llvm.lifetime.end.p0(ptr %8) #10
  call void @llvm.lifetime.end.p0(ptr %7) #10
  call void @llvm.lifetime.end.p0(ptr %6) #10
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #10
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #3

; Function Attrs: cold
declare void @perror(ptr noundef) #4

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #5

; Function Attrs: nounwind allocsize(1)
declare ptr @realloc(ptr noundef, i64 noundef) #6

; Function Attrs: nounwind willreturn memory(read)
declare i64 @strlen(ptr noundef) #7

; Function Attrs: nounwind
declare ptr @strcat(ptr noundef, ptr noundef) #8

declare i32 @printf(ptr noundef, ...) #9

; Function Attrs: nounwind
declare void @free(ptr noundef) #8

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #8

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0,1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { cold "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind allocsize(1) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #9 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #10 = { nounwind }
attributes #11 = { nounwind willreturn memory(read) }
attributes #12 = { nounwind allocsize(0,1) }
attributes #13 = { cold }
attributes #14 = { noreturn nounwind }
attributes #15 = { nounwind allocsize(1) }

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
!10 = !{!11, !11, i64 0}
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 omnipotent char", !13, i64 0}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
