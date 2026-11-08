; @source: tests/e2e/src/intrinsics/struct_copy_memset.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/intrinsics/struct_copy_memset.c'
source_filename = "tests/e2e/src/intrinsics/struct_copy_memset.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.big = type { [20 x i64], [13 x i8] }

@.str = private unnamed_addr constant [19 x i8] c"%ld %ld %s %zu %c\0A\00", align 1
@.str.1 = private unnamed_addr constant [5 x i8] c"made\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca %struct.big, align 8
  %2 = alloca [100 x i8], align 16
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 165
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #5
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 1 dereferenceable(11) %3, i8 0, i64 11, i1 false)
  %4 = getelementptr inbounds nuw i8, ptr %1, i64 160
  call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(5) %4, ptr noundef nonnull align 1 dereferenceable(5) @.str.1, i64 5, i1 false)
  store i64 0, ptr %1, align 8
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store i64 3, ptr %5, align 8
  %6 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store i64 6, ptr %6, align 8
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 24
  store i64 9, ptr %7, align 8
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 32
  store i64 12, ptr %8, align 8
  %9 = getelementptr inbounds nuw i8, ptr %1, i64 40
  %10 = getelementptr inbounds nuw i8, ptr %1, i64 48
  store i64 18, ptr %10, align 8
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 56
  store i64 21, ptr %11, align 8
  %12 = getelementptr inbounds nuw i8, ptr %1, i64 64
  store i64 24, ptr %12, align 8
  %13 = getelementptr inbounds nuw i8, ptr %1, i64 72
  store i64 27, ptr %13, align 8
  %14 = getelementptr inbounds nuw i8, ptr %1, i64 80
  store i64 30, ptr %14, align 8
  %15 = getelementptr inbounds nuw i8, ptr %1, i64 88
  store i64 33, ptr %15, align 8
  %16 = getelementptr inbounds nuw i8, ptr %1, i64 96
  store i64 36, ptr %16, align 8
  %17 = getelementptr inbounds nuw i8, ptr %1, i64 104
  store i64 39, ptr %17, align 8
  %18 = getelementptr inbounds nuw i8, ptr %1, i64 112
  store i64 42, ptr %18, align 8
  %19 = getelementptr inbounds nuw i8, ptr %1, i64 120
  store i64 45, ptr %19, align 8
  %20 = getelementptr inbounds nuw i8, ptr %1, i64 128
  store i64 48, ptr %20, align 8
  %21 = getelementptr inbounds nuw i8, ptr %1, i64 136
  store i64 51, ptr %21, align 8
  %22 = getelementptr inbounds nuw i8, ptr %1, i64 144
  store i64 54, ptr %22, align 8
  %23 = getelementptr inbounds nuw i8, ptr %1, i64 152
  store i64 57, ptr %23, align 8, !tbaa !9
  store i64 -1, ptr %9, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #5
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(100) %2, i8 97, i64 100, i1 false)
  %24 = getelementptr inbounds nuw i8, ptr %2, i64 10
  call void @llvm.memmove.p0.p0.i64(ptr noundef nonnull align 2 dereferenceable(50) %24, ptr noundef nonnull align 16 dereferenceable(50) %2, i64 50, i1 false)
  %25 = getelementptr inbounds nuw i8, ptr %2, i64 99
  store i8 0, ptr %25, align 1, !tbaa !9
  %26 = call i64 @strlen(ptr noundef nonnull dereferenceable(1) %2) #6
  %27 = call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, i64 noundef 15, i64 noundef 56, ptr noundef nonnull %4, i64 noundef %26, i32 noundef 97)
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #5
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #5
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memmove.p0.p0.i64(ptr writeonly captures(none), ptr readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read)
declare i64 @strlen(ptr noundef captures(none)) local_unnamed_addr #4

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nounwind }
attributes #6 = { nounwind willreturn memory(read) }

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
!11 = !{!"long", !7, i64 0}
