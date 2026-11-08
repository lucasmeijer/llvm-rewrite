; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2002-10-12-StructureArgs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.vec2 = type { double, double }

@.str = private unnamed_addr constant [16 x i8] c"%f, %f, %f, %f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @print(double %0, double %1, double %2, double %3) #0 {
  %5 = alloca %struct.vec2, align 8
  %6 = alloca %struct.vec2, align 8
  %7 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 0
  store double %0, ptr %7, align 8
  %8 = getelementptr inbounds nuw { double, double }, ptr %5, i32 0, i32 1
  store double %1, ptr %8, align 8
  %9 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 0
  store double %2, ptr %9, align 8
  %10 = getelementptr inbounds nuw { double, double }, ptr %6, i32 0, i32 1
  store double %3, ptr %10, align 8
  %11 = getelementptr inbounds nuw %struct.vec2, ptr %5, i32 0, i32 0
  %12 = load double, ptr %11, align 8, !tbaa !9
  %13 = getelementptr inbounds nuw %struct.vec2, ptr %5, i32 0, i32 1
  %14 = load double, ptr %13, align 8, !tbaa !12
  %15 = getelementptr inbounds nuw %struct.vec2, ptr %6, i32 0, i32 0
  %16 = load double, ptr %15, align 8, !tbaa !9
  %17 = getelementptr inbounds nuw %struct.vec2, ptr %6, i32 0, i32 1
  %18 = load double, ptr %17, align 8, !tbaa !12
  %19 = call i32 (ptr, ...) @printf(ptr noundef @.str, double noundef %12, double noundef %14, double noundef %16, double noundef %18)
  ret void
}

declare i32 @printf(ptr noundef, ...) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.vec2, align 8
  %3 = alloca %struct.vec2, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  %4 = getelementptr inbounds nuw %struct.vec2, ptr %2, i32 0, i32 0
  store double 5.000000e-01, ptr %4, align 8, !tbaa !9
  %5 = getelementptr inbounds nuw %struct.vec2, ptr %2, i32 0, i32 1
  store double 1.200000e+00, ptr %5, align 8, !tbaa !12
  %6 = getelementptr inbounds nuw %struct.vec2, ptr %3, i32 0, i32 0
  store double -1.230100e+02, ptr %6, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw %struct.vec2, ptr %3, i32 0, i32 1
  store double f0x3FD5555555555555, ptr %7, align 8, !tbaa !12
  %8 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 0
  %9 = load double, ptr %8, align 8
  %10 = getelementptr inbounds nuw { double, double }, ptr %2, i32 0, i32 1
  %11 = load double, ptr %10, align 8
  %12 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 0
  %13 = load double, ptr %12, align 8
  %14 = getelementptr inbounds nuw { double, double }, ptr %3, i32 0, i32 1
  %15 = load double, ptr %14, align 8
  call void @print(double %9, double %11, double %13, double %15)
  call void @llvm.lifetime.end.p0(ptr %3) #3
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
!9 = !{!10, !11, i64 0}
!10 = !{!"vec2", !11, i64 0, !11, i64 8}
!11 = !{!"double", !7, i64 0}
!12 = !{!10, !11, i64 8}
