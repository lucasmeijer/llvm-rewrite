; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/StructModifyTest.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S1Ty = type { i32, float, double, i64 }
%struct.S2Ty = type { %struct.S1Ty, %struct.S1Ty }

@.str = private unnamed_addr constant [18 x i8] c"%d, %f, %f, %lld\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @printS1(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !9
  %3 = load ptr, ptr %2, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw %struct.S1Ty, ptr %3, i32 0, i32 0
  %5 = load i32, ptr %4, align 8, !tbaa !11
  %6 = load ptr, ptr %2, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw %struct.S1Ty, ptr %6, i32 0, i32 1
  %8 = load float, ptr %7, align 4, !tbaa !16
  %9 = fpext float %8 to double
  %10 = load ptr, ptr %2, align 8, !tbaa !9
  %11 = getelementptr inbounds nuw %struct.S1Ty, ptr %10, i32 0, i32 2
  %12 = load double, ptr %11, align 8, !tbaa !17
  %13 = load ptr, ptr %2, align 8, !tbaa !9
  %14 = getelementptr inbounds nuw %struct.S1Ty, ptr %13, i32 0, i32 3
  %15 = load i64, ptr %14, align 8, !tbaa !18
  %16 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %5, double noundef %9, double noundef %12, i64 noundef %15)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.S2Ty, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  %3 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %4 = getelementptr inbounds nuw %struct.S1Ty, ptr %3, i32 0, i32 0
  store i32 1, ptr %4, align 8, !tbaa !19
  %5 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %6 = getelementptr inbounds nuw %struct.S1Ty, ptr %5, i32 0, i32 1
  store float 1.234200e+02, ptr %6, align 4, !tbaa !21
  %7 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %8 = getelementptr inbounds nuw %struct.S1Ty, ptr %7, i32 0, i32 2
  store double 1.900000e+01, ptr %8, align 8, !tbaa !22
  %9 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  %10 = getelementptr inbounds nuw %struct.S1Ty, ptr %9, i32 0, i32 3
  store i64 123455678902, ptr %10, align 8, !tbaa !23
  %11 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %12 = getelementptr inbounds nuw %struct.S1Ty, ptr %11, i32 0, i32 0
  store i32 2, ptr %12, align 8, !tbaa !24
  %13 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %14 = getelementptr inbounds nuw %struct.S1Ty, ptr %13, i32 0, i32 1
  store float 2.342000e+01, ptr %14, align 4, !tbaa !25
  %15 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %16 = getelementptr inbounds nuw %struct.S1Ty, ptr %15, i32 0, i32 2
  store double 2.900000e+01, ptr %16, align 8, !tbaa !26
  %17 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  %18 = getelementptr inbounds nuw %struct.S1Ty, ptr %17, i32 0, i32 3
  store i64 23455678902, ptr %18, align 8, !tbaa !27
  %19 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 0
  call void @printS1(ptr noundef %19)
  %20 = getelementptr inbounds nuw %struct.S2Ty, ptr %2, i32 0, i32 1
  call void @printS1(ptr noundef %20)
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"any pointer", !7, i64 0}
!11 = !{!12, !6, i64 0}
!12 = !{!"", !6, i64 0, !13, i64 4, !14, i64 8, !15, i64 16}
!13 = !{!"float", !7, i64 0}
!14 = !{!"double", !7, i64 0}
!15 = !{!"long long", !7, i64 0}
!16 = !{!12, !13, i64 4}
!17 = !{!12, !14, i64 8}
!18 = !{!12, !15, i64 16}
!19 = !{!20, !6, i64 0}
!20 = !{!"", !12, i64 0, !12, i64 24}
!21 = !{!20, !13, i64 4}
!22 = !{!20, !14, i64 8}
!23 = !{!20, !15, i64 16}
!24 = !{!20, !6, i64 24}
!25 = !{!20, !13, i64 28}
!26 = !{!20, !14, i64 32}
!27 = !{!20, !15, i64 40}
