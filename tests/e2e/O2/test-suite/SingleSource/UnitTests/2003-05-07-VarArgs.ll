; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }
%struct.DWordS_struct = type { i32, i8 }
%struct.LargeS_struct = type { i32, double, ptr, i32 }

@.str = private unnamed_addr constant [11 x i8] c"string %s\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"int %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"double %f\0A\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"long long %lld\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"char %c\0A\00", align 1
@.str.5 = private unnamed_addr constant [18 x i8] c"DWord { %d, %c }\0A\00", align 1
@.str.6 = private unnamed_addr constant [21 x i8] c"QuadWord { %d, %f }\0A\00", align 1
@.str.7 = private unnamed_addr constant [29 x i8] c"LargeS { %d, %f, 0x%d, %d }\0A\00", align 1
@.str.8 = private unnamed_addr constant [11 x i8] c"ssiciiiiis\00", align 1
@.str.9 = private unnamed_addr constant [4 x i8] c"abc\00", align 1
@.str.10 = private unnamed_addr constant [4 x i8] c"def\00", align 1
@.str.11 = private unnamed_addr constant [14 x i8] c"10 args done!\00", align 1
@.str.12 = private unnamed_addr constant [5 x i8] c"ddil\00", align 1
@.str.13 = private unnamed_addr constant [4 x i8] c"DQL\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local void @test(ptr nofree noundef readonly captures(none) %0, ...) local_unnamed_addr #0 {
  %2 = alloca [1 x %struct.__va_list_tag], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #4
  call void @llvm.va_start.p0(ptr nonnull %2)
  %3 = load i8, ptr %0, align 1, !tbaa !9
  %4 = icmp eq i8 %3, 0
  br i1 %4, label %150, label %5

5:                                                ; preds = %1
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 4
  %8 = getelementptr inbounds nuw i8, ptr %2, i64 16
  br label %9

9:                                                ; preds = %5, %147
  %10 = phi i8 [ %3, %5 ], [ %148, %147 ]
  %11 = phi ptr [ %0, %5 ], [ %12, %147 ]
  %12 = getelementptr inbounds nuw i8, ptr %11, i64 1
  switch i8 %10, label %147 [
    i8 115, label %13
    i8 105, label %28
    i8 100, label %43
    i8 108, label %58
    i8 99, label %73
    i8 68, label %90
    i8 81, label %108
    i8 76, label %134
  ]

13:                                               ; preds = %9
  %14 = load i32, ptr %2, align 16
  %15 = icmp ult i32 %14, 41
  br i1 %15, label %16, label %21

16:                                               ; preds = %13
  %17 = load ptr, ptr %8, align 16
  %18 = zext nneg i32 %14 to i64
  %19 = getelementptr i8, ptr %17, i64 %18
  %20 = add nuw nsw i32 %14, 8
  store i32 %20, ptr %2, align 16
  br label %24

21:                                               ; preds = %13
  %22 = load ptr, ptr %6, align 8
  %23 = getelementptr i8, ptr %22, i64 8
  store ptr %23, ptr %6, align 8
  br label %24

24:                                               ; preds = %21, %16
  %25 = phi ptr [ %19, %16 ], [ %22, %21 ]
  %26 = load ptr, ptr %25, align 8, !tbaa !10
  %27 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, ptr noundef %26)
  br label %147

28:                                               ; preds = %9
  %29 = load i32, ptr %2, align 16
  %30 = icmp ult i32 %29, 41
  br i1 %30, label %31, label %36

31:                                               ; preds = %28
  %32 = load ptr, ptr %8, align 16
  %33 = zext nneg i32 %29 to i64
  %34 = getelementptr i8, ptr %32, i64 %33
  %35 = add nuw nsw i32 %29, 8
  store i32 %35, ptr %2, align 16
  br label %39

36:                                               ; preds = %28
  %37 = load ptr, ptr %6, align 8
  %38 = getelementptr i8, ptr %37, i64 8
  store ptr %38, ptr %6, align 8
  br label %39

39:                                               ; preds = %36, %31
  %40 = phi ptr [ %34, %31 ], [ %37, %36 ]
  %41 = load i32, ptr %40, align 4, !tbaa !13
  %42 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %41)
  br label %147

43:                                               ; preds = %9
  %44 = load i32, ptr %7, align 4
  %45 = icmp ult i32 %44, 161
  br i1 %45, label %46, label %51

46:                                               ; preds = %43
  %47 = load ptr, ptr %8, align 16
  %48 = zext nneg i32 %44 to i64
  %49 = getelementptr i8, ptr %47, i64 %48
  %50 = add nuw nsw i32 %44, 16
  store i32 %50, ptr %7, align 4
  br label %54

51:                                               ; preds = %43
  %52 = load ptr, ptr %6, align 8
  %53 = getelementptr i8, ptr %52, i64 8
  store ptr %53, ptr %6, align 8
  br label %54

54:                                               ; preds = %51, %46
  %55 = phi ptr [ %49, %46 ], [ %52, %51 ]
  %56 = load double, ptr %55, align 8, !tbaa !14
  %57 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.2, double noundef %56)
  br label %147

58:                                               ; preds = %9
  %59 = load i32, ptr %2, align 16
  %60 = icmp ult i32 %59, 41
  br i1 %60, label %61, label %66

61:                                               ; preds = %58
  %62 = load ptr, ptr %8, align 16
  %63 = zext nneg i32 %59 to i64
  %64 = getelementptr i8, ptr %62, i64 %63
  %65 = add nuw nsw i32 %59, 8
  store i32 %65, ptr %2, align 16
  br label %69

66:                                               ; preds = %58
  %67 = load ptr, ptr %6, align 8
  %68 = getelementptr i8, ptr %67, i64 8
  store ptr %68, ptr %6, align 8
  br label %69

69:                                               ; preds = %66, %61
  %70 = phi ptr [ %64, %61 ], [ %67, %66 ]
  %71 = load i64, ptr %70, align 8, !tbaa !16
  %72 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.3, i64 noundef %71)
  br label %147

73:                                               ; preds = %9
  %74 = load i32, ptr %2, align 16
  %75 = icmp ult i32 %74, 41
  br i1 %75, label %76, label %81

76:                                               ; preds = %73
  %77 = load ptr, ptr %8, align 16
  %78 = zext nneg i32 %74 to i64
  %79 = getelementptr i8, ptr %77, i64 %78
  %80 = add nuw nsw i32 %74, 8
  store i32 %80, ptr %2, align 16
  br label %84

81:                                               ; preds = %73
  %82 = load ptr, ptr %6, align 8
  %83 = getelementptr i8, ptr %82, i64 8
  store ptr %83, ptr %6, align 8
  br label %84

84:                                               ; preds = %81, %76
  %85 = phi ptr [ %79, %76 ], [ %82, %81 ]
  %86 = load i32, ptr %85, align 4, !tbaa !13
  %87 = shl i32 %86, 24
  %88 = ashr exact i32 %87, 24
  %89 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.4, i32 noundef %88)
  br label %147

90:                                               ; preds = %9
  %91 = load i32, ptr %2, align 16
  %92 = icmp ult i32 %91, 41
  br i1 %92, label %93, label %98

93:                                               ; preds = %90
  %94 = load ptr, ptr %8, align 16
  %95 = zext nneg i32 %91 to i64
  %96 = getelementptr i8, ptr %94, i64 %95
  %97 = add nuw nsw i32 %91, 8
  store i32 %97, ptr %2, align 16
  br label %101

98:                                               ; preds = %90
  %99 = load ptr, ptr %6, align 8
  %100 = getelementptr i8, ptr %99, i64 8
  store ptr %100, ptr %6, align 8
  br label %101

101:                                              ; preds = %98, %93
  %102 = phi ptr [ %96, %93 ], [ %99, %98 ]
  %103 = load i32, ptr %102, align 4, !tbaa !13
  %104 = getelementptr inbounds nuw i8, ptr %102, i64 4
  %105 = load i8, ptr %104, align 4, !tbaa !9
  %106 = sext i8 %105 to i32
  %107 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.5, i32 noundef %103, i32 noundef %106)
  br label %147

108:                                              ; preds = %9
  %109 = load i32, ptr %2, align 16
  %110 = icmp ult i32 %109, 41
  %111 = load i32, ptr %7, align 4
  %112 = icmp ult i32 %111, 161
  %113 = and i1 %110, %112
  br i1 %113, label %114, label %124

114:                                              ; preds = %108
  %115 = load ptr, ptr %8, align 16
  %116 = zext nneg i32 %109 to i64
  %117 = getelementptr i8, ptr %115, i64 %116
  %118 = zext nneg i32 %111 to i64
  %119 = getelementptr i8, ptr %115, i64 %118
  %120 = load i32, ptr %117, align 4
  %121 = load double, ptr %119, align 8
  %122 = add nuw nsw i32 %109, 8
  store i32 %122, ptr %2, align 16
  %123 = add nuw nsw i32 %111, 16
  store i32 %123, ptr %7, align 4
  br label %130

124:                                              ; preds = %108
  %125 = load ptr, ptr %6, align 8
  %126 = getelementptr i8, ptr %125, i64 16
  store ptr %126, ptr %6, align 8
  %127 = load i32, ptr %125, align 8, !tbaa !13
  %128 = getelementptr inbounds nuw i8, ptr %125, i64 8
  %129 = load double, ptr %128, align 8, !tbaa !14
  br label %130

130:                                              ; preds = %124, %114
  %131 = phi double [ %121, %114 ], [ %129, %124 ]
  %132 = phi i32 [ %120, %114 ], [ %127, %124 ]
  %133 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.6, i32 noundef %132, double noundef %131)
  br label %147

134:                                              ; preds = %9
  %135 = load ptr, ptr %6, align 8
  %136 = getelementptr i8, ptr %135, i64 32
  store ptr %136, ptr %6, align 8
  %137 = load i32, ptr %135, align 8, !tbaa !13
  %138 = getelementptr inbounds nuw i8, ptr %135, i64 8
  %139 = load double, ptr %138, align 8, !tbaa !14
  %140 = getelementptr inbounds nuw i8, ptr %135, i64 16
  %141 = load ptr, ptr %140, align 8, !tbaa !18
  %142 = getelementptr inbounds nuw i8, ptr %135, i64 24
  %143 = load i32, ptr %142, align 8, !tbaa !13
  %144 = icmp ne ptr %141, null
  %145 = zext i1 %144 to i32
  %146 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.7, i32 noundef %137, double noundef %139, i32 noundef %145, i32 noundef %143)
  br label %147

147:                                              ; preds = %9, %134, %130, %101, %84, %69, %54, %39, %24
  %148 = load i8, ptr %12, align 1, !tbaa !9
  %149 = icmp eq i8 %148, 0
  br i1 %149, label %150, label %9, !llvm.loop !20

150:                                              ; preds = %147, %1
  call void @llvm.va_end.p0(ptr nonnull %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #4
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #2

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca %struct.DWordS_struct, align 8
  %2 = alloca %struct.LargeS_struct, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #4
  store i64 416611827730, ptr %1, align 8
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #4
  store i32 21, ptr %2, align 8, !tbaa !22
  %3 = getelementptr inbounds nuw i8, ptr %2, i64 4
  store i32 0, ptr %3, align 4
  %4 = getelementptr inbounds nuw i8, ptr %2, i64 8
  store double 2.200000e+01, ptr %4, align 8, !tbaa !24
  %5 = getelementptr inbounds nuw i8, ptr %2, i64 16
  store ptr %1, ptr %5, align 8, !tbaa !25
  %6 = getelementptr inbounds nuw i8, ptr %2, i64 24
  store i32 23, ptr %6, align 8, !tbaa !26
  %7 = getelementptr inbounds nuw i8, ptr %2, i64 28
  store i32 0, ptr %7, align 4
  call void (ptr, ...) @test(ptr noundef nonnull @.str.8, ptr noundef nonnull @.str.9, ptr noundef nonnull @.str.10, i32 noundef -123, i32 noundef 97, i32 noundef 123, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, ptr noundef nonnull @.str.11)
  call void (ptr, ...) @test(ptr noundef nonnull @.str.12, double noundef 1.000000e+00, double noundef 2.000000e+00, i32 noundef 32764, i64 noundef 12345677823423)
  %8 = load i64, ptr %1, align 8
  call void (ptr, ...) @test(ptr noundef nonnull @.str.13, i64 %8, i32 19, double 2.000000e+01, ptr noundef nonnull byval(%struct.LargeS_struct) align 8 %2)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #4
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #4
  ret i32 0
}

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!7, !7, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"p1 omnipotent char", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!6, !6, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"double", !7, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"long long", !7, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"p1 _ZTS13DWordS_struct", !12, i64 0}
!20 = distinct !{!20, !21}
!21 = !{!"llvm.loop.mustprogress"}
!22 = !{!23, !6, i64 0}
!23 = !{!"LargeS_struct", !6, i64 0, !15, i64 8, !19, i64 16, !6, i64 24}
!24 = !{!23, !15, i64 8}
!25 = !{!23, !19, i64 16}
!26 = !{!23, !6, i64 24}
