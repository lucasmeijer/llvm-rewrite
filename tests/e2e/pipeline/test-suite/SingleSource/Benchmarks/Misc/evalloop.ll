; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/evalloop.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/evalloop.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/evalloop.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@sum = dso_local global i32 0, align 4
@eval.dispatch = internal global [32 x ptr] [ptr blockaddress(@eval, %8), ptr blockaddress(@eval, %12), ptr blockaddress(@eval, %21), ptr blockaddress(@eval, %30), ptr blockaddress(@eval, %39), ptr blockaddress(@eval, %48), ptr blockaddress(@eval, %57), ptr blockaddress(@eval, %66), ptr blockaddress(@eval, %75), ptr blockaddress(@eval, %84), ptr blockaddress(@eval, %93), ptr blockaddress(@eval, %102), ptr blockaddress(@eval, %111), ptr blockaddress(@eval, %120), ptr blockaddress(@eval, %129), ptr blockaddress(@eval, %138), ptr blockaddress(@eval, %147), ptr blockaddress(@eval, %156), ptr blockaddress(@eval, %165), ptr blockaddress(@eval, %174), ptr blockaddress(@eval, %183), ptr blockaddress(@eval, %192), ptr blockaddress(@eval, %201), ptr blockaddress(@eval, %210), ptr blockaddress(@eval, %219), ptr blockaddress(@eval, %228), ptr blockaddress(@eval, %237), ptr blockaddress(@eval, %246), ptr blockaddress(@eval, %255), ptr blockaddress(@eval, %264), ptr blockaddress(@eval, %273), ptr blockaddress(@eval, %282)], align 16
@.str = private unnamed_addr constant [9 x i8] c"Sum: %u\0A\00", align 1

; Function Attrs: noinline nounwind uwtable
define dso_local void @execute(i32 noundef %0) #0 {
  %2 = alloca i32, align 4
  store i32 %0, ptr %2, align 4, !tbaa !9
  %3 = load i32, ptr %2, align 4, !tbaa !9
  %4 = load i32, ptr @sum, align 4, !tbaa !9
  %5 = add i32 %4, %3
  store i32 %5, ptr @sum, align 4, !tbaa !9
  ret void
}

; Function Attrs: noinline nounwind uwtable
define dso_local void @eval(ptr noundef %0) #0 {
  %2 = alloca ptr, align 8
  %3 = alloca i32, align 4
  store ptr %0, ptr %2, align 8, !tbaa !10
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %4

4:                                                ; preds = %1, %291
  %5 = load ptr, ptr %2, align 8, !tbaa !10
  %6 = getelementptr inbounds nuw i32, ptr %5, i32 1
  store ptr %6, ptr %2, align 8, !tbaa !10
  %7 = load i32, ptr %5, align 4, !tbaa !9
  switch i32 %7, label %291 [
    i32 0, label %9
    i32 1, label %13
    i32 2, label %22
    i32 3, label %31
    i32 4, label %40
    i32 5, label %49
    i32 6, label %58
    i32 7, label %67
    i32 8, label %76
    i32 9, label %85
    i32 10, label %94
    i32 11, label %103
    i32 12, label %112
    i32 13, label %121
    i32 14, label %130
    i32 15, label %139
    i32 16, label %148
    i32 17, label %157
    i32 18, label %166
    i32 19, label %175
    i32 20, label %184
    i32 21, label %193
    i32 22, label %202
    i32 23, label %211
    i32 24, label %220
    i32 25, label %229
    i32 26, label %238
    i32 27, label %247
    i32 28, label %256
    i32 29, label %265
    i32 30, label %274
    i32 31, label %283
  ]

8:                                                ; preds = %10
  store i32 0, ptr %3, align 4, !tbaa !9
  br label %9

9:                                                ; preds = %4, %8
  ret void

10:                                               ; preds = %283, %274, %265, %256, %247, %238, %229, %220, %211, %202, %193, %184, %175, %166, %157, %148, %139, %130, %121, %112, %103, %94, %85, %76, %67, %58, %49, %40, %31, %22, %13
  %11 = phi ptr [ %20, %13 ], [ %29, %22 ], [ %38, %31 ], [ %47, %40 ], [ %56, %49 ], [ %65, %58 ], [ %74, %67 ], [ %83, %76 ], [ %92, %85 ], [ %101, %94 ], [ %110, %103 ], [ %119, %112 ], [ %128, %121 ], [ %137, %130 ], [ %146, %139 ], [ %155, %148 ], [ %164, %157 ], [ %173, %166 ], [ %182, %175 ], [ %191, %184 ], [ %200, %193 ], [ %209, %202 ], [ %218, %211 ], [ %227, %220 ], [ %236, %229 ], [ %245, %238 ], [ %254, %247 ], [ %263, %256 ], [ %272, %265 ], [ %281, %274 ], [ %290, %283 ]
  indirectbr ptr %11, [label %8, label %12, label %21, label %30, label %39, label %48, label %57, label %66, label %75, label %84, label %93, label %102, label %111, label %120, label %129, label %138, label %147, label %156, label %165, label %174, label %183, label %192, label %201, label %210, label %219, label %228, label %237, label %246, label %255, label %264, label %273, label %282]

12:                                               ; preds = %10
  store i32 1, ptr %3, align 4, !tbaa !9
  br label %13

13:                                               ; preds = %4, %12
  %14 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %14)
  %15 = load ptr, ptr %2, align 8, !tbaa !10
  %16 = getelementptr inbounds nuw i32, ptr %15, i32 1
  store ptr %16, ptr %2, align 8, !tbaa !10
  %17 = load i32, ptr %15, align 4, !tbaa !9
  %18 = sext i32 %17 to i64
  %19 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %18
  %20 = load ptr, ptr %19, align 8, !tbaa !13
  br label %10

21:                                               ; preds = %10
  store i32 2, ptr %3, align 4, !tbaa !9
  br label %22

22:                                               ; preds = %4, %21
  %23 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %23)
  %24 = load ptr, ptr %2, align 8, !tbaa !10
  %25 = getelementptr inbounds nuw i32, ptr %24, i32 1
  store ptr %25, ptr %2, align 8, !tbaa !10
  %26 = load i32, ptr %24, align 4, !tbaa !9
  %27 = sext i32 %26 to i64
  %28 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %27
  %29 = load ptr, ptr %28, align 8, !tbaa !13
  br label %10

30:                                               ; preds = %10
  store i32 3, ptr %3, align 4, !tbaa !9
  br label %31

31:                                               ; preds = %4, %30
  %32 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %32)
  %33 = load ptr, ptr %2, align 8, !tbaa !10
  %34 = getelementptr inbounds nuw i32, ptr %33, i32 1
  store ptr %34, ptr %2, align 8, !tbaa !10
  %35 = load i32, ptr %33, align 4, !tbaa !9
  %36 = sext i32 %35 to i64
  %37 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %36
  %38 = load ptr, ptr %37, align 8, !tbaa !13
  br label %10

39:                                               ; preds = %10
  store i32 4, ptr %3, align 4, !tbaa !9
  br label %40

40:                                               ; preds = %4, %39
  %41 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %41)
  %42 = load ptr, ptr %2, align 8, !tbaa !10
  %43 = getelementptr inbounds nuw i32, ptr %42, i32 1
  store ptr %43, ptr %2, align 8, !tbaa !10
  %44 = load i32, ptr %42, align 4, !tbaa !9
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %45
  %47 = load ptr, ptr %46, align 8, !tbaa !13
  br label %10

48:                                               ; preds = %10
  store i32 5, ptr %3, align 4, !tbaa !9
  br label %49

49:                                               ; preds = %4, %48
  %50 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %50)
  %51 = load ptr, ptr %2, align 8, !tbaa !10
  %52 = getelementptr inbounds nuw i32, ptr %51, i32 1
  store ptr %52, ptr %2, align 8, !tbaa !10
  %53 = load i32, ptr %51, align 4, !tbaa !9
  %54 = sext i32 %53 to i64
  %55 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %54
  %56 = load ptr, ptr %55, align 8, !tbaa !13
  br label %10

57:                                               ; preds = %10
  store i32 6, ptr %3, align 4, !tbaa !9
  br label %58

58:                                               ; preds = %4, %57
  %59 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %59)
  %60 = load ptr, ptr %2, align 8, !tbaa !10
  %61 = getelementptr inbounds nuw i32, ptr %60, i32 1
  store ptr %61, ptr %2, align 8, !tbaa !10
  %62 = load i32, ptr %60, align 4, !tbaa !9
  %63 = sext i32 %62 to i64
  %64 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %63
  %65 = load ptr, ptr %64, align 8, !tbaa !13
  br label %10

66:                                               ; preds = %10
  store i32 7, ptr %3, align 4, !tbaa !9
  br label %67

67:                                               ; preds = %4, %66
  %68 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %68)
  %69 = load ptr, ptr %2, align 8, !tbaa !10
  %70 = getelementptr inbounds nuw i32, ptr %69, i32 1
  store ptr %70, ptr %2, align 8, !tbaa !10
  %71 = load i32, ptr %69, align 4, !tbaa !9
  %72 = sext i32 %71 to i64
  %73 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %72
  %74 = load ptr, ptr %73, align 8, !tbaa !13
  br label %10

75:                                               ; preds = %10
  store i32 8, ptr %3, align 4, !tbaa !9
  br label %76

76:                                               ; preds = %4, %75
  %77 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %77)
  %78 = load ptr, ptr %2, align 8, !tbaa !10
  %79 = getelementptr inbounds nuw i32, ptr %78, i32 1
  store ptr %79, ptr %2, align 8, !tbaa !10
  %80 = load i32, ptr %78, align 4, !tbaa !9
  %81 = sext i32 %80 to i64
  %82 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %81
  %83 = load ptr, ptr %82, align 8, !tbaa !13
  br label %10

84:                                               ; preds = %10
  store i32 9, ptr %3, align 4, !tbaa !9
  br label %85

85:                                               ; preds = %4, %84
  %86 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %86)
  %87 = load ptr, ptr %2, align 8, !tbaa !10
  %88 = getelementptr inbounds nuw i32, ptr %87, i32 1
  store ptr %88, ptr %2, align 8, !tbaa !10
  %89 = load i32, ptr %87, align 4, !tbaa !9
  %90 = sext i32 %89 to i64
  %91 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %90
  %92 = load ptr, ptr %91, align 8, !tbaa !13
  br label %10

93:                                               ; preds = %10
  store i32 10, ptr %3, align 4, !tbaa !9
  br label %94

94:                                               ; preds = %4, %93
  %95 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %95)
  %96 = load ptr, ptr %2, align 8, !tbaa !10
  %97 = getelementptr inbounds nuw i32, ptr %96, i32 1
  store ptr %97, ptr %2, align 8, !tbaa !10
  %98 = load i32, ptr %96, align 4, !tbaa !9
  %99 = sext i32 %98 to i64
  %100 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %99
  %101 = load ptr, ptr %100, align 8, !tbaa !13
  br label %10

102:                                              ; preds = %10
  store i32 11, ptr %3, align 4, !tbaa !9
  br label %103

103:                                              ; preds = %4, %102
  %104 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %104)
  %105 = load ptr, ptr %2, align 8, !tbaa !10
  %106 = getelementptr inbounds nuw i32, ptr %105, i32 1
  store ptr %106, ptr %2, align 8, !tbaa !10
  %107 = load i32, ptr %105, align 4, !tbaa !9
  %108 = sext i32 %107 to i64
  %109 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %108
  %110 = load ptr, ptr %109, align 8, !tbaa !13
  br label %10

111:                                              ; preds = %10
  store i32 12, ptr %3, align 4, !tbaa !9
  br label %112

112:                                              ; preds = %4, %111
  %113 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %113)
  %114 = load ptr, ptr %2, align 8, !tbaa !10
  %115 = getelementptr inbounds nuw i32, ptr %114, i32 1
  store ptr %115, ptr %2, align 8, !tbaa !10
  %116 = load i32, ptr %114, align 4, !tbaa !9
  %117 = sext i32 %116 to i64
  %118 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %117
  %119 = load ptr, ptr %118, align 8, !tbaa !13
  br label %10

120:                                              ; preds = %10
  store i32 13, ptr %3, align 4, !tbaa !9
  br label %121

121:                                              ; preds = %4, %120
  %122 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %122)
  %123 = load ptr, ptr %2, align 8, !tbaa !10
  %124 = getelementptr inbounds nuw i32, ptr %123, i32 1
  store ptr %124, ptr %2, align 8, !tbaa !10
  %125 = load i32, ptr %123, align 4, !tbaa !9
  %126 = sext i32 %125 to i64
  %127 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %126
  %128 = load ptr, ptr %127, align 8, !tbaa !13
  br label %10

129:                                              ; preds = %10
  store i32 14, ptr %3, align 4, !tbaa !9
  br label %130

130:                                              ; preds = %4, %129
  %131 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %131)
  %132 = load ptr, ptr %2, align 8, !tbaa !10
  %133 = getelementptr inbounds nuw i32, ptr %132, i32 1
  store ptr %133, ptr %2, align 8, !tbaa !10
  %134 = load i32, ptr %132, align 4, !tbaa !9
  %135 = sext i32 %134 to i64
  %136 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %135
  %137 = load ptr, ptr %136, align 8, !tbaa !13
  br label %10

138:                                              ; preds = %10
  store i32 15, ptr %3, align 4, !tbaa !9
  br label %139

139:                                              ; preds = %4, %138
  %140 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %140)
  %141 = load ptr, ptr %2, align 8, !tbaa !10
  %142 = getelementptr inbounds nuw i32, ptr %141, i32 1
  store ptr %142, ptr %2, align 8, !tbaa !10
  %143 = load i32, ptr %141, align 4, !tbaa !9
  %144 = sext i32 %143 to i64
  %145 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %144
  %146 = load ptr, ptr %145, align 8, !tbaa !13
  br label %10

147:                                              ; preds = %10
  store i32 16, ptr %3, align 4, !tbaa !9
  br label %148

148:                                              ; preds = %4, %147
  %149 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %149)
  %150 = load ptr, ptr %2, align 8, !tbaa !10
  %151 = getelementptr inbounds nuw i32, ptr %150, i32 1
  store ptr %151, ptr %2, align 8, !tbaa !10
  %152 = load i32, ptr %150, align 4, !tbaa !9
  %153 = sext i32 %152 to i64
  %154 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %153
  %155 = load ptr, ptr %154, align 8, !tbaa !13
  br label %10

156:                                              ; preds = %10
  store i32 17, ptr %3, align 4, !tbaa !9
  br label %157

157:                                              ; preds = %4, %156
  %158 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %158)
  %159 = load ptr, ptr %2, align 8, !tbaa !10
  %160 = getelementptr inbounds nuw i32, ptr %159, i32 1
  store ptr %160, ptr %2, align 8, !tbaa !10
  %161 = load i32, ptr %159, align 4, !tbaa !9
  %162 = sext i32 %161 to i64
  %163 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %162
  %164 = load ptr, ptr %163, align 8, !tbaa !13
  br label %10

165:                                              ; preds = %10
  store i32 18, ptr %3, align 4, !tbaa !9
  br label %166

166:                                              ; preds = %4, %165
  %167 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %167)
  %168 = load ptr, ptr %2, align 8, !tbaa !10
  %169 = getelementptr inbounds nuw i32, ptr %168, i32 1
  store ptr %169, ptr %2, align 8, !tbaa !10
  %170 = load i32, ptr %168, align 4, !tbaa !9
  %171 = sext i32 %170 to i64
  %172 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %171
  %173 = load ptr, ptr %172, align 8, !tbaa !13
  br label %10

174:                                              ; preds = %10
  store i32 19, ptr %3, align 4, !tbaa !9
  br label %175

175:                                              ; preds = %4, %174
  %176 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %176)
  %177 = load ptr, ptr %2, align 8, !tbaa !10
  %178 = getelementptr inbounds nuw i32, ptr %177, i32 1
  store ptr %178, ptr %2, align 8, !tbaa !10
  %179 = load i32, ptr %177, align 4, !tbaa !9
  %180 = sext i32 %179 to i64
  %181 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %180
  %182 = load ptr, ptr %181, align 8, !tbaa !13
  br label %10

183:                                              ; preds = %10
  store i32 20, ptr %3, align 4, !tbaa !9
  br label %184

184:                                              ; preds = %4, %183
  %185 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %185)
  %186 = load ptr, ptr %2, align 8, !tbaa !10
  %187 = getelementptr inbounds nuw i32, ptr %186, i32 1
  store ptr %187, ptr %2, align 8, !tbaa !10
  %188 = load i32, ptr %186, align 4, !tbaa !9
  %189 = sext i32 %188 to i64
  %190 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %189
  %191 = load ptr, ptr %190, align 8, !tbaa !13
  br label %10

192:                                              ; preds = %10
  store i32 21, ptr %3, align 4, !tbaa !9
  br label %193

193:                                              ; preds = %4, %192
  %194 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %194)
  %195 = load ptr, ptr %2, align 8, !tbaa !10
  %196 = getelementptr inbounds nuw i32, ptr %195, i32 1
  store ptr %196, ptr %2, align 8, !tbaa !10
  %197 = load i32, ptr %195, align 4, !tbaa !9
  %198 = sext i32 %197 to i64
  %199 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %198
  %200 = load ptr, ptr %199, align 8, !tbaa !13
  br label %10

201:                                              ; preds = %10
  store i32 22, ptr %3, align 4, !tbaa !9
  br label %202

202:                                              ; preds = %4, %201
  %203 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %203)
  %204 = load ptr, ptr %2, align 8, !tbaa !10
  %205 = getelementptr inbounds nuw i32, ptr %204, i32 1
  store ptr %205, ptr %2, align 8, !tbaa !10
  %206 = load i32, ptr %204, align 4, !tbaa !9
  %207 = sext i32 %206 to i64
  %208 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %207
  %209 = load ptr, ptr %208, align 8, !tbaa !13
  br label %10

210:                                              ; preds = %10
  store i32 23, ptr %3, align 4, !tbaa !9
  br label %211

211:                                              ; preds = %4, %210
  %212 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %212)
  %213 = load ptr, ptr %2, align 8, !tbaa !10
  %214 = getelementptr inbounds nuw i32, ptr %213, i32 1
  store ptr %214, ptr %2, align 8, !tbaa !10
  %215 = load i32, ptr %213, align 4, !tbaa !9
  %216 = sext i32 %215 to i64
  %217 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %216
  %218 = load ptr, ptr %217, align 8, !tbaa !13
  br label %10

219:                                              ; preds = %10
  store i32 24, ptr %3, align 4, !tbaa !9
  br label %220

220:                                              ; preds = %4, %219
  %221 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %221)
  %222 = load ptr, ptr %2, align 8, !tbaa !10
  %223 = getelementptr inbounds nuw i32, ptr %222, i32 1
  store ptr %223, ptr %2, align 8, !tbaa !10
  %224 = load i32, ptr %222, align 4, !tbaa !9
  %225 = sext i32 %224 to i64
  %226 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %225
  %227 = load ptr, ptr %226, align 8, !tbaa !13
  br label %10

228:                                              ; preds = %10
  store i32 25, ptr %3, align 4, !tbaa !9
  br label %229

229:                                              ; preds = %4, %228
  %230 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %230)
  %231 = load ptr, ptr %2, align 8, !tbaa !10
  %232 = getelementptr inbounds nuw i32, ptr %231, i32 1
  store ptr %232, ptr %2, align 8, !tbaa !10
  %233 = load i32, ptr %231, align 4, !tbaa !9
  %234 = sext i32 %233 to i64
  %235 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %234
  %236 = load ptr, ptr %235, align 8, !tbaa !13
  br label %10

237:                                              ; preds = %10
  store i32 26, ptr %3, align 4, !tbaa !9
  br label %238

238:                                              ; preds = %4, %237
  %239 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %239)
  %240 = load ptr, ptr %2, align 8, !tbaa !10
  %241 = getelementptr inbounds nuw i32, ptr %240, i32 1
  store ptr %241, ptr %2, align 8, !tbaa !10
  %242 = load i32, ptr %240, align 4, !tbaa !9
  %243 = sext i32 %242 to i64
  %244 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %243
  %245 = load ptr, ptr %244, align 8, !tbaa !13
  br label %10

246:                                              ; preds = %10
  store i32 27, ptr %3, align 4, !tbaa !9
  br label %247

247:                                              ; preds = %4, %246
  %248 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %248)
  %249 = load ptr, ptr %2, align 8, !tbaa !10
  %250 = getelementptr inbounds nuw i32, ptr %249, i32 1
  store ptr %250, ptr %2, align 8, !tbaa !10
  %251 = load i32, ptr %249, align 4, !tbaa !9
  %252 = sext i32 %251 to i64
  %253 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %252
  %254 = load ptr, ptr %253, align 8, !tbaa !13
  br label %10

255:                                              ; preds = %10
  store i32 28, ptr %3, align 4, !tbaa !9
  br label %256

256:                                              ; preds = %4, %255
  %257 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %257)
  %258 = load ptr, ptr %2, align 8, !tbaa !10
  %259 = getelementptr inbounds nuw i32, ptr %258, i32 1
  store ptr %259, ptr %2, align 8, !tbaa !10
  %260 = load i32, ptr %258, align 4, !tbaa !9
  %261 = sext i32 %260 to i64
  %262 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %261
  %263 = load ptr, ptr %262, align 8, !tbaa !13
  br label %10

264:                                              ; preds = %10
  store i32 29, ptr %3, align 4, !tbaa !9
  br label %265

265:                                              ; preds = %4, %264
  %266 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %266)
  %267 = load ptr, ptr %2, align 8, !tbaa !10
  %268 = getelementptr inbounds nuw i32, ptr %267, i32 1
  store ptr %268, ptr %2, align 8, !tbaa !10
  %269 = load i32, ptr %267, align 4, !tbaa !9
  %270 = sext i32 %269 to i64
  %271 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %270
  %272 = load ptr, ptr %271, align 8, !tbaa !13
  br label %10

273:                                              ; preds = %10
  store i32 30, ptr %3, align 4, !tbaa !9
  br label %274

274:                                              ; preds = %4, %273
  %275 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %275)
  %276 = load ptr, ptr %2, align 8, !tbaa !10
  %277 = getelementptr inbounds nuw i32, ptr %276, i32 1
  store ptr %277, ptr %2, align 8, !tbaa !10
  %278 = load i32, ptr %276, align 4, !tbaa !9
  %279 = sext i32 %278 to i64
  %280 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %279
  %281 = load ptr, ptr %280, align 8, !tbaa !13
  br label %10

282:                                              ; preds = %10
  store i32 31, ptr %3, align 4, !tbaa !9
  br label %283

283:                                              ; preds = %4, %282
  %284 = load i32, ptr %3, align 4, !tbaa !9
  call void @execute(i32 noundef %284)
  %285 = load ptr, ptr %2, align 8, !tbaa !10
  %286 = getelementptr inbounds nuw i32, ptr %285, i32 1
  store ptr %286, ptr %2, align 8, !tbaa !10
  %287 = load i32, ptr %285, align 4, !tbaa !9
  %288 = sext i32 %287 to i64
  %289 = getelementptr inbounds [32 x ptr], ptr @eval.dispatch, i64 0, i64 %288
  %290 = load ptr, ptr %289, align 8, !tbaa !13
  br label %10

291:                                              ; preds = %4
  br label %4
}

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #1 {
  %1 = alloca i32, align 4
  %2 = alloca i32, align 4
  %3 = alloca ptr, align 8
  %4 = alloca i32, align 4
  %5 = alloca i32, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #5
  store i32 2048, ptr %2, align 4, !tbaa !9
  %6 = call ptr @llvm.stacksave.p0()
  store ptr %6, ptr %3, align 8
  %7 = alloca i32, i64 2048, align 16
  call void @llvm.lifetime.start.p0(ptr %4) #5
  store i32 0, ptr %4, align 4, !tbaa !9
  br label %8

8:                                                ; preds = %19, %0
  %9 = load i32, ptr %4, align 4, !tbaa !9
  %10 = icmp slt i32 %9, 2047
  br i1 %10, label %12, label %11

11:                                               ; preds = %8
  call void @llvm.lifetime.end.p0(ptr %4) #5
  br label %22

12:                                               ; preds = %8
  %13 = load i32, ptr %4, align 4, !tbaa !9
  %14 = srem i32 %13, 31
  %15 = add nsw i32 %14, 1
  %16 = load i32, ptr %4, align 4, !tbaa !9
  %17 = sext i32 %16 to i64
  %18 = getelementptr inbounds i32, ptr %7, i64 %17
  store i32 %15, ptr %18, align 4, !tbaa !9
  br label %19

19:                                               ; preds = %12
  %20 = load i32, ptr %4, align 4, !tbaa !9
  %21 = add nsw i32 %20, 1
  store i32 %21, ptr %4, align 4, !tbaa !9
  br label %8, !llvm.loop !14

22:                                               ; preds = %11
  %23 = getelementptr inbounds i32, ptr %7, i64 2047
  store i32 0, ptr %23, align 4, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %5) #5
  store i32 0, ptr %5, align 4, !tbaa !9
  br label %24

24:                                               ; preds = %29, %22
  %25 = load i32, ptr %5, align 4, !tbaa !9
  %26 = icmp slt i32 %25, 100000
  br i1 %26, label %28, label %27

27:                                               ; preds = %24
  call void @llvm.lifetime.end.p0(ptr %5) #5
  br label %32

28:                                               ; preds = %24
  call void @eval(ptr noundef %7)
  br label %29

29:                                               ; preds = %28
  %30 = load i32, ptr %5, align 4, !tbaa !9
  %31 = add nsw i32 %30, 1
  store i32 %31, ptr %5, align 4, !tbaa !9
  br label %24, !llvm.loop !16

32:                                               ; preds = %27
  %33 = load i32, ptr @sum, align 4, !tbaa !9
  %34 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %33)
  store i32 0, ptr %1, align 4
  %35 = load ptr, ptr %3, align 8
  call void @llvm.stackrestore.p0(ptr %35)
  call void @llvm.lifetime.end.p0(ptr %2) #5
  %36 = load i32, ptr %1, align 4
  ret i32 %36
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #2

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare ptr @llvm.stacksave.p0() #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #2

declare i32 @printf(ptr noundef, ...) #4

; Function Attrs: nocallback nofree nosync nounwind willreturn
declare void @llvm.stackrestore.p0(ptr) #3

attributes #0 = { noinline nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #3 = { nocallback nofree nosync nounwind willreturn }
attributes #4 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
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
!9 = !{!6, !6, i64 0}
!10 = !{!11, !11, i64 0}
!11 = !{!"p1 int", !12, i64 0}
!12 = !{!"any pointer", !7, i64 0}
!13 = !{!12, !12, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.mustprogress"}
!16 = distinct !{!16, !15}
