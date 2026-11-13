; @source: tests/lto/src/split/hash_table/table.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/split/hash_table/table.c'
source_filename = "tests/lto/src/split/hash_table/table.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.entry = type { [16 x i8], i32, i32 }

@table = internal global [64 x %struct.entry] zeroinitializer, align 16

; Function Attrs: nounwind uwtable
define dso_local void @put(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  store i32 %1, ptr %4, align 4, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #4
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = call i32 @hash(ptr noundef %6)
  %8 = urem i32 %7, 64
  store i32 %8, ptr %5, align 4, !tbaa !12
  br label %9

9:                                                ; preds = %27, %2
  %10 = load i32, ptr %5, align 4, !tbaa !12
  %11 = zext i32 %10 to i64
  %12 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.entry, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !13
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %25

16:                                               ; preds = %9
  %17 = load i32, ptr %5, align 4, !tbaa !12
  %18 = zext i32 %17 to i64
  %19 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %18
  %20 = getelementptr inbounds nuw %struct.entry, ptr %19, i32 0, i32 0
  %21 = getelementptr inbounds [16 x i8], ptr %20, i64 0, i64 0
  %22 = load ptr, ptr %3, align 8, !tbaa !9
  %23 = call i32 @strcmp(ptr noundef %21, ptr noundef %22) #5
  %24 = icmp ne i32 %23, 0
  br label %25

25:                                               ; preds = %16, %9
  %26 = phi i1 [ false, %9 ], [ %24, %16 ]
  br i1 %26, label %27, label %31

27:                                               ; preds = %25
  %28 = load i32, ptr %5, align 4, !tbaa !12
  %29 = add i32 %28, 1
  %30 = urem i32 %29, 64
  store i32 %30, ptr %5, align 4, !tbaa !12
  br label %9, !llvm.loop !15

31:                                               ; preds = %25
  %32 = load i32, ptr %5, align 4, !tbaa !12
  %33 = zext i32 %32 to i64
  %34 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %33
  %35 = getelementptr inbounds nuw %struct.entry, ptr %34, i32 0, i32 0
  %36 = getelementptr inbounds [16 x i8], ptr %35, i64 0, i64 0
  %37 = load ptr, ptr %3, align 8, !tbaa !9
  %38 = call ptr @strcpy(ptr noundef %36, ptr noundef %37) #4
  %39 = load i32, ptr %4, align 4, !tbaa !12
  %40 = load i32, ptr %5, align 4, !tbaa !12
  %41 = zext i32 %40 to i64
  %42 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %41
  %43 = getelementptr inbounds nuw %struct.entry, ptr %42, i32 0, i32 1
  store i32 %39, ptr %43, align 8, !tbaa !17
  %44 = load i32, ptr %5, align 4, !tbaa !12
  %45 = zext i32 %44 to i64
  %46 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %45
  %47 = getelementptr inbounds nuw %struct.entry, ptr %46, i32 0, i32 2
  store i32 1, ptr %47, align 4, !tbaa !13
  call void @llvm.lifetime.end.p0(ptr %5) #4
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @hash(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #4
  store i32 5381, ptr %3, align 4, !tbaa !12
  br label %4

4:                                                ; preds = %8, %1
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  %6 = load i8, ptr %5, align 1, !tbaa !18
  %7 = icmp ne i8 %6, 0
  br i1 %7, label %8, label %16

8:                                                ; preds = %4
  %9 = load i32, ptr %3, align 4, !tbaa !12
  %10 = mul i32 %9, 33
  %11 = load ptr, ptr %2, align 8, !tbaa !9
  %12 = getelementptr inbounds nuw i8, ptr %11, i32 1
  store ptr %12, ptr %2, align 8, !tbaa !9
  %13 = load i8, ptr %11, align 1, !tbaa !18
  %14 = zext i8 %13 to i32
  %15 = add i32 %10, %14
  store i32 %15, ptr %3, align 4, !tbaa !12
  br label %4, !llvm.loop !19

16:                                               ; preds = %4
  %17 = load i32, ptr %3, align 4, !tbaa !12
  call void @llvm.lifetime.end.p0(ptr %3) #4
  ret i32 %17
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #2

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @get(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %4) #4
  %6 = load ptr, ptr %3, align 8, !tbaa !9
  %7 = call i32 @hash(ptr noundef %6)
  %8 = urem i32 %7, 64
  store i32 %8, ptr %4, align 4, !tbaa !12
  br label %9

9:                                                ; preds = %31, %1
  %10 = load i32, ptr %4, align 4, !tbaa !12
  %11 = zext i32 %10 to i64
  %12 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.entry, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !13
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %35

16:                                               ; preds = %9
  %17 = load i32, ptr %4, align 4, !tbaa !12
  %18 = zext i32 %17 to i64
  %19 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %18
  %20 = getelementptr inbounds nuw %struct.entry, ptr %19, i32 0, i32 0
  %21 = getelementptr inbounds [16 x i8], ptr %20, i64 0, i64 0
  %22 = load ptr, ptr %3, align 8, !tbaa !9
  %23 = call i32 @strcmp(ptr noundef %21, ptr noundef %22) #5
  %24 = icmp ne i32 %23, 0
  br i1 %24, label %31, label %25

25:                                               ; preds = %16
  %26 = load i32, ptr %4, align 4, !tbaa !12
  %27 = zext i32 %26 to i64
  %28 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %27
  %29 = getelementptr inbounds nuw %struct.entry, ptr %28, i32 0, i32 1
  %30 = load i32, ptr %29, align 8, !tbaa !17
  store i32 %30, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %36

31:                                               ; preds = %16
  %32 = load i32, ptr %4, align 4, !tbaa !12
  %33 = add i32 %32, 1
  %34 = urem i32 %33, 64
  store i32 %34, ptr %4, align 4, !tbaa !12
  br label %9, !llvm.loop !20

35:                                               ; preds = %9
  store i32 -1, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %36

36:                                               ; preds = %35, %25
  call void @llvm.lifetime.end.p0(ptr %4) #4
  %37 = load i32, ptr %2, align 4
  ret i32 %37
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!13 = !{!14, !6, i64 20}
!14 = !{!"entry", !7, i64 0, !6, i64 16, !6, i64 20}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{!14, !6, i64 16}
!18 = !{!7, !7, i64 0}
!19 = distinct !{!19, !16}
!20 = distinct !{!20, !16}
