; @source: tests/e2e/src/test-suite/SingleSource/Regression/C/casts.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Regression/C/casts.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Regression/C/casts.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [41 x i8] c"\0ACHAR             C = '%c' (%d)\09\09(0x%x)\0A\00", align 1
@.str.1 = private unnamed_addr constant [33 x i8] c"char to short   s1 = %d\09\09(0x%x)\0A\00", align 1
@.str.2 = private unnamed_addr constant [33 x i8] c"char to int     i1 = %d\09\09(0x%x)\0A\00", align 1
@.str.3 = private unnamed_addr constant [35 x i8] c"char to int64_t l1 = %ld\09\09(0x%lx)\0A\00", align 1
@.str.4 = private unnamed_addr constant [34 x i8] c"\0Achar to ubyte  uc1 = %u\09\09(0x%x)\0A\00", align 1
@.str.5 = private unnamed_addr constant [33 x i8] c"char to ushort us1 = %u\09\09(0x%x)\0A\00", align 1
@.str.6 = private unnamed_addr constant [33 x i8] c"char to uint   ui1 = %u\09\09(0x%x)\0A\00", align 1
@.str.7 = private unnamed_addr constant [37 x i8] c"char to uint64_t ul1 = %lu\09\09(0x%lx)\0A\00", align 1
@.str.8 = private unnamed_addr constant [35 x i8] c"\0A\0ASHORT            S = %d\09\09(0x%x)\0A\00", align 1
@.str.9 = private unnamed_addr constant [34 x i8] c"short to byte    c1 = %d\09\09(0x%x)\0A\00", align 1
@.str.10 = private unnamed_addr constant [34 x i8] c"short to int     i1 = %d\09\09(0x%x)\0A\00", align 1
@.str.11 = private unnamed_addr constant [36 x i8] c"short to int64_t l1 = %ld\09\09(0x%lx)\0A\00", align 1
@.str.12 = private unnamed_addr constant [35 x i8] c"\0Ashort to ubyte  uc1 = %u\09\09(0x%x)\0A\00", align 1
@.str.13 = private unnamed_addr constant [34 x i8] c"short to ushort us1 = %u\09\09(0x%x)\0A\00", align 1
@.str.14 = private unnamed_addr constant [34 x i8] c"short to uint   ui1 = %u\09\09(0x%x)\0A\00", align 1
@.str.15 = private unnamed_addr constant [38 x i8] c"short to uint64_t ul1 = %lu\09\09(0x%lx)\0A\00", align 1
@.str.16 = private unnamed_addr constant [36 x i8] c"\0A\0ALONG            L = %ld\09\09(0x%lx)\0A\00", align 1
@.str.17 = private unnamed_addr constant [33 x i8] c"long to byte    c1 = %d\09\09(0x%x)\0A\00", align 1
@.str.18 = private unnamed_addr constant [33 x i8] c"long to short   s1 = %d\09\09(0x%x)\0A\00", align 1
@.str.19 = private unnamed_addr constant [33 x i8] c"long to int     i1 = %d\09\09(0x%x)\0A\00", align 1
@.str.20 = private unnamed_addr constant [34 x i8] c"\0Along to ubyte  uc1 = %u\09\09(0x%x)\0A\00", align 1
@.str.21 = private unnamed_addr constant [33 x i8] c"long to ushort us1 = %u\09\09(0x%x)\0A\00", align 1
@.str.22 = private unnamed_addr constant [33 x i8] c"long to uint   ui1 = %u\09\09(0x%x)\0A\00", align 1
@.str.23 = private unnamed_addr constant [37 x i8] c"long to uint64_t ul1 = %lu\09\09(0x%lx)\0A\00", align 1
@.str.24 = private unnamed_addr constant [27 x i8] c"\0A\0AFLOAT            F = %f\0A\00", align 1
@.str.25 = private unnamed_addr constant [34 x i8] c"float to short   s1 = %d\09\09(0x%x)\0A\00", align 1
@.str.26 = private unnamed_addr constant [34 x i8] c"float to int     i1 = %d\09\09(0x%x)\0A\00", align 1
@.str.27 = private unnamed_addr constant [34 x i8] c"float to ushort us1 = %u\09\09(0x%x)\0A\00", align 1
@.str.28 = private unnamed_addr constant [34 x i8] c"float to uint   ui1 = %u\09\09(0x%x)\0A\00", align 1
@.str.29 = private unnamed_addr constant [38 x i8] c"float to uint64_t ul1 = %lu\09\09(0x%lx)\0A\00", align 1
@.str.30 = private unnamed_addr constant [28 x i8] c"\0A\0ADOUBLE            D = %f\0A\00", align 1
@.str.31 = private unnamed_addr constant [35 x i8] c"double to short   s1 = %d\09\09(0x%x)\0A\00", align 1
@.str.32 = private unnamed_addr constant [35 x i8] c"double to int     i1 = %d\09\09(0x%x)\0A\00", align 1
@.str.33 = private unnamed_addr constant [37 x i8] c"double to int64_t l1 = %ld\09\09(0x%lx)\0A\00", align 1
@.str.34 = private unnamed_addr constant [35 x i8] c"double to ushort us1 = %u\09\09(0x%x)\0A\00", align 1
@.str.35 = private unnamed_addr constant [35 x i8] c"double to uint   ui1 = %u\09\09(0x%x)\0A\00", align 1
@.str.36 = private unnamed_addr constant [39 x i8] c"double to uint64_t ul1 = %lu\09\09(0x%lx)\0A\00", align 1
@lls = internal global [6 x i64] [i64 123, i64 -1, i64 -14, i64 14, i64 -9223372036854775808, i64 0], align 16
@.str.37 = private unnamed_addr constant [28 x i8] c"double <- int64_t %ld = %f\0A\00", align 1
@.str.38 = private unnamed_addr constant [29 x i8] c"double <- uint64_t %lu = %f\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i8, align 1
  %7 = alloca i8, align 1
  %8 = alloca i8, align 1
  %9 = alloca i16, align 2
  %10 = alloca i16, align 2
  %11 = alloca i16, align 2
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i64, align 8
  %16 = alloca i64, align 8
  %17 = alloca i64, align 8
  %18 = alloca float, align 4
  %19 = alloca double, align 8
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !9
  store ptr %1, ptr %5, align 8, !tbaa !10
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  call void @llvm.lifetime.start.p0(ptr %9) #5
  call void @llvm.lifetime.start.p0(ptr %10) #5
  call void @llvm.lifetime.start.p0(ptr %11) #5
  call void @llvm.lifetime.start.p0(ptr %12) #5
  call void @llvm.lifetime.start.p0(ptr %13) #5
  call void @llvm.lifetime.start.p0(ptr %14) #5
  call void @llvm.lifetime.start.p0(ptr %15) #5
  call void @llvm.lifetime.start.p0(ptr %16) #5
  call void @llvm.lifetime.start.p0(ptr %17) #5
  call void @llvm.lifetime.start.p0(ptr %18) #5
  call void @llvm.lifetime.start.p0(ptr %19) #5
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = icmp sge i32 %20, 2
  %22 = zext i1 %21 to i32
  %23 = trunc i32 %22 to i8
  %24 = sext i8 %23 to i32
  %25 = icmp ne i32 %24, 0
  br i1 %25, label %26, label %31

26:                                               ; preds = %2
  %27 = load ptr, ptr %5, align 8, !tbaa !10
  %28 = getelementptr inbounds ptr, ptr %27, i64 1
  %29 = load ptr, ptr %28, align 8, !tbaa !14
  %30 = call i32 @atoi(ptr noundef %29) #6
  br label %32

31:                                               ; preds = %2
  br label %32

32:                                               ; preds = %31, %26
  %33 = phi i32 [ %30, %26 ], [ 100, %31 ]
  %34 = trunc i32 %33 to i8
  store i8 %34, ptr %6, align 1, !tbaa !16
  %35 = load i32, ptr %4, align 4, !tbaa !9
  %36 = icmp sge i32 %35, 3
  %37 = zext i1 %36 to i32
  %38 = trunc i32 %37 to i16
  %39 = sext i16 %38 to i32
  %40 = icmp ne i32 %39, 0
  br i1 %40, label %41, label %46

41:                                               ; preds = %32
  %42 = load ptr, ptr %5, align 8, !tbaa !10
  %43 = getelementptr inbounds ptr, ptr %42, i64 2
  %44 = load ptr, ptr %43, align 8, !tbaa !14
  %45 = call i32 @atoi(ptr noundef %44) #6
  br label %47

46:                                               ; preds = %32
  br label %47

47:                                               ; preds = %46, %41
  %48 = phi i32 [ %45, %41 ], [ -769, %46 ]
  %49 = trunc i32 %48 to i16
  store i16 %49, ptr %9, align 2, !tbaa !17
  %50 = load i32, ptr %4, align 4, !tbaa !9
  %51 = icmp sge i32 %50, 4
  %52 = zext i1 %51 to i32
  %53 = sext i32 %52 to i64
  %54 = icmp ne i64 %53, 0
  br i1 %54, label %55, label %61

55:                                               ; preds = %47
  %56 = load ptr, ptr %5, align 8, !tbaa !10
  %57 = getelementptr inbounds ptr, ptr %56, i64 3
  %58 = load ptr, ptr %57, align 8, !tbaa !14
  %59 = call i32 @atoi(ptr noundef %58) #6
  %60 = sext i32 %59 to i64
  br label %62

61:                                               ; preds = %47
  br label %62

62:                                               ; preds = %61, %55
  %63 = phi i64 [ %60, %55 ], [ 179923220407203, %61 ]
  store i64 %63, ptr %15, align 8, !tbaa !19
  %64 = load i8, ptr %6, align 1, !tbaa !16
  store i8 %64, ptr %8, align 1, !tbaa !16
  %65 = load i8, ptr %6, align 1, !tbaa !16
  %66 = sext i8 %65 to i16
  store i16 %66, ptr %11, align 2, !tbaa !17
  %67 = load i8, ptr %6, align 1, !tbaa !16
  %68 = sext i8 %67 to i32
  store i32 %68, ptr %14, align 4, !tbaa !9
  %69 = load i8, ptr %6, align 1, !tbaa !16
  %70 = sext i8 %69 to i64
  store i64 %70, ptr %17, align 8, !tbaa !19
  %71 = load i8, ptr %6, align 1, !tbaa !16
  %72 = sext i8 %71 to i16
  store i16 %72, ptr %10, align 2, !tbaa !17
  %73 = load i8, ptr %6, align 1, !tbaa !16
  %74 = sext i8 %73 to i32
  store i32 %74, ptr %12, align 4, !tbaa !9
  %75 = load i8, ptr %6, align 1, !tbaa !16
  %76 = sext i8 %75 to i64
  store i64 %76, ptr %16, align 8, !tbaa !19
  %77 = load i8, ptr %6, align 1, !tbaa !16
  %78 = sext i8 %77 to i32
  %79 = load i8, ptr %6, align 1, !tbaa !16
  %80 = sext i8 %79 to i32
  %81 = load i8, ptr %6, align 1, !tbaa !16
  %82 = sext i8 %81 to i32
  %83 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %78, i32 noundef %80, i32 noundef %82)
  %84 = load i16, ptr %10, align 2, !tbaa !17
  %85 = sext i16 %84 to i32
  %86 = load i16, ptr %10, align 2, !tbaa !17
  %87 = sext i16 %86 to i32
  %88 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %85, i32 noundef %87)
  %89 = load i32, ptr %12, align 4, !tbaa !9
  %90 = load i32, ptr %12, align 4, !tbaa !9
  %91 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, i32 noundef %89, i32 noundef %90)
  %92 = load i64, ptr %16, align 8, !tbaa !19
  %93 = load i64, ptr %16, align 8, !tbaa !19
  %94 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %92, i64 noundef %93)
  %95 = load i8, ptr %8, align 1, !tbaa !16
  %96 = zext i8 %95 to i32
  %97 = load i8, ptr %8, align 1, !tbaa !16
  %98 = zext i8 %97 to i32
  %99 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %96, i32 noundef %98)
  %100 = load i16, ptr %11, align 2, !tbaa !17
  %101 = zext i16 %100 to i32
  %102 = load i16, ptr %11, align 2, !tbaa !17
  %103 = zext i16 %102 to i32
  %104 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %101, i32 noundef %103)
  %105 = load i32, ptr %14, align 4, !tbaa !9
  %106 = load i32, ptr %14, align 4, !tbaa !9
  %107 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %105, i32 noundef %106)
  %108 = load i64, ptr %17, align 8, !tbaa !19
  %109 = load i64, ptr %17, align 8, !tbaa !19
  %110 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i64 noundef %108, i64 noundef %109)
  %111 = load i16, ptr %9, align 2, !tbaa !17
  %112 = trunc i16 %111 to i8
  store i8 %112, ptr %8, align 1, !tbaa !16
  %113 = load i16, ptr %9, align 2, !tbaa !17
  store i16 %113, ptr %11, align 2, !tbaa !17
  %114 = load i16, ptr %9, align 2, !tbaa !17
  %115 = sext i16 %114 to i32
  store i32 %115, ptr %14, align 4, !tbaa !9
  %116 = load i16, ptr %9, align 2, !tbaa !17
  %117 = sext i16 %116 to i64
  store i64 %117, ptr %17, align 8, !tbaa !19
  %118 = load i16, ptr %9, align 2, !tbaa !17
  %119 = trunc i16 %118 to i8
  store i8 %119, ptr %7, align 1, !tbaa !16
  %120 = load i16, ptr %9, align 2, !tbaa !17
  %121 = sext i16 %120 to i32
  store i32 %121, ptr %12, align 4, !tbaa !9
  %122 = load i16, ptr %9, align 2, !tbaa !17
  %123 = sext i16 %122 to i64
  store i64 %123, ptr %16, align 8, !tbaa !19
  %124 = load i16, ptr %9, align 2, !tbaa !17
  %125 = sext i16 %124 to i32
  %126 = load i16, ptr %9, align 2, !tbaa !17
  %127 = sext i16 %126 to i32
  %128 = call i32 (ptr, ...) @printf(ptr noundef @.str.8, i32 noundef %125, i32 noundef %127)
  %129 = load i8, ptr %7, align 1, !tbaa !16
  %130 = sext i8 %129 to i32
  %131 = load i8, ptr %7, align 1, !tbaa !16
  %132 = sext i8 %131 to i32
  %133 = call i32 (ptr, ...) @printf(ptr noundef @.str.9, i32 noundef %130, i32 noundef %132)
  %134 = load i32, ptr %12, align 4, !tbaa !9
  %135 = load i32, ptr %12, align 4, !tbaa !9
  %136 = call i32 (ptr, ...) @printf(ptr noundef @.str.10, i32 noundef %134, i32 noundef %135)
  %137 = load i64, ptr %16, align 8, !tbaa !19
  %138 = load i64, ptr %16, align 8, !tbaa !19
  %139 = call i32 (ptr, ...) @printf(ptr noundef @.str.11, i64 noundef %137, i64 noundef %138)
  %140 = load i8, ptr %8, align 1, !tbaa !16
  %141 = zext i8 %140 to i32
  %142 = load i8, ptr %8, align 1, !tbaa !16
  %143 = zext i8 %142 to i32
  %144 = call i32 (ptr, ...) @printf(ptr noundef @.str.12, i32 noundef %141, i32 noundef %143)
  %145 = load i16, ptr %11, align 2, !tbaa !17
  %146 = zext i16 %145 to i32
  %147 = load i16, ptr %11, align 2, !tbaa !17
  %148 = zext i16 %147 to i32
  %149 = call i32 (ptr, ...) @printf(ptr noundef @.str.13, i32 noundef %146, i32 noundef %148)
  %150 = load i32, ptr %14, align 4, !tbaa !9
  %151 = load i32, ptr %14, align 4, !tbaa !9
  %152 = call i32 (ptr, ...) @printf(ptr noundef @.str.14, i32 noundef %150, i32 noundef %151)
  %153 = load i64, ptr %17, align 8, !tbaa !19
  %154 = load i64, ptr %17, align 8, !tbaa !19
  %155 = call i32 (ptr, ...) @printf(ptr noundef @.str.15, i64 noundef %153, i64 noundef %154)
  %156 = load i64, ptr %15, align 8, !tbaa !19
  %157 = trunc i64 %156 to i8
  store i8 %157, ptr %8, align 1, !tbaa !16
  %158 = load i64, ptr %15, align 8, !tbaa !19
  %159 = trunc i64 %158 to i8
  store i8 %159, ptr %7, align 1, !tbaa !16
  %160 = load i64, ptr %15, align 8, !tbaa !19
  %161 = trunc i64 %160 to i16
  store i16 %161, ptr %10, align 2, !tbaa !17
  %162 = load i64, ptr %15, align 8, !tbaa !19
  %163 = trunc i64 %162 to i16
  store i16 %163, ptr %11, align 2, !tbaa !17
  %164 = load i64, ptr %15, align 8, !tbaa !19
  %165 = trunc i64 %164 to i32
  store i32 %165, ptr %12, align 4, !tbaa !9
  %166 = load i64, ptr %15, align 8, !tbaa !19
  %167 = trunc i64 %166 to i32
  store i32 %167, ptr %14, align 4, !tbaa !9
  %168 = load i64, ptr %15, align 8, !tbaa !19
  store i64 %168, ptr %17, align 8, !tbaa !19
  %169 = load i64, ptr %15, align 8, !tbaa !19
  %170 = load i64, ptr %15, align 8, !tbaa !19
  %171 = call i32 (ptr, ...) @printf(ptr noundef @.str.16, i64 noundef %169, i64 noundef %170)
  %172 = load i8, ptr %7, align 1, !tbaa !16
  %173 = sext i8 %172 to i32
  %174 = load i8, ptr %7, align 1, !tbaa !16
  %175 = sext i8 %174 to i32
  %176 = call i32 (ptr, ...) @printf(ptr noundef @.str.17, i32 noundef %173, i32 noundef %175)
  %177 = load i16, ptr %10, align 2, !tbaa !17
  %178 = sext i16 %177 to i32
  %179 = load i16, ptr %10, align 2, !tbaa !17
  %180 = sext i16 %179 to i32
  %181 = call i32 (ptr, ...) @printf(ptr noundef @.str.18, i32 noundef %178, i32 noundef %180)
  %182 = load i32, ptr %12, align 4, !tbaa !9
  %183 = load i32, ptr %12, align 4, !tbaa !9
  %184 = call i32 (ptr, ...) @printf(ptr noundef @.str.19, i32 noundef %182, i32 noundef %183)
  %185 = load i8, ptr %8, align 1, !tbaa !16
  %186 = zext i8 %185 to i32
  %187 = load i8, ptr %8, align 1, !tbaa !16
  %188 = zext i8 %187 to i32
  %189 = call i32 (ptr, ...) @printf(ptr noundef @.str.20, i32 noundef %186, i32 noundef %188)
  %190 = load i16, ptr %11, align 2, !tbaa !17
  %191 = zext i16 %190 to i32
  %192 = load i16, ptr %11, align 2, !tbaa !17
  %193 = zext i16 %192 to i32
  %194 = call i32 (ptr, ...) @printf(ptr noundef @.str.21, i32 noundef %191, i32 noundef %193)
  %195 = load i32, ptr %14, align 4, !tbaa !9
  %196 = load i32, ptr %14, align 4, !tbaa !9
  %197 = call i32 (ptr, ...) @printf(ptr noundef @.str.22, i32 noundef %195, i32 noundef %196)
  %198 = load i64, ptr %17, align 8, !tbaa !19
  %199 = load i64, ptr %17, align 8, !tbaa !19
  %200 = call i32 (ptr, ...) @printf(ptr noundef @.str.23, i64 noundef %198, i64 noundef %199)
  %201 = load i32, ptr %4, align 4, !tbaa !9
  %202 = icmp sge i32 %201, 4
  %203 = zext i1 %202 to i32
  %204 = sitofp i32 %203 to float
  %205 = fcmp une float %204, 0.000000e+00
  br i1 %205, label %206, label %211

206:                                              ; preds = %62
  %207 = load ptr, ptr %5, align 8, !tbaa !10
  %208 = getelementptr inbounds ptr, ptr %207, i64 3
  %209 = load ptr, ptr %208, align 8, !tbaa !14
  %210 = call double @atof(ptr noundef %209) #6
  br label %212

211:                                              ; preds = %62
  br label %212

212:                                              ; preds = %211, %206
  %213 = phi double [ %210, %206 ], [ 1.000000e+00, %211 ]
  %214 = fptrunc double %213 to float
  store float %214, ptr %18, align 4, !tbaa !21
  %215 = load i32, ptr %4, align 4, !tbaa !9
  %216 = icmp sge i32 %215, 5
  br i1 %216, label %217, label %222

217:                                              ; preds = %212
  %218 = load ptr, ptr %5, align 8, !tbaa !10
  %219 = getelementptr inbounds ptr, ptr %218, i64 4
  %220 = load ptr, ptr %219, align 8, !tbaa !14
  %221 = call double @atof(ptr noundef %220) #6
  br label %223

222:                                              ; preds = %212
  br label %223

223:                                              ; preds = %222, %217
  %224 = phi double [ %221, %217 ], [ 2.000000e+00, %222 ]
  store double %224, ptr %19, align 8, !tbaa !23
  %225 = load float, ptr %18, align 4, !tbaa !21
  %226 = fptoui float %225 to i16
  store i16 %226, ptr %11, align 2, !tbaa !17
  %227 = load float, ptr %18, align 4, !tbaa !21
  %228 = fptoui float %227 to i32
  store i32 %228, ptr %14, align 4, !tbaa !9
  %229 = load float, ptr %18, align 4, !tbaa !21
  %230 = fptoui float %229 to i64
  store i64 %230, ptr %17, align 8, !tbaa !19
  %231 = load float, ptr %18, align 4, !tbaa !21
  %232 = fptosi float %231 to i16
  store i16 %232, ptr %10, align 2, !tbaa !17
  %233 = load float, ptr %18, align 4, !tbaa !21
  %234 = fptosi float %233 to i32
  store i32 %234, ptr %12, align 4, !tbaa !9
  %235 = load float, ptr %18, align 4, !tbaa !21
  %236 = fptosi float %235 to i64
  store i64 %236, ptr %16, align 8, !tbaa !19
  %237 = load float, ptr %18, align 4, !tbaa !21
  %238 = fpext float %237 to double
  %239 = call i32 (ptr, ...) @printf(ptr noundef @.str.24, double noundef %238)
  %240 = load i16, ptr %10, align 2, !tbaa !17
  %241 = sext i16 %240 to i32
  %242 = load i16, ptr %10, align 2, !tbaa !17
  %243 = sext i16 %242 to i32
  %244 = call i32 (ptr, ...) @printf(ptr noundef @.str.25, i32 noundef %241, i32 noundef %243)
  %245 = load i32, ptr %12, align 4, !tbaa !9
  %246 = load i32, ptr %12, align 4, !tbaa !9
  %247 = call i32 (ptr, ...) @printf(ptr noundef @.str.26, i32 noundef %245, i32 noundef %246)
  %248 = load i16, ptr %11, align 2, !tbaa !17
  %249 = zext i16 %248 to i32
  %250 = load i16, ptr %11, align 2, !tbaa !17
  %251 = zext i16 %250 to i32
  %252 = call i32 (ptr, ...) @printf(ptr noundef @.str.27, i32 noundef %249, i32 noundef %251)
  %253 = load i32, ptr %14, align 4, !tbaa !9
  %254 = load i32, ptr %14, align 4, !tbaa !9
  %255 = call i32 (ptr, ...) @printf(ptr noundef @.str.28, i32 noundef %253, i32 noundef %254)
  %256 = load i64, ptr %17, align 8, !tbaa !19
  %257 = load i64, ptr %17, align 8, !tbaa !19
  %258 = call i32 (ptr, ...) @printf(ptr noundef @.str.29, i64 noundef %256, i64 noundef %257)
  %259 = load double, ptr %19, align 8, !tbaa !23
  %260 = fptoui double %259 to i16
  store i16 %260, ptr %11, align 2, !tbaa !17
  %261 = load double, ptr %19, align 8, !tbaa !23
  %262 = fptoui double %261 to i32
  store i32 %262, ptr %14, align 4, !tbaa !9
  %263 = load double, ptr %19, align 8, !tbaa !23
  %264 = fptoui double %263 to i64
  store i64 %264, ptr %17, align 8, !tbaa !19
  %265 = load double, ptr %19, align 8, !tbaa !23
  %266 = fptosi double %265 to i16
  store i16 %266, ptr %10, align 2, !tbaa !17
  %267 = load double, ptr %19, align 8, !tbaa !23
  %268 = fptosi double %267 to i32
  store i32 %268, ptr %12, align 4, !tbaa !9
  %269 = load double, ptr %19, align 8, !tbaa !23
  %270 = fptosi double %269 to i64
  store i64 %270, ptr %16, align 8, !tbaa !19
  %271 = load double, ptr %19, align 8, !tbaa !23
  %272 = call i32 (ptr, ...) @printf(ptr noundef @.str.30, double noundef %271)
  %273 = load i16, ptr %10, align 2, !tbaa !17
  %274 = sext i16 %273 to i32
  %275 = load i16, ptr %10, align 2, !tbaa !17
  %276 = sext i16 %275 to i32
  %277 = call i32 (ptr, ...) @printf(ptr noundef @.str.31, i32 noundef %274, i32 noundef %276)
  %278 = load i32, ptr %12, align 4, !tbaa !9
  %279 = load i32, ptr %12, align 4, !tbaa !9
  %280 = call i32 (ptr, ...) @printf(ptr noundef @.str.32, i32 noundef %278, i32 noundef %279)
  %281 = load i64, ptr %16, align 8, !tbaa !19
  %282 = load i64, ptr %16, align 8, !tbaa !19
  %283 = call i32 (ptr, ...) @printf(ptr noundef @.str.33, i64 noundef %281, i64 noundef %282)
  %284 = load i16, ptr %11, align 2, !tbaa !17
  %285 = zext i16 %284 to i32
  %286 = load i16, ptr %11, align 2, !tbaa !17
  %287 = zext i16 %286 to i32
  %288 = call i32 (ptr, ...) @printf(ptr noundef @.str.34, i32 noundef %285, i32 noundef %287)
  %289 = load i32, ptr %14, align 4, !tbaa !9
  %290 = load i32, ptr %14, align 4, !tbaa !9
  %291 = call i32 (ptr, ...) @printf(ptr noundef @.str.35, i32 noundef %289, i32 noundef %290)
  %292 = load i64, ptr %17, align 8, !tbaa !19
  %293 = load i64, ptr %17, align 8, !tbaa !19
  %294 = call i32 (ptr, ...) @printf(ptr noundef @.str.36, i64 noundef %292, i64 noundef %293)
  store i32 0, ptr %13, align 4, !tbaa !9
  br label %295

295:                                              ; preds = %322, %223
  %296 = load i32, ptr %13, align 4, !tbaa !9
  %297 = sext i32 %296 to i64
  %298 = getelementptr inbounds [6 x i64], ptr @lls, i64 0, i64 %297
  %299 = load i64, ptr %298, align 8, !tbaa !19
  %300 = icmp ne i64 %299, 0
  br i1 %300, label %301, label %325

301:                                              ; preds = %295
  %302 = load i32, ptr %13, align 4, !tbaa !9
  %303 = sext i32 %302 to i64
  %304 = getelementptr inbounds [6 x i64], ptr @lls, i64 0, i64 %303
  %305 = load i64, ptr %304, align 8, !tbaa !19
  %306 = load i32, ptr %13, align 4, !tbaa !9
  %307 = sext i32 %306 to i64
  %308 = getelementptr inbounds [6 x i64], ptr @lls, i64 0, i64 %307
  %309 = load i64, ptr %308, align 8, !tbaa !19
  %310 = sitofp i64 %309 to double
  %311 = call i32 (ptr, ...) @printf(ptr noundef @.str.37, i64 noundef %305, double noundef %310)
  %312 = load i32, ptr %13, align 4, !tbaa !9
  %313 = sext i32 %312 to i64
  %314 = getelementptr inbounds [6 x i64], ptr @lls, i64 0, i64 %313
  %315 = load i64, ptr %314, align 8, !tbaa !19
  %316 = load i32, ptr %13, align 4, !tbaa !9
  %317 = sext i32 %316 to i64
  %318 = getelementptr inbounds [6 x i64], ptr @lls, i64 0, i64 %317
  %319 = load i64, ptr %318, align 8, !tbaa !19
  %320 = uitofp i64 %319 to double
  %321 = call i32 (ptr, ...) @printf(ptr noundef @.str.38, i64 noundef %315, double noundef %320)
  br label %322

322:                                              ; preds = %301
  %323 = load i32, ptr %13, align 4, !tbaa !9
  %324 = add nsw i32 %323, 1
  store i32 %324, ptr %13, align 4, !tbaa !9
  br label %295, !llvm.loop !25

325:                                              ; preds = %295
  call void @llvm.lifetime.end.p0(ptr %19) #5
  call void @llvm.lifetime.end.p0(ptr %18) #5
  call void @llvm.lifetime.end.p0(ptr %17) #5
  call void @llvm.lifetime.end.p0(ptr %16) #5
  call void @llvm.lifetime.end.p0(ptr %15) #5
  call void @llvm.lifetime.end.p0(ptr %14) #5
  call void @llvm.lifetime.end.p0(ptr %13) #5
  call void @llvm.lifetime.end.p0(ptr %12) #5
  call void @llvm.lifetime.end.p0(ptr %11) #5
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally i32 @atoi(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call i64 @strtol(ptr noundef %3, ptr noundef null, i32 noundef 10) #5
  %5 = trunc i64 %4 to i32
  ret i32 %5
}

declare i32 @printf(ptr noundef, ...) #3

; Function Attrs: inlinehint nounwind willreturn memory(read) uwtable
define available_externally double @atof(ptr noundef nonnull %0) #2 {
  %2 = alloca ptr, align 8
  store ptr %0, ptr %2, align 8, !tbaa !14
  %3 = load ptr, ptr %2, align 8, !tbaa !14
  %4 = call double @strtod(ptr noundef %3, ptr noundef null) #5
  ret double %4
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare i64 @strtol(ptr noundef, ptr noundef, i32 noundef) #4

; Function Attrs: nounwind
declare double @strtod(ptr noundef, ptr noundef) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { inlinehint nounwind willreturn memory(read) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"p2 omnipotent char", !12, i64 0}
!12 = !{!"any p2 pointer", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!15, !15, i64 0}
!15 = !{!"p1 omnipotent char", !13, i64 0}
!16 = !{!7, !7, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"short", !7, i64 0}
!19 = !{!20, !20, i64 0}
!20 = !{!"long", !7, i64 0}
!21 = !{!22, !22, i64 0}
!22 = !{!"float", !7, i64 0}
!23 = !{!24, !24, i64 0}
!24 = !{!"double", !7, i64 0}
!25 = distinct !{!25, !26}
!26 = !{!"llvm.loop.mustprogress"}
