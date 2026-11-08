; @source: tests/e2e/src/misc/hash_table.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/hash_table.c'
source_filename = "tests/e2e/src/misc/hash_table.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.entry = type { [16 x i8], i32, i32 }

@.str = private unnamed_addr constant [6 x i8] c"key%d\00", align 1
@.str.1 = private unnamed_addr constant [6 x i8] c"key13\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%ld %d %d\0A\00", align 1
@.str.3 = private unnamed_addr constant [5 x i8] c"nope\00", align 1
@table = internal global [64 x %struct.entry] zeroinitializer, align 16

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [16 x i8], align 16
  %3 = alloca i32, align 4
  %4 = alloca i64, align 8
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %6

6:                                                ; preds = %19, %0
  %7 = load i32, ptr %3, align 4, !tbaa !9
  %8 = icmp slt i32 %7, 40
  br i1 %8, label %10, label %9

9:                                                ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %3) #5
  br label %22

10:                                               ; preds = %6
  %11 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = mul nsw i32 %12, 13
  %14 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %11, i64 noundef 16, ptr noundef @.str, i32 noundef %13) #5
  %15 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %16 = load i32, ptr %3, align 4, !tbaa !9
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = mul nsw i32 %16, %17
  call void @put(ptr noundef %15, i32 noundef %18)
  br label %19

19:                                               ; preds = %10
  %20 = load i32, ptr %3, align 4, !tbaa !9
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %3, align 4, !tbaa !9
  br label %6, !llvm.loop !10

22:                                               ; preds = %9
  call void @put(ptr noundef @.str.1, i32 noundef -5)
  call void @llvm.lifetime.start.p0(ptr %4) #5
  store i64 0, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #5
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %23

23:                                               ; preds = %37, %22
  %24 = load i32, ptr %5, align 4, !tbaa !9
  %25 = icmp slt i32 %24, 60
  br i1 %25, label %27, label %26

26:                                               ; preds = %23
  call void @llvm.lifetime.end.p0(ptr %5) #5
  br label %40

27:                                               ; preds = %23
  %28 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %29 = load i32, ptr %5, align 4, !tbaa !9
  %30 = mul nsw i32 %29, 13
  %31 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr noundef %28, i64 noundef 16, ptr noundef @.str, i32 noundef %30) #5
  %32 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  %33 = call i32 @get(ptr noundef %32)
  %34 = sext i32 %33 to i64
  %35 = load i64, ptr %4, align 8, !tbaa !12
  %36 = add nsw i64 %35, %34
  store i64 %36, ptr %4, align 8, !tbaa !12
  br label %37

37:                                               ; preds = %27
  %38 = load i32, ptr %5, align 4, !tbaa !9
  %39 = add nsw i32 %38, 1
  store i32 %39, ptr %5, align 4, !tbaa !9
  br label %23, !llvm.loop !14

40:                                               ; preds = %26
  %41 = load i64, ptr %4, align 8, !tbaa !12
  %42 = call i32 @get(ptr noundef @.str.1)
  %43 = call i32 @get(ptr noundef @.str.3)
  %44 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i64 noundef %41, i32 noundef %42, i32 noundef %43)
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i32 @snprintf(ptr noundef, i64 noundef, ptr noundef, ...) #2

; Function Attrs: nounwind uwtable
define internal void @put(ptr noundef %0, i32 noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !15
  store i32 %1, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #5
  %6 = load ptr, ptr %3, align 8, !tbaa !15
  %7 = call i32 @hash(ptr noundef %6)
  %8 = urem i32 %7, 64
  store i32 %8, ptr %5, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %27, %2
  %10 = load i32, ptr %5, align 4, !tbaa !9
  %11 = zext i32 %10 to i64
  %12 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.entry, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !18
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %25

16:                                               ; preds = %9
  %17 = load i32, ptr %5, align 4, !tbaa !9
  %18 = zext i32 %17 to i64
  %19 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %18
  %20 = getelementptr inbounds nuw %struct.entry, ptr %19, i32 0, i32 0
  %21 = getelementptr inbounds [16 x i8], ptr %20, i64 0, i64 0
  %22 = load ptr, ptr %3, align 8, !tbaa !15
  %23 = call i32 @strcmp(ptr noundef %21, ptr noundef %22) #6
  %24 = icmp ne i32 %23, 0
  br label %25

25:                                               ; preds = %16, %9
  %26 = phi i1 [ false, %9 ], [ %24, %16 ]
  br i1 %26, label %27, label %31

27:                                               ; preds = %25
  %28 = load i32, ptr %5, align 4, !tbaa !9
  %29 = add i32 %28, 1
  %30 = urem i32 %29, 64
  store i32 %30, ptr %5, align 4, !tbaa !9
  br label %9, !llvm.loop !20

31:                                               ; preds = %25
  %32 = load i32, ptr %5, align 4, !tbaa !9
  %33 = zext i32 %32 to i64
  %34 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %33
  %35 = getelementptr inbounds nuw %struct.entry, ptr %34, i32 0, i32 0
  %36 = getelementptr inbounds [16 x i8], ptr %35, i64 0, i64 0
  %37 = load ptr, ptr %3, align 8, !tbaa !15
  %38 = call ptr @strcpy(ptr noundef %36, ptr noundef %37) #5
  %39 = load i32, ptr %4, align 4, !tbaa !9
  %40 = load i32, ptr %5, align 4, !tbaa !9
  %41 = zext i32 %40 to i64
  %42 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %41
  %43 = getelementptr inbounds nuw %struct.entry, ptr %42, i32 0, i32 1
  store i32 %39, ptr %43, align 8, !tbaa !21
  %44 = load i32, ptr %5, align 4, !tbaa !9
  %45 = zext i32 %44 to i64
  %46 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %45
  %47 = getelementptr inbounds nuw %struct.entry, ptr %46, i32 0, i32 2
  store i32 1, ptr %47, align 4, !tbaa !18
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @get(ptr noundef %0) #0 {
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store ptr %0, ptr %3, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %4) #5
  %6 = load ptr, ptr %3, align 8, !tbaa !15
  %7 = call i32 @hash(ptr noundef %6)
  %8 = urem i32 %7, 64
  store i32 %8, ptr %4, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %31, %1
  %10 = load i32, ptr %4, align 4, !tbaa !9
  %11 = zext i32 %10 to i64
  %12 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %11
  %13 = getelementptr inbounds nuw %struct.entry, ptr %12, i32 0, i32 2
  %14 = load i32, ptr %13, align 4, !tbaa !18
  %15 = icmp ne i32 %14, 0
  br i1 %15, label %16, label %35

16:                                               ; preds = %9
  %17 = load i32, ptr %4, align 4, !tbaa !9
  %18 = zext i32 %17 to i64
  %19 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %18
  %20 = getelementptr inbounds nuw %struct.entry, ptr %19, i32 0, i32 0
  %21 = getelementptr inbounds [16 x i8], ptr %20, i64 0, i64 0
  %22 = load ptr, ptr %3, align 8, !tbaa !15
  %23 = call i32 @strcmp(ptr noundef %21, ptr noundef %22) #6
  %24 = icmp ne i32 %23, 0
  br i1 %24, label %31, label %25

25:                                               ; preds = %16
  %26 = load i32, ptr %4, align 4, !tbaa !9
  %27 = zext i32 %26 to i64
  %28 = getelementptr inbounds nuw [64 x %struct.entry], ptr @table, i64 0, i64 %27
  %29 = getelementptr inbounds nuw %struct.entry, ptr %28, i32 0, i32 1
  %30 = load i32, ptr %29, align 8, !tbaa !21
  store i32 %30, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %36

31:                                               ; preds = %16
  %32 = load i32, ptr %4, align 4, !tbaa !9
  %33 = add i32 %32, 1
  %34 = urem i32 %33, 64
  store i32 %34, ptr %4, align 4, !tbaa !9
  br label %9, !llvm.loop !22

35:                                               ; preds = %9
  store i32 -1, ptr %2, align 4
  store i32 1, ptr %5, align 4
  br label %36

36:                                               ; preds = %35, %25
  call void @llvm.lifetime.end.p0(ptr %4) #5
  %37 = load i32, ptr %2, align 4
  ret i32 %37
}

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: nounwind uwtable
define internal i32 @hash(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !15
  call void @llvm.lifetime.start.p0(ptr %3) #5
  store i32 5381, ptr %3, align 4, !tbaa !9
  br label %4

4:                                                ; preds = %8, %1
  %5 = load ptr, ptr %2, align 8, !tbaa !15
  %6 = load i8, ptr %5, align 1, !tbaa !23
  %7 = icmp ne i8 %6, 0
  br i1 %7, label %8, label %16

8:                                                ; preds = %4
  %9 = load i32, ptr %3, align 4, !tbaa !9
  %10 = mul i32 %9, 33
  %11 = load ptr, ptr %2, align 8, !tbaa !15
  %12 = getelementptr inbounds nuw i8, ptr %11, i32 1
  store ptr %12, ptr %2, align 8, !tbaa !15
  %13 = load i8, ptr %11, align 1, !tbaa !23
  %14 = zext i8 %13 to i32
  %15 = add i32 %10, %14
  store i32 %15, ptr %3, align 4, !tbaa !9
  br label %4, !llvm.loop !24

16:                                               ; preds = %4
  %17 = load i32, ptr %3, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #5
  ret i32 %17
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #4

; Function Attrs: nounwind
declare ptr @strcpy(ptr noundef, ptr noundef) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

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
!12 = !{!13, !13, i64 0}
!13 = !{!"long", !7, i64 0}
!14 = distinct !{!14, !11}
!15 = !{!16, !16, i64 0}
!16 = !{!"p1 omnipotent char", !17, i64 0}
!17 = !{!"any pointer", !7, i64 0}
!18 = !{!19, !6, i64 20}
!19 = !{!"entry", !7, i64 0, !6, i64 16, !6, i64 20}
!20 = distinct !{!20, !11}
!21 = !{!19, !6, i64 16}
!22 = distinct !{!22, !11}
!23 = !{!7, !7, i64 0}
!24 = distinct !{!24, !11}
