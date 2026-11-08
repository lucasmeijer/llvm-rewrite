; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ffbench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@main.nsize = internal global [3 x i32] zeroinitializer, align 4
@stderr = external global ptr, align 8
@.str = private unnamed_addr constant [28 x i8] c"Can't allocate data array.\0A\00", align 1
@.str.1 = private unnamed_addr constant [48 x i8] c"Wrong answer at (%d,%d)!  Expected %d, got %d.\0A\00", align 1
@.str.2 = private unnamed_addr constant [35 x i8] c"%d passes.  No errors in results.\0A\00", align 1
@.str.3 = private unnamed_addr constant [35 x i8] c"%d passes.  %d errors in results.\0A\00", align 1

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca ptr, align 8
  %10 = alloca i64, align 8
  %11 = alloca i64, align 8
  %12 = alloca double, align 8
  %13 = alloca double, align 8
  %14 = alloca double, align 8
  %15 = alloca double, align 8
  %16 = alloca double, align 8
  %17 = alloca double, align 8
  %18 = alloca double, align 8
  %19 = alloca double, align 8
  %20 = alloca double, align 8
  %21 = alloca double, align 8
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #7
  call void @llvm.lifetime.start.p0(ptr %3) #7
  call void @llvm.lifetime.start.p0(ptr %4) #7
  call void @llvm.lifetime.start.p0(ptr %5) #7
  call void @llvm.lifetime.start.p0(ptr %6) #7
  call void @llvm.lifetime.start.p0(ptr %7) #7
  store i32 63, ptr %7, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %8) #7
  call void @llvm.lifetime.start.p0(ptr %9) #7
  call void @llvm.lifetime.start.p0(ptr %10) #7
  call void @llvm.lifetime.start.p0(ptr %11) #7
  call void @llvm.lifetime.start.p0(ptr %12) #7
  call void @llvm.lifetime.start.p0(ptr %13) #7
  call void @llvm.lifetime.start.p0(ptr %14) #7
  call void @llvm.lifetime.start.p0(ptr %15) #7
  call void @llvm.lifetime.start.p0(ptr %16) #7
  call void @llvm.lifetime.start.p0(ptr %17) #7
  store i32 256, ptr %8, align 4, !tbaa !9
  %22 = load i32, ptr %8, align 4, !tbaa !9
  %23 = load i32, ptr %8, align 4, !tbaa !9
  %24 = mul nsw i32 %22, %23
  %25 = sext i32 %24 to i64
  store i64 %25, ptr %10, align 8, !tbaa !10
  %26 = load i64, ptr %10, align 8, !tbaa !10
  %27 = add nsw i64 %26, 1
  %28 = mul nsw i64 %27, 2
  %29 = mul i64 %28, 8
  store i64 %29, ptr %11, align 8, !tbaa !10
  %30 = load i32, ptr %8, align 4, !tbaa !9
  store i32 %30, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 8), align 4, !tbaa !9
  store i32 %30, ptr getelementptr inbounds nuw (i8, ptr @main.nsize, i64 4), align 4, !tbaa !9
  %31 = load i64, ptr %11, align 8, !tbaa !10
  %32 = call noalias ptr @malloc(i64 noundef %31) #8
  store ptr %32, ptr %9, align 8, !tbaa !12
  %33 = load ptr, ptr %9, align 8, !tbaa !12
  %34 = icmp eq ptr %33, null
  br i1 %34, label %35, label %38

35:                                               ; preds = %0
  %36 = load ptr, ptr @stderr, align 8, !tbaa !15
  %37 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %36, ptr noundef @.str) #7
  call void @exit(i32 noundef 1) #9
  unreachable

38:                                               ; preds = %0
  %39 = load ptr, ptr %9, align 8, !tbaa !12
  %40 = load i64, ptr %11, align 8, !tbaa !10
  call void @llvm.memset.p0.i64(ptr align 8 %39, i8 0, i64 %40, i1 false)
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %41

41:                                               ; preds = %74, %38
  %42 = load i32, ptr %2, align 4, !tbaa !9
  %43 = load i32, ptr %8, align 4, !tbaa !9
  %44 = icmp slt i32 %42, %43
  br i1 %44, label %45, label %77

45:                                               ; preds = %41
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %46

46:                                               ; preds = %70, %45
  %47 = load i32, ptr %3, align 4, !tbaa !9
  %48 = load i32, ptr %8, align 4, !tbaa !9
  %49 = icmp slt i32 %47, %48
  br i1 %49, label %50, label %73

50:                                               ; preds = %46
  %51 = load i32, ptr %2, align 4, !tbaa !9
  %52 = and i32 %51, 15
  %53 = icmp eq i32 %52, 8
  br i1 %53, label %58, label %54

54:                                               ; preds = %50
  %55 = load i32, ptr %3, align 4, !tbaa !9
  %56 = and i32 %55, 15
  %57 = icmp eq i32 %56, 8
  br i1 %57, label %58, label %69

58:                                               ; preds = %54, %50
  %59 = load ptr, ptr %9, align 8, !tbaa !12
  %60 = load i32, ptr %8, align 4, !tbaa !9
  %61 = load i32, ptr %2, align 4, !tbaa !9
  %62 = mul nsw i32 %60, %61
  %63 = load i32, ptr %3, align 4, !tbaa !9
  %64 = add nsw i32 %62, %63
  %65 = mul nsw i32 %64, 2
  %66 = add nsw i32 1, %65
  %67 = sext i32 %66 to i64
  %68 = getelementptr inbounds double, ptr %59, i64 %67
  store double 1.280000e+02, ptr %68, align 8, !tbaa !17
  br label %69

69:                                               ; preds = %58, %54
  br label %70

70:                                               ; preds = %69
  %71 = load i32, ptr %3, align 4, !tbaa !9
  %72 = add nsw i32 %71, 1
  store i32 %72, ptr %3, align 4, !tbaa !9
  br label %46, !llvm.loop !19

73:                                               ; preds = %46
  br label %74

74:                                               ; preds = %73
  %75 = load i32, ptr %2, align 4, !tbaa !9
  %76 = add nsw i32 %75, 1
  store i32 %76, ptr %2, align 4, !tbaa !9
  br label %41, !llvm.loop !21

77:                                               ; preds = %41
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %78

78:                                               ; preds = %85, %77
  %79 = load i32, ptr %2, align 4, !tbaa !9
  %80 = load i32, ptr %7, align 4, !tbaa !9
  %81 = icmp slt i32 %79, %80
  br i1 %81, label %82, label %88

82:                                               ; preds = %78
  %83 = load ptr, ptr %9, align 8, !tbaa !12
  call void @fourn(ptr noundef %83, ptr noundef @main.nsize, i32 noundef 2, i32 noundef 1)
  %84 = load ptr, ptr %9, align 8, !tbaa !12
  call void @fourn(ptr noundef %84, ptr noundef @main.nsize, i32 noundef 2, i32 noundef -1)
  br label %85

85:                                               ; preds = %82
  %86 = load i32, ptr %2, align 4, !tbaa !9
  %87 = add nsw i32 %86, 1
  store i32 %87, ptr %2, align 4, !tbaa !9
  br label %78, !llvm.loop !22

88:                                               ; preds = %78
  call void @llvm.lifetime.start.p0(ptr %18) #7
  call void @llvm.lifetime.start.p0(ptr %19) #7
  call void @llvm.lifetime.start.p0(ptr %20) #7
  call void @llvm.lifetime.start.p0(ptr %21) #7
  store double 1.000000e+10, ptr %14, align 8, !tbaa !17
  store double -1.000000e+10, ptr %15, align 8, !tbaa !17
  store double 1.000000e+10, ptr %16, align 8, !tbaa !17
  store double -1.000000e+10, ptr %17, align 8, !tbaa !17
  store double 0.000000e+00, ptr %20, align 8, !tbaa !17
  store double 0.000000e+00, ptr %21, align 8, !tbaa !17
  store i32 1, ptr %2, align 4, !tbaa !9
  br label %89

89:                                               ; preds = %148, %88
  %90 = load i32, ptr %2, align 4, !tbaa !9
  %91 = sext i32 %90 to i64
  %92 = load i64, ptr %10, align 8, !tbaa !10
  %93 = icmp sle i64 %91, %92
  br i1 %93, label %94, label %151

94:                                               ; preds = %89
  %95 = load ptr, ptr %9, align 8, !tbaa !12
  %96 = load i32, ptr %2, align 4, !tbaa !9
  %97 = sext i32 %96 to i64
  %98 = getelementptr inbounds double, ptr %95, i64 %97
  %99 = load double, ptr %98, align 8, !tbaa !17
  store double %99, ptr %18, align 8, !tbaa !17
  %100 = load ptr, ptr %9, align 8, !tbaa !12
  %101 = load i32, ptr %2, align 4, !tbaa !9
  %102 = add nsw i32 %101, 1
  %103 = sext i32 %102 to i64
  %104 = getelementptr inbounds double, ptr %100, i64 %103
  %105 = load double, ptr %104, align 8, !tbaa !17
  store double %105, ptr %19, align 8, !tbaa !17
  %106 = load double, ptr %18, align 8, !tbaa !17
  %107 = load double, ptr %20, align 8, !tbaa !17
  %108 = fadd double %107, %106
  store double %108, ptr %20, align 8, !tbaa !17
  %109 = load double, ptr %19, align 8, !tbaa !17
  %110 = load double, ptr %21, align 8, !tbaa !17
  %111 = fadd double %110, %109
  store double %111, ptr %21, align 8, !tbaa !17
  %112 = load double, ptr %18, align 8, !tbaa !17
  %113 = load double, ptr %14, align 8, !tbaa !17
  %114 = fcmp ole double %112, %113
  br i1 %114, label %115, label %117

115:                                              ; preds = %94
  %116 = load double, ptr %18, align 8, !tbaa !17
  br label %119

117:                                              ; preds = %94
  %118 = load double, ptr %14, align 8, !tbaa !17
  br label %119

119:                                              ; preds = %117, %115
  %120 = phi double [ %116, %115 ], [ %118, %117 ]
  store double %120, ptr %14, align 8, !tbaa !17
  %121 = load double, ptr %18, align 8, !tbaa !17
  %122 = load double, ptr %15, align 8, !tbaa !17
  %123 = fcmp ogt double %121, %122
  br i1 %123, label %124, label %126

124:                                              ; preds = %119
  %125 = load double, ptr %18, align 8, !tbaa !17
  br label %128

126:                                              ; preds = %119
  %127 = load double, ptr %15, align 8, !tbaa !17
  br label %128

128:                                              ; preds = %126, %124
  %129 = phi double [ %125, %124 ], [ %127, %126 ]
  store double %129, ptr %15, align 8, !tbaa !17
  %130 = load double, ptr %19, align 8, !tbaa !17
  %131 = load double, ptr %16, align 8, !tbaa !17
  %132 = fcmp ole double %130, %131
  br i1 %132, label %133, label %135

133:                                              ; preds = %128
  %134 = load double, ptr %19, align 8, !tbaa !17
  br label %137

135:                                              ; preds = %128
  %136 = load double, ptr %16, align 8, !tbaa !17
  br label %137

137:                                              ; preds = %135, %133
  %138 = phi double [ %134, %133 ], [ %136, %135 ]
  store double %138, ptr %16, align 8, !tbaa !17
  %139 = load double, ptr %19, align 8, !tbaa !17
  %140 = load double, ptr %17, align 8, !tbaa !17
  %141 = fcmp ogt double %139, %140
  br i1 %141, label %142, label %144

142:                                              ; preds = %137
  %143 = load double, ptr %19, align 8, !tbaa !17
  br label %146

144:                                              ; preds = %137
  %145 = load double, ptr %17, align 8, !tbaa !17
  br label %146

146:                                              ; preds = %144, %142
  %147 = phi double [ %143, %142 ], [ %145, %144 ]
  store double %147, ptr %17, align 8, !tbaa !17
  br label %148

148:                                              ; preds = %146
  %149 = load i32, ptr %2, align 4, !tbaa !9
  %150 = add nsw i32 %149, 2
  store i32 %150, ptr %2, align 4, !tbaa !9
  br label %89, !llvm.loop !23

151:                                              ; preds = %89
  %152 = load double, ptr %14, align 8, !tbaa !17
  store double %152, ptr %12, align 8, !tbaa !17
  %153 = load double, ptr %15, align 8, !tbaa !17
  %154 = load double, ptr %14, align 8, !tbaa !17
  %155 = fsub double %153, %154
  %156 = fdiv double 2.550000e+02, %155
  store double %156, ptr %13, align 8, !tbaa !17
  call void @llvm.lifetime.end.p0(ptr %21) #7
  call void @llvm.lifetime.end.p0(ptr %20) #7
  call void @llvm.lifetime.end.p0(ptr %19) #7
  call void @llvm.lifetime.end.p0(ptr %18) #7
  store i32 0, ptr %6, align 4, !tbaa !9
  store i32 0, ptr %2, align 4, !tbaa !9
  br label %157

157:                                              ; preds = %211, %151
  %158 = load i32, ptr %2, align 4, !tbaa !9
  %159 = load i32, ptr %8, align 4, !tbaa !9
  %160 = icmp slt i32 %158, %159
  br i1 %160, label %161, label %214

161:                                              ; preds = %157
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %162

162:                                              ; preds = %207, %161
  %163 = load i32, ptr %3, align 4, !tbaa !9
  %164 = load i32, ptr %8, align 4, !tbaa !9
  %165 = icmp slt i32 %163, %164
  br i1 %165, label %166, label %210

166:                                              ; preds = %162
  %167 = load ptr, ptr %9, align 8, !tbaa !12
  %168 = load i32, ptr %8, align 4, !tbaa !9
  %169 = load i32, ptr %2, align 4, !tbaa !9
  %170 = mul nsw i32 %168, %169
  %171 = load i32, ptr %3, align 4, !tbaa !9
  %172 = add nsw i32 %170, %171
  %173 = mul nsw i32 %172, 2
  %174 = add nsw i32 1, %173
  %175 = sext i32 %174 to i64
  %176 = getelementptr inbounds double, ptr %167, i64 %175
  %177 = load double, ptr %176, align 8, !tbaa !17
  %178 = load double, ptr %12, align 8, !tbaa !17
  %179 = fsub double %177, %178
  %180 = load double, ptr %13, align 8, !tbaa !17
  %181 = fmul double %179, %180
  %182 = fptosi double %181 to i32
  store i32 %182, ptr %4, align 4, !tbaa !9
  %183 = load i32, ptr %2, align 4, !tbaa !9
  %184 = and i32 %183, 15
  %185 = icmp eq i32 %184, 8
  br i1 %185, label %190, label %186

186:                                              ; preds = %166
  %187 = load i32, ptr %3, align 4, !tbaa !9
  %188 = and i32 %187, 15
  %189 = icmp eq i32 %188, 8
  br label %190

190:                                              ; preds = %186, %166
  %191 = phi i1 [ true, %166 ], [ %189, %186 ]
  %192 = zext i1 %191 to i64
  %193 = select i1 %191, i32 255, i32 0
  store i32 %193, ptr %5, align 4, !tbaa !9
  %194 = load i32, ptr %4, align 4, !tbaa !9
  %195 = load i32, ptr %5, align 4, !tbaa !9
  %196 = icmp ne i32 %194, %195
  br i1 %196, label %197, label %206

197:                                              ; preds = %190
  %198 = load i32, ptr %6, align 4, !tbaa !9
  %199 = add nsw i32 %198, 1
  store i32 %199, ptr %6, align 4, !tbaa !9
  %200 = load ptr, ptr @stderr, align 8, !tbaa !15
  %201 = load i32, ptr %2, align 4, !tbaa !9
  %202 = load i32, ptr %3, align 4, !tbaa !9
  %203 = load i32, ptr %5, align 4, !tbaa !9
  %204 = load i32, ptr %4, align 4, !tbaa !9
  %205 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %200, ptr noundef @.str.1, i32 noundef %201, i32 noundef %202, i32 noundef %203, i32 noundef %204) #7
  br label %206

206:                                              ; preds = %197, %190
  br label %207

207:                                              ; preds = %206
  %208 = load i32, ptr %3, align 4, !tbaa !9
  %209 = add nsw i32 %208, 1
  store i32 %209, ptr %3, align 4, !tbaa !9
  br label %162, !llvm.loop !24

210:                                              ; preds = %162
  br label %211

211:                                              ; preds = %210
  %212 = load i32, ptr %2, align 4, !tbaa !9
  %213 = add nsw i32 %212, 1
  store i32 %213, ptr %2, align 4, !tbaa !9
  br label %157, !llvm.loop !25

214:                                              ; preds = %157
  %215 = load i32, ptr %6, align 4, !tbaa !9
  %216 = icmp eq i32 %215, 0
  br i1 %216, label %217, label %221

217:                                              ; preds = %214
  %218 = load ptr, ptr @stderr, align 8, !tbaa !15
  %219 = load i32, ptr %7, align 4, !tbaa !9
  %220 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %218, ptr noundef @.str.2, i32 noundef %219) #7
  br label %226

221:                                              ; preds = %214
  %222 = load ptr, ptr @stderr, align 8, !tbaa !15
  %223 = load i32, ptr %7, align 4, !tbaa !9
  %224 = load i32, ptr %6, align 4, !tbaa !9
  %225 = call i32 (ptr, ptr, ...) @fprintf(ptr noundef %222, ptr noundef @.str.3, i32 noundef %223, i32 noundef %224) #7
  br label %226

226:                                              ; preds = %221, %217
  call void @llvm.lifetime.end.p0(ptr %17) #7
  call void @llvm.lifetime.end.p0(ptr %16) #7
  call void @llvm.lifetime.end.p0(ptr %15) #7
  call void @llvm.lifetime.end.p0(ptr %14) #7
  call void @llvm.lifetime.end.p0(ptr %13) #7
  call void @llvm.lifetime.end.p0(ptr %12) #7
  call void @llvm.lifetime.end.p0(ptr %11) #7
  call void @llvm.lifetime.end.p0(ptr %10) #7
  call void @llvm.lifetime.end.p0(ptr %9) #7
  call void @llvm.lifetime.end.p0(ptr %8) #7
  call void @llvm.lifetime.end.p0(ptr %7) #7
  call void @llvm.lifetime.end.p0(ptr %6) #7
  call void @llvm.lifetime.end.p0(ptr %5) #7
  call void @llvm.lifetime.end.p0(ptr %4) #7
  call void @llvm.lifetime.end.p0(ptr %3) #7
  call void @llvm.lifetime.end.p0(ptr %2) #7
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #2

; Function Attrs: nounwind
declare i32 @fprintf(ptr noundef, ptr noundef, ...) #3

; Function Attrs: noreturn nounwind
declare void @exit(i32 noundef) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #5

; Function Attrs: nounwind uwtable
define internal void @fourn(ptr noundef %0, ptr noundef %1, i32 noundef %2, i32 noundef %3) #0 {
  %5 = alloca ptr, align 8
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca i32, align 4
  %11 = alloca i32, align 4
  %12 = alloca i32, align 4
  %13 = alloca i32, align 4
  %14 = alloca i32, align 4
  %15 = alloca i32, align 4
  %16 = alloca i32, align 4
  %17 = alloca i32, align 4
  %18 = alloca i32, align 4
  %19 = alloca i32, align 4
  %20 = alloca i32, align 4
  %21 = alloca i32, align 4
  %22 = alloca i32, align 4
  %23 = alloca i32, align 4
  %24 = alloca i32, align 4
  %25 = alloca i32, align 4
  %26 = alloca i32, align 4
  %27 = alloca double, align 8
  %28 = alloca double, align 8
  %29 = alloca double, align 8
  %30 = alloca double, align 8
  %31 = alloca double, align 8
  %32 = alloca double, align 8
  %33 = alloca double, align 8
  %34 = alloca double, align 8
  store ptr %0, ptr %5, align 8, !tbaa !12
  store ptr %1, ptr %6, align 8, !tbaa !26
  store i32 %2, ptr %7, align 4, !tbaa !9
  store i32 %3, ptr %8, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %9) #7
  call void @llvm.lifetime.start.p0(ptr %10) #7
  call void @llvm.lifetime.start.p0(ptr %11) #7
  call void @llvm.lifetime.start.p0(ptr %12) #7
  call void @llvm.lifetime.start.p0(ptr %13) #7
  call void @llvm.lifetime.start.p0(ptr %14) #7
  call void @llvm.lifetime.start.p0(ptr %15) #7
  call void @llvm.lifetime.start.p0(ptr %16) #7
  call void @llvm.lifetime.start.p0(ptr %17) #7
  call void @llvm.lifetime.start.p0(ptr %18) #7
  call void @llvm.lifetime.start.p0(ptr %19) #7
  call void @llvm.lifetime.start.p0(ptr %20) #7
  call void @llvm.lifetime.start.p0(ptr %21) #7
  call void @llvm.lifetime.start.p0(ptr %22) #7
  call void @llvm.lifetime.start.p0(ptr %23) #7
  call void @llvm.lifetime.start.p0(ptr %24) #7
  call void @llvm.lifetime.start.p0(ptr %25) #7
  call void @llvm.lifetime.start.p0(ptr %26) #7
  call void @llvm.lifetime.start.p0(ptr %27) #7
  call void @llvm.lifetime.start.p0(ptr %28) #7
  call void @llvm.lifetime.start.p0(ptr %29) #7
  call void @llvm.lifetime.start.p0(ptr %30) #7
  call void @llvm.lifetime.start.p0(ptr %31) #7
  call void @llvm.lifetime.start.p0(ptr %32) #7
  call void @llvm.lifetime.start.p0(ptr %33) #7
  call void @llvm.lifetime.start.p0(ptr %34) #7
  store i32 1, ptr %26, align 4, !tbaa !9
  store i32 1, ptr %20, align 4, !tbaa !9
  br label %35

35:                                               ; preds = %47, %4
  %36 = load i32, ptr %20, align 4, !tbaa !9
  %37 = load i32, ptr %7, align 4, !tbaa !9
  %38 = icmp sle i32 %36, %37
  br i1 %38, label %39, label %50

39:                                               ; preds = %35
  %40 = load ptr, ptr %6, align 8, !tbaa !26
  %41 = load i32, ptr %20, align 4, !tbaa !9
  %42 = sext i32 %41 to i64
  %43 = getelementptr inbounds i32, ptr %40, i64 %42
  %44 = load i32, ptr %43, align 4, !tbaa !9
  %45 = load i32, ptr %26, align 4, !tbaa !9
  %46 = mul nsw i32 %45, %44
  store i32 %46, ptr %26, align 4, !tbaa !9
  br label %47

47:                                               ; preds = %39
  %48 = load i32, ptr %20, align 4, !tbaa !9
  %49 = add nsw i32 %48, 1
  store i32 %49, ptr %20, align 4, !tbaa !9
  br label %35, !llvm.loop !28

50:                                               ; preds = %35
  store i32 1, ptr %24, align 4, !tbaa !9
  %51 = load i32, ptr %7, align 4, !tbaa !9
  store i32 %51, ptr %20, align 4, !tbaa !9
  br label %52

52:                                               ; preds = %337, %50
  %53 = load i32, ptr %20, align 4, !tbaa !9
  %54 = icmp sge i32 %53, 1
  br i1 %54, label %55, label %340

55:                                               ; preds = %52
  %56 = load ptr, ptr %6, align 8, !tbaa !26
  %57 = load i32, ptr %20, align 4, !tbaa !9
  %58 = sext i32 %57 to i64
  %59 = getelementptr inbounds i32, ptr %56, i64 %58
  %60 = load i32, ptr %59, align 4, !tbaa !9
  store i32 %60, ptr %23, align 4, !tbaa !9
  %61 = load i32, ptr %26, align 4, !tbaa !9
  %62 = load i32, ptr %23, align 4, !tbaa !9
  %63 = load i32, ptr %24, align 4, !tbaa !9
  %64 = mul nsw i32 %62, %63
  %65 = sdiv i32 %61, %64
  store i32 %65, ptr %25, align 4, !tbaa !9
  %66 = load i32, ptr %24, align 4, !tbaa !9
  %67 = shl i32 %66, 1
  store i32 %67, ptr %14, align 4, !tbaa !9
  %68 = load i32, ptr %14, align 4, !tbaa !9
  %69 = load i32, ptr %23, align 4, !tbaa !9
  %70 = mul nsw i32 %68, %69
  store i32 %70, ptr %15, align 4, !tbaa !9
  %71 = load i32, ptr %15, align 4, !tbaa !9
  %72 = load i32, ptr %25, align 4, !tbaa !9
  %73 = mul nsw i32 %71, %72
  store i32 %73, ptr %16, align 4, !tbaa !9
  store i32 1, ptr %12, align 4, !tbaa !9
  store i32 1, ptr %10, align 4, !tbaa !9
  br label %74

74:                                               ; preds = %177, %55
  %75 = load i32, ptr %10, align 4, !tbaa !9
  %76 = load i32, ptr %15, align 4, !tbaa !9
  %77 = icmp sle i32 %75, %76
  br i1 %77, label %78, label %181

78:                                               ; preds = %74
  %79 = load i32, ptr %10, align 4, !tbaa !9
  %80 = load i32, ptr %12, align 4, !tbaa !9
  %81 = icmp slt i32 %79, %80
  br i1 %81, label %82, label %154

82:                                               ; preds = %78
  %83 = load i32, ptr %10, align 4, !tbaa !9
  store i32 %83, ptr %9, align 4, !tbaa !9
  br label %84

84:                                               ; preds = %150, %82
  %85 = load i32, ptr %9, align 4, !tbaa !9
  %86 = load i32, ptr %10, align 4, !tbaa !9
  %87 = load i32, ptr %14, align 4, !tbaa !9
  %88 = add nsw i32 %86, %87
  %89 = sub nsw i32 %88, 2
  %90 = icmp sle i32 %85, %89
  br i1 %90, label %91, label %153

91:                                               ; preds = %84
  %92 = load i32, ptr %9, align 4, !tbaa !9
  store i32 %92, ptr %11, align 4, !tbaa !9
  br label %93

93:                                               ; preds = %145, %91
  %94 = load i32, ptr %11, align 4, !tbaa !9
  %95 = load i32, ptr %16, align 4, !tbaa !9
  %96 = icmp sle i32 %94, %95
  br i1 %96, label %97, label %149

97:                                               ; preds = %93
  %98 = load i32, ptr %12, align 4, !tbaa !9
  %99 = load i32, ptr %11, align 4, !tbaa !9
  %100 = add nsw i32 %98, %99
  %101 = load i32, ptr %10, align 4, !tbaa !9
  %102 = sub nsw i32 %100, %101
  store i32 %102, ptr %13, align 4, !tbaa !9
  %103 = load ptr, ptr %5, align 8, !tbaa !12
  %104 = load i32, ptr %11, align 4, !tbaa !9
  %105 = sext i32 %104 to i64
  %106 = getelementptr inbounds double, ptr %103, i64 %105
  %107 = load double, ptr %106, align 8, !tbaa !17
  store double %107, ptr %28, align 8, !tbaa !17
  %108 = load ptr, ptr %5, align 8, !tbaa !12
  %109 = load i32, ptr %13, align 4, !tbaa !9
  %110 = sext i32 %109 to i64
  %111 = getelementptr inbounds double, ptr %108, i64 %110
  %112 = load double, ptr %111, align 8, !tbaa !17
  %113 = load ptr, ptr %5, align 8, !tbaa !12
  %114 = load i32, ptr %11, align 4, !tbaa !9
  %115 = sext i32 %114 to i64
  %116 = getelementptr inbounds double, ptr %113, i64 %115
  store double %112, ptr %116, align 8, !tbaa !17
  %117 = load double, ptr %28, align 8, !tbaa !17
  %118 = load ptr, ptr %5, align 8, !tbaa !12
  %119 = load i32, ptr %13, align 4, !tbaa !9
  %120 = sext i32 %119 to i64
  %121 = getelementptr inbounds double, ptr %118, i64 %120
  store double %117, ptr %121, align 8, !tbaa !17
  %122 = load ptr, ptr %5, align 8, !tbaa !12
  %123 = load i32, ptr %11, align 4, !tbaa !9
  %124 = add nsw i32 %123, 1
  %125 = sext i32 %124 to i64
  %126 = getelementptr inbounds double, ptr %122, i64 %125
  %127 = load double, ptr %126, align 8, !tbaa !17
  store double %127, ptr %28, align 8, !tbaa !17
  %128 = load ptr, ptr %5, align 8, !tbaa !12
  %129 = load i32, ptr %13, align 4, !tbaa !9
  %130 = add nsw i32 %129, 1
  %131 = sext i32 %130 to i64
  %132 = getelementptr inbounds double, ptr %128, i64 %131
  %133 = load double, ptr %132, align 8, !tbaa !17
  %134 = load ptr, ptr %5, align 8, !tbaa !12
  %135 = load i32, ptr %11, align 4, !tbaa !9
  %136 = add nsw i32 %135, 1
  %137 = sext i32 %136 to i64
  %138 = getelementptr inbounds double, ptr %134, i64 %137
  store double %133, ptr %138, align 8, !tbaa !17
  %139 = load double, ptr %28, align 8, !tbaa !17
  %140 = load ptr, ptr %5, align 8, !tbaa !12
  %141 = load i32, ptr %13, align 4, !tbaa !9
  %142 = add nsw i32 %141, 1
  %143 = sext i32 %142 to i64
  %144 = getelementptr inbounds double, ptr %140, i64 %143
  store double %139, ptr %144, align 8, !tbaa !17
  br label %145

145:                                              ; preds = %97
  %146 = load i32, ptr %15, align 4, !tbaa !9
  %147 = load i32, ptr %11, align 4, !tbaa !9
  %148 = add nsw i32 %147, %146
  store i32 %148, ptr %11, align 4, !tbaa !9
  br label %93, !llvm.loop !29

149:                                              ; preds = %93
  br label %150

150:                                              ; preds = %149
  %151 = load i32, ptr %9, align 4, !tbaa !9
  %152 = add nsw i32 %151, 2
  store i32 %152, ptr %9, align 4, !tbaa !9
  br label %84, !llvm.loop !30

153:                                              ; preds = %84
  br label %154

154:                                              ; preds = %153, %78
  %155 = load i32, ptr %15, align 4, !tbaa !9
  %156 = ashr i32 %155, 1
  store i32 %156, ptr %19, align 4, !tbaa !9
  br label %157

157:                                              ; preds = %167, %154
  %158 = load i32, ptr %19, align 4, !tbaa !9
  %159 = load i32, ptr %14, align 4, !tbaa !9
  %160 = icmp sge i32 %158, %159
  br i1 %160, label %161, label %165

161:                                              ; preds = %157
  %162 = load i32, ptr %12, align 4, !tbaa !9
  %163 = load i32, ptr %19, align 4, !tbaa !9
  %164 = icmp sgt i32 %162, %163
  br label %165

165:                                              ; preds = %161, %157
  %166 = phi i1 [ false, %157 ], [ %164, %161 ]
  br i1 %166, label %167, label %173

167:                                              ; preds = %165
  %168 = load i32, ptr %19, align 4, !tbaa !9
  %169 = load i32, ptr %12, align 4, !tbaa !9
  %170 = sub nsw i32 %169, %168
  store i32 %170, ptr %12, align 4, !tbaa !9
  %171 = load i32, ptr %19, align 4, !tbaa !9
  %172 = ashr i32 %171, 1
  store i32 %172, ptr %19, align 4, !tbaa !9
  br label %157, !llvm.loop !31

173:                                              ; preds = %165
  %174 = load i32, ptr %19, align 4, !tbaa !9
  %175 = load i32, ptr %12, align 4, !tbaa !9
  %176 = add nsw i32 %175, %174
  store i32 %176, ptr %12, align 4, !tbaa !9
  br label %177

177:                                              ; preds = %173
  %178 = load i32, ptr %14, align 4, !tbaa !9
  %179 = load i32, ptr %10, align 4, !tbaa !9
  %180 = add nsw i32 %179, %178
  store i32 %180, ptr %10, align 4, !tbaa !9
  br label %74, !llvm.loop !32

181:                                              ; preds = %74
  %182 = load i32, ptr %14, align 4, !tbaa !9
  store i32 %182, ptr %17, align 4, !tbaa !9
  br label %183

183:                                              ; preds = %331, %181
  %184 = load i32, ptr %17, align 4, !tbaa !9
  %185 = load i32, ptr %15, align 4, !tbaa !9
  %186 = icmp slt i32 %184, %185
  br i1 %186, label %187, label %333

187:                                              ; preds = %183
  %188 = load i32, ptr %17, align 4, !tbaa !9
  %189 = shl i32 %188, 1
  store i32 %189, ptr %18, align 4, !tbaa !9
  %190 = load i32, ptr %8, align 4, !tbaa !9
  %191 = sitofp i32 %190 to double
  %192 = fmul double %191, f0x401921FB54442D1C
  %193 = load i32, ptr %18, align 4, !tbaa !9
  %194 = load i32, ptr %14, align 4, !tbaa !9
  %195 = sdiv i32 %193, %194
  %196 = sitofp i32 %195 to double
  %197 = fdiv double %192, %196
  store double %197, ptr %29, align 8, !tbaa !17
  %198 = load double, ptr %29, align 8, !tbaa !17
  %199 = fmul double 5.000000e-01, %198
  %200 = call double @sin(double noundef %199) #7
  store double %200, ptr %34, align 8, !tbaa !17
  %201 = load double, ptr %34, align 8, !tbaa !17
  %202 = fmul double -2.000000e+00, %201
  %203 = load double, ptr %34, align 8, !tbaa !17
  %204 = fmul double %202, %203
  store double %204, ptr %32, align 8, !tbaa !17
  %205 = load double, ptr %29, align 8, !tbaa !17
  %206 = call double @sin(double noundef %205) #7
  store double %206, ptr %31, align 8, !tbaa !17
  store double 1.000000e+00, ptr %33, align 8, !tbaa !17
  store double 0.000000e+00, ptr %30, align 8, !tbaa !17
  store i32 1, ptr %11, align 4, !tbaa !9
  br label %207

207:                                              ; preds = %327, %187
  %208 = load i32, ptr %11, align 4, !tbaa !9
  %209 = load i32, ptr %17, align 4, !tbaa !9
  %210 = icmp sle i32 %208, %209
  br i1 %210, label %211, label %331

211:                                              ; preds = %207
  %212 = load i32, ptr %11, align 4, !tbaa !9
  store i32 %212, ptr %9, align 4, !tbaa !9
  br label %213

213:                                              ; preds = %306, %211
  %214 = load i32, ptr %9, align 4, !tbaa !9
  %215 = load i32, ptr %11, align 4, !tbaa !9
  %216 = load i32, ptr %14, align 4, !tbaa !9
  %217 = add nsw i32 %215, %216
  %218 = sub nsw i32 %217, 2
  %219 = icmp sle i32 %214, %218
  br i1 %219, label %220, label %309

220:                                              ; preds = %213
  %221 = load i32, ptr %9, align 4, !tbaa !9
  store i32 %221, ptr %10, align 4, !tbaa !9
  br label %222

222:                                              ; preds = %301, %220
  %223 = load i32, ptr %10, align 4, !tbaa !9
  %224 = load i32, ptr %16, align 4, !tbaa !9
  %225 = icmp sle i32 %223, %224
  br i1 %225, label %226, label %305

226:                                              ; preds = %222
  %227 = load i32, ptr %10, align 4, !tbaa !9
  store i32 %227, ptr %21, align 4, !tbaa !9
  %228 = load i32, ptr %21, align 4, !tbaa !9
  %229 = load i32, ptr %17, align 4, !tbaa !9
  %230 = add nsw i32 %228, %229
  store i32 %230, ptr %22, align 4, !tbaa !9
  %231 = load double, ptr %33, align 8, !tbaa !17
  %232 = load ptr, ptr %5, align 8, !tbaa !12
  %233 = load i32, ptr %22, align 4, !tbaa !9
  %234 = sext i32 %233 to i64
  %235 = getelementptr inbounds double, ptr %232, i64 %234
  %236 = load double, ptr %235, align 8, !tbaa !17
  %237 = load double, ptr %30, align 8, !tbaa !17
  %238 = load ptr, ptr %5, align 8, !tbaa !12
  %239 = load i32, ptr %22, align 4, !tbaa !9
  %240 = add nsw i32 %239, 1
  %241 = sext i32 %240 to i64
  %242 = getelementptr inbounds double, ptr %238, i64 %241
  %243 = load double, ptr %242, align 8, !tbaa !17
  %244 = fmul double %237, %243
  %245 = fneg double %244
  %246 = call double @llvm.fmuladd.f64(double %231, double %236, double %245)
  store double %246, ptr %28, align 8, !tbaa !17
  %247 = load double, ptr %33, align 8, !tbaa !17
  %248 = load ptr, ptr %5, align 8, !tbaa !12
  %249 = load i32, ptr %22, align 4, !tbaa !9
  %250 = add nsw i32 %249, 1
  %251 = sext i32 %250 to i64
  %252 = getelementptr inbounds double, ptr %248, i64 %251
  %253 = load double, ptr %252, align 8, !tbaa !17
  %254 = load double, ptr %30, align 8, !tbaa !17
  %255 = load ptr, ptr %5, align 8, !tbaa !12
  %256 = load i32, ptr %22, align 4, !tbaa !9
  %257 = sext i32 %256 to i64
  %258 = getelementptr inbounds double, ptr %255, i64 %257
  %259 = load double, ptr %258, align 8, !tbaa !17
  %260 = fmul double %254, %259
  %261 = call double @llvm.fmuladd.f64(double %247, double %253, double %260)
  store double %261, ptr %27, align 8, !tbaa !17
  %262 = load ptr, ptr %5, align 8, !tbaa !12
  %263 = load i32, ptr %21, align 4, !tbaa !9
  %264 = sext i32 %263 to i64
  %265 = getelementptr inbounds double, ptr %262, i64 %264
  %266 = load double, ptr %265, align 8, !tbaa !17
  %267 = load double, ptr %28, align 8, !tbaa !17
  %268 = fsub double %266, %267
  %269 = load ptr, ptr %5, align 8, !tbaa !12
  %270 = load i32, ptr %22, align 4, !tbaa !9
  %271 = sext i32 %270 to i64
  %272 = getelementptr inbounds double, ptr %269, i64 %271
  store double %268, ptr %272, align 8, !tbaa !17
  %273 = load ptr, ptr %5, align 8, !tbaa !12
  %274 = load i32, ptr %21, align 4, !tbaa !9
  %275 = add nsw i32 %274, 1
  %276 = sext i32 %275 to i64
  %277 = getelementptr inbounds double, ptr %273, i64 %276
  %278 = load double, ptr %277, align 8, !tbaa !17
  %279 = load double, ptr %27, align 8, !tbaa !17
  %280 = fsub double %278, %279
  %281 = load ptr, ptr %5, align 8, !tbaa !12
  %282 = load i32, ptr %22, align 4, !tbaa !9
  %283 = add nsw i32 %282, 1
  %284 = sext i32 %283 to i64
  %285 = getelementptr inbounds double, ptr %281, i64 %284
  store double %280, ptr %285, align 8, !tbaa !17
  %286 = load double, ptr %28, align 8, !tbaa !17
  %287 = load ptr, ptr %5, align 8, !tbaa !12
  %288 = load i32, ptr %21, align 4, !tbaa !9
  %289 = sext i32 %288 to i64
  %290 = getelementptr inbounds double, ptr %287, i64 %289
  %291 = load double, ptr %290, align 8, !tbaa !17
  %292 = fadd double %291, %286
  store double %292, ptr %290, align 8, !tbaa !17
  %293 = load double, ptr %27, align 8, !tbaa !17
  %294 = load ptr, ptr %5, align 8, !tbaa !12
  %295 = load i32, ptr %21, align 4, !tbaa !9
  %296 = add nsw i32 %295, 1
  %297 = sext i32 %296 to i64
  %298 = getelementptr inbounds double, ptr %294, i64 %297
  %299 = load double, ptr %298, align 8, !tbaa !17
  %300 = fadd double %299, %293
  store double %300, ptr %298, align 8, !tbaa !17
  br label %301

301:                                              ; preds = %226
  %302 = load i32, ptr %18, align 4, !tbaa !9
  %303 = load i32, ptr %10, align 4, !tbaa !9
  %304 = add nsw i32 %303, %302
  store i32 %304, ptr %10, align 4, !tbaa !9
  br label %222, !llvm.loop !33

305:                                              ; preds = %222
  br label %306

306:                                              ; preds = %305
  %307 = load i32, ptr %9, align 4, !tbaa !9
  %308 = add nsw i32 %307, 2
  store i32 %308, ptr %9, align 4, !tbaa !9
  br label %213, !llvm.loop !34

309:                                              ; preds = %213
  %310 = load double, ptr %33, align 8, !tbaa !17
  store double %310, ptr %34, align 8, !tbaa !17
  %311 = load double, ptr %32, align 8, !tbaa !17
  %312 = load double, ptr %30, align 8, !tbaa !17
  %313 = load double, ptr %31, align 8, !tbaa !17
  %314 = fmul double %312, %313
  %315 = fneg double %314
  %316 = call double @llvm.fmuladd.f64(double %310, double %311, double %315)
  %317 = load double, ptr %33, align 8, !tbaa !17
  %318 = fadd double %316, %317
  store double %318, ptr %33, align 8, !tbaa !17
  %319 = load double, ptr %30, align 8, !tbaa !17
  %320 = load double, ptr %32, align 8, !tbaa !17
  %321 = load double, ptr %34, align 8, !tbaa !17
  %322 = load double, ptr %31, align 8, !tbaa !17
  %323 = fmul double %321, %322
  %324 = call double @llvm.fmuladd.f64(double %319, double %320, double %323)
  %325 = load double, ptr %30, align 8, !tbaa !17
  %326 = fadd double %324, %325
  store double %326, ptr %30, align 8, !tbaa !17
  br label %327

327:                                              ; preds = %309
  %328 = load i32, ptr %14, align 4, !tbaa !9
  %329 = load i32, ptr %11, align 4, !tbaa !9
  %330 = add nsw i32 %329, %328
  store i32 %330, ptr %11, align 4, !tbaa !9
  br label %207, !llvm.loop !35

331:                                              ; preds = %207
  %332 = load i32, ptr %18, align 4, !tbaa !9
  store i32 %332, ptr %17, align 4, !tbaa !9
  br label %183, !llvm.loop !36

333:                                              ; preds = %183
  %334 = load i32, ptr %23, align 4, !tbaa !9
  %335 = load i32, ptr %24, align 4, !tbaa !9
  %336 = mul nsw i32 %335, %334
  store i32 %336, ptr %24, align 4, !tbaa !9
  br label %337

337:                                              ; preds = %333
  %338 = load i32, ptr %20, align 4, !tbaa !9
  %339 = add nsw i32 %338, -1
  store i32 %339, ptr %20, align 4, !tbaa !9
  br label %52, !llvm.loop !37

340:                                              ; preds = %52
  call void @llvm.lifetime.end.p0(ptr %34) #7
  call void @llvm.lifetime.end.p0(ptr %33) #7
  call void @llvm.lifetime.end.p0(ptr %32) #7
  call void @llvm.lifetime.end.p0(ptr %31) #7
  call void @llvm.lifetime.end.p0(ptr %30) #7
  call void @llvm.lifetime.end.p0(ptr %29) #7
  call void @llvm.lifetime.end.p0(ptr %28) #7
  call void @llvm.lifetime.end.p0(ptr %27) #7
  call void @llvm.lifetime.end.p0(ptr %26) #7
  call void @llvm.lifetime.end.p0(ptr %25) #7
  call void @llvm.lifetime.end.p0(ptr %24) #7
  call void @llvm.lifetime.end.p0(ptr %23) #7
  call void @llvm.lifetime.end.p0(ptr %22) #7
  call void @llvm.lifetime.end.p0(ptr %21) #7
  call void @llvm.lifetime.end.p0(ptr %20) #7
  call void @llvm.lifetime.end.p0(ptr %19) #7
  call void @llvm.lifetime.end.p0(ptr %18) #7
  call void @llvm.lifetime.end.p0(ptr %17) #7
  call void @llvm.lifetime.end.p0(ptr %16) #7
  call void @llvm.lifetime.end.p0(ptr %15) #7
  call void @llvm.lifetime.end.p0(ptr %14) #7
  call void @llvm.lifetime.end.p0(ptr %13) #7
  call void @llvm.lifetime.end.p0(ptr %12) #7
  call void @llvm.lifetime.end.p0(ptr %11) #7
  call void @llvm.lifetime.end.p0(ptr %10) #7
  call void @llvm.lifetime.end.p0(ptr %9) #7
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare double @sin(double noundef) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #6

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind allocsize(0) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #6 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #7 = { nounwind }
attributes #8 = { nounwind allocsize(0) }
attributes #9 = { noreturn nounwind }

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
!11 = !{!"long", !7, i64 0}
!12 = !{!13, !13, i64 0}
!13 = !{!"p1 double", !14, i64 0}
!14 = !{!"any pointer", !7, i64 0}
!15 = !{!16, !16, i64 0}
!16 = !{!"p1 _ZTS8_IO_FILE", !14, i64 0}
!17 = !{!18, !18, i64 0}
!18 = !{!"double", !7, i64 0}
!19 = distinct !{!19, !20}
!20 = !{!"llvm.loop.mustprogress"}
!21 = distinct !{!21, !20}
!22 = distinct !{!22, !20}
!23 = distinct !{!23, !20}
!24 = distinct !{!24, !20}
!25 = distinct !{!25, !20}
!26 = !{!27, !27, i64 0}
!27 = !{!"p1 int", !14, i64 0}
!28 = distinct !{!28, !20}
!29 = distinct !{!29, !20}
!30 = distinct !{!30, !20}
!31 = distinct !{!31, !20}
!32 = distinct !{!32, !20}
!33 = distinct !{!33, !20}
!34 = distinct !{!34, !20}
!35 = distinct !{!35, !20}
!36 = distinct !{!36, !20}
!37 = distinct !{!37, !20}
