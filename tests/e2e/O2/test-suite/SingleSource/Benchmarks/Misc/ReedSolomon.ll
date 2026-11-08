; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ReedSolomon.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ReedSolomon.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/Misc/ReedSolomon.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@inited = internal unnamed_addr global i1 false, align 4
@recd = internal unnamed_addr global [255 x i32] zeroinitializer, align 16
@index_of = internal unnamed_addr global [256 x i32] zeroinitializer, align 16
@data = internal unnamed_addr global [239 x i32] zeroinitializer, align 16
@bb = internal unnamed_addr global [16 x i32] zeroinitializer, align 16
@alpha_to = internal unnamed_addr global [256 x i32] zeroinitializer, align 16
@gg = internal unnamed_addr global [17 x i32] zeroinitializer, align 16

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @rsdec_204(ptr nofree noundef writeonly captures(none) %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = alloca [18 x [16 x i32]], align 16
  %4 = alloca [18 x i32], align 16
  %5 = alloca [18 x i32], align 16
  %6 = alloca [18 x i32], align 16
  %7 = alloca [17 x i32], align 16
  %8 = alloca [8 x i32], align 16
  %9 = alloca [8 x i32], align 16
  %10 = alloca [9 x i32], align 16
  %11 = alloca [9 x i32], align 16
  %12 = load i1, ptr @inited, align 4
  br i1 %12, label %34, label %13

13:                                               ; preds = %2
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 4), align 4, !tbaa !9
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 8), align 8, !tbaa !9
  store i32 2, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 16), align 16, !tbaa !9
  store <4 x i32> <i32 1, i32 2, i32 4, i32 8>, ptr @alpha_to, align 16, !tbaa !9
  store i32 3, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 32), align 16, !tbaa !9
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 64), align 16, !tbaa !9
  store i32 29, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 32), align 16, !tbaa !9
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 128), align 16, !tbaa !9
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 256), align 16, !tbaa !9
  store <4 x i32> <i32 16, i32 32, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 16), align 16, !tbaa !9
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 512), align 16, !tbaa !9
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 116), align 4, !tbaa !9
  br label %14

14:                                               ; preds = %26, %13
  %15 = phi i32 [ 29, %13 ], [ %27, %26 ]
  %16 = phi i64 [ 9, %13 ], [ %31, %26 ]
  %17 = getelementptr [4 x i8], ptr @alpha_to, i64 %16
  %18 = icmp slt i32 %15, 128
  br i1 %18, label %24, label %19

19:                                               ; preds = %14
  %20 = load i32, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 32), align 16, !tbaa !9
  %21 = shl nuw i32 %15, 1
  %22 = xor i32 %21, %20
  %23 = xor i32 %22, 256
  br label %26

24:                                               ; preds = %14
  %25 = shl i32 %15, 1
  br label %26

26:                                               ; preds = %24, %19
  %27 = phi i32 [ %23, %19 ], [ %25, %24 ]
  store i32 %27, ptr %17, align 4, !tbaa !9
  %28 = sext i32 %27 to i64
  %29 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %28
  %30 = trunc nuw nsw i64 %16 to i32
  store i32 %30, ptr %29, align 4, !tbaa !9
  %31 = add nuw nsw i64 %16, 1
  %32 = icmp eq i64 %31, 255
  br i1 %32, label %33, label %14, !llvm.loop !10

33:                                               ; preds = %26
  store i32 -1, ptr @index_of, align 16, !tbaa !9
  tail call fastcc void @gen_poly()
  store i1 true, ptr @inited, align 4
  br label %34

34:                                               ; preds = %33, %2
  %35 = getelementptr inbounds nuw i8, ptr %1, i64 188
  %36 = load <4 x i8>, ptr %35, align 1, !tbaa !12
  %37 = zext <4 x i8> %36 to <4 x i32>
  store <4 x i32> %37, ptr @recd, align 16, !tbaa !9
  %38 = getelementptr inbounds nuw i8, ptr %1, i64 192
  %39 = load <4 x i8>, ptr %38, align 1, !tbaa !12
  %40 = zext <4 x i8> %39 to <4 x i32>
  store <4 x i32> %40, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 16), align 16, !tbaa !9
  %41 = getelementptr inbounds nuw i8, ptr %1, i64 196
  %42 = load <4 x i8>, ptr %41, align 1, !tbaa !12
  %43 = zext <4 x i8> %42 to <4 x i32>
  store <4 x i32> %43, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 32), align 16, !tbaa !9
  %44 = getelementptr inbounds nuw i8, ptr %1, i64 200
  %45 = load <4 x i8>, ptr %44, align 1, !tbaa !12
  %46 = zext <4 x i8> %45 to <4 x i32>
  store <4 x i32> %46, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 48), align 16, !tbaa !9
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(204) getelementptr inbounds nuw (i8, ptr @recd, i64 64), i8 0, i64 204, i1 false), !tbaa !9
  br label %47

47:                                               ; preds = %59, %34
  %48 = phi i64 [ 0, %34 ], [ %70, %59 ]
  %49 = getelementptr inbounds nuw i8, ptr %1, i64 %48
  %50 = getelementptr inbounds nuw i8, ptr %49, i64 4
  %51 = load <4 x i8>, ptr %49, align 1, !tbaa !12
  %52 = load <4 x i8>, ptr %50, align 1, !tbaa !12
  %53 = zext <4 x i8> %51 to <4 x i32>
  %54 = zext <4 x i8> %52 to <4 x i32>
  %55 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %48
  %56 = getelementptr inbounds nuw i8, ptr %55, i64 268
  %57 = getelementptr inbounds nuw i8, ptr %55, i64 284
  store <4 x i32> %53, ptr %56, align 4, !tbaa !9
  store <4 x i32> %54, ptr %57, align 4, !tbaa !9
  %58 = icmp eq i64 %48, 176
  br i1 %58, label %71, label %59

59:                                               ; preds = %47
  %60 = or disjoint i64 %48, 8
  %61 = getelementptr inbounds nuw i8, ptr %1, i64 %60
  %62 = getelementptr inbounds nuw i8, ptr %61, i64 4
  %63 = load <4 x i8>, ptr %61, align 1, !tbaa !12
  %64 = load <4 x i8>, ptr %62, align 1, !tbaa !12
  %65 = zext <4 x i8> %63 to <4 x i32>
  %66 = zext <4 x i8> %64 to <4 x i32>
  %67 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %60
  %68 = getelementptr inbounds nuw i8, ptr %67, i64 268
  %69 = getelementptr inbounds nuw i8, ptr %67, i64 284
  store <4 x i32> %65, ptr %68, align 4, !tbaa !9
  store <4 x i32> %66, ptr %69, align 4, !tbaa !9
  %70 = add nuw nsw i64 %48, 16
  br label %47

71:                                               ; preds = %47
  %72 = getelementptr inbounds nuw i8, ptr %1, i64 184
  %73 = load i8, ptr %72, align 1, !tbaa !12
  %74 = zext i8 %73 to i32
  store i32 %74, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1004), align 4, !tbaa !9
  %75 = getelementptr inbounds nuw i8, ptr %1, i64 185
  %76 = load i8, ptr %75, align 1, !tbaa !12
  %77 = zext i8 %76 to i32
  store i32 %77, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1008), align 16, !tbaa !9
  %78 = getelementptr inbounds nuw i8, ptr %1, i64 186
  %79 = load i8, ptr %78, align 1, !tbaa !12
  %80 = zext i8 %79 to i32
  store i32 %80, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1012), align 4, !tbaa !9
  %81 = getelementptr inbounds nuw i8, ptr %1, i64 187
  %82 = load i8, ptr %81, align 1, !tbaa !12
  %83 = zext i8 %82 to i32
  store i32 %83, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1016), align 8, !tbaa !9
  br label %84

84:                                               ; preds = %84, %71
  %85 = phi i64 [ 0, %71 ], [ %103, %84 ]
  %86 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %85
  %87 = load i32, ptr %86, align 4, !tbaa !9
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %88
  %90 = load i32, ptr %89, align 4, !tbaa !9
  store i32 %90, ptr %86, align 4, !tbaa !9
  %91 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %85
  %92 = getelementptr inbounds nuw i8, ptr %91, i64 4
  %93 = load i32, ptr %92, align 4, !tbaa !9
  %94 = sext i32 %93 to i64
  %95 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %94
  %96 = load i32, ptr %95, align 4, !tbaa !9
  store i32 %96, ptr %92, align 4, !tbaa !9
  %97 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %85
  %98 = getelementptr inbounds nuw i8, ptr %97, i64 8
  %99 = load i32, ptr %98, align 4, !tbaa !9
  %100 = sext i32 %99 to i64
  %101 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %100
  %102 = load i32, ptr %101, align 4, !tbaa !9
  store i32 %102, ptr %98, align 4, !tbaa !9
  %103 = add nuw nsw i64 %85, 3
  %104 = icmp eq i64 %103, 255
  br i1 %104, label %105, label %84, !llvm.loop !13

105:                                              ; preds = %84
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %5) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %6) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %7) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %8) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %9) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %10) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %11) #9
  br label %106

106:                                              ; preds = %129, %105
  %107 = phi i64 [ 1, %105 ], [ %135, %129 ]
  %108 = phi i32 [ 0, %105 ], [ %131, %129 ]
  %109 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %107
  br label %110

110:                                              ; preds = %125, %106
  %111 = phi i32 [ 0, %106 ], [ %126, %125 ]
  %112 = phi i64 [ 0, %106 ], [ %127, %125 ]
  %113 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %112
  %114 = load i32, ptr %113, align 4, !tbaa !9
  %115 = icmp eq i32 %114, -1
  br i1 %115, label %125, label %116

116:                                              ; preds = %110
  %117 = mul nuw nsw i64 %112, %107
  %118 = trunc nuw nsw i64 %117 to i32
  %119 = add nsw i32 %114, %118
  %120 = srem i32 %119, 255
  %121 = sext i32 %120 to i64
  %122 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %121
  %123 = load i32, ptr %122, align 4, !tbaa !9
  %124 = xor i32 %123, %111
  store i32 %124, ptr %109, align 4, !tbaa !9
  br label %125

125:                                              ; preds = %116, %110
  %126 = phi i32 [ %111, %110 ], [ %124, %116 ]
  %127 = add nuw nsw i64 %112, 1
  %128 = icmp eq i64 %127, 255
  br i1 %128, label %129, label %110, !llvm.loop !14

129:                                              ; preds = %125
  %130 = icmp eq i32 %126, 0
  %131 = select i1 %130, i32 %108, i32 1
  %132 = sext i32 %126 to i64
  %133 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %132
  %134 = load i32, ptr %133, align 4, !tbaa !9
  store i32 %134, ptr %109, align 4, !tbaa !9
  %135 = add nuw nsw i64 %107, 1
  %136 = icmp eq i64 %135, 17
  br i1 %136, label %137, label %106, !llvm.loop !15

137:                                              ; preds = %129
  %138 = icmp eq i32 %131, 0
  br i1 %138, label %689, label %139

139:                                              ; preds = %137
  store i32 0, ptr %4, align 16, !tbaa !9
  %140 = getelementptr inbounds nuw i8, ptr %7, i64 4
  %141 = load i32, ptr %140, align 4, !tbaa !9
  %142 = getelementptr inbounds nuw i8, ptr %4, i64 4
  store i32 %141, ptr %142, align 4, !tbaa !9
  store i32 0, ptr %3, align 16, !tbaa !9
  %143 = getelementptr inbounds nuw i8, ptr %3, i64 64
  store i32 1, ptr %143, align 16, !tbaa !9
  %144 = getelementptr inbounds nuw i8, ptr %3, i64 4
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(60) %144, i8 -1, i64 60, i1 false), !tbaa !9
  %145 = getelementptr inbounds nuw i8, ptr %3, i64 68
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 4 dereferenceable(60) %145, i8 0, i64 60, i1 false), !tbaa !9
  store i32 0, ptr %5, align 16, !tbaa !9
  %146 = getelementptr inbounds nuw i8, ptr %5, i64 4
  store i32 0, ptr %146, align 4, !tbaa !9
  store i32 -1, ptr %6, align 16, !tbaa !9
  %147 = getelementptr inbounds nuw i8, ptr %6, i64 4
  store i32 0, ptr %147, align 4, !tbaa !9
  br label %148

148:                                              ; preds = %372, %139
  %149 = phi i32 [ %376, %372 ], [ %141, %139 ]
  %150 = phi i64 [ %154, %372 ], [ 0, %139 ]
  %151 = shl nuw nsw i64 %150, 6
  %152 = getelementptr nuw i8, ptr %3, i64 %151
  %153 = getelementptr nuw i8, ptr %152, i64 128
  %154 = add nuw nsw i64 %150, 1
  %155 = icmp eq i32 %149, -1
  br i1 %155, label %156, label %190

156:                                              ; preds = %148
  %157 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %154
  %158 = load i32, ptr %157, align 4, !tbaa !9
  %159 = add nuw nsw i64 %150, 2
  %160 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %159
  store i32 %158, ptr %160, align 4, !tbaa !9
  %161 = icmp slt i32 %158, 0
  br i1 %161, label %324, label %162

162:                                              ; preds = %156
  %163 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %154
  %164 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %159
  %165 = add nuw i32 %158, 1
  %166 = zext i32 %165 to i64
  %167 = and i64 %166, 1
  %168 = icmp eq i32 %158, 0
  br i1 %168, label %302, label %169

169:                                              ; preds = %162
  %170 = and i64 %166, 4294967294
  br label %171

171:                                              ; preds = %171, %169
  %172 = phi i64 [ 0, %169 ], [ %187, %171 ]
  %173 = phi i64 [ 0, %169 ], [ %188, %171 ]
  %174 = getelementptr inbounds nuw [4 x i8], ptr %163, i64 %172
  %175 = load i32, ptr %174, align 8, !tbaa !9
  %176 = getelementptr inbounds nuw [4 x i8], ptr %164, i64 %172
  store i32 %175, ptr %176, align 8, !tbaa !9
  %177 = sext i32 %175 to i64
  %178 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %177
  %179 = load i32, ptr %178, align 4, !tbaa !9
  store i32 %179, ptr %174, align 8, !tbaa !9
  %180 = or disjoint i64 %172, 1
  %181 = getelementptr inbounds nuw [4 x i8], ptr %163, i64 %180
  %182 = load i32, ptr %181, align 4, !tbaa !9
  %183 = getelementptr inbounds nuw [4 x i8], ptr %164, i64 %180
  store i32 %182, ptr %183, align 4, !tbaa !9
  %184 = sext i32 %182 to i64
  %185 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %184
  %186 = load i32, ptr %185, align 4, !tbaa !9
  store i32 %186, ptr %181, align 4, !tbaa !9
  %187 = add nuw nsw i64 %172, 2
  %188 = add i64 %173, 2
  %189 = icmp eq i64 %188, %170
  br i1 %189, label %300, label %171, !llvm.loop !16

190:                                              ; preds = %148, %190
  %191 = phi i64 [ %197, %190 ], [ %150, %148 ]
  %192 = getelementptr inbounds [4 x i8], ptr %4, i64 %191
  %193 = load i32, ptr %192, align 4, !tbaa !9
  %194 = icmp eq i32 %193, -1
  %195 = icmp sgt i64 %191, 0
  %196 = and i1 %195, %194
  %197 = add nsw i64 %191, -1
  br i1 %196, label %190, label %198, !llvm.loop !17

198:                                              ; preds = %190
  br i1 %195, label %199, label %222

199:                                              ; preds = %198
  %200 = trunc i64 %191 to i32
  %201 = and i64 %191, 4294967295
  br label %202

202:                                              ; preds = %219, %199
  %203 = phi i64 [ %201, %199 ], [ %205, %219 ]
  %204 = phi i32 [ %200, %199 ], [ %220, %219 ]
  %205 = add nsw i64 %203, -1
  %206 = and i64 %205, 4294967295
  %207 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %206
  %208 = load i32, ptr %207, align 4, !tbaa !9
  %209 = icmp eq i32 %208, -1
  br i1 %209, label %219, label %210

210:                                              ; preds = %202
  %211 = trunc i64 %205 to i32
  %212 = zext nneg i32 %204 to i64
  %213 = getelementptr inbounds nuw [4 x i8], ptr %6, i64 %212
  %214 = load i32, ptr %213, align 4, !tbaa !9
  %215 = getelementptr inbounds nuw [4 x i8], ptr %6, i64 %206
  %216 = load i32, ptr %215, align 4, !tbaa !9
  %217 = icmp slt i32 %214, %216
  %218 = select i1 %217, i32 %211, i32 %204
  br label %219

219:                                              ; preds = %210, %202
  %220 = phi i32 [ %204, %202 ], [ %218, %210 ]
  %221 = icmp samesign ugt i64 %203, 1
  br i1 %221, label %202, label %222, !llvm.loop !18

222:                                              ; preds = %219, %198
  %223 = phi i32 [ 0, %198 ], [ %220, %219 ]
  %224 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %154
  %225 = load i32, ptr %224, align 4, !tbaa !9
  %226 = sext i32 %223 to i64
  %227 = getelementptr inbounds [4 x i8], ptr %5, i64 %226
  %228 = load i32, ptr %227, align 4, !tbaa !9
  %229 = trunc nuw nsw i64 %154 to i32
  %230 = sub i32 %229, %223
  %231 = add i32 %228, %230
  %232 = getelementptr inbounds nuw [4 x i8], ptr %5, i64 %150
  %233 = getelementptr inbounds nuw i8, ptr %232, i64 8
  %234 = tail call i32 @llvm.smax.i32(i32 %225, i32 %231)
  store i32 %234, ptr %233, align 4, !tbaa !9
  call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(64) %153, i8 0, i64 64, i1 false), !tbaa !9
  %235 = load i32, ptr %227, align 4, !tbaa !9
  %236 = icmp slt i32 %235, 0
  br i1 %236, label %245, label %237

237:                                              ; preds = %222
  %238 = getelementptr inbounds [64 x i8], ptr %3, i64 %226
  %239 = add nsw i32 %149, 255
  %240 = getelementptr inbounds [4 x i8], ptr %4, i64 %226
  %241 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %150
  %242 = getelementptr inbounds nuw i8, ptr %241, i64 128
  %243 = add nuw i32 %235, 1
  %244 = zext i32 %243 to i64
  br label %257

245:                                              ; preds = %274, %222
  %246 = icmp slt i32 %225, 0
  br i1 %246, label %324, label %247

247:                                              ; preds = %245
  %248 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %154
  %249 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %150
  %250 = getelementptr inbounds nuw i8, ptr %249, i64 128
  %251 = add nuw i32 %225, 1
  %252 = zext i32 %251 to i64
  %253 = and i64 %252, 1
  %254 = icmp eq i32 %225, 0
  br i1 %254, label %313, label %255

255:                                              ; preds = %247
  %256 = and i64 %252, 4294967294
  br label %277

257:                                              ; preds = %274, %237
  %258 = phi i64 [ 0, %237 ], [ %275, %274 ]
  %259 = getelementptr inbounds nuw [4 x i8], ptr %238, i64 %258
  %260 = load i32, ptr %259, align 4, !tbaa !9
  %261 = icmp eq i32 %260, -1
  br i1 %261, label %274, label %262

262:                                              ; preds = %257
  %263 = load i32, ptr %240, align 4, !tbaa !9
  %264 = add i32 %239, %260
  %265 = sub i32 %264, %263
  %266 = srem i32 %265, 255
  %267 = sext i32 %266 to i64
  %268 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %267
  %269 = load i32, ptr %268, align 4, !tbaa !9
  %270 = trunc nuw nsw i64 %258 to i32
  %271 = add i32 %230, %270
  %272 = sext i32 %271 to i64
  %273 = getelementptr inbounds [4 x i8], ptr %242, i64 %272
  store i32 %269, ptr %273, align 4, !tbaa !9
  br label %274

274:                                              ; preds = %262, %257
  %275 = add nuw nsw i64 %258, 1
  %276 = icmp eq i64 %275, %244
  br i1 %276, label %245, label %257, !llvm.loop !19

277:                                              ; preds = %277, %255
  %278 = phi i64 [ 0, %255 ], [ %297, %277 ]
  %279 = phi i64 [ 0, %255 ], [ %298, %277 ]
  %280 = getelementptr inbounds nuw [4 x i8], ptr %248, i64 %278
  %281 = load i32, ptr %280, align 8, !tbaa !9
  %282 = getelementptr inbounds nuw [4 x i8], ptr %250, i64 %278
  %283 = load i32, ptr %282, align 8, !tbaa !9
  %284 = xor i32 %283, %281
  store i32 %284, ptr %282, align 8, !tbaa !9
  %285 = sext i32 %281 to i64
  %286 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %285
  %287 = load i32, ptr %286, align 4, !tbaa !9
  store i32 %287, ptr %280, align 8, !tbaa !9
  %288 = or disjoint i64 %278, 1
  %289 = getelementptr inbounds nuw [4 x i8], ptr %248, i64 %288
  %290 = load i32, ptr %289, align 4, !tbaa !9
  %291 = getelementptr inbounds nuw [4 x i8], ptr %250, i64 %288
  %292 = load i32, ptr %291, align 4, !tbaa !9
  %293 = xor i32 %292, %290
  store i32 %293, ptr %291, align 4, !tbaa !9
  %294 = sext i32 %290 to i64
  %295 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %294
  %296 = load i32, ptr %295, align 4, !tbaa !9
  store i32 %296, ptr %289, align 4, !tbaa !9
  %297 = add nuw nsw i64 %278, 2
  %298 = add i64 %279, 2
  %299 = icmp eq i64 %298, %256
  br i1 %299, label %311, label %277, !llvm.loop !20

300:                                              ; preds = %171
  %301 = icmp eq i64 %167, 0
  br i1 %301, label %324, label %302

302:                                              ; preds = %300, %162
  %303 = phi i64 [ 0, %162 ], [ %187, %300 ]
  %304 = trunc i32 %165 to i1
  tail call void @llvm.assume(i1 %304)
  %305 = getelementptr inbounds nuw [4 x i8], ptr %163, i64 %303
  %306 = load i32, ptr %305, align 4, !tbaa !9
  %307 = getelementptr inbounds nuw [4 x i8], ptr %164, i64 %303
  store i32 %306, ptr %307, align 4, !tbaa !9
  %308 = sext i32 %306 to i64
  %309 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %308
  %310 = load i32, ptr %309, align 4, !tbaa !9
  store i32 %310, ptr %305, align 4, !tbaa !9
  br label %324

311:                                              ; preds = %277
  %312 = icmp eq i64 %253, 0
  br i1 %312, label %324, label %313

313:                                              ; preds = %311, %247
  %314 = phi i64 [ 0, %247 ], [ %297, %311 ]
  %315 = trunc i32 %251 to i1
  tail call void @llvm.assume(i1 %315)
  %316 = getelementptr inbounds nuw [4 x i8], ptr %248, i64 %314
  %317 = load i32, ptr %316, align 4, !tbaa !9
  %318 = getelementptr inbounds nuw [4 x i8], ptr %250, i64 %314
  %319 = load i32, ptr %318, align 4, !tbaa !9
  %320 = xor i32 %319, %317
  store i32 %320, ptr %318, align 4, !tbaa !9
  %321 = sext i32 %317 to i64
  %322 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %321
  %323 = load i32, ptr %322, align 4, !tbaa !9
  store i32 %323, ptr %316, align 4, !tbaa !9
  br label %324

324:                                              ; preds = %313, %311, %302, %300, %245, %156
  %325 = phi i32 [ %158, %302 ], [ %158, %156 ], [ %234, %245 ], [ %158, %300 ], [ %234, %311 ], [ %234, %313 ]
  %326 = add nuw nsw i64 %150, 2
  %327 = trunc nuw nsw i64 %154 to i32
  %328 = sub nsw i32 %327, %325
  %329 = getelementptr inbounds nuw [4 x i8], ptr %6, i64 %326
  store i32 %328, ptr %329, align 4, !tbaa !9
  %330 = icmp eq i64 %150, 15
  br i1 %330, label %378, label %331

331:                                              ; preds = %324
  %332 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %326
  %333 = load i32, ptr %332, align 4, !tbaa !9
  %334 = icmp eq i32 %333, -1
  br i1 %334, label %339, label %335

335:                                              ; preds = %331
  %336 = sext i32 %333 to i64
  %337 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %336
  %338 = load i32, ptr %337, align 4, !tbaa !9
  br label %339

339:                                              ; preds = %335, %331
  %340 = phi i32 [ %338, %335 ], [ 0, %331 ]
  %341 = getelementptr inbounds nuw [4 x i8], ptr %4, i64 %326
  %342 = icmp slt i32 %325, 1
  br i1 %342, label %372, label %343

343:                                              ; preds = %339
  %344 = getelementptr inbounds nuw [64 x i8], ptr %3, i64 %326
  %345 = add nuw i32 %325, 1
  %346 = zext i32 %345 to i64
  br label %347

347:                                              ; preds = %368, %343
  %348 = phi i32 [ %340, %343 ], [ %369, %368 ]
  %349 = phi i64 [ 1, %343 ], [ %370, %368 ]
  %350 = sub nsw i64 %326, %349
  %351 = getelementptr inbounds [4 x i8], ptr %7, i64 %350
  %352 = load i32, ptr %351, align 4, !tbaa !9
  %353 = icmp eq i32 %352, -1
  br i1 %353, label %368, label %354

354:                                              ; preds = %347
  %355 = getelementptr inbounds nuw [4 x i8], ptr %344, i64 %349
  %356 = load i32, ptr %355, align 4, !tbaa !9
  %357 = icmp eq i32 %356, 0
  br i1 %357, label %368, label %358

358:                                              ; preds = %354
  %359 = sext i32 %356 to i64
  %360 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %359
  %361 = load i32, ptr %360, align 4, !tbaa !9
  %362 = add nsw i32 %361, %352
  %363 = srem i32 %362, 255
  %364 = sext i32 %363 to i64
  %365 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %364
  %366 = load i32, ptr %365, align 4, !tbaa !9
  %367 = xor i32 %366, %348
  store i32 %367, ptr %341, align 4, !tbaa !9
  br label %368

368:                                              ; preds = %358, %354, %347
  %369 = phi i32 [ %348, %347 ], [ %348, %354 ], [ %367, %358 ]
  %370 = add nuw nsw i64 %349, 1
  %371 = icmp eq i64 %370, %346
  br i1 %371, label %372, label %347, !llvm.loop !21

372:                                              ; preds = %368, %339
  %373 = phi i32 [ %340, %339 ], [ %369, %368 ]
  %374 = sext i32 %373 to i64
  %375 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %374
  %376 = load i32, ptr %375, align 4, !tbaa !9
  store i32 %376, ptr %341, align 4, !tbaa !9
  %377 = icmp slt i32 %325, 9
  br i1 %377, label %148, label %380, !llvm.loop !22

378:                                              ; preds = %324
  %379 = icmp slt i32 %325, 9
  br i1 %379, label %381, label %380

380:                                              ; preds = %372, %378
  br label %665

381:                                              ; preds = %378
  %382 = icmp slt i32 %325, 0
  br i1 %382, label %383, label %386

383:                                              ; preds = %381
  %384 = add nsw i32 %325, 1
  %385 = zext nneg i32 %384 to i64
  br label %446

386:                                              ; preds = %381
  %387 = getelementptr inbounds nuw i8, ptr %3, i64 1088
  %388 = add nuw nsw i32 %325, 1
  %389 = zext nneg i32 %388 to i64
  %390 = and i64 %389, 3
  %391 = icmp ult i32 %325, 3
  br i1 %391, label %396, label %392

392:                                              ; preds = %386
  %393 = and i64 %389, 2147483644
  br label %417

394:                                              ; preds = %417
  %395 = icmp eq i64 %390, 0
  br i1 %395, label %410, label %396

396:                                              ; preds = %394, %386
  %397 = phi i64 [ 0, %386 ], [ %443, %394 ]
  %398 = icmp ne i64 %390, 0
  tail call void @llvm.assume(i1 %398)
  br label %399

399:                                              ; preds = %399, %396
  %400 = phi i64 [ %397, %396 ], [ %407, %399 ]
  %401 = phi i64 [ 0, %396 ], [ %408, %399 ]
  %402 = getelementptr inbounds nuw [4 x i8], ptr %387, i64 %400
  %403 = load i32, ptr %402, align 4, !tbaa !9
  %404 = sext i32 %403 to i64
  %405 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %404
  %406 = load i32, ptr %405, align 4, !tbaa !9
  store i32 %406, ptr %402, align 4, !tbaa !9
  %407 = add nuw nsw i64 %400, 1
  %408 = add i64 %401, 1
  %409 = icmp eq i64 %408, %390
  br i1 %409, label %410, label %399, !llvm.loop !23

410:                                              ; preds = %399, %394
  %411 = icmp eq i32 %325, 0
  br i1 %411, label %446, label %412

412:                                              ; preds = %410
  %413 = getelementptr inbounds nuw i8, ptr %11, i64 4
  %414 = getelementptr inbounds nuw i8, ptr %3, i64 1092
  %415 = zext nneg i32 %325 to i64
  %416 = shl nuw nsw i64 %415, 2
  call void @llvm.memcpy.p0.p0.i64(ptr nonnull align 4 %413, ptr nonnull align 4 %414, i64 %416, i1 false), !tbaa !9
  br label %446

417:                                              ; preds = %417, %392
  %418 = phi i64 [ 0, %392 ], [ %443, %417 ]
  %419 = phi i64 [ 0, %392 ], [ %444, %417 ]
  %420 = getelementptr inbounds nuw [4 x i8], ptr %387, i64 %418
  %421 = load i32, ptr %420, align 16, !tbaa !9
  %422 = sext i32 %421 to i64
  %423 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %422
  %424 = load i32, ptr %423, align 4, !tbaa !9
  store i32 %424, ptr %420, align 16, !tbaa !9
  %425 = getelementptr inbounds nuw [4 x i8], ptr %387, i64 %418
  %426 = getelementptr inbounds nuw i8, ptr %425, i64 4
  %427 = load i32, ptr %426, align 4, !tbaa !9
  %428 = sext i32 %427 to i64
  %429 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %428
  %430 = load i32, ptr %429, align 4, !tbaa !9
  store i32 %430, ptr %426, align 4, !tbaa !9
  %431 = getelementptr inbounds nuw [4 x i8], ptr %387, i64 %418
  %432 = getelementptr inbounds nuw i8, ptr %431, i64 8
  %433 = load i32, ptr %432, align 8, !tbaa !9
  %434 = sext i32 %433 to i64
  %435 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %434
  %436 = load i32, ptr %435, align 4, !tbaa !9
  store i32 %436, ptr %432, align 8, !tbaa !9
  %437 = getelementptr inbounds nuw [4 x i8], ptr %387, i64 %418
  %438 = getelementptr inbounds nuw i8, ptr %437, i64 12
  %439 = load i32, ptr %438, align 4, !tbaa !9
  %440 = sext i32 %439 to i64
  %441 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %440
  %442 = load i32, ptr %441, align 4, !tbaa !9
  store i32 %442, ptr %438, align 4, !tbaa !9
  %443 = add nuw nsw i64 %418, 4
  %444 = add i64 %419, 4
  %445 = icmp eq i64 %444, %393
  br i1 %445, label %394, label %417, !llvm.loop !25

446:                                              ; preds = %383, %412, %410
  %447 = phi i64 [ %385, %383 ], [ %389, %412 ], [ 1, %410 ]
  %448 = phi i1 [ true, %383 ], [ false, %412 ], [ true, %410 ]
  br label %449

449:                                              ; preds = %478, %446
  %450 = phi i32 [ 0, %446 ], [ %479, %478 ]
  %451 = phi i32 [ 1, %446 ], [ %480, %478 ]
  br i1 %448, label %478, label %452

452:                                              ; preds = %449, %466
  %453 = phi i64 [ %468, %466 ], [ 1, %449 ]
  %454 = phi i32 [ %467, %466 ], [ 1, %449 ]
  %455 = getelementptr inbounds nuw [4 x i8], ptr %11, i64 %453
  %456 = load i32, ptr %455, align 4, !tbaa !9
  %457 = icmp eq i32 %456, -1
  br i1 %457, label %466, label %458

458:                                              ; preds = %452
  %459 = trunc nuw nsw i64 %453 to i32
  %460 = add nsw i32 %456, %459
  %461 = srem i32 %460, 255
  store i32 %461, ptr %455, align 4, !tbaa !9
  %462 = sext i32 %461 to i64
  %463 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %462
  %464 = load i32, ptr %463, align 4, !tbaa !9
  %465 = xor i32 %464, %454
  br label %466

466:                                              ; preds = %458, %452
  %467 = phi i32 [ %465, %458 ], [ %454, %452 ]
  %468 = add nuw nsw i64 %453, 1
  %469 = icmp eq i64 %468, %447
  br i1 %469, label %470, label %452, !llvm.loop !26

470:                                              ; preds = %466
  %471 = icmp eq i32 %467, 0
  br i1 %471, label %472, label %478

472:                                              ; preds = %470
  %473 = sext i32 %450 to i64
  %474 = getelementptr inbounds [4 x i8], ptr %8, i64 %473
  store i32 %451, ptr %474, align 4, !tbaa !9
  %475 = sub nuw nsw i32 255, %451
  %476 = getelementptr inbounds [4 x i8], ptr %9, i64 %473
  store i32 %475, ptr %476, align 4, !tbaa !9
  %477 = add nsw i32 %450, 1
  br label %478

478:                                              ; preds = %472, %470, %449
  %479 = phi i32 [ %450, %470 ], [ %477, %472 ], [ %450, %449 ]
  %480 = add nuw nsw i32 %451, 1
  %481 = icmp eq i32 %480, 256
  br i1 %481, label %482, label %449, !llvm.loop !27

482:                                              ; preds = %478
  %483 = icmp eq i32 %479, %325
  br i1 %483, label %484, label %641

484:                                              ; preds = %482
  br i1 %448, label %485, label %486

485:                                              ; preds = %537, %484
  br label %549

486:                                              ; preds = %484
  %487 = getelementptr inbounds nuw i8, ptr %3, i64 1088
  br label %488

488:                                              ; preds = %537, %486
  %489 = phi i64 [ 1, %486 ], [ %543, %537 ]
  %490 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %489
  %491 = load i32, ptr %490, align 4, !tbaa !9
  %492 = icmp eq i32 %491, -1
  %493 = getelementptr inbounds nuw [4 x i8], ptr %487, i64 %489
  %494 = load i32, ptr %493, align 4, !tbaa !9
  %495 = icmp eq i32 %494, -1
  br i1 %492, label %505, label %496

496:                                              ; preds = %488
  %497 = sext i32 %491 to i64
  %498 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %497
  %499 = load i32, ptr %498, align 4, !tbaa !9
  br i1 %495, label %510, label %500

500:                                              ; preds = %496
  %501 = sext i32 %494 to i64
  %502 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %501
  %503 = load i32, ptr %502, align 4, !tbaa !9
  %504 = xor i32 %503, %499
  br label %510

505:                                              ; preds = %488
  br i1 %495, label %510, label %506

506:                                              ; preds = %505
  %507 = sext i32 %494 to i64
  %508 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %507
  %509 = load i32, ptr %508, align 4, !tbaa !9
  br label %510

510:                                              ; preds = %506, %505, %500, %496
  %511 = phi i32 [ %504, %500 ], [ %499, %496 ], [ %509, %506 ], [ 0, %505 ]
  %512 = icmp samesign ugt i64 %489, 1
  br i1 %512, label %513, label %537

513:                                              ; preds = %510
  %514 = getelementptr inbounds nuw [4 x i8], ptr %10, i64 %489
  br label %515

515:                                              ; preds = %533, %513
  %516 = phi i32 [ %511, %513 ], [ %534, %533 ]
  %517 = phi i64 [ 1, %513 ], [ %535, %533 ]
  %518 = getelementptr inbounds nuw [4 x i8], ptr %7, i64 %517
  %519 = load i32, ptr %518, align 4, !tbaa !9
  %520 = icmp eq i32 %519, -1
  br i1 %520, label %533, label %521

521:                                              ; preds = %515
  %522 = sub nsw i64 %489, %517
  %523 = getelementptr inbounds [4 x i8], ptr %487, i64 %522
  %524 = load i32, ptr %523, align 4, !tbaa !9
  %525 = icmp eq i32 %524, -1
  br i1 %525, label %533, label %526

526:                                              ; preds = %521
  %527 = add nsw i32 %524, %519
  %528 = srem i32 %527, 255
  %529 = sext i32 %528 to i64
  %530 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %529
  %531 = load i32, ptr %530, align 4, !tbaa !9
  %532 = xor i32 %531, %516
  store i32 %532, ptr %514, align 4, !tbaa !9
  br label %533

533:                                              ; preds = %526, %521, %515
  %534 = phi i32 [ %516, %515 ], [ %516, %521 ], [ %532, %526 ]
  %535 = add nuw nsw i64 %517, 1
  %536 = icmp eq i64 %535, %489
  br i1 %536, label %537, label %515, !llvm.loop !28

537:                                              ; preds = %533, %510
  %538 = phi i32 [ %511, %510 ], [ %534, %533 ]
  %539 = getelementptr inbounds nuw [4 x i8], ptr %10, i64 %489
  %540 = sext i32 %538 to i64
  %541 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %540
  %542 = load i32, ptr %541, align 4, !tbaa !9
  store i32 %542, ptr %539, align 4, !tbaa !9
  %543 = add nuw nsw i64 %489, 1
  %544 = icmp eq i64 %543, %447
  br i1 %544, label %485, label %488, !llvm.loop !29

545:                                              ; preds = %558
  %546 = icmp sgt i32 %325, 0
  br i1 %546, label %547, label %713

547:                                              ; preds = %545
  %548 = zext nneg i32 %325 to i64
  br label %573

549:                                              ; preds = %570, %485
  %550 = phi i64 [ 0, %485 ], [ %572, %570 ]
  %551 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %550
  %552 = load i32, ptr %551, align 8, !tbaa !9
  %553 = icmp eq i32 %552, -1
  br i1 %553, label %558, label %554

554:                                              ; preds = %549
  %555 = sext i32 %552 to i64
  %556 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %555
  %557 = load i32, ptr %556, align 4, !tbaa !9
  br label %558

558:                                              ; preds = %554, %549
  %559 = phi i32 [ %557, %554 ], [ 0, %549 ]
  store i32 %559, ptr %551, align 8, !tbaa !9
  %560 = icmp eq i64 %550, 254
  br i1 %560, label %545, label %561

561:                                              ; preds = %558
  %562 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %550
  %563 = getelementptr inbounds nuw i8, ptr %562, i64 4
  %564 = load i32, ptr %563, align 4, !tbaa !9
  %565 = icmp eq i32 %564, -1
  br i1 %565, label %570, label %566

566:                                              ; preds = %561
  %567 = sext i32 %564 to i64
  %568 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %567
  %569 = load i32, ptr %568, align 4, !tbaa !9
  br label %570

570:                                              ; preds = %566, %561
  %571 = phi i32 [ %569, %566 ], [ 0, %561 ]
  store i32 %571, ptr %563, align 4, !tbaa !9
  %572 = add nuw nsw i64 %550, 2
  br label %549

573:                                              ; preds = %638, %547
  %574 = phi i64 [ 0, %547 ], [ %639, %638 ]
  %575 = getelementptr inbounds nuw [4 x i8], ptr %9, i64 %574
  %576 = load i32, ptr %575, align 4, !tbaa !9
  %577 = getelementptr inbounds nuw [4 x i8], ptr %8, i64 %574
  br label %578

578:                                              ; preds = %594, %573
  %579 = phi i32 [ 1, %573 ], [ %595, %594 ]
  %580 = phi i64 [ 1, %573 ], [ %596, %594 ]
  %581 = getelementptr inbounds nuw [4 x i8], ptr %10, i64 %580
  %582 = load i32, ptr %581, align 4, !tbaa !9
  %583 = icmp eq i32 %582, -1
  br i1 %583, label %594, label %584

584:                                              ; preds = %578
  %585 = load i32, ptr %577, align 4, !tbaa !9
  %586 = trunc nuw nsw i64 %580 to i32
  %587 = mul nsw i32 %585, %586
  %588 = add nsw i32 %587, %582
  %589 = srem i32 %588, 255
  %590 = sext i32 %589 to i64
  %591 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %590
  %592 = load i32, ptr %591, align 4, !tbaa !9
  %593 = xor i32 %592, %579
  br label %594

594:                                              ; preds = %584, %578
  %595 = phi i32 [ %579, %578 ], [ %593, %584 ]
  %596 = add nuw nsw i64 %580, 1
  %597 = icmp eq i64 %596, %447
  br i1 %597, label %598, label %578, !llvm.loop !30

598:                                              ; preds = %594
  %599 = sext i32 %576 to i64
  %600 = icmp eq i32 %595, 0
  br i1 %600, label %638, label %601

601:                                              ; preds = %598
  %602 = sext i32 %595 to i64
  %603 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %602
  %604 = load i32, ptr %603, align 4, !tbaa !9
  br label %605

605:                                              ; preds = %623, %601
  %606 = phi i64 [ 0, %601 ], [ %625, %623 ]
  %607 = phi i32 [ 0, %601 ], [ %624, %623 ]
  %608 = icmp eq i64 %606, %574
  br i1 %608, label %623, label %609

609:                                              ; preds = %605
  %610 = getelementptr inbounds nuw [4 x i8], ptr %9, i64 %606
  %611 = load i32, ptr %610, align 4, !tbaa !9
  %612 = load i32, ptr %577, align 4, !tbaa !9
  %613 = add nsw i32 %612, %611
  %614 = srem i32 %613, 255
  %615 = sext i32 %614 to i64
  %616 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %615
  %617 = load i32, ptr %616, align 4, !tbaa !9
  %618 = xor i32 %617, 1
  %619 = sext i32 %618 to i64
  %620 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %619
  %621 = load i32, ptr %620, align 4, !tbaa !9
  %622 = add nsw i32 %621, %607
  br label %623

623:                                              ; preds = %609, %605
  %624 = phi i32 [ %622, %609 ], [ %607, %605 ]
  %625 = add nuw nsw i64 %606, 1
  %626 = icmp eq i64 %625, %548
  br i1 %626, label %627, label %605, !llvm.loop !31

627:                                              ; preds = %623
  %628 = srem i32 %624, 255
  %629 = add i32 %604, 255
  %630 = sub i32 %629, %628
  %631 = srem i32 %630, 255
  %632 = sext i32 %631 to i64
  %633 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %632
  %634 = load i32, ptr %633, align 4, !tbaa !9
  %635 = getelementptr inbounds [4 x i8], ptr @recd, i64 %599
  %636 = load i32, ptr %635, align 4, !tbaa !9
  %637 = xor i32 %636, %634
  store i32 %637, ptr %635, align 4, !tbaa !9
  br label %638

638:                                              ; preds = %627, %598
  %639 = add nuw nsw i64 %574, 1
  %640 = icmp eq i64 %639, %548
  br i1 %640, label %713, label %573, !llvm.loop !32

641:                                              ; preds = %482, %662
  %642 = phi i64 [ %664, %662 ], [ 0, %482 ]
  %643 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %642
  %644 = load i32, ptr %643, align 8, !tbaa !9
  %645 = icmp eq i32 %644, -1
  br i1 %645, label %650, label %646

646:                                              ; preds = %641
  %647 = sext i32 %644 to i64
  %648 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %647
  %649 = load i32, ptr %648, align 4, !tbaa !9
  br label %650

650:                                              ; preds = %646, %641
  %651 = phi i32 [ %649, %646 ], [ 0, %641 ]
  store i32 %651, ptr %643, align 8, !tbaa !9
  %652 = icmp eq i64 %642, 254
  br i1 %652, label %713, label %653

653:                                              ; preds = %650
  %654 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %642
  %655 = getelementptr inbounds nuw i8, ptr %654, i64 4
  %656 = load i32, ptr %655, align 4, !tbaa !9
  %657 = icmp eq i32 %656, -1
  br i1 %657, label %662, label %658

658:                                              ; preds = %653
  %659 = sext i32 %656 to i64
  %660 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %659
  %661 = load i32, ptr %660, align 4, !tbaa !9
  br label %662

662:                                              ; preds = %658, %653
  %663 = phi i32 [ %661, %658 ], [ 0, %653 ]
  store i32 %663, ptr %655, align 4, !tbaa !9
  %664 = add nuw nsw i64 %642, 2
  br label %641

665:                                              ; preds = %686, %380
  %666 = phi i64 [ 0, %380 ], [ %688, %686 ]
  %667 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %666
  %668 = load i32, ptr %667, align 8, !tbaa !9
  %669 = icmp eq i32 %668, -1
  br i1 %669, label %674, label %670

670:                                              ; preds = %665
  %671 = sext i32 %668 to i64
  %672 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %671
  %673 = load i32, ptr %672, align 4, !tbaa !9
  br label %674

674:                                              ; preds = %670, %665
  %675 = phi i32 [ %673, %670 ], [ 0, %665 ]
  store i32 %675, ptr %667, align 8, !tbaa !9
  %676 = icmp eq i64 %666, 254
  br i1 %676, label %713, label %677

677:                                              ; preds = %674
  %678 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %666
  %679 = getelementptr inbounds nuw i8, ptr %678, i64 4
  %680 = load i32, ptr %679, align 4, !tbaa !9
  %681 = icmp eq i32 %680, -1
  br i1 %681, label %686, label %682

682:                                              ; preds = %677
  %683 = sext i32 %680 to i64
  %684 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %683
  %685 = load i32, ptr %684, align 4, !tbaa !9
  br label %686

686:                                              ; preds = %682, %677
  %687 = phi i32 [ %685, %682 ], [ 0, %677 ]
  store i32 %687, ptr %679, align 4, !tbaa !9
  %688 = add nuw nsw i64 %666, 2
  br label %665

689:                                              ; preds = %137, %710
  %690 = phi i64 [ %712, %710 ], [ 0, %137 ]
  %691 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %690
  %692 = load i32, ptr %691, align 8, !tbaa !9
  %693 = icmp eq i32 %692, -1
  br i1 %693, label %698, label %694

694:                                              ; preds = %689
  %695 = sext i32 %692 to i64
  %696 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %695
  %697 = load i32, ptr %696, align 4, !tbaa !9
  br label %698

698:                                              ; preds = %694, %689
  %699 = phi i32 [ %697, %694 ], [ 0, %689 ]
  store i32 %699, ptr %691, align 8, !tbaa !9
  %700 = icmp eq i64 %690, 254
  br i1 %700, label %713, label %701

701:                                              ; preds = %698
  %702 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %690
  %703 = getelementptr inbounds nuw i8, ptr %702, i64 4
  %704 = load i32, ptr %703, align 4, !tbaa !9
  %705 = icmp eq i32 %704, -1
  br i1 %705, label %710, label %706

706:                                              ; preds = %701
  %707 = sext i32 %704 to i64
  %708 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %707
  %709 = load i32, ptr %708, align 4, !tbaa !9
  br label %710

710:                                              ; preds = %706, %701
  %711 = phi i32 [ %709, %706 ], [ 0, %701 ]
  store i32 %711, ptr %703, align 4, !tbaa !9
  %712 = add nuw nsw i64 %690, 2
  br label %689

713:                                              ; preds = %674, %650, %638, %698, %545
  call void @llvm.lifetime.end.p0(ptr nonnull %11) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %10) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %9) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %8) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %7) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %6) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %5) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #9
  br label %714

714:                                              ; preds = %726, %713
  %715 = phi i64 [ 0, %713 ], [ %737, %726 ]
  %716 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %715
  %717 = getelementptr inbounds nuw i8, ptr %716, i64 268
  %718 = getelementptr inbounds nuw i8, ptr %716, i64 284
  %719 = load <4 x i32>, ptr %717, align 4, !tbaa !9
  %720 = load <4 x i32>, ptr %718, align 4, !tbaa !9
  %721 = trunc <4 x i32> %719 to <4 x i8>
  %722 = trunc <4 x i32> %720 to <4 x i8>
  %723 = getelementptr inbounds nuw i8, ptr %0, i64 %715
  %724 = getelementptr inbounds nuw i8, ptr %723, i64 4
  store <4 x i8> %721, ptr %723, align 1, !tbaa !12
  store <4 x i8> %722, ptr %724, align 1, !tbaa !12
  %725 = icmp eq i64 %715, 176
  br i1 %725, label %738, label %726

726:                                              ; preds = %714
  %727 = or disjoint i64 %715, 8
  %728 = getelementptr inbounds nuw [4 x i8], ptr @recd, i64 %727
  %729 = getelementptr inbounds nuw i8, ptr %728, i64 268
  %730 = getelementptr inbounds nuw i8, ptr %728, i64 284
  %731 = load <4 x i32>, ptr %729, align 4, !tbaa !9
  %732 = load <4 x i32>, ptr %730, align 4, !tbaa !9
  %733 = trunc <4 x i32> %731 to <4 x i8>
  %734 = trunc <4 x i32> %732 to <4 x i8>
  %735 = getelementptr inbounds nuw i8, ptr %0, i64 %727
  %736 = getelementptr inbounds nuw i8, ptr %735, i64 4
  store <4 x i8> %733, ptr %735, align 1, !tbaa !12
  store <4 x i8> %734, ptr %736, align 1, !tbaa !12
  %737 = add nuw nsw i64 %715, 16
  br label %714

738:                                              ; preds = %714
  %739 = load i32, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1004), align 4, !tbaa !9
  %740 = trunc i32 %739 to i8
  %741 = getelementptr inbounds nuw i8, ptr %0, i64 184
  store i8 %740, ptr %741, align 1, !tbaa !12
  %742 = load i32, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1008), align 16, !tbaa !9
  %743 = trunc i32 %742 to i8
  %744 = getelementptr inbounds nuw i8, ptr %0, i64 185
  store i8 %743, ptr %744, align 1, !tbaa !12
  %745 = load i32, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1012), align 4, !tbaa !9
  %746 = trunc i32 %745 to i8
  %747 = getelementptr inbounds nuw i8, ptr %0, i64 186
  store i8 %746, ptr %747, align 1, !tbaa !12
  %748 = load i32, ptr getelementptr inbounds nuw (i8, ptr @recd, i64 1016), align 8, !tbaa !9
  %749 = trunc i32 %748 to i8
  %750 = getelementptr inbounds nuw i8, ptr %0, i64 187
  store i8 %749, ptr %750, align 1, !tbaa !12
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable
define dso_local void @rsenc_204(ptr nofree noundef writeonly captures(none) %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #0 {
  %3 = ptrtoaddr ptr %1 to i64
  %4 = ptrtoaddr ptr %0 to i64
  %5 = load i1, ptr @inited, align 4
  br i1 %5, label %27, label %6

6:                                                ; preds = %2
  store i32 0, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 4), align 4, !tbaa !9
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 8), align 8, !tbaa !9
  store i32 2, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 16), align 16, !tbaa !9
  store <4 x i32> <i32 1, i32 2, i32 4, i32 8>, ptr @alpha_to, align 16, !tbaa !9
  store i32 3, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 32), align 16, !tbaa !9
  store i32 4, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 64), align 16, !tbaa !9
  store i32 29, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 32), align 16, !tbaa !9
  store i32 5, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 128), align 16, !tbaa !9
  store i32 6, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 256), align 16, !tbaa !9
  store <4 x i32> <i32 16, i32 32, i32 64, i32 128>, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 16), align 16, !tbaa !9
  store i32 7, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 512), align 16, !tbaa !9
  store i32 8, ptr getelementptr inbounds nuw (i8, ptr @index_of, i64 116), align 4, !tbaa !9
  br label %7

7:                                                ; preds = %19, %6
  %8 = phi i32 [ 29, %6 ], [ %20, %19 ]
  %9 = phi i64 [ 9, %6 ], [ %24, %19 ]
  %10 = getelementptr [4 x i8], ptr @alpha_to, i64 %9
  %11 = icmp slt i32 %8, 128
  br i1 %11, label %17, label %12

12:                                               ; preds = %7
  %13 = load i32, ptr getelementptr inbounds nuw (i8, ptr @alpha_to, i64 32), align 16, !tbaa !9
  %14 = shl nuw i32 %8, 1
  %15 = xor i32 %14, %13
  %16 = xor i32 %15, 256
  br label %19

17:                                               ; preds = %7
  %18 = shl i32 %8, 1
  br label %19

19:                                               ; preds = %17, %12
  %20 = phi i32 [ %16, %12 ], [ %18, %17 ]
  store i32 %20, ptr %10, align 4, !tbaa !9
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %21
  %23 = trunc nuw nsw i64 %9 to i32
  store i32 %23, ptr %22, align 4, !tbaa !9
  %24 = add nuw nsw i64 %9, 1
  %25 = icmp eq i64 %24, 255
  br i1 %25, label %26, label %7, !llvm.loop !10

26:                                               ; preds = %19
  store i32 -1, ptr @index_of, align 16, !tbaa !9
  tail call fastcc void @gen_poly()
  store i1 true, ptr @inited, align 4
  br label %27

27:                                               ; preds = %26, %2
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(204) @data, i8 0, i64 204, i1 false), !tbaa !9
  br label %28

28:                                               ; preds = %40, %27
  %29 = phi i64 [ 0, %27 ], [ %51, %40 ]
  %30 = getelementptr inbounds nuw i8, ptr %1, i64 %29
  %31 = getelementptr inbounds nuw i8, ptr %30, i64 4
  %32 = load <4 x i8>, ptr %30, align 1, !tbaa !12
  %33 = load <4 x i8>, ptr %31, align 1, !tbaa !12
  %34 = zext <4 x i8> %32 to <4 x i32>
  %35 = zext <4 x i8> %33 to <4 x i32>
  %36 = getelementptr inbounds nuw [4 x i8], ptr @data, i64 %29
  %37 = getelementptr inbounds nuw i8, ptr %36, i64 204
  %38 = getelementptr inbounds nuw i8, ptr %36, i64 220
  store <4 x i32> %34, ptr %37, align 4, !tbaa !9
  store <4 x i32> %35, ptr %38, align 4, !tbaa !9
  %39 = icmp eq i64 %29, 176
  br i1 %39, label %52, label %40

40:                                               ; preds = %28
  %41 = or disjoint i64 %29, 8
  %42 = getelementptr inbounds nuw i8, ptr %1, i64 %41
  %43 = getelementptr inbounds nuw i8, ptr %42, i64 4
  %44 = load <4 x i8>, ptr %42, align 1, !tbaa !12
  %45 = load <4 x i8>, ptr %43, align 1, !tbaa !12
  %46 = zext <4 x i8> %44 to <4 x i32>
  %47 = zext <4 x i8> %45 to <4 x i32>
  %48 = getelementptr inbounds nuw [4 x i8], ptr @data, i64 %41
  %49 = getelementptr inbounds nuw i8, ptr %48, i64 204
  %50 = getelementptr inbounds nuw i8, ptr %48, i64 220
  store <4 x i32> %46, ptr %49, align 4, !tbaa !9
  store <4 x i32> %47, ptr %50, align 4, !tbaa !9
  %51 = add nuw nsw i64 %29, 16
  br label %28

52:                                               ; preds = %28
  %53 = getelementptr inbounds nuw i8, ptr %1, i64 184
  %54 = load i8, ptr %53, align 1, !tbaa !12
  %55 = zext i8 %54 to i32
  store i32 %55, ptr getelementptr inbounds nuw (i8, ptr @data, i64 940), align 4, !tbaa !9
  %56 = getelementptr inbounds nuw i8, ptr %1, i64 185
  %57 = load i8, ptr %56, align 1, !tbaa !12
  %58 = zext i8 %57 to i32
  store i32 %58, ptr getelementptr inbounds nuw (i8, ptr @data, i64 944), align 16, !tbaa !9
  %59 = getelementptr inbounds nuw i8, ptr %1, i64 186
  %60 = load i8, ptr %59, align 1, !tbaa !12
  %61 = zext i8 %60 to i32
  store i32 %61, ptr getelementptr inbounds nuw (i8, ptr @data, i64 948), align 4, !tbaa !9
  %62 = getelementptr inbounds nuw i8, ptr %1, i64 187
  %63 = load i8, ptr %62, align 1, !tbaa !12
  %64 = zext i8 %63 to i32
  store i32 %64, ptr getelementptr inbounds nuw (i8, ptr @data, i64 952), align 8, !tbaa !9
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 16 dereferenceable(64) @bb, i8 0, i64 64, i1 false), !tbaa !9
  %65 = load i32, ptr @gg, align 16
  br label %66

66:                                               ; preds = %102, %52
  %67 = phi i64 [ 238, %52 ], [ %104, %102 ]
  %68 = getelementptr inbounds nuw [4 x i8], ptr @data, i64 %67
  %69 = load i32, ptr %68, align 4, !tbaa !9
  %70 = load i32, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 60), align 4, !tbaa !9
  %71 = xor i32 %70, %69
  %72 = sext i32 %71 to i64
  %73 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %72
  %74 = load i32, ptr %73, align 4, !tbaa !9
  %75 = icmp eq i32 %74, -1
  br i1 %75, label %76, label %77

76:                                               ; preds = %66
  tail call void @llvm.memmove.p0.p0.i64(ptr noundef nonnull align 4 dereferenceable(60) getelementptr inbounds nuw (i8, ptr @bb, i64 4), ptr noundef nonnull align 16 dereferenceable(60) @bb, i64 60, i1 false), !tbaa !9
  br label %102

77:                                               ; preds = %66, %92
  %78 = phi i64 [ %94, %92 ], [ 15, %66 ]
  %79 = getelementptr inbounds nuw [4 x i8], ptr @gg, i64 %78
  %80 = load i32, ptr %79, align 4, !tbaa !9
  %81 = icmp eq i32 %80, -1
  %82 = getelementptr [4 x i8], ptr @bb, i64 %78
  %83 = getelementptr i8, ptr %82, i64 -4
  %84 = load i32, ptr %83, align 4, !tbaa !9
  br i1 %81, label %92, label %85

85:                                               ; preds = %77
  %86 = add nsw i32 %80, %74
  %87 = srem i32 %86, 255
  %88 = sext i32 %87 to i64
  %89 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %88
  %90 = load i32, ptr %89, align 4, !tbaa !9
  %91 = xor i32 %90, %84
  br label %92

92:                                               ; preds = %85, %77
  %93 = phi i32 [ %91, %85 ], [ %84, %77 ]
  store i32 %93, ptr %82, align 4, !tbaa !9
  %94 = add nsw i64 %78, -1
  %95 = icmp samesign ugt i64 %78, 1
  br i1 %95, label %77, label %96, !llvm.loop !33

96:                                               ; preds = %92
  %97 = add nsw i32 %74, %65
  %98 = srem i32 %97, 255
  %99 = sext i32 %98 to i64
  %100 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %99
  %101 = load i32, ptr %100, align 4, !tbaa !9
  br label %102

102:                                              ; preds = %96, %76
  %103 = phi i32 [ %101, %96 ], [ 0, %76 ]
  store i32 %103, ptr @bb, align 16, !tbaa !9
  %104 = add nsw i64 %67, -1
  %105 = icmp eq i64 %67, 0
  br i1 %105, label %106, label %66, !llvm.loop !34

106:                                              ; preds = %102
  %107 = sub i64 %3, %4
  %108 = icmp ugt i64 %107, -32
  br i1 %108, label %159, label %109

109:                                              ; preds = %106
  %110 = getelementptr inbounds nuw i8, ptr %1, i64 16
  %111 = load <16 x i8>, ptr %1, align 1, !tbaa !12
  %112 = load <16 x i8>, ptr %110, align 1, !tbaa !12
  %113 = getelementptr inbounds nuw i8, ptr %0, i64 16
  store <16 x i8> %111, ptr %0, align 1, !tbaa !12
  store <16 x i8> %112, ptr %113, align 1, !tbaa !12
  %114 = getelementptr inbounds nuw i8, ptr %1, i64 32
  %115 = getelementptr inbounds nuw i8, ptr %1, i64 48
  %116 = load <16 x i8>, ptr %114, align 1, !tbaa !12
  %117 = load <16 x i8>, ptr %115, align 1, !tbaa !12
  %118 = getelementptr inbounds nuw i8, ptr %0, i64 32
  %119 = getelementptr inbounds nuw i8, ptr %0, i64 48
  store <16 x i8> %116, ptr %118, align 1, !tbaa !12
  store <16 x i8> %117, ptr %119, align 1, !tbaa !12
  %120 = getelementptr inbounds nuw i8, ptr %1, i64 64
  %121 = getelementptr inbounds nuw i8, ptr %1, i64 80
  %122 = load <16 x i8>, ptr %120, align 1, !tbaa !12
  %123 = load <16 x i8>, ptr %121, align 1, !tbaa !12
  %124 = getelementptr inbounds nuw i8, ptr %0, i64 64
  %125 = getelementptr inbounds nuw i8, ptr %0, i64 80
  store <16 x i8> %122, ptr %124, align 1, !tbaa !12
  store <16 x i8> %123, ptr %125, align 1, !tbaa !12
  %126 = getelementptr inbounds nuw i8, ptr %1, i64 96
  %127 = getelementptr inbounds nuw i8, ptr %1, i64 112
  %128 = load <16 x i8>, ptr %126, align 1, !tbaa !12
  %129 = load <16 x i8>, ptr %127, align 1, !tbaa !12
  %130 = getelementptr inbounds nuw i8, ptr %0, i64 96
  %131 = getelementptr inbounds nuw i8, ptr %0, i64 112
  store <16 x i8> %128, ptr %130, align 1, !tbaa !12
  store <16 x i8> %129, ptr %131, align 1, !tbaa !12
  %132 = getelementptr inbounds nuw i8, ptr %1, i64 128
  %133 = getelementptr inbounds nuw i8, ptr %1, i64 144
  %134 = load <16 x i8>, ptr %132, align 1, !tbaa !12
  %135 = load <16 x i8>, ptr %133, align 1, !tbaa !12
  %136 = getelementptr inbounds nuw i8, ptr %0, i64 128
  %137 = getelementptr inbounds nuw i8, ptr %0, i64 144
  store <16 x i8> %134, ptr %136, align 1, !tbaa !12
  store <16 x i8> %135, ptr %137, align 1, !tbaa !12
  %138 = getelementptr inbounds nuw i8, ptr %1, i64 160
  %139 = load <4 x i8>, ptr %138, align 1, !tbaa !12
  %140 = getelementptr inbounds nuw i8, ptr %0, i64 160
  store <4 x i8> %139, ptr %140, align 1, !tbaa !12
  %141 = getelementptr inbounds nuw i8, ptr %1, i64 164
  %142 = load <4 x i8>, ptr %141, align 1, !tbaa !12
  %143 = getelementptr inbounds nuw i8, ptr %0, i64 164
  store <4 x i8> %142, ptr %143, align 1, !tbaa !12
  %144 = getelementptr inbounds nuw i8, ptr %1, i64 168
  %145 = load <4 x i8>, ptr %144, align 1, !tbaa !12
  %146 = getelementptr inbounds nuw i8, ptr %0, i64 168
  store <4 x i8> %145, ptr %146, align 1, !tbaa !12
  %147 = getelementptr inbounds nuw i8, ptr %1, i64 172
  %148 = load <4 x i8>, ptr %147, align 1, !tbaa !12
  %149 = getelementptr inbounds nuw i8, ptr %0, i64 172
  store <4 x i8> %148, ptr %149, align 1, !tbaa !12
  %150 = getelementptr inbounds nuw i8, ptr %1, i64 176
  %151 = load <4 x i8>, ptr %150, align 1, !tbaa !12
  %152 = getelementptr inbounds nuw i8, ptr %0, i64 176
  store <4 x i8> %151, ptr %152, align 1, !tbaa !12
  %153 = getelementptr inbounds nuw i8, ptr %1, i64 180
  %154 = load <4 x i8>, ptr %153, align 1, !tbaa !12
  %155 = getelementptr inbounds nuw i8, ptr %0, i64 180
  store <4 x i8> %154, ptr %155, align 1, !tbaa !12
  %156 = getelementptr inbounds nuw i8, ptr %1, i64 184
  %157 = load <4 x i8>, ptr %156, align 1, !tbaa !12
  %158 = getelementptr inbounds nuw i8, ptr %0, i64 184
  store <4 x i8> %157, ptr %158, align 1, !tbaa !12
  br label %178

159:                                              ; preds = %106, %159
  %160 = phi i64 [ %176, %159 ], [ 0, %106 ]
  %161 = getelementptr inbounds nuw i8, ptr %1, i64 %160
  %162 = load i8, ptr %161, align 1, !tbaa !12
  %163 = getelementptr inbounds nuw i8, ptr %0, i64 %160
  store i8 %162, ptr %163, align 1, !tbaa !12
  %164 = or disjoint i64 %160, 1
  %165 = getelementptr inbounds nuw i8, ptr %1, i64 %164
  %166 = load i8, ptr %165, align 1, !tbaa !12
  %167 = getelementptr inbounds nuw i8, ptr %0, i64 %164
  store i8 %166, ptr %167, align 1, !tbaa !12
  %168 = or disjoint i64 %160, 2
  %169 = getelementptr inbounds nuw i8, ptr %1, i64 %168
  %170 = load i8, ptr %169, align 1, !tbaa !12
  %171 = getelementptr inbounds nuw i8, ptr %0, i64 %168
  store i8 %170, ptr %171, align 1, !tbaa !12
  %172 = or disjoint i64 %160, 3
  %173 = getelementptr inbounds nuw i8, ptr %1, i64 %172
  %174 = load i8, ptr %173, align 1, !tbaa !12
  %175 = getelementptr inbounds nuw i8, ptr %0, i64 %172
  store i8 %174, ptr %175, align 1, !tbaa !12
  %176 = add nuw nsw i64 %160, 4
  %177 = icmp eq i64 %176, 188
  br i1 %177, label %178, label %159, !llvm.loop !35

178:                                              ; preds = %159, %109
  %179 = trunc i32 %103 to i8
  %180 = getelementptr inbounds nuw i8, ptr %0, i64 188
  store i8 %179, ptr %180, align 1, !tbaa !12
  %181 = getelementptr inbounds nuw i8, ptr %0, i64 189
  %182 = load <8 x i32>, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 4), align 4, !tbaa !9
  %183 = trunc <8 x i32> %182 to <8 x i8>
  store <8 x i8> %183, ptr %181, align 1, !tbaa !12
  %184 = getelementptr inbounds nuw i8, ptr %0, i64 197
  %185 = load <4 x i32>, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 36), align 4, !tbaa !9
  %186 = trunc <4 x i32> %185 to <4 x i8>
  store <4 x i8> %186, ptr %184, align 1, !tbaa !12
  %187 = load i32, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 52), align 4, !tbaa !9
  %188 = trunc i32 %187 to i8
  %189 = getelementptr inbounds nuw i8, ptr %0, i64 201
  store i8 %188, ptr %189, align 1, !tbaa !12
  %190 = load i32, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 56), align 8, !tbaa !9
  %191 = trunc i32 %190 to i8
  %192 = getelementptr inbounds nuw i8, ptr %0, i64 202
  store i8 %191, ptr %192, align 1, !tbaa !12
  %193 = load i32, ptr getelementptr inbounds nuw (i8, ptr @bb, i64 60), align 4, !tbaa !9
  %194 = trunc i32 %193 to i8
  %195 = getelementptr inbounds nuw i8, ptr %0, i64 203
  store i8 %194, ptr %195, align 1, !tbaa !12
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local noundef i32 @main() local_unnamed_addr #2 {
  %1 = alloca [204 x i8], align 16
  %2 = alloca [204 x i8], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %1) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %2) #9
  br label %3

3:                                                ; preds = %0, %26
  %4 = phi i32 [ 0, %0 ], [ %27, %26 ]
  br label %5

5:                                                ; preds = %3, %5
  %6 = phi i64 [ 0, %3 ], [ %10, %5 ]
  %7 = tail call i64 @random() #9
  %8 = trunc i64 %7 to i8
  %9 = getelementptr inbounds nuw i8, ptr %1, i64 %6
  store i8 %8, ptr %9, align 1, !tbaa !12
  %10 = add nuw nsw i64 %6, 1
  %11 = icmp eq i64 %10, 188
  br i1 %11, label %12, label %5, !llvm.loop !37

12:                                               ; preds = %5
  call void @rsenc_204(ptr noundef nonnull %2, ptr noundef nonnull %1)
  %13 = tail call i64 @random() #9
  %14 = trunc i64 %13 to i32
  %15 = and i32 %14, 127
  %16 = icmp eq i32 %15, 0
  br i1 %16, label %26, label %17

17:                                               ; preds = %12, %17
  %18 = phi i32 [ %24, %17 ], [ 0, %12 ]
  %19 = tail call i64 @random() #9
  %20 = trunc i64 %19 to i8
  %21 = tail call i64 @random() #9
  %22 = srem i64 %21, 204
  %23 = getelementptr inbounds i8, ptr %2, i64 %22
  store i8 %20, ptr %23, align 1, !tbaa !12
  %24 = add nuw nsw i32 %18, 1
  %25 = icmp eq i32 %24, %15
  br i1 %25, label %26, label %17, !llvm.loop !38

26:                                               ; preds = %17, %12
  call void @rsdec_204(ptr noundef nonnull %1, ptr noundef nonnull %2)
  %27 = add nuw nsw i32 %4, 1
  %28 = icmp eq i32 %27, 150000
  br i1 %28, label %29, label %3, !llvm.loop !39

29:                                               ; preds = %26
  call void @llvm.lifetime.end.p0(ptr nonnull %2) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %1) #9
  ret i32 0
}

; Function Attrs: nounwind
declare i64 @random() local_unnamed_addr #3

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable
define internal fastcc void @gen_poly() unnamed_addr #4 {
  store i32 2, ptr @gg, align 16, !tbaa !9
  store i32 1, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 4), align 4, !tbaa !9
  br label %1

1:                                                ; preds = %0, %27
  %2 = phi i64 [ 2, %0 ], [ %38, %27 ]
  %3 = getelementptr inbounds nuw [4 x i8], ptr @gg, i64 %2
  store i32 1, ptr %3, align 4, !tbaa !9
  %4 = trunc nuw nsw i64 %2 to i32
  br label %5

5:                                                ; preds = %1, %24
  %6 = phi i64 [ %2, %1 ], [ %7, %24 ]
  %7 = add nsw i64 %6, -1
  %8 = getelementptr inbounds nuw [4 x i8], ptr @gg, i64 %7
  %9 = load i32, ptr %8, align 4, !tbaa !9
  %10 = icmp eq i32 %9, 0
  %11 = getelementptr [4 x i8], ptr @gg, i64 %6
  %12 = getelementptr i8, ptr %11, i64 -8
  %13 = load i32, ptr %12, align 4, !tbaa !9
  br i1 %10, label %24, label %14

14:                                               ; preds = %5
  %15 = sext i32 %9 to i64
  %16 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %15
  %17 = load i32, ptr %16, align 4, !tbaa !9
  %18 = add nsw i32 %17, %4
  %19 = srem i32 %18, 255
  %20 = sext i32 %19 to i64
  %21 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %20
  %22 = load i32, ptr %21, align 4, !tbaa !9
  %23 = xor i32 %22, %13
  br label %24

24:                                               ; preds = %5, %14
  %25 = phi i32 [ %23, %14 ], [ %13, %5 ]
  store i32 %25, ptr %8, align 4, !tbaa !9
  %26 = icmp sgt i64 %6, 2
  br i1 %26, label %5, label %27, !llvm.loop !40

27:                                               ; preds = %24
  %28 = load i32, ptr @gg, align 16, !tbaa !9
  %29 = sext i32 %28 to i64
  %30 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %29
  %31 = load i32, ptr %30, align 4, !tbaa !9
  %32 = trunc nuw nsw i64 %2 to i32
  %33 = add nsw i32 %31, %32
  %34 = srem i32 %33, 255
  %35 = sext i32 %34 to i64
  %36 = getelementptr inbounds [4 x i8], ptr @alpha_to, i64 %35
  %37 = load i32, ptr %36, align 4, !tbaa !9
  store i32 %37, ptr @gg, align 16, !tbaa !9
  %38 = add nuw nsw i64 %2, 1
  %39 = icmp eq i64 %38, 17
  br i1 %39, label %40, label %1, !llvm.loop !41

40:                                               ; preds = %27
  %41 = sext i32 %37 to i64
  %42 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %41
  %43 = load i32, ptr %42, align 4, !tbaa !9
  store i32 %43, ptr @gg, align 16, !tbaa !9
  %44 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 4), align 4, !tbaa !9
  %45 = sext i32 %44 to i64
  %46 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %45
  %47 = load i32, ptr %46, align 4, !tbaa !9
  store i32 %47, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 4), align 4, !tbaa !9
  %48 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 8), align 8, !tbaa !9
  %49 = sext i32 %48 to i64
  %50 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %49
  %51 = load i32, ptr %50, align 4, !tbaa !9
  store i32 %51, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 8), align 8, !tbaa !9
  %52 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 12), align 4, !tbaa !9
  %53 = sext i32 %52 to i64
  %54 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %53
  %55 = load i32, ptr %54, align 4, !tbaa !9
  store i32 %55, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 12), align 4, !tbaa !9
  %56 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 16), align 16, !tbaa !9
  %57 = sext i32 %56 to i64
  %58 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %57
  %59 = load i32, ptr %58, align 4, !tbaa !9
  store i32 %59, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 16), align 16, !tbaa !9
  %60 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 20), align 4, !tbaa !9
  %61 = sext i32 %60 to i64
  %62 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %61
  %63 = load i32, ptr %62, align 4, !tbaa !9
  store i32 %63, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 20), align 4, !tbaa !9
  %64 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 24), align 8, !tbaa !9
  %65 = sext i32 %64 to i64
  %66 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %65
  %67 = load i32, ptr %66, align 4, !tbaa !9
  store i32 %67, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 24), align 8, !tbaa !9
  %68 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 28), align 4, !tbaa !9
  %69 = sext i32 %68 to i64
  %70 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %69
  %71 = load i32, ptr %70, align 4, !tbaa !9
  store i32 %71, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 28), align 4, !tbaa !9
  %72 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 32), align 16, !tbaa !9
  %73 = sext i32 %72 to i64
  %74 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %73
  %75 = load i32, ptr %74, align 4, !tbaa !9
  store i32 %75, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 32), align 16, !tbaa !9
  %76 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 36), align 4, !tbaa !9
  %77 = sext i32 %76 to i64
  %78 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %77
  %79 = load i32, ptr %78, align 4, !tbaa !9
  store i32 %79, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 36), align 4, !tbaa !9
  %80 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 40), align 8, !tbaa !9
  %81 = sext i32 %80 to i64
  %82 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %81
  %83 = load i32, ptr %82, align 4, !tbaa !9
  store i32 %83, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 40), align 8, !tbaa !9
  %84 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 44), align 4, !tbaa !9
  %85 = sext i32 %84 to i64
  %86 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %85
  %87 = load i32, ptr %86, align 4, !tbaa !9
  store i32 %87, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 44), align 4, !tbaa !9
  %88 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 48), align 16, !tbaa !9
  %89 = sext i32 %88 to i64
  %90 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %89
  %91 = load i32, ptr %90, align 4, !tbaa !9
  store i32 %91, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 48), align 16, !tbaa !9
  %92 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 52), align 4, !tbaa !9
  %93 = sext i32 %92 to i64
  %94 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %93
  %95 = load i32, ptr %94, align 4, !tbaa !9
  store i32 %95, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 52), align 4, !tbaa !9
  %96 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 56), align 8, !tbaa !9
  %97 = sext i32 %96 to i64
  %98 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %97
  %99 = load i32, ptr %98, align 4, !tbaa !9
  store i32 %99, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 56), align 8, !tbaa !9
  %100 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 60), align 4, !tbaa !9
  %101 = sext i32 %100 to i64
  %102 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %101
  %103 = load i32, ptr %102, align 4, !tbaa !9
  store i32 %103, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 60), align 4, !tbaa !9
  %104 = load i32, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 64), align 16, !tbaa !9
  %105 = sext i32 %104 to i64
  %106 = getelementptr inbounds [4 x i8], ptr @index_of, i64 %105
  %107 = load i32, ptr %106, align 4, !tbaa !9
  store i32 %107, ptr getelementptr inbounds nuw (i8, ptr @gg, i64 64), align 16, !tbaa !9
  ret void
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #5

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #6

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.smax.i32(i32, i32) #7

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memmove.p0.p0.i64(ptr writeonly captures(none), ptr readonly captures(none), i64, i1 immarg) #6

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #8

attributes #0 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nofree norecurse nosync nounwind memory(readwrite, argmem: none, inaccessiblemem: none, target_mem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #6 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #7 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #8 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #9 = { nounwind }

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
!12 = !{!7, !7, i64 0}
!13 = distinct !{!13, !11}
!14 = distinct !{!14, !11}
!15 = distinct !{!15, !11}
!16 = distinct !{!16, !11}
!17 = distinct !{!17, !11}
!18 = distinct !{!18, !11}
!19 = distinct !{!19, !11}
!20 = distinct !{!20, !11}
!21 = distinct !{!21, !11}
!22 = distinct !{!22, !11}
!23 = distinct !{!23, !24}
!24 = !{!"llvm.loop.unroll.disable"}
!25 = distinct !{!25, !11}
!26 = distinct !{!26, !11}
!27 = distinct !{!27, !11}
!28 = distinct !{!28, !11}
!29 = distinct !{!29, !11}
!30 = distinct !{!30, !11}
!31 = distinct !{!31, !11}
!32 = distinct !{!32, !11}
!33 = distinct !{!33, !11}
!34 = distinct !{!34, !11}
!35 = distinct !{!35, !11, !36}
!36 = !{!"llvm.loop.isvectorized", i32 1}
!37 = distinct !{!37, !11}
!38 = distinct !{!38, !11}
!39 = distinct !{!39, !11}
!40 = distinct !{!40, !11}
!41 = distinct !{!41, !11}
