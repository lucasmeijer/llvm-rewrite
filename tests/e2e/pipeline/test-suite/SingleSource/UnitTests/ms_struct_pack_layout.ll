; @source: tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct_pack_layout.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct_pack_layout.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/UnitTests/ms_struct_pack_layout.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.one = type { i32, i8, i16, i8 }
%struct.two = type { i32, i8, i32, i8 }
%struct.three = type { i16, i16, i8 }
%struct.four = type { i16, [2 x i8], i8, [3 x i8] }
%struct.five = type { i8, i8, i8 }
%struct.six = type { i8, [3 x i8], i8, i8, [2 x i8] }
%struct.seven = type { i8, i8, i8 }
%struct.eight = type { i16, i8 }
%union.nine = type { i64 }
%struct.ten = type { i64, i8 }

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 {
  %1 = alloca i32, align 4
  %2 = alloca [16 x i8], align 16
  %3 = alloca %struct.one, align 4
  %4 = alloca %struct.two, align 4
  %5 = alloca %struct.three, align 2
  %6 = alloca %struct.four, align 4
  %7 = alloca %struct.five, align 1
  %8 = alloca %struct.six, align 4
  %9 = alloca %struct.seven, align 1
  %10 = alloca %struct.eight, align 2
  %11 = alloca %union.nine, align 1
  %12 = alloca %struct.ten, align 8
  %13 = alloca i64, align 8
  %14 = alloca i64, align 8
  %15 = alloca i64, align 8
  %16 = alloca i64, align 8
  %17 = alloca i64, align 8
  %18 = alloca i64, align 8
  %19 = alloca i64, align 8
  %20 = alloca i64, align 8
  %21 = alloca i64, align 8
  %22 = alloca i64, align 8
  %23 = alloca i8, align 1
  %24 = alloca i8, align 1
  %25 = alloca i8, align 1
  %26 = alloca i8, align 1
  %27 = alloca i8, align 1
  %28 = alloca i8, align 1
  %29 = alloca i8, align 1
  %30 = alloca i8, align 1
  %31 = alloca i8, align 1
  %32 = alloca i8, align 1
  %33 = alloca i8, align 1
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #3
  call void @llvm.lifetime.start.p0(ptr %3) #3
  call void @llvm.lifetime.start.p0(ptr %4) #3
  call void @llvm.lifetime.start.p0(ptr %5) #3
  call void @llvm.lifetime.start.p0(ptr %6) #3
  call void @llvm.lifetime.start.p0(ptr %7) #3
  call void @llvm.lifetime.start.p0(ptr %8) #3
  call void @llvm.lifetime.start.p0(ptr %9) #3
  call void @llvm.lifetime.start.p0(ptr %10) #3
  call void @llvm.lifetime.start.p0(ptr %11) #3
  call void @llvm.lifetime.start.p0(ptr %12) #3
  call void @llvm.lifetime.start.p0(ptr %13) #3
  store i64 12, ptr %13, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %14) #3
  store i64 16, ptr %14, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %15) #3
  store i64 6, ptr %15, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %16) #3
  store i64 8, ptr %16, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %17) #3
  store i64 3, ptr %17, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %18) #3
  store i64 8, ptr %18, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %19) #3
  store i64 3, ptr %19, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %20) #3
  store i64 4, ptr %20, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %21) #3
  store i64 8, ptr %21, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %22) #3
  store i64 16, ptr %22, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %23) #3
  store i8 8, ptr %23, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %24) #3
  store i8 12, ptr %24, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %25) #3
  store i8 4, ptr %25, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %26) #3
  store i8 4, ptr %26, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %27) #3
  store i8 2, ptr %27, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %28) #3
  store i8 5, ptr %28, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %29) #3
  store i8 2, ptr %29, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %30) #3
  store i8 2, ptr %30, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %31) #3
  store i8 0, ptr %31, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %32) #3
  store i8 8, ptr %32, align 1, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %33) #3
  store i8 0, ptr %33, align 1, !tbaa !11
  br label %34

34:                                               ; preds = %43, %0
  %35 = load i8, ptr %33, align 1, !tbaa !11
  %36 = zext i8 %35 to i32
  %37 = icmp slt i32 %36, 16
  br i1 %37, label %38, label %46

38:                                               ; preds = %34
  %39 = load i8, ptr %33, align 1, !tbaa !11
  %40 = load i8, ptr %33, align 1, !tbaa !11
  %41 = zext i8 %40 to i64
  %42 = getelementptr inbounds nuw [16 x i8], ptr %2, i64 0, i64 %41
  store i8 %39, ptr %42, align 1, !tbaa !11
  br label %43

43:                                               ; preds = %38
  %44 = load i8, ptr %33, align 1, !tbaa !11
  %45 = add i8 %44, 1
  store i8 %45, ptr %33, align 1, !tbaa !11
  br label %34, !llvm.loop !12

46:                                               ; preds = %34
  %47 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %3, ptr align 16 %47, i64 12, i1 false)
  %48 = getelementptr inbounds nuw %struct.one, ptr %3, i32 0, i32 3
  %49 = load i8, ptr %48, align 4, !tbaa !14
  %50 = sext i8 %49 to i32
  %51 = load i8, ptr %23, align 1, !tbaa !11
  %52 = zext i8 %51 to i32
  %53 = icmp ne i32 %50, %52
  br i1 %53, label %54, label %55

54:                                               ; preds = %46
  call void @abort() #4
  unreachable

55:                                               ; preds = %46
  %56 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %4, ptr align 16 %56, i64 16, i1 false)
  %57 = getelementptr inbounds nuw %struct.two, ptr %4, i32 0, i32 3
  %58 = load i8, ptr %57, align 4, !tbaa !17
  %59 = sext i8 %58 to i32
  %60 = load i8, ptr %24, align 1, !tbaa !11
  %61 = zext i8 %60 to i32
  %62 = icmp ne i32 %59, %61
  br i1 %62, label %63, label %64

63:                                               ; preds = %55
  call void @abort() #4
  unreachable

64:                                               ; preds = %55
  %65 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 2 %5, ptr align 16 %65, i64 6, i1 false)
  %66 = getelementptr inbounds nuw %struct.three, ptr %5, i32 0, i32 2
  %67 = load i8, ptr %66, align 2
  %68 = and i8 %67, 127
  %69 = zext i8 %68 to i32
  %70 = load i8, ptr %25, align 1, !tbaa !11
  %71 = zext i8 %70 to i32
  %72 = icmp ne i32 %69, %71
  br i1 %72, label %73, label %74

73:                                               ; preds = %64
  call void @abort() #4
  unreachable

74:                                               ; preds = %64
  %75 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %6, ptr align 16 %75, i64 8, i1 false)
  %76 = getelementptr inbounds nuw %struct.four, ptr %6, i32 0, i32 2
  %77 = load i8, ptr %76, align 4
  %78 = and i8 %77, 127
  %79 = zext i8 %78 to i32
  %80 = load i8, ptr %26, align 1, !tbaa !11
  %81 = zext i8 %80 to i32
  %82 = icmp ne i32 %79, %81
  br i1 %82, label %83, label %84

83:                                               ; preds = %74
  call void @abort() #4
  unreachable

84:                                               ; preds = %74
  %85 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %7, ptr align 16 %85, i64 3, i1 false)
  %86 = getelementptr inbounds nuw %struct.five, ptr %7, i32 0, i32 2
  %87 = load i8, ptr %86, align 1, !tbaa !19
  %88 = sext i8 %87 to i32
  %89 = load i8, ptr %27, align 1, !tbaa !11
  %90 = sext i8 %89 to i32
  %91 = icmp ne i32 %88, %90
  br i1 %91, label %92, label %93

92:                                               ; preds = %84
  call void @abort() #4
  unreachable

93:                                               ; preds = %84
  %94 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %8, ptr align 16 %94, i64 8, i1 false)
  %95 = getelementptr inbounds nuw %struct.six, ptr %8, i32 0, i32 3
  %96 = load i8, ptr %95, align 1, !tbaa !21
  %97 = sext i8 %96 to i32
  %98 = load i8, ptr %28, align 1, !tbaa !11
  %99 = sext i8 %98 to i32
  %100 = icmp ne i32 %97, %99
  br i1 %100, label %101, label %102

101:                                              ; preds = %93
  call void @abort() #4
  unreachable

102:                                              ; preds = %93
  %103 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %9, ptr align 16 %103, i64 3, i1 false)
  %104 = getelementptr inbounds nuw %struct.seven, ptr %9, i32 0, i32 2
  %105 = load i8, ptr %104, align 1, !tbaa !23
  %106 = sext i8 %105 to i32
  %107 = load i8, ptr %29, align 1, !tbaa !11
  %108 = sext i8 %107 to i32
  %109 = icmp ne i32 %106, %108
  br i1 %109, label %110, label %111

110:                                              ; preds = %102
  call void @abort() #4
  unreachable

111:                                              ; preds = %102
  %112 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 2 %10, ptr align 16 %112, i64 4, i1 false)
  %113 = getelementptr inbounds nuw %struct.eight, ptr %10, i32 0, i32 1
  %114 = load i8, ptr %113, align 2, !tbaa !25
  %115 = sext i8 %114 to i32
  %116 = load i8, ptr %30, align 1, !tbaa !11
  %117 = sext i8 %116 to i32
  %118 = icmp ne i32 %115, %117
  br i1 %118, label %119, label %120

119:                                              ; preds = %111
  call void @abort() #4
  unreachable

120:                                              ; preds = %111
  %121 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 1 %11, ptr align 16 %121, i64 8, i1 false)
  %122 = load i8, ptr %11, align 1, !tbaa !11
  %123 = sext i8 %122 to i32
  %124 = load i8, ptr %31, align 1, !tbaa !11
  %125 = sext i8 %124 to i32
  %126 = icmp ne i32 %123, %125
  br i1 %126, label %127, label %128

127:                                              ; preds = %120
  call void @abort() #4
  unreachable

128:                                              ; preds = %120
  %129 = getelementptr inbounds [16 x i8], ptr %2, i64 0, i64 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %12, ptr align 16 %129, i64 16, i1 false)
  %130 = getelementptr inbounds nuw %struct.ten, ptr %12, i32 0, i32 1
  %131 = load i8, ptr %130, align 8, !tbaa !27
  %132 = sext i8 %131 to i32
  %133 = load i8, ptr %32, align 1, !tbaa !11
  %134 = sext i8 %133 to i32
  %135 = icmp ne i32 %132, %134
  br i1 %135, label %136, label %137

136:                                              ; preds = %128
  call void @abort() #4
  unreachable

137:                                              ; preds = %128
  %138 = load i64, ptr %13, align 8, !tbaa !9
  %139 = icmp ne i64 12, %138
  br i1 %139, label %140, label %141

140:                                              ; preds = %137
  call void @abort() #4
  unreachable

141:                                              ; preds = %137
  %142 = load i64, ptr %14, align 8, !tbaa !9
  %143 = icmp ne i64 16, %142
  br i1 %143, label %144, label %145

144:                                              ; preds = %141
  call void @abort() #4
  unreachable

145:                                              ; preds = %141
  %146 = load i64, ptr %15, align 8, !tbaa !9
  %147 = icmp ne i64 6, %146
  br i1 %147, label %148, label %149

148:                                              ; preds = %145
  call void @abort() #4
  unreachable

149:                                              ; preds = %145
  %150 = load i64, ptr %16, align 8, !tbaa !9
  %151 = icmp ne i64 8, %150
  br i1 %151, label %152, label %153

152:                                              ; preds = %149
  call void @abort() #4
  unreachable

153:                                              ; preds = %149
  %154 = load i64, ptr %17, align 8, !tbaa !9
  %155 = icmp ne i64 3, %154
  br i1 %155, label %156, label %157

156:                                              ; preds = %153
  call void @abort() #4
  unreachable

157:                                              ; preds = %153
  %158 = load i64, ptr %18, align 8, !tbaa !9
  %159 = icmp ne i64 8, %158
  br i1 %159, label %160, label %161

160:                                              ; preds = %157
  call void @abort() #4
  unreachable

161:                                              ; preds = %157
  %162 = load i64, ptr %19, align 8, !tbaa !9
  %163 = icmp ne i64 3, %162
  br i1 %163, label %164, label %165

164:                                              ; preds = %161
  call void @abort() #4
  unreachable

165:                                              ; preds = %161
  %166 = load i64, ptr %20, align 8, !tbaa !9
  %167 = icmp ne i64 4, %166
  br i1 %167, label %168, label %169

168:                                              ; preds = %165
  call void @abort() #4
  unreachable

169:                                              ; preds = %165
  %170 = load i64, ptr %21, align 8, !tbaa !9
  %171 = icmp ne i64 8, %170
  br i1 %171, label %172, label %173

172:                                              ; preds = %169
  call void @abort() #4
  unreachable

173:                                              ; preds = %169
  %174 = load i64, ptr %22, align 8, !tbaa !9
  %175 = icmp ne i64 16, %174
  br i1 %175, label %176, label %177

176:                                              ; preds = %173
  call void @abort() #4
  unreachable

177:                                              ; preds = %173
  call void @llvm.lifetime.end.p0(ptr %33) #3
  call void @llvm.lifetime.end.p0(ptr %32) #3
  call void @llvm.lifetime.end.p0(ptr %31) #3
  call void @llvm.lifetime.end.p0(ptr %30) #3
  call void @llvm.lifetime.end.p0(ptr %29) #3
  call void @llvm.lifetime.end.p0(ptr %28) #3
  call void @llvm.lifetime.end.p0(ptr %27) #3
  call void @llvm.lifetime.end.p0(ptr %26) #3
  call void @llvm.lifetime.end.p0(ptr %25) #3
  call void @llvm.lifetime.end.p0(ptr %24) #3
  call void @llvm.lifetime.end.p0(ptr %23) #3
  call void @llvm.lifetime.end.p0(ptr %22) #3
  call void @llvm.lifetime.end.p0(ptr %21) #3
  call void @llvm.lifetime.end.p0(ptr %20) #3
  call void @llvm.lifetime.end.p0(ptr %19) #3
  call void @llvm.lifetime.end.p0(ptr %18) #3
  call void @llvm.lifetime.end.p0(ptr %17) #3
  call void @llvm.lifetime.end.p0(ptr %16) #3
  call void @llvm.lifetime.end.p0(ptr %15) #3
  call void @llvm.lifetime.end.p0(ptr %14) #3
  call void @llvm.lifetime.end.p0(ptr %13) #3
  call void @llvm.lifetime.end.p0(ptr %12) #3
  call void @llvm.lifetime.end.p0(ptr %11) #3
  call void @llvm.lifetime.end.p0(ptr %10) #3
  call void @llvm.lifetime.end.p0(ptr %9) #3
  call void @llvm.lifetime.end.p0(ptr %8) #3
  call void @llvm.lifetime.end.p0(ptr %7) #3
  call void @llvm.lifetime.end.p0(ptr %6) #3
  call void @llvm.lifetime.end.p0(ptr %5) #3
  call void @llvm.lifetime.end.p0(ptr %4) #3
  call void @llvm.lifetime.end.p0(ptr %3) #3
  call void @llvm.lifetime.end.p0(ptr %2) #3
  ret i32 0
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

; Function Attrs: noreturn nounwind
declare void @abort() #2

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { noreturn nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind }
attributes #4 = { noreturn nounwind }

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
!10 = !{!"long", !7, i64 0}
!11 = !{!7, !7, i64 0}
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
!14 = !{!15, !7, i64 8}
!15 = !{!"one", !6, i64 0, !7, i64 4, !16, i64 6, !7, i64 8}
!16 = !{!"short", !7, i64 0}
!17 = !{!18, !7, i64 12}
!18 = !{!"two", !6, i64 0, !7, i64 4, !6, i64 8, !7, i64 12}
!19 = !{!20, !7, i64 2}
!20 = !{!"five", !7, i64 0, !7, i64 1, !7, i64 2}
!21 = !{!22, !7, i64 5}
!22 = !{!"six", !7, i64 0, !7, i64 4, !7, i64 5}
!23 = !{!24, !7, i64 2}
!24 = !{!"seven", !7, i64 0, !7, i64 1, !7, i64 2}
!25 = !{!26, !7, i64 2}
!26 = !{!"eight", !16, i64 0, !7, i64 2}
!27 = !{!28, !7, i64 8}
!28 = !{!"ten", !29, i64 0, !29, i64 0, !7, i64 8}
!29 = !{!"long long", !7, i64 0}
