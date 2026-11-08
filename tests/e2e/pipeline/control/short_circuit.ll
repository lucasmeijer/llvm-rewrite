; @source: tests/e2e/src/control/short_circuit.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/control/short_circuit.c'
source_filename = "tests/e2e/src/control/short_circuit.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [7 x i8] c"%d %d\0A\00", align 1
@calls = internal global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  store i32 0, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #3
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %7

7:                                                ; preds = %53, %0
  %8 = load i32, ptr %3, align 4, !tbaa !9
  %9 = icmp slt i32 %8, 8
  br i1 %9, label %11, label %10

10:                                               ; preds = %7
  call void @llvm.lifetime.end.p0(ptr %3) #3
  br label %56

11:                                               ; preds = %7
  call void @llvm.lifetime.start.p0(ptr %4) #3
  %12 = load i32, ptr %3, align 4, !tbaa !9
  %13 = and i32 %12, 1
  store i32 %13, ptr %4, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #3
  %14 = load i32, ptr %3, align 4, !tbaa !9
  %15 = ashr i32 %14, 1
  %16 = and i32 %15, 1
  store i32 %16, ptr %5, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %6) #3
  %17 = load i32, ptr %3, align 4, !tbaa !9
  %18 = ashr i32 %17, 2
  %19 = and i32 %18, 1
  store i32 %19, ptr %6, align 4, !tbaa !9
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = call i32 @t(i32 noundef %20)
  %22 = icmp ne i32 %21, 0
  br i1 %22, label %23, label %27

23:                                               ; preds = %11
  %24 = load i32, ptr %5, align 4, !tbaa !9
  %25 = call i32 @t(i32 noundef %24)
  %26 = icmp ne i32 %25, 0
  br i1 %26, label %31, label %27

27:                                               ; preds = %23, %11
  %28 = load i32, ptr %6, align 4, !tbaa !9
  %29 = call i32 @t(i32 noundef %28)
  %30 = icmp ne i32 %29, 0
  br label %31

31:                                               ; preds = %27, %23
  %32 = phi i1 [ true, %23 ], [ %30, %27 ]
  %33 = zext i1 %32 to i32
  %34 = load i32, ptr %2, align 4, !tbaa !9
  %35 = add nsw i32 %34, %33
  store i32 %35, ptr %2, align 4, !tbaa !9
  %36 = load i32, ptr %4, align 4, !tbaa !9
  %37 = call i32 @t(i32 noundef %36)
  %38 = icmp ne i32 %37, 0
  br i1 %38, label %43, label %39

39:                                               ; preds = %31
  %40 = load i32, ptr %5, align 4, !tbaa !9
  %41 = call i32 @t(i32 noundef %40)
  %42 = icmp ne i32 %41, 0
  br i1 %42, label %43, label %48

43:                                               ; preds = %39, %31
  %44 = load i32, ptr %6, align 4, !tbaa !9
  %45 = call i32 @t(i32 noundef %44)
  %46 = icmp ne i32 %45, 0
  %47 = xor i1 %46, true
  br label %48

48:                                               ; preds = %43, %39
  %49 = phi i1 [ false, %39 ], [ %47, %43 ]
  %50 = zext i1 %49 to i32
  %51 = load i32, ptr %2, align 4, !tbaa !9
  %52 = add nsw i32 %51, %50
  store i32 %52, ptr %2, align 4, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  br label %53

53:                                               ; preds = %48
  %54 = load i32, ptr %3, align 4, !tbaa !9
  %55 = add nsw i32 %54, 1
  store i32 %55, ptr %3, align 4, !tbaa !9
  br label %7, !llvm.loop !10

56:                                               ; preds = %10
  %57 = load i32, ptr %2, align 4, !tbaa !9
  %58 = load i32, ptr @calls, align 4, !tbaa !9
  %59 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %57, i32 noundef %58)
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define internal i32 @t(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr @calls, align 4, !tbaa !9
  %4 = add nsw i32 %3, 1
  store i32 %4, ptr @calls, align 4, !tbaa !9
  %5 = load i32, ptr %2, align 4, !tbaa !9
  ret i32 %5
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

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
!9 = !{!6, !6, i64 0}
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
