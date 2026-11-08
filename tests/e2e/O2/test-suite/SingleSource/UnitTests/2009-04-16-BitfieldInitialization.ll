; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2009-04-16-BitfieldInitialization.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2009-04-16-BitfieldInitialization.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2009-04-16-BitfieldInitialization.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.ty2 = type <{ float, i8, i32 }>
%struct.ty4 = type <{ x86_fp80, i8, x86_fp80 }>
%struct.anon = type { i8, i8 }
%struct.anon.2 = type <{ x86_fp80, i8 }>
%struct.t10s = type <{ i16, [2 x i8], ptr }>

@t1 = dso_local local_unnamed_addr global { i32, [4 x i8], { i32, [4 x i8] } } { i32 101, [4 x i8] zeroinitializer, { i32, [4 x i8] } { i32 1, [4 x i8] zeroinitializer } }, align 8
@t2 = dso_local local_unnamed_addr global %struct.ty2 <{ float 1.010000e+02, i8 1, i32 204 }>, align 4
@t3 = dso_local global <{ i32, [3 x i8] }> <{ i32 4, [3 x i8] c"fo\00" }>, align 4
@t4 = dso_local local_unnamed_addr global %struct.ty4 <{ x86_fp80 1.000000e+00, i8 4, x86_fp80 1.700000e+01 }>, align 16
@t5a = dso_local local_unnamed_addr global %struct.anon { i8 101, i8 15 }, align 1
@t5b = dso_local local_unnamed_addr global { i8, i8, i8 } { i8 101, i8 -49, i8 4 }, align 1
@t5 = dso_local local_unnamed_addr global { i8, i8, i8 } { i8 101, i8 -65, i8 7 }, align 1
@t6 = dso_local local_unnamed_addr global %struct.anon.2 <{ x86_fp80 f0x4005F6D2F1A9FBE77000, i8 5 }>, align 16
@t7 = dso_local local_unnamed_addr global { i8, i8, i8 } { i8 101, i8 63, i8 0 }, align 1
@t7a = dso_local local_unnamed_addr global { i8, i8, i8 } { i8 101, i8 -65, i8 7 }, align 1
@t8 = dso_local local_unnamed_addr global { i8, [7 x i8], ptr, i8, [7 x i8] } { i8 16, [7 x i8] zeroinitializer, ptr null, i8 32, [7 x i8] zeroinitializer }, align 8
@t9 = dso_local local_unnamed_addr global { ptr, i8, i8, i8, i8, [4 x i8] } { ptr null, i8 123, i8 0, i8 -56, i8 1, [4 x i8] zeroinitializer }, align 8
@x = dso_local global i32 42, align 4
@t10 = dso_local local_unnamed_addr global %struct.t10s <{ i16 0, [2 x i8] zeroinitializer, ptr @x }>, align 4
@.str = private unnamed_addr constant [11 x i8] c"1: %d, %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [15 x i8] c"2: %f, %d, %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [10 x i8] c"3: %d %s\0A\00", align 1
@.str.3 = private unnamed_addr constant [13 x i8] c"4: %f %d %f\0A\00", align 1
@.str.4 = private unnamed_addr constant [13 x i8] c"5: %d %d %d\0A\00", align 1
@.str.5 = private unnamed_addr constant [11 x i8] c"5a: %d %d\0A\00", align 1
@.str.6 = private unnamed_addr constant [11 x i8] c"5b: %d %d\0A\00", align 1
@.str.7 = private unnamed_addr constant [11 x i8] c"6: %Lf %d\0A\00", align 1
@.str.8 = private unnamed_addr constant [16 x i8] c"7: %d %d %d %d\0A\00", align 1
@.str.9 = private unnamed_addr constant [14 x i8] c"7a: %d %d %d\0A\00", align 1
@.str.10 = private unnamed_addr constant [10 x i8] c"8: %d %d\0A\00", align 1
@.str.11 = private unnamed_addr constant [10 x i8] c"9: %d %d\0A\00", align 1
@.str.12 = private unnamed_addr constant [8 x i8] c"10: %d\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = load i32, ptr @t1, align 8, !tbaa !9
  %2 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t1, i64 8), align 8, !tbaa !11
  %3 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %1, i32 noundef %2)
  %4 = load float, ptr @t2, align 4, !tbaa !12
  %5 = fpext float %4 to double
  %6 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t2, i64 4), align 4, !tbaa !15
  %7 = sext i8 %6 to i32
  %8 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t2, i64 5), align 1, !tbaa !16
  %9 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %5, i32 noundef %7, i32 noundef %8)
  %10 = load i32, ptr @t3, align 4, !tbaa !17
  %11 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, i32 noundef %10, ptr noundef nonnull getelementptr inbounds nuw (i8, ptr @t3, i64 4))
  %12 = load x86_fp80, ptr @t4, align 16, !tbaa !18
  %13 = fptrunc x86_fp80 %12 to double
  %14 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t4, i64 16), align 16, !tbaa !21
  %15 = sext i8 %14 to i32
  %16 = load x86_fp80, ptr getelementptr inbounds nuw (i8, ptr @t4, i64 17), align 1, !tbaa !22
  %17 = fptrunc x86_fp80 %16 to double
  %18 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, double noundef %13, i32 noundef %15, double noundef %17)
  %19 = load i8, ptr @t5, align 1, !tbaa !23
  %20 = sext i8 %19 to i32
  %21 = load i16, ptr getelementptr inbounds nuw (i8, ptr @t5, i64 1), align 1
  %22 = and i16 %21, 15
  %23 = zext nneg i16 %22 to i32
  %24 = lshr i16 %21, 4
  %25 = and i16 %24, 127
  %26 = zext nneg i16 %25 to i32
  %27 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.4, i32 noundef %20, i32 noundef %23, i32 noundef %26)
  %28 = load i8, ptr @t5a, align 1, !tbaa !25
  %29 = sext i8 %28 to i32
  %30 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t5a, i64 1), align 1
  %31 = and i8 %30, 15
  %32 = zext nneg i8 %31 to i32
  %33 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.5, i32 noundef %29, i32 noundef %32)
  %34 = load i8, ptr @t5b, align 1, !tbaa !27
  %35 = sext i8 %34 to i32
  %36 = load i16, ptr getelementptr inbounds nuw (i8, ptr @t5b, i64 1), align 1
  %37 = and i16 %36, 4095
  %38 = zext nneg i16 %37 to i32
  %39 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.6, i32 noundef %35, i32 noundef %38)
  %40 = load x86_fp80, ptr @t6, align 16, !tbaa !30
  %41 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t6, i64 16), align 16
  %42 = and i8 %41, 15
  %43 = zext nneg i8 %42 to i32
  %44 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.7, x86_fp80 noundef %40, i32 noundef %43)
  %45 = load i8, ptr @t7, align 1, !tbaa !32
  %46 = sext i8 %45 to i32
  %47 = load i16, ptr getelementptr inbounds nuw (i8, ptr @t7, i64 1), align 1
  %48 = and i16 %47, 15
  %49 = zext nneg i16 %48 to i32
  %50 = lshr i16 %47, 4
  %51 = and i16 %50, 7
  %52 = zext nneg i16 %51 to i32
  %53 = lshr i16 %47, 7
  %54 = and i16 %53, 127
  %55 = zext nneg i16 %54 to i32
  %56 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.8, i32 noundef %46, i32 noundef %49, i32 noundef %52, i32 noundef %55)
  %57 = load i8, ptr @t7a, align 1, !tbaa !34
  %58 = sext i8 %57 to i32
  %59 = load i16, ptr getelementptr inbounds nuw (i8, ptr @t7a, i64 1), align 1
  %60 = and i16 %59, 15
  %61 = zext nneg i16 %60 to i32
  %62 = lshr i16 %59, 4
  %63 = zext nneg i16 %62 to i32
  %64 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.9, i32 noundef %58, i32 noundef %61, i32 noundef %63)
  %65 = load i8, ptr @t8, align 8, !tbaa !36
  %66 = sext i8 %65 to i32
  %67 = load i8, ptr getelementptr inbounds nuw (i8, ptr @t8, i64 16), align 8, !tbaa !40
  %68 = sext i8 %67 to i32
  %69 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.10, i32 noundef %66, i32 noundef %68)
  %70 = load i32, ptr getelementptr inbounds nuw (i8, ptr @t9, i64 8), align 8
  %71 = and i32 %70, 65535
  %72 = ashr i32 %70, 16
  %73 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.11, i32 noundef %71, i32 noundef %72)
  %74 = load ptr, ptr getelementptr inbounds nuw (i8, ptr @t10, i64 4), align 4, !tbaa !41
  %75 = load i32, ptr %74, align 4, !tbaa !17
  %76 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.12, i32 noundef %75)
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
!9 = !{!10, !6, i64 0}
!10 = !{!"ty", !6, i64 0, !7, i64 8}
!11 = !{!7, !7, i64 0}
!12 = !{!13, !14, i64 0}
!13 = !{!"ty2", !14, i64 0, !7, i64 4, !6, i64 5}
!14 = !{!"float", !7, i64 0}
!15 = !{!13, !7, i64 4}
!16 = !{!13, !6, i64 5}
!17 = !{!6, !6, i64 0}
!18 = !{!19, !20, i64 0}
!19 = !{!"ty4", !20, i64 0, !7, i64 16, !20, i64 17}
!20 = !{!"long double", !7, i64 0}
!21 = !{!19, !7, i64 16}
!22 = !{!19, !20, i64 17}
!23 = !{!24, !7, i64 0}
!24 = !{!"", !7, i64 0, !7, i64 1, !7, i64 1}
!25 = !{!26, !7, i64 0}
!26 = !{!"", !7, i64 0, !7, i64 1}
!27 = !{!28, !7, i64 0}
!28 = !{!"", !7, i64 0, !29, i64 1}
!29 = !{!"short", !7, i64 0}
!30 = !{!31, !20, i64 0}
!31 = !{!"", !20, i64 0, !7, i64 16}
!32 = !{!33, !7, i64 0}
!33 = !{!"", !7, i64 0, !7, i64 1, !7, i64 1, !7, i64 1}
!34 = !{!35, !7, i64 0}
!35 = !{!"", !7, i64 0, !29, i64 1, !29, i64 1}
!36 = !{!37, !7, i64 0}
!37 = !{!"sDescrItem", !7, i64 0, !38, i64 8, !7, i64 16}
!38 = !{!"p1 omnipotent char", !39, i64 0}
!39 = !{!"any pointer", !7, i64 0}
!40 = !{!37, !7, i64 16}
!41 = !{!42, !43, i64 4}
!42 = !{!"t10s", !29, i64 0, !43, i64 4}
!43 = !{!"p1 int", !39, i64 0}
