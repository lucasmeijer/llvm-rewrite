; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c
; @opt: -O2
; @llc: -O2
; @generated: clang -O2 -Xclang -disable-llvm-passes -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = internal constant [8 x [3 x double]] [[3 x double] [double f0x3FD8C637FD3B6253, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FE725849423E3E0, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FF000011136AEF5, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FF860FD96F0D223, double 3.000000e-10, double 0.000000e+00], [3 x double] [double f0x4014CF7737365089, double 1.913200e-06, double -3.900000e-09], [3 x double] [double f0x40231C1D0EBB7C0F, double -2.138960e-05, double 4.440000e-08], [3 x double] [double f0x403337EC14C35EFA, double -3.716000e-07, double f0x3E7A47A3038502A4], [3 x double] [double f0x403E1C425059FB17, double -1.663500e-06, double 6.860000e-08]], align 16
@dlm = internal constant [8 x [3 x double]] [[3 x double] [double f0x406F88076B035926, double f0x41F40BBCADEE3CB4, double -1.927890e+00], [3 x double] [double f0x4066BF5A874FEAFA, double f0x41DF6432F5157881, double 5.938100e-01], [3 x double] [double f0x40591DDA6DBF7622, double f0x41D34FC2F3B56502, double -2.044110e+00], [3 x double] [double f0x407636ED90F7B482, double f0x41C4890A4B784DFD, double 9.426400e-01], [3 x double] [double f0x40412CFE90EA1D96, double f0x419A0C7E6F1EA0BA, double f0xC03E9A915379FA98], [3 x double] [double f0x404909E9B1DFE17D, double f0x4184FA9E14756430, double f0x4052E76ED677707A], [3 x double] [double f0x4073A0E14D09C902, double f0x416D6BA57E0EFDCA, double -1.750830e+00], [3 x double] [double f0x4073059422411D82, double f0x415E0127CD46B26C, double 2.110300e-01]], align 16
@e = internal constant [8 x [3 x double]] [[3 x double] [double f0x3FCA52242A37D430, double f0x3F2ABF4B9459E7F4, double -2.834900e-06], [3 x double] [double f0x3F7BBCDE77820827, double f0xBF3F4DAC25FB4BC2, double 9.812700e-06], [3 x double] [double f0x3F911C1175CC9F7B, double f0xBF3B8C8FA536F731, double -1.267340e-05], [3 x double] [double f0x3FB7E91AD74BF5B0, double f0x3F4DA66143B5E407, double -8.064100e-06], [3 x double] [double f0x3FA8D4B857E48742, double f0x3F5ABE2B9A18B7B5, double -4.713660e-05], [3 x double] [double f0x3FAC70CE5FA41E66, double f0xBF6C6594A86FD58E, double -6.436390e-05], [3 x double] [double f0x3FA7BF479022D287, double f0xBF31E2FE6AE927D8, double 7.891300e-06], [3 x double] [double f0x3F835D88E0FE76D8, double 6.032630e-05, double 0.000000e+00]], align 16
@pi = internal constant [8 x [3 x double]] [[3 x double] [double f0x40535D310DE9F882, double f0x40B6571DAB9F559B, double -4.830160e+00], [3 x double] [double f0x40607209DADFB507, double f0x4065EF9096BB98C8, double f0xC07F27B59DDC1E79], [3 x double] [double f0x4059BBFD82CD2461, double f0x40C6AE2D2BD3C361, double f0x404AA34C6E6D9BE5], [3 x double] [double f0x407500F6B7DFD5BE, double f0x40CF363AC3222920, double -6.232800e+01], [3 x double] [double f0x402CA993F265B897, double f0x40BE4EC06AD2DCB1, double f0x40703F599ED7C6FC], [3 x double] [double f0x405743A9C7642D26, double f0x40D3EADFA415F45E, double f0x4067C84DFCE3150E], [3 x double] [double f0x4065A02B58283528, double f0x40A91F1FF04577D9, double f0xC0410BE37DE939EB], [3 x double] [double f0x40480F65305B6785, double f0x40906AE060FE4799, double f0x403B65ACEEE0F3CB]], align 16
@dinc = internal constant [8 x [3 x double]] [[3 x double] [double f0x401C051B1D92B7FE, double f0xC06AC83387160957, double 2.897700e-01], [3 x double] [double f0x400B28447E34386C, double f0xC03ED828A1DFB939, double f0xC0275B52007DD441], [3 x double] [double 0.000000e+00, double f0x407D5F90F51AC9B0, double -3.350530e+00], [3 x double] [double f0x3FFD987ACB2252BB, double f0xC072551355475A32, double -8.118300e+00], [3 x double] [double f0x3FF4DA2E7A10E830, double f0xC051E3C504816F00, double f0x4027E7EBAF102364], [3 x double] [double f0x4003E939471E778F, double f0x4056F686594AF4F1, double f0xC031A989374BC6A8], [3 x double] [double f0x3FE8BE07677D67B5, double f0xC04E5D15DF6555C5, double 1.257590e+00], [3 x double] [double f0x3FFC51B9CE9853F4, double f0x40203F251C193B3A, double 8.135000e-02]], align 16
@omega = internal constant [8 x [3 x double]] [[3 x double] [double f0x40482A5AB400A313, double f0xC0B1A3379F01B867, double f0xC03FCC8605681ECD], [3 x double] [double f0x40532B83CFF8FC2B, double f0xC0C38C3DA31A4BDC, double f0xC049A9BEF49CF56F], [3 x double] [double f0x4065DBF10E4FF9E8, double f0xC0C0F3A29A804966, double f0x402EAF0ED3D859C9], [3 x double] [double f0x4048C76F992A88EB, double f0xC0C4BE7350092CCF, double f0xC06CD25F84CAD57C], [3 x double] [double f0x40591DB8D838BBB3, double f0x40B8DA091DBCA969, double f0x4074685935FC3B4F], [3 x double] [double f0x405C6A9797E1B38F, double f0xC0C20C1986983516, double f0xC0508F320D9945B7], [3 x double] [double f0x405280619982C872, double f0x40A4DA4CF80DC337, double f0x40623E1187E7C06E], [3 x double] [double f0x40607916FEBF632D, double f0xC06BBE2EDBB59DDC, double -7.872800e-01]], align 16
@kp = internal constant [8 x [9 x double]] [[9 x double] [double 6.961300e+04, double 7.564500e+04, double 8.830600e+04, double 5.989900e+04, double 1.574600e+04, double 7.108700e+04, double 1.421730e+05, double 3.086000e+03, double 0.000000e+00], [9 x double] [double 2.186300e+04, double 3.279400e+04, double 2.693400e+04, double 1.093100e+04, double 2.625000e+04, double 4.372500e+04, double 5.386700e+04, double 2.893900e+04, double 0.000000e+00], [9 x double] [double 1.600200e+04, double 2.186300e+04, double 3.200400e+04, double 1.093100e+04, double 1.452900e+04, double 1.636800e+04, double 1.531800e+04, double 3.279400e+04, double 0.000000e+00], [9 x double] [double 6.345000e+03, double 7.818000e+03, double 1.563600e+04, double 7.077000e+03, double 8.184000e+03, double 1.416300e+04, double 1.107000e+03, double 4.872000e+03, double 0.000000e+00], [9 x double] [double 1.760000e+03, double 1.454000e+03, double 1.167000e+03, double 8.800000e+02, double 2.870000e+02, double 2.640000e+03, double 1.900000e+01, double 2.047000e+03, double 1.454000e+03], [9 x double] [double 5.740000e+02, double 0.000000e+00, double 8.800000e+02, double 2.870000e+02, double 1.900000e+01, double 1.760000e+03, double 1.167000e+03, double 3.060000e+02, double 5.740000e+02], [9 x double] [double 2.040000e+02, double 0.000000e+00, double 1.770000e+02, double 1.265000e+03, double 4.000000e+00, double 3.850000e+02, double 2.000000e+02, double 2.080000e+02, double 2.040000e+02], [9 x double] [double 0.000000e+00, double 1.020000e+02, double 1.060000e+02, double 4.000000e+00, double 9.800000e+01, double 1.367000e+03, double 4.870000e+02, double 2.040000e+02, double 0.000000e+00]], align 16
@kq = internal constant [8 x [10 x double]] [[10 x double] [double 3.086000e+03, double 1.574600e+04, double 6.961300e+04, double 5.989900e+04, double 7.564500e+04, double 8.830600e+04, double 1.266100e+04, double 2.658000e+03, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 2.186300e+04, double 3.279400e+04, double 1.093100e+04, double 7.300000e+01, double 4.387000e+03, double 2.693400e+04, double 1.473000e+03, double 2.157000e+03, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 1.000000e+01, double 1.600200e+04, double 2.186300e+04, double 1.093100e+04, double 1.473000e+03, double 3.200400e+04, double 4.387000e+03, double 7.300000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 1.000000e+01, double 6.345000e+03, double 7.818000e+03, double 1.107000e+03, double 1.563600e+04, double 7.077000e+03, double 8.184000e+03, double 5.320000e+02, double 1.000000e+01, double 0.000000e+00], [10 x double] [double 1.900000e+01, double 1.760000e+03, double 1.454000e+03, double 2.870000e+02, double 1.167000e+03, double 8.800000e+02, double 5.740000e+02, double 2.640000e+03, double 1.900000e+01, double 1.454000e+03], [10 x double] [double 1.900000e+01, double 5.740000e+02, double 2.870000e+02, double 3.060000e+02, double 1.760000e+03, double 1.200000e+01, double 3.100000e+01, double 3.800000e+01, double 1.900000e+01, double 5.740000e+02], [10 x double] [double 4.000000e+00, double 2.040000e+02, double 1.770000e+02, double 8.000000e+00, double 3.100000e+01, double 2.000000e+02, double 1.265000e+03, double 1.020000e+02, double 4.000000e+00, double 2.040000e+02], [10 x double] [double 4.000000e+00, double 1.020000e+02, double 1.060000e+02, double 8.000000e+00, double 9.800000e+01, double 1.367000e+03, double 4.870000e+02, double 2.040000e+02, double 4.000000e+00, double 1.020000e+02]], align 16
@ca = internal constant [8 x [9 x double]] [[9 x double] [double 4.000000e+00, double -1.300000e+01, double 1.100000e+01, double -9.000000e+00, double -9.000000e+00, double -3.000000e+00, double -1.000000e+00, double 4.000000e+00, double 0.000000e+00], [9 x double] [double -1.560000e+02, double 5.900000e+01, double -4.200000e+01, double 6.000000e+00, double 1.900000e+01, double -2.000000e+01, double -1.000000e+01, double -1.200000e+01, double 0.000000e+00], [9 x double] [double 6.400000e+01, double -1.520000e+02, double 6.200000e+01, double -8.000000e+00, double 3.200000e+01, double -4.100000e+01, double 1.900000e+01, double -1.100000e+01, double 0.000000e+00], [9 x double] [double 1.240000e+02, double 6.210000e+02, double -1.450000e+02, double 2.080000e+02, double 5.400000e+01, double -5.700000e+01, double 3.000000e+01, double 1.500000e+01, double 0.000000e+00], [9 x double] [double -2.343700e+04, double -2.634000e+03, double 6.601000e+03, double 6.259000e+03, double -1.507000e+03, double -1.821000e+03, double 2.620000e+03, double -2.115000e+03, double -1.489000e+03], [9 x double] [double 6.291100e+04, double -1.199190e+05, double 7.933600e+04, double 1.781400e+04, double -2.424100e+04, double 1.206800e+04, double 8.306000e+03, double -4.893000e+03, double 8.902000e+03], [9 x double] [double 3.890610e+05, double -2.621250e+05, double -4.408800e+04, double 8.387000e+03, double -2.297600e+04, double -2.093000e+03, double -6.150000e+02, double -9.720000e+03, double 6.633000e+03], [9 x double] [double -4.122350e+05, double -1.570460e+05, double -3.143000e+04, double 3.781700e+04, double -9.740000e+03, double -1.300000e+01, double -7.449000e+03, double 9.644000e+03, double 0.000000e+00]], align 16
@sa = internal constant [8 x [9 x double]] [[9 x double] [double -2.900000e+01, double -1.000000e+00, double 9.000000e+00, double 6.000000e+00, double -6.000000e+00, double 5.000000e+00, double 4.000000e+00, double 0.000000e+00, double 0.000000e+00], [9 x double] [double -4.800000e+01, double -1.250000e+02, double -2.600000e+01, double -3.700000e+01, double 1.800000e+01, double -1.300000e+01, double -2.000000e+01, double -2.000000e+00, double 0.000000e+00], [9 x double] [double -1.500000e+02, double -4.600000e+01, double 6.800000e+01, double 5.400000e+01, double 1.400000e+01, double 2.400000e+01, double -2.800000e+01, double 2.200000e+01, double 0.000000e+00], [9 x double] [double -6.210000e+02, double 5.320000e+02, double -6.940000e+02, double -2.000000e+01, double 1.920000e+02, double -9.400000e+01, double 7.100000e+01, double -7.300000e+01, double 0.000000e+00], [9 x double] [double -1.461400e+04, double -1.982800e+04, double -5.869000e+03, double 1.881000e+03, double -4.372000e+03, double -2.255000e+03, double 7.820000e+02, double 9.300000e+02, double 9.130000e+02], [9 x double] [double 1.397370e+05, double 0.000000e+00, double 2.466700e+04, double 5.112300e+04, double -5.102000e+03, double 7.429000e+03, double -4.095000e+03, double -1.976000e+03, double -9.566000e+03], [9 x double] [double -1.380810e+05, double 0.000000e+00, double 3.720500e+04, double -4.903900e+04, double -4.190100e+04, double -3.387200e+04, double -2.703700e+04, double -1.247400e+04, double 1.879700e+04], [9 x double] [double 0.000000e+00, double 2.849200e+04, double 1.332360e+05, double 6.965400e+04, double 5.232200e+04, double -4.957700e+04, double -2.643000e+04, double -3.593000e+03, double 0.000000e+00]], align 16
@cl = internal constant [8 x [10 x double]] [[10 x double] [double 2.100000e+01, double -9.500000e+01, double -1.570000e+02, double 4.100000e+01, double -5.000000e+00, double 4.200000e+01, double 2.300000e+01, double 3.000000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -1.600000e+02, double -3.130000e+02, double -2.350000e+02, double 6.000000e+01, double -7.400000e+01, double -7.600000e+01, double -2.700000e+01, double 3.400000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -3.250000e+02, double -3.220000e+02, double -7.900000e+01, double 2.320000e+02, double -5.200000e+01, double 9.700000e+01, double 5.500000e+01, double -4.100000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 2.268000e+03, double -9.790000e+02, double 8.020000e+02, double 6.020000e+02, double -6.680000e+02, double -3.300000e+01, double 3.450000e+02, double 2.010000e+02, double -5.500000e+01, double 0.000000e+00], [10 x double] [double 7.610000e+03, double -4.997000e+03, double -7.689000e+03, double -5.841000e+03, double -2.617000e+03, double 1.115000e+03, double -7.480000e+02, double -6.070000e+02, double 6.074000e+03, double 3.540000e+02], [10 x double] [double -1.854900e+04, double 3.012500e+04, double 2.001200e+04, double -7.300000e+02, double 8.240000e+02, double 2.300000e+01, double 1.289000e+03, double -3.520000e+02, double -1.476700e+04, double -2.062000e+03], [10 x double] [double -1.352450e+05, double -1.459400e+04, double 4.197000e+03, double -4.030000e+03, double -5.630000e+03, double -2.898000e+03, double 2.540000e+03, double -3.060000e+02, double 2.939000e+03, double 1.986000e+03], [10 x double] [double 8.994800e+04, double 2.103000e+03, double 8.963000e+03, double 2.695000e+03, double 3.682000e+03, double 1.648000e+03, double 8.660000e+02, double -1.540000e+02, double -1.963000e+03, double -2.830000e+02]], align 16
@sl = internal constant [8 x [10 x double]] [[10 x double] [double -3.420000e+02, double 1.360000e+02, double -2.300000e+01, double 6.200000e+01, double 6.600000e+01, double -5.200000e+01, double -3.300000e+01, double 1.700000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 5.240000e+02, double -1.490000e+02, double -3.500000e+01, double 1.170000e+02, double 1.510000e+02, double 1.220000e+02, double -7.100000e+01, double -6.200000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -1.050000e+02, double -1.370000e+02, double 2.580000e+02, double 3.500000e+01, double -1.160000e+02, double -8.800000e+01, double -1.120000e+02, double -8.000000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 8.540000e+02, double -2.050000e+02, double -9.360000e+02, double -2.400000e+02, double 1.400000e+02, double -3.410000e+02, double -9.700000e+01, double -2.320000e+02, double 5.360000e+02, double 0.000000e+00], [10 x double] [double -5.698000e+04, double 8.016000e+03, double 1.012000e+03, double 1.448000e+03, double -3.024000e+03, double -3.710000e+03, double 3.180000e+02, double 5.030000e+02, double 3.767000e+03, double 5.770000e+02], [10 x double] [double 1.386060e+05, double -1.347800e+04, double -4.964000e+03, double 1.441000e+03, double -1.319000e+03, double -1.482000e+03, double 4.270000e+02, double 1.236000e+03, double -9.167000e+03, double -1.918000e+03], [10 x double] [double 7.123400e+04, double -4.111600e+04, double 5.334000e+03, double -4.935000e+03, double -1.848000e+03, double 6.600000e+01, double 4.340000e+02, double -1.748000e+03, double 3.780000e+03, double -7.010000e+02], [10 x double] [double -4.764500e+04, double 1.164700e+04, double 2.166000e+03, double 3.194000e+03, double 6.790000e+02, double 0.000000e+00, double -2.440000e+02, double -4.190000e+02, double -2.531000e+03, double 4.800000e+01]], align 16
@amas = internal constant [8 x double] [double 6.023600e+06, double f0x4118EF2E00000000, double f0x4114131200000000, double 3.098710e+06, double f0x40905D6B851EB852, double 3.498500e+03, double 2.286900e+04, double 1.931400e+04], align 16
@.str = private unnamed_addr constant [4 x i8] c"-ga\00", align 1
@.str.1 = private unnamed_addr constant [10 x i8] c"%f %f %f\0A\00", align 1
@stdout = external global ptr, align 8

; Function Attrs: nounwind uwtable
define dso_local double @anpm(double noundef %0) #0 {
  %2 = alloca double, align 8
  %3 = alloca double, align 8
  store double %0, ptr %2, align 8, !tbaa !9
  call void @llvm.lifetime.start.p0(ptr %3) #6
  %4 = load double, ptr %2, align 8, !tbaa !9
  %5 = call double @fmod(double noundef %4, double noundef f0x401921FB54442D18) #6
  store double %5, ptr %3, align 8, !tbaa !9
  %6 = load double, ptr %3, align 8, !tbaa !9
  %7 = call double @llvm.fabs.f64(double %6)
  %8 = fcmp oge double %7, f0x400921FB54442D18
  br i1 %8, label %9, label %16

9:                                                ; preds = %1
  %10 = load double, ptr %3, align 8, !tbaa !9
  %11 = load double, ptr %2, align 8, !tbaa !9
  %12 = fcmp olt double %11, 0.000000e+00
  %13 = zext i1 %12 to i64
  %14 = select i1 %12, double f0xC01921FB54442D18, double f0x401921FB54442D18
  %15 = fsub double %10, %14
  store double %15, ptr %3, align 8, !tbaa !9
  br label %16

16:                                               ; preds = %9, %1
  %17 = load double, ptr %3, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %3) #6
  ret double %17
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nounwind
declare double @fmod(double noundef, double noundef) #2

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nounwind uwtable
define dso_local void @planetpv(ptr noundef %0, i32 noundef %1, ptr noundef %2) #0 {
  %4 = alloca ptr, align 8
  %5 = alloca i32, align 4
  %6 = alloca ptr, align 8
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca i32, align 4
  %10 = alloca double, align 8
  %11 = alloca double, align 8
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
  %22 = alloca double, align 8
  %23 = alloca double, align 8
  %24 = alloca double, align 8
  %25 = alloca double, align 8
  %26 = alloca double, align 8
  %27 = alloca double, align 8
  %28 = alloca double, align 8
  %29 = alloca double, align 8
  %30 = alloca double, align 8
  %31 = alloca double, align 8
  %32 = alloca double, align 8
  %33 = alloca double, align 8
  %34 = alloca double, align 8
  %35 = alloca double, align 8
  %36 = alloca double, align 8
  %37 = alloca double, align 8
  %38 = alloca double, align 8
  %39 = alloca double, align 8
  %40 = alloca double, align 8
  %41 = alloca double, align 8
  store ptr %0, ptr %4, align 8, !tbaa !11
  store i32 %1, ptr %5, align 4, !tbaa !14
  store ptr %2, ptr %6, align 8, !tbaa !11
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  call void @llvm.lifetime.start.p0(ptr %10) #6
  call void @llvm.lifetime.start.p0(ptr %11) #6
  call void @llvm.lifetime.start.p0(ptr %12) #6
  call void @llvm.lifetime.start.p0(ptr %13) #6
  call void @llvm.lifetime.start.p0(ptr %14) #6
  call void @llvm.lifetime.start.p0(ptr %15) #6
  call void @llvm.lifetime.start.p0(ptr %16) #6
  call void @llvm.lifetime.start.p0(ptr %17) #6
  call void @llvm.lifetime.start.p0(ptr %18) #6
  call void @llvm.lifetime.start.p0(ptr %19) #6
  call void @llvm.lifetime.start.p0(ptr %20) #6
  call void @llvm.lifetime.start.p0(ptr %21) #6
  call void @llvm.lifetime.start.p0(ptr %22) #6
  call void @llvm.lifetime.start.p0(ptr %23) #6
  call void @llvm.lifetime.start.p0(ptr %24) #6
  call void @llvm.lifetime.start.p0(ptr %25) #6
  call void @llvm.lifetime.start.p0(ptr %26) #6
  call void @llvm.lifetime.start.p0(ptr %27) #6
  call void @llvm.lifetime.start.p0(ptr %28) #6
  call void @llvm.lifetime.start.p0(ptr %29) #6
  call void @llvm.lifetime.start.p0(ptr %30) #6
  call void @llvm.lifetime.start.p0(ptr %31) #6
  call void @llvm.lifetime.start.p0(ptr %32) #6
  call void @llvm.lifetime.start.p0(ptr %33) #6
  call void @llvm.lifetime.start.p0(ptr %34) #6
  call void @llvm.lifetime.start.p0(ptr %35) #6
  call void @llvm.lifetime.start.p0(ptr %36) #6
  call void @llvm.lifetime.start.p0(ptr %37) #6
  call void @llvm.lifetime.start.p0(ptr %38) #6
  call void @llvm.lifetime.start.p0(ptr %39) #6
  call void @llvm.lifetime.start.p0(ptr %40) #6
  call void @llvm.lifetime.start.p0(ptr %41) #6
  %42 = load ptr, ptr %4, align 8, !tbaa !11
  %43 = getelementptr inbounds double, ptr %42, i64 0
  %44 = load double, ptr %43, align 8, !tbaa !9
  %45 = fsub double %44, f0x4142B42C80000000
  %46 = load ptr, ptr %4, align 8, !tbaa !11
  %47 = getelementptr inbounds double, ptr %46, i64 1
  %48 = load double, ptr %47, align 8, !tbaa !9
  %49 = fadd double %45, %48
  %50 = fdiv double %49, 3.652500e+05
  store double %50, ptr %10, align 8, !tbaa !9
  %51 = load i32, ptr %5, align 4, !tbaa !14
  %52 = sext i32 %51 to i64
  %53 = getelementptr inbounds [8 x [3 x double]], ptr @a, i64 0, i64 %52
  %54 = getelementptr inbounds [3 x double], ptr %53, i64 0, i64 0
  %55 = load double, ptr %54, align 8, !tbaa !9
  %56 = load i32, ptr %5, align 4, !tbaa !14
  %57 = sext i32 %56 to i64
  %58 = getelementptr inbounds [8 x [3 x double]], ptr @a, i64 0, i64 %57
  %59 = getelementptr inbounds [3 x double], ptr %58, i64 0, i64 1
  %60 = load double, ptr %59, align 8, !tbaa !9
  %61 = load i32, ptr %5, align 4, !tbaa !14
  %62 = sext i32 %61 to i64
  %63 = getelementptr inbounds [8 x [3 x double]], ptr @a, i64 0, i64 %62
  %64 = getelementptr inbounds [3 x double], ptr %63, i64 0, i64 2
  %65 = load double, ptr %64, align 8, !tbaa !9
  %66 = load double, ptr %10, align 8, !tbaa !9
  %67 = call double @llvm.fmuladd.f64(double %65, double %66, double %60)
  %68 = load double, ptr %10, align 8, !tbaa !9
  %69 = call double @llvm.fmuladd.f64(double %67, double %68, double %55)
  store double %69, ptr %11, align 8, !tbaa !9
  %70 = load i32, ptr %5, align 4, !tbaa !14
  %71 = sext i32 %70 to i64
  %72 = getelementptr inbounds [8 x [3 x double]], ptr @dlm, i64 0, i64 %71
  %73 = getelementptr inbounds [3 x double], ptr %72, i64 0, i64 0
  %74 = load double, ptr %73, align 8, !tbaa !9
  %75 = load i32, ptr %5, align 4, !tbaa !14
  %76 = sext i32 %75 to i64
  %77 = getelementptr inbounds [8 x [3 x double]], ptr @dlm, i64 0, i64 %76
  %78 = getelementptr inbounds [3 x double], ptr %77, i64 0, i64 1
  %79 = load double, ptr %78, align 8, !tbaa !9
  %80 = load i32, ptr %5, align 4, !tbaa !14
  %81 = sext i32 %80 to i64
  %82 = getelementptr inbounds [8 x [3 x double]], ptr @dlm, i64 0, i64 %81
  %83 = getelementptr inbounds [3 x double], ptr %82, i64 0, i64 2
  %84 = load double, ptr %83, align 8, !tbaa !9
  %85 = load double, ptr %10, align 8, !tbaa !9
  %86 = call double @llvm.fmuladd.f64(double %84, double %85, double %79)
  %87 = load double, ptr %10, align 8, !tbaa !9
  %88 = fmul double %86, %87
  %89 = call double @llvm.fmuladd.f64(double 3.600000e+03, double %74, double %88)
  %90 = fmul double %89, f0x3ED455A5B2FF8F9D
  store double %90, ptr %12, align 8, !tbaa !9
  %91 = load i32, ptr %5, align 4, !tbaa !14
  %92 = sext i32 %91 to i64
  %93 = getelementptr inbounds [8 x [3 x double]], ptr @e, i64 0, i64 %92
  %94 = getelementptr inbounds [3 x double], ptr %93, i64 0, i64 0
  %95 = load double, ptr %94, align 8, !tbaa !9
  %96 = load i32, ptr %5, align 4, !tbaa !14
  %97 = sext i32 %96 to i64
  %98 = getelementptr inbounds [8 x [3 x double]], ptr @e, i64 0, i64 %97
  %99 = getelementptr inbounds [3 x double], ptr %98, i64 0, i64 1
  %100 = load double, ptr %99, align 8, !tbaa !9
  %101 = load i32, ptr %5, align 4, !tbaa !14
  %102 = sext i32 %101 to i64
  %103 = getelementptr inbounds [8 x [3 x double]], ptr @e, i64 0, i64 %102
  %104 = getelementptr inbounds [3 x double], ptr %103, i64 0, i64 2
  %105 = load double, ptr %104, align 8, !tbaa !9
  %106 = load double, ptr %10, align 8, !tbaa !9
  %107 = call double @llvm.fmuladd.f64(double %105, double %106, double %100)
  %108 = load double, ptr %10, align 8, !tbaa !9
  %109 = call double @llvm.fmuladd.f64(double %107, double %108, double %95)
  store double %109, ptr %13, align 8, !tbaa !9
  %110 = load i32, ptr %5, align 4, !tbaa !14
  %111 = sext i32 %110 to i64
  %112 = getelementptr inbounds [8 x [3 x double]], ptr @pi, i64 0, i64 %111
  %113 = getelementptr inbounds [3 x double], ptr %112, i64 0, i64 0
  %114 = load double, ptr %113, align 8, !tbaa !9
  %115 = load i32, ptr %5, align 4, !tbaa !14
  %116 = sext i32 %115 to i64
  %117 = getelementptr inbounds [8 x [3 x double]], ptr @pi, i64 0, i64 %116
  %118 = getelementptr inbounds [3 x double], ptr %117, i64 0, i64 1
  %119 = load double, ptr %118, align 8, !tbaa !9
  %120 = load i32, ptr %5, align 4, !tbaa !14
  %121 = sext i32 %120 to i64
  %122 = getelementptr inbounds [8 x [3 x double]], ptr @pi, i64 0, i64 %121
  %123 = getelementptr inbounds [3 x double], ptr %122, i64 0, i64 2
  %124 = load double, ptr %123, align 8, !tbaa !9
  %125 = load double, ptr %10, align 8, !tbaa !9
  %126 = call double @llvm.fmuladd.f64(double %124, double %125, double %119)
  %127 = load double, ptr %10, align 8, !tbaa !9
  %128 = fmul double %126, %127
  %129 = call double @llvm.fmuladd.f64(double 3.600000e+03, double %114, double %128)
  %130 = fmul double %129, f0x3ED455A5B2FF8F9D
  %131 = call double @anpm(double noundef %130)
  store double %131, ptr %14, align 8, !tbaa !9
  %132 = load i32, ptr %5, align 4, !tbaa !14
  %133 = sext i32 %132 to i64
  %134 = getelementptr inbounds [8 x [3 x double]], ptr @dinc, i64 0, i64 %133
  %135 = getelementptr inbounds [3 x double], ptr %134, i64 0, i64 0
  %136 = load double, ptr %135, align 8, !tbaa !9
  %137 = load i32, ptr %5, align 4, !tbaa !14
  %138 = sext i32 %137 to i64
  %139 = getelementptr inbounds [8 x [3 x double]], ptr @dinc, i64 0, i64 %138
  %140 = getelementptr inbounds [3 x double], ptr %139, i64 0, i64 1
  %141 = load double, ptr %140, align 8, !tbaa !9
  %142 = load i32, ptr %5, align 4, !tbaa !14
  %143 = sext i32 %142 to i64
  %144 = getelementptr inbounds [8 x [3 x double]], ptr @dinc, i64 0, i64 %143
  %145 = getelementptr inbounds [3 x double], ptr %144, i64 0, i64 2
  %146 = load double, ptr %145, align 8, !tbaa !9
  %147 = load double, ptr %10, align 8, !tbaa !9
  %148 = call double @llvm.fmuladd.f64(double %146, double %147, double %141)
  %149 = load double, ptr %10, align 8, !tbaa !9
  %150 = fmul double %148, %149
  %151 = call double @llvm.fmuladd.f64(double 3.600000e+03, double %136, double %150)
  %152 = fmul double %151, f0x3ED455A5B2FF8F9D
  store double %152, ptr %15, align 8, !tbaa !9
  %153 = load i32, ptr %5, align 4, !tbaa !14
  %154 = sext i32 %153 to i64
  %155 = getelementptr inbounds [8 x [3 x double]], ptr @omega, i64 0, i64 %154
  %156 = getelementptr inbounds [3 x double], ptr %155, i64 0, i64 0
  %157 = load double, ptr %156, align 8, !tbaa !9
  %158 = load i32, ptr %5, align 4, !tbaa !14
  %159 = sext i32 %158 to i64
  %160 = getelementptr inbounds [8 x [3 x double]], ptr @omega, i64 0, i64 %159
  %161 = getelementptr inbounds [3 x double], ptr %160, i64 0, i64 1
  %162 = load double, ptr %161, align 8, !tbaa !9
  %163 = load i32, ptr %5, align 4, !tbaa !14
  %164 = sext i32 %163 to i64
  %165 = getelementptr inbounds [8 x [3 x double]], ptr @omega, i64 0, i64 %164
  %166 = getelementptr inbounds [3 x double], ptr %165, i64 0, i64 2
  %167 = load double, ptr %166, align 8, !tbaa !9
  %168 = load double, ptr %10, align 8, !tbaa !9
  %169 = call double @llvm.fmuladd.f64(double %167, double %168, double %162)
  %170 = load double, ptr %10, align 8, !tbaa !9
  %171 = fmul double %169, %170
  %172 = call double @llvm.fmuladd.f64(double 3.600000e+03, double %157, double %171)
  %173 = fmul double %172, f0x3ED455A5B2FF8F9D
  %174 = call double @anpm(double noundef %173)
  store double %174, ptr %16, align 8, !tbaa !9
  %175 = load double, ptr %10, align 8, !tbaa !9
  %176 = fmul double f0x3FD702A41F2E9970, %175
  store double %176, ptr %17, align 8, !tbaa !9
  store i32 0, ptr %9, align 4, !tbaa !14
  br label %177

177:                                              ; preds = %243, %3
  %178 = load i32, ptr %9, align 4, !tbaa !14
  %179 = icmp slt i32 %178, 8
  br i1 %179, label %180, label %246

180:                                              ; preds = %177
  %181 = load i32, ptr %5, align 4, !tbaa !14
  %182 = sext i32 %181 to i64
  %183 = getelementptr inbounds [8 x [9 x double]], ptr @kp, i64 0, i64 %182
  %184 = load i32, ptr %9, align 4, !tbaa !14
  %185 = sext i32 %184 to i64
  %186 = getelementptr inbounds [9 x double], ptr %183, i64 0, i64 %185
  %187 = load double, ptr %186, align 8, !tbaa !9
  %188 = load double, ptr %17, align 8, !tbaa !9
  %189 = fmul double %187, %188
  store double %189, ptr %18, align 8, !tbaa !9
  %190 = load i32, ptr %5, align 4, !tbaa !14
  %191 = sext i32 %190 to i64
  %192 = getelementptr inbounds [8 x [10 x double]], ptr @kq, i64 0, i64 %191
  %193 = load i32, ptr %9, align 4, !tbaa !14
  %194 = sext i32 %193 to i64
  %195 = getelementptr inbounds [10 x double], ptr %192, i64 0, i64 %194
  %196 = load double, ptr %195, align 8, !tbaa !9
  %197 = load double, ptr %17, align 8, !tbaa !9
  %198 = fmul double %196, %197
  store double %198, ptr %19, align 8, !tbaa !9
  %199 = load double, ptr %11, align 8, !tbaa !9
  %200 = load i32, ptr %5, align 4, !tbaa !14
  %201 = sext i32 %200 to i64
  %202 = getelementptr inbounds [8 x [9 x double]], ptr @ca, i64 0, i64 %201
  %203 = load i32, ptr %9, align 4, !tbaa !14
  %204 = sext i32 %203 to i64
  %205 = getelementptr inbounds [9 x double], ptr %202, i64 0, i64 %204
  %206 = load double, ptr %205, align 8, !tbaa !9
  %207 = load double, ptr %18, align 8, !tbaa !9
  %208 = call double @cos(double noundef %207) #6
  %209 = load i32, ptr %5, align 4, !tbaa !14
  %210 = sext i32 %209 to i64
  %211 = getelementptr inbounds [8 x [9 x double]], ptr @sa, i64 0, i64 %210
  %212 = load i32, ptr %9, align 4, !tbaa !14
  %213 = sext i32 %212 to i64
  %214 = getelementptr inbounds [9 x double], ptr %211, i64 0, i64 %213
  %215 = load double, ptr %214, align 8, !tbaa !9
  %216 = load double, ptr %18, align 8, !tbaa !9
  %217 = call double @sin(double noundef %216) #6
  %218 = fmul double %215, %217
  %219 = call double @llvm.fmuladd.f64(double %206, double %208, double %218)
  %220 = call double @llvm.fmuladd.f64(double %219, double f0x3E7AD7F29ABCAF48, double %199)
  store double %220, ptr %11, align 8, !tbaa !9
  %221 = load double, ptr %12, align 8, !tbaa !9
  %222 = load i32, ptr %5, align 4, !tbaa !14
  %223 = sext i32 %222 to i64
  %224 = getelementptr inbounds [8 x [10 x double]], ptr @cl, i64 0, i64 %223
  %225 = load i32, ptr %9, align 4, !tbaa !14
  %226 = sext i32 %225 to i64
  %227 = getelementptr inbounds [10 x double], ptr %224, i64 0, i64 %226
  %228 = load double, ptr %227, align 8, !tbaa !9
  %229 = load double, ptr %19, align 8, !tbaa !9
  %230 = call double @cos(double noundef %229) #6
  %231 = load i32, ptr %5, align 4, !tbaa !14
  %232 = sext i32 %231 to i64
  %233 = getelementptr inbounds [8 x [10 x double]], ptr @sl, i64 0, i64 %232
  %234 = load i32, ptr %9, align 4, !tbaa !14
  %235 = sext i32 %234 to i64
  %236 = getelementptr inbounds [10 x double], ptr %233, i64 0, i64 %235
  %237 = load double, ptr %236, align 8, !tbaa !9
  %238 = load double, ptr %19, align 8, !tbaa !9
  %239 = call double @sin(double noundef %238) #6
  %240 = fmul double %237, %239
  %241 = call double @llvm.fmuladd.f64(double %228, double %230, double %240)
  %242 = call double @llvm.fmuladd.f64(double %241, double f0x3E7AD7F29ABCAF48, double %221)
  store double %242, ptr %12, align 8, !tbaa !9
  br label %243

243:                                              ; preds = %180
  %244 = load i32, ptr %9, align 4, !tbaa !14
  %245 = add nsw i32 %244, 1
  store i32 %245, ptr %9, align 4, !tbaa !14
  br label %177, !llvm.loop !15

246:                                              ; preds = %177
  %247 = load i32, ptr %5, align 4, !tbaa !14
  %248 = sext i32 %247 to i64
  %249 = getelementptr inbounds [8 x [9 x double]], ptr @kp, i64 0, i64 %248
  %250 = getelementptr inbounds [9 x double], ptr %249, i64 0, i64 8
  %251 = load double, ptr %250, align 8, !tbaa !9
  %252 = load double, ptr %17, align 8, !tbaa !9
  %253 = fmul double %251, %252
  store double %253, ptr %18, align 8, !tbaa !9
  %254 = load double, ptr %11, align 8, !tbaa !9
  %255 = load double, ptr %10, align 8, !tbaa !9
  %256 = load i32, ptr %5, align 4, !tbaa !14
  %257 = sext i32 %256 to i64
  %258 = getelementptr inbounds [8 x [9 x double]], ptr @ca, i64 0, i64 %257
  %259 = getelementptr inbounds [9 x double], ptr %258, i64 0, i64 8
  %260 = load double, ptr %259, align 8, !tbaa !9
  %261 = load double, ptr %18, align 8, !tbaa !9
  %262 = call double @cos(double noundef %261) #6
  %263 = load i32, ptr %5, align 4, !tbaa !14
  %264 = sext i32 %263 to i64
  %265 = getelementptr inbounds [8 x [9 x double]], ptr @sa, i64 0, i64 %264
  %266 = getelementptr inbounds [9 x double], ptr %265, i64 0, i64 8
  %267 = load double, ptr %266, align 8, !tbaa !9
  %268 = load double, ptr %18, align 8, !tbaa !9
  %269 = call double @sin(double noundef %268) #6
  %270 = fmul double %267, %269
  %271 = call double @llvm.fmuladd.f64(double %260, double %262, double %270)
  %272 = fmul double %255, %271
  %273 = call double @llvm.fmuladd.f64(double %272, double f0x3E7AD7F29ABCAF48, double %254)
  store double %273, ptr %11, align 8, !tbaa !9
  store i32 8, ptr %9, align 4, !tbaa !14
  br label %274

274:                                              ; preds = %311, %246
  %275 = load i32, ptr %9, align 4, !tbaa !14
  %276 = icmp sle i32 %275, 9
  br i1 %276, label %277, label %314

277:                                              ; preds = %274
  %278 = load i32, ptr %5, align 4, !tbaa !14
  %279 = sext i32 %278 to i64
  %280 = getelementptr inbounds [8 x [10 x double]], ptr @kq, i64 0, i64 %279
  %281 = load i32, ptr %9, align 4, !tbaa !14
  %282 = sext i32 %281 to i64
  %283 = getelementptr inbounds [10 x double], ptr %280, i64 0, i64 %282
  %284 = load double, ptr %283, align 8, !tbaa !9
  %285 = load double, ptr %17, align 8, !tbaa !9
  %286 = fmul double %284, %285
  store double %286, ptr %19, align 8, !tbaa !9
  %287 = load double, ptr %12, align 8, !tbaa !9
  %288 = load double, ptr %10, align 8, !tbaa !9
  %289 = load i32, ptr %5, align 4, !tbaa !14
  %290 = sext i32 %289 to i64
  %291 = getelementptr inbounds [8 x [10 x double]], ptr @cl, i64 0, i64 %290
  %292 = load i32, ptr %9, align 4, !tbaa !14
  %293 = sext i32 %292 to i64
  %294 = getelementptr inbounds [10 x double], ptr %291, i64 0, i64 %293
  %295 = load double, ptr %294, align 8, !tbaa !9
  %296 = load double, ptr %19, align 8, !tbaa !9
  %297 = call double @cos(double noundef %296) #6
  %298 = load i32, ptr %5, align 4, !tbaa !14
  %299 = sext i32 %298 to i64
  %300 = getelementptr inbounds [8 x [10 x double]], ptr @sl, i64 0, i64 %299
  %301 = load i32, ptr %9, align 4, !tbaa !14
  %302 = sext i32 %301 to i64
  %303 = getelementptr inbounds [10 x double], ptr %300, i64 0, i64 %302
  %304 = load double, ptr %303, align 8, !tbaa !9
  %305 = load double, ptr %19, align 8, !tbaa !9
  %306 = call double @sin(double noundef %305) #6
  %307 = fmul double %304, %306
  %308 = call double @llvm.fmuladd.f64(double %295, double %297, double %307)
  %309 = fmul double %288, %308
  %310 = call double @llvm.fmuladd.f64(double %309, double f0x3E7AD7F29ABCAF48, double %287)
  store double %310, ptr %12, align 8, !tbaa !9
  br label %311

311:                                              ; preds = %277
  %312 = load i32, ptr %9, align 4, !tbaa !14
  %313 = add nsw i32 %312, 1
  store i32 %313, ptr %9, align 4, !tbaa !14
  br label %274, !llvm.loop !17

314:                                              ; preds = %274
  %315 = load double, ptr %12, align 8, !tbaa !9
  %316 = call double @fmod(double noundef %315, double noundef f0x401921FB54442D18) #6
  store double %316, ptr %12, align 8, !tbaa !9
  %317 = load double, ptr %12, align 8, !tbaa !9
  %318 = load double, ptr %14, align 8, !tbaa !9
  %319 = fsub double %317, %318
  store double %319, ptr %20, align 8, !tbaa !9
  %320 = load double, ptr %20, align 8, !tbaa !9
  %321 = load double, ptr %13, align 8, !tbaa !9
  %322 = load double, ptr %20, align 8, !tbaa !9
  %323 = call double @sin(double noundef %322) #6
  %324 = call double @llvm.fmuladd.f64(double %321, double %323, double %320)
  store double %324, ptr %21, align 8, !tbaa !9
  store i32 0, ptr %9, align 4, !tbaa !14
  br label %325

325:                                              ; preds = %352, %314
  br label %326

326:                                              ; preds = %325
  %327 = load double, ptr %20, align 8, !tbaa !9
  %328 = load double, ptr %21, align 8, !tbaa !9
  %329 = fsub double %327, %328
  %330 = load double, ptr %13, align 8, !tbaa !9
  %331 = load double, ptr %21, align 8, !tbaa !9
  %332 = call double @sin(double noundef %331) #6
  %333 = call double @llvm.fmuladd.f64(double %330, double %332, double %329)
  %334 = load double, ptr %13, align 8, !tbaa !9
  %335 = load double, ptr %21, align 8, !tbaa !9
  %336 = call double @cos(double noundef %335) #6
  %337 = fneg double %334
  %338 = call double @llvm.fmuladd.f64(double %337, double %336, double 1.000000e+00)
  %339 = fdiv double %333, %338
  store double %339, ptr %22, align 8, !tbaa !9
  %340 = load double, ptr %21, align 8, !tbaa !9
  %341 = load double, ptr %22, align 8, !tbaa !9
  %342 = fadd double %340, %341
  store double %342, ptr %21, align 8, !tbaa !9
  %343 = load i32, ptr %9, align 4, !tbaa !14
  %344 = add nsw i32 %343, 1
  store i32 %344, ptr %9, align 4, !tbaa !14
  %345 = load i32, ptr %9, align 4, !tbaa !14
  %346 = icmp sge i32 %345, 10
  br i1 %346, label %351, label %347

347:                                              ; preds = %326
  %348 = load double, ptr %22, align 8, !tbaa !9
  %349 = call double @llvm.fabs.f64(double %348)
  %350 = fcmp olt double %349, f0x3D719799812DEA11
  br i1 %350, label %351, label %352

351:                                              ; preds = %347, %326
  br label %353

352:                                              ; preds = %347
  br label %325

353:                                              ; preds = %351
  %354 = load double, ptr %21, align 8, !tbaa !9
  %355 = fdiv double %354, 2.000000e+00
  store double %355, ptr %23, align 8, !tbaa !9
  %356 = load double, ptr %13, align 8, !tbaa !9
  %357 = fadd double 1.000000e+00, %356
  %358 = load double, ptr %13, align 8, !tbaa !9
  %359 = fsub double 1.000000e+00, %358
  %360 = fdiv double %357, %359
  %361 = call double @sqrt(double noundef %360) #6
  %362 = load double, ptr %23, align 8, !tbaa !9
  %363 = call double @sin(double noundef %362) #6
  %364 = fmul double %361, %363
  %365 = load double, ptr %23, align 8, !tbaa !9
  %366 = call double @cos(double noundef %365) #6
  %367 = call double @atan2(double noundef %364, double noundef %366) #6
  %368 = fmul double 2.000000e+00, %367
  store double %368, ptr %24, align 8, !tbaa !9
  %369 = load double, ptr %11, align 8, !tbaa !9
  %370 = load double, ptr %13, align 8, !tbaa !9
  %371 = load double, ptr %21, align 8, !tbaa !9
  %372 = call double @cos(double noundef %371) #6
  %373 = fneg double %370
  %374 = call double @llvm.fmuladd.f64(double %373, double %372, double 1.000000e+00)
  %375 = fmul double %369, %374
  store double %375, ptr %25, align 8, !tbaa !9
  %376 = load i32, ptr %5, align 4, !tbaa !14
  %377 = sext i32 %376 to i64
  %378 = getelementptr inbounds [8 x double], ptr @amas, i64 0, i64 %377
  %379 = load double, ptr %378, align 8, !tbaa !9
  %380 = fdiv double 1.000000e+00, %379
  %381 = fadd double 1.000000e+00, %380
  %382 = load double, ptr %11, align 8, !tbaa !9
  %383 = load double, ptr %11, align 8, !tbaa !9
  %384 = fmul double %382, %383
  %385 = load double, ptr %11, align 8, !tbaa !9
  %386 = fmul double %384, %385
  %387 = fdiv double %381, %386
  %388 = call double @sqrt(double noundef %387) #6
  %389 = fmul double f0x3F919D6D51A6B69A, %388
  store double %389, ptr %26, align 8, !tbaa !9
  %390 = load double, ptr %15, align 8, !tbaa !9
  %391 = fdiv double %390, 2.000000e+00
  %392 = call double @sin(double noundef %391) #6
  store double %392, ptr %27, align 8, !tbaa !9
  %393 = load double, ptr %27, align 8, !tbaa !9
  %394 = load double, ptr %16, align 8, !tbaa !9
  %395 = call double @cos(double noundef %394) #6
  %396 = fmul double %393, %395
  store double %396, ptr %28, align 8, !tbaa !9
  %397 = load double, ptr %27, align 8, !tbaa !9
  %398 = load double, ptr %16, align 8, !tbaa !9
  %399 = call double @sin(double noundef %398) #6
  %400 = fmul double %397, %399
  store double %400, ptr %29, align 8, !tbaa !9
  %401 = load double, ptr %24, align 8, !tbaa !9
  %402 = load double, ptr %14, align 8, !tbaa !9
  %403 = fadd double %401, %402
  store double %403, ptr %30, align 8, !tbaa !9
  %404 = load double, ptr %30, align 8, !tbaa !9
  %405 = call double @sin(double noundef %404) #6
  store double %405, ptr %31, align 8, !tbaa !9
  %406 = load double, ptr %30, align 8, !tbaa !9
  %407 = call double @cos(double noundef %406) #6
  store double %407, ptr %32, align 8, !tbaa !9
  %408 = load double, ptr %29, align 8, !tbaa !9
  %409 = load double, ptr %32, align 8, !tbaa !9
  %410 = load double, ptr %28, align 8, !tbaa !9
  %411 = load double, ptr %31, align 8, !tbaa !9
  %412 = fmul double %410, %411
  %413 = fneg double %412
  %414 = call double @llvm.fmuladd.f64(double %408, double %409, double %413)
  %415 = fmul double 2.000000e+00, %414
  store double %415, ptr %33, align 8, !tbaa !9
  %416 = load double, ptr %11, align 8, !tbaa !9
  %417 = load double, ptr %13, align 8, !tbaa !9
  %418 = load double, ptr %13, align 8, !tbaa !9
  %419 = fneg double %417
  %420 = call double @llvm.fmuladd.f64(double %419, double %418, double 1.000000e+00)
  %421 = call double @sqrt(double noundef %420) #6
  %422 = fdiv double %416, %421
  store double %422, ptr %34, align 8, !tbaa !9
  %423 = load double, ptr %15, align 8, !tbaa !9
  %424 = fdiv double %423, 2.000000e+00
  %425 = call double @cos(double noundef %424) #6
  store double %425, ptr %35, align 8, !tbaa !9
  %426 = load double, ptr %13, align 8, !tbaa !9
  %427 = load double, ptr %14, align 8, !tbaa !9
  %428 = call double @sin(double noundef %427) #6
  %429 = load double, ptr %31, align 8, !tbaa !9
  %430 = call double @llvm.fmuladd.f64(double %426, double %428, double %429)
  %431 = load double, ptr %34, align 8, !tbaa !9
  %432 = fmul double %430, %431
  store double %432, ptr %36, align 8, !tbaa !9
  %433 = load double, ptr %13, align 8, !tbaa !9
  %434 = load double, ptr %14, align 8, !tbaa !9
  %435 = call double @cos(double noundef %434) #6
  %436 = load double, ptr %32, align 8, !tbaa !9
  %437 = call double @llvm.fmuladd.f64(double %433, double %435, double %436)
  %438 = load double, ptr %34, align 8, !tbaa !9
  %439 = fmul double %437, %438
  store double %439, ptr %37, align 8, !tbaa !9
  %440 = load double, ptr %29, align 8, !tbaa !9
  %441 = fmul double 2.000000e+00, %440
  %442 = load double, ptr %28, align 8, !tbaa !9
  %443 = fmul double %441, %442
  store double %443, ptr %38, align 8, !tbaa !9
  %444 = load double, ptr %25, align 8, !tbaa !9
  %445 = load double, ptr %32, align 8, !tbaa !9
  %446 = load double, ptr %33, align 8, !tbaa !9
  %447 = load double, ptr %29, align 8, !tbaa !9
  %448 = fneg double %446
  %449 = call double @llvm.fmuladd.f64(double %448, double %447, double %445)
  %450 = fmul double %444, %449
  store double %450, ptr %39, align 8, !tbaa !9
  %451 = load double, ptr %25, align 8, !tbaa !9
  %452 = load double, ptr %31, align 8, !tbaa !9
  %453 = load double, ptr %33, align 8, !tbaa !9
  %454 = load double, ptr %28, align 8, !tbaa !9
  %455 = call double @llvm.fmuladd.f64(double %453, double %454, double %452)
  %456 = fmul double %451, %455
  store double %456, ptr %40, align 8, !tbaa !9
  %457 = load double, ptr %25, align 8, !tbaa !9
  %458 = load double, ptr %33, align 8, !tbaa !9
  %459 = fneg double %458
  %460 = load double, ptr %35, align 8, !tbaa !9
  %461 = fmul double %459, %460
  %462 = fmul double %457, %461
  store double %462, ptr %41, align 8, !tbaa !9
  %463 = load double, ptr %39, align 8, !tbaa !9
  %464 = load ptr, ptr %6, align 8, !tbaa !11
  %465 = getelementptr inbounds [3 x double], ptr %464, i64 0
  %466 = getelementptr inbounds [3 x double], ptr %465, i64 0, i64 0
  store double %463, ptr %466, align 8, !tbaa !9
  %467 = load double, ptr %40, align 8, !tbaa !9
  %468 = load double, ptr %41, align 8, !tbaa !9
  %469 = fmul double %468, f0x3FD9752E50F4B399
  %470 = fneg double %469
  %471 = call double @llvm.fmuladd.f64(double %467, double f0x3FED5C0357681EF3, double %470)
  %472 = load ptr, ptr %6, align 8, !tbaa !11
  %473 = getelementptr inbounds [3 x double], ptr %472, i64 0
  %474 = getelementptr inbounds [3 x double], ptr %473, i64 0, i64 1
  store double %471, ptr %474, align 8, !tbaa !9
  %475 = load double, ptr %40, align 8, !tbaa !9
  %476 = load double, ptr %41, align 8, !tbaa !9
  %477 = fmul double %476, f0x3FED5C0357681EF3
  %478 = call double @llvm.fmuladd.f64(double %475, double f0x3FD9752E50F4B399, double %477)
  %479 = load ptr, ptr %6, align 8, !tbaa !11
  %480 = getelementptr inbounds [3 x double], ptr %479, i64 0
  %481 = getelementptr inbounds [3 x double], ptr %480, i64 0, i64 2
  store double %478, ptr %481, align 8, !tbaa !9
  %482 = load double, ptr %26, align 8, !tbaa !9
  %483 = load double, ptr %29, align 8, !tbaa !9
  %484 = fmul double 2.000000e+00, %483
  %485 = load double, ptr %29, align 8, !tbaa !9
  %486 = call double @llvm.fmuladd.f64(double %484, double %485, double -1.000000e+00)
  %487 = load double, ptr %36, align 8, !tbaa !9
  %488 = load double, ptr %38, align 8, !tbaa !9
  %489 = load double, ptr %37, align 8, !tbaa !9
  %490 = fmul double %488, %489
  %491 = call double @llvm.fmuladd.f64(double %486, double %487, double %490)
  %492 = fmul double %482, %491
  store double %492, ptr %39, align 8, !tbaa !9
  %493 = load double, ptr %26, align 8, !tbaa !9
  %494 = load double, ptr %28, align 8, !tbaa !9
  %495 = fmul double 2.000000e+00, %494
  %496 = load double, ptr %28, align 8, !tbaa !9
  %497 = fneg double %495
  %498 = call double @llvm.fmuladd.f64(double %497, double %496, double 1.000000e+00)
  %499 = load double, ptr %37, align 8, !tbaa !9
  %500 = load double, ptr %38, align 8, !tbaa !9
  %501 = load double, ptr %36, align 8, !tbaa !9
  %502 = fmul double %500, %501
  %503 = fneg double %502
  %504 = call double @llvm.fmuladd.f64(double %498, double %499, double %503)
  %505 = fmul double %493, %504
  store double %505, ptr %40, align 8, !tbaa !9
  %506 = load double, ptr %26, align 8, !tbaa !9
  %507 = load double, ptr %35, align 8, !tbaa !9
  %508 = fmul double 2.000000e+00, %507
  %509 = load double, ptr %29, align 8, !tbaa !9
  %510 = load double, ptr %36, align 8, !tbaa !9
  %511 = load double, ptr %28, align 8, !tbaa !9
  %512 = load double, ptr %37, align 8, !tbaa !9
  %513 = fmul double %511, %512
  %514 = call double @llvm.fmuladd.f64(double %509, double %510, double %513)
  %515 = fmul double %508, %514
  %516 = fmul double %506, %515
  store double %516, ptr %41, align 8, !tbaa !9
  %517 = load double, ptr %39, align 8, !tbaa !9
  %518 = load ptr, ptr %6, align 8, !tbaa !11
  %519 = getelementptr inbounds [3 x double], ptr %518, i64 1
  %520 = getelementptr inbounds [3 x double], ptr %519, i64 0, i64 0
  store double %517, ptr %520, align 8, !tbaa !9
  %521 = load double, ptr %40, align 8, !tbaa !9
  %522 = load double, ptr %41, align 8, !tbaa !9
  %523 = fmul double %522, f0x3FD9752E50F4B399
  %524 = fneg double %523
  %525 = call double @llvm.fmuladd.f64(double %521, double f0x3FED5C0357681EF3, double %524)
  %526 = load ptr, ptr %6, align 8, !tbaa !11
  %527 = getelementptr inbounds [3 x double], ptr %526, i64 1
  %528 = getelementptr inbounds [3 x double], ptr %527, i64 0, i64 1
  store double %525, ptr %528, align 8, !tbaa !9
  %529 = load double, ptr %40, align 8, !tbaa !9
  %530 = load double, ptr %41, align 8, !tbaa !9
  %531 = fmul double %530, f0x3FED5C0357681EF3
  %532 = call double @llvm.fmuladd.f64(double %529, double f0x3FD9752E50F4B399, double %531)
  %533 = load ptr, ptr %6, align 8, !tbaa !11
  %534 = getelementptr inbounds [3 x double], ptr %533, i64 1
  %535 = getelementptr inbounds [3 x double], ptr %534, i64 0, i64 2
  store double %532, ptr %535, align 8, !tbaa !9
  call void @llvm.lifetime.end.p0(ptr %41) #6
  call void @llvm.lifetime.end.p0(ptr %40) #6
  call void @llvm.lifetime.end.p0(ptr %39) #6
  call void @llvm.lifetime.end.p0(ptr %38) #6
  call void @llvm.lifetime.end.p0(ptr %37) #6
  call void @llvm.lifetime.end.p0(ptr %36) #6
  call void @llvm.lifetime.end.p0(ptr %35) #6
  call void @llvm.lifetime.end.p0(ptr %34) #6
  call void @llvm.lifetime.end.p0(ptr %33) #6
  call void @llvm.lifetime.end.p0(ptr %32) #6
  call void @llvm.lifetime.end.p0(ptr %31) #6
  call void @llvm.lifetime.end.p0(ptr %30) #6
  call void @llvm.lifetime.end.p0(ptr %29) #6
  call void @llvm.lifetime.end.p0(ptr %28) #6
  call void @llvm.lifetime.end.p0(ptr %27) #6
  call void @llvm.lifetime.end.p0(ptr %26) #6
  call void @llvm.lifetime.end.p0(ptr %25) #6
  call void @llvm.lifetime.end.p0(ptr %24) #6
  call void @llvm.lifetime.end.p0(ptr %23) #6
  call void @llvm.lifetime.end.p0(ptr %22) #6
  call void @llvm.lifetime.end.p0(ptr %21) #6
  call void @llvm.lifetime.end.p0(ptr %20) #6
  call void @llvm.lifetime.end.p0(ptr %19) #6
  call void @llvm.lifetime.end.p0(ptr %18) #6
  call void @llvm.lifetime.end.p0(ptr %17) #6
  call void @llvm.lifetime.end.p0(ptr %16) #6
  call void @llvm.lifetime.end.p0(ptr %15) #6
  call void @llvm.lifetime.end.p0(ptr %14) #6
  call void @llvm.lifetime.end.p0(ptr %13) #6
  call void @llvm.lifetime.end.p0(ptr %12) #6
  call void @llvm.lifetime.end.p0(ptr %11) #6
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  ret void
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: nounwind
declare double @cos(double noundef) #2

; Function Attrs: nounwind
declare double @sin(double noundef) #2

; Function Attrs: nounwind
declare double @atan2(double noundef, double noundef) #2

; Function Attrs: nounwind
declare double @sqrt(double noundef) #2

; Function Attrs: nounwind uwtable
define dso_local void @radecdist(ptr noundef %0, ptr noundef %1) #0 {
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  store ptr %0, ptr %3, align 8, !tbaa !11
  store ptr %1, ptr %4, align 8, !tbaa !11
  %5 = load ptr, ptr %3, align 8, !tbaa !11
  %6 = getelementptr inbounds [3 x double], ptr %5, i64 0
  %7 = getelementptr inbounds [3 x double], ptr %6, i64 0, i64 0
  %8 = load double, ptr %7, align 8, !tbaa !9
  %9 = load ptr, ptr %3, align 8, !tbaa !11
  %10 = getelementptr inbounds [3 x double], ptr %9, i64 0
  %11 = getelementptr inbounds [3 x double], ptr %10, i64 0, i64 0
  %12 = load double, ptr %11, align 8, !tbaa !9
  %13 = load ptr, ptr %3, align 8, !tbaa !11
  %14 = getelementptr inbounds [3 x double], ptr %13, i64 0
  %15 = getelementptr inbounds [3 x double], ptr %14, i64 0, i64 1
  %16 = load double, ptr %15, align 8, !tbaa !9
  %17 = load ptr, ptr %3, align 8, !tbaa !11
  %18 = getelementptr inbounds [3 x double], ptr %17, i64 0
  %19 = getelementptr inbounds [3 x double], ptr %18, i64 0, i64 1
  %20 = load double, ptr %19, align 8, !tbaa !9
  %21 = fmul double %16, %20
  %22 = call double @llvm.fmuladd.f64(double %8, double %12, double %21)
  %23 = load ptr, ptr %3, align 8, !tbaa !11
  %24 = getelementptr inbounds [3 x double], ptr %23, i64 0
  %25 = getelementptr inbounds [3 x double], ptr %24, i64 0, i64 2
  %26 = load double, ptr %25, align 8, !tbaa !9
  %27 = load ptr, ptr %3, align 8, !tbaa !11
  %28 = getelementptr inbounds [3 x double], ptr %27, i64 0
  %29 = getelementptr inbounds [3 x double], ptr %28, i64 0, i64 2
  %30 = load double, ptr %29, align 8, !tbaa !9
  %31 = call double @llvm.fmuladd.f64(double %26, double %30, double %22)
  %32 = call double @sqrt(double noundef %31) #6
  %33 = load ptr, ptr %4, align 8, !tbaa !11
  %34 = getelementptr inbounds double, ptr %33, i64 2
  store double %32, ptr %34, align 8, !tbaa !9
  %35 = load ptr, ptr %3, align 8, !tbaa !11
  %36 = getelementptr inbounds [3 x double], ptr %35, i64 0
  %37 = getelementptr inbounds [3 x double], ptr %36, i64 0, i64 1
  %38 = load double, ptr %37, align 8, !tbaa !9
  %39 = load ptr, ptr %3, align 8, !tbaa !11
  %40 = getelementptr inbounds [3 x double], ptr %39, i64 0
  %41 = getelementptr inbounds [3 x double], ptr %40, i64 0, i64 0
  %42 = load double, ptr %41, align 8, !tbaa !9
  %43 = call double @atan2(double noundef %38, double noundef %42) #6
  %44 = fmul double %43, f0x400E8EC8A4AEACC4
  %45 = load ptr, ptr %4, align 8, !tbaa !11
  %46 = getelementptr inbounds double, ptr %45, i64 0
  store double %44, ptr %46, align 8, !tbaa !9
  %47 = load ptr, ptr %4, align 8, !tbaa !11
  %48 = getelementptr inbounds double, ptr %47, i64 0
  %49 = load double, ptr %48, align 8, !tbaa !9
  %50 = fcmp olt double %49, 0.000000e+00
  br i1 %50, label %51, label %56

51:                                               ; preds = %2
  %52 = load ptr, ptr %4, align 8, !tbaa !11
  %53 = getelementptr inbounds double, ptr %52, i64 0
  %54 = load double, ptr %53, align 8, !tbaa !9
  %55 = fadd double %54, 2.400000e+01
  store double %55, ptr %53, align 8, !tbaa !9
  br label %56

56:                                               ; preds = %51, %2
  %57 = load ptr, ptr %3, align 8, !tbaa !11
  %58 = getelementptr inbounds [3 x double], ptr %57, i64 0
  %59 = getelementptr inbounds [3 x double], ptr %58, i64 0, i64 2
  %60 = load double, ptr %59, align 8, !tbaa !9
  %61 = load ptr, ptr %4, align 8, !tbaa !11
  %62 = getelementptr inbounds double, ptr %61, i64 2
  %63 = load double, ptr %62, align 8, !tbaa !9
  %64 = fdiv double %60, %63
  %65 = call double @asin(double noundef %64) #6
  %66 = fmul double %65, f0x404CA5DC1A63C1F8
  %67 = load ptr, ptr %4, align 8, !tbaa !11
  %68 = getelementptr inbounds double, ptr %67, i64 1
  store double %66, ptr %68, align 8, !tbaa !9
  ret void
}

; Function Attrs: nounwind
declare double @asin(double noundef) #2

; Function Attrs: nounwind uwtable
define dso_local i32 @main(i32 noundef %0, ptr noundef %1) #0 {
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca ptr, align 8
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  %8 = alloca i32, align 4
  %9 = alloca [2 x double], align 16
  %10 = alloca [2 x [3 x double]], align 16
  %11 = alloca [8 x [3 x double]], align 16
  %12 = alloca i8, align 1
  store i32 0, ptr %3, align 4
  store i32 %0, ptr %4, align 4, !tbaa !14
  store ptr %1, ptr %5, align 8, !tbaa !18
  call void @llvm.lifetime.start.p0(ptr %6) #6
  call void @llvm.lifetime.start.p0(ptr %7) #6
  call void @llvm.lifetime.start.p0(ptr %8) #6
  call void @llvm.lifetime.start.p0(ptr %9) #6
  call void @llvm.lifetime.start.p0(ptr %10) #6
  call void @llvm.lifetime.start.p0(ptr %11) #6
  call void @llvm.lifetime.start.p0(ptr %12) #6
  store i8 0, ptr %12, align 1, !tbaa !21
  %13 = load i32, ptr %4, align 4, !tbaa !14
  %14 = icmp sgt i32 %13, 1
  br i1 %14, label %15, label %32

15:                                               ; preds = %2
  store i32 1, ptr %6, align 4, !tbaa !14
  br label %16

16:                                               ; preds = %28, %15
  %17 = load i32, ptr %6, align 4, !tbaa !14
  %18 = load i32, ptr %4, align 4, !tbaa !14
  %19 = icmp slt i32 %17, %18
  br i1 %19, label %20, label %31

20:                                               ; preds = %16
  %21 = load ptr, ptr %5, align 8, !tbaa !18
  %22 = getelementptr inbounds ptr, ptr %21, i64 1
  %23 = load ptr, ptr %22, align 8, !tbaa !23
  %24 = call i32 @strcmp(ptr noundef %23, ptr noundef @.str) #7
  %25 = icmp ne i32 %24, 0
  br i1 %25, label %27, label %26

26:                                               ; preds = %20
  store i8 1, ptr %12, align 1, !tbaa !21
  br label %31

27:                                               ; preds = %20
  br label %28

28:                                               ; preds = %27
  %29 = load i32, ptr %6, align 4, !tbaa !14
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %6, align 4, !tbaa !14
  br label %16, !llvm.loop !25

31:                                               ; preds = %26, %16
  br label %32

32:                                               ; preds = %31, %2
  store i32 0, ptr %6, align 4, !tbaa !14
  br label %33

33:                                               ; preds = %66, %32
  %34 = load i32, ptr %6, align 4, !tbaa !14
  %35 = icmp slt i32 %34, 20
  br i1 %35, label %36, label %69

36:                                               ; preds = %33
  %37 = getelementptr inbounds [2 x double], ptr %9, i64 0, i64 0
  store double f0x4142B42C80000000, ptr %37, align 16, !tbaa !9
  %38 = getelementptr inbounds [2 x double], ptr %9, i64 0, i64 1
  store double 0.000000e+00, ptr %38, align 8, !tbaa !9
  store i32 0, ptr %7, align 4, !tbaa !14
  br label %39

39:                                               ; preds = %62, %36
  %40 = load i32, ptr %7, align 4, !tbaa !14
  %41 = icmp slt i32 %40, 36525
  br i1 %41, label %42, label %65

42:                                               ; preds = %39
  %43 = getelementptr inbounds [2 x double], ptr %9, i64 0, i64 0
  %44 = load double, ptr %43, align 16, !tbaa !9
  %45 = fadd double %44, 1.000000e+00
  store double %45, ptr %43, align 16, !tbaa !9
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %46

46:                                               ; preds = %58, %42
  %47 = load i32, ptr %8, align 4, !tbaa !14
  %48 = icmp slt i32 %47, 8
  br i1 %48, label %49, label %61

49:                                               ; preds = %46
  %50 = getelementptr inbounds [2 x double], ptr %9, i64 0, i64 0
  %51 = load i32, ptr %8, align 4, !tbaa !14
  %52 = getelementptr inbounds [2 x [3 x double]], ptr %10, i64 0, i64 0
  call void @planetpv(ptr noundef %50, i32 noundef %51, ptr noundef %52)
  %53 = getelementptr inbounds [2 x [3 x double]], ptr %10, i64 0, i64 0
  %54 = load i32, ptr %8, align 4, !tbaa !14
  %55 = sext i32 %54 to i64
  %56 = getelementptr inbounds [8 x [3 x double]], ptr %11, i64 0, i64 %55
  %57 = getelementptr inbounds [3 x double], ptr %56, i64 0, i64 0
  call void @radecdist(ptr noundef %53, ptr noundef %57)
  br label %58

58:                                               ; preds = %49
  %59 = load i32, ptr %8, align 4, !tbaa !14
  %60 = add nsw i32 %59, 1
  store i32 %60, ptr %8, align 4, !tbaa !14
  br label %46, !llvm.loop !26

61:                                               ; preds = %46
  br label %62

62:                                               ; preds = %61
  %63 = load i32, ptr %7, align 4, !tbaa !14
  %64 = add nsw i32 %63, 1
  store i32 %64, ptr %7, align 4, !tbaa !14
  br label %39, !llvm.loop !27

65:                                               ; preds = %39
  br label %66

66:                                               ; preds = %65
  %67 = load i32, ptr %6, align 4, !tbaa !14
  %68 = add nsw i32 %67, 1
  store i32 %68, ptr %6, align 4, !tbaa !14
  br label %33, !llvm.loop !28

69:                                               ; preds = %33
  store i32 0, ptr %8, align 4, !tbaa !14
  br label %70

70:                                               ; preds = %90, %69
  %71 = load i32, ptr %8, align 4, !tbaa !14
  %72 = icmp slt i32 %71, 8
  br i1 %72, label %73, label %93

73:                                               ; preds = %70
  %74 = load i32, ptr %8, align 4, !tbaa !14
  %75 = sext i32 %74 to i64
  %76 = getelementptr inbounds [8 x [3 x double]], ptr %11, i64 0, i64 %75
  %77 = getelementptr inbounds [3 x double], ptr %76, i64 0, i64 0
  %78 = load double, ptr %77, align 8, !tbaa !9
  %79 = load i32, ptr %8, align 4, !tbaa !14
  %80 = sext i32 %79 to i64
  %81 = getelementptr inbounds [8 x [3 x double]], ptr %11, i64 0, i64 %80
  %82 = getelementptr inbounds [3 x double], ptr %81, i64 0, i64 1
  %83 = load double, ptr %82, align 8, !tbaa !9
  %84 = load i32, ptr %8, align 4, !tbaa !14
  %85 = sext i32 %84 to i64
  %86 = getelementptr inbounds [8 x [3 x double]], ptr %11, i64 0, i64 %85
  %87 = getelementptr inbounds [3 x double], ptr %86, i64 0, i64 2
  %88 = load double, ptr %87, align 8, !tbaa !9
  %89 = call i32 (ptr, ...) @printf(ptr noundef @.str.1, double noundef %78, double noundef %83, double noundef %88)
  br label %90

90:                                               ; preds = %73
  %91 = load i32, ptr %8, align 4, !tbaa !14
  %92 = add nsw i32 %91, 1
  store i32 %92, ptr %8, align 4, !tbaa !14
  br label %70, !llvm.loop !29

93:                                               ; preds = %70
  %94 = load ptr, ptr @stdout, align 8, !tbaa !30
  %95 = call i32 @fflush(ptr noundef %94)
  call void @llvm.lifetime.end.p0(ptr %12) #6
  call void @llvm.lifetime.end.p0(ptr %11) #6
  call void @llvm.lifetime.end.p0(ptr %10) #6
  call void @llvm.lifetime.end.p0(ptr %9) #6
  call void @llvm.lifetime.end.p0(ptr %8) #6
  call void @llvm.lifetime.end.p0(ptr %7) #6
  call void @llvm.lifetime.end.p0(ptr %6) #6
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(read)
declare i32 @strcmp(ptr noundef, ptr noundef) #4

declare i32 @printf(ptr noundef, ...) #5

declare i32 @fflush(ptr noundef) #5

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nounwind willreturn memory(read) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nounwind }
attributes #7 = { nounwind willreturn memory(read) }

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
!10 = !{!"double", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"p1 double", !13, i64 0}
!13 = !{!"any pointer", !7, i64 0}
!14 = !{!6, !6, i64 0}
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.mustprogress"}
!17 = distinct !{!17, !16}
!18 = !{!19, !19, i64 0}
!19 = !{!"p2 omnipotent char", !20, i64 0}
!20 = !{!"any p2 pointer", !13, i64 0}
!21 = !{!22, !22, i64 0}
!22 = !{!"_Bool", !7, i64 0}
!23 = !{!24, !24, i64 0}
!24 = !{!"p1 omnipotent char", !13, i64 0}
!25 = distinct !{!25, !16}
!26 = distinct !{!26, !16}
!27 = distinct !{!27, !16}
!28 = distinct !{!28, !16}
!29 = distinct !{!29, !16}
!30 = !{!31, !31, i64 0}
!31 = !{!"p1 _ZTS8_IO_FILE", !13, i64 0}
