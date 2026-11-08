; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/conditional-gnu-ext.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/conditional-gnu-ext.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/conditional-gnu-ext.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@getComplex.count = internal global i32 0, align 4

; Function Attrs: nounwind uwtable
define dso_local i64 @getComplex(i64 noundef %0) #0 {
  %2 = alloca { i32, i32 }, align 4
  %3 = alloca { i32, i32 }, align 4
  store i64 %0, ptr %3, align 4
  %4 = load i32, ptr @getComplex.count, align 4, !tbaa !9
  %5 = add nsw i32 %4, 1
  store i32 %5, ptr @getComplex.count, align 4, !tbaa !9
  %6 = icmp ne i32 %4, 0
  br i1 %6, label %7, label %8

7:                                                ; preds = %1
  call void @abort() #3
  unreachable

8:                                                ; preds = %1
  %9 = getelementptr inbounds nuw { i32, i32 }, ptr %3, i32 0, i32 0
  %10 = load i32, ptr %9, align 4
  %11 = getelementptr inbounds nuw { i32, i32 }, ptr %3, i32 0, i32 1
  %12 = load i32, ptr %11, align 4
  %13 = getelementptr inbounds nuw { i32, i32 }, ptr %2, i32 0, i32 0
  %14 = getelementptr inbounds nuw { i32, i32 }, ptr %2, i32 0, i32 1
  store i32 %10, ptr %13, align 4
  store i32 %12, ptr %14, align 4
  %15 = load i64, ptr %2, align 4
  ret i64 %15
}

; Function Attrs: noreturn nounwind
declare void @abort() #1

; Function Attrs: nounwind uwtable
define dso_local i64 @doo() #0 {
  %1 = alloca { i32, i32 }, align 4
  %2 = alloca { i32, i32 }, align 4
  %3 = alloca { i32, i32 }, align 4
  %4 = alloca { i32, i32 }, align 4
  %5 = alloca { i32, i32 }, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4
  call void @llvm.lifetime.start.p0(ptr %3) #4
  %6 = getelementptr inbounds nuw { i32, i32 }, ptr %4, i32 0, i32 0
  %7 = getelementptr inbounds nuw { i32, i32 }, ptr %4, i32 0, i32 1
  store i32 1, ptr %6, align 4
  store i32 2, ptr %7, align 4
  %8 = load i64, ptr %4, align 4
  %9 = call i64 @getComplex(i64 noundef %8)
  store i64 %9, ptr %5, align 4
  %10 = getelementptr inbounds nuw { i32, i32 }, ptr %5, i32 0, i32 0
  %11 = load i32, ptr %10, align 4
  %12 = getelementptr inbounds nuw { i32, i32 }, ptr %5, i32 0, i32 1
  %13 = load i32, ptr %12, align 4
  %14 = icmp ne i32 %11, 0
  %15 = icmp ne i32 %13, 0
  %16 = or i1 %14, %15
  br i1 %16, label %17, label %18

17:                                               ; preds = %0
  br label %23

18:                                               ; preds = %0
  %19 = getelementptr inbounds nuw { i32, i32 }, ptr %3, i32 0, i32 0
  %20 = load i32, ptr %19, align 4
  %21 = getelementptr inbounds nuw { i32, i32 }, ptr %3, i32 0, i32 1
  %22 = load i32, ptr %21, align 4
  br label %23

23:                                               ; preds = %18, %17
  %24 = phi i32 [ %11, %17 ], [ %20, %18 ]
  %25 = phi i32 [ %13, %17 ], [ %22, %18 ]
  %26 = getelementptr inbounds nuw { i32, i32 }, ptr %1, i32 0, i32 0
  %27 = getelementptr inbounds nuw { i32, i32 }, ptr %1, i32 0, i32 1
  store i32 %24, ptr %26, align 4
  store i32 %25, ptr %27, align 4
  call void @llvm.lifetime.end.p0(ptr %3) #4
  call void @llvm.lifetime.end.p0(ptr %2) #4
  %28 = load i64, ptr %1, align 4
  ret i64 %28
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca { i32, i32 }, align 4
  store i32 0, ptr %1, align 4
  %3 = call i64 @doo()
  store i64 %3, ptr %2, align 4
  %4 = getelementptr inbounds nuw { i32, i32 }, ptr %2, i32 0, i32 0
  %5 = load i32, ptr %4, align 4
  %6 = getelementptr inbounds nuw { i32, i32 }, ptr %2, i32 0, i32 1
  %7 = load i32, ptr %6, align 4
  ret i32 0
}

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { noreturn nounwind }
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
