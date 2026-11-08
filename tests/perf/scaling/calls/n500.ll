; @perf-size: 500
; @opt: -passes=inline
; @opt: -O2
; @perf: opt
; @perf: opt -passes=inline
; @perf: opt -O2
; @generated: harness/run gen-perf, shape 'calls', n=500
define internal i32 @f0(i32 %x) {
  %r = add i32 %x, 1
  ret i32 %r
}
define internal i32 @f1(i32 %x) {
  %a = call i32 @f0(i32 %x)
  %b = call i32 @f0(i32 %a)
  %r = xor i32 %b, 1
  ret i32 %r
}
define internal i32 @f2(i32 %x) {
  %a = call i32 @f1(i32 %x)
  %b = call i32 @f1(i32 %a)
  %r = xor i32 %b, 2
  ret i32 %r
}
define internal i32 @f3(i32 %x) {
  %a = call i32 @f2(i32 %x)
  %b = call i32 @f1(i32 %a)
  %r = xor i32 %b, 3
  ret i32 %r
}
define internal i32 @f4(i32 %x) {
  %a = call i32 @f3(i32 %x)
  %b = call i32 @f2(i32 %a)
  %r = xor i32 %b, 4
  ret i32 %r
}
define internal i32 @f5(i32 %x) {
  %a = call i32 @f4(i32 %x)
  %b = call i32 @f2(i32 %a)
  %r = xor i32 %b, 5
  ret i32 %r
}
define internal i32 @f6(i32 %x) {
  %a = call i32 @f5(i32 %x)
  %b = call i32 @f3(i32 %a)
  %r = xor i32 %b, 6
  ret i32 %r
}
define internal i32 @f7(i32 %x) {
  %a = call i32 @f6(i32 %x)
  %b = call i32 @f3(i32 %a)
  %r = xor i32 %b, 7
  ret i32 %r
}
define internal i32 @f8(i32 %x) {
  %a = call i32 @f7(i32 %x)
  %b = call i32 @f4(i32 %a)
  %r = xor i32 %b, 8
  ret i32 %r
}
define internal i32 @f9(i32 %x) {
  %a = call i32 @f8(i32 %x)
  %b = call i32 @f4(i32 %a)
  %r = xor i32 %b, 9
  ret i32 %r
}
define internal i32 @f10(i32 %x) {
  %a = call i32 @f9(i32 %x)
  %b = call i32 @f5(i32 %a)
  %r = xor i32 %b, 10
  ret i32 %r
}
define internal i32 @f11(i32 %x) {
  %a = call i32 @f10(i32 %x)
  %b = call i32 @f5(i32 %a)
  %r = xor i32 %b, 11
  ret i32 %r
}
define internal i32 @f12(i32 %x) {
  %a = call i32 @f11(i32 %x)
  %b = call i32 @f6(i32 %a)
  %r = xor i32 %b, 12
  ret i32 %r
}
define internal i32 @f13(i32 %x) {
  %a = call i32 @f12(i32 %x)
  %b = call i32 @f6(i32 %a)
  %r = xor i32 %b, 13
  ret i32 %r
}
define internal i32 @f14(i32 %x) {
  %a = call i32 @f13(i32 %x)
  %b = call i32 @f7(i32 %a)
  %r = xor i32 %b, 14
  ret i32 %r
}
define internal i32 @f15(i32 %x) {
  %a = call i32 @f14(i32 %x)
  %b = call i32 @f7(i32 %a)
  %r = xor i32 %b, 15
  ret i32 %r
}
define internal i32 @f16(i32 %x) {
  %a = call i32 @f15(i32 %x)
  %b = call i32 @f8(i32 %a)
  %r = xor i32 %b, 16
  ret i32 %r
}
define internal i32 @f17(i32 %x) {
  %a = call i32 @f16(i32 %x)
  %b = call i32 @f8(i32 %a)
  %r = xor i32 %b, 17
  ret i32 %r
}
define internal i32 @f18(i32 %x) {
  %a = call i32 @f17(i32 %x)
  %b = call i32 @f9(i32 %a)
  %r = xor i32 %b, 18
  ret i32 %r
}
define internal i32 @f19(i32 %x) {
  %a = call i32 @f18(i32 %x)
  %b = call i32 @f9(i32 %a)
  %r = xor i32 %b, 19
  ret i32 %r
}
define internal i32 @f20(i32 %x) {
  %a = call i32 @f19(i32 %x)
  %b = call i32 @f10(i32 %a)
  %r = xor i32 %b, 20
  ret i32 %r
}
define internal i32 @f21(i32 %x) {
  %a = call i32 @f20(i32 %x)
  %b = call i32 @f10(i32 %a)
  %r = xor i32 %b, 21
  ret i32 %r
}
define internal i32 @f22(i32 %x) {
  %a = call i32 @f21(i32 %x)
  %b = call i32 @f11(i32 %a)
  %r = xor i32 %b, 22
  ret i32 %r
}
define internal i32 @f23(i32 %x) {
  %a = call i32 @f22(i32 %x)
  %b = call i32 @f11(i32 %a)
  %r = xor i32 %b, 23
  ret i32 %r
}
define internal i32 @f24(i32 %x) {
  %a = call i32 @f23(i32 %x)
  %b = call i32 @f12(i32 %a)
  %r = xor i32 %b, 24
  ret i32 %r
}
define internal i32 @f25(i32 %x) {
  %a = call i32 @f24(i32 %x)
  %b = call i32 @f12(i32 %a)
  %r = xor i32 %b, 25
  ret i32 %r
}
define internal i32 @f26(i32 %x) {
  %a = call i32 @f25(i32 %x)
  %b = call i32 @f13(i32 %a)
  %r = xor i32 %b, 26
  ret i32 %r
}
define internal i32 @f27(i32 %x) {
  %a = call i32 @f26(i32 %x)
  %b = call i32 @f13(i32 %a)
  %r = xor i32 %b, 27
  ret i32 %r
}
define internal i32 @f28(i32 %x) {
  %a = call i32 @f27(i32 %x)
  %b = call i32 @f14(i32 %a)
  %r = xor i32 %b, 28
  ret i32 %r
}
define internal i32 @f29(i32 %x) {
  %a = call i32 @f28(i32 %x)
  %b = call i32 @f14(i32 %a)
  %r = xor i32 %b, 29
  ret i32 %r
}
define internal i32 @f30(i32 %x) {
  %a = call i32 @f29(i32 %x)
  %b = call i32 @f15(i32 %a)
  %r = xor i32 %b, 30
  ret i32 %r
}
define internal i32 @f31(i32 %x) {
  %a = call i32 @f30(i32 %x)
  %b = call i32 @f15(i32 %a)
  %r = xor i32 %b, 31
  ret i32 %r
}
define internal i32 @f32(i32 %x) {
  %a = call i32 @f31(i32 %x)
  %b = call i32 @f16(i32 %a)
  %r = xor i32 %b, 32
  ret i32 %r
}
define internal i32 @f33(i32 %x) {
  %a = call i32 @f32(i32 %x)
  %b = call i32 @f16(i32 %a)
  %r = xor i32 %b, 33
  ret i32 %r
}
define internal i32 @f34(i32 %x) {
  %a = call i32 @f33(i32 %x)
  %b = call i32 @f17(i32 %a)
  %r = xor i32 %b, 34
  ret i32 %r
}
define internal i32 @f35(i32 %x) {
  %a = call i32 @f34(i32 %x)
  %b = call i32 @f17(i32 %a)
  %r = xor i32 %b, 35
  ret i32 %r
}
define internal i32 @f36(i32 %x) {
  %a = call i32 @f35(i32 %x)
  %b = call i32 @f18(i32 %a)
  %r = xor i32 %b, 36
  ret i32 %r
}
define internal i32 @f37(i32 %x) {
  %a = call i32 @f36(i32 %x)
  %b = call i32 @f18(i32 %a)
  %r = xor i32 %b, 37
  ret i32 %r
}
define internal i32 @f38(i32 %x) {
  %a = call i32 @f37(i32 %x)
  %b = call i32 @f19(i32 %a)
  %r = xor i32 %b, 38
  ret i32 %r
}
define internal i32 @f39(i32 %x) {
  %a = call i32 @f38(i32 %x)
  %b = call i32 @f19(i32 %a)
  %r = xor i32 %b, 39
  ret i32 %r
}
define internal i32 @f40(i32 %x) {
  %a = call i32 @f39(i32 %x)
  %b = call i32 @f20(i32 %a)
  %r = xor i32 %b, 40
  ret i32 %r
}
define internal i32 @f41(i32 %x) {
  %a = call i32 @f40(i32 %x)
  %b = call i32 @f20(i32 %a)
  %r = xor i32 %b, 41
  ret i32 %r
}
define internal i32 @f42(i32 %x) {
  %a = call i32 @f41(i32 %x)
  %b = call i32 @f21(i32 %a)
  %r = xor i32 %b, 42
  ret i32 %r
}
define internal i32 @f43(i32 %x) {
  %a = call i32 @f42(i32 %x)
  %b = call i32 @f21(i32 %a)
  %r = xor i32 %b, 43
  ret i32 %r
}
define internal i32 @f44(i32 %x) {
  %a = call i32 @f43(i32 %x)
  %b = call i32 @f22(i32 %a)
  %r = xor i32 %b, 44
  ret i32 %r
}
define internal i32 @f45(i32 %x) {
  %a = call i32 @f44(i32 %x)
  %b = call i32 @f22(i32 %a)
  %r = xor i32 %b, 45
  ret i32 %r
}
define internal i32 @f46(i32 %x) {
  %a = call i32 @f45(i32 %x)
  %b = call i32 @f23(i32 %a)
  %r = xor i32 %b, 46
  ret i32 %r
}
define internal i32 @f47(i32 %x) {
  %a = call i32 @f46(i32 %x)
  %b = call i32 @f23(i32 %a)
  %r = xor i32 %b, 47
  ret i32 %r
}
define internal i32 @f48(i32 %x) {
  %a = call i32 @f47(i32 %x)
  %b = call i32 @f24(i32 %a)
  %r = xor i32 %b, 48
  ret i32 %r
}
define internal i32 @f49(i32 %x) {
  %a = call i32 @f48(i32 %x)
  %b = call i32 @f24(i32 %a)
  %r = xor i32 %b, 49
  ret i32 %r
}
define internal i32 @f50(i32 %x) {
  %a = call i32 @f49(i32 %x)
  %b = call i32 @f25(i32 %a)
  %r = xor i32 %b, 50
  ret i32 %r
}
define internal i32 @f51(i32 %x) {
  %a = call i32 @f50(i32 %x)
  %b = call i32 @f25(i32 %a)
  %r = xor i32 %b, 51
  ret i32 %r
}
define internal i32 @f52(i32 %x) {
  %a = call i32 @f51(i32 %x)
  %b = call i32 @f26(i32 %a)
  %r = xor i32 %b, 52
  ret i32 %r
}
define internal i32 @f53(i32 %x) {
  %a = call i32 @f52(i32 %x)
  %b = call i32 @f26(i32 %a)
  %r = xor i32 %b, 53
  ret i32 %r
}
define internal i32 @f54(i32 %x) {
  %a = call i32 @f53(i32 %x)
  %b = call i32 @f27(i32 %a)
  %r = xor i32 %b, 54
  ret i32 %r
}
define internal i32 @f55(i32 %x) {
  %a = call i32 @f54(i32 %x)
  %b = call i32 @f27(i32 %a)
  %r = xor i32 %b, 55
  ret i32 %r
}
define internal i32 @f56(i32 %x) {
  %a = call i32 @f55(i32 %x)
  %b = call i32 @f28(i32 %a)
  %r = xor i32 %b, 56
  ret i32 %r
}
define internal i32 @f57(i32 %x) {
  %a = call i32 @f56(i32 %x)
  %b = call i32 @f28(i32 %a)
  %r = xor i32 %b, 57
  ret i32 %r
}
define internal i32 @f58(i32 %x) {
  %a = call i32 @f57(i32 %x)
  %b = call i32 @f29(i32 %a)
  %r = xor i32 %b, 58
  ret i32 %r
}
define internal i32 @f59(i32 %x) {
  %a = call i32 @f58(i32 %x)
  %b = call i32 @f29(i32 %a)
  %r = xor i32 %b, 59
  ret i32 %r
}
define internal i32 @f60(i32 %x) {
  %a = call i32 @f59(i32 %x)
  %b = call i32 @f30(i32 %a)
  %r = xor i32 %b, 60
  ret i32 %r
}
define internal i32 @f61(i32 %x) {
  %a = call i32 @f60(i32 %x)
  %b = call i32 @f30(i32 %a)
  %r = xor i32 %b, 61
  ret i32 %r
}
define internal i32 @f62(i32 %x) {
  %a = call i32 @f61(i32 %x)
  %b = call i32 @f31(i32 %a)
  %r = xor i32 %b, 62
  ret i32 %r
}
define internal i32 @f63(i32 %x) {
  %a = call i32 @f62(i32 %x)
  %b = call i32 @f31(i32 %a)
  %r = xor i32 %b, 63
  ret i32 %r
}
define internal i32 @f64(i32 %x) {
  %a = call i32 @f63(i32 %x)
  %b = call i32 @f32(i32 %a)
  %r = xor i32 %b, 64
  ret i32 %r
}
define internal i32 @f65(i32 %x) {
  %a = call i32 @f64(i32 %x)
  %b = call i32 @f32(i32 %a)
  %r = xor i32 %b, 65
  ret i32 %r
}
define internal i32 @f66(i32 %x) {
  %a = call i32 @f65(i32 %x)
  %b = call i32 @f33(i32 %a)
  %r = xor i32 %b, 66
  ret i32 %r
}
define internal i32 @f67(i32 %x) {
  %a = call i32 @f66(i32 %x)
  %b = call i32 @f33(i32 %a)
  %r = xor i32 %b, 67
  ret i32 %r
}
define internal i32 @f68(i32 %x) {
  %a = call i32 @f67(i32 %x)
  %b = call i32 @f34(i32 %a)
  %r = xor i32 %b, 68
  ret i32 %r
}
define internal i32 @f69(i32 %x) {
  %a = call i32 @f68(i32 %x)
  %b = call i32 @f34(i32 %a)
  %r = xor i32 %b, 69
  ret i32 %r
}
define internal i32 @f70(i32 %x) {
  %a = call i32 @f69(i32 %x)
  %b = call i32 @f35(i32 %a)
  %r = xor i32 %b, 70
  ret i32 %r
}
define internal i32 @f71(i32 %x) {
  %a = call i32 @f70(i32 %x)
  %b = call i32 @f35(i32 %a)
  %r = xor i32 %b, 71
  ret i32 %r
}
define internal i32 @f72(i32 %x) {
  %a = call i32 @f71(i32 %x)
  %b = call i32 @f36(i32 %a)
  %r = xor i32 %b, 72
  ret i32 %r
}
define internal i32 @f73(i32 %x) {
  %a = call i32 @f72(i32 %x)
  %b = call i32 @f36(i32 %a)
  %r = xor i32 %b, 73
  ret i32 %r
}
define internal i32 @f74(i32 %x) {
  %a = call i32 @f73(i32 %x)
  %b = call i32 @f37(i32 %a)
  %r = xor i32 %b, 74
  ret i32 %r
}
define internal i32 @f75(i32 %x) {
  %a = call i32 @f74(i32 %x)
  %b = call i32 @f37(i32 %a)
  %r = xor i32 %b, 75
  ret i32 %r
}
define internal i32 @f76(i32 %x) {
  %a = call i32 @f75(i32 %x)
  %b = call i32 @f38(i32 %a)
  %r = xor i32 %b, 76
  ret i32 %r
}
define internal i32 @f77(i32 %x) {
  %a = call i32 @f76(i32 %x)
  %b = call i32 @f38(i32 %a)
  %r = xor i32 %b, 77
  ret i32 %r
}
define internal i32 @f78(i32 %x) {
  %a = call i32 @f77(i32 %x)
  %b = call i32 @f39(i32 %a)
  %r = xor i32 %b, 78
  ret i32 %r
}
define internal i32 @f79(i32 %x) {
  %a = call i32 @f78(i32 %x)
  %b = call i32 @f39(i32 %a)
  %r = xor i32 %b, 79
  ret i32 %r
}
define internal i32 @f80(i32 %x) {
  %a = call i32 @f79(i32 %x)
  %b = call i32 @f40(i32 %a)
  %r = xor i32 %b, 80
  ret i32 %r
}
define internal i32 @f81(i32 %x) {
  %a = call i32 @f80(i32 %x)
  %b = call i32 @f40(i32 %a)
  %r = xor i32 %b, 81
  ret i32 %r
}
define internal i32 @f82(i32 %x) {
  %a = call i32 @f81(i32 %x)
  %b = call i32 @f41(i32 %a)
  %r = xor i32 %b, 82
  ret i32 %r
}
define internal i32 @f83(i32 %x) {
  %a = call i32 @f82(i32 %x)
  %b = call i32 @f41(i32 %a)
  %r = xor i32 %b, 83
  ret i32 %r
}
define internal i32 @f84(i32 %x) {
  %a = call i32 @f83(i32 %x)
  %b = call i32 @f42(i32 %a)
  %r = xor i32 %b, 84
  ret i32 %r
}
define internal i32 @f85(i32 %x) {
  %a = call i32 @f84(i32 %x)
  %b = call i32 @f42(i32 %a)
  %r = xor i32 %b, 85
  ret i32 %r
}
define internal i32 @f86(i32 %x) {
  %a = call i32 @f85(i32 %x)
  %b = call i32 @f43(i32 %a)
  %r = xor i32 %b, 86
  ret i32 %r
}
define internal i32 @f87(i32 %x) {
  %a = call i32 @f86(i32 %x)
  %b = call i32 @f43(i32 %a)
  %r = xor i32 %b, 87
  ret i32 %r
}
define internal i32 @f88(i32 %x) {
  %a = call i32 @f87(i32 %x)
  %b = call i32 @f44(i32 %a)
  %r = xor i32 %b, 88
  ret i32 %r
}
define internal i32 @f89(i32 %x) {
  %a = call i32 @f88(i32 %x)
  %b = call i32 @f44(i32 %a)
  %r = xor i32 %b, 89
  ret i32 %r
}
define internal i32 @f90(i32 %x) {
  %a = call i32 @f89(i32 %x)
  %b = call i32 @f45(i32 %a)
  %r = xor i32 %b, 90
  ret i32 %r
}
define internal i32 @f91(i32 %x) {
  %a = call i32 @f90(i32 %x)
  %b = call i32 @f45(i32 %a)
  %r = xor i32 %b, 91
  ret i32 %r
}
define internal i32 @f92(i32 %x) {
  %a = call i32 @f91(i32 %x)
  %b = call i32 @f46(i32 %a)
  %r = xor i32 %b, 92
  ret i32 %r
}
define internal i32 @f93(i32 %x) {
  %a = call i32 @f92(i32 %x)
  %b = call i32 @f46(i32 %a)
  %r = xor i32 %b, 93
  ret i32 %r
}
define internal i32 @f94(i32 %x) {
  %a = call i32 @f93(i32 %x)
  %b = call i32 @f47(i32 %a)
  %r = xor i32 %b, 94
  ret i32 %r
}
define internal i32 @f95(i32 %x) {
  %a = call i32 @f94(i32 %x)
  %b = call i32 @f47(i32 %a)
  %r = xor i32 %b, 95
  ret i32 %r
}
define internal i32 @f96(i32 %x) {
  %a = call i32 @f95(i32 %x)
  %b = call i32 @f48(i32 %a)
  %r = xor i32 %b, 96
  ret i32 %r
}
define internal i32 @f97(i32 %x) {
  %a = call i32 @f96(i32 %x)
  %b = call i32 @f48(i32 %a)
  %r = xor i32 %b, 97
  ret i32 %r
}
define internal i32 @f98(i32 %x) {
  %a = call i32 @f97(i32 %x)
  %b = call i32 @f49(i32 %a)
  %r = xor i32 %b, 98
  ret i32 %r
}
define internal i32 @f99(i32 %x) {
  %a = call i32 @f98(i32 %x)
  %b = call i32 @f49(i32 %a)
  %r = xor i32 %b, 99
  ret i32 %r
}
define internal i32 @f100(i32 %x) {
  %a = call i32 @f99(i32 %x)
  %b = call i32 @f50(i32 %a)
  %r = xor i32 %b, 100
  ret i32 %r
}
define internal i32 @f101(i32 %x) {
  %a = call i32 @f100(i32 %x)
  %b = call i32 @f50(i32 %a)
  %r = xor i32 %b, 101
  ret i32 %r
}
define internal i32 @f102(i32 %x) {
  %a = call i32 @f101(i32 %x)
  %b = call i32 @f51(i32 %a)
  %r = xor i32 %b, 102
  ret i32 %r
}
define internal i32 @f103(i32 %x) {
  %a = call i32 @f102(i32 %x)
  %b = call i32 @f51(i32 %a)
  %r = xor i32 %b, 103
  ret i32 %r
}
define internal i32 @f104(i32 %x) {
  %a = call i32 @f103(i32 %x)
  %b = call i32 @f52(i32 %a)
  %r = xor i32 %b, 104
  ret i32 %r
}
define internal i32 @f105(i32 %x) {
  %a = call i32 @f104(i32 %x)
  %b = call i32 @f52(i32 %a)
  %r = xor i32 %b, 105
  ret i32 %r
}
define internal i32 @f106(i32 %x) {
  %a = call i32 @f105(i32 %x)
  %b = call i32 @f53(i32 %a)
  %r = xor i32 %b, 106
  ret i32 %r
}
define internal i32 @f107(i32 %x) {
  %a = call i32 @f106(i32 %x)
  %b = call i32 @f53(i32 %a)
  %r = xor i32 %b, 107
  ret i32 %r
}
define internal i32 @f108(i32 %x) {
  %a = call i32 @f107(i32 %x)
  %b = call i32 @f54(i32 %a)
  %r = xor i32 %b, 108
  ret i32 %r
}
define internal i32 @f109(i32 %x) {
  %a = call i32 @f108(i32 %x)
  %b = call i32 @f54(i32 %a)
  %r = xor i32 %b, 109
  ret i32 %r
}
define internal i32 @f110(i32 %x) {
  %a = call i32 @f109(i32 %x)
  %b = call i32 @f55(i32 %a)
  %r = xor i32 %b, 110
  ret i32 %r
}
define internal i32 @f111(i32 %x) {
  %a = call i32 @f110(i32 %x)
  %b = call i32 @f55(i32 %a)
  %r = xor i32 %b, 111
  ret i32 %r
}
define internal i32 @f112(i32 %x) {
  %a = call i32 @f111(i32 %x)
  %b = call i32 @f56(i32 %a)
  %r = xor i32 %b, 112
  ret i32 %r
}
define internal i32 @f113(i32 %x) {
  %a = call i32 @f112(i32 %x)
  %b = call i32 @f56(i32 %a)
  %r = xor i32 %b, 113
  ret i32 %r
}
define internal i32 @f114(i32 %x) {
  %a = call i32 @f113(i32 %x)
  %b = call i32 @f57(i32 %a)
  %r = xor i32 %b, 114
  ret i32 %r
}
define internal i32 @f115(i32 %x) {
  %a = call i32 @f114(i32 %x)
  %b = call i32 @f57(i32 %a)
  %r = xor i32 %b, 115
  ret i32 %r
}
define internal i32 @f116(i32 %x) {
  %a = call i32 @f115(i32 %x)
  %b = call i32 @f58(i32 %a)
  %r = xor i32 %b, 116
  ret i32 %r
}
define internal i32 @f117(i32 %x) {
  %a = call i32 @f116(i32 %x)
  %b = call i32 @f58(i32 %a)
  %r = xor i32 %b, 117
  ret i32 %r
}
define internal i32 @f118(i32 %x) {
  %a = call i32 @f117(i32 %x)
  %b = call i32 @f59(i32 %a)
  %r = xor i32 %b, 118
  ret i32 %r
}
define internal i32 @f119(i32 %x) {
  %a = call i32 @f118(i32 %x)
  %b = call i32 @f59(i32 %a)
  %r = xor i32 %b, 119
  ret i32 %r
}
define internal i32 @f120(i32 %x) {
  %a = call i32 @f119(i32 %x)
  %b = call i32 @f60(i32 %a)
  %r = xor i32 %b, 120
  ret i32 %r
}
define internal i32 @f121(i32 %x) {
  %a = call i32 @f120(i32 %x)
  %b = call i32 @f60(i32 %a)
  %r = xor i32 %b, 121
  ret i32 %r
}
define internal i32 @f122(i32 %x) {
  %a = call i32 @f121(i32 %x)
  %b = call i32 @f61(i32 %a)
  %r = xor i32 %b, 122
  ret i32 %r
}
define internal i32 @f123(i32 %x) {
  %a = call i32 @f122(i32 %x)
  %b = call i32 @f61(i32 %a)
  %r = xor i32 %b, 123
  ret i32 %r
}
define internal i32 @f124(i32 %x) {
  %a = call i32 @f123(i32 %x)
  %b = call i32 @f62(i32 %a)
  %r = xor i32 %b, 124
  ret i32 %r
}
define internal i32 @f125(i32 %x) {
  %a = call i32 @f124(i32 %x)
  %b = call i32 @f62(i32 %a)
  %r = xor i32 %b, 125
  ret i32 %r
}
define internal i32 @f126(i32 %x) {
  %a = call i32 @f125(i32 %x)
  %b = call i32 @f63(i32 %a)
  %r = xor i32 %b, 126
  ret i32 %r
}
define internal i32 @f127(i32 %x) {
  %a = call i32 @f126(i32 %x)
  %b = call i32 @f63(i32 %a)
  %r = xor i32 %b, 127
  ret i32 %r
}
define internal i32 @f128(i32 %x) {
  %a = call i32 @f127(i32 %x)
  %b = call i32 @f64(i32 %a)
  %r = xor i32 %b, 128
  ret i32 %r
}
define internal i32 @f129(i32 %x) {
  %a = call i32 @f128(i32 %x)
  %b = call i32 @f64(i32 %a)
  %r = xor i32 %b, 129
  ret i32 %r
}
define internal i32 @f130(i32 %x) {
  %a = call i32 @f129(i32 %x)
  %b = call i32 @f65(i32 %a)
  %r = xor i32 %b, 130
  ret i32 %r
}
define internal i32 @f131(i32 %x) {
  %a = call i32 @f130(i32 %x)
  %b = call i32 @f65(i32 %a)
  %r = xor i32 %b, 131
  ret i32 %r
}
define internal i32 @f132(i32 %x) {
  %a = call i32 @f131(i32 %x)
  %b = call i32 @f66(i32 %a)
  %r = xor i32 %b, 132
  ret i32 %r
}
define internal i32 @f133(i32 %x) {
  %a = call i32 @f132(i32 %x)
  %b = call i32 @f66(i32 %a)
  %r = xor i32 %b, 133
  ret i32 %r
}
define internal i32 @f134(i32 %x) {
  %a = call i32 @f133(i32 %x)
  %b = call i32 @f67(i32 %a)
  %r = xor i32 %b, 134
  ret i32 %r
}
define internal i32 @f135(i32 %x) {
  %a = call i32 @f134(i32 %x)
  %b = call i32 @f67(i32 %a)
  %r = xor i32 %b, 135
  ret i32 %r
}
define internal i32 @f136(i32 %x) {
  %a = call i32 @f135(i32 %x)
  %b = call i32 @f68(i32 %a)
  %r = xor i32 %b, 136
  ret i32 %r
}
define internal i32 @f137(i32 %x) {
  %a = call i32 @f136(i32 %x)
  %b = call i32 @f68(i32 %a)
  %r = xor i32 %b, 137
  ret i32 %r
}
define internal i32 @f138(i32 %x) {
  %a = call i32 @f137(i32 %x)
  %b = call i32 @f69(i32 %a)
  %r = xor i32 %b, 138
  ret i32 %r
}
define internal i32 @f139(i32 %x) {
  %a = call i32 @f138(i32 %x)
  %b = call i32 @f69(i32 %a)
  %r = xor i32 %b, 139
  ret i32 %r
}
define internal i32 @f140(i32 %x) {
  %a = call i32 @f139(i32 %x)
  %b = call i32 @f70(i32 %a)
  %r = xor i32 %b, 140
  ret i32 %r
}
define internal i32 @f141(i32 %x) {
  %a = call i32 @f140(i32 %x)
  %b = call i32 @f70(i32 %a)
  %r = xor i32 %b, 141
  ret i32 %r
}
define internal i32 @f142(i32 %x) {
  %a = call i32 @f141(i32 %x)
  %b = call i32 @f71(i32 %a)
  %r = xor i32 %b, 142
  ret i32 %r
}
define internal i32 @f143(i32 %x) {
  %a = call i32 @f142(i32 %x)
  %b = call i32 @f71(i32 %a)
  %r = xor i32 %b, 143
  ret i32 %r
}
define internal i32 @f144(i32 %x) {
  %a = call i32 @f143(i32 %x)
  %b = call i32 @f72(i32 %a)
  %r = xor i32 %b, 144
  ret i32 %r
}
define internal i32 @f145(i32 %x) {
  %a = call i32 @f144(i32 %x)
  %b = call i32 @f72(i32 %a)
  %r = xor i32 %b, 145
  ret i32 %r
}
define internal i32 @f146(i32 %x) {
  %a = call i32 @f145(i32 %x)
  %b = call i32 @f73(i32 %a)
  %r = xor i32 %b, 146
  ret i32 %r
}
define internal i32 @f147(i32 %x) {
  %a = call i32 @f146(i32 %x)
  %b = call i32 @f73(i32 %a)
  %r = xor i32 %b, 147
  ret i32 %r
}
define internal i32 @f148(i32 %x) {
  %a = call i32 @f147(i32 %x)
  %b = call i32 @f74(i32 %a)
  %r = xor i32 %b, 148
  ret i32 %r
}
define internal i32 @f149(i32 %x) {
  %a = call i32 @f148(i32 %x)
  %b = call i32 @f74(i32 %a)
  %r = xor i32 %b, 149
  ret i32 %r
}
define internal i32 @f150(i32 %x) {
  %a = call i32 @f149(i32 %x)
  %b = call i32 @f75(i32 %a)
  %r = xor i32 %b, 150
  ret i32 %r
}
define internal i32 @f151(i32 %x) {
  %a = call i32 @f150(i32 %x)
  %b = call i32 @f75(i32 %a)
  %r = xor i32 %b, 151
  ret i32 %r
}
define internal i32 @f152(i32 %x) {
  %a = call i32 @f151(i32 %x)
  %b = call i32 @f76(i32 %a)
  %r = xor i32 %b, 152
  ret i32 %r
}
define internal i32 @f153(i32 %x) {
  %a = call i32 @f152(i32 %x)
  %b = call i32 @f76(i32 %a)
  %r = xor i32 %b, 153
  ret i32 %r
}
define internal i32 @f154(i32 %x) {
  %a = call i32 @f153(i32 %x)
  %b = call i32 @f77(i32 %a)
  %r = xor i32 %b, 154
  ret i32 %r
}
define internal i32 @f155(i32 %x) {
  %a = call i32 @f154(i32 %x)
  %b = call i32 @f77(i32 %a)
  %r = xor i32 %b, 155
  ret i32 %r
}
define internal i32 @f156(i32 %x) {
  %a = call i32 @f155(i32 %x)
  %b = call i32 @f78(i32 %a)
  %r = xor i32 %b, 156
  ret i32 %r
}
define internal i32 @f157(i32 %x) {
  %a = call i32 @f156(i32 %x)
  %b = call i32 @f78(i32 %a)
  %r = xor i32 %b, 157
  ret i32 %r
}
define internal i32 @f158(i32 %x) {
  %a = call i32 @f157(i32 %x)
  %b = call i32 @f79(i32 %a)
  %r = xor i32 %b, 158
  ret i32 %r
}
define internal i32 @f159(i32 %x) {
  %a = call i32 @f158(i32 %x)
  %b = call i32 @f79(i32 %a)
  %r = xor i32 %b, 159
  ret i32 %r
}
define internal i32 @f160(i32 %x) {
  %a = call i32 @f159(i32 %x)
  %b = call i32 @f80(i32 %a)
  %r = xor i32 %b, 160
  ret i32 %r
}
define internal i32 @f161(i32 %x) {
  %a = call i32 @f160(i32 %x)
  %b = call i32 @f80(i32 %a)
  %r = xor i32 %b, 161
  ret i32 %r
}
define internal i32 @f162(i32 %x) {
  %a = call i32 @f161(i32 %x)
  %b = call i32 @f81(i32 %a)
  %r = xor i32 %b, 162
  ret i32 %r
}
define internal i32 @f163(i32 %x) {
  %a = call i32 @f162(i32 %x)
  %b = call i32 @f81(i32 %a)
  %r = xor i32 %b, 163
  ret i32 %r
}
define internal i32 @f164(i32 %x) {
  %a = call i32 @f163(i32 %x)
  %b = call i32 @f82(i32 %a)
  %r = xor i32 %b, 164
  ret i32 %r
}
define internal i32 @f165(i32 %x) {
  %a = call i32 @f164(i32 %x)
  %b = call i32 @f82(i32 %a)
  %r = xor i32 %b, 165
  ret i32 %r
}
define internal i32 @f166(i32 %x) {
  %a = call i32 @f165(i32 %x)
  %b = call i32 @f83(i32 %a)
  %r = xor i32 %b, 166
  ret i32 %r
}
define internal i32 @f167(i32 %x) {
  %a = call i32 @f166(i32 %x)
  %b = call i32 @f83(i32 %a)
  %r = xor i32 %b, 167
  ret i32 %r
}
define internal i32 @f168(i32 %x) {
  %a = call i32 @f167(i32 %x)
  %b = call i32 @f84(i32 %a)
  %r = xor i32 %b, 168
  ret i32 %r
}
define internal i32 @f169(i32 %x) {
  %a = call i32 @f168(i32 %x)
  %b = call i32 @f84(i32 %a)
  %r = xor i32 %b, 169
  ret i32 %r
}
define internal i32 @f170(i32 %x) {
  %a = call i32 @f169(i32 %x)
  %b = call i32 @f85(i32 %a)
  %r = xor i32 %b, 170
  ret i32 %r
}
define internal i32 @f171(i32 %x) {
  %a = call i32 @f170(i32 %x)
  %b = call i32 @f85(i32 %a)
  %r = xor i32 %b, 171
  ret i32 %r
}
define internal i32 @f172(i32 %x) {
  %a = call i32 @f171(i32 %x)
  %b = call i32 @f86(i32 %a)
  %r = xor i32 %b, 172
  ret i32 %r
}
define internal i32 @f173(i32 %x) {
  %a = call i32 @f172(i32 %x)
  %b = call i32 @f86(i32 %a)
  %r = xor i32 %b, 173
  ret i32 %r
}
define internal i32 @f174(i32 %x) {
  %a = call i32 @f173(i32 %x)
  %b = call i32 @f87(i32 %a)
  %r = xor i32 %b, 174
  ret i32 %r
}
define internal i32 @f175(i32 %x) {
  %a = call i32 @f174(i32 %x)
  %b = call i32 @f87(i32 %a)
  %r = xor i32 %b, 175
  ret i32 %r
}
define internal i32 @f176(i32 %x) {
  %a = call i32 @f175(i32 %x)
  %b = call i32 @f88(i32 %a)
  %r = xor i32 %b, 176
  ret i32 %r
}
define internal i32 @f177(i32 %x) {
  %a = call i32 @f176(i32 %x)
  %b = call i32 @f88(i32 %a)
  %r = xor i32 %b, 177
  ret i32 %r
}
define internal i32 @f178(i32 %x) {
  %a = call i32 @f177(i32 %x)
  %b = call i32 @f89(i32 %a)
  %r = xor i32 %b, 178
  ret i32 %r
}
define internal i32 @f179(i32 %x) {
  %a = call i32 @f178(i32 %x)
  %b = call i32 @f89(i32 %a)
  %r = xor i32 %b, 179
  ret i32 %r
}
define internal i32 @f180(i32 %x) {
  %a = call i32 @f179(i32 %x)
  %b = call i32 @f90(i32 %a)
  %r = xor i32 %b, 180
  ret i32 %r
}
define internal i32 @f181(i32 %x) {
  %a = call i32 @f180(i32 %x)
  %b = call i32 @f90(i32 %a)
  %r = xor i32 %b, 181
  ret i32 %r
}
define internal i32 @f182(i32 %x) {
  %a = call i32 @f181(i32 %x)
  %b = call i32 @f91(i32 %a)
  %r = xor i32 %b, 182
  ret i32 %r
}
define internal i32 @f183(i32 %x) {
  %a = call i32 @f182(i32 %x)
  %b = call i32 @f91(i32 %a)
  %r = xor i32 %b, 183
  ret i32 %r
}
define internal i32 @f184(i32 %x) {
  %a = call i32 @f183(i32 %x)
  %b = call i32 @f92(i32 %a)
  %r = xor i32 %b, 184
  ret i32 %r
}
define internal i32 @f185(i32 %x) {
  %a = call i32 @f184(i32 %x)
  %b = call i32 @f92(i32 %a)
  %r = xor i32 %b, 185
  ret i32 %r
}
define internal i32 @f186(i32 %x) {
  %a = call i32 @f185(i32 %x)
  %b = call i32 @f93(i32 %a)
  %r = xor i32 %b, 186
  ret i32 %r
}
define internal i32 @f187(i32 %x) {
  %a = call i32 @f186(i32 %x)
  %b = call i32 @f93(i32 %a)
  %r = xor i32 %b, 187
  ret i32 %r
}
define internal i32 @f188(i32 %x) {
  %a = call i32 @f187(i32 %x)
  %b = call i32 @f94(i32 %a)
  %r = xor i32 %b, 188
  ret i32 %r
}
define internal i32 @f189(i32 %x) {
  %a = call i32 @f188(i32 %x)
  %b = call i32 @f94(i32 %a)
  %r = xor i32 %b, 189
  ret i32 %r
}
define internal i32 @f190(i32 %x) {
  %a = call i32 @f189(i32 %x)
  %b = call i32 @f95(i32 %a)
  %r = xor i32 %b, 190
  ret i32 %r
}
define internal i32 @f191(i32 %x) {
  %a = call i32 @f190(i32 %x)
  %b = call i32 @f95(i32 %a)
  %r = xor i32 %b, 191
  ret i32 %r
}
define internal i32 @f192(i32 %x) {
  %a = call i32 @f191(i32 %x)
  %b = call i32 @f96(i32 %a)
  %r = xor i32 %b, 192
  ret i32 %r
}
define internal i32 @f193(i32 %x) {
  %a = call i32 @f192(i32 %x)
  %b = call i32 @f96(i32 %a)
  %r = xor i32 %b, 193
  ret i32 %r
}
define internal i32 @f194(i32 %x) {
  %a = call i32 @f193(i32 %x)
  %b = call i32 @f97(i32 %a)
  %r = xor i32 %b, 194
  ret i32 %r
}
define internal i32 @f195(i32 %x) {
  %a = call i32 @f194(i32 %x)
  %b = call i32 @f97(i32 %a)
  %r = xor i32 %b, 195
  ret i32 %r
}
define internal i32 @f196(i32 %x) {
  %a = call i32 @f195(i32 %x)
  %b = call i32 @f98(i32 %a)
  %r = xor i32 %b, 196
  ret i32 %r
}
define internal i32 @f197(i32 %x) {
  %a = call i32 @f196(i32 %x)
  %b = call i32 @f98(i32 %a)
  %r = xor i32 %b, 197
  ret i32 %r
}
define internal i32 @f198(i32 %x) {
  %a = call i32 @f197(i32 %x)
  %b = call i32 @f99(i32 %a)
  %r = xor i32 %b, 198
  ret i32 %r
}
define internal i32 @f199(i32 %x) {
  %a = call i32 @f198(i32 %x)
  %b = call i32 @f99(i32 %a)
  %r = xor i32 %b, 199
  ret i32 %r
}
define internal i32 @f200(i32 %x) {
  %a = call i32 @f199(i32 %x)
  %b = call i32 @f100(i32 %a)
  %r = xor i32 %b, 200
  ret i32 %r
}
define internal i32 @f201(i32 %x) {
  %a = call i32 @f200(i32 %x)
  %b = call i32 @f100(i32 %a)
  %r = xor i32 %b, 201
  ret i32 %r
}
define internal i32 @f202(i32 %x) {
  %a = call i32 @f201(i32 %x)
  %b = call i32 @f101(i32 %a)
  %r = xor i32 %b, 202
  ret i32 %r
}
define internal i32 @f203(i32 %x) {
  %a = call i32 @f202(i32 %x)
  %b = call i32 @f101(i32 %a)
  %r = xor i32 %b, 203
  ret i32 %r
}
define internal i32 @f204(i32 %x) {
  %a = call i32 @f203(i32 %x)
  %b = call i32 @f102(i32 %a)
  %r = xor i32 %b, 204
  ret i32 %r
}
define internal i32 @f205(i32 %x) {
  %a = call i32 @f204(i32 %x)
  %b = call i32 @f102(i32 %a)
  %r = xor i32 %b, 205
  ret i32 %r
}
define internal i32 @f206(i32 %x) {
  %a = call i32 @f205(i32 %x)
  %b = call i32 @f103(i32 %a)
  %r = xor i32 %b, 206
  ret i32 %r
}
define internal i32 @f207(i32 %x) {
  %a = call i32 @f206(i32 %x)
  %b = call i32 @f103(i32 %a)
  %r = xor i32 %b, 207
  ret i32 %r
}
define internal i32 @f208(i32 %x) {
  %a = call i32 @f207(i32 %x)
  %b = call i32 @f104(i32 %a)
  %r = xor i32 %b, 208
  ret i32 %r
}
define internal i32 @f209(i32 %x) {
  %a = call i32 @f208(i32 %x)
  %b = call i32 @f104(i32 %a)
  %r = xor i32 %b, 209
  ret i32 %r
}
define internal i32 @f210(i32 %x) {
  %a = call i32 @f209(i32 %x)
  %b = call i32 @f105(i32 %a)
  %r = xor i32 %b, 210
  ret i32 %r
}
define internal i32 @f211(i32 %x) {
  %a = call i32 @f210(i32 %x)
  %b = call i32 @f105(i32 %a)
  %r = xor i32 %b, 211
  ret i32 %r
}
define internal i32 @f212(i32 %x) {
  %a = call i32 @f211(i32 %x)
  %b = call i32 @f106(i32 %a)
  %r = xor i32 %b, 212
  ret i32 %r
}
define internal i32 @f213(i32 %x) {
  %a = call i32 @f212(i32 %x)
  %b = call i32 @f106(i32 %a)
  %r = xor i32 %b, 213
  ret i32 %r
}
define internal i32 @f214(i32 %x) {
  %a = call i32 @f213(i32 %x)
  %b = call i32 @f107(i32 %a)
  %r = xor i32 %b, 214
  ret i32 %r
}
define internal i32 @f215(i32 %x) {
  %a = call i32 @f214(i32 %x)
  %b = call i32 @f107(i32 %a)
  %r = xor i32 %b, 215
  ret i32 %r
}
define internal i32 @f216(i32 %x) {
  %a = call i32 @f215(i32 %x)
  %b = call i32 @f108(i32 %a)
  %r = xor i32 %b, 216
  ret i32 %r
}
define internal i32 @f217(i32 %x) {
  %a = call i32 @f216(i32 %x)
  %b = call i32 @f108(i32 %a)
  %r = xor i32 %b, 217
  ret i32 %r
}
define internal i32 @f218(i32 %x) {
  %a = call i32 @f217(i32 %x)
  %b = call i32 @f109(i32 %a)
  %r = xor i32 %b, 218
  ret i32 %r
}
define internal i32 @f219(i32 %x) {
  %a = call i32 @f218(i32 %x)
  %b = call i32 @f109(i32 %a)
  %r = xor i32 %b, 219
  ret i32 %r
}
define internal i32 @f220(i32 %x) {
  %a = call i32 @f219(i32 %x)
  %b = call i32 @f110(i32 %a)
  %r = xor i32 %b, 220
  ret i32 %r
}
define internal i32 @f221(i32 %x) {
  %a = call i32 @f220(i32 %x)
  %b = call i32 @f110(i32 %a)
  %r = xor i32 %b, 221
  ret i32 %r
}
define internal i32 @f222(i32 %x) {
  %a = call i32 @f221(i32 %x)
  %b = call i32 @f111(i32 %a)
  %r = xor i32 %b, 222
  ret i32 %r
}
define internal i32 @f223(i32 %x) {
  %a = call i32 @f222(i32 %x)
  %b = call i32 @f111(i32 %a)
  %r = xor i32 %b, 223
  ret i32 %r
}
define internal i32 @f224(i32 %x) {
  %a = call i32 @f223(i32 %x)
  %b = call i32 @f112(i32 %a)
  %r = xor i32 %b, 224
  ret i32 %r
}
define internal i32 @f225(i32 %x) {
  %a = call i32 @f224(i32 %x)
  %b = call i32 @f112(i32 %a)
  %r = xor i32 %b, 225
  ret i32 %r
}
define internal i32 @f226(i32 %x) {
  %a = call i32 @f225(i32 %x)
  %b = call i32 @f113(i32 %a)
  %r = xor i32 %b, 226
  ret i32 %r
}
define internal i32 @f227(i32 %x) {
  %a = call i32 @f226(i32 %x)
  %b = call i32 @f113(i32 %a)
  %r = xor i32 %b, 227
  ret i32 %r
}
define internal i32 @f228(i32 %x) {
  %a = call i32 @f227(i32 %x)
  %b = call i32 @f114(i32 %a)
  %r = xor i32 %b, 228
  ret i32 %r
}
define internal i32 @f229(i32 %x) {
  %a = call i32 @f228(i32 %x)
  %b = call i32 @f114(i32 %a)
  %r = xor i32 %b, 229
  ret i32 %r
}
define internal i32 @f230(i32 %x) {
  %a = call i32 @f229(i32 %x)
  %b = call i32 @f115(i32 %a)
  %r = xor i32 %b, 230
  ret i32 %r
}
define internal i32 @f231(i32 %x) {
  %a = call i32 @f230(i32 %x)
  %b = call i32 @f115(i32 %a)
  %r = xor i32 %b, 231
  ret i32 %r
}
define internal i32 @f232(i32 %x) {
  %a = call i32 @f231(i32 %x)
  %b = call i32 @f116(i32 %a)
  %r = xor i32 %b, 232
  ret i32 %r
}
define internal i32 @f233(i32 %x) {
  %a = call i32 @f232(i32 %x)
  %b = call i32 @f116(i32 %a)
  %r = xor i32 %b, 233
  ret i32 %r
}
define internal i32 @f234(i32 %x) {
  %a = call i32 @f233(i32 %x)
  %b = call i32 @f117(i32 %a)
  %r = xor i32 %b, 234
  ret i32 %r
}
define internal i32 @f235(i32 %x) {
  %a = call i32 @f234(i32 %x)
  %b = call i32 @f117(i32 %a)
  %r = xor i32 %b, 235
  ret i32 %r
}
define internal i32 @f236(i32 %x) {
  %a = call i32 @f235(i32 %x)
  %b = call i32 @f118(i32 %a)
  %r = xor i32 %b, 236
  ret i32 %r
}
define internal i32 @f237(i32 %x) {
  %a = call i32 @f236(i32 %x)
  %b = call i32 @f118(i32 %a)
  %r = xor i32 %b, 237
  ret i32 %r
}
define internal i32 @f238(i32 %x) {
  %a = call i32 @f237(i32 %x)
  %b = call i32 @f119(i32 %a)
  %r = xor i32 %b, 238
  ret i32 %r
}
define internal i32 @f239(i32 %x) {
  %a = call i32 @f238(i32 %x)
  %b = call i32 @f119(i32 %a)
  %r = xor i32 %b, 239
  ret i32 %r
}
define internal i32 @f240(i32 %x) {
  %a = call i32 @f239(i32 %x)
  %b = call i32 @f120(i32 %a)
  %r = xor i32 %b, 240
  ret i32 %r
}
define internal i32 @f241(i32 %x) {
  %a = call i32 @f240(i32 %x)
  %b = call i32 @f120(i32 %a)
  %r = xor i32 %b, 241
  ret i32 %r
}
define internal i32 @f242(i32 %x) {
  %a = call i32 @f241(i32 %x)
  %b = call i32 @f121(i32 %a)
  %r = xor i32 %b, 242
  ret i32 %r
}
define internal i32 @f243(i32 %x) {
  %a = call i32 @f242(i32 %x)
  %b = call i32 @f121(i32 %a)
  %r = xor i32 %b, 243
  ret i32 %r
}
define internal i32 @f244(i32 %x) {
  %a = call i32 @f243(i32 %x)
  %b = call i32 @f122(i32 %a)
  %r = xor i32 %b, 244
  ret i32 %r
}
define internal i32 @f245(i32 %x) {
  %a = call i32 @f244(i32 %x)
  %b = call i32 @f122(i32 %a)
  %r = xor i32 %b, 245
  ret i32 %r
}
define internal i32 @f246(i32 %x) {
  %a = call i32 @f245(i32 %x)
  %b = call i32 @f123(i32 %a)
  %r = xor i32 %b, 246
  ret i32 %r
}
define internal i32 @f247(i32 %x) {
  %a = call i32 @f246(i32 %x)
  %b = call i32 @f123(i32 %a)
  %r = xor i32 %b, 247
  ret i32 %r
}
define internal i32 @f248(i32 %x) {
  %a = call i32 @f247(i32 %x)
  %b = call i32 @f124(i32 %a)
  %r = xor i32 %b, 248
  ret i32 %r
}
define internal i32 @f249(i32 %x) {
  %a = call i32 @f248(i32 %x)
  %b = call i32 @f124(i32 %a)
  %r = xor i32 %b, 249
  ret i32 %r
}
define internal i32 @f250(i32 %x) {
  %a = call i32 @f249(i32 %x)
  %b = call i32 @f125(i32 %a)
  %r = xor i32 %b, 250
  ret i32 %r
}
define internal i32 @f251(i32 %x) {
  %a = call i32 @f250(i32 %x)
  %b = call i32 @f125(i32 %a)
  %r = xor i32 %b, 251
  ret i32 %r
}
define internal i32 @f252(i32 %x) {
  %a = call i32 @f251(i32 %x)
  %b = call i32 @f126(i32 %a)
  %r = xor i32 %b, 252
  ret i32 %r
}
define internal i32 @f253(i32 %x) {
  %a = call i32 @f252(i32 %x)
  %b = call i32 @f126(i32 %a)
  %r = xor i32 %b, 253
  ret i32 %r
}
define internal i32 @f254(i32 %x) {
  %a = call i32 @f253(i32 %x)
  %b = call i32 @f127(i32 %a)
  %r = xor i32 %b, 254
  ret i32 %r
}
define internal i32 @f255(i32 %x) {
  %a = call i32 @f254(i32 %x)
  %b = call i32 @f127(i32 %a)
  %r = xor i32 %b, 255
  ret i32 %r
}
define internal i32 @f256(i32 %x) {
  %a = call i32 @f255(i32 %x)
  %b = call i32 @f128(i32 %a)
  %r = xor i32 %b, 256
  ret i32 %r
}
define internal i32 @f257(i32 %x) {
  %a = call i32 @f256(i32 %x)
  %b = call i32 @f128(i32 %a)
  %r = xor i32 %b, 257
  ret i32 %r
}
define internal i32 @f258(i32 %x) {
  %a = call i32 @f257(i32 %x)
  %b = call i32 @f129(i32 %a)
  %r = xor i32 %b, 258
  ret i32 %r
}
define internal i32 @f259(i32 %x) {
  %a = call i32 @f258(i32 %x)
  %b = call i32 @f129(i32 %a)
  %r = xor i32 %b, 259
  ret i32 %r
}
define internal i32 @f260(i32 %x) {
  %a = call i32 @f259(i32 %x)
  %b = call i32 @f130(i32 %a)
  %r = xor i32 %b, 260
  ret i32 %r
}
define internal i32 @f261(i32 %x) {
  %a = call i32 @f260(i32 %x)
  %b = call i32 @f130(i32 %a)
  %r = xor i32 %b, 261
  ret i32 %r
}
define internal i32 @f262(i32 %x) {
  %a = call i32 @f261(i32 %x)
  %b = call i32 @f131(i32 %a)
  %r = xor i32 %b, 262
  ret i32 %r
}
define internal i32 @f263(i32 %x) {
  %a = call i32 @f262(i32 %x)
  %b = call i32 @f131(i32 %a)
  %r = xor i32 %b, 263
  ret i32 %r
}
define internal i32 @f264(i32 %x) {
  %a = call i32 @f263(i32 %x)
  %b = call i32 @f132(i32 %a)
  %r = xor i32 %b, 264
  ret i32 %r
}
define internal i32 @f265(i32 %x) {
  %a = call i32 @f264(i32 %x)
  %b = call i32 @f132(i32 %a)
  %r = xor i32 %b, 265
  ret i32 %r
}
define internal i32 @f266(i32 %x) {
  %a = call i32 @f265(i32 %x)
  %b = call i32 @f133(i32 %a)
  %r = xor i32 %b, 266
  ret i32 %r
}
define internal i32 @f267(i32 %x) {
  %a = call i32 @f266(i32 %x)
  %b = call i32 @f133(i32 %a)
  %r = xor i32 %b, 267
  ret i32 %r
}
define internal i32 @f268(i32 %x) {
  %a = call i32 @f267(i32 %x)
  %b = call i32 @f134(i32 %a)
  %r = xor i32 %b, 268
  ret i32 %r
}
define internal i32 @f269(i32 %x) {
  %a = call i32 @f268(i32 %x)
  %b = call i32 @f134(i32 %a)
  %r = xor i32 %b, 269
  ret i32 %r
}
define internal i32 @f270(i32 %x) {
  %a = call i32 @f269(i32 %x)
  %b = call i32 @f135(i32 %a)
  %r = xor i32 %b, 270
  ret i32 %r
}
define internal i32 @f271(i32 %x) {
  %a = call i32 @f270(i32 %x)
  %b = call i32 @f135(i32 %a)
  %r = xor i32 %b, 271
  ret i32 %r
}
define internal i32 @f272(i32 %x) {
  %a = call i32 @f271(i32 %x)
  %b = call i32 @f136(i32 %a)
  %r = xor i32 %b, 272
  ret i32 %r
}
define internal i32 @f273(i32 %x) {
  %a = call i32 @f272(i32 %x)
  %b = call i32 @f136(i32 %a)
  %r = xor i32 %b, 273
  ret i32 %r
}
define internal i32 @f274(i32 %x) {
  %a = call i32 @f273(i32 %x)
  %b = call i32 @f137(i32 %a)
  %r = xor i32 %b, 274
  ret i32 %r
}
define internal i32 @f275(i32 %x) {
  %a = call i32 @f274(i32 %x)
  %b = call i32 @f137(i32 %a)
  %r = xor i32 %b, 275
  ret i32 %r
}
define internal i32 @f276(i32 %x) {
  %a = call i32 @f275(i32 %x)
  %b = call i32 @f138(i32 %a)
  %r = xor i32 %b, 276
  ret i32 %r
}
define internal i32 @f277(i32 %x) {
  %a = call i32 @f276(i32 %x)
  %b = call i32 @f138(i32 %a)
  %r = xor i32 %b, 277
  ret i32 %r
}
define internal i32 @f278(i32 %x) {
  %a = call i32 @f277(i32 %x)
  %b = call i32 @f139(i32 %a)
  %r = xor i32 %b, 278
  ret i32 %r
}
define internal i32 @f279(i32 %x) {
  %a = call i32 @f278(i32 %x)
  %b = call i32 @f139(i32 %a)
  %r = xor i32 %b, 279
  ret i32 %r
}
define internal i32 @f280(i32 %x) {
  %a = call i32 @f279(i32 %x)
  %b = call i32 @f140(i32 %a)
  %r = xor i32 %b, 280
  ret i32 %r
}
define internal i32 @f281(i32 %x) {
  %a = call i32 @f280(i32 %x)
  %b = call i32 @f140(i32 %a)
  %r = xor i32 %b, 281
  ret i32 %r
}
define internal i32 @f282(i32 %x) {
  %a = call i32 @f281(i32 %x)
  %b = call i32 @f141(i32 %a)
  %r = xor i32 %b, 282
  ret i32 %r
}
define internal i32 @f283(i32 %x) {
  %a = call i32 @f282(i32 %x)
  %b = call i32 @f141(i32 %a)
  %r = xor i32 %b, 283
  ret i32 %r
}
define internal i32 @f284(i32 %x) {
  %a = call i32 @f283(i32 %x)
  %b = call i32 @f142(i32 %a)
  %r = xor i32 %b, 284
  ret i32 %r
}
define internal i32 @f285(i32 %x) {
  %a = call i32 @f284(i32 %x)
  %b = call i32 @f142(i32 %a)
  %r = xor i32 %b, 285
  ret i32 %r
}
define internal i32 @f286(i32 %x) {
  %a = call i32 @f285(i32 %x)
  %b = call i32 @f143(i32 %a)
  %r = xor i32 %b, 286
  ret i32 %r
}
define internal i32 @f287(i32 %x) {
  %a = call i32 @f286(i32 %x)
  %b = call i32 @f143(i32 %a)
  %r = xor i32 %b, 287
  ret i32 %r
}
define internal i32 @f288(i32 %x) {
  %a = call i32 @f287(i32 %x)
  %b = call i32 @f144(i32 %a)
  %r = xor i32 %b, 288
  ret i32 %r
}
define internal i32 @f289(i32 %x) {
  %a = call i32 @f288(i32 %x)
  %b = call i32 @f144(i32 %a)
  %r = xor i32 %b, 289
  ret i32 %r
}
define internal i32 @f290(i32 %x) {
  %a = call i32 @f289(i32 %x)
  %b = call i32 @f145(i32 %a)
  %r = xor i32 %b, 290
  ret i32 %r
}
define internal i32 @f291(i32 %x) {
  %a = call i32 @f290(i32 %x)
  %b = call i32 @f145(i32 %a)
  %r = xor i32 %b, 291
  ret i32 %r
}
define internal i32 @f292(i32 %x) {
  %a = call i32 @f291(i32 %x)
  %b = call i32 @f146(i32 %a)
  %r = xor i32 %b, 292
  ret i32 %r
}
define internal i32 @f293(i32 %x) {
  %a = call i32 @f292(i32 %x)
  %b = call i32 @f146(i32 %a)
  %r = xor i32 %b, 293
  ret i32 %r
}
define internal i32 @f294(i32 %x) {
  %a = call i32 @f293(i32 %x)
  %b = call i32 @f147(i32 %a)
  %r = xor i32 %b, 294
  ret i32 %r
}
define internal i32 @f295(i32 %x) {
  %a = call i32 @f294(i32 %x)
  %b = call i32 @f147(i32 %a)
  %r = xor i32 %b, 295
  ret i32 %r
}
define internal i32 @f296(i32 %x) {
  %a = call i32 @f295(i32 %x)
  %b = call i32 @f148(i32 %a)
  %r = xor i32 %b, 296
  ret i32 %r
}
define internal i32 @f297(i32 %x) {
  %a = call i32 @f296(i32 %x)
  %b = call i32 @f148(i32 %a)
  %r = xor i32 %b, 297
  ret i32 %r
}
define internal i32 @f298(i32 %x) {
  %a = call i32 @f297(i32 %x)
  %b = call i32 @f149(i32 %a)
  %r = xor i32 %b, 298
  ret i32 %r
}
define internal i32 @f299(i32 %x) {
  %a = call i32 @f298(i32 %x)
  %b = call i32 @f149(i32 %a)
  %r = xor i32 %b, 299
  ret i32 %r
}
define internal i32 @f300(i32 %x) {
  %a = call i32 @f299(i32 %x)
  %b = call i32 @f150(i32 %a)
  %r = xor i32 %b, 300
  ret i32 %r
}
define internal i32 @f301(i32 %x) {
  %a = call i32 @f300(i32 %x)
  %b = call i32 @f150(i32 %a)
  %r = xor i32 %b, 301
  ret i32 %r
}
define internal i32 @f302(i32 %x) {
  %a = call i32 @f301(i32 %x)
  %b = call i32 @f151(i32 %a)
  %r = xor i32 %b, 302
  ret i32 %r
}
define internal i32 @f303(i32 %x) {
  %a = call i32 @f302(i32 %x)
  %b = call i32 @f151(i32 %a)
  %r = xor i32 %b, 303
  ret i32 %r
}
define internal i32 @f304(i32 %x) {
  %a = call i32 @f303(i32 %x)
  %b = call i32 @f152(i32 %a)
  %r = xor i32 %b, 304
  ret i32 %r
}
define internal i32 @f305(i32 %x) {
  %a = call i32 @f304(i32 %x)
  %b = call i32 @f152(i32 %a)
  %r = xor i32 %b, 305
  ret i32 %r
}
define internal i32 @f306(i32 %x) {
  %a = call i32 @f305(i32 %x)
  %b = call i32 @f153(i32 %a)
  %r = xor i32 %b, 306
  ret i32 %r
}
define internal i32 @f307(i32 %x) {
  %a = call i32 @f306(i32 %x)
  %b = call i32 @f153(i32 %a)
  %r = xor i32 %b, 307
  ret i32 %r
}
define internal i32 @f308(i32 %x) {
  %a = call i32 @f307(i32 %x)
  %b = call i32 @f154(i32 %a)
  %r = xor i32 %b, 308
  ret i32 %r
}
define internal i32 @f309(i32 %x) {
  %a = call i32 @f308(i32 %x)
  %b = call i32 @f154(i32 %a)
  %r = xor i32 %b, 309
  ret i32 %r
}
define internal i32 @f310(i32 %x) {
  %a = call i32 @f309(i32 %x)
  %b = call i32 @f155(i32 %a)
  %r = xor i32 %b, 310
  ret i32 %r
}
define internal i32 @f311(i32 %x) {
  %a = call i32 @f310(i32 %x)
  %b = call i32 @f155(i32 %a)
  %r = xor i32 %b, 311
  ret i32 %r
}
define internal i32 @f312(i32 %x) {
  %a = call i32 @f311(i32 %x)
  %b = call i32 @f156(i32 %a)
  %r = xor i32 %b, 312
  ret i32 %r
}
define internal i32 @f313(i32 %x) {
  %a = call i32 @f312(i32 %x)
  %b = call i32 @f156(i32 %a)
  %r = xor i32 %b, 313
  ret i32 %r
}
define internal i32 @f314(i32 %x) {
  %a = call i32 @f313(i32 %x)
  %b = call i32 @f157(i32 %a)
  %r = xor i32 %b, 314
  ret i32 %r
}
define internal i32 @f315(i32 %x) {
  %a = call i32 @f314(i32 %x)
  %b = call i32 @f157(i32 %a)
  %r = xor i32 %b, 315
  ret i32 %r
}
define internal i32 @f316(i32 %x) {
  %a = call i32 @f315(i32 %x)
  %b = call i32 @f158(i32 %a)
  %r = xor i32 %b, 316
  ret i32 %r
}
define internal i32 @f317(i32 %x) {
  %a = call i32 @f316(i32 %x)
  %b = call i32 @f158(i32 %a)
  %r = xor i32 %b, 317
  ret i32 %r
}
define internal i32 @f318(i32 %x) {
  %a = call i32 @f317(i32 %x)
  %b = call i32 @f159(i32 %a)
  %r = xor i32 %b, 318
  ret i32 %r
}
define internal i32 @f319(i32 %x) {
  %a = call i32 @f318(i32 %x)
  %b = call i32 @f159(i32 %a)
  %r = xor i32 %b, 319
  ret i32 %r
}
define internal i32 @f320(i32 %x) {
  %a = call i32 @f319(i32 %x)
  %b = call i32 @f160(i32 %a)
  %r = xor i32 %b, 320
  ret i32 %r
}
define internal i32 @f321(i32 %x) {
  %a = call i32 @f320(i32 %x)
  %b = call i32 @f160(i32 %a)
  %r = xor i32 %b, 321
  ret i32 %r
}
define internal i32 @f322(i32 %x) {
  %a = call i32 @f321(i32 %x)
  %b = call i32 @f161(i32 %a)
  %r = xor i32 %b, 322
  ret i32 %r
}
define internal i32 @f323(i32 %x) {
  %a = call i32 @f322(i32 %x)
  %b = call i32 @f161(i32 %a)
  %r = xor i32 %b, 323
  ret i32 %r
}
define internal i32 @f324(i32 %x) {
  %a = call i32 @f323(i32 %x)
  %b = call i32 @f162(i32 %a)
  %r = xor i32 %b, 324
  ret i32 %r
}
define internal i32 @f325(i32 %x) {
  %a = call i32 @f324(i32 %x)
  %b = call i32 @f162(i32 %a)
  %r = xor i32 %b, 325
  ret i32 %r
}
define internal i32 @f326(i32 %x) {
  %a = call i32 @f325(i32 %x)
  %b = call i32 @f163(i32 %a)
  %r = xor i32 %b, 326
  ret i32 %r
}
define internal i32 @f327(i32 %x) {
  %a = call i32 @f326(i32 %x)
  %b = call i32 @f163(i32 %a)
  %r = xor i32 %b, 327
  ret i32 %r
}
define internal i32 @f328(i32 %x) {
  %a = call i32 @f327(i32 %x)
  %b = call i32 @f164(i32 %a)
  %r = xor i32 %b, 328
  ret i32 %r
}
define internal i32 @f329(i32 %x) {
  %a = call i32 @f328(i32 %x)
  %b = call i32 @f164(i32 %a)
  %r = xor i32 %b, 329
  ret i32 %r
}
define internal i32 @f330(i32 %x) {
  %a = call i32 @f329(i32 %x)
  %b = call i32 @f165(i32 %a)
  %r = xor i32 %b, 330
  ret i32 %r
}
define internal i32 @f331(i32 %x) {
  %a = call i32 @f330(i32 %x)
  %b = call i32 @f165(i32 %a)
  %r = xor i32 %b, 331
  ret i32 %r
}
define internal i32 @f332(i32 %x) {
  %a = call i32 @f331(i32 %x)
  %b = call i32 @f166(i32 %a)
  %r = xor i32 %b, 332
  ret i32 %r
}
define internal i32 @f333(i32 %x) {
  %a = call i32 @f332(i32 %x)
  %b = call i32 @f166(i32 %a)
  %r = xor i32 %b, 333
  ret i32 %r
}
define internal i32 @f334(i32 %x) {
  %a = call i32 @f333(i32 %x)
  %b = call i32 @f167(i32 %a)
  %r = xor i32 %b, 334
  ret i32 %r
}
define internal i32 @f335(i32 %x) {
  %a = call i32 @f334(i32 %x)
  %b = call i32 @f167(i32 %a)
  %r = xor i32 %b, 335
  ret i32 %r
}
define internal i32 @f336(i32 %x) {
  %a = call i32 @f335(i32 %x)
  %b = call i32 @f168(i32 %a)
  %r = xor i32 %b, 336
  ret i32 %r
}
define internal i32 @f337(i32 %x) {
  %a = call i32 @f336(i32 %x)
  %b = call i32 @f168(i32 %a)
  %r = xor i32 %b, 337
  ret i32 %r
}
define internal i32 @f338(i32 %x) {
  %a = call i32 @f337(i32 %x)
  %b = call i32 @f169(i32 %a)
  %r = xor i32 %b, 338
  ret i32 %r
}
define internal i32 @f339(i32 %x) {
  %a = call i32 @f338(i32 %x)
  %b = call i32 @f169(i32 %a)
  %r = xor i32 %b, 339
  ret i32 %r
}
define internal i32 @f340(i32 %x) {
  %a = call i32 @f339(i32 %x)
  %b = call i32 @f170(i32 %a)
  %r = xor i32 %b, 340
  ret i32 %r
}
define internal i32 @f341(i32 %x) {
  %a = call i32 @f340(i32 %x)
  %b = call i32 @f170(i32 %a)
  %r = xor i32 %b, 341
  ret i32 %r
}
define internal i32 @f342(i32 %x) {
  %a = call i32 @f341(i32 %x)
  %b = call i32 @f171(i32 %a)
  %r = xor i32 %b, 342
  ret i32 %r
}
define internal i32 @f343(i32 %x) {
  %a = call i32 @f342(i32 %x)
  %b = call i32 @f171(i32 %a)
  %r = xor i32 %b, 343
  ret i32 %r
}
define internal i32 @f344(i32 %x) {
  %a = call i32 @f343(i32 %x)
  %b = call i32 @f172(i32 %a)
  %r = xor i32 %b, 344
  ret i32 %r
}
define internal i32 @f345(i32 %x) {
  %a = call i32 @f344(i32 %x)
  %b = call i32 @f172(i32 %a)
  %r = xor i32 %b, 345
  ret i32 %r
}
define internal i32 @f346(i32 %x) {
  %a = call i32 @f345(i32 %x)
  %b = call i32 @f173(i32 %a)
  %r = xor i32 %b, 346
  ret i32 %r
}
define internal i32 @f347(i32 %x) {
  %a = call i32 @f346(i32 %x)
  %b = call i32 @f173(i32 %a)
  %r = xor i32 %b, 347
  ret i32 %r
}
define internal i32 @f348(i32 %x) {
  %a = call i32 @f347(i32 %x)
  %b = call i32 @f174(i32 %a)
  %r = xor i32 %b, 348
  ret i32 %r
}
define internal i32 @f349(i32 %x) {
  %a = call i32 @f348(i32 %x)
  %b = call i32 @f174(i32 %a)
  %r = xor i32 %b, 349
  ret i32 %r
}
define internal i32 @f350(i32 %x) {
  %a = call i32 @f349(i32 %x)
  %b = call i32 @f175(i32 %a)
  %r = xor i32 %b, 350
  ret i32 %r
}
define internal i32 @f351(i32 %x) {
  %a = call i32 @f350(i32 %x)
  %b = call i32 @f175(i32 %a)
  %r = xor i32 %b, 351
  ret i32 %r
}
define internal i32 @f352(i32 %x) {
  %a = call i32 @f351(i32 %x)
  %b = call i32 @f176(i32 %a)
  %r = xor i32 %b, 352
  ret i32 %r
}
define internal i32 @f353(i32 %x) {
  %a = call i32 @f352(i32 %x)
  %b = call i32 @f176(i32 %a)
  %r = xor i32 %b, 353
  ret i32 %r
}
define internal i32 @f354(i32 %x) {
  %a = call i32 @f353(i32 %x)
  %b = call i32 @f177(i32 %a)
  %r = xor i32 %b, 354
  ret i32 %r
}
define internal i32 @f355(i32 %x) {
  %a = call i32 @f354(i32 %x)
  %b = call i32 @f177(i32 %a)
  %r = xor i32 %b, 355
  ret i32 %r
}
define internal i32 @f356(i32 %x) {
  %a = call i32 @f355(i32 %x)
  %b = call i32 @f178(i32 %a)
  %r = xor i32 %b, 356
  ret i32 %r
}
define internal i32 @f357(i32 %x) {
  %a = call i32 @f356(i32 %x)
  %b = call i32 @f178(i32 %a)
  %r = xor i32 %b, 357
  ret i32 %r
}
define internal i32 @f358(i32 %x) {
  %a = call i32 @f357(i32 %x)
  %b = call i32 @f179(i32 %a)
  %r = xor i32 %b, 358
  ret i32 %r
}
define internal i32 @f359(i32 %x) {
  %a = call i32 @f358(i32 %x)
  %b = call i32 @f179(i32 %a)
  %r = xor i32 %b, 359
  ret i32 %r
}
define internal i32 @f360(i32 %x) {
  %a = call i32 @f359(i32 %x)
  %b = call i32 @f180(i32 %a)
  %r = xor i32 %b, 360
  ret i32 %r
}
define internal i32 @f361(i32 %x) {
  %a = call i32 @f360(i32 %x)
  %b = call i32 @f180(i32 %a)
  %r = xor i32 %b, 361
  ret i32 %r
}
define internal i32 @f362(i32 %x) {
  %a = call i32 @f361(i32 %x)
  %b = call i32 @f181(i32 %a)
  %r = xor i32 %b, 362
  ret i32 %r
}
define internal i32 @f363(i32 %x) {
  %a = call i32 @f362(i32 %x)
  %b = call i32 @f181(i32 %a)
  %r = xor i32 %b, 363
  ret i32 %r
}
define internal i32 @f364(i32 %x) {
  %a = call i32 @f363(i32 %x)
  %b = call i32 @f182(i32 %a)
  %r = xor i32 %b, 364
  ret i32 %r
}
define internal i32 @f365(i32 %x) {
  %a = call i32 @f364(i32 %x)
  %b = call i32 @f182(i32 %a)
  %r = xor i32 %b, 365
  ret i32 %r
}
define internal i32 @f366(i32 %x) {
  %a = call i32 @f365(i32 %x)
  %b = call i32 @f183(i32 %a)
  %r = xor i32 %b, 366
  ret i32 %r
}
define internal i32 @f367(i32 %x) {
  %a = call i32 @f366(i32 %x)
  %b = call i32 @f183(i32 %a)
  %r = xor i32 %b, 367
  ret i32 %r
}
define internal i32 @f368(i32 %x) {
  %a = call i32 @f367(i32 %x)
  %b = call i32 @f184(i32 %a)
  %r = xor i32 %b, 368
  ret i32 %r
}
define internal i32 @f369(i32 %x) {
  %a = call i32 @f368(i32 %x)
  %b = call i32 @f184(i32 %a)
  %r = xor i32 %b, 369
  ret i32 %r
}
define internal i32 @f370(i32 %x) {
  %a = call i32 @f369(i32 %x)
  %b = call i32 @f185(i32 %a)
  %r = xor i32 %b, 370
  ret i32 %r
}
define internal i32 @f371(i32 %x) {
  %a = call i32 @f370(i32 %x)
  %b = call i32 @f185(i32 %a)
  %r = xor i32 %b, 371
  ret i32 %r
}
define internal i32 @f372(i32 %x) {
  %a = call i32 @f371(i32 %x)
  %b = call i32 @f186(i32 %a)
  %r = xor i32 %b, 372
  ret i32 %r
}
define internal i32 @f373(i32 %x) {
  %a = call i32 @f372(i32 %x)
  %b = call i32 @f186(i32 %a)
  %r = xor i32 %b, 373
  ret i32 %r
}
define internal i32 @f374(i32 %x) {
  %a = call i32 @f373(i32 %x)
  %b = call i32 @f187(i32 %a)
  %r = xor i32 %b, 374
  ret i32 %r
}
define internal i32 @f375(i32 %x) {
  %a = call i32 @f374(i32 %x)
  %b = call i32 @f187(i32 %a)
  %r = xor i32 %b, 375
  ret i32 %r
}
define internal i32 @f376(i32 %x) {
  %a = call i32 @f375(i32 %x)
  %b = call i32 @f188(i32 %a)
  %r = xor i32 %b, 376
  ret i32 %r
}
define internal i32 @f377(i32 %x) {
  %a = call i32 @f376(i32 %x)
  %b = call i32 @f188(i32 %a)
  %r = xor i32 %b, 377
  ret i32 %r
}
define internal i32 @f378(i32 %x) {
  %a = call i32 @f377(i32 %x)
  %b = call i32 @f189(i32 %a)
  %r = xor i32 %b, 378
  ret i32 %r
}
define internal i32 @f379(i32 %x) {
  %a = call i32 @f378(i32 %x)
  %b = call i32 @f189(i32 %a)
  %r = xor i32 %b, 379
  ret i32 %r
}
define internal i32 @f380(i32 %x) {
  %a = call i32 @f379(i32 %x)
  %b = call i32 @f190(i32 %a)
  %r = xor i32 %b, 380
  ret i32 %r
}
define internal i32 @f381(i32 %x) {
  %a = call i32 @f380(i32 %x)
  %b = call i32 @f190(i32 %a)
  %r = xor i32 %b, 381
  ret i32 %r
}
define internal i32 @f382(i32 %x) {
  %a = call i32 @f381(i32 %x)
  %b = call i32 @f191(i32 %a)
  %r = xor i32 %b, 382
  ret i32 %r
}
define internal i32 @f383(i32 %x) {
  %a = call i32 @f382(i32 %x)
  %b = call i32 @f191(i32 %a)
  %r = xor i32 %b, 383
  ret i32 %r
}
define internal i32 @f384(i32 %x) {
  %a = call i32 @f383(i32 %x)
  %b = call i32 @f192(i32 %a)
  %r = xor i32 %b, 384
  ret i32 %r
}
define internal i32 @f385(i32 %x) {
  %a = call i32 @f384(i32 %x)
  %b = call i32 @f192(i32 %a)
  %r = xor i32 %b, 385
  ret i32 %r
}
define internal i32 @f386(i32 %x) {
  %a = call i32 @f385(i32 %x)
  %b = call i32 @f193(i32 %a)
  %r = xor i32 %b, 386
  ret i32 %r
}
define internal i32 @f387(i32 %x) {
  %a = call i32 @f386(i32 %x)
  %b = call i32 @f193(i32 %a)
  %r = xor i32 %b, 387
  ret i32 %r
}
define internal i32 @f388(i32 %x) {
  %a = call i32 @f387(i32 %x)
  %b = call i32 @f194(i32 %a)
  %r = xor i32 %b, 388
  ret i32 %r
}
define internal i32 @f389(i32 %x) {
  %a = call i32 @f388(i32 %x)
  %b = call i32 @f194(i32 %a)
  %r = xor i32 %b, 389
  ret i32 %r
}
define internal i32 @f390(i32 %x) {
  %a = call i32 @f389(i32 %x)
  %b = call i32 @f195(i32 %a)
  %r = xor i32 %b, 390
  ret i32 %r
}
define internal i32 @f391(i32 %x) {
  %a = call i32 @f390(i32 %x)
  %b = call i32 @f195(i32 %a)
  %r = xor i32 %b, 391
  ret i32 %r
}
define internal i32 @f392(i32 %x) {
  %a = call i32 @f391(i32 %x)
  %b = call i32 @f196(i32 %a)
  %r = xor i32 %b, 392
  ret i32 %r
}
define internal i32 @f393(i32 %x) {
  %a = call i32 @f392(i32 %x)
  %b = call i32 @f196(i32 %a)
  %r = xor i32 %b, 393
  ret i32 %r
}
define internal i32 @f394(i32 %x) {
  %a = call i32 @f393(i32 %x)
  %b = call i32 @f197(i32 %a)
  %r = xor i32 %b, 394
  ret i32 %r
}
define internal i32 @f395(i32 %x) {
  %a = call i32 @f394(i32 %x)
  %b = call i32 @f197(i32 %a)
  %r = xor i32 %b, 395
  ret i32 %r
}
define internal i32 @f396(i32 %x) {
  %a = call i32 @f395(i32 %x)
  %b = call i32 @f198(i32 %a)
  %r = xor i32 %b, 396
  ret i32 %r
}
define internal i32 @f397(i32 %x) {
  %a = call i32 @f396(i32 %x)
  %b = call i32 @f198(i32 %a)
  %r = xor i32 %b, 397
  ret i32 %r
}
define internal i32 @f398(i32 %x) {
  %a = call i32 @f397(i32 %x)
  %b = call i32 @f199(i32 %a)
  %r = xor i32 %b, 398
  ret i32 %r
}
define internal i32 @f399(i32 %x) {
  %a = call i32 @f398(i32 %x)
  %b = call i32 @f199(i32 %a)
  %r = xor i32 %b, 399
  ret i32 %r
}
define internal i32 @f400(i32 %x) {
  %a = call i32 @f399(i32 %x)
  %b = call i32 @f200(i32 %a)
  %r = xor i32 %b, 400
  ret i32 %r
}
define internal i32 @f401(i32 %x) {
  %a = call i32 @f400(i32 %x)
  %b = call i32 @f200(i32 %a)
  %r = xor i32 %b, 401
  ret i32 %r
}
define internal i32 @f402(i32 %x) {
  %a = call i32 @f401(i32 %x)
  %b = call i32 @f201(i32 %a)
  %r = xor i32 %b, 402
  ret i32 %r
}
define internal i32 @f403(i32 %x) {
  %a = call i32 @f402(i32 %x)
  %b = call i32 @f201(i32 %a)
  %r = xor i32 %b, 403
  ret i32 %r
}
define internal i32 @f404(i32 %x) {
  %a = call i32 @f403(i32 %x)
  %b = call i32 @f202(i32 %a)
  %r = xor i32 %b, 404
  ret i32 %r
}
define internal i32 @f405(i32 %x) {
  %a = call i32 @f404(i32 %x)
  %b = call i32 @f202(i32 %a)
  %r = xor i32 %b, 405
  ret i32 %r
}
define internal i32 @f406(i32 %x) {
  %a = call i32 @f405(i32 %x)
  %b = call i32 @f203(i32 %a)
  %r = xor i32 %b, 406
  ret i32 %r
}
define internal i32 @f407(i32 %x) {
  %a = call i32 @f406(i32 %x)
  %b = call i32 @f203(i32 %a)
  %r = xor i32 %b, 407
  ret i32 %r
}
define internal i32 @f408(i32 %x) {
  %a = call i32 @f407(i32 %x)
  %b = call i32 @f204(i32 %a)
  %r = xor i32 %b, 408
  ret i32 %r
}
define internal i32 @f409(i32 %x) {
  %a = call i32 @f408(i32 %x)
  %b = call i32 @f204(i32 %a)
  %r = xor i32 %b, 409
  ret i32 %r
}
define internal i32 @f410(i32 %x) {
  %a = call i32 @f409(i32 %x)
  %b = call i32 @f205(i32 %a)
  %r = xor i32 %b, 410
  ret i32 %r
}
define internal i32 @f411(i32 %x) {
  %a = call i32 @f410(i32 %x)
  %b = call i32 @f205(i32 %a)
  %r = xor i32 %b, 411
  ret i32 %r
}
define internal i32 @f412(i32 %x) {
  %a = call i32 @f411(i32 %x)
  %b = call i32 @f206(i32 %a)
  %r = xor i32 %b, 412
  ret i32 %r
}
define internal i32 @f413(i32 %x) {
  %a = call i32 @f412(i32 %x)
  %b = call i32 @f206(i32 %a)
  %r = xor i32 %b, 413
  ret i32 %r
}
define internal i32 @f414(i32 %x) {
  %a = call i32 @f413(i32 %x)
  %b = call i32 @f207(i32 %a)
  %r = xor i32 %b, 414
  ret i32 %r
}
define internal i32 @f415(i32 %x) {
  %a = call i32 @f414(i32 %x)
  %b = call i32 @f207(i32 %a)
  %r = xor i32 %b, 415
  ret i32 %r
}
define internal i32 @f416(i32 %x) {
  %a = call i32 @f415(i32 %x)
  %b = call i32 @f208(i32 %a)
  %r = xor i32 %b, 416
  ret i32 %r
}
define internal i32 @f417(i32 %x) {
  %a = call i32 @f416(i32 %x)
  %b = call i32 @f208(i32 %a)
  %r = xor i32 %b, 417
  ret i32 %r
}
define internal i32 @f418(i32 %x) {
  %a = call i32 @f417(i32 %x)
  %b = call i32 @f209(i32 %a)
  %r = xor i32 %b, 418
  ret i32 %r
}
define internal i32 @f419(i32 %x) {
  %a = call i32 @f418(i32 %x)
  %b = call i32 @f209(i32 %a)
  %r = xor i32 %b, 419
  ret i32 %r
}
define internal i32 @f420(i32 %x) {
  %a = call i32 @f419(i32 %x)
  %b = call i32 @f210(i32 %a)
  %r = xor i32 %b, 420
  ret i32 %r
}
define internal i32 @f421(i32 %x) {
  %a = call i32 @f420(i32 %x)
  %b = call i32 @f210(i32 %a)
  %r = xor i32 %b, 421
  ret i32 %r
}
define internal i32 @f422(i32 %x) {
  %a = call i32 @f421(i32 %x)
  %b = call i32 @f211(i32 %a)
  %r = xor i32 %b, 422
  ret i32 %r
}
define internal i32 @f423(i32 %x) {
  %a = call i32 @f422(i32 %x)
  %b = call i32 @f211(i32 %a)
  %r = xor i32 %b, 423
  ret i32 %r
}
define internal i32 @f424(i32 %x) {
  %a = call i32 @f423(i32 %x)
  %b = call i32 @f212(i32 %a)
  %r = xor i32 %b, 424
  ret i32 %r
}
define internal i32 @f425(i32 %x) {
  %a = call i32 @f424(i32 %x)
  %b = call i32 @f212(i32 %a)
  %r = xor i32 %b, 425
  ret i32 %r
}
define internal i32 @f426(i32 %x) {
  %a = call i32 @f425(i32 %x)
  %b = call i32 @f213(i32 %a)
  %r = xor i32 %b, 426
  ret i32 %r
}
define internal i32 @f427(i32 %x) {
  %a = call i32 @f426(i32 %x)
  %b = call i32 @f213(i32 %a)
  %r = xor i32 %b, 427
  ret i32 %r
}
define internal i32 @f428(i32 %x) {
  %a = call i32 @f427(i32 %x)
  %b = call i32 @f214(i32 %a)
  %r = xor i32 %b, 428
  ret i32 %r
}
define internal i32 @f429(i32 %x) {
  %a = call i32 @f428(i32 %x)
  %b = call i32 @f214(i32 %a)
  %r = xor i32 %b, 429
  ret i32 %r
}
define internal i32 @f430(i32 %x) {
  %a = call i32 @f429(i32 %x)
  %b = call i32 @f215(i32 %a)
  %r = xor i32 %b, 430
  ret i32 %r
}
define internal i32 @f431(i32 %x) {
  %a = call i32 @f430(i32 %x)
  %b = call i32 @f215(i32 %a)
  %r = xor i32 %b, 431
  ret i32 %r
}
define internal i32 @f432(i32 %x) {
  %a = call i32 @f431(i32 %x)
  %b = call i32 @f216(i32 %a)
  %r = xor i32 %b, 432
  ret i32 %r
}
define internal i32 @f433(i32 %x) {
  %a = call i32 @f432(i32 %x)
  %b = call i32 @f216(i32 %a)
  %r = xor i32 %b, 433
  ret i32 %r
}
define internal i32 @f434(i32 %x) {
  %a = call i32 @f433(i32 %x)
  %b = call i32 @f217(i32 %a)
  %r = xor i32 %b, 434
  ret i32 %r
}
define internal i32 @f435(i32 %x) {
  %a = call i32 @f434(i32 %x)
  %b = call i32 @f217(i32 %a)
  %r = xor i32 %b, 435
  ret i32 %r
}
define internal i32 @f436(i32 %x) {
  %a = call i32 @f435(i32 %x)
  %b = call i32 @f218(i32 %a)
  %r = xor i32 %b, 436
  ret i32 %r
}
define internal i32 @f437(i32 %x) {
  %a = call i32 @f436(i32 %x)
  %b = call i32 @f218(i32 %a)
  %r = xor i32 %b, 437
  ret i32 %r
}
define internal i32 @f438(i32 %x) {
  %a = call i32 @f437(i32 %x)
  %b = call i32 @f219(i32 %a)
  %r = xor i32 %b, 438
  ret i32 %r
}
define internal i32 @f439(i32 %x) {
  %a = call i32 @f438(i32 %x)
  %b = call i32 @f219(i32 %a)
  %r = xor i32 %b, 439
  ret i32 %r
}
define internal i32 @f440(i32 %x) {
  %a = call i32 @f439(i32 %x)
  %b = call i32 @f220(i32 %a)
  %r = xor i32 %b, 440
  ret i32 %r
}
define internal i32 @f441(i32 %x) {
  %a = call i32 @f440(i32 %x)
  %b = call i32 @f220(i32 %a)
  %r = xor i32 %b, 441
  ret i32 %r
}
define internal i32 @f442(i32 %x) {
  %a = call i32 @f441(i32 %x)
  %b = call i32 @f221(i32 %a)
  %r = xor i32 %b, 442
  ret i32 %r
}
define internal i32 @f443(i32 %x) {
  %a = call i32 @f442(i32 %x)
  %b = call i32 @f221(i32 %a)
  %r = xor i32 %b, 443
  ret i32 %r
}
define internal i32 @f444(i32 %x) {
  %a = call i32 @f443(i32 %x)
  %b = call i32 @f222(i32 %a)
  %r = xor i32 %b, 444
  ret i32 %r
}
define internal i32 @f445(i32 %x) {
  %a = call i32 @f444(i32 %x)
  %b = call i32 @f222(i32 %a)
  %r = xor i32 %b, 445
  ret i32 %r
}
define internal i32 @f446(i32 %x) {
  %a = call i32 @f445(i32 %x)
  %b = call i32 @f223(i32 %a)
  %r = xor i32 %b, 446
  ret i32 %r
}
define internal i32 @f447(i32 %x) {
  %a = call i32 @f446(i32 %x)
  %b = call i32 @f223(i32 %a)
  %r = xor i32 %b, 447
  ret i32 %r
}
define internal i32 @f448(i32 %x) {
  %a = call i32 @f447(i32 %x)
  %b = call i32 @f224(i32 %a)
  %r = xor i32 %b, 448
  ret i32 %r
}
define internal i32 @f449(i32 %x) {
  %a = call i32 @f448(i32 %x)
  %b = call i32 @f224(i32 %a)
  %r = xor i32 %b, 449
  ret i32 %r
}
define internal i32 @f450(i32 %x) {
  %a = call i32 @f449(i32 %x)
  %b = call i32 @f225(i32 %a)
  %r = xor i32 %b, 450
  ret i32 %r
}
define internal i32 @f451(i32 %x) {
  %a = call i32 @f450(i32 %x)
  %b = call i32 @f225(i32 %a)
  %r = xor i32 %b, 451
  ret i32 %r
}
define internal i32 @f452(i32 %x) {
  %a = call i32 @f451(i32 %x)
  %b = call i32 @f226(i32 %a)
  %r = xor i32 %b, 452
  ret i32 %r
}
define internal i32 @f453(i32 %x) {
  %a = call i32 @f452(i32 %x)
  %b = call i32 @f226(i32 %a)
  %r = xor i32 %b, 453
  ret i32 %r
}
define internal i32 @f454(i32 %x) {
  %a = call i32 @f453(i32 %x)
  %b = call i32 @f227(i32 %a)
  %r = xor i32 %b, 454
  ret i32 %r
}
define internal i32 @f455(i32 %x) {
  %a = call i32 @f454(i32 %x)
  %b = call i32 @f227(i32 %a)
  %r = xor i32 %b, 455
  ret i32 %r
}
define internal i32 @f456(i32 %x) {
  %a = call i32 @f455(i32 %x)
  %b = call i32 @f228(i32 %a)
  %r = xor i32 %b, 456
  ret i32 %r
}
define internal i32 @f457(i32 %x) {
  %a = call i32 @f456(i32 %x)
  %b = call i32 @f228(i32 %a)
  %r = xor i32 %b, 457
  ret i32 %r
}
define internal i32 @f458(i32 %x) {
  %a = call i32 @f457(i32 %x)
  %b = call i32 @f229(i32 %a)
  %r = xor i32 %b, 458
  ret i32 %r
}
define internal i32 @f459(i32 %x) {
  %a = call i32 @f458(i32 %x)
  %b = call i32 @f229(i32 %a)
  %r = xor i32 %b, 459
  ret i32 %r
}
define internal i32 @f460(i32 %x) {
  %a = call i32 @f459(i32 %x)
  %b = call i32 @f230(i32 %a)
  %r = xor i32 %b, 460
  ret i32 %r
}
define internal i32 @f461(i32 %x) {
  %a = call i32 @f460(i32 %x)
  %b = call i32 @f230(i32 %a)
  %r = xor i32 %b, 461
  ret i32 %r
}
define internal i32 @f462(i32 %x) {
  %a = call i32 @f461(i32 %x)
  %b = call i32 @f231(i32 %a)
  %r = xor i32 %b, 462
  ret i32 %r
}
define internal i32 @f463(i32 %x) {
  %a = call i32 @f462(i32 %x)
  %b = call i32 @f231(i32 %a)
  %r = xor i32 %b, 463
  ret i32 %r
}
define internal i32 @f464(i32 %x) {
  %a = call i32 @f463(i32 %x)
  %b = call i32 @f232(i32 %a)
  %r = xor i32 %b, 464
  ret i32 %r
}
define internal i32 @f465(i32 %x) {
  %a = call i32 @f464(i32 %x)
  %b = call i32 @f232(i32 %a)
  %r = xor i32 %b, 465
  ret i32 %r
}
define internal i32 @f466(i32 %x) {
  %a = call i32 @f465(i32 %x)
  %b = call i32 @f233(i32 %a)
  %r = xor i32 %b, 466
  ret i32 %r
}
define internal i32 @f467(i32 %x) {
  %a = call i32 @f466(i32 %x)
  %b = call i32 @f233(i32 %a)
  %r = xor i32 %b, 467
  ret i32 %r
}
define internal i32 @f468(i32 %x) {
  %a = call i32 @f467(i32 %x)
  %b = call i32 @f234(i32 %a)
  %r = xor i32 %b, 468
  ret i32 %r
}
define internal i32 @f469(i32 %x) {
  %a = call i32 @f468(i32 %x)
  %b = call i32 @f234(i32 %a)
  %r = xor i32 %b, 469
  ret i32 %r
}
define internal i32 @f470(i32 %x) {
  %a = call i32 @f469(i32 %x)
  %b = call i32 @f235(i32 %a)
  %r = xor i32 %b, 470
  ret i32 %r
}
define internal i32 @f471(i32 %x) {
  %a = call i32 @f470(i32 %x)
  %b = call i32 @f235(i32 %a)
  %r = xor i32 %b, 471
  ret i32 %r
}
define internal i32 @f472(i32 %x) {
  %a = call i32 @f471(i32 %x)
  %b = call i32 @f236(i32 %a)
  %r = xor i32 %b, 472
  ret i32 %r
}
define internal i32 @f473(i32 %x) {
  %a = call i32 @f472(i32 %x)
  %b = call i32 @f236(i32 %a)
  %r = xor i32 %b, 473
  ret i32 %r
}
define internal i32 @f474(i32 %x) {
  %a = call i32 @f473(i32 %x)
  %b = call i32 @f237(i32 %a)
  %r = xor i32 %b, 474
  ret i32 %r
}
define internal i32 @f475(i32 %x) {
  %a = call i32 @f474(i32 %x)
  %b = call i32 @f237(i32 %a)
  %r = xor i32 %b, 475
  ret i32 %r
}
define internal i32 @f476(i32 %x) {
  %a = call i32 @f475(i32 %x)
  %b = call i32 @f238(i32 %a)
  %r = xor i32 %b, 476
  ret i32 %r
}
define internal i32 @f477(i32 %x) {
  %a = call i32 @f476(i32 %x)
  %b = call i32 @f238(i32 %a)
  %r = xor i32 %b, 477
  ret i32 %r
}
define internal i32 @f478(i32 %x) {
  %a = call i32 @f477(i32 %x)
  %b = call i32 @f239(i32 %a)
  %r = xor i32 %b, 478
  ret i32 %r
}
define internal i32 @f479(i32 %x) {
  %a = call i32 @f478(i32 %x)
  %b = call i32 @f239(i32 %a)
  %r = xor i32 %b, 479
  ret i32 %r
}
define internal i32 @f480(i32 %x) {
  %a = call i32 @f479(i32 %x)
  %b = call i32 @f240(i32 %a)
  %r = xor i32 %b, 480
  ret i32 %r
}
define internal i32 @f481(i32 %x) {
  %a = call i32 @f480(i32 %x)
  %b = call i32 @f240(i32 %a)
  %r = xor i32 %b, 481
  ret i32 %r
}
define internal i32 @f482(i32 %x) {
  %a = call i32 @f481(i32 %x)
  %b = call i32 @f241(i32 %a)
  %r = xor i32 %b, 482
  ret i32 %r
}
define internal i32 @f483(i32 %x) {
  %a = call i32 @f482(i32 %x)
  %b = call i32 @f241(i32 %a)
  %r = xor i32 %b, 483
  ret i32 %r
}
define internal i32 @f484(i32 %x) {
  %a = call i32 @f483(i32 %x)
  %b = call i32 @f242(i32 %a)
  %r = xor i32 %b, 484
  ret i32 %r
}
define internal i32 @f485(i32 %x) {
  %a = call i32 @f484(i32 %x)
  %b = call i32 @f242(i32 %a)
  %r = xor i32 %b, 485
  ret i32 %r
}
define internal i32 @f486(i32 %x) {
  %a = call i32 @f485(i32 %x)
  %b = call i32 @f243(i32 %a)
  %r = xor i32 %b, 486
  ret i32 %r
}
define internal i32 @f487(i32 %x) {
  %a = call i32 @f486(i32 %x)
  %b = call i32 @f243(i32 %a)
  %r = xor i32 %b, 487
  ret i32 %r
}
define internal i32 @f488(i32 %x) {
  %a = call i32 @f487(i32 %x)
  %b = call i32 @f244(i32 %a)
  %r = xor i32 %b, 488
  ret i32 %r
}
define internal i32 @f489(i32 %x) {
  %a = call i32 @f488(i32 %x)
  %b = call i32 @f244(i32 %a)
  %r = xor i32 %b, 489
  ret i32 %r
}
define internal i32 @f490(i32 %x) {
  %a = call i32 @f489(i32 %x)
  %b = call i32 @f245(i32 %a)
  %r = xor i32 %b, 490
  ret i32 %r
}
define internal i32 @f491(i32 %x) {
  %a = call i32 @f490(i32 %x)
  %b = call i32 @f245(i32 %a)
  %r = xor i32 %b, 491
  ret i32 %r
}
define internal i32 @f492(i32 %x) {
  %a = call i32 @f491(i32 %x)
  %b = call i32 @f246(i32 %a)
  %r = xor i32 %b, 492
  ret i32 %r
}
define internal i32 @f493(i32 %x) {
  %a = call i32 @f492(i32 %x)
  %b = call i32 @f246(i32 %a)
  %r = xor i32 %b, 493
  ret i32 %r
}
define internal i32 @f494(i32 %x) {
  %a = call i32 @f493(i32 %x)
  %b = call i32 @f247(i32 %a)
  %r = xor i32 %b, 494
  ret i32 %r
}
define internal i32 @f495(i32 %x) {
  %a = call i32 @f494(i32 %x)
  %b = call i32 @f247(i32 %a)
  %r = xor i32 %b, 495
  ret i32 %r
}
define internal i32 @f496(i32 %x) {
  %a = call i32 @f495(i32 %x)
  %b = call i32 @f248(i32 %a)
  %r = xor i32 %b, 496
  ret i32 %r
}
define internal i32 @f497(i32 %x) {
  %a = call i32 @f496(i32 %x)
  %b = call i32 @f248(i32 %a)
  %r = xor i32 %b, 497
  ret i32 %r
}
define internal i32 @f498(i32 %x) {
  %a = call i32 @f497(i32 %x)
  %b = call i32 @f249(i32 %a)
  %r = xor i32 %b, 498
  ret i32 %r
}
define internal i32 @f499(i32 %x) {
  %a = call i32 @f498(i32 %x)
  %b = call i32 @f249(i32 %a)
  %r = xor i32 %b, 499
  ret i32 %r
}
define i32 @entry(i32 %x) {
  %r = call i32 @f499(i32 %x)
  ret i32 %r
}
