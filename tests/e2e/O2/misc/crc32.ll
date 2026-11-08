; @source: tests/e2e/src/misc/crc32.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/misc/crc32.c'
source_filename = "tests/e2e/src/misc/crc32.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str.1 = private unnamed_addr constant [6 x i8] c"%08x\0A\00", align 1

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca [256 x i8], align 16
  %2 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef 1095738169)
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #4
  %3 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store <16 x i8> <i8 11, i8 48, i8 85, i8 122, i8 -97, i8 -60, i8 -23, i8 14, i8 51, i8 88, i8 125, i8 -94, i8 -57, i8 -20, i8 17, i8 54>, ptr %1, align 16, !tbaa !9
  store <16 x i8> <i8 91, i8 -128, i8 -91, i8 -54, i8 -17, i8 20, i8 57, i8 94, i8 -125, i8 -88, i8 -51, i8 -14, i8 23, i8 60, i8 97, i8 -122>, ptr %3, align 16, !tbaa !9
  %4 = getelementptr inbounds nuw i8, ptr %1, i64 32
  %5 = getelementptr inbounds nuw i8, ptr %1, i64 48
  store <16 x i8> <i8 -85, i8 -48, i8 -11, i8 26, i8 63, i8 100, i8 -119, i8 -82, i8 -45, i8 -8, i8 29, i8 66, i8 103, i8 -116, i8 -79, i8 -42>, ptr %4, align 16, !tbaa !9
  store <16 x i8> <i8 -5, i8 32, i8 69, i8 106, i8 -113, i8 -76, i8 -39, i8 -2, i8 35, i8 72, i8 109, i8 -110, i8 -73, i8 -36, i8 1, i8 38>, ptr %5, align 16, !tbaa !9
  %6 = getelementptr inbounds nuw i8, ptr %1, i64 64
  %7 = getelementptr inbounds nuw i8, ptr %1, i64 80
  store <16 x i8> <i8 75, i8 112, i8 -107, i8 -70, i8 -33, i8 4, i8 41, i8 78, i8 115, i8 -104, i8 -67, i8 -30, i8 7, i8 44, i8 81, i8 118>, ptr %6, align 16, !tbaa !9
  store <16 x i8> <i8 -101, i8 -64, i8 -27, i8 10, i8 47, i8 84, i8 121, i8 -98, i8 -61, i8 -24, i8 13, i8 50, i8 87, i8 124, i8 -95, i8 -58>, ptr %7, align 16, !tbaa !9
  %8 = getelementptr inbounds nuw i8, ptr %1, i64 96
  %9 = getelementptr inbounds nuw i8, ptr %1, i64 112
  store <16 x i8> <i8 -21, i8 16, i8 53, i8 90, i8 127, i8 -92, i8 -55, i8 -18, i8 19, i8 56, i8 93, i8 -126, i8 -89, i8 -52, i8 -15, i8 22>, ptr %8, align 16, !tbaa !9
  store <16 x i8> <i8 59, i8 96, i8 -123, i8 -86, i8 -49, i8 -12, i8 25, i8 62, i8 99, i8 -120, i8 -83, i8 -46, i8 -9, i8 28, i8 65, i8 102>, ptr %9, align 16, !tbaa !9
  %10 = getelementptr inbounds nuw i8, ptr %1, i64 128
  %11 = getelementptr inbounds nuw i8, ptr %1, i64 144
  store <16 x i8> <i8 -117, i8 -80, i8 -43, i8 -6, i8 31, i8 68, i8 105, i8 -114, i8 -77, i8 -40, i8 -3, i8 34, i8 71, i8 108, i8 -111, i8 -74>, ptr %10, align 16, !tbaa !9
  store <16 x i8> <i8 -37, i8 0, i8 37, i8 74, i8 111, i8 -108, i8 -71, i8 -34, i8 3, i8 40, i8 77, i8 114, i8 -105, i8 -68, i8 -31, i8 6>, ptr %11, align 16, !tbaa !9
  %12 = getelementptr inbounds nuw i8, ptr %1, i64 160
  %13 = getelementptr inbounds nuw i8, ptr %1, i64 176
  store <16 x i8> <i8 43, i8 80, i8 117, i8 -102, i8 -65, i8 -28, i8 9, i8 46, i8 83, i8 120, i8 -99, i8 -62, i8 -25, i8 12, i8 49, i8 86>, ptr %12, align 16, !tbaa !9
  store <16 x i8> <i8 123, i8 -96, i8 -59, i8 -22, i8 15, i8 52, i8 89, i8 126, i8 -93, i8 -56, i8 -19, i8 18, i8 55, i8 92, i8 -127, i8 -90>, ptr %13, align 16, !tbaa !9
  %14 = getelementptr inbounds nuw i8, ptr %1, i64 192
  %15 = getelementptr inbounds nuw i8, ptr %1, i64 208
  store <16 x i8> <i8 -53, i8 -16, i8 21, i8 58, i8 95, i8 -124, i8 -87, i8 -50, i8 -13, i8 24, i8 61, i8 98, i8 -121, i8 -84, i8 -47, i8 -10>, ptr %14, align 16, !tbaa !9
  store <16 x i8> <i8 27, i8 64, i8 101, i8 -118, i8 -81, i8 -44, i8 -7, i8 30, i8 67, i8 104, i8 -115, i8 -78, i8 -41, i8 -4, i8 33, i8 70>, ptr %15, align 16, !tbaa !9
  %16 = getelementptr inbounds nuw i8, ptr %1, i64 224
  %17 = getelementptr inbounds nuw i8, ptr %1, i64 240
  store <16 x i8> <i8 107, i8 -112, i8 -75, i8 -38, i8 -1, i8 36, i8 73, i8 110, i8 -109, i8 -72, i8 -35, i8 2, i8 39, i8 76, i8 113, i8 -106>, ptr %16, align 16, !tbaa !9
  store <16 x i8> <i8 -69, i8 -32, i8 5, i8 42, i8 79, i8 116, i8 -103, i8 -66, i8 -29, i8 8, i8 45, i8 82, i8 119, i8 -100, i8 -63, i8 -26>, ptr %17, align 16, !tbaa !9
  br label %18

18:                                               ; preds = %0, %18
  %19 = phi i64 [ %52, %18 ], [ 0, %0 ]
  %20 = phi i32 [ %51, %18 ], [ -1, %0 ]
  %21 = getelementptr inbounds nuw i8, ptr %1, i64 %19
  %22 = load i8, ptr %21, align 1, !tbaa !9
  %23 = zext i8 %22 to i32
  %24 = xor i32 %20, %23
  %25 = lshr i32 %24, 1
  %26 = and i32 %24, 1
  %27 = icmp eq i32 %26, 0
  %28 = select i1 %27, i32 0, i32 -306674912
  %29 = xor i32 %28, %25
  %30 = lshr i32 %29, 1
  %31 = and i32 %24, 2
  %32 = icmp eq i32 %31, 0
  %33 = select i1 %32, i32 0, i32 -306674912
  %34 = xor i32 %30, %33
  %35 = insertelement <4 x i32> poison, i32 %24, i64 0
  %36 = shufflevector <4 x i32> %35, <4 x i32> poison, <4 x i32> zeroinitializer
  %37 = and <4 x i32> %36, <i32 32, i32 16, i32 8, i32 4>
  %38 = icmp eq <4 x i32> %37, zeroinitializer
  %39 = select <4 x i1> %38, <4 x i32> zeroinitializer, <4 x i32> <i32 -306674912, i32 1994146192, i32 997073096, i32 498536548>
  %40 = tail call i32 @llvm.vector.reduce.xor.v4i32(<4 x i32> %39)
  %41 = and i32 %29, 32
  %42 = icmp eq i32 %41, 0
  %43 = select i1 %42, i32 0, i32 1994146192
  %44 = lshr i32 %34, 6
  %45 = lshr exact i32 %40, 2
  %46 = xor i32 %44, %45
  %47 = and i32 %34, 32
  %48 = icmp eq i32 %47, 0
  %49 = select i1 %48, i32 0, i32 -306674912
  %50 = xor i32 %49, %43
  %51 = xor i32 %50, %46
  %52 = add nuw nsw i64 %19, 1
  %53 = icmp eq i64 %52, 256
  br i1 %53, label %54, label %18, !llvm.loop !10

54:                                               ; preds = %18
  %55 = xor i32 %51, -1
  %56 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, i32 noundef %55)
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #4
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.vector.reduce.xor.v4i32(<4 x i32>) #3

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
