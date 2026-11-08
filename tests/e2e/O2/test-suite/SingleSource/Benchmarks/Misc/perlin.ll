; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/perlin.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/perlin.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/perlin.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [4 x i8] c"%e\0A\00", align 1
@permutation = internal unnamed_addr constant [256 x i32] [i32 151, i32 160, i32 137, i32 91, i32 90, i32 15, i32 131, i32 13, i32 201, i32 95, i32 96, i32 53, i32 194, i32 233, i32 7, i32 225, i32 140, i32 36, i32 103, i32 30, i32 69, i32 142, i32 8, i32 99, i32 37, i32 240, i32 21, i32 10, i32 23, i32 190, i32 6, i32 148, i32 247, i32 120, i32 234, i32 75, i32 0, i32 26, i32 197, i32 62, i32 94, i32 252, i32 219, i32 203, i32 117, i32 35, i32 11, i32 32, i32 57, i32 177, i32 33, i32 88, i32 237, i32 149, i32 56, i32 87, i32 174, i32 20, i32 125, i32 136, i32 171, i32 168, i32 68, i32 175, i32 74, i32 165, i32 71, i32 134, i32 139, i32 48, i32 27, i32 166, i32 77, i32 146, i32 158, i32 231, i32 83, i32 111, i32 229, i32 122, i32 60, i32 211, i32 133, i32 230, i32 220, i32 105, i32 92, i32 41, i32 55, i32 46, i32 245, i32 40, i32 244, i32 102, i32 143, i32 54, i32 65, i32 25, i32 63, i32 161, i32 1, i32 216, i32 80, i32 73, i32 209, i32 76, i32 132, i32 187, i32 208, i32 89, i32 18, i32 169, i32 200, i32 196, i32 135, i32 130, i32 116, i32 188, i32 159, i32 86, i32 164, i32 100, i32 109, i32 198, i32 173, i32 186, i32 3, i32 64, i32 52, i32 217, i32 226, i32 250, i32 124, i32 123, i32 5, i32 202, i32 38, i32 147, i32 118, i32 126, i32 255, i32 82, i32 85, i32 212, i32 207, i32 206, i32 59, i32 227, i32 47, i32 16, i32 58, i32 17, i32 182, i32 189, i32 28, i32 42, i32 223, i32 183, i32 170, i32 213, i32 119, i32 248, i32 152, i32 2, i32 44, i32 154, i32 163, i32 70, i32 221, i32 153, i32 101, i32 155, i32 167, i32 43, i32 172, i32 9, i32 129, i32 22, i32 39, i32 253, i32 19, i32 98, i32 108, i32 110, i32 79, i32 113, i32 224, i32 232, i32 178, i32 185, i32 112, i32 104, i32 218, i32 246, i32 97, i32 228, i32 251, i32 34, i32 242, i32 193, i32 238, i32 210, i32 144, i32 12, i32 191, i32 179, i32 162, i32 241, i32 81, i32 51, i32 145, i32 235, i32 249, i32 14, i32 239, i32 107, i32 49, i32 192, i32 214, i32 31, i32 181, i32 199, i32 106, i32 157, i32 184, i32 84, i32 204, i32 176, i32 115, i32 121, i32 50, i32 45, i32 127, i32 4, i32 150, i32 254, i32 138, i32 236, i32 205, i32 93, i32 222, i32 114, i32 67, i32 29, i32 24, i32 72, i32 243, i32 141, i32 128, i32 195, i32 78, i32 66, i32 215, i32 61, i32 156, i32 180], align 16
@p = internal unnamed_addr global [512 x i32] zeroinitializer, align 16

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #0 {
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(1024) @p, ptr noundef nonnull align 16 dereferenceable(1024) @permutation, i64 1024, i1 false), !tbaa !9
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 16 dereferenceable(1024) getelementptr inbounds nuw (i8, ptr @p, i64 1024), ptr noundef nonnull align 16 dereferenceable(1024) @permutation, i64 1024, i1 false), !tbaa !9
  br label %1

1:                                                ; preds = %0, %235
  %2 = phi double [ 0.000000e+00, %0 ], [ %232, %235 ]
  %3 = phi double [ f0xC0C62C48F5C28F5C, %0 ], [ %236, %235 ]
  %4 = tail call double @llvm.floor.f64(double %3)
  %5 = fptosi double %4 to i32
  %6 = and i32 %5, 255
  %7 = fsub double %3, %4
  %8 = zext nneg i32 %6 to i64
  %9 = getelementptr inbounds nuw [4 x i8], ptr @p, i64 %8
  %10 = getelementptr inbounds nuw i8, ptr %9, i64 4
  %11 = fadd double %7, -1.000000e+00
  %12 = fmul double %7, %7
  %13 = fmul double %7, %12
  %14 = tail call double @llvm.fmuladd.f64(double %7, double 6.000000e+00, double -1.500000e+01)
  %15 = tail call double @llvm.fmuladd.f64(double %7, double %14, double 1.000000e+01)
  %16 = fmul double %13, %15
  %17 = insertelement <2 x double> poison, double %7, i64 0
  %18 = shufflevector <2 x double> %17, <2 x double> poison, <2 x i32> zeroinitializer
  %19 = insertelement <2 x double> poison, double %16, i64 0
  %20 = shufflevector <2 x double> %19, <2 x double> poison, <2 x i32> zeroinitializer
  %21 = insertelement <2 x double> poison, double %11, i64 0
  %22 = shufflevector <2 x double> %21, <2 x double> poison, <2 x i32> zeroinitializer
  br label %23

23:                                               ; preds = %1, %230
  %24 = phi double [ %2, %1 ], [ %232, %230 ]
  %25 = phi double [ f0xC075A1F9DB22D0E5, %1 ], [ %233, %230 ]
  %26 = fcmp olt double %25, 2.323450e+01
  br i1 %26, label %27, label %230

27:                                               ; preds = %23
  %28 = load i32, ptr %9, align 4, !tbaa !9
  %29 = load i32, ptr %10, align 4, !tbaa !9
  br label %30

30:                                               ; preds = %27, %136
  %31 = phi double [ %24, %27 ], [ %227, %136 ]
  %32 = phi double [ %25, %27 ], [ %228, %136 ]
  %33 = tail call double @llvm.floor.f64(double %32)
  %34 = fptosi double %33 to i32
  %35 = and i32 %34, 255
  %36 = fsub double %32, %33
  %37 = add nsw i32 %28, %35
  %38 = sext i32 %37 to i64
  %39 = getelementptr inbounds [4 x i8], ptr @p, i64 %38
  %40 = load i32, ptr %39, align 4, !tbaa !9
  %41 = getelementptr i8, ptr %39, i64 4
  %42 = load i32, ptr %41, align 4, !tbaa !9
  %43 = add nsw i32 %29, %35
  %44 = sext i32 %43 to i64
  %45 = getelementptr inbounds [4 x i8], ptr @p, i64 %44
  %46 = load i32, ptr %45, align 4, !tbaa !9
  %47 = getelementptr i8, ptr %45, i64 4
  %48 = load i32, ptr %47, align 4, !tbaa !9
  %49 = sext i32 %40 to i64
  %50 = getelementptr [4 x i8], ptr @p, i64 %49
  %51 = getelementptr i8, ptr %50, i64 396
  %52 = load i32, ptr %51, align 4, !tbaa !9
  %53 = and i32 %52, 15
  %54 = icmp samesign ult i32 %53, 4
  br i1 %54, label %59, label %55

55:                                               ; preds = %30
  %56 = and i32 %52, 13
  %57 = icmp eq i32 %56, 12
  %58 = select i1 %57, double %7, double f0x3FE87AE147AE1400
  br label %59

59:                                               ; preds = %55, %30
  %60 = phi double [ %58, %55 ], [ %36, %30 ]
  %61 = sext i32 %46 to i64
  %62 = getelementptr [4 x i8], ptr @p, i64 %61
  %63 = getelementptr i8, ptr %62, i64 396
  %64 = load i32, ptr %63, align 4, !tbaa !9
  %65 = and i32 %64, 15
  %66 = icmp samesign ult i32 %65, 4
  br i1 %66, label %71, label %67

67:                                               ; preds = %59
  %68 = and i32 %64, 13
  %69 = icmp eq i32 %68, 12
  %70 = select i1 %69, double %11, double f0x3FE87AE147AE1400
  br label %71

71:                                               ; preds = %67, %59
  %72 = phi double [ %70, %67 ], [ %36, %59 ]
  %73 = sext i32 %42 to i64
  %74 = getelementptr [4 x i8], ptr @p, i64 %73
  %75 = getelementptr i8, ptr %74, i64 396
  %76 = load i32, ptr %75, align 4, !tbaa !9
  %77 = fadd double %36, -1.000000e+00
  %78 = and i32 %76, 15
  %79 = icmp samesign ult i32 %78, 4
  br i1 %79, label %84, label %80

80:                                               ; preds = %71
  %81 = and i32 %76, 13
  %82 = icmp eq i32 %81, 12
  %83 = select i1 %82, double %7, double f0x3FE87AE147AE1400
  br label %84

84:                                               ; preds = %80, %71
  %85 = phi double [ %83, %80 ], [ %77, %71 ]
  %86 = sext i32 %48 to i64
  %87 = getelementptr [4 x i8], ptr @p, i64 %86
  %88 = getelementptr i8, ptr %87, i64 396
  %89 = load i32, ptr %88, align 4, !tbaa !9
  %90 = and i32 %89, 15
  %91 = icmp samesign ult i32 %90, 4
  br i1 %91, label %96, label %92

92:                                               ; preds = %84
  %93 = and i32 %89, 13
  %94 = icmp eq i32 %93, 12
  %95 = select i1 %94, double %11, double f0x3FE87AE147AE1400
  br label %96

96:                                               ; preds = %92, %84
  %97 = phi double [ %95, %92 ], [ %77, %84 ]
  %98 = getelementptr i8, ptr %50, i64 400
  %99 = load i32, ptr %98, align 4, !tbaa !9
  %100 = and i32 %99, 15
  %101 = icmp samesign ult i32 %100, 4
  br i1 %101, label %106, label %102

102:                                              ; preds = %96
  %103 = and i32 %99, 13
  %104 = icmp eq i32 %103, 12
  %105 = select i1 %104, double %7, double f0xBFCE147AE147B000
  br label %106

106:                                              ; preds = %102, %96
  %107 = phi double [ %105, %102 ], [ %36, %96 ]
  %108 = getelementptr i8, ptr %62, i64 400
  %109 = load i32, ptr %108, align 4, !tbaa !9
  %110 = and i32 %109, 15
  %111 = icmp samesign ult i32 %110, 4
  br i1 %111, label %116, label %112

112:                                              ; preds = %106
  %113 = and i32 %109, 13
  %114 = icmp eq i32 %113, 12
  %115 = select i1 %114, double %11, double f0xBFCE147AE147B000
  br label %116

116:                                              ; preds = %112, %106
  %117 = phi double [ %115, %112 ], [ %36, %106 ]
  %118 = getelementptr i8, ptr %74, i64 400
  %119 = load i32, ptr %118, align 4, !tbaa !9
  %120 = and i32 %119, 15
  %121 = icmp samesign ult i32 %120, 4
  br i1 %121, label %126, label %122

122:                                              ; preds = %116
  %123 = and i32 %119, 13
  %124 = icmp eq i32 %123, 12
  %125 = select i1 %124, double %7, double f0xBFCE147AE147B000
  br label %126

126:                                              ; preds = %122, %116
  %127 = phi double [ %125, %122 ], [ %77, %116 ]
  %128 = getelementptr i8, ptr %87, i64 400
  %129 = load i32, ptr %128, align 4, !tbaa !9
  %130 = and i32 %129, 15
  %131 = icmp samesign ult i32 %130, 4
  br i1 %131, label %136, label %132

132:                                              ; preds = %126
  %133 = and i32 %129, 13
  %134 = icmp eq i32 %133, 12
  %135 = select i1 %134, double %11, double f0xBFCE147AE147B000
  br label %136

136:                                              ; preds = %126, %132
  %137 = phi double [ %135, %132 ], [ %77, %126 ]
  %138 = insertelement <2 x i32> poison, i32 %119, i64 0
  %139 = insertelement <2 x i32> %138, i32 %76, i64 1
  %140 = and <2 x i32> %139, splat (i32 1)
  %141 = insertelement <2 x i32> poison, i32 %120, i64 0
  %142 = insertelement <2 x i32> %141, i32 %78, i64 1
  %143 = icmp samesign ult <2 x i32> %142, splat (i32 8)
  %144 = and <2 x i32> %139, splat (i32 2)
  %145 = insertelement <2 x double> poison, double %127, i64 0
  %146 = insertelement <2 x double> %145, double %85, i64 1
  %147 = fneg <2 x double> %146
  %148 = insertelement <2 x i32> poison, i32 %109, i64 0
  %149 = insertelement <2 x i32> %148, i32 %64, i64 1
  %150 = and <2 x i32> %149, splat (i32 1)
  %151 = insertelement <2 x i32> poison, i32 %110, i64 0
  %152 = insertelement <2 x i32> %151, i32 %65, i64 1
  %153 = icmp samesign ult <2 x i32> %152, splat (i32 8)
  %154 = and <2 x i32> %149, splat (i32 2)
  %155 = insertelement <2 x double> poison, double %117, i64 0
  %156 = insertelement <2 x double> %155, double %72, i64 1
  %157 = fneg <2 x double> %156
  %158 = insertelement <2 x i32> poison, i32 %99, i64 0
  %159 = insertelement <2 x i32> %158, i32 %52, i64 1
  %160 = and <2 x i32> %159, splat (i32 1)
  %161 = insertelement <2 x i32> poison, i32 %100, i64 0
  %162 = insertelement <2 x i32> %161, i32 %53, i64 1
  %163 = icmp samesign ult <2 x i32> %162, splat (i32 8)
  %164 = and <2 x i32> %159, splat (i32 2)
  %165 = insertelement <2 x double> poison, double %107, i64 0
  %166 = insertelement <2 x double> %165, double %60, i64 1
  %167 = fneg <2 x double> %166
  %168 = fmul double %36, %36
  %169 = fmul double %36, %168
  %170 = tail call double @llvm.fmuladd.f64(double %36, double 6.000000e+00, double -1.500000e+01)
  %171 = tail call double @llvm.fmuladd.f64(double %36, double %170, double 1.000000e+01)
  %172 = fmul double %169, %171
  %173 = insertelement <2 x i32> poison, i32 %129, i64 0
  %174 = insertelement <2 x i32> %173, i32 %89, i64 1
  %175 = and <2 x i32> %174, splat (i32 1)
  %176 = insertelement <2 x i32> poison, i32 %130, i64 0
  %177 = insertelement <2 x i32> %176, i32 %90, i64 1
  %178 = icmp samesign ult <2 x i32> %177, splat (i32 8)
  %179 = and <2 x i32> %174, splat (i32 2)
  %180 = insertelement <2 x double> poison, double %137, i64 0
  %181 = insertelement <2 x double> %180, double %97, i64 1
  %182 = fneg <2 x double> %181
  %183 = icmp eq <2 x i32> %140, zeroinitializer
  %184 = insertelement <2 x double> poison, double %77, i64 0
  %185 = shufflevector <2 x double> %184, <2 x double> poison, <2 x i32> zeroinitializer
  %186 = select <2 x i1> %143, <2 x double> %18, <2 x double> %185
  %187 = fneg <2 x double> %186
  %188 = select <2 x i1> %183, <2 x double> %186, <2 x double> %187
  %189 = icmp eq <2 x i32> %144, zeroinitializer
  %190 = select <2 x i1> %189, <2 x double> %146, <2 x double> %147
  %191 = fadd <2 x double> %188, %190
  %192 = icmp eq <2 x i32> %150, zeroinitializer
  %193 = insertelement <2 x double> poison, double %36, i64 0
  %194 = shufflevector <2 x double> %193, <2 x double> poison, <2 x i32> zeroinitializer
  %195 = select <2 x i1> %153, <2 x double> %22, <2 x double> %194
  %196 = fneg <2 x double> %195
  %197 = select <2 x i1> %192, <2 x double> %195, <2 x double> %196
  %198 = icmp eq <2 x i32> %154, zeroinitializer
  %199 = select <2 x i1> %198, <2 x double> %156, <2 x double> %157
  %200 = fadd <2 x double> %197, %199
  %201 = icmp eq <2 x i32> %160, zeroinitializer
  %202 = select <2 x i1> %163, <2 x double> %18, <2 x double> %194
  %203 = fneg <2 x double> %202
  %204 = select <2 x i1> %201, <2 x double> %202, <2 x double> %203
  %205 = icmp eq <2 x i32> %164, zeroinitializer
  %206 = select <2 x i1> %205, <2 x double> %166, <2 x double> %167
  %207 = fadd <2 x double> %204, %206
  %208 = fsub <2 x double> %200, %207
  %209 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %20, <2 x double> %208, <2 x double> %207)
  %210 = select <2 x i1> %178, <2 x double> %22, <2 x double> %185
  %211 = icmp eq <2 x i32> %175, zeroinitializer
  %212 = fneg <2 x double> %210
  %213 = select <2 x i1> %211, <2 x double> %210, <2 x double> %212
  %214 = icmp eq <2 x i32> %179, zeroinitializer
  %215 = select <2 x i1> %214, <2 x double> %181, <2 x double> %182
  %216 = fadd <2 x double> %213, %215
  %217 = fsub <2 x double> %216, %191
  %218 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %20, <2 x double> %217, <2 x double> %191)
  %219 = fsub <2 x double> %218, %209
  %220 = insertelement <2 x double> poison, double %172, i64 0
  %221 = shufflevector <2 x double> %220, <2 x double> poison, <2 x i32> zeroinitializer
  %222 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %221, <2 x double> %219, <2 x double> %209)
  %223 = extractelement <2 x double> %222, i64 0
  %224 = extractelement <2 x double> %222, i64 1
  %225 = fsub double %223, %224
  %226 = tail call noundef double @llvm.fmuladd.f64(double %225, double f0x3FED2C62745753FF, double %224)
  %227 = fadd double %31, %226
  %228 = fadd double %32, 2.450000e+00
  %229 = fcmp olt double %228, 2.323450e+01
  br i1 %229, label %30, label %230, !llvm.loop !10

230:                                              ; preds = %136, %23
  %231 = phi double [ %25, %23 ], [ %228, %136 ]
  %232 = phi double [ %24, %23 ], [ %227, %136 ]
  %233 = fadd double %231, 1.432500e+00
  %234 = fcmp olt double %233, 1.241240e+02
  br i1 %234, label %23, label %235, !llvm.loop !12

235:                                              ; preds = %230
  %236 = fadd double %3, 1.235000e-01
  %237 = fcmp olt double %236, f0x40D702647AE147AE
  br i1 %237, label %1, label %238, !llvm.loop !13

238:                                              ; preds = %235
  %239 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str, double noundef %232)
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #1

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.floor.f64(double) #2

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #3

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #4

attributes #0 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }

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
!10 = distinct !{!10, !11}
!11 = !{!"llvm.loop.mustprogress"}
!12 = distinct !{!12, !11}
!13 = distinct !{!13, !11}
