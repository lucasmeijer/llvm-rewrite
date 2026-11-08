; @source: tests/e2e/src/float/libm.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/float/libm.c'
source_filename = "tests/e2e/src/float/libm.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [31 x i8] c"%.12f %.12f %.12f %.12f %.12f\0A\00", align 1
@.str.1 = private unnamed_addr constant [21 x i8] c"%.3f %.3f %.3f %.3f\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"%.6f %.6f\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef f0x3FD43D136248490F, double noundef f0x3FB98EAECB8BCB2C, double noundef f0x3FF1AEC7B35A00D4, double noundef f0xC0026BB1BBB55515, double noundef f0x3FA030DC4EA03A73)
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef f0x3FEC9F25C5BFEDD9, double noundef f0x3FE6F494C2BFFECC, double noundef f0x4001CDE866FE46E8, double noundef f0xBFCC8FF7C79A9A25, double noundef f0x3FE6E5B7D16657E0)
  %3 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef f0x3FF3988E1409212E, double noundef f0x3FEFEB7A9B2C6D8B, double noundef f0x4011ED3FE64FC541, double noundef f0x3FD9F323ECBF984C, double noundef f0x3FFD64D51E0DB1C6)
  %4 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef f0x3FF7BB598C88B4AD, double noundef f0x3FE9DF33D9AAD708, double noundef f0x40220CCE91C40E5F, double noundef f0x3FE93B0AEE21C2C9, double noundef f0x400A1AE280FCC6BF)
  %5 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef f0x3FFB3F3C957429DB, double noundef f0x3FCE9FB8D64830D3, double noundef f0x40322C94CA7A8200, double noundef f0x3FF1090E20315213, double noundef f0x4013C10BEC5A9E59)
  %6 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef -3.000000e+00, double noundef -2.000000e+00, double noundef 3.250000e+00, double noundef 1.500000e+00)
  %7 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, double noundef f0x3FF6A09E60000000, double noundef 1.000000e+00)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

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
