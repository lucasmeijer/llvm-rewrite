; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2009-12-07-StructReturn.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.barstruct = type { %struct.foostruct, float }
%struct.foostruct = type { [3 x float] }

@bar_ary = dso_local global [4 x %struct.barstruct] zeroinitializer, align 16
@foobify.my_static_foo = internal global %struct.barstruct { %struct.foostruct { [3 x float] [float 4.200000e+01, float 4.200000e+01, float 4.200000e+01] }, float 4.200000e+01 }, align 4
@.str = private unnamed_addr constant [51 x i8] c"error: store clobbered memory outside destination\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local ptr @spooky(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = sext i32 %3 to i64
  %5 = getelementptr inbounds [4 x %struct.barstruct], ptr @bar_ary, i64 0, i64 %4
  %6 = getelementptr inbounds nuw %struct.barstruct, ptr %5, i32 0, i32 1
  store float 1.420000e+02, ptr %6, align 4, !tbaa !10
  %7 = load i32, ptr %2, align 4, !tbaa !9
  %8 = sext i32 %7 to i64
  %9 = getelementptr inbounds [4 x %struct.barstruct], ptr @bar_ary, i64 0, i64 %8
  %10 = getelementptr inbounds nuw %struct.barstruct, ptr %9, i32 0, i32 1
  ret ptr %10
}

; Function Attrs: noinline nounwind uwtable
define dso_local { <2 x float>, float } @foobify() #0 {
  %1 = alloca %struct.foostruct, align 4
  %2 = alloca { <2 x float>, float }, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %1, ptr align 4 @foobify.my_static_foo, i64 12, i1 false), !tbaa.struct !14
  %3 = getelementptr inbounds nuw %struct.foostruct, ptr %1, i32 0, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %2, ptr align 4 %3, i64 12, i1 false)
  %4 = load { <2 x float>, float }, ptr %2, align 8
  ret { <2 x float>, float } %4
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #2 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca %struct.foostruct, align 4
  %8 = alloca { <2 x float>, float }, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !16
  call void @llvm.lifetime.start.p0(ptr %6) #5
  %9 = call ptr @spooky(i32 noundef 0)
  store ptr %9, ptr %6, align 8, !tbaa !20
  call void @llvm.lifetime.start.p0(ptr %7) #5
  %10 = call { <2 x float>, float } @foobify()
  %11 = getelementptr inbounds nuw %struct.foostruct, ptr %7, i32 0, i32 0
  store { <2 x float>, float } %10, ptr %8, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %11, ptr align 8 %8, i64 12, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 16 @bar_ary, ptr align 4 %7, i64 12, i1 false), !tbaa.struct !14
  call void @llvm.lifetime.end.p0(ptr %7) #5
  %12 = load ptr, ptr %6, align 8, !tbaa !20
  %13 = load float, ptr %12, align 4, !tbaa !22
  %14 = fpext float %13 to double
  %15 = fcmp une double %14, 1.420000e+02
  br i1 %15, label %16, label %18

16:                                               ; preds = %2
  %17 = call i32 (ptr, ...) @printf(ptr noundef @.str)
  call void @abort() #6
  unreachable

18:                                               ; preds = %2
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: noreturn nounwind
declare void @abort() #4

attributes #0 = { noinline nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind uwtable "min-legal-vector-width"="64" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { noreturn nounwind }

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
!10 = !{!11, !13, i64 12}
!11 = !{!"", !12, i64 0, !13, i64 12}
!12 = !{!"", !7, i64 0}
!13 = !{!"float", !7, i64 0}
!14 = !{i64 0, i64 12, !15}
!15 = !{!7, !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"p2 omnipotent char", !18, i64 0}
!18 = !{!"any p2 pointer", !19, i64 0}
!19 = !{!"any pointer", !7, i64 0}
!20 = !{!21, !21, i64 0}
!21 = !{!"p1 float", !19, i64 0}
!22 = !{!13, !13, i64 0}
