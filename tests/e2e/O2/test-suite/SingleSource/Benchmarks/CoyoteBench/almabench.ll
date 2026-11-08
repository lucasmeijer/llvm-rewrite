; @source: tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c
; @llc: -O2
; @generated: clang -O2 -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c'
source_filename = "tests/e2e/src/test-suite/SingleSource/Benchmarks/CoyoteBench/almabench.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@a = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x3FD8C637FD3B6253, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FE725849423E3E0, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FF000011136AEF5, double 0.000000e+00, double 0.000000e+00], [3 x double] [double f0x3FF860FD96F0D223, double 3.000000e-10, double 0.000000e+00], [3 x double] [double f0x4014CF7737365089, double 1.913200e-06, double -3.900000e-09], [3 x double] [double f0x40231C1D0EBB7C0F, double -2.138960e-05, double 4.440000e-08], [3 x double] [double f0x403337EC14C35EFA, double -3.716000e-07, double f0x3E7A47A3038502A4], [3 x double] [double f0x403E1C425059FB17, double -1.663500e-06, double 6.860000e-08]], align 16
@dlm = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x406F88076B035926, double f0x41F40BBCADEE3CB4, double -1.927890e+00], [3 x double] [double f0x4066BF5A874FEAFA, double f0x41DF6432F5157881, double 5.938100e-01], [3 x double] [double f0x40591DDA6DBF7622, double f0x41D34FC2F3B56502, double -2.044110e+00], [3 x double] [double f0x407636ED90F7B482, double f0x41C4890A4B784DFD, double 9.426400e-01], [3 x double] [double f0x40412CFE90EA1D96, double f0x419A0C7E6F1EA0BA, double f0xC03E9A915379FA98], [3 x double] [double f0x404909E9B1DFE17D, double f0x4184FA9E14756430, double f0x4052E76ED677707A], [3 x double] [double f0x4073A0E14D09C902, double f0x416D6BA57E0EFDCA, double -1.750830e+00], [3 x double] [double f0x4073059422411D82, double f0x415E0127CD46B26C, double 2.110300e-01]], align 16
@e = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x3FCA52242A37D430, double f0x3F2ABF4B9459E7F4, double -2.834900e-06], [3 x double] [double f0x3F7BBCDE77820827, double f0xBF3F4DAC25FB4BC2, double 9.812700e-06], [3 x double] [double f0x3F911C1175CC9F7B, double f0xBF3B8C8FA536F731, double -1.267340e-05], [3 x double] [double f0x3FB7E91AD74BF5B0, double f0x3F4DA66143B5E407, double -8.064100e-06], [3 x double] [double f0x3FA8D4B857E48742, double f0x3F5ABE2B9A18B7B5, double -4.713660e-05], [3 x double] [double f0x3FAC70CE5FA41E66, double f0xBF6C6594A86FD58E, double -6.436390e-05], [3 x double] [double f0x3FA7BF479022D287, double f0xBF31E2FE6AE927D8, double 7.891300e-06], [3 x double] [double f0x3F835D88E0FE76D8, double 6.032630e-05, double 0.000000e+00]], align 16
@pi = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x40535D310DE9F882, double f0x40B6571DAB9F559B, double -4.830160e+00], [3 x double] [double f0x40607209DADFB507, double f0x4065EF9096BB98C8, double f0xC07F27B59DDC1E79], [3 x double] [double f0x4059BBFD82CD2461, double f0x40C6AE2D2BD3C361, double f0x404AA34C6E6D9BE5], [3 x double] [double f0x407500F6B7DFD5BE, double f0x40CF363AC3222920, double -6.232800e+01], [3 x double] [double f0x402CA993F265B897, double f0x40BE4EC06AD2DCB1, double f0x40703F599ED7C6FC], [3 x double] [double f0x405743A9C7642D26, double f0x40D3EADFA415F45E, double f0x4067C84DFCE3150E], [3 x double] [double f0x4065A02B58283528, double f0x40A91F1FF04577D9, double f0xC0410BE37DE939EB], [3 x double] [double f0x40480F65305B6785, double f0x40906AE060FE4799, double f0x403B65ACEEE0F3CB]], align 16
@dinc = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x401C051B1D92B7FE, double f0xC06AC83387160957, double 2.897700e-01], [3 x double] [double f0x400B28447E34386C, double f0xC03ED828A1DFB939, double f0xC0275B52007DD441], [3 x double] [double 0.000000e+00, double f0x407D5F90F51AC9B0, double -3.350530e+00], [3 x double] [double f0x3FFD987ACB2252BB, double f0xC072551355475A32, double -8.118300e+00], [3 x double] [double f0x3FF4DA2E7A10E830, double f0xC051E3C504816F00, double f0x4027E7EBAF102364], [3 x double] [double f0x4003E939471E778F, double f0x4056F686594AF4F1, double f0xC031A989374BC6A8], [3 x double] [double f0x3FE8BE07677D67B5, double f0xC04E5D15DF6555C5, double 1.257590e+00], [3 x double] [double f0x3FFC51B9CE9853F4, double f0x40203F251C193B3A, double 8.135000e-02]], align 16
@omega = internal unnamed_addr constant [8 x [3 x double]] [[3 x double] [double f0x40482A5AB400A313, double f0xC0B1A3379F01B867, double f0xC03FCC8605681ECD], [3 x double] [double f0x40532B83CFF8FC2B, double f0xC0C38C3DA31A4BDC, double f0xC049A9BEF49CF56F], [3 x double] [double f0x4065DBF10E4FF9E8, double f0xC0C0F3A29A804966, double f0x402EAF0ED3D859C9], [3 x double] [double f0x4048C76F992A88EB, double f0xC0C4BE7350092CCF, double f0xC06CD25F84CAD57C], [3 x double] [double f0x40591DB8D838BBB3, double f0x40B8DA091DBCA969, double f0x4074685935FC3B4F], [3 x double] [double f0x405C6A9797E1B38F, double f0xC0C20C1986983516, double f0xC0508F320D9945B7], [3 x double] [double f0x405280619982C872, double f0x40A4DA4CF80DC337, double f0x40623E1187E7C06E], [3 x double] [double f0x40607916FEBF632D, double f0xC06BBE2EDBB59DDC, double -7.872800e-01]], align 16
@kp = internal unnamed_addr constant [8 x [9 x double]] [[9 x double] [double 6.961300e+04, double 7.564500e+04, double 8.830600e+04, double 5.989900e+04, double 1.574600e+04, double 7.108700e+04, double 1.421730e+05, double 3.086000e+03, double 0.000000e+00], [9 x double] [double 2.186300e+04, double 3.279400e+04, double 2.693400e+04, double 1.093100e+04, double 2.625000e+04, double 4.372500e+04, double 5.386700e+04, double 2.893900e+04, double 0.000000e+00], [9 x double] [double 1.600200e+04, double 2.186300e+04, double 3.200400e+04, double 1.093100e+04, double 1.452900e+04, double 1.636800e+04, double 1.531800e+04, double 3.279400e+04, double 0.000000e+00], [9 x double] [double 6.345000e+03, double 7.818000e+03, double 1.563600e+04, double 7.077000e+03, double 8.184000e+03, double 1.416300e+04, double 1.107000e+03, double 4.872000e+03, double 0.000000e+00], [9 x double] [double 1.760000e+03, double 1.454000e+03, double 1.167000e+03, double 8.800000e+02, double 2.870000e+02, double 2.640000e+03, double 1.900000e+01, double 2.047000e+03, double 1.454000e+03], [9 x double] [double 5.740000e+02, double 0.000000e+00, double 8.800000e+02, double 2.870000e+02, double 1.900000e+01, double 1.760000e+03, double 1.167000e+03, double 3.060000e+02, double 5.740000e+02], [9 x double] [double 2.040000e+02, double 0.000000e+00, double 1.770000e+02, double 1.265000e+03, double 4.000000e+00, double 3.850000e+02, double 2.000000e+02, double 2.080000e+02, double 2.040000e+02], [9 x double] [double 0.000000e+00, double 1.020000e+02, double 1.060000e+02, double 4.000000e+00, double 9.800000e+01, double 1.367000e+03, double 4.870000e+02, double 2.040000e+02, double 0.000000e+00]], align 16
@kq = internal unnamed_addr constant [8 x [10 x double]] [[10 x double] [double 3.086000e+03, double 1.574600e+04, double 6.961300e+04, double 5.989900e+04, double 7.564500e+04, double 8.830600e+04, double 1.266100e+04, double 2.658000e+03, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 2.186300e+04, double 3.279400e+04, double 1.093100e+04, double 7.300000e+01, double 4.387000e+03, double 2.693400e+04, double 1.473000e+03, double 2.157000e+03, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 1.000000e+01, double 1.600200e+04, double 2.186300e+04, double 1.093100e+04, double 1.473000e+03, double 3.200400e+04, double 4.387000e+03, double 7.300000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 1.000000e+01, double 6.345000e+03, double 7.818000e+03, double 1.107000e+03, double 1.563600e+04, double 7.077000e+03, double 8.184000e+03, double 5.320000e+02, double 1.000000e+01, double 0.000000e+00], [10 x double] [double 1.900000e+01, double 1.760000e+03, double 1.454000e+03, double 2.870000e+02, double 1.167000e+03, double 8.800000e+02, double 5.740000e+02, double 2.640000e+03, double 1.900000e+01, double 1.454000e+03], [10 x double] [double 1.900000e+01, double 5.740000e+02, double 2.870000e+02, double 3.060000e+02, double 1.760000e+03, double 1.200000e+01, double 3.100000e+01, double 3.800000e+01, double 1.900000e+01, double 5.740000e+02], [10 x double] [double 4.000000e+00, double 2.040000e+02, double 1.770000e+02, double 8.000000e+00, double 3.100000e+01, double 2.000000e+02, double 1.265000e+03, double 1.020000e+02, double 4.000000e+00, double 2.040000e+02], [10 x double] [double 4.000000e+00, double 1.020000e+02, double 1.060000e+02, double 8.000000e+00, double 9.800000e+01, double 1.367000e+03, double 4.870000e+02, double 2.040000e+02, double 4.000000e+00, double 1.020000e+02]], align 16
@ca = internal unnamed_addr constant [8 x [9 x double]] [[9 x double] [double 4.000000e+00, double -1.300000e+01, double 1.100000e+01, double -9.000000e+00, double -9.000000e+00, double -3.000000e+00, double -1.000000e+00, double 4.000000e+00, double 0.000000e+00], [9 x double] [double -1.560000e+02, double 5.900000e+01, double -4.200000e+01, double 6.000000e+00, double 1.900000e+01, double -2.000000e+01, double -1.000000e+01, double -1.200000e+01, double 0.000000e+00], [9 x double] [double 6.400000e+01, double -1.520000e+02, double 6.200000e+01, double -8.000000e+00, double 3.200000e+01, double -4.100000e+01, double 1.900000e+01, double -1.100000e+01, double 0.000000e+00], [9 x double] [double 1.240000e+02, double 6.210000e+02, double -1.450000e+02, double 2.080000e+02, double 5.400000e+01, double -5.700000e+01, double 3.000000e+01, double 1.500000e+01, double 0.000000e+00], [9 x double] [double -2.343700e+04, double -2.634000e+03, double 6.601000e+03, double 6.259000e+03, double -1.507000e+03, double -1.821000e+03, double 2.620000e+03, double -2.115000e+03, double -1.489000e+03], [9 x double] [double 6.291100e+04, double -1.199190e+05, double 7.933600e+04, double 1.781400e+04, double -2.424100e+04, double 1.206800e+04, double 8.306000e+03, double -4.893000e+03, double 8.902000e+03], [9 x double] [double 3.890610e+05, double -2.621250e+05, double -4.408800e+04, double 8.387000e+03, double -2.297600e+04, double -2.093000e+03, double -6.150000e+02, double -9.720000e+03, double 6.633000e+03], [9 x double] [double -4.122350e+05, double -1.570460e+05, double -3.143000e+04, double 3.781700e+04, double -9.740000e+03, double -1.300000e+01, double -7.449000e+03, double 9.644000e+03, double 0.000000e+00]], align 16
@sa = internal unnamed_addr constant [8 x [9 x double]] [[9 x double] [double -2.900000e+01, double -1.000000e+00, double 9.000000e+00, double 6.000000e+00, double -6.000000e+00, double 5.000000e+00, double 4.000000e+00, double 0.000000e+00, double 0.000000e+00], [9 x double] [double -4.800000e+01, double -1.250000e+02, double -2.600000e+01, double -3.700000e+01, double 1.800000e+01, double -1.300000e+01, double -2.000000e+01, double -2.000000e+00, double 0.000000e+00], [9 x double] [double -1.500000e+02, double -4.600000e+01, double 6.800000e+01, double 5.400000e+01, double 1.400000e+01, double 2.400000e+01, double -2.800000e+01, double 2.200000e+01, double 0.000000e+00], [9 x double] [double -6.210000e+02, double 5.320000e+02, double -6.940000e+02, double -2.000000e+01, double 1.920000e+02, double -9.400000e+01, double 7.100000e+01, double -7.300000e+01, double 0.000000e+00], [9 x double] [double -1.461400e+04, double -1.982800e+04, double -5.869000e+03, double 1.881000e+03, double -4.372000e+03, double -2.255000e+03, double 7.820000e+02, double 9.300000e+02, double 9.130000e+02], [9 x double] [double 1.397370e+05, double 0.000000e+00, double 2.466700e+04, double 5.112300e+04, double -5.102000e+03, double 7.429000e+03, double -4.095000e+03, double -1.976000e+03, double -9.566000e+03], [9 x double] [double -1.380810e+05, double 0.000000e+00, double 3.720500e+04, double -4.903900e+04, double -4.190100e+04, double -3.387200e+04, double -2.703700e+04, double -1.247400e+04, double 1.879700e+04], [9 x double] [double 0.000000e+00, double 2.849200e+04, double 1.332360e+05, double 6.965400e+04, double 5.232200e+04, double -4.957700e+04, double -2.643000e+04, double -3.593000e+03, double 0.000000e+00]], align 16
@cl = internal unnamed_addr constant [8 x [10 x double]] [[10 x double] [double 2.100000e+01, double -9.500000e+01, double -1.570000e+02, double 4.100000e+01, double -5.000000e+00, double 4.200000e+01, double 2.300000e+01, double 3.000000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -1.600000e+02, double -3.130000e+02, double -2.350000e+02, double 6.000000e+01, double -7.400000e+01, double -7.600000e+01, double -2.700000e+01, double 3.400000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -3.250000e+02, double -3.220000e+02, double -7.900000e+01, double 2.320000e+02, double -5.200000e+01, double 9.700000e+01, double 5.500000e+01, double -4.100000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 2.268000e+03, double -9.790000e+02, double 8.020000e+02, double 6.020000e+02, double -6.680000e+02, double -3.300000e+01, double 3.450000e+02, double 2.010000e+02, double -5.500000e+01, double 0.000000e+00], [10 x double] [double 7.610000e+03, double -4.997000e+03, double -7.689000e+03, double -5.841000e+03, double -2.617000e+03, double 1.115000e+03, double -7.480000e+02, double -6.070000e+02, double 6.074000e+03, double 3.540000e+02], [10 x double] [double -1.854900e+04, double 3.012500e+04, double 2.001200e+04, double -7.300000e+02, double 8.240000e+02, double 2.300000e+01, double 1.289000e+03, double -3.520000e+02, double -1.476700e+04, double -2.062000e+03], [10 x double] [double -1.352450e+05, double -1.459400e+04, double 4.197000e+03, double -4.030000e+03, double -5.630000e+03, double -2.898000e+03, double 2.540000e+03, double -3.060000e+02, double 2.939000e+03, double 1.986000e+03], [10 x double] [double 8.994800e+04, double 2.103000e+03, double 8.963000e+03, double 2.695000e+03, double 3.682000e+03, double 1.648000e+03, double 8.660000e+02, double -1.540000e+02, double -1.963000e+03, double -2.830000e+02]], align 16
@sl = internal unnamed_addr constant [8 x [10 x double]] [[10 x double] [double -3.420000e+02, double 1.360000e+02, double -2.300000e+01, double 6.200000e+01, double 6.600000e+01, double -5.200000e+01, double -3.300000e+01, double 1.700000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 5.240000e+02, double -1.490000e+02, double -3.500000e+01, double 1.170000e+02, double 1.510000e+02, double 1.220000e+02, double -7.100000e+01, double -6.200000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double -1.050000e+02, double -1.370000e+02, double 2.580000e+02, double 3.500000e+01, double -1.160000e+02, double -8.800000e+01, double -1.120000e+02, double -8.000000e+01, double 0.000000e+00, double 0.000000e+00], [10 x double] [double 8.540000e+02, double -2.050000e+02, double -9.360000e+02, double -2.400000e+02, double 1.400000e+02, double -3.410000e+02, double -9.700000e+01, double -2.320000e+02, double 5.360000e+02, double 0.000000e+00], [10 x double] [double -5.698000e+04, double 8.016000e+03, double 1.012000e+03, double 1.448000e+03, double -3.024000e+03, double -3.710000e+03, double 3.180000e+02, double 5.030000e+02, double 3.767000e+03, double 5.770000e+02], [10 x double] [double 1.386060e+05, double -1.347800e+04, double -4.964000e+03, double 1.441000e+03, double -1.319000e+03, double -1.482000e+03, double 4.270000e+02, double 1.236000e+03, double -9.167000e+03, double -1.918000e+03], [10 x double] [double 7.123400e+04, double -4.111600e+04, double 5.334000e+03, double -4.935000e+03, double -1.848000e+03, double 6.600000e+01, double 4.340000e+02, double -1.748000e+03, double 3.780000e+03, double -7.010000e+02], [10 x double] [double -4.764500e+04, double 1.164700e+04, double 2.166000e+03, double 3.194000e+03, double 6.790000e+02, double 0.000000e+00, double -2.440000e+02, double -4.190000e+02, double -2.531000e+03, double 4.800000e+01]], align 16
@amas = internal unnamed_addr constant [8 x double] [double 6.023600e+06, double f0x4118EF2E00000000, double f0x4114131200000000, double 3.098710e+06, double f0x40905D6B851EB852, double 3.498500e+03, double 2.286900e+04, double 1.931400e+04], align 16
@.str.1 = private unnamed_addr constant [10 x i8] c"%f %f %f\0A\00", align 1
@stdout = external local_unnamed_addr global ptr, align 8

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(errnomem: write) uwtable
define dso_local double @anpm(double noundef %0) local_unnamed_addr #0 {
  %2 = tail call double @fmod(double noundef %0, double noundef f0x401921FB54442D18) #9
  %3 = tail call double @llvm.fabs.f64(double %2)
  %4 = fcmp ult double %3, f0x400921FB54442D18
  br i1 %4, label %9, label %5

5:                                                ; preds = %1
  %6 = fcmp olt double %0, 0.000000e+00
  %7 = select i1 %6, double f0xC01921FB54442D18, double f0x401921FB54442D18
  %8 = fsub double %2, %7
  br label %9

9:                                                ; preds = %5, %1
  %10 = phi double [ %8, %5 ], [ %2, %1 ]
  ret double %10
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @fmod(double noundef, double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fabs.f64(double) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: readwrite, errnomem: write) uwtable
define dso_local void @planetpv(ptr nofree noundef readonly captures(none) %0, i32 noundef %1, ptr nofree noundef writeonly captures(none) %2) local_unnamed_addr #4 {
  %4 = load double, ptr %0, align 8, !tbaa !9
  %5 = fadd double %4, f0xC142B42C80000000
  %6 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %7 = load double, ptr %6, align 8, !tbaa !9
  %8 = fadd double %5, %7
  %9 = fdiv double %8, 3.652500e+05
  %10 = sext i32 %1 to i64
  %11 = getelementptr inbounds [24 x i8], ptr @a, i64 %10
  %12 = load double, ptr %11, align 8, !tbaa !9
  %13 = getelementptr inbounds nuw i8, ptr %11, i64 8
  %14 = getelementptr inbounds [24 x i8], ptr @dlm, i64 %10
  %15 = load double, ptr %14, align 8, !tbaa !9
  %16 = getelementptr inbounds nuw i8, ptr %14, i64 8
  %17 = load <2 x double>, ptr %13, align 8, !tbaa !9
  %18 = load <2 x double>, ptr %16, align 8, !tbaa !9
  %19 = shufflevector <2 x double> %17, <2 x double> %18, <2 x i32> <i32 1, i32 3>
  %20 = insertelement <2 x double> poison, double %9, i64 0
  %21 = shufflevector <2 x double> %20, <2 x double> poison, <2 x i32> zeroinitializer
  %22 = shufflevector <2 x double> %17, <2 x double> %18, <2 x i32> <i32 0, i32 2>
  %23 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %19, <2 x double> %21, <2 x double> %22)
  %24 = extractelement <2 x double> %23, i64 1
  %25 = fmul double %9, %24
  %26 = tail call double @llvm.fmuladd.f64(double %15, double 3.600000e+03, double %25)
  %27 = extractelement <2 x double> %23, i64 0
  %28 = tail call double @llvm.fmuladd.f64(double %27, double %9, double %12)
  %29 = fmul double %26, f0x3ED455A5B2FF8F9D
  %30 = getelementptr inbounds [24 x i8], ptr @e, i64 %10
  %31 = load double, ptr %30, align 8, !tbaa !9
  %32 = getelementptr inbounds nuw i8, ptr %30, i64 8
  %33 = load double, ptr %32, align 8, !tbaa !9
  %34 = getelementptr inbounds nuw i8, ptr %30, i64 16
  %35 = load double, ptr %34, align 8, !tbaa !9
  %36 = tail call double @llvm.fmuladd.f64(double %35, double %9, double %33)
  %37 = tail call double @llvm.fmuladd.f64(double %36, double %9, double %31)
  %38 = getelementptr inbounds [24 x i8], ptr @pi, i64 %10
  %39 = load double, ptr %38, align 8, !tbaa !9
  %40 = getelementptr inbounds nuw i8, ptr %38, i64 8
  %41 = load double, ptr %40, align 8, !tbaa !9
  %42 = getelementptr inbounds nuw i8, ptr %38, i64 16
  %43 = load double, ptr %42, align 8, !tbaa !9
  %44 = tail call double @llvm.fmuladd.f64(double %43, double %9, double %41)
  %45 = fmul double %9, %44
  %46 = tail call double @llvm.fmuladd.f64(double %39, double 3.600000e+03, double %45)
  %47 = fmul double %46, f0x3ED455A5B2FF8F9D
  %48 = tail call double @fmod(double noundef %47, double noundef f0x401921FB54442D18) #9
  %49 = tail call double @llvm.fabs.f64(double %48)
  %50 = fcmp ult double %49, f0x400921FB54442D18
  br i1 %50, label %55, label %51

51:                                               ; preds = %3
  %52 = fcmp olt double %47, 0.000000e+00
  %53 = select i1 %52, double f0xC01921FB54442D18, double f0x401921FB54442D18
  %54 = fsub double %48, %53
  br label %55

55:                                               ; preds = %3, %51
  %56 = phi double [ %54, %51 ], [ %48, %3 ]
  %57 = getelementptr inbounds [24 x i8], ptr @dinc, i64 %10
  %58 = load double, ptr %57, align 8, !tbaa !9
  %59 = getelementptr inbounds nuw i8, ptr %57, i64 8
  %60 = load double, ptr %59, align 8, !tbaa !9
  %61 = getelementptr inbounds nuw i8, ptr %57, i64 16
  %62 = load double, ptr %61, align 8, !tbaa !9
  %63 = getelementptr inbounds [24 x i8], ptr @omega, i64 %10
  %64 = load double, ptr %63, align 8, !tbaa !9
  %65 = getelementptr inbounds nuw i8, ptr %63, i64 8
  %66 = load double, ptr %65, align 8, !tbaa !9
  %67 = getelementptr inbounds nuw i8, ptr %63, i64 16
  %68 = load double, ptr %67, align 8, !tbaa !9
  %69 = tail call double @llvm.fmuladd.f64(double %68, double %9, double %66)
  %70 = fmul double %9, %69
  %71 = tail call double @llvm.fmuladd.f64(double %64, double 3.600000e+03, double %70)
  %72 = fmul double %71, f0x3ED455A5B2FF8F9D
  %73 = tail call double @fmod(double noundef %72, double noundef f0x401921FB54442D18) #9
  %74 = tail call double @llvm.fabs.f64(double %73)
  %75 = fcmp ult double %74, f0x400921FB54442D18
  br i1 %75, label %80, label %76

76:                                               ; preds = %55
  %77 = fcmp olt double %72, 0.000000e+00
  %78 = select i1 %77, double f0xC01921FB54442D18, double f0x401921FB54442D18
  %79 = fsub double %73, %78
  br label %80

80:                                               ; preds = %76, %55
  %81 = phi double [ %79, %76 ], [ %73, %55 ]
  %82 = insertelement <2 x double> poison, double %29, i64 0
  %83 = insertelement <2 x double> %82, double %28, i64 1
  %84 = getelementptr inbounds [80 x i8], ptr @sl, i64 %10
  %85 = getelementptr inbounds [80 x i8], ptr @cl, i64 %10
  %86 = getelementptr inbounds [72 x i8], ptr @sa, i64 %10
  %87 = getelementptr inbounds [72 x i8], ptr @ca, i64 %10
  %88 = getelementptr inbounds [80 x i8], ptr @kq, i64 %10
  %89 = getelementptr inbounds [72 x i8], ptr @kp, i64 %10
  %90 = fmul double %9, f0x3FD702A41F2E9970
  %91 = load double, ptr %89, align 8, !tbaa !9
  %92 = fmul double %90, %91
  %93 = load double, ptr %88, align 16, !tbaa !9
  %94 = fmul double %90, %93
  %95 = load double, ptr %87, align 8, !tbaa !9
  %96 = tail call double @cos(double noundef %92) #9
  %97 = load double, ptr %86, align 8, !tbaa !9
  %98 = tail call double @sin(double noundef %92) #9
  %99 = load double, ptr %85, align 16, !tbaa !9
  %100 = tail call double @cos(double noundef %94) #9
  %101 = load double, ptr %84, align 16, !tbaa !9
  %102 = tail call double @sin(double noundef %94) #9
  %103 = insertelement <2 x double> poison, double %101, i64 0
  %104 = insertelement <2 x double> %103, double %97, i64 1
  %105 = insertelement <2 x double> poison, double %102, i64 0
  %106 = insertelement <2 x double> %105, double %98, i64 1
  %107 = fmul <2 x double> %104, %106
  %108 = insertelement <2 x double> poison, double %99, i64 0
  %109 = insertelement <2 x double> %108, double %95, i64 1
  %110 = insertelement <2 x double> poison, double %100, i64 0
  %111 = insertelement <2 x double> %110, double %96, i64 1
  %112 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %109, <2 x double> %111, <2 x double> %107)
  %113 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %112, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %83)
  %114 = getelementptr inbounds nuw i8, ptr %89, i64 8
  %115 = load double, ptr %114, align 8, !tbaa !9
  %116 = fmul double %90, %115
  %117 = getelementptr inbounds nuw i8, ptr %88, i64 8
  %118 = load double, ptr %117, align 8, !tbaa !9
  %119 = fmul double %90, %118
  %120 = getelementptr inbounds nuw i8, ptr %87, i64 8
  %121 = load double, ptr %120, align 8, !tbaa !9
  %122 = tail call double @cos(double noundef %116) #9
  %123 = getelementptr inbounds nuw i8, ptr %86, i64 8
  %124 = load double, ptr %123, align 8, !tbaa !9
  %125 = tail call double @sin(double noundef %116) #9
  %126 = getelementptr inbounds nuw i8, ptr %85, i64 8
  %127 = load double, ptr %126, align 8, !tbaa !9
  %128 = tail call double @cos(double noundef %119) #9
  %129 = getelementptr inbounds nuw i8, ptr %84, i64 8
  %130 = load double, ptr %129, align 8, !tbaa !9
  %131 = tail call double @sin(double noundef %119) #9
  %132 = insertelement <2 x double> poison, double %130, i64 0
  %133 = insertelement <2 x double> %132, double %124, i64 1
  %134 = insertelement <2 x double> poison, double %131, i64 0
  %135 = insertelement <2 x double> %134, double %125, i64 1
  %136 = fmul <2 x double> %133, %135
  %137 = insertelement <2 x double> poison, double %127, i64 0
  %138 = insertelement <2 x double> %137, double %121, i64 1
  %139 = insertelement <2 x double> poison, double %128, i64 0
  %140 = insertelement <2 x double> %139, double %122, i64 1
  %141 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %138, <2 x double> %140, <2 x double> %136)
  %142 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %141, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %113)
  %143 = getelementptr inbounds nuw i8, ptr %89, i64 16
  %144 = load double, ptr %143, align 8, !tbaa !9
  %145 = fmul double %90, %144
  %146 = getelementptr inbounds nuw i8, ptr %88, i64 16
  %147 = load double, ptr %146, align 16, !tbaa !9
  %148 = fmul double %90, %147
  %149 = getelementptr inbounds nuw i8, ptr %87, i64 16
  %150 = load double, ptr %149, align 8, !tbaa !9
  %151 = tail call double @cos(double noundef %145) #9
  %152 = getelementptr inbounds nuw i8, ptr %86, i64 16
  %153 = load double, ptr %152, align 8, !tbaa !9
  %154 = tail call double @sin(double noundef %145) #9
  %155 = getelementptr inbounds nuw i8, ptr %85, i64 16
  %156 = load double, ptr %155, align 16, !tbaa !9
  %157 = tail call double @cos(double noundef %148) #9
  %158 = getelementptr inbounds nuw i8, ptr %84, i64 16
  %159 = load double, ptr %158, align 16, !tbaa !9
  %160 = tail call double @sin(double noundef %148) #9
  %161 = insertelement <2 x double> poison, double %159, i64 0
  %162 = insertelement <2 x double> %161, double %153, i64 1
  %163 = insertelement <2 x double> poison, double %160, i64 0
  %164 = insertelement <2 x double> %163, double %154, i64 1
  %165 = fmul <2 x double> %162, %164
  %166 = insertelement <2 x double> poison, double %156, i64 0
  %167 = insertelement <2 x double> %166, double %150, i64 1
  %168 = insertelement <2 x double> poison, double %157, i64 0
  %169 = insertelement <2 x double> %168, double %151, i64 1
  %170 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %167, <2 x double> %169, <2 x double> %165)
  %171 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %170, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %142)
  %172 = getelementptr inbounds nuw i8, ptr %89, i64 24
  %173 = load double, ptr %172, align 8, !tbaa !9
  %174 = fmul double %90, %173
  %175 = getelementptr inbounds nuw i8, ptr %88, i64 24
  %176 = load double, ptr %175, align 8, !tbaa !9
  %177 = fmul double %90, %176
  %178 = getelementptr inbounds nuw i8, ptr %87, i64 24
  %179 = load double, ptr %178, align 8, !tbaa !9
  %180 = tail call double @cos(double noundef %174) #9
  %181 = getelementptr inbounds nuw i8, ptr %86, i64 24
  %182 = load double, ptr %181, align 8, !tbaa !9
  %183 = tail call double @sin(double noundef %174) #9
  %184 = getelementptr inbounds nuw i8, ptr %85, i64 24
  %185 = load double, ptr %184, align 8, !tbaa !9
  %186 = tail call double @cos(double noundef %177) #9
  %187 = getelementptr inbounds nuw i8, ptr %84, i64 24
  %188 = load double, ptr %187, align 8, !tbaa !9
  %189 = tail call double @sin(double noundef %177) #9
  %190 = insertelement <2 x double> poison, double %188, i64 0
  %191 = insertelement <2 x double> %190, double %182, i64 1
  %192 = insertelement <2 x double> poison, double %189, i64 0
  %193 = insertelement <2 x double> %192, double %183, i64 1
  %194 = fmul <2 x double> %191, %193
  %195 = insertelement <2 x double> poison, double %185, i64 0
  %196 = insertelement <2 x double> %195, double %179, i64 1
  %197 = insertelement <2 x double> poison, double %186, i64 0
  %198 = insertelement <2 x double> %197, double %180, i64 1
  %199 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %196, <2 x double> %198, <2 x double> %194)
  %200 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %199, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %171)
  %201 = getelementptr inbounds nuw i8, ptr %89, i64 32
  %202 = load double, ptr %201, align 8, !tbaa !9
  %203 = fmul double %90, %202
  %204 = getelementptr inbounds nuw i8, ptr %88, i64 32
  %205 = load double, ptr %204, align 16, !tbaa !9
  %206 = fmul double %90, %205
  %207 = getelementptr inbounds nuw i8, ptr %87, i64 32
  %208 = load double, ptr %207, align 8, !tbaa !9
  %209 = tail call double @cos(double noundef %203) #9
  %210 = getelementptr inbounds nuw i8, ptr %86, i64 32
  %211 = load double, ptr %210, align 8, !tbaa !9
  %212 = tail call double @sin(double noundef %203) #9
  %213 = getelementptr inbounds nuw i8, ptr %85, i64 32
  %214 = load double, ptr %213, align 16, !tbaa !9
  %215 = tail call double @cos(double noundef %206) #9
  %216 = getelementptr inbounds nuw i8, ptr %84, i64 32
  %217 = load double, ptr %216, align 16, !tbaa !9
  %218 = tail call double @sin(double noundef %206) #9
  %219 = insertelement <2 x double> poison, double %217, i64 0
  %220 = insertelement <2 x double> %219, double %211, i64 1
  %221 = insertelement <2 x double> poison, double %218, i64 0
  %222 = insertelement <2 x double> %221, double %212, i64 1
  %223 = fmul <2 x double> %220, %222
  %224 = insertelement <2 x double> poison, double %214, i64 0
  %225 = insertelement <2 x double> %224, double %208, i64 1
  %226 = insertelement <2 x double> poison, double %215, i64 0
  %227 = insertelement <2 x double> %226, double %209, i64 1
  %228 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %225, <2 x double> %227, <2 x double> %223)
  %229 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %228, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %200)
  %230 = getelementptr inbounds nuw i8, ptr %89, i64 40
  %231 = load double, ptr %230, align 8, !tbaa !9
  %232 = fmul double %90, %231
  %233 = getelementptr inbounds nuw i8, ptr %88, i64 40
  %234 = load double, ptr %233, align 8, !tbaa !9
  %235 = fmul double %90, %234
  %236 = getelementptr inbounds nuw i8, ptr %87, i64 40
  %237 = load double, ptr %236, align 8, !tbaa !9
  %238 = tail call double @cos(double noundef %232) #9
  %239 = getelementptr inbounds nuw i8, ptr %86, i64 40
  %240 = load double, ptr %239, align 8, !tbaa !9
  %241 = tail call double @sin(double noundef %232) #9
  %242 = getelementptr inbounds nuw i8, ptr %85, i64 40
  %243 = load double, ptr %242, align 8, !tbaa !9
  %244 = tail call double @cos(double noundef %235) #9
  %245 = getelementptr inbounds nuw i8, ptr %84, i64 40
  %246 = load double, ptr %245, align 8, !tbaa !9
  %247 = tail call double @sin(double noundef %235) #9
  %248 = insertelement <2 x double> poison, double %246, i64 0
  %249 = insertelement <2 x double> %248, double %240, i64 1
  %250 = insertelement <2 x double> poison, double %247, i64 0
  %251 = insertelement <2 x double> %250, double %241, i64 1
  %252 = fmul <2 x double> %249, %251
  %253 = insertelement <2 x double> poison, double %243, i64 0
  %254 = insertelement <2 x double> %253, double %237, i64 1
  %255 = insertelement <2 x double> poison, double %244, i64 0
  %256 = insertelement <2 x double> %255, double %238, i64 1
  %257 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %254, <2 x double> %256, <2 x double> %252)
  %258 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %257, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %229)
  %259 = getelementptr inbounds nuw i8, ptr %89, i64 48
  %260 = load double, ptr %259, align 8, !tbaa !9
  %261 = fmul double %90, %260
  %262 = getelementptr inbounds nuw i8, ptr %88, i64 48
  %263 = load double, ptr %262, align 16, !tbaa !9
  %264 = fmul double %90, %263
  %265 = getelementptr inbounds nuw i8, ptr %87, i64 48
  %266 = load double, ptr %265, align 8, !tbaa !9
  %267 = tail call double @cos(double noundef %261) #9
  %268 = getelementptr inbounds nuw i8, ptr %86, i64 48
  %269 = load double, ptr %268, align 8, !tbaa !9
  %270 = tail call double @sin(double noundef %261) #9
  %271 = getelementptr inbounds nuw i8, ptr %85, i64 48
  %272 = load double, ptr %271, align 16, !tbaa !9
  %273 = tail call double @cos(double noundef %264) #9
  %274 = getelementptr inbounds nuw i8, ptr %84, i64 48
  %275 = load double, ptr %274, align 16, !tbaa !9
  %276 = tail call double @sin(double noundef %264) #9
  %277 = insertelement <2 x double> poison, double %275, i64 0
  %278 = insertelement <2 x double> %277, double %269, i64 1
  %279 = insertelement <2 x double> poison, double %276, i64 0
  %280 = insertelement <2 x double> %279, double %270, i64 1
  %281 = fmul <2 x double> %278, %280
  %282 = insertelement <2 x double> poison, double %272, i64 0
  %283 = insertelement <2 x double> %282, double %266, i64 1
  %284 = insertelement <2 x double> poison, double %273, i64 0
  %285 = insertelement <2 x double> %284, double %267, i64 1
  %286 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %283, <2 x double> %285, <2 x double> %281)
  %287 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %286, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %258)
  %288 = getelementptr inbounds nuw i8, ptr %89, i64 56
  %289 = load double, ptr %288, align 8, !tbaa !9
  %290 = fmul double %90, %289
  %291 = getelementptr inbounds nuw i8, ptr %88, i64 56
  %292 = load double, ptr %291, align 8, !tbaa !9
  %293 = fmul double %90, %292
  %294 = getelementptr inbounds nuw i8, ptr %87, i64 56
  %295 = load double, ptr %294, align 8, !tbaa !9
  %296 = tail call double @cos(double noundef %290) #9
  %297 = getelementptr inbounds nuw i8, ptr %86, i64 56
  %298 = load double, ptr %297, align 8, !tbaa !9
  %299 = tail call double @sin(double noundef %290) #9
  %300 = getelementptr inbounds nuw i8, ptr %85, i64 56
  %301 = load double, ptr %300, align 8, !tbaa !9
  %302 = tail call double @cos(double noundef %293) #9
  %303 = getelementptr inbounds nuw i8, ptr %84, i64 56
  %304 = load double, ptr %303, align 8, !tbaa !9
  %305 = tail call double @sin(double noundef %293) #9
  %306 = insertelement <2 x double> poison, double %304, i64 0
  %307 = insertelement <2 x double> %306, double %298, i64 1
  %308 = insertelement <2 x double> poison, double %305, i64 0
  %309 = insertelement <2 x double> %308, double %299, i64 1
  %310 = fmul <2 x double> %307, %309
  %311 = insertelement <2 x double> poison, double %301, i64 0
  %312 = insertelement <2 x double> %311, double %295, i64 1
  %313 = insertelement <2 x double> poison, double %302, i64 0
  %314 = insertelement <2 x double> %313, double %296, i64 1
  %315 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %312, <2 x double> %314, <2 x double> %310)
  %316 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %315, <2 x double> splat (double f0x3E7AD7F29ABCAF48), <2 x double> %287)
  %317 = getelementptr inbounds nuw i8, ptr %89, i64 64
  %318 = load double, ptr %317, align 8, !tbaa !9
  %319 = fmul double %90, %318
  %320 = getelementptr inbounds nuw i8, ptr %87, i64 64
  %321 = load double, ptr %320, align 8, !tbaa !9
  %322 = tail call double @cos(double noundef %319) #9
  %323 = getelementptr inbounds nuw i8, ptr %86, i64 64
  %324 = load double, ptr %323, align 8, !tbaa !9
  %325 = tail call double @sin(double noundef %319) #9
  %326 = getelementptr inbounds nuw i8, ptr %88, i64 64
  %327 = load double, ptr %326, align 16, !tbaa !9
  %328 = fmul double %90, %327
  %329 = getelementptr inbounds nuw i8, ptr %85, i64 64
  %330 = load double, ptr %329, align 16, !tbaa !9
  %331 = tail call double @cos(double noundef %328) #9
  %332 = getelementptr inbounds nuw i8, ptr %84, i64 64
  %333 = load double, ptr %332, align 16, !tbaa !9
  %334 = tail call double @sin(double noundef %328) #9
  %335 = fmul double %333, %334
  %336 = tail call double @llvm.fmuladd.f64(double %330, double %331, double %335)
  %337 = fmul double %9, %336
  %338 = extractelement <2 x double> %316, i64 0
  %339 = tail call double @llvm.fmuladd.f64(double %337, double f0x3E7AD7F29ABCAF48, double %338)
  %340 = getelementptr inbounds nuw i8, ptr %88, i64 72
  %341 = load double, ptr %340, align 8, !tbaa !9
  %342 = fmul double %90, %341
  %343 = getelementptr inbounds nuw i8, ptr %85, i64 72
  %344 = load double, ptr %343, align 8, !tbaa !9
  %345 = tail call double @cos(double noundef %342) #9
  %346 = getelementptr inbounds nuw i8, ptr %84, i64 72
  %347 = load double, ptr %346, align 8, !tbaa !9
  %348 = tail call double @sin(double noundef %342) #9
  %349 = fmul double %347, %348
  %350 = tail call double @llvm.fmuladd.f64(double %344, double %345, double %349)
  %351 = fmul double %9, %350
  %352 = tail call double @llvm.fmuladd.f64(double %351, double f0x3E7AD7F29ABCAF48, double %339)
  %353 = tail call double @fmod(double noundef %352, double noundef f0x401921FB54442D18) #9
  %354 = fsub double %353, %56
  %355 = tail call double @sin(double noundef %354) #9
  %356 = tail call double @llvm.fmuladd.f64(double %37, double %355, double %354)
  %357 = fneg double %37
  %358 = fsub double %354, %356
  %359 = tail call double @sin(double noundef %356) #9
  %360 = tail call double @llvm.fmuladd.f64(double %37, double %359, double %358)
  %361 = tail call double @cos(double noundef %356) #9
  %362 = tail call double @llvm.fmuladd.f64(double %357, double %361, double 1.000000e+00)
  %363 = fdiv double %360, %362
  %364 = fadd double %356, %363
  %365 = tail call double @llvm.fabs.f64(double %363)
  %366 = fcmp olt double %365, f0x3D719799812DEA11
  br i1 %366, label %455, label %367

367:                                              ; preds = %80
  %368 = fsub double %354, %364
  %369 = tail call double @sin(double noundef %364) #9
  %370 = tail call double @llvm.fmuladd.f64(double %37, double %369, double %368)
  %371 = tail call double @cos(double noundef %364) #9
  %372 = tail call double @llvm.fmuladd.f64(double %357, double %371, double 1.000000e+00)
  %373 = fdiv double %370, %372
  %374 = fadd double %364, %373
  %375 = tail call double @llvm.fabs.f64(double %373)
  %376 = fcmp olt double %375, f0x3D719799812DEA11
  br i1 %376, label %455, label %377

377:                                              ; preds = %367
  %378 = fsub double %354, %374
  %379 = tail call double @sin(double noundef %374) #9
  %380 = tail call double @llvm.fmuladd.f64(double %37, double %379, double %378)
  %381 = tail call double @cos(double noundef %374) #9
  %382 = tail call double @llvm.fmuladd.f64(double %357, double %381, double 1.000000e+00)
  %383 = fdiv double %380, %382
  %384 = fadd double %374, %383
  %385 = tail call double @llvm.fabs.f64(double %383)
  %386 = fcmp olt double %385, f0x3D719799812DEA11
  br i1 %386, label %455, label %387

387:                                              ; preds = %377
  %388 = fsub double %354, %384
  %389 = tail call double @sin(double noundef %384) #9
  %390 = tail call double @llvm.fmuladd.f64(double %37, double %389, double %388)
  %391 = tail call double @cos(double noundef %384) #9
  %392 = tail call double @llvm.fmuladd.f64(double %357, double %391, double 1.000000e+00)
  %393 = fdiv double %390, %392
  %394 = fadd double %384, %393
  %395 = tail call double @llvm.fabs.f64(double %393)
  %396 = fcmp olt double %395, f0x3D719799812DEA11
  br i1 %396, label %455, label %397

397:                                              ; preds = %387
  %398 = fsub double %354, %394
  %399 = tail call double @sin(double noundef %394) #9
  %400 = tail call double @llvm.fmuladd.f64(double %37, double %399, double %398)
  %401 = tail call double @cos(double noundef %394) #9
  %402 = tail call double @llvm.fmuladd.f64(double %357, double %401, double 1.000000e+00)
  %403 = fdiv double %400, %402
  %404 = fadd double %394, %403
  %405 = tail call double @llvm.fabs.f64(double %403)
  %406 = fcmp olt double %405, f0x3D719799812DEA11
  br i1 %406, label %455, label %407

407:                                              ; preds = %397
  %408 = fsub double %354, %404
  %409 = tail call double @sin(double noundef %404) #9
  %410 = tail call double @llvm.fmuladd.f64(double %37, double %409, double %408)
  %411 = tail call double @cos(double noundef %404) #9
  %412 = tail call double @llvm.fmuladd.f64(double %357, double %411, double 1.000000e+00)
  %413 = fdiv double %410, %412
  %414 = fadd double %404, %413
  %415 = tail call double @llvm.fabs.f64(double %413)
  %416 = fcmp olt double %415, f0x3D719799812DEA11
  br i1 %416, label %455, label %417

417:                                              ; preds = %407
  %418 = fsub double %354, %414
  %419 = tail call double @sin(double noundef %414) #9
  %420 = tail call double @llvm.fmuladd.f64(double %37, double %419, double %418)
  %421 = tail call double @cos(double noundef %414) #9
  %422 = tail call double @llvm.fmuladd.f64(double %357, double %421, double 1.000000e+00)
  %423 = fdiv double %420, %422
  %424 = fadd double %414, %423
  %425 = tail call double @llvm.fabs.f64(double %423)
  %426 = fcmp olt double %425, f0x3D719799812DEA11
  br i1 %426, label %455, label %427

427:                                              ; preds = %417
  %428 = fsub double %354, %424
  %429 = tail call double @sin(double noundef %424) #9
  %430 = tail call double @llvm.fmuladd.f64(double %37, double %429, double %428)
  %431 = tail call double @cos(double noundef %424) #9
  %432 = tail call double @llvm.fmuladd.f64(double %357, double %431, double 1.000000e+00)
  %433 = fdiv double %430, %432
  %434 = fadd double %424, %433
  %435 = tail call double @llvm.fabs.f64(double %433)
  %436 = fcmp olt double %435, f0x3D719799812DEA11
  br i1 %436, label %455, label %437

437:                                              ; preds = %427
  %438 = fsub double %354, %434
  %439 = tail call double @sin(double noundef %434) #9
  %440 = tail call double @llvm.fmuladd.f64(double %37, double %439, double %438)
  %441 = tail call double @cos(double noundef %434) #9
  %442 = tail call double @llvm.fmuladd.f64(double %357, double %441, double 1.000000e+00)
  %443 = fdiv double %440, %442
  %444 = fadd double %434, %443
  %445 = tail call double @llvm.fabs.f64(double %443)
  %446 = fcmp olt double %445, f0x3D719799812DEA11
  br i1 %446, label %455, label %447

447:                                              ; preds = %437
  %448 = fsub double %354, %444
  %449 = tail call double @sin(double noundef %444) #9
  %450 = tail call double @llvm.fmuladd.f64(double %37, double %449, double %448)
  %451 = tail call double @cos(double noundef %444) #9
  %452 = tail call double @llvm.fmuladd.f64(double %357, double %451, double 1.000000e+00)
  %453 = fdiv double %450, %452
  %454 = fadd double %444, %453
  br label %455

455:                                              ; preds = %447, %437, %427, %417, %407, %397, %387, %377, %367, %80
  %456 = phi double [ %424, %417 ], [ %364, %80 ], [ %454, %447 ], [ %374, %367 ], [ %444, %437 ], [ %384, %377 ], [ %414, %407 ], [ %394, %387 ], [ %434, %427 ], [ %404, %397 ]
  %457 = fmul double %324, %325
  %458 = tail call double @llvm.fmuladd.f64(double %321, double %322, double %457)
  %459 = fmul double %9, %458
  %460 = extractelement <2 x double> %316, i64 1
  %461 = tail call double @llvm.fmuladd.f64(double %459, double f0x3E7AD7F29ABCAF48, double %460)
  %462 = tail call double @llvm.fmuladd.f64(double %62, double %9, double %60)
  %463 = fmul double %9, %462
  %464 = fmul double %456, 5.000000e-01
  %465 = fadd double %37, 1.000000e+00
  %466 = fsub double 1.000000e+00, %37
  %467 = fdiv double %465, %466
  %468 = tail call double @sqrt(double noundef %467) #9
  %469 = tail call double @sin(double noundef %464) #9
  %470 = fmul double %468, %469
  %471 = tail call double @cos(double noundef %464) #9
  %472 = tail call double @atan2(double noundef %470, double noundef %471) #9
  %473 = fmul double %472, 2.000000e+00
  %474 = tail call double @cos(double noundef %456) #9
  %475 = insertelement <2 x double> poison, double %58, i64 0
  %476 = insertelement <2 x double> %475, double %357, i64 1
  %477 = insertelement <2 x double> <double 3.600000e+03, double poison>, double %474, i64 1
  %478 = insertelement <2 x double> <double poison, double 1.000000e+00>, double %463, i64 0
  %479 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %476, <2 x double> %477, <2 x double> %478)
  %480 = extractelement <2 x double> %479, i64 0
  %481 = fmul double %480, f0x3ED455A5B2FF8F9D
  %482 = getelementptr inbounds [8 x i8], ptr @amas, i64 %10
  %483 = load double, ptr %482, align 8, !tbaa !9
  %484 = fdiv double 1.000000e+00, %483
  %485 = fadd double %484, 1.000000e+00
  %486 = fmul double %461, %461
  %487 = fmul double %461, %486
  %488 = fdiv double %485, %487
  %489 = tail call double @sqrt(double noundef %488) #9
  %490 = fmul double %481, 5.000000e-01
  %491 = tail call double @sin(double noundef %490) #9
  %492 = tail call double @cos(double noundef %81) #9
  %493 = fmul double %491, %492
  %494 = tail call double @sin(double noundef %81) #9
  %495 = fadd double %56, %473
  %496 = tail call double @sin(double noundef %495) #9
  %497 = tail call double @cos(double noundef %495) #9
  %498 = fneg double %496
  %499 = fmul double %493, %498
  %500 = tail call double @llvm.fmuladd.f64(double %357, double %37, double 1.000000e+00)
  %501 = tail call double @sqrt(double noundef %500) #9
  %502 = fdiv double %461, %501
  %503 = tail call double @cos(double noundef %490) #9
  %504 = tail call double @sin(double noundef %56) #9
  %505 = tail call double @llvm.fmuladd.f64(double %37, double %504, double %496)
  %506 = tail call double @cos(double noundef %56) #9
  %507 = tail call double @llvm.fmuladd.f64(double %37, double %506, double %497)
  %508 = fmul double %502, %507
  %509 = getelementptr inbounds nuw i8, ptr %2, i64 8
  %510 = insertelement <2 x double> poison, double %461, i64 0
  %511 = insertelement <2 x double> %510, double %489, i64 1
  %512 = shufflevector <2 x double> <double poison, double f0x3F919D6D51A6B69A>, <2 x double> %479, <2 x i32> <i32 3, i32 1>
  %513 = fmul <2 x double> %511, %512
  %514 = insertelement <2 x double> poison, double %491, i64 0
  %515 = insertelement <2 x double> %514, double %502, i64 1
  %516 = insertelement <2 x double> poison, double %494, i64 0
  %517 = insertelement <2 x double> %516, double %505, i64 1
  %518 = fmul <2 x double> %515, %517
  %519 = extractelement <2 x double> %518, i64 0
  %520 = tail call double @llvm.fmuladd.f64(double %519, double %497, double %499)
  %521 = extractelement <2 x double> %513, i64 0
  %522 = shufflevector <2 x double> %518, <2 x double> poison, <2 x i32> <i32 poison, i32 0>
  %523 = insertelement <2 x double> %522, double %520, i64 0
  %524 = fmul <2 x double> %523, splat (double 2.000000e+00)
  %525 = extractelement <2 x double> %524, i64 1
  %526 = fmul double %493, %525
  %527 = extractelement <2 x double> %524, i64 0
  %528 = fneg double %527
  %529 = insertelement <2 x double> %522, double %493, i64 0
  %530 = insertelement <2 x double> <double poison, double -1.000000e+00>, double %496, i64 0
  %531 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %524, <2 x double> %529, <2 x double> %530)
  %532 = fmul <2 x double> %513, %531
  %533 = fmul double %503, %528
  %534 = fmul double %521, %533
  %535 = fmul double %526, %508
  %536 = insertelement <2 x double> %531, double %528, i64 0
  %537 = insertelement <2 x double> poison, double %497, i64 0
  %538 = insertelement <2 x double> %537, double %535, i64 1
  %539 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %536, <2 x double> %518, <2 x double> %538)
  %540 = fmul <2 x double> %513, %539
  %541 = extractelement <2 x double> %540, i64 0
  store double %541, ptr %2, align 8, !tbaa !9
  %542 = insertelement <2 x double> poison, double %534, i64 0
  %543 = shufflevector <2 x double> %542, <2 x double> poison, <2 x i32> zeroinitializer
  %544 = fmul <2 x double> %543, <double f0xBFD9752E50F4B399, double f0x3FED5C0357681EF3>
  %545 = shufflevector <2 x double> %532, <2 x double> poison, <2 x i32> zeroinitializer
  %546 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %545, <2 x double> <double f0x3FED5C0357681EF3, double f0x3FD9752E50F4B399>, <2 x double> %544)
  store <2 x double> %546, ptr %509, align 8, !tbaa !9
  %547 = fmul double %493, -2.000000e+00
  %548 = tail call double @llvm.fmuladd.f64(double %547, double %493, double 1.000000e+00)
  %549 = extractelement <2 x double> %518, i64 1
  %550 = fneg double %549
  %551 = fmul double %526, %550
  %552 = tail call double @llvm.fmuladd.f64(double %548, double %508, double %551)
  %553 = extractelement <2 x double> %513, i64 1
  %554 = fmul double %553, %552
  %555 = fmul double %503, 2.000000e+00
  %556 = fmul double %493, %508
  %557 = tail call double @llvm.fmuladd.f64(double %519, double %549, double %556)
  %558 = fmul double %555, %557
  %559 = fmul double %553, %558
  %560 = getelementptr inbounds nuw i8, ptr %2, i64 24
  %561 = extractelement <2 x double> %540, i64 1
  store double %561, ptr %560, align 8, !tbaa !9
  %562 = getelementptr inbounds nuw i8, ptr %2, i64 32
  %563 = insertelement <2 x double> poison, double %559, i64 0
  %564 = shufflevector <2 x double> %563, <2 x double> poison, <2 x i32> zeroinitializer
  %565 = fmul <2 x double> %564, <double f0xBFD9752E50F4B399, double f0x3FED5C0357681EF3>
  %566 = insertelement <2 x double> poison, double %554, i64 0
  %567 = shufflevector <2 x double> %566, <2 x double> poison, <2 x i32> zeroinitializer
  %568 = tail call <2 x double> @llvm.fmuladd.v2f64(<2 x double> %567, <2 x double> <double f0x3FED5C0357681EF3, double f0x3FD9752E50F4B399>, <2 x double> %565)
  store <2 x double> %568, ptr %562, align 8, !tbaa !9
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.fmuladd.f64(double, double, double) #3

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @cos(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sin(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @atan2(double noundef, double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @sqrt(double noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite, errnomem: write) uwtable
define dso_local void @radecdist(ptr nofree noundef readonly captures(none) %0, ptr nofree noundef writeonly captures(none) initializes((0, 24)) %1) local_unnamed_addr #5 {
  %3 = load double, ptr %0, align 8, !tbaa !9
  %4 = getelementptr inbounds nuw i8, ptr %0, i64 8
  %5 = load double, ptr %4, align 8, !tbaa !9
  %6 = fmul double %5, %5
  %7 = tail call double @llvm.fmuladd.f64(double %3, double %3, double %6)
  %8 = getelementptr inbounds nuw i8, ptr %0, i64 16
  %9 = load double, ptr %8, align 8, !tbaa !9
  %10 = tail call double @llvm.fmuladd.f64(double %9, double %9, double %7)
  %11 = tail call double @llvm.sqrt.f64(double %10)
  %12 = getelementptr inbounds nuw i8, ptr %1, i64 16
  store double %11, ptr %12, align 8, !tbaa !9
  %13 = load double, ptr %4, align 8, !tbaa !9
  %14 = load double, ptr %0, align 8, !tbaa !9
  %15 = tail call double @atan2(double noundef %13, double noundef %14) #9
  %16 = fmul double %15, f0x400E8EC8A4AEACC4
  %17 = fcmp olt double %16, 0.000000e+00
  %18 = fadd double %16, 2.400000e+01
  %19 = select i1 %17, double %18, double %16
  store double %19, ptr %1, align 8, !tbaa !9
  %20 = load double, ptr %8, align 8, !tbaa !9
  %21 = fdiv double %20, %11
  %22 = tail call double @asin(double noundef %21) #9
  %23 = fmul double %22, f0x404CA5DC1A63C1F8
  %24 = getelementptr inbounds nuw i8, ptr %1, i64 8
  store double %23, ptr %24, align 8, !tbaa !9
  ret void
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write)
declare double @asin(double noundef) local_unnamed_addr #2

; Function Attrs: nofree nounwind uwtable
define dso_local noundef i32 @main(i32 noundef %0, ptr nofree noundef readonly captures(none) %1) local_unnamed_addr #6 {
  %3 = alloca [2 x double], align 16
  %4 = alloca [2 x [3 x double]], align 16
  %5 = alloca [8 x [3 x double]], align 16
  call void @llvm.lifetime.start.p0(ptr nonnull %3) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %4) #9
  call void @llvm.lifetime.start.p0(ptr nonnull %5) #9
  %6 = getelementptr inbounds nuw i8, ptr %3, i64 8
  store double 0.000000e+00, ptr %6, align 8, !tbaa !9
  %7 = getelementptr inbounds nuw i8, ptr %4, i64 8
  %8 = getelementptr inbounds nuw i8, ptr %4, i64 16
  br label %9

9:                                                ; preds = %2, %41
  %10 = phi i32 [ 0, %2 ], [ %42, %41 ]
  br label %11

11:                                               ; preds = %9, %38
  %12 = phi i32 [ 0, %9 ], [ %39, %38 ]
  %13 = phi double [ f0x4142B42C80000000, %9 ], [ %14, %38 ]
  %14 = fadd double %13, 1.000000e+00
  store double %14, ptr %3, align 16, !tbaa !9
  br label %15

15:                                               ; preds = %11, %15
  %16 = phi i64 [ 0, %11 ], [ %36, %15 ]
  %17 = trunc nuw nsw i64 %16 to i32
  call void @planetpv(ptr noundef nonnull %3, i32 noundef %17, ptr noundef nonnull %4)
  %18 = getelementptr inbounds nuw [24 x i8], ptr %5, i64 %16
  %19 = load double, ptr %4, align 16, !tbaa !9
  %20 = load double, ptr %7, align 8, !tbaa !9
  %21 = fmul double %20, %20
  %22 = tail call double @llvm.fmuladd.f64(double %19, double %19, double %21)
  %23 = load double, ptr %8, align 16, !tbaa !9
  %24 = tail call double @llvm.fmuladd.f64(double %23, double %23, double %22)
  %25 = tail call double @llvm.sqrt.f64(double %24)
  %26 = getelementptr inbounds nuw i8, ptr %18, i64 16
  store double %25, ptr %26, align 8, !tbaa !9
  %27 = tail call double @atan2(double noundef %20, double noundef %19) #9
  %28 = fmul double %27, f0x400E8EC8A4AEACC4
  %29 = fcmp olt double %28, 0.000000e+00
  %30 = fadd double %28, 2.400000e+01
  %31 = select i1 %29, double %30, double %28
  store double %31, ptr %18, align 8, !tbaa !9
  %32 = fdiv double %23, %25
  %33 = tail call double @asin(double noundef %32) #9
  %34 = fmul double %33, f0x404CA5DC1A63C1F8
  %35 = getelementptr inbounds nuw i8, ptr %18, i64 8
  store double %34, ptr %35, align 8, !tbaa !9
  %36 = add nuw nsw i64 %16, 1
  %37 = icmp eq i64 %36, 8
  br i1 %37, label %38, label %15, !llvm.loop !11

38:                                               ; preds = %15
  %39 = add nuw nsw i32 %12, 1
  %40 = icmp eq i32 %39, 36525
  br i1 %40, label %41, label %11, !llvm.loop !13

41:                                               ; preds = %38
  %42 = add nuw nsw i32 %10, 1
  %43 = icmp eq i32 %42, 20
  br i1 %43, label %44, label %9, !llvm.loop !14

44:                                               ; preds = %41
  %45 = load double, ptr %5, align 16, !tbaa !9
  %46 = getelementptr inbounds nuw i8, ptr %5, i64 8
  %47 = load double, ptr %46, align 8, !tbaa !9
  %48 = getelementptr inbounds nuw i8, ptr %5, i64 16
  %49 = load double, ptr %48, align 16, !tbaa !9
  %50 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %45, double noundef %47, double noundef %49)
  %51 = getelementptr inbounds nuw i8, ptr %5, i64 24
  %52 = load double, ptr %51, align 8, !tbaa !9
  %53 = getelementptr inbounds nuw i8, ptr %5, i64 32
  %54 = load double, ptr %53, align 16, !tbaa !9
  %55 = getelementptr inbounds nuw i8, ptr %5, i64 40
  %56 = load double, ptr %55, align 8, !tbaa !9
  %57 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %52, double noundef %54, double noundef %56)
  %58 = getelementptr inbounds nuw i8, ptr %5, i64 48
  %59 = load double, ptr %58, align 16, !tbaa !9
  %60 = getelementptr inbounds nuw i8, ptr %5, i64 56
  %61 = load double, ptr %60, align 8, !tbaa !9
  %62 = getelementptr inbounds nuw i8, ptr %5, i64 64
  %63 = load double, ptr %62, align 16, !tbaa !9
  %64 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %59, double noundef %61, double noundef %63)
  %65 = getelementptr inbounds nuw i8, ptr %5, i64 72
  %66 = load double, ptr %65, align 8, !tbaa !9
  %67 = getelementptr inbounds nuw i8, ptr %5, i64 80
  %68 = load double, ptr %67, align 16, !tbaa !9
  %69 = getelementptr inbounds nuw i8, ptr %5, i64 88
  %70 = load double, ptr %69, align 8, !tbaa !9
  %71 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %66, double noundef %68, double noundef %70)
  %72 = getelementptr inbounds nuw i8, ptr %5, i64 96
  %73 = load double, ptr %72, align 16, !tbaa !9
  %74 = getelementptr inbounds nuw i8, ptr %5, i64 104
  %75 = load double, ptr %74, align 8, !tbaa !9
  %76 = getelementptr inbounds nuw i8, ptr %5, i64 112
  %77 = load double, ptr %76, align 16, !tbaa !9
  %78 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %73, double noundef %75, double noundef %77)
  %79 = getelementptr inbounds nuw i8, ptr %5, i64 120
  %80 = load double, ptr %79, align 8, !tbaa !9
  %81 = getelementptr inbounds nuw i8, ptr %5, i64 128
  %82 = load double, ptr %81, align 16, !tbaa !9
  %83 = getelementptr inbounds nuw i8, ptr %5, i64 136
  %84 = load double, ptr %83, align 8, !tbaa !9
  %85 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %80, double noundef %82, double noundef %84)
  %86 = getelementptr inbounds nuw i8, ptr %5, i64 144
  %87 = load double, ptr %86, align 16, !tbaa !9
  %88 = getelementptr inbounds nuw i8, ptr %5, i64 152
  %89 = load double, ptr %88, align 8, !tbaa !9
  %90 = getelementptr inbounds nuw i8, ptr %5, i64 160
  %91 = load double, ptr %90, align 16, !tbaa !9
  %92 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %87, double noundef %89, double noundef %91)
  %93 = getelementptr inbounds nuw i8, ptr %5, i64 168
  %94 = load double, ptr %93, align 8, !tbaa !9
  %95 = getelementptr inbounds nuw i8, ptr %5, i64 176
  %96 = load double, ptr %95, align 16, !tbaa !9
  %97 = getelementptr inbounds nuw i8, ptr %5, i64 184
  %98 = load double, ptr %97, align 8, !tbaa !9
  %99 = tail call i32 (ptr, ...) @printf(ptr noundef nonnull dereferenceable(1) @.str.1, double noundef %94, double noundef %96, double noundef %98)
  %100 = load ptr, ptr @stdout, align 8, !tbaa !15
  %101 = tail call i32 @fflush(ptr noundef %100)
  call void @llvm.lifetime.end.p0(ptr nonnull %5) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %4) #9
  call void @llvm.lifetime.end.p0(ptr nonnull %3) #9
  ret i32 0
}

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr noundef readonly captures(none), ...) local_unnamed_addr #7

; Function Attrs: nofree nounwind
declare noundef i32 @fflush(ptr noundef captures(none)) local_unnamed_addr #7

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.sqrt.f64(double) #8

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x double> @llvm.fmuladd.v2f64(<2 x double>, <2 x double>, <2 x double>) #8

attributes #0 = { mustprogress nofree norecurse nosync nounwind willreturn memory(errnomem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { mustprogress nocallback nofree nosync nounwind willreturn memory(errnomem: write) "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #4 = { nofree norecurse nosync nounwind memory(argmem: readwrite, errnomem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #5 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: readwrite, errnomem: write) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #6 = { nofree nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #7 = { nofree nounwind "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #8 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
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
!9 = !{!10, !10, i64 0}
!10 = !{!"double", !7, i64 0}
!11 = distinct !{!11, !12}
!12 = !{!"llvm.loop.mustprogress"}
!13 = distinct !{!13, !12}
!14 = distinct !{!14, !12}
!15 = !{!16, !16, i64 0}
!16 = !{!"p1 _ZTS8_IO_FILE", !17, i64 0}
!17 = !{!"any pointer", !7, i64 0}
