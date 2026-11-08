; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/sumarraymalloc.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/sumarraymalloc.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/sumarraymalloc.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"Sum1 = %d\0A\00", align 1
@.str.1 = private unnamed_addr constant [11 x i8] c"Sum2 = %d\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = icmp slt i32 %0, 2
  br i1 %3, label %9, label %4

4:                                                ; preds = %2
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  %6 = load ptr, ptr %5, align 8, !tbaa !9
  %7 = tail call i64 @strtol(ptr noundef nonnull captures(none) %6, ptr noundef null, i32 noundef 10) #6, !inline_history !12
  %8 = trunc i64 %7 to i32
  br label %9

9:                                                ; preds = %2, %4
  %10 = phi i32 [ %8, %4 ], [ 100, %2 ]
  %11 = sext i32 %10 to i64
  %12 = shl nsw i64 %11, 2
  %13 = tail call noalias ptr @malloc(i64 noundef %12) #7
  %14 = icmp eq i32 %10, 0
  br i1 %14, label %39, label %15

15:                                               ; preds = %9
  %16 = zext i32 %10 to i64
  %17 = icmp ult i32 %10, 8
  br i1 %17, label %31, label %18

18:                                               ; preds = %15
  %19 = and i64 %16, 4294967288
  br label %20

20:                                               ; preds = %20, %18
  %21 = phi i64 [ 0, %18 ], [ %26, %20 ]
  %22 = phi <4 x i32> [ <i32 0, i32 1, i32 2, i32 3>, %18 ], [ %27, %20 ]
  %23 = add <4 x i32> %22, splat (i32 4)
  %24 = getelementptr inbounds nuw [4 x i8], ptr %13, i64 %21
  %25 = getelementptr inbounds nuw i8, ptr %24, i64 16
  store <4 x i32> %22, ptr %24, align 4, !tbaa !13
  store <4 x i32> %23, ptr %25, align 4, !tbaa !13
  %26 = add nuw i64 %21, 8
  %27 = add <4 x i32> %22, splat (i32 8)
  %28 = icmp eq i64 %26, %19
  br i1 %28, label %29, label %20, !llvm.loop !14

29:                                               ; preds = %20
  %30 = icmp eq i64 %19, %16
  br i1 %30, label %39, label %31

31:                                               ; preds = %15, %29
  %32 = phi i64 [ 0, %15 ], [ %19, %29 ]
  br label %33

33:                                               ; preds = %31, %33
  %34 = phi i64 [ %37, %33 ], [ %32, %31 ]
  %35 = getelementptr inbounds nuw [4 x i8], ptr %13, i64 %34
  %36 = trunc nuw i64 %34 to i32
  store i32 %36, ptr %35, align 4, !tbaa !13
  %37 = add nuw nsw i64 %34, 1
  %38 = icmp eq i64 %37, %16
  br i1 %38, label %39, label %33, !llvm.loop !18

39:                                               ; preds = %33, %9, %29
  %40 = getelementptr inbounds nuw i8, ptr %13, i64 368
  %41 = load <4 x i32>, ptr %40, align 4, !tbaa !13
  %42 = getelementptr inbounds nuw i8, ptr %13, i64 336
  %43 = load <4 x i32>, ptr %42, align 4, !tbaa !13
  %44 = getelementptr inbounds nuw i8, ptr %13, i64 304
  %45 = load <4 x i32>, ptr %44, align 4, !tbaa !13
  %46 = getelementptr inbounds nuw i8, ptr %13, i64 272
  %47 = load <4 x i32>, ptr %46, align 4, !tbaa !13
  %48 = getelementptr inbounds nuw i8, ptr %13, i64 240
  %49 = load <4 x i32>, ptr %48, align 4, !tbaa !13
  %50 = getelementptr inbounds nuw i8, ptr %13, i64 208
  %51 = load <4 x i32>, ptr %50, align 4, !tbaa !13
  %52 = getelementptr inbounds nuw i8, ptr %13, i64 176
  %53 = load <4 x i32>, ptr %52, align 4, !tbaa !13
  %54 = getelementptr inbounds nuw i8, ptr %13, i64 144
  %55 = load <4 x i32>, ptr %54, align 4, !tbaa !13
  %56 = getelementptr inbounds nuw i8, ptr %13, i64 112
  %57 = load <4 x i32>, ptr %56, align 4, !tbaa !13
  %58 = getelementptr inbounds nuw i8, ptr %13, i64 80
  %59 = load <4 x i32>, ptr %58, align 4, !tbaa !13
  %60 = getelementptr inbounds nuw i8, ptr %13, i64 48
  %61 = load <4 x i32>, ptr %60, align 4, !tbaa !13
  %62 = getelementptr inbounds nuw i8, ptr %13, i64 16
  %63 = load <4 x i32>, ptr %62, align 4, !tbaa !13
  %64 = add <4 x i32> %61, %63
  %65 = add <4 x i32> %59, %64
  %66 = add <4 x i32> %57, %65
  %67 = add <4 x i32> %55, %66
  %68 = add <4 x i32> %53, %67
  %69 = add <4 x i32> %51, %68
  %70 = add <4 x i32> %49, %69
  %71 = add <4 x i32> %47, %70
  %72 = add <4 x i32> %45, %71
  %73 = add <4 x i32> %43, %72
  %74 = add <4 x i32> %41, %73
  %75 = getelementptr inbounds nuw i8, ptr %13, i64 352
  %76 = load <4 x i32>, ptr %75, align 4, !tbaa !13
  %77 = getelementptr inbounds nuw i8, ptr %13, i64 320
  %78 = load <4 x i32>, ptr %77, align 4, !tbaa !13
  %79 = getelementptr inbounds nuw i8, ptr %13, i64 288
  %80 = load <4 x i32>, ptr %79, align 4, !tbaa !13
  %81 = getelementptr inbounds nuw i8, ptr %13, i64 256
  %82 = load <4 x i32>, ptr %81, align 4, !tbaa !13
  %83 = getelementptr inbounds nuw i8, ptr %13, i64 224
  %84 = load <4 x i32>, ptr %83, align 4, !tbaa !13
  %85 = getelementptr inbounds nuw i8, ptr %13, i64 192
  %86 = load <4 x i32>, ptr %85, align 4, !tbaa !13
  %87 = getelementptr inbounds nuw i8, ptr %13, i64 160
  %88 = load <4 x i32>, ptr %87, align 4, !tbaa !13
  %89 = getelementptr inbounds nuw i8, ptr %13, i64 128
  %90 = load <4 x i32>, ptr %89, align 4, !tbaa !13
  %91 = getelementptr inbounds nuw i8, ptr %13, i64 96
  %92 = load <4 x i32>, ptr %91, align 4, !tbaa !13
  %93 = getelementptr inbounds nuw i8, ptr %13, i64 64
  %94 = load <4 x i32>, ptr %93, align 4, !tbaa !13
  %95 = getelementptr inbounds nuw i8, ptr %13, i64 32
  %96 = load <4 x i32>, ptr %95, align 4, !tbaa !13
  %97 = load <4 x i32>, ptr %13, align 4, !tbaa !13
  %98 = add <4 x i32> %96, %97
  %99 = add <4 x i32> %94, %98
  %100 = add <4 x i32> %92, %99
  %101 = add <4 x i32> %90, %100
  %102 = add <4 x i32> %88, %101
  %103 = add <4 x i32> %86, %102
  %104 = add <4 x i32> %84, %103
  %105 = add <4 x i32> %82, %104
  %106 = add <4 x i32> %80, %105
  %107 = add <4 x i32> %78, %106
  %108 = add <4 x i32> %76, %107
  %109 = add <4 x i32> %74, %108
  %110 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %109)
  %111 = getelementptr inbounds nuw i8, ptr %13, i64 384
  %112 = load i32, ptr %111, align 4, !tbaa !13
  %113 = add nsw i32 %112, %110
  %114 = getelementptr inbounds nuw i8, ptr %13, i64 388
  %115 = load i32, ptr %114, align 4, !tbaa !13
  %116 = add nsw i32 %115, %113
  %117 = getelementptr inbounds nuw i8, ptr %13, i64 392
  %118 = load i32, ptr %117, align 4, !tbaa !13
  %119 = add nsw i32 %118, %116
  %120 = getelementptr inbounds nuw i8, ptr %13, i64 396
  %121 = load i32, ptr %120, align 4, !tbaa !13
  %122 = add nsw i32 %121, %119
  %123 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i32 noundef %122)
  %124 = getelementptr i8, ptr %13, i64 368
  %125 = load <4 x i32>, ptr %124, align 4, !tbaa !13
  %126 = getelementptr i8, ptr %13, i64 336
  %127 = load <4 x i32>, ptr %126, align 4, !tbaa !13
  %128 = getelementptr i8, ptr %13, i64 304
  %129 = load <4 x i32>, ptr %128, align 4, !tbaa !13
  %130 = getelementptr i8, ptr %13, i64 272
  %131 = load <4 x i32>, ptr %130, align 4, !tbaa !13
  %132 = getelementptr i8, ptr %13, i64 240
  %133 = load <4 x i32>, ptr %132, align 4, !tbaa !13
  %134 = getelementptr i8, ptr %13, i64 208
  %135 = load <4 x i32>, ptr %134, align 4, !tbaa !13
  %136 = getelementptr i8, ptr %13, i64 176
  %137 = load <4 x i32>, ptr %136, align 4, !tbaa !13
  %138 = getelementptr i8, ptr %13, i64 144
  %139 = load <4 x i32>, ptr %138, align 4, !tbaa !13
  %140 = getelementptr i8, ptr %13, i64 112
  %141 = load <4 x i32>, ptr %140, align 4, !tbaa !13
  %142 = getelementptr i8, ptr %13, i64 80
  %143 = load <4 x i32>, ptr %142, align 4, !tbaa !13
  %144 = getelementptr i8, ptr %13, i64 48
  %145 = load <4 x i32>, ptr %144, align 4, !tbaa !13
  %146 = getelementptr i8, ptr %13, i64 16
  %147 = load <4 x i32>, ptr %146, align 4, !tbaa !13
  %148 = add <4 x i32> %145, %147
  %149 = add <4 x i32> %143, %148
  %150 = add <4 x i32> %141, %149
  %151 = add <4 x i32> %139, %150
  %152 = add <4 x i32> %137, %151
  %153 = add <4 x i32> %135, %152
  %154 = add <4 x i32> %133, %153
  %155 = add <4 x i32> %131, %154
  %156 = add <4 x i32> %129, %155
  %157 = add <4 x i32> %127, %156
  %158 = add <4 x i32> %125, %157
  %159 = getelementptr i8, ptr %13, i64 352
  %160 = load <4 x i32>, ptr %159, align 4, !tbaa !13
  %161 = getelementptr i8, ptr %13, i64 320
  %162 = load <4 x i32>, ptr %161, align 4, !tbaa !13
  %163 = getelementptr i8, ptr %13, i64 288
  %164 = load <4 x i32>, ptr %163, align 4, !tbaa !13
  %165 = getelementptr i8, ptr %13, i64 256
  %166 = load <4 x i32>, ptr %165, align 4, !tbaa !13
  %167 = getelementptr i8, ptr %13, i64 224
  %168 = load <4 x i32>, ptr %167, align 4, !tbaa !13
  %169 = getelementptr i8, ptr %13, i64 192
  %170 = load <4 x i32>, ptr %169, align 4, !tbaa !13
  %171 = getelementptr i8, ptr %13, i64 160
  %172 = load <4 x i32>, ptr %171, align 4, !tbaa !13
  %173 = getelementptr i8, ptr %13, i64 128
  %174 = load <4 x i32>, ptr %173, align 4, !tbaa !13
  %175 = getelementptr i8, ptr %13, i64 96
  %176 = load <4 x i32>, ptr %175, align 4, !tbaa !13
  %177 = getelementptr i8, ptr %13, i64 64
  %178 = load <4 x i32>, ptr %177, align 4, !tbaa !13
  %179 = getelementptr i8, ptr %13, i64 32
  %180 = load <4 x i32>, ptr %179, align 4, !tbaa !13
  %181 = load <4 x i32>, ptr %13, align 4, !tbaa !13
  %182 = add <4 x i32> %180, %181
  %183 = add <4 x i32> %178, %182
  %184 = add <4 x i32> %176, %183
  %185 = add <4 x i32> %174, %184
  %186 = add <4 x i32> %172, %185
  %187 = add <4 x i32> %170, %186
  %188 = add <4 x i32> %168, %187
  %189 = add <4 x i32> %166, %188
  %190 = add <4 x i32> %164, %189
  %191 = add <4 x i32> %162, %190
  %192 = add <4 x i32> %160, %191
  %193 = add <4 x i32> %158, %192
  %194 = tail call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %193)
  %195 = getelementptr i8, ptr %13, i64 384
  %196 = getelementptr i8, ptr %13, i64 388
  %197 = load i32, ptr %195, align 4, !tbaa !13
  %198 = add nsw i32 %197, %194
  %199 = getelementptr i8, ptr %13, i64 392
  %200 = load i32, ptr %196, align 4, !tbaa !13
  %201 = add nsw i32 %200, %198
  %202 = getelementptr i8, ptr %13, i64 396
  %203 = load i32, ptr %199, align 4, !tbaa !13
  %204 = add nsw i32 %203, %201
  %205 = load i32, ptr %202, align 4, !tbaa !13
  %206 = add nsw i32 %205, %204
  %207 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %206)
  tail call void @free(ptr noundef nonnull %13) #6
  ret i32 0
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr noundef captures(none)) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nounwind willreturn
declare i64 @strtol(ptr noundef readonly, ptr noundef captures(none), i32 noundef) local_unnamed_addr #4

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite, errnomem: write) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nounwind willreturn "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #6 = { nounwind }
attributes #7 = { nounwind allocsize(0) }

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
!10 = !{!"p1 omnipotent char", !11, i64 0}
!11 = !{!"any pointer", !7, i64 0}
!12 = distinct !{null}
!13 = !{!6, !6, i64 0}
!14 = distinct !{!14, !15, !16, !17}
!15 = !{!"llvm.loop.mustprogress"}
!16 = !{!"llvm.loop.isvectorized", i32 1}
!17 = !{!"llvm.loop.unroll.runtime.disable"}
!18 = distinct !{!18, !15, !17, !16}
