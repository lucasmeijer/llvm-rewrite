; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-11-VaListArg.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-11-VaListArg.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-08-11-VaListArg.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.DWordS_struct = type { i32, i8 }
%struct.QuadWordS_struct = type { i32, double }
%struct.LargeS_struct = type { i32, double, ptr, i32 }
%struct.__va_list_tag = type { i32, i32, ptr, ptr }

@.str = private unnamed_addr constant [11 x i8] c"string %s\0A\00", align 1
@.str.1 = private unnamed_addr constant [8 x i8] c"int %d\0A\00", align 1
@.str.2 = private unnamed_addr constant [11 x i8] c"double %f\0A\00", align 1
@.str.3 = private unnamed_addr constant [16 x i8] c"long long %lld\0A\00", align 1
@.str.4 = private unnamed_addr constant [9 x i8] c"char %c\0A\00", align 1
@.str.5 = private unnamed_addr constant [18 x i8] c"DWord { %d, %c }\0A\00", align 1
@.str.6 = private unnamed_addr constant [21 x i8] c"QuadWord { %d, %f }\0A\00", align 1
@.str.7 = private unnamed_addr constant [29 x i8] c"LargeS { %d, %f, 0x%d, %d }\0A\00", align 1
@__const.main.dw = private unnamed_addr constant { i32, i8, [3 x i8] } { i32 18, i8 97, [3 x i8] zeroinitializer }, align 4
@__const.main.qw = private unnamed_addr constant { i32, [4 x i8], double } { i32 19, [4 x i8] zeroinitializer, double 2.000000e+01 }, align 8
@.str.8 = private unnamed_addr constant [11 x i8] c"ssiciiiiis\00", align 1
@.str.9 = private unnamed_addr constant [4 x i8] c"abc\00", align 1
@.str.10 = private unnamed_addr constant [4 x i8] c"def\00", align 1
@.str.11 = private unnamed_addr constant [14 x i8] c"10 args done!\00", align 1
@.str.12 = private unnamed_addr constant [5 x i8] c"ddil\00", align 1
@.str.13 = private unnamed_addr constant [4 x i8] c"DQL\00", align 1

; Function Attrs: nounwind uwtable
define dso_local void @test(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca i8, align 1
  %7 = alloca ptr, align 8
  %8 = alloca %struct.DWordS_struct, align 4
  %9 = alloca %struct.QuadWordS_struct, align 8
  %10 = alloca %struct.LargeS_struct, align 8
  %11 = alloca %struct.QuadWordS_struct, align 8
  store ptr %0, ptr %3, align 8, !tbaa !9
  store ptr %1, ptr %4, align 8, !tbaa !12
  call void @llvm.lifetime.start.p0(ptr %5) #5
  call void @llvm.lifetime.start.p0(ptr %6) #5
  call void @llvm.lifetime.start.p0(ptr %7) #5
  call void @llvm.lifetime.start.p0(ptr %8) #5
  call void @llvm.lifetime.start.p0(ptr %9) #5
  call void @llvm.lifetime.start.p0(ptr %10) #5
  br label %12

12:                                               ; preds = %185, %2
  %13 = load ptr, ptr %3, align 8, !tbaa !9
  %14 = load i8, ptr %13, align 1, !tbaa !14
  %15 = icmp ne i8 %14, 0
  br i1 %15, label %16, label %186

16:                                               ; preds = %12
  %17 = load ptr, ptr %3, align 8, !tbaa !9
  %18 = getelementptr inbounds nuw i8, ptr %17, i32 1
  store ptr %18, ptr %3, align 8, !tbaa !9
  %19 = load i8, ptr %17, align 1, !tbaa !14
  %20 = sext i8 %19 to i32
  switch i32 %20, label %185 [
    i32 115, label %21
    i32 105, label %40
    i32 100, label %59
    i32 108, label %77
    i32 99, label %95
    i32 68, label %116
    i32 81, label %138
    i32 76, label %169
  ]

21:                                               ; preds = %16
  %22 = load ptr, ptr %4, align 8, !tbaa !12
  %23 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %22, i32 0, i32 0
  %24 = load i32, ptr %23, align 8
  %25 = icmp ule i32 %24, 40
  br i1 %25, label %26, label %31

26:                                               ; preds = %21
  %27 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %22, i32 0, i32 3
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr i8, ptr %28, i32 %24
  %30 = add i32 %24, 8
  store i32 %30, ptr %23, align 8
  br label %35

31:                                               ; preds = %21
  %32 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %22, i32 0, i32 2
  %33 = load ptr, ptr %32, align 8
  %34 = getelementptr i8, ptr %33, i32 8
  store ptr %34, ptr %32, align 8
  br label %35

35:                                               ; preds = %31, %26
  %36 = phi ptr [ %29, %26 ], [ %33, %31 ]
  %37 = load ptr, ptr %36, align 8, !tbaa !9
  store ptr %37, ptr %7, align 8, !tbaa !9
  %38 = load ptr, ptr %7, align 8, !tbaa !9
  %39 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %38)
  br label %185

40:                                               ; preds = %16
  %41 = load ptr, ptr %4, align 8, !tbaa !12
  %42 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 0
  %43 = load i32, ptr %42, align 8
  %44 = icmp ule i32 %43, 40
  br i1 %44, label %45, label %50

45:                                               ; preds = %40
  %46 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 3
  %47 = load ptr, ptr %46, align 8
  %48 = getelementptr i8, ptr %47, i32 %43
  %49 = add i32 %43, 8
  store i32 %49, ptr %42, align 8
  br label %54

50:                                               ; preds = %40
  %51 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %41, i32 0, i32 2
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr i8, ptr %52, i32 8
  store ptr %53, ptr %51, align 8
  br label %54

54:                                               ; preds = %50, %45
  %55 = phi ptr [ %48, %45 ], [ %52, %50 ]
  %56 = load i32, ptr %55, align 4, !tbaa !15
  store i32 %56, ptr %5, align 4, !tbaa !15
  %57 = load i32, ptr %5, align 4, !tbaa !15
  %58 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %57)
  br label %185

59:                                               ; preds = %16
  %60 = load ptr, ptr %4, align 8, !tbaa !12
  %61 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %60, i32 0, i32 1
  %62 = load i32, ptr %61, align 4
  %63 = icmp ule i32 %62, 160
  br i1 %63, label %64, label %69

64:                                               ; preds = %59
  %65 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %60, i32 0, i32 3
  %66 = load ptr, ptr %65, align 8
  %67 = getelementptr i8, ptr %66, i32 %62
  %68 = add i32 %62, 16
  store i32 %68, ptr %61, align 4
  br label %73

69:                                               ; preds = %59
  %70 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %60, i32 0, i32 2
  %71 = load ptr, ptr %70, align 8
  %72 = getelementptr i8, ptr %71, i32 8
  store ptr %72, ptr %70, align 8
  br label %73

73:                                               ; preds = %69, %64
  %74 = phi ptr [ %67, %64 ], [ %71, %69 ]
  %75 = load double, ptr %74, align 8, !tbaa !16
  %76 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %75)
  br label %185

77:                                               ; preds = %16
  %78 = load ptr, ptr %4, align 8, !tbaa !12
  %79 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %78, i32 0, i32 0
  %80 = load i32, ptr %79, align 8
  %81 = icmp ule i32 %80, 40
  br i1 %81, label %82, label %87

82:                                               ; preds = %77
  %83 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %78, i32 0, i32 3
  %84 = load ptr, ptr %83, align 8
  %85 = getelementptr i8, ptr %84, i32 %80
  %86 = add i32 %80, 8
  store i32 %86, ptr %79, align 8
  br label %91

87:                                               ; preds = %77
  %88 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %78, i32 0, i32 2
  %89 = load ptr, ptr %88, align 8
  %90 = getelementptr i8, ptr %89, i32 8
  store ptr %90, ptr %88, align 8
  br label %91

91:                                               ; preds = %87, %82
  %92 = phi ptr [ %85, %82 ], [ %89, %87 ]
  %93 = load i64, ptr %92, align 8, !tbaa !18
  %94 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %93)
  br label %185

95:                                               ; preds = %16
  %96 = load ptr, ptr %4, align 8, !tbaa !12
  %97 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %96, i32 0, i32 0
  %98 = load i32, ptr %97, align 8
  %99 = icmp ule i32 %98, 40
  br i1 %99, label %100, label %105

100:                                              ; preds = %95
  %101 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %96, i32 0, i32 3
  %102 = load ptr, ptr %101, align 8
  %103 = getelementptr i8, ptr %102, i32 %98
  %104 = add i32 %98, 8
  store i32 %104, ptr %97, align 8
  br label %109

105:                                              ; preds = %95
  %106 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %96, i32 0, i32 2
  %107 = load ptr, ptr %106, align 8
  %108 = getelementptr i8, ptr %107, i32 8
  store ptr %108, ptr %106, align 8
  br label %109

109:                                              ; preds = %105, %100
  %110 = phi ptr [ %103, %100 ], [ %107, %105 ]
  %111 = load i32, ptr %110, align 4, !tbaa !15
  %112 = trunc i32 %111 to i8
  store i8 %112, ptr %6, align 1, !tbaa !14
  %113 = load i8, ptr %6, align 1, !tbaa !14
  %114 = sext i8 %113 to i32
  %115 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %114)
  br label %185

116:                                              ; preds = %16
  %117 = load ptr, ptr %4, align 8, !tbaa !12
  %118 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %117, i32 0, i32 0
  %119 = load i32, ptr %118, align 8
  %120 = icmp ule i32 %119, 40
  br i1 %120, label %121, label %126

121:                                              ; preds = %116
  %122 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %117, i32 0, i32 3
  %123 = load ptr, ptr %122, align 8
  %124 = getelementptr i8, ptr %123, i32 %119
  %125 = add i32 %119, 8
  store i32 %125, ptr %118, align 8
  br label %130

126:                                              ; preds = %116
  %127 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %117, i32 0, i32 2
  %128 = load ptr, ptr %127, align 8
  %129 = getelementptr i8, ptr %128, i32 8
  store ptr %129, ptr %127, align 8
  br label %130

130:                                              ; preds = %126, %121
  %131 = phi ptr [ %124, %121 ], [ %128, %126 ]
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %8, ptr align 4 %131, i64 8, i1 false), !tbaa.struct !20
  %132 = getelementptr inbounds nuw %struct.DWordS_struct, ptr %8, i32 0, i32 0
  %133 = load i32, ptr %132, align 4, !tbaa !21
  %134 = getelementptr inbounds nuw %struct.DWordS_struct, ptr %8, i32 0, i32 1
  %135 = load i8, ptr %134, align 4, !tbaa !23
  %136 = sext i8 %135 to i32
  %137 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %133, i32 noundef %136)
  br label %185

138:                                              ; preds = %16
  %139 = load ptr, ptr %4, align 8, !tbaa !12
  %140 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %139, i32 0, i32 0
  %141 = load i32, ptr %140, align 8
  %142 = icmp ule i32 %141, 40
  %143 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %139, i32 0, i32 1
  %144 = load i32, ptr %143, align 4
  %145 = icmp ule i32 %144, 160
  %146 = and i1 %142, %145
  br i1 %146, label %147, label %158

147:                                              ; preds = %138
  %148 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %139, i32 0, i32 3
  %149 = load ptr, ptr %148, align 8
  %150 = getelementptr i8, ptr %149, i32 %141
  %151 = getelementptr i8, ptr %149, i32 %144
  %152 = load i32, ptr %150, align 4
  %153 = getelementptr inbounds nuw { i32, double }, ptr %11, i32 0, i32 0
  store i32 %152, ptr %153, align 8
  %154 = load double, ptr %151, align 8
  %155 = getelementptr inbounds nuw { i32, double }, ptr %11, i32 0, i32 1
  store double %154, ptr %155, align 8
  %156 = add i32 %141, 8
  store i32 %156, ptr %140, align 8
  %157 = add i32 %144, 16
  store i32 %157, ptr %143, align 4
  br label %162

158:                                              ; preds = %138
  %159 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %139, i32 0, i32 2
  %160 = load ptr, ptr %159, align 8
  %161 = getelementptr i8, ptr %160, i32 16
  store ptr %161, ptr %159, align 8
  br label %162

162:                                              ; preds = %158, %147
  %163 = phi ptr [ %11, %147 ], [ %160, %158 ]
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %9, ptr align 8 %163, i64 16, i1 false), !tbaa.struct !24
  %164 = getelementptr inbounds nuw %struct.QuadWordS_struct, ptr %9, i32 0, i32 0
  %165 = load i32, ptr %164, align 8, !tbaa !25
  %166 = getelementptr inbounds nuw %struct.QuadWordS_struct, ptr %9, i32 0, i32 1
  %167 = load double, ptr %166, align 8, !tbaa !27
  %168 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %165, double noundef %167)
  br label %185

169:                                              ; preds = %16
  %170 = load ptr, ptr %4, align 8, !tbaa !12
  %171 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %170, i32 0, i32 2
  %172 = load ptr, ptr %171, align 8
  %173 = getelementptr i8, ptr %172, i32 32
  store ptr %173, ptr %171, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %10, ptr align 8 %172, i64 32, i1 false), !tbaa.struct !28
  %174 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 0
  %175 = load i32, ptr %174, align 8, !tbaa !31
  %176 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 1
  %177 = load double, ptr %176, align 8, !tbaa !33
  %178 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 2
  %179 = load ptr, ptr %178, align 8, !tbaa !34
  %180 = icmp ne ptr %179, null
  %181 = zext i1 %180 to i32
  %182 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 3
  %183 = load i32, ptr %182, align 8, !tbaa !35
  %184 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %175, double noundef %177, i32 noundef %181, i32 noundef %183)
  br label %185

185:                                              ; preds = %16, %169, %162, %130, %109, %91, %73, %54, %35
  br label %12, !llvm.loop !36

186:                                              ; preds = %12
  %187 = load ptr, ptr %4, align 8, !tbaa !12
  call void @llvm.va_end.p0(ptr %187)
  call void @llvm.lifetime.end.p0(ptr %10) #5
  call void @llvm.lifetime.end.p0(ptr %9) #5
  call void @llvm.lifetime.end.p0(ptr %8) #5
  call void @llvm.lifetime.end.p0(ptr %7) #5
  call void @llvm.lifetime.end.p0(ptr %6) #5
  call void @llvm.lifetime.end.p0(ptr %5) #5
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @testVaListArg(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #5
  %4 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %4)
  %5 = load ptr, ptr %2, align 8, !tbaa !9
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @test(ptr noundef %5, ptr noundef %6)
  %7 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %7)
  call void @llvm.lifetime.end.p0(ptr %3) #5
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #3

; Function Attrs: nounwind uwtable
define dso_local void @testVaCopyArg(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca [1 x %struct.__va_list_tag], align 16
  store ptr %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.lifetime.start.p0(ptr %4) #5
  %5 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %5)
  %6 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %4, i64 0, i64 0
  %7 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_copy.p0(ptr %6, ptr %7)
  %8 = load ptr, ptr %2, align 8, !tbaa !9
  %9 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %4, i64 0, i64 0
  call void @test(ptr noundef %8, ptr noundef %9)
  %10 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %4, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %10)
  %11 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %11)
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_copy.p0(ptr, ptr) #3

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.DWordS_struct, align 4
  %3 = alloca %struct.QuadWordS_struct, align 8
  %4 = alloca %struct.LargeS_struct, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %2, ptr align 4 @__const.main.dw, i64 8, i1 false)
  call void @llvm.lifetime.start.p0(ptr %3) #5
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 @__const.main.qw, i64 16, i1 false)
  call void @llvm.lifetime.start.p0(ptr %4) #5
  %5 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 0
  store i32 21, ptr %5, align 8, !tbaa !31
  %6 = getelementptr i8, ptr %4, i64 4
  call void @llvm.memset.p0.i64(ptr align 4 %6, i8 0, i64 4, i1 false)
  %7 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 1
  store double 2.200000e+01, ptr %7, align 8, !tbaa !33
  %8 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 2
  store ptr %2, ptr %8, align 8, !tbaa !34
  %9 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 3
  store i32 23, ptr %9, align 8, !tbaa !35
  %10 = getelementptr i8, ptr %4, i64 28
  call void @llvm.memset.p0.i64(ptr align 4 %10, i8 0, i64 4, i1 false)
  call void (ptr, ...) @testVaListArg(ptr noundef @.str.8, ptr noundef @.str.9, ptr noundef @.str.10, i32 noundef -123, i32 noundef 97, i32 noundef 123, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, ptr noundef @.str.11)
  call void (ptr, ...) @testVaCopyArg(ptr noundef @.str.8, ptr noundef @.str.9, ptr noundef @.str.10, i32 noundef -123, i32 noundef 97, i32 noundef 123, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, ptr noundef @.str.11)
  call void (ptr, ...) @testVaListArg(ptr noundef @.str.12, double noundef 1.000000e+00, double noundef 2.000000e+00, i32 noundef 32764, i64 noundef 12345677823423)
  call void (ptr, ...) @testVaCopyArg(ptr noundef @.str.12, double noundef 1.000000e+00, double noundef 2.000000e+00, i32 noundef 32764, i64 noundef 12345677823423)
  %11 = load i64, ptr %2, align 4
  %12 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 0
  %13 = load i32, ptr %12, align 8
  %14 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 1
  %15 = load double, ptr %14, align 8
  call void (ptr, ...) @testVaListArg(ptr noundef @.str.13, i64 %11, i32 %13, double %15, ptr noundef byval(%struct.LargeS_struct) align 8 %4)
  %16 = load i64, ptr %2, align 4
  %17 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 0
  %18 = load i32, ptr %17, align 8
  %19 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 1
  %20 = load double, ptr %19, align 8
  call void (ptr, ...) @testVaCopyArg(ptr noundef @.str.13, i64 %16, i32 %18, double %20, ptr noundef byval(%struct.LargeS_struct) align 8 %4)
  call void @llvm.lifetime.end.p0(ptr %4) #5
  call void @llvm.lifetime.end.p0(ptr %3) #5
  call void @llvm.lifetime.end.p0(ptr %2) #5
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #5 = { nounwind }

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
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 _ZTS13__va_list_tag", !11, i64 0}
!14 = !{!7, !7, i64 0}
!15 = !{!6, !6, i64 0}
!16 = !{!17, !17, i64 0}
!17 = !{!"double", !7, i64 0}
!18 = !{!19, !19, i64 0}
!19 = !{!"long long", !7, i64 0}
!20 = !{i64 0, i64 4, !15, i64 4, i64 1, !14}
!21 = !{!22, !6, i64 0}
!22 = !{!"DWordS_struct", !6, i64 0, !7, i64 4}
!23 = !{!22, !7, i64 4}
!24 = !{i64 0, i64 4, !15, i64 8, i64 8, !16}
!25 = !{!26, !6, i64 0}
!26 = !{!"QuadWordS_struct", !6, i64 0, !17, i64 8}
!27 = !{!26, !17, i64 8}
!28 = !{i64 0, i64 4, !15, i64 8, i64 8, !16, i64 16, i64 8, !29, i64 24, i64 4, !15}
!29 = !{!30, !30, i64 0}
!30 = !{!"p1 _ZTS13DWordS_struct", !11, i64 0}
!31 = !{!32, !6, i64 0}
!32 = !{!"LargeS_struct", !6, i64 0, !17, i64 8, !30, i64 16, !6, i64 24}
!33 = !{!32, !17, i64 8}
!34 = !{!32, !30, i64 16}
!35 = !{!32, !6, i64 24}
!36 = distinct !{!36, !37}
!37 = !{!"llvm.loop.mustprogress"}
