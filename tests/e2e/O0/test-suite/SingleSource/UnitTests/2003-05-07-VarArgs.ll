; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c
; @llc: -O0
; @generated: clang -O0 -Xclang -disable-O0-optnone -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/2003-05-07-VarArgs.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__va_list_tag = type { i32, i32, ptr, ptr }
%struct.DWordS_struct = type { i32, i8 }
%struct.QuadWordS_struct = type { i32, double }
%struct.LargeS_struct = type { i32, double, ptr, i32 }

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

; Function Attrs: noinline nounwind uwtable
define dso_local void @test(ptr noundef %0, ...) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca [1 x %struct.__va_list_tag], align 16
  %4 = alloca [1 x %struct.__va_list_tag], align 16
  %5 = alloca i32, align 4
  %6 = alloca i8, align 1
  %7 = alloca ptr, align 8
  %8 = alloca %struct.DWordS_struct, align 4
  %9 = alloca %struct.QuadWordS_struct, align 8
  %10 = alloca %struct.LargeS_struct, align 8
  %11 = alloca %struct.QuadWordS_struct, align 8
  store ptr %0, ptr %2, align 8
  %12 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_start.p0(ptr %12)
  %13 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %4, i64 0, i64 0
  %14 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_copy.p0(ptr %13, ptr %14)
  %15 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %4, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %15)
  br label %16

16:                                               ; preds = %189, %1
  %17 = load ptr, ptr %2, align 8
  %18 = load i8, ptr %17, align 1
  %19 = icmp ne i8 %18, 0
  br i1 %19, label %20, label %190

20:                                               ; preds = %16
  %21 = load ptr, ptr %2, align 8
  %22 = getelementptr inbounds nuw i8, ptr %21, i32 1
  store ptr %22, ptr %2, align 8
  %23 = load i8, ptr %21, align 1
  %24 = sext i8 %23 to i32
  switch i32 %24, label %189 [
    i32 115, label %25
    i32 105, label %44
    i32 100, label %63
    i32 108, label %81
    i32 99, label %99
    i32 68, label %120
    i32 81, label %142
    i32 76, label %173
  ]

25:                                               ; preds = %20
  %26 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %27 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %26, i32 0, i32 0
  %28 = load i32, ptr %27, align 16
  %29 = icmp ule i32 %28, 40
  br i1 %29, label %30, label %35

30:                                               ; preds = %25
  %31 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %26, i32 0, i32 3
  %32 = load ptr, ptr %31, align 16
  %33 = getelementptr i8, ptr %32, i32 %28
  %34 = add i32 %28, 8
  store i32 %34, ptr %27, align 16
  br label %39

35:                                               ; preds = %25
  %36 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %26, i32 0, i32 2
  %37 = load ptr, ptr %36, align 8
  %38 = getelementptr i8, ptr %37, i32 8
  store ptr %38, ptr %36, align 8
  br label %39

39:                                               ; preds = %35, %30
  %40 = phi ptr [ %33, %30 ], [ %37, %35 ]
  %41 = load ptr, ptr %40, align 8
  store ptr %41, ptr %7, align 8
  %42 = load ptr, ptr %7, align 8
  %43 = call i32 (ptr, ...) @printf(ptr noundef @.str, ptr noundef %42)
  br label %189

44:                                               ; preds = %20
  %45 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %46 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %45, i32 0, i32 0
  %47 = load i32, ptr %46, align 16
  %48 = icmp ule i32 %47, 40
  br i1 %48, label %49, label %54

49:                                               ; preds = %44
  %50 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %45, i32 0, i32 3
  %51 = load ptr, ptr %50, align 16
  %52 = getelementptr i8, ptr %51, i32 %47
  %53 = add i32 %47, 8
  store i32 %53, ptr %46, align 16
  br label %58

54:                                               ; preds = %44
  %55 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %45, i32 0, i32 2
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr i8, ptr %56, i32 8
  store ptr %57, ptr %55, align 8
  br label %58

58:                                               ; preds = %54, %49
  %59 = phi ptr [ %52, %49 ], [ %56, %54 ]
  %60 = load i32, ptr %59, align 4
  store i32 %60, ptr %5, align 4
  %61 = load i32, ptr %5, align 4
  %62 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, i32 noundef %61)
  br label %189

63:                                               ; preds = %20
  %64 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %65 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %64, i32 0, i32 1
  %66 = load i32, ptr %65, align 4
  %67 = icmp ule i32 %66, 160
  br i1 %67, label %68, label %73

68:                                               ; preds = %63
  %69 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %64, i32 0, i32 3
  %70 = load ptr, ptr %69, align 16
  %71 = getelementptr i8, ptr %70, i32 %66
  %72 = add i32 %66, 16
  store i32 %72, ptr %65, align 4
  br label %77

73:                                               ; preds = %63
  %74 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %64, i32 0, i32 2
  %75 = load ptr, ptr %74, align 8
  %76 = getelementptr i8, ptr %75, i32 8
  store ptr %76, ptr %74, align 8
  br label %77

77:                                               ; preds = %73, %68
  %78 = phi ptr [ %71, %68 ], [ %75, %73 ]
  %79 = load double, ptr %78, align 8
  %80 = call i32 (ptr, ...) @printf(ptr noundef @.str.2, double noundef %79)
  br label %189

81:                                               ; preds = %20
  %82 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %83 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %82, i32 0, i32 0
  %84 = load i32, ptr %83, align 16
  %85 = icmp ule i32 %84, 40
  br i1 %85, label %86, label %91

86:                                               ; preds = %81
  %87 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %82, i32 0, i32 3
  %88 = load ptr, ptr %87, align 16
  %89 = getelementptr i8, ptr %88, i32 %84
  %90 = add i32 %84, 8
  store i32 %90, ptr %83, align 16
  br label %95

91:                                               ; preds = %81
  %92 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %82, i32 0, i32 2
  %93 = load ptr, ptr %92, align 8
  %94 = getelementptr i8, ptr %93, i32 8
  store ptr %94, ptr %92, align 8
  br label %95

95:                                               ; preds = %91, %86
  %96 = phi ptr [ %89, %86 ], [ %93, %91 ]
  %97 = load i64, ptr %96, align 8
  %98 = call i32 (ptr, ...) @printf(ptr noundef @.str.3, i64 noundef %97)
  br label %189

99:                                               ; preds = %20
  %100 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %101 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %100, i32 0, i32 0
  %102 = load i32, ptr %101, align 16
  %103 = icmp ule i32 %102, 40
  br i1 %103, label %104, label %109

104:                                              ; preds = %99
  %105 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %100, i32 0, i32 3
  %106 = load ptr, ptr %105, align 16
  %107 = getelementptr i8, ptr %106, i32 %102
  %108 = add i32 %102, 8
  store i32 %108, ptr %101, align 16
  br label %113

109:                                              ; preds = %99
  %110 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %100, i32 0, i32 2
  %111 = load ptr, ptr %110, align 8
  %112 = getelementptr i8, ptr %111, i32 8
  store ptr %112, ptr %110, align 8
  br label %113

113:                                              ; preds = %109, %104
  %114 = phi ptr [ %107, %104 ], [ %111, %109 ]
  %115 = load i32, ptr %114, align 4
  %116 = trunc i32 %115 to i8
  store i8 %116, ptr %6, align 1
  %117 = load i8, ptr %6, align 1
  %118 = sext i8 %117 to i32
  %119 = call i32 (ptr, ...) @printf(ptr noundef @.str.4, i32 noundef %118)
  br label %189

120:                                              ; preds = %20
  %121 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %122 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %121, i32 0, i32 0
  %123 = load i32, ptr %122, align 16
  %124 = icmp ule i32 %123, 40
  br i1 %124, label %125, label %130

125:                                              ; preds = %120
  %126 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %121, i32 0, i32 3
  %127 = load ptr, ptr %126, align 16
  %128 = getelementptr i8, ptr %127, i32 %123
  %129 = add i32 %123, 8
  store i32 %129, ptr %122, align 16
  br label %134

130:                                              ; preds = %120
  %131 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %121, i32 0, i32 2
  %132 = load ptr, ptr %131, align 8
  %133 = getelementptr i8, ptr %132, i32 8
  store ptr %133, ptr %131, align 8
  br label %134

134:                                              ; preds = %130, %125
  %135 = phi ptr [ %128, %125 ], [ %132, %130 ]
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %8, ptr align 4 %135, i64 8, i1 false)
  %136 = getelementptr inbounds nuw %struct.DWordS_struct, ptr %8, i32 0, i32 0
  %137 = load i32, ptr %136, align 4
  %138 = getelementptr inbounds nuw %struct.DWordS_struct, ptr %8, i32 0, i32 1
  %139 = load i8, ptr %138, align 4
  %140 = sext i8 %139 to i32
  %141 = call i32 (ptr, ...) @printf(ptr noundef @.str.5, i32 noundef %137, i32 noundef %140)
  br label %189

142:                                              ; preds = %20
  %143 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %144 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %143, i32 0, i32 0
  %145 = load i32, ptr %144, align 16
  %146 = icmp ule i32 %145, 40
  %147 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %143, i32 0, i32 1
  %148 = load i32, ptr %147, align 4
  %149 = icmp ule i32 %148, 160
  %150 = and i1 %146, %149
  br i1 %150, label %151, label %162

151:                                              ; preds = %142
  %152 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %143, i32 0, i32 3
  %153 = load ptr, ptr %152, align 16
  %154 = getelementptr i8, ptr %153, i32 %145
  %155 = getelementptr i8, ptr %153, i32 %148
  %156 = load i32, ptr %154, align 4
  %157 = getelementptr inbounds nuw { i32, double }, ptr %11, i32 0, i32 0
  store i32 %156, ptr %157, align 8
  %158 = load double, ptr %155, align 8
  %159 = getelementptr inbounds nuw { i32, double }, ptr %11, i32 0, i32 1
  store double %158, ptr %159, align 8
  %160 = add i32 %145, 8
  store i32 %160, ptr %144, align 16
  %161 = add i32 %148, 16
  store i32 %161, ptr %147, align 4
  br label %166

162:                                              ; preds = %142
  %163 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %143, i32 0, i32 2
  %164 = load ptr, ptr %163, align 8
  %165 = getelementptr i8, ptr %164, i32 16
  store ptr %165, ptr %163, align 8
  br label %166

166:                                              ; preds = %162, %151
  %167 = phi ptr [ %11, %151 ], [ %164, %162 ]
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %9, ptr align 8 %167, i64 16, i1 false)
  %168 = getelementptr inbounds nuw %struct.QuadWordS_struct, ptr %9, i32 0, i32 0
  %169 = load i32, ptr %168, align 8
  %170 = getelementptr inbounds nuw %struct.QuadWordS_struct, ptr %9, i32 0, i32 1
  %171 = load double, ptr %170, align 8
  %172 = call i32 (ptr, ...) @printf(ptr noundef @.str.6, i32 noundef %169, double noundef %171)
  br label %189

173:                                              ; preds = %20
  %174 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  %175 = getelementptr inbounds nuw %struct.__va_list_tag, ptr %174, i32 0, i32 2
  %176 = load ptr, ptr %175, align 8
  %177 = getelementptr i8, ptr %176, i32 32
  store ptr %177, ptr %175, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %10, ptr align 8 %176, i64 32, i1 false)
  %178 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 0
  %179 = load i32, ptr %178, align 8
  %180 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 1
  %181 = load double, ptr %180, align 8
  %182 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 2
  %183 = load ptr, ptr %182, align 8
  %184 = icmp ne ptr %183, null
  %185 = zext i1 %184 to i32
  %186 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %10, i32 0, i32 3
  %187 = load i32, ptr %186, align 8
  %188 = call i32 (ptr, ...) @printf(ptr noundef @.str.7, i32 noundef %179, double noundef %181, i32 noundef %185, i32 noundef %187)
  br label %189

189:                                              ; preds = %20, %173, %166, %134, %113, %95, %77, %58, %39
  br label %16, !llvm.loop !5

190:                                              ; preds = %16
  %191 = getelementptr inbounds [1 x %struct.__va_list_tag], ptr %3, i64 0, i64 0
  call void @llvm.va_end.p0(ptr %191)
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_start.p0(ptr) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_copy.p0(ptr, ptr) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.va_end.p0(ptr) #1

declare i32 @printf(ptr noundef, ...) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #3

; Function Attrs: noinline nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.DWordS_struct, align 4
  %3 = alloca %struct.QuadWordS_struct, align 8
  %4 = alloca %struct.LargeS_struct, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %2, ptr align 4 @__const.main.dw, i64 8, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %3, ptr align 8 @__const.main.qw, i64 16, i1 false)
  %5 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 0
  store i32 21, ptr %5, align 8
  %6 = getelementptr i8, ptr %4, i64 4
  call void @llvm.memset.p0.i64(ptr align 4 %6, i8 0, i64 4, i1 false)
  %7 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 1
  store double 2.200000e+01, ptr %7, align 8
  %8 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 2
  store ptr %2, ptr %8, align 8
  %9 = getelementptr inbounds nuw %struct.LargeS_struct, ptr %4, i32 0, i32 3
  store i32 23, ptr %9, align 8
  %10 = getelementptr i8, ptr %4, i64 28
  call void @llvm.memset.p0.i64(ptr align 4 %10, i8 0, i64 4, i1 false)
  call void (ptr, ...) @test(ptr noundef @.str.8, ptr noundef @.str.9, ptr noundef @.str.10, i32 noundef -123, i32 noundef 97, i32 noundef 123, i32 noundef 6, i32 noundef 7, i32 noundef 8, i32 noundef 9, ptr noundef @.str.11)
  call void (ptr, ...) @test(ptr noundef @.str.12, double noundef 1.000000e+00, double noundef 2.000000e+00, i32 noundef 32764, i64 noundef 12345677823423)
  %11 = load i64, ptr %2, align 4
  %12 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 0
  %13 = load i32, ptr %12, align 8
  %14 = getelementptr inbounds nuw { i32, double }, ptr %3, i32 0, i32 1
  %15 = load double, ptr %14, align 8
  call void (ptr, ...) @test(ptr noundef @.str.13, i64 %11, i32 %13, double %15, ptr noundef byval(%struct.LargeS_struct) align 8 %4)
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #4

attributes #0 = { noinline nounwind uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn }
attributes #2 = { "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{i32 7, !"PIE Level", i32 2}
!2 = !{i32 7, !"uwtable", i32 2}
!3 = !{i32 7, !"frame-pointer", i32 2}
!4 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!5 = distinct !{!5, !6}
!6 = !{!"llvm.loop.mustprogress"}
