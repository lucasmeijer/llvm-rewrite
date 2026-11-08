; @source: tests/e2e/src/structs/struct_basic.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/structs/struct_basic.c'
source_filename = "tests/e2e/src/structs/struct_basic.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.point = type { i32, i32 }
%struct.rect = type { %struct.point, %struct.point, i8 }

@__const.main.r = private unnamed_addr constant { %struct.point, %struct.point, i8, [3 x i8] } { %struct.point { i32 1, i32 2 }, %struct.point { i32 11, i32 7 }, i8 114, [3 x i8] zeroinitializer }, align 4
@.str = private unnamed_addr constant [14 x i8] c"%d %d %c %zu\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.rect, align 4
  %3 = alloca %struct.rect, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %2, ptr align 4 @__const.main.r, i64 20, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 4 %2, i64 20, i1 false)
  %4 = getelementptr inbounds nuw %struct.rect, ptr %3, i32 0, i32 1
  %5 = getelementptr inbounds nuw %struct.point, ptr %4, i32 0, i32 0
  %6 = load i32, ptr %5, align 4
  %7 = add nsw i32 %6, 5
  store i32 %7, ptr %5, align 4
  %8 = call i32 @area(ptr noundef %2)
  %9 = call i32 @area(ptr noundef %3)
  %10 = getelementptr inbounds nuw %struct.rect, ptr %3, i32 0, i32 2
  %11 = load i8, ptr %10, align 4
  %12 = sext i8 %11 to i32
  %13 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %8, i32 noundef %9, i32 noundef %12, i64 noundef 20)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: noinline nounwind uwtable
define internal i32 @area(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8
  %3 = load ptr, ptr %2, align 8
  %4 = getelementptr inbounds nuw %struct.rect, ptr %3, i32 0, i32 1
  %5 = getelementptr inbounds nuw %struct.point, ptr %4, i32 0, i32 0
  %6 = load i32, ptr %5, align 4
  %7 = load ptr, ptr %2, align 8
  %8 = getelementptr inbounds nuw %struct.rect, ptr %7, i32 0, i32 0
  %9 = getelementptr inbounds nuw %struct.point, ptr %8, i32 0, i32 0
  %10 = load i32, ptr %9, align 4
  %11 = sub nsw i32 %6, %10
  %12 = load ptr, ptr %2, align 8
  %13 = getelementptr inbounds nuw %struct.rect, ptr %12, i32 0, i32 1
  %14 = getelementptr inbounds nuw %struct.point, ptr %13, i32 0, i32 1
  %15 = load i32, ptr %14, align 4
  %16 = load ptr, ptr %2, align 8
  %17 = getelementptr inbounds nuw %struct.rect, ptr %16, i32 0, i32 0
  %18 = getelementptr inbounds nuw %struct.point, ptr %17, i32 0, i32 1
  %19 = load i32, ptr %18, align 4
  %20 = sub nsw i32 %15, %19
  %21 = mul nsw i32 %11, %20
  ret i32 %21
}

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
