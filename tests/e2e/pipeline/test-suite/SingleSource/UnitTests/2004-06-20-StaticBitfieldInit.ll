; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2004-06-20-StaticBitfieldInit.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2004-06-20-StaticBitfieldInit.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2004-06-20-StaticBitfieldInit.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@GV = dso_local global { i8, i8, [2 x i8] } { i8 -95, i8 8, [2 x i8] zeroinitializer }, align 4
@.str = private unnamed_addr constant [10 x i8] c"%d %d %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  %2 = load i16, ptr @GV, align 4
  %3 = and i16 %2, 31
  %4 = zext i16 %3 to i32
  %5 = load i16, ptr @GV, align 4
  %6 = lshr i16 %5, 5
  %7 = and i16 %6, 63
  %8 = zext i16 %7 to i32
  %9 = load i16, ptr @GV, align 4
  %10 = lshr i16 %9, 11
  %11 = zext i16 %10 to i32
  %12 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4, i32 noundef %8, i32 noundef %11)
  ret i32 0
}

declare i32 @printf(ptr noundef, ...) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
