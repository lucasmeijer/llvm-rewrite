; @perf-size: 2000
; @opt: -passes=inline
; @opt: -O2
; @perf: opt
; @perf: opt -passes=inline
; @perf: opt -O2
; @generated: harness/run gen-perf, shape 'calls', n=2000
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
define internal i32 @f500(i32 %x) {
  %a = call i32 @f499(i32 %x)
  %b = call i32 @f250(i32 %a)
  %r = xor i32 %b, 500
  ret i32 %r
}
define internal i32 @f501(i32 %x) {
  %a = call i32 @f500(i32 %x)
  %b = call i32 @f250(i32 %a)
  %r = xor i32 %b, 501
  ret i32 %r
}
define internal i32 @f502(i32 %x) {
  %a = call i32 @f501(i32 %x)
  %b = call i32 @f251(i32 %a)
  %r = xor i32 %b, 502
  ret i32 %r
}
define internal i32 @f503(i32 %x) {
  %a = call i32 @f502(i32 %x)
  %b = call i32 @f251(i32 %a)
  %r = xor i32 %b, 503
  ret i32 %r
}
define internal i32 @f504(i32 %x) {
  %a = call i32 @f503(i32 %x)
  %b = call i32 @f252(i32 %a)
  %r = xor i32 %b, 504
  ret i32 %r
}
define internal i32 @f505(i32 %x) {
  %a = call i32 @f504(i32 %x)
  %b = call i32 @f252(i32 %a)
  %r = xor i32 %b, 505
  ret i32 %r
}
define internal i32 @f506(i32 %x) {
  %a = call i32 @f505(i32 %x)
  %b = call i32 @f253(i32 %a)
  %r = xor i32 %b, 506
  ret i32 %r
}
define internal i32 @f507(i32 %x) {
  %a = call i32 @f506(i32 %x)
  %b = call i32 @f253(i32 %a)
  %r = xor i32 %b, 507
  ret i32 %r
}
define internal i32 @f508(i32 %x) {
  %a = call i32 @f507(i32 %x)
  %b = call i32 @f254(i32 %a)
  %r = xor i32 %b, 508
  ret i32 %r
}
define internal i32 @f509(i32 %x) {
  %a = call i32 @f508(i32 %x)
  %b = call i32 @f254(i32 %a)
  %r = xor i32 %b, 509
  ret i32 %r
}
define internal i32 @f510(i32 %x) {
  %a = call i32 @f509(i32 %x)
  %b = call i32 @f255(i32 %a)
  %r = xor i32 %b, 510
  ret i32 %r
}
define internal i32 @f511(i32 %x) {
  %a = call i32 @f510(i32 %x)
  %b = call i32 @f255(i32 %a)
  %r = xor i32 %b, 511
  ret i32 %r
}
define internal i32 @f512(i32 %x) {
  %a = call i32 @f511(i32 %x)
  %b = call i32 @f256(i32 %a)
  %r = xor i32 %b, 512
  ret i32 %r
}
define internal i32 @f513(i32 %x) {
  %a = call i32 @f512(i32 %x)
  %b = call i32 @f256(i32 %a)
  %r = xor i32 %b, 513
  ret i32 %r
}
define internal i32 @f514(i32 %x) {
  %a = call i32 @f513(i32 %x)
  %b = call i32 @f257(i32 %a)
  %r = xor i32 %b, 514
  ret i32 %r
}
define internal i32 @f515(i32 %x) {
  %a = call i32 @f514(i32 %x)
  %b = call i32 @f257(i32 %a)
  %r = xor i32 %b, 515
  ret i32 %r
}
define internal i32 @f516(i32 %x) {
  %a = call i32 @f515(i32 %x)
  %b = call i32 @f258(i32 %a)
  %r = xor i32 %b, 516
  ret i32 %r
}
define internal i32 @f517(i32 %x) {
  %a = call i32 @f516(i32 %x)
  %b = call i32 @f258(i32 %a)
  %r = xor i32 %b, 517
  ret i32 %r
}
define internal i32 @f518(i32 %x) {
  %a = call i32 @f517(i32 %x)
  %b = call i32 @f259(i32 %a)
  %r = xor i32 %b, 518
  ret i32 %r
}
define internal i32 @f519(i32 %x) {
  %a = call i32 @f518(i32 %x)
  %b = call i32 @f259(i32 %a)
  %r = xor i32 %b, 519
  ret i32 %r
}
define internal i32 @f520(i32 %x) {
  %a = call i32 @f519(i32 %x)
  %b = call i32 @f260(i32 %a)
  %r = xor i32 %b, 520
  ret i32 %r
}
define internal i32 @f521(i32 %x) {
  %a = call i32 @f520(i32 %x)
  %b = call i32 @f260(i32 %a)
  %r = xor i32 %b, 521
  ret i32 %r
}
define internal i32 @f522(i32 %x) {
  %a = call i32 @f521(i32 %x)
  %b = call i32 @f261(i32 %a)
  %r = xor i32 %b, 522
  ret i32 %r
}
define internal i32 @f523(i32 %x) {
  %a = call i32 @f522(i32 %x)
  %b = call i32 @f261(i32 %a)
  %r = xor i32 %b, 523
  ret i32 %r
}
define internal i32 @f524(i32 %x) {
  %a = call i32 @f523(i32 %x)
  %b = call i32 @f262(i32 %a)
  %r = xor i32 %b, 524
  ret i32 %r
}
define internal i32 @f525(i32 %x) {
  %a = call i32 @f524(i32 %x)
  %b = call i32 @f262(i32 %a)
  %r = xor i32 %b, 525
  ret i32 %r
}
define internal i32 @f526(i32 %x) {
  %a = call i32 @f525(i32 %x)
  %b = call i32 @f263(i32 %a)
  %r = xor i32 %b, 526
  ret i32 %r
}
define internal i32 @f527(i32 %x) {
  %a = call i32 @f526(i32 %x)
  %b = call i32 @f263(i32 %a)
  %r = xor i32 %b, 527
  ret i32 %r
}
define internal i32 @f528(i32 %x) {
  %a = call i32 @f527(i32 %x)
  %b = call i32 @f264(i32 %a)
  %r = xor i32 %b, 528
  ret i32 %r
}
define internal i32 @f529(i32 %x) {
  %a = call i32 @f528(i32 %x)
  %b = call i32 @f264(i32 %a)
  %r = xor i32 %b, 529
  ret i32 %r
}
define internal i32 @f530(i32 %x) {
  %a = call i32 @f529(i32 %x)
  %b = call i32 @f265(i32 %a)
  %r = xor i32 %b, 530
  ret i32 %r
}
define internal i32 @f531(i32 %x) {
  %a = call i32 @f530(i32 %x)
  %b = call i32 @f265(i32 %a)
  %r = xor i32 %b, 531
  ret i32 %r
}
define internal i32 @f532(i32 %x) {
  %a = call i32 @f531(i32 %x)
  %b = call i32 @f266(i32 %a)
  %r = xor i32 %b, 532
  ret i32 %r
}
define internal i32 @f533(i32 %x) {
  %a = call i32 @f532(i32 %x)
  %b = call i32 @f266(i32 %a)
  %r = xor i32 %b, 533
  ret i32 %r
}
define internal i32 @f534(i32 %x) {
  %a = call i32 @f533(i32 %x)
  %b = call i32 @f267(i32 %a)
  %r = xor i32 %b, 534
  ret i32 %r
}
define internal i32 @f535(i32 %x) {
  %a = call i32 @f534(i32 %x)
  %b = call i32 @f267(i32 %a)
  %r = xor i32 %b, 535
  ret i32 %r
}
define internal i32 @f536(i32 %x) {
  %a = call i32 @f535(i32 %x)
  %b = call i32 @f268(i32 %a)
  %r = xor i32 %b, 536
  ret i32 %r
}
define internal i32 @f537(i32 %x) {
  %a = call i32 @f536(i32 %x)
  %b = call i32 @f268(i32 %a)
  %r = xor i32 %b, 537
  ret i32 %r
}
define internal i32 @f538(i32 %x) {
  %a = call i32 @f537(i32 %x)
  %b = call i32 @f269(i32 %a)
  %r = xor i32 %b, 538
  ret i32 %r
}
define internal i32 @f539(i32 %x) {
  %a = call i32 @f538(i32 %x)
  %b = call i32 @f269(i32 %a)
  %r = xor i32 %b, 539
  ret i32 %r
}
define internal i32 @f540(i32 %x) {
  %a = call i32 @f539(i32 %x)
  %b = call i32 @f270(i32 %a)
  %r = xor i32 %b, 540
  ret i32 %r
}
define internal i32 @f541(i32 %x) {
  %a = call i32 @f540(i32 %x)
  %b = call i32 @f270(i32 %a)
  %r = xor i32 %b, 541
  ret i32 %r
}
define internal i32 @f542(i32 %x) {
  %a = call i32 @f541(i32 %x)
  %b = call i32 @f271(i32 %a)
  %r = xor i32 %b, 542
  ret i32 %r
}
define internal i32 @f543(i32 %x) {
  %a = call i32 @f542(i32 %x)
  %b = call i32 @f271(i32 %a)
  %r = xor i32 %b, 543
  ret i32 %r
}
define internal i32 @f544(i32 %x) {
  %a = call i32 @f543(i32 %x)
  %b = call i32 @f272(i32 %a)
  %r = xor i32 %b, 544
  ret i32 %r
}
define internal i32 @f545(i32 %x) {
  %a = call i32 @f544(i32 %x)
  %b = call i32 @f272(i32 %a)
  %r = xor i32 %b, 545
  ret i32 %r
}
define internal i32 @f546(i32 %x) {
  %a = call i32 @f545(i32 %x)
  %b = call i32 @f273(i32 %a)
  %r = xor i32 %b, 546
  ret i32 %r
}
define internal i32 @f547(i32 %x) {
  %a = call i32 @f546(i32 %x)
  %b = call i32 @f273(i32 %a)
  %r = xor i32 %b, 547
  ret i32 %r
}
define internal i32 @f548(i32 %x) {
  %a = call i32 @f547(i32 %x)
  %b = call i32 @f274(i32 %a)
  %r = xor i32 %b, 548
  ret i32 %r
}
define internal i32 @f549(i32 %x) {
  %a = call i32 @f548(i32 %x)
  %b = call i32 @f274(i32 %a)
  %r = xor i32 %b, 549
  ret i32 %r
}
define internal i32 @f550(i32 %x) {
  %a = call i32 @f549(i32 %x)
  %b = call i32 @f275(i32 %a)
  %r = xor i32 %b, 550
  ret i32 %r
}
define internal i32 @f551(i32 %x) {
  %a = call i32 @f550(i32 %x)
  %b = call i32 @f275(i32 %a)
  %r = xor i32 %b, 551
  ret i32 %r
}
define internal i32 @f552(i32 %x) {
  %a = call i32 @f551(i32 %x)
  %b = call i32 @f276(i32 %a)
  %r = xor i32 %b, 552
  ret i32 %r
}
define internal i32 @f553(i32 %x) {
  %a = call i32 @f552(i32 %x)
  %b = call i32 @f276(i32 %a)
  %r = xor i32 %b, 553
  ret i32 %r
}
define internal i32 @f554(i32 %x) {
  %a = call i32 @f553(i32 %x)
  %b = call i32 @f277(i32 %a)
  %r = xor i32 %b, 554
  ret i32 %r
}
define internal i32 @f555(i32 %x) {
  %a = call i32 @f554(i32 %x)
  %b = call i32 @f277(i32 %a)
  %r = xor i32 %b, 555
  ret i32 %r
}
define internal i32 @f556(i32 %x) {
  %a = call i32 @f555(i32 %x)
  %b = call i32 @f278(i32 %a)
  %r = xor i32 %b, 556
  ret i32 %r
}
define internal i32 @f557(i32 %x) {
  %a = call i32 @f556(i32 %x)
  %b = call i32 @f278(i32 %a)
  %r = xor i32 %b, 557
  ret i32 %r
}
define internal i32 @f558(i32 %x) {
  %a = call i32 @f557(i32 %x)
  %b = call i32 @f279(i32 %a)
  %r = xor i32 %b, 558
  ret i32 %r
}
define internal i32 @f559(i32 %x) {
  %a = call i32 @f558(i32 %x)
  %b = call i32 @f279(i32 %a)
  %r = xor i32 %b, 559
  ret i32 %r
}
define internal i32 @f560(i32 %x) {
  %a = call i32 @f559(i32 %x)
  %b = call i32 @f280(i32 %a)
  %r = xor i32 %b, 560
  ret i32 %r
}
define internal i32 @f561(i32 %x) {
  %a = call i32 @f560(i32 %x)
  %b = call i32 @f280(i32 %a)
  %r = xor i32 %b, 561
  ret i32 %r
}
define internal i32 @f562(i32 %x) {
  %a = call i32 @f561(i32 %x)
  %b = call i32 @f281(i32 %a)
  %r = xor i32 %b, 562
  ret i32 %r
}
define internal i32 @f563(i32 %x) {
  %a = call i32 @f562(i32 %x)
  %b = call i32 @f281(i32 %a)
  %r = xor i32 %b, 563
  ret i32 %r
}
define internal i32 @f564(i32 %x) {
  %a = call i32 @f563(i32 %x)
  %b = call i32 @f282(i32 %a)
  %r = xor i32 %b, 564
  ret i32 %r
}
define internal i32 @f565(i32 %x) {
  %a = call i32 @f564(i32 %x)
  %b = call i32 @f282(i32 %a)
  %r = xor i32 %b, 565
  ret i32 %r
}
define internal i32 @f566(i32 %x) {
  %a = call i32 @f565(i32 %x)
  %b = call i32 @f283(i32 %a)
  %r = xor i32 %b, 566
  ret i32 %r
}
define internal i32 @f567(i32 %x) {
  %a = call i32 @f566(i32 %x)
  %b = call i32 @f283(i32 %a)
  %r = xor i32 %b, 567
  ret i32 %r
}
define internal i32 @f568(i32 %x) {
  %a = call i32 @f567(i32 %x)
  %b = call i32 @f284(i32 %a)
  %r = xor i32 %b, 568
  ret i32 %r
}
define internal i32 @f569(i32 %x) {
  %a = call i32 @f568(i32 %x)
  %b = call i32 @f284(i32 %a)
  %r = xor i32 %b, 569
  ret i32 %r
}
define internal i32 @f570(i32 %x) {
  %a = call i32 @f569(i32 %x)
  %b = call i32 @f285(i32 %a)
  %r = xor i32 %b, 570
  ret i32 %r
}
define internal i32 @f571(i32 %x) {
  %a = call i32 @f570(i32 %x)
  %b = call i32 @f285(i32 %a)
  %r = xor i32 %b, 571
  ret i32 %r
}
define internal i32 @f572(i32 %x) {
  %a = call i32 @f571(i32 %x)
  %b = call i32 @f286(i32 %a)
  %r = xor i32 %b, 572
  ret i32 %r
}
define internal i32 @f573(i32 %x) {
  %a = call i32 @f572(i32 %x)
  %b = call i32 @f286(i32 %a)
  %r = xor i32 %b, 573
  ret i32 %r
}
define internal i32 @f574(i32 %x) {
  %a = call i32 @f573(i32 %x)
  %b = call i32 @f287(i32 %a)
  %r = xor i32 %b, 574
  ret i32 %r
}
define internal i32 @f575(i32 %x) {
  %a = call i32 @f574(i32 %x)
  %b = call i32 @f287(i32 %a)
  %r = xor i32 %b, 575
  ret i32 %r
}
define internal i32 @f576(i32 %x) {
  %a = call i32 @f575(i32 %x)
  %b = call i32 @f288(i32 %a)
  %r = xor i32 %b, 576
  ret i32 %r
}
define internal i32 @f577(i32 %x) {
  %a = call i32 @f576(i32 %x)
  %b = call i32 @f288(i32 %a)
  %r = xor i32 %b, 577
  ret i32 %r
}
define internal i32 @f578(i32 %x) {
  %a = call i32 @f577(i32 %x)
  %b = call i32 @f289(i32 %a)
  %r = xor i32 %b, 578
  ret i32 %r
}
define internal i32 @f579(i32 %x) {
  %a = call i32 @f578(i32 %x)
  %b = call i32 @f289(i32 %a)
  %r = xor i32 %b, 579
  ret i32 %r
}
define internal i32 @f580(i32 %x) {
  %a = call i32 @f579(i32 %x)
  %b = call i32 @f290(i32 %a)
  %r = xor i32 %b, 580
  ret i32 %r
}
define internal i32 @f581(i32 %x) {
  %a = call i32 @f580(i32 %x)
  %b = call i32 @f290(i32 %a)
  %r = xor i32 %b, 581
  ret i32 %r
}
define internal i32 @f582(i32 %x) {
  %a = call i32 @f581(i32 %x)
  %b = call i32 @f291(i32 %a)
  %r = xor i32 %b, 582
  ret i32 %r
}
define internal i32 @f583(i32 %x) {
  %a = call i32 @f582(i32 %x)
  %b = call i32 @f291(i32 %a)
  %r = xor i32 %b, 583
  ret i32 %r
}
define internal i32 @f584(i32 %x) {
  %a = call i32 @f583(i32 %x)
  %b = call i32 @f292(i32 %a)
  %r = xor i32 %b, 584
  ret i32 %r
}
define internal i32 @f585(i32 %x) {
  %a = call i32 @f584(i32 %x)
  %b = call i32 @f292(i32 %a)
  %r = xor i32 %b, 585
  ret i32 %r
}
define internal i32 @f586(i32 %x) {
  %a = call i32 @f585(i32 %x)
  %b = call i32 @f293(i32 %a)
  %r = xor i32 %b, 586
  ret i32 %r
}
define internal i32 @f587(i32 %x) {
  %a = call i32 @f586(i32 %x)
  %b = call i32 @f293(i32 %a)
  %r = xor i32 %b, 587
  ret i32 %r
}
define internal i32 @f588(i32 %x) {
  %a = call i32 @f587(i32 %x)
  %b = call i32 @f294(i32 %a)
  %r = xor i32 %b, 588
  ret i32 %r
}
define internal i32 @f589(i32 %x) {
  %a = call i32 @f588(i32 %x)
  %b = call i32 @f294(i32 %a)
  %r = xor i32 %b, 589
  ret i32 %r
}
define internal i32 @f590(i32 %x) {
  %a = call i32 @f589(i32 %x)
  %b = call i32 @f295(i32 %a)
  %r = xor i32 %b, 590
  ret i32 %r
}
define internal i32 @f591(i32 %x) {
  %a = call i32 @f590(i32 %x)
  %b = call i32 @f295(i32 %a)
  %r = xor i32 %b, 591
  ret i32 %r
}
define internal i32 @f592(i32 %x) {
  %a = call i32 @f591(i32 %x)
  %b = call i32 @f296(i32 %a)
  %r = xor i32 %b, 592
  ret i32 %r
}
define internal i32 @f593(i32 %x) {
  %a = call i32 @f592(i32 %x)
  %b = call i32 @f296(i32 %a)
  %r = xor i32 %b, 593
  ret i32 %r
}
define internal i32 @f594(i32 %x) {
  %a = call i32 @f593(i32 %x)
  %b = call i32 @f297(i32 %a)
  %r = xor i32 %b, 594
  ret i32 %r
}
define internal i32 @f595(i32 %x) {
  %a = call i32 @f594(i32 %x)
  %b = call i32 @f297(i32 %a)
  %r = xor i32 %b, 595
  ret i32 %r
}
define internal i32 @f596(i32 %x) {
  %a = call i32 @f595(i32 %x)
  %b = call i32 @f298(i32 %a)
  %r = xor i32 %b, 596
  ret i32 %r
}
define internal i32 @f597(i32 %x) {
  %a = call i32 @f596(i32 %x)
  %b = call i32 @f298(i32 %a)
  %r = xor i32 %b, 597
  ret i32 %r
}
define internal i32 @f598(i32 %x) {
  %a = call i32 @f597(i32 %x)
  %b = call i32 @f299(i32 %a)
  %r = xor i32 %b, 598
  ret i32 %r
}
define internal i32 @f599(i32 %x) {
  %a = call i32 @f598(i32 %x)
  %b = call i32 @f299(i32 %a)
  %r = xor i32 %b, 599
  ret i32 %r
}
define internal i32 @f600(i32 %x) {
  %a = call i32 @f599(i32 %x)
  %b = call i32 @f300(i32 %a)
  %r = xor i32 %b, 600
  ret i32 %r
}
define internal i32 @f601(i32 %x) {
  %a = call i32 @f600(i32 %x)
  %b = call i32 @f300(i32 %a)
  %r = xor i32 %b, 601
  ret i32 %r
}
define internal i32 @f602(i32 %x) {
  %a = call i32 @f601(i32 %x)
  %b = call i32 @f301(i32 %a)
  %r = xor i32 %b, 602
  ret i32 %r
}
define internal i32 @f603(i32 %x) {
  %a = call i32 @f602(i32 %x)
  %b = call i32 @f301(i32 %a)
  %r = xor i32 %b, 603
  ret i32 %r
}
define internal i32 @f604(i32 %x) {
  %a = call i32 @f603(i32 %x)
  %b = call i32 @f302(i32 %a)
  %r = xor i32 %b, 604
  ret i32 %r
}
define internal i32 @f605(i32 %x) {
  %a = call i32 @f604(i32 %x)
  %b = call i32 @f302(i32 %a)
  %r = xor i32 %b, 605
  ret i32 %r
}
define internal i32 @f606(i32 %x) {
  %a = call i32 @f605(i32 %x)
  %b = call i32 @f303(i32 %a)
  %r = xor i32 %b, 606
  ret i32 %r
}
define internal i32 @f607(i32 %x) {
  %a = call i32 @f606(i32 %x)
  %b = call i32 @f303(i32 %a)
  %r = xor i32 %b, 607
  ret i32 %r
}
define internal i32 @f608(i32 %x) {
  %a = call i32 @f607(i32 %x)
  %b = call i32 @f304(i32 %a)
  %r = xor i32 %b, 608
  ret i32 %r
}
define internal i32 @f609(i32 %x) {
  %a = call i32 @f608(i32 %x)
  %b = call i32 @f304(i32 %a)
  %r = xor i32 %b, 609
  ret i32 %r
}
define internal i32 @f610(i32 %x) {
  %a = call i32 @f609(i32 %x)
  %b = call i32 @f305(i32 %a)
  %r = xor i32 %b, 610
  ret i32 %r
}
define internal i32 @f611(i32 %x) {
  %a = call i32 @f610(i32 %x)
  %b = call i32 @f305(i32 %a)
  %r = xor i32 %b, 611
  ret i32 %r
}
define internal i32 @f612(i32 %x) {
  %a = call i32 @f611(i32 %x)
  %b = call i32 @f306(i32 %a)
  %r = xor i32 %b, 612
  ret i32 %r
}
define internal i32 @f613(i32 %x) {
  %a = call i32 @f612(i32 %x)
  %b = call i32 @f306(i32 %a)
  %r = xor i32 %b, 613
  ret i32 %r
}
define internal i32 @f614(i32 %x) {
  %a = call i32 @f613(i32 %x)
  %b = call i32 @f307(i32 %a)
  %r = xor i32 %b, 614
  ret i32 %r
}
define internal i32 @f615(i32 %x) {
  %a = call i32 @f614(i32 %x)
  %b = call i32 @f307(i32 %a)
  %r = xor i32 %b, 615
  ret i32 %r
}
define internal i32 @f616(i32 %x) {
  %a = call i32 @f615(i32 %x)
  %b = call i32 @f308(i32 %a)
  %r = xor i32 %b, 616
  ret i32 %r
}
define internal i32 @f617(i32 %x) {
  %a = call i32 @f616(i32 %x)
  %b = call i32 @f308(i32 %a)
  %r = xor i32 %b, 617
  ret i32 %r
}
define internal i32 @f618(i32 %x) {
  %a = call i32 @f617(i32 %x)
  %b = call i32 @f309(i32 %a)
  %r = xor i32 %b, 618
  ret i32 %r
}
define internal i32 @f619(i32 %x) {
  %a = call i32 @f618(i32 %x)
  %b = call i32 @f309(i32 %a)
  %r = xor i32 %b, 619
  ret i32 %r
}
define internal i32 @f620(i32 %x) {
  %a = call i32 @f619(i32 %x)
  %b = call i32 @f310(i32 %a)
  %r = xor i32 %b, 620
  ret i32 %r
}
define internal i32 @f621(i32 %x) {
  %a = call i32 @f620(i32 %x)
  %b = call i32 @f310(i32 %a)
  %r = xor i32 %b, 621
  ret i32 %r
}
define internal i32 @f622(i32 %x) {
  %a = call i32 @f621(i32 %x)
  %b = call i32 @f311(i32 %a)
  %r = xor i32 %b, 622
  ret i32 %r
}
define internal i32 @f623(i32 %x) {
  %a = call i32 @f622(i32 %x)
  %b = call i32 @f311(i32 %a)
  %r = xor i32 %b, 623
  ret i32 %r
}
define internal i32 @f624(i32 %x) {
  %a = call i32 @f623(i32 %x)
  %b = call i32 @f312(i32 %a)
  %r = xor i32 %b, 624
  ret i32 %r
}
define internal i32 @f625(i32 %x) {
  %a = call i32 @f624(i32 %x)
  %b = call i32 @f312(i32 %a)
  %r = xor i32 %b, 625
  ret i32 %r
}
define internal i32 @f626(i32 %x) {
  %a = call i32 @f625(i32 %x)
  %b = call i32 @f313(i32 %a)
  %r = xor i32 %b, 626
  ret i32 %r
}
define internal i32 @f627(i32 %x) {
  %a = call i32 @f626(i32 %x)
  %b = call i32 @f313(i32 %a)
  %r = xor i32 %b, 627
  ret i32 %r
}
define internal i32 @f628(i32 %x) {
  %a = call i32 @f627(i32 %x)
  %b = call i32 @f314(i32 %a)
  %r = xor i32 %b, 628
  ret i32 %r
}
define internal i32 @f629(i32 %x) {
  %a = call i32 @f628(i32 %x)
  %b = call i32 @f314(i32 %a)
  %r = xor i32 %b, 629
  ret i32 %r
}
define internal i32 @f630(i32 %x) {
  %a = call i32 @f629(i32 %x)
  %b = call i32 @f315(i32 %a)
  %r = xor i32 %b, 630
  ret i32 %r
}
define internal i32 @f631(i32 %x) {
  %a = call i32 @f630(i32 %x)
  %b = call i32 @f315(i32 %a)
  %r = xor i32 %b, 631
  ret i32 %r
}
define internal i32 @f632(i32 %x) {
  %a = call i32 @f631(i32 %x)
  %b = call i32 @f316(i32 %a)
  %r = xor i32 %b, 632
  ret i32 %r
}
define internal i32 @f633(i32 %x) {
  %a = call i32 @f632(i32 %x)
  %b = call i32 @f316(i32 %a)
  %r = xor i32 %b, 633
  ret i32 %r
}
define internal i32 @f634(i32 %x) {
  %a = call i32 @f633(i32 %x)
  %b = call i32 @f317(i32 %a)
  %r = xor i32 %b, 634
  ret i32 %r
}
define internal i32 @f635(i32 %x) {
  %a = call i32 @f634(i32 %x)
  %b = call i32 @f317(i32 %a)
  %r = xor i32 %b, 635
  ret i32 %r
}
define internal i32 @f636(i32 %x) {
  %a = call i32 @f635(i32 %x)
  %b = call i32 @f318(i32 %a)
  %r = xor i32 %b, 636
  ret i32 %r
}
define internal i32 @f637(i32 %x) {
  %a = call i32 @f636(i32 %x)
  %b = call i32 @f318(i32 %a)
  %r = xor i32 %b, 637
  ret i32 %r
}
define internal i32 @f638(i32 %x) {
  %a = call i32 @f637(i32 %x)
  %b = call i32 @f319(i32 %a)
  %r = xor i32 %b, 638
  ret i32 %r
}
define internal i32 @f639(i32 %x) {
  %a = call i32 @f638(i32 %x)
  %b = call i32 @f319(i32 %a)
  %r = xor i32 %b, 639
  ret i32 %r
}
define internal i32 @f640(i32 %x) {
  %a = call i32 @f639(i32 %x)
  %b = call i32 @f320(i32 %a)
  %r = xor i32 %b, 640
  ret i32 %r
}
define internal i32 @f641(i32 %x) {
  %a = call i32 @f640(i32 %x)
  %b = call i32 @f320(i32 %a)
  %r = xor i32 %b, 641
  ret i32 %r
}
define internal i32 @f642(i32 %x) {
  %a = call i32 @f641(i32 %x)
  %b = call i32 @f321(i32 %a)
  %r = xor i32 %b, 642
  ret i32 %r
}
define internal i32 @f643(i32 %x) {
  %a = call i32 @f642(i32 %x)
  %b = call i32 @f321(i32 %a)
  %r = xor i32 %b, 643
  ret i32 %r
}
define internal i32 @f644(i32 %x) {
  %a = call i32 @f643(i32 %x)
  %b = call i32 @f322(i32 %a)
  %r = xor i32 %b, 644
  ret i32 %r
}
define internal i32 @f645(i32 %x) {
  %a = call i32 @f644(i32 %x)
  %b = call i32 @f322(i32 %a)
  %r = xor i32 %b, 645
  ret i32 %r
}
define internal i32 @f646(i32 %x) {
  %a = call i32 @f645(i32 %x)
  %b = call i32 @f323(i32 %a)
  %r = xor i32 %b, 646
  ret i32 %r
}
define internal i32 @f647(i32 %x) {
  %a = call i32 @f646(i32 %x)
  %b = call i32 @f323(i32 %a)
  %r = xor i32 %b, 647
  ret i32 %r
}
define internal i32 @f648(i32 %x) {
  %a = call i32 @f647(i32 %x)
  %b = call i32 @f324(i32 %a)
  %r = xor i32 %b, 648
  ret i32 %r
}
define internal i32 @f649(i32 %x) {
  %a = call i32 @f648(i32 %x)
  %b = call i32 @f324(i32 %a)
  %r = xor i32 %b, 649
  ret i32 %r
}
define internal i32 @f650(i32 %x) {
  %a = call i32 @f649(i32 %x)
  %b = call i32 @f325(i32 %a)
  %r = xor i32 %b, 650
  ret i32 %r
}
define internal i32 @f651(i32 %x) {
  %a = call i32 @f650(i32 %x)
  %b = call i32 @f325(i32 %a)
  %r = xor i32 %b, 651
  ret i32 %r
}
define internal i32 @f652(i32 %x) {
  %a = call i32 @f651(i32 %x)
  %b = call i32 @f326(i32 %a)
  %r = xor i32 %b, 652
  ret i32 %r
}
define internal i32 @f653(i32 %x) {
  %a = call i32 @f652(i32 %x)
  %b = call i32 @f326(i32 %a)
  %r = xor i32 %b, 653
  ret i32 %r
}
define internal i32 @f654(i32 %x) {
  %a = call i32 @f653(i32 %x)
  %b = call i32 @f327(i32 %a)
  %r = xor i32 %b, 654
  ret i32 %r
}
define internal i32 @f655(i32 %x) {
  %a = call i32 @f654(i32 %x)
  %b = call i32 @f327(i32 %a)
  %r = xor i32 %b, 655
  ret i32 %r
}
define internal i32 @f656(i32 %x) {
  %a = call i32 @f655(i32 %x)
  %b = call i32 @f328(i32 %a)
  %r = xor i32 %b, 656
  ret i32 %r
}
define internal i32 @f657(i32 %x) {
  %a = call i32 @f656(i32 %x)
  %b = call i32 @f328(i32 %a)
  %r = xor i32 %b, 657
  ret i32 %r
}
define internal i32 @f658(i32 %x) {
  %a = call i32 @f657(i32 %x)
  %b = call i32 @f329(i32 %a)
  %r = xor i32 %b, 658
  ret i32 %r
}
define internal i32 @f659(i32 %x) {
  %a = call i32 @f658(i32 %x)
  %b = call i32 @f329(i32 %a)
  %r = xor i32 %b, 659
  ret i32 %r
}
define internal i32 @f660(i32 %x) {
  %a = call i32 @f659(i32 %x)
  %b = call i32 @f330(i32 %a)
  %r = xor i32 %b, 660
  ret i32 %r
}
define internal i32 @f661(i32 %x) {
  %a = call i32 @f660(i32 %x)
  %b = call i32 @f330(i32 %a)
  %r = xor i32 %b, 661
  ret i32 %r
}
define internal i32 @f662(i32 %x) {
  %a = call i32 @f661(i32 %x)
  %b = call i32 @f331(i32 %a)
  %r = xor i32 %b, 662
  ret i32 %r
}
define internal i32 @f663(i32 %x) {
  %a = call i32 @f662(i32 %x)
  %b = call i32 @f331(i32 %a)
  %r = xor i32 %b, 663
  ret i32 %r
}
define internal i32 @f664(i32 %x) {
  %a = call i32 @f663(i32 %x)
  %b = call i32 @f332(i32 %a)
  %r = xor i32 %b, 664
  ret i32 %r
}
define internal i32 @f665(i32 %x) {
  %a = call i32 @f664(i32 %x)
  %b = call i32 @f332(i32 %a)
  %r = xor i32 %b, 665
  ret i32 %r
}
define internal i32 @f666(i32 %x) {
  %a = call i32 @f665(i32 %x)
  %b = call i32 @f333(i32 %a)
  %r = xor i32 %b, 666
  ret i32 %r
}
define internal i32 @f667(i32 %x) {
  %a = call i32 @f666(i32 %x)
  %b = call i32 @f333(i32 %a)
  %r = xor i32 %b, 667
  ret i32 %r
}
define internal i32 @f668(i32 %x) {
  %a = call i32 @f667(i32 %x)
  %b = call i32 @f334(i32 %a)
  %r = xor i32 %b, 668
  ret i32 %r
}
define internal i32 @f669(i32 %x) {
  %a = call i32 @f668(i32 %x)
  %b = call i32 @f334(i32 %a)
  %r = xor i32 %b, 669
  ret i32 %r
}
define internal i32 @f670(i32 %x) {
  %a = call i32 @f669(i32 %x)
  %b = call i32 @f335(i32 %a)
  %r = xor i32 %b, 670
  ret i32 %r
}
define internal i32 @f671(i32 %x) {
  %a = call i32 @f670(i32 %x)
  %b = call i32 @f335(i32 %a)
  %r = xor i32 %b, 671
  ret i32 %r
}
define internal i32 @f672(i32 %x) {
  %a = call i32 @f671(i32 %x)
  %b = call i32 @f336(i32 %a)
  %r = xor i32 %b, 672
  ret i32 %r
}
define internal i32 @f673(i32 %x) {
  %a = call i32 @f672(i32 %x)
  %b = call i32 @f336(i32 %a)
  %r = xor i32 %b, 673
  ret i32 %r
}
define internal i32 @f674(i32 %x) {
  %a = call i32 @f673(i32 %x)
  %b = call i32 @f337(i32 %a)
  %r = xor i32 %b, 674
  ret i32 %r
}
define internal i32 @f675(i32 %x) {
  %a = call i32 @f674(i32 %x)
  %b = call i32 @f337(i32 %a)
  %r = xor i32 %b, 675
  ret i32 %r
}
define internal i32 @f676(i32 %x) {
  %a = call i32 @f675(i32 %x)
  %b = call i32 @f338(i32 %a)
  %r = xor i32 %b, 676
  ret i32 %r
}
define internal i32 @f677(i32 %x) {
  %a = call i32 @f676(i32 %x)
  %b = call i32 @f338(i32 %a)
  %r = xor i32 %b, 677
  ret i32 %r
}
define internal i32 @f678(i32 %x) {
  %a = call i32 @f677(i32 %x)
  %b = call i32 @f339(i32 %a)
  %r = xor i32 %b, 678
  ret i32 %r
}
define internal i32 @f679(i32 %x) {
  %a = call i32 @f678(i32 %x)
  %b = call i32 @f339(i32 %a)
  %r = xor i32 %b, 679
  ret i32 %r
}
define internal i32 @f680(i32 %x) {
  %a = call i32 @f679(i32 %x)
  %b = call i32 @f340(i32 %a)
  %r = xor i32 %b, 680
  ret i32 %r
}
define internal i32 @f681(i32 %x) {
  %a = call i32 @f680(i32 %x)
  %b = call i32 @f340(i32 %a)
  %r = xor i32 %b, 681
  ret i32 %r
}
define internal i32 @f682(i32 %x) {
  %a = call i32 @f681(i32 %x)
  %b = call i32 @f341(i32 %a)
  %r = xor i32 %b, 682
  ret i32 %r
}
define internal i32 @f683(i32 %x) {
  %a = call i32 @f682(i32 %x)
  %b = call i32 @f341(i32 %a)
  %r = xor i32 %b, 683
  ret i32 %r
}
define internal i32 @f684(i32 %x) {
  %a = call i32 @f683(i32 %x)
  %b = call i32 @f342(i32 %a)
  %r = xor i32 %b, 684
  ret i32 %r
}
define internal i32 @f685(i32 %x) {
  %a = call i32 @f684(i32 %x)
  %b = call i32 @f342(i32 %a)
  %r = xor i32 %b, 685
  ret i32 %r
}
define internal i32 @f686(i32 %x) {
  %a = call i32 @f685(i32 %x)
  %b = call i32 @f343(i32 %a)
  %r = xor i32 %b, 686
  ret i32 %r
}
define internal i32 @f687(i32 %x) {
  %a = call i32 @f686(i32 %x)
  %b = call i32 @f343(i32 %a)
  %r = xor i32 %b, 687
  ret i32 %r
}
define internal i32 @f688(i32 %x) {
  %a = call i32 @f687(i32 %x)
  %b = call i32 @f344(i32 %a)
  %r = xor i32 %b, 688
  ret i32 %r
}
define internal i32 @f689(i32 %x) {
  %a = call i32 @f688(i32 %x)
  %b = call i32 @f344(i32 %a)
  %r = xor i32 %b, 689
  ret i32 %r
}
define internal i32 @f690(i32 %x) {
  %a = call i32 @f689(i32 %x)
  %b = call i32 @f345(i32 %a)
  %r = xor i32 %b, 690
  ret i32 %r
}
define internal i32 @f691(i32 %x) {
  %a = call i32 @f690(i32 %x)
  %b = call i32 @f345(i32 %a)
  %r = xor i32 %b, 691
  ret i32 %r
}
define internal i32 @f692(i32 %x) {
  %a = call i32 @f691(i32 %x)
  %b = call i32 @f346(i32 %a)
  %r = xor i32 %b, 692
  ret i32 %r
}
define internal i32 @f693(i32 %x) {
  %a = call i32 @f692(i32 %x)
  %b = call i32 @f346(i32 %a)
  %r = xor i32 %b, 693
  ret i32 %r
}
define internal i32 @f694(i32 %x) {
  %a = call i32 @f693(i32 %x)
  %b = call i32 @f347(i32 %a)
  %r = xor i32 %b, 694
  ret i32 %r
}
define internal i32 @f695(i32 %x) {
  %a = call i32 @f694(i32 %x)
  %b = call i32 @f347(i32 %a)
  %r = xor i32 %b, 695
  ret i32 %r
}
define internal i32 @f696(i32 %x) {
  %a = call i32 @f695(i32 %x)
  %b = call i32 @f348(i32 %a)
  %r = xor i32 %b, 696
  ret i32 %r
}
define internal i32 @f697(i32 %x) {
  %a = call i32 @f696(i32 %x)
  %b = call i32 @f348(i32 %a)
  %r = xor i32 %b, 697
  ret i32 %r
}
define internal i32 @f698(i32 %x) {
  %a = call i32 @f697(i32 %x)
  %b = call i32 @f349(i32 %a)
  %r = xor i32 %b, 698
  ret i32 %r
}
define internal i32 @f699(i32 %x) {
  %a = call i32 @f698(i32 %x)
  %b = call i32 @f349(i32 %a)
  %r = xor i32 %b, 699
  ret i32 %r
}
define internal i32 @f700(i32 %x) {
  %a = call i32 @f699(i32 %x)
  %b = call i32 @f350(i32 %a)
  %r = xor i32 %b, 700
  ret i32 %r
}
define internal i32 @f701(i32 %x) {
  %a = call i32 @f700(i32 %x)
  %b = call i32 @f350(i32 %a)
  %r = xor i32 %b, 701
  ret i32 %r
}
define internal i32 @f702(i32 %x) {
  %a = call i32 @f701(i32 %x)
  %b = call i32 @f351(i32 %a)
  %r = xor i32 %b, 702
  ret i32 %r
}
define internal i32 @f703(i32 %x) {
  %a = call i32 @f702(i32 %x)
  %b = call i32 @f351(i32 %a)
  %r = xor i32 %b, 703
  ret i32 %r
}
define internal i32 @f704(i32 %x) {
  %a = call i32 @f703(i32 %x)
  %b = call i32 @f352(i32 %a)
  %r = xor i32 %b, 704
  ret i32 %r
}
define internal i32 @f705(i32 %x) {
  %a = call i32 @f704(i32 %x)
  %b = call i32 @f352(i32 %a)
  %r = xor i32 %b, 705
  ret i32 %r
}
define internal i32 @f706(i32 %x) {
  %a = call i32 @f705(i32 %x)
  %b = call i32 @f353(i32 %a)
  %r = xor i32 %b, 706
  ret i32 %r
}
define internal i32 @f707(i32 %x) {
  %a = call i32 @f706(i32 %x)
  %b = call i32 @f353(i32 %a)
  %r = xor i32 %b, 707
  ret i32 %r
}
define internal i32 @f708(i32 %x) {
  %a = call i32 @f707(i32 %x)
  %b = call i32 @f354(i32 %a)
  %r = xor i32 %b, 708
  ret i32 %r
}
define internal i32 @f709(i32 %x) {
  %a = call i32 @f708(i32 %x)
  %b = call i32 @f354(i32 %a)
  %r = xor i32 %b, 709
  ret i32 %r
}
define internal i32 @f710(i32 %x) {
  %a = call i32 @f709(i32 %x)
  %b = call i32 @f355(i32 %a)
  %r = xor i32 %b, 710
  ret i32 %r
}
define internal i32 @f711(i32 %x) {
  %a = call i32 @f710(i32 %x)
  %b = call i32 @f355(i32 %a)
  %r = xor i32 %b, 711
  ret i32 %r
}
define internal i32 @f712(i32 %x) {
  %a = call i32 @f711(i32 %x)
  %b = call i32 @f356(i32 %a)
  %r = xor i32 %b, 712
  ret i32 %r
}
define internal i32 @f713(i32 %x) {
  %a = call i32 @f712(i32 %x)
  %b = call i32 @f356(i32 %a)
  %r = xor i32 %b, 713
  ret i32 %r
}
define internal i32 @f714(i32 %x) {
  %a = call i32 @f713(i32 %x)
  %b = call i32 @f357(i32 %a)
  %r = xor i32 %b, 714
  ret i32 %r
}
define internal i32 @f715(i32 %x) {
  %a = call i32 @f714(i32 %x)
  %b = call i32 @f357(i32 %a)
  %r = xor i32 %b, 715
  ret i32 %r
}
define internal i32 @f716(i32 %x) {
  %a = call i32 @f715(i32 %x)
  %b = call i32 @f358(i32 %a)
  %r = xor i32 %b, 716
  ret i32 %r
}
define internal i32 @f717(i32 %x) {
  %a = call i32 @f716(i32 %x)
  %b = call i32 @f358(i32 %a)
  %r = xor i32 %b, 717
  ret i32 %r
}
define internal i32 @f718(i32 %x) {
  %a = call i32 @f717(i32 %x)
  %b = call i32 @f359(i32 %a)
  %r = xor i32 %b, 718
  ret i32 %r
}
define internal i32 @f719(i32 %x) {
  %a = call i32 @f718(i32 %x)
  %b = call i32 @f359(i32 %a)
  %r = xor i32 %b, 719
  ret i32 %r
}
define internal i32 @f720(i32 %x) {
  %a = call i32 @f719(i32 %x)
  %b = call i32 @f360(i32 %a)
  %r = xor i32 %b, 720
  ret i32 %r
}
define internal i32 @f721(i32 %x) {
  %a = call i32 @f720(i32 %x)
  %b = call i32 @f360(i32 %a)
  %r = xor i32 %b, 721
  ret i32 %r
}
define internal i32 @f722(i32 %x) {
  %a = call i32 @f721(i32 %x)
  %b = call i32 @f361(i32 %a)
  %r = xor i32 %b, 722
  ret i32 %r
}
define internal i32 @f723(i32 %x) {
  %a = call i32 @f722(i32 %x)
  %b = call i32 @f361(i32 %a)
  %r = xor i32 %b, 723
  ret i32 %r
}
define internal i32 @f724(i32 %x) {
  %a = call i32 @f723(i32 %x)
  %b = call i32 @f362(i32 %a)
  %r = xor i32 %b, 724
  ret i32 %r
}
define internal i32 @f725(i32 %x) {
  %a = call i32 @f724(i32 %x)
  %b = call i32 @f362(i32 %a)
  %r = xor i32 %b, 725
  ret i32 %r
}
define internal i32 @f726(i32 %x) {
  %a = call i32 @f725(i32 %x)
  %b = call i32 @f363(i32 %a)
  %r = xor i32 %b, 726
  ret i32 %r
}
define internal i32 @f727(i32 %x) {
  %a = call i32 @f726(i32 %x)
  %b = call i32 @f363(i32 %a)
  %r = xor i32 %b, 727
  ret i32 %r
}
define internal i32 @f728(i32 %x) {
  %a = call i32 @f727(i32 %x)
  %b = call i32 @f364(i32 %a)
  %r = xor i32 %b, 728
  ret i32 %r
}
define internal i32 @f729(i32 %x) {
  %a = call i32 @f728(i32 %x)
  %b = call i32 @f364(i32 %a)
  %r = xor i32 %b, 729
  ret i32 %r
}
define internal i32 @f730(i32 %x) {
  %a = call i32 @f729(i32 %x)
  %b = call i32 @f365(i32 %a)
  %r = xor i32 %b, 730
  ret i32 %r
}
define internal i32 @f731(i32 %x) {
  %a = call i32 @f730(i32 %x)
  %b = call i32 @f365(i32 %a)
  %r = xor i32 %b, 731
  ret i32 %r
}
define internal i32 @f732(i32 %x) {
  %a = call i32 @f731(i32 %x)
  %b = call i32 @f366(i32 %a)
  %r = xor i32 %b, 732
  ret i32 %r
}
define internal i32 @f733(i32 %x) {
  %a = call i32 @f732(i32 %x)
  %b = call i32 @f366(i32 %a)
  %r = xor i32 %b, 733
  ret i32 %r
}
define internal i32 @f734(i32 %x) {
  %a = call i32 @f733(i32 %x)
  %b = call i32 @f367(i32 %a)
  %r = xor i32 %b, 734
  ret i32 %r
}
define internal i32 @f735(i32 %x) {
  %a = call i32 @f734(i32 %x)
  %b = call i32 @f367(i32 %a)
  %r = xor i32 %b, 735
  ret i32 %r
}
define internal i32 @f736(i32 %x) {
  %a = call i32 @f735(i32 %x)
  %b = call i32 @f368(i32 %a)
  %r = xor i32 %b, 736
  ret i32 %r
}
define internal i32 @f737(i32 %x) {
  %a = call i32 @f736(i32 %x)
  %b = call i32 @f368(i32 %a)
  %r = xor i32 %b, 737
  ret i32 %r
}
define internal i32 @f738(i32 %x) {
  %a = call i32 @f737(i32 %x)
  %b = call i32 @f369(i32 %a)
  %r = xor i32 %b, 738
  ret i32 %r
}
define internal i32 @f739(i32 %x) {
  %a = call i32 @f738(i32 %x)
  %b = call i32 @f369(i32 %a)
  %r = xor i32 %b, 739
  ret i32 %r
}
define internal i32 @f740(i32 %x) {
  %a = call i32 @f739(i32 %x)
  %b = call i32 @f370(i32 %a)
  %r = xor i32 %b, 740
  ret i32 %r
}
define internal i32 @f741(i32 %x) {
  %a = call i32 @f740(i32 %x)
  %b = call i32 @f370(i32 %a)
  %r = xor i32 %b, 741
  ret i32 %r
}
define internal i32 @f742(i32 %x) {
  %a = call i32 @f741(i32 %x)
  %b = call i32 @f371(i32 %a)
  %r = xor i32 %b, 742
  ret i32 %r
}
define internal i32 @f743(i32 %x) {
  %a = call i32 @f742(i32 %x)
  %b = call i32 @f371(i32 %a)
  %r = xor i32 %b, 743
  ret i32 %r
}
define internal i32 @f744(i32 %x) {
  %a = call i32 @f743(i32 %x)
  %b = call i32 @f372(i32 %a)
  %r = xor i32 %b, 744
  ret i32 %r
}
define internal i32 @f745(i32 %x) {
  %a = call i32 @f744(i32 %x)
  %b = call i32 @f372(i32 %a)
  %r = xor i32 %b, 745
  ret i32 %r
}
define internal i32 @f746(i32 %x) {
  %a = call i32 @f745(i32 %x)
  %b = call i32 @f373(i32 %a)
  %r = xor i32 %b, 746
  ret i32 %r
}
define internal i32 @f747(i32 %x) {
  %a = call i32 @f746(i32 %x)
  %b = call i32 @f373(i32 %a)
  %r = xor i32 %b, 747
  ret i32 %r
}
define internal i32 @f748(i32 %x) {
  %a = call i32 @f747(i32 %x)
  %b = call i32 @f374(i32 %a)
  %r = xor i32 %b, 748
  ret i32 %r
}
define internal i32 @f749(i32 %x) {
  %a = call i32 @f748(i32 %x)
  %b = call i32 @f374(i32 %a)
  %r = xor i32 %b, 749
  ret i32 %r
}
define internal i32 @f750(i32 %x) {
  %a = call i32 @f749(i32 %x)
  %b = call i32 @f375(i32 %a)
  %r = xor i32 %b, 750
  ret i32 %r
}
define internal i32 @f751(i32 %x) {
  %a = call i32 @f750(i32 %x)
  %b = call i32 @f375(i32 %a)
  %r = xor i32 %b, 751
  ret i32 %r
}
define internal i32 @f752(i32 %x) {
  %a = call i32 @f751(i32 %x)
  %b = call i32 @f376(i32 %a)
  %r = xor i32 %b, 752
  ret i32 %r
}
define internal i32 @f753(i32 %x) {
  %a = call i32 @f752(i32 %x)
  %b = call i32 @f376(i32 %a)
  %r = xor i32 %b, 753
  ret i32 %r
}
define internal i32 @f754(i32 %x) {
  %a = call i32 @f753(i32 %x)
  %b = call i32 @f377(i32 %a)
  %r = xor i32 %b, 754
  ret i32 %r
}
define internal i32 @f755(i32 %x) {
  %a = call i32 @f754(i32 %x)
  %b = call i32 @f377(i32 %a)
  %r = xor i32 %b, 755
  ret i32 %r
}
define internal i32 @f756(i32 %x) {
  %a = call i32 @f755(i32 %x)
  %b = call i32 @f378(i32 %a)
  %r = xor i32 %b, 756
  ret i32 %r
}
define internal i32 @f757(i32 %x) {
  %a = call i32 @f756(i32 %x)
  %b = call i32 @f378(i32 %a)
  %r = xor i32 %b, 757
  ret i32 %r
}
define internal i32 @f758(i32 %x) {
  %a = call i32 @f757(i32 %x)
  %b = call i32 @f379(i32 %a)
  %r = xor i32 %b, 758
  ret i32 %r
}
define internal i32 @f759(i32 %x) {
  %a = call i32 @f758(i32 %x)
  %b = call i32 @f379(i32 %a)
  %r = xor i32 %b, 759
  ret i32 %r
}
define internal i32 @f760(i32 %x) {
  %a = call i32 @f759(i32 %x)
  %b = call i32 @f380(i32 %a)
  %r = xor i32 %b, 760
  ret i32 %r
}
define internal i32 @f761(i32 %x) {
  %a = call i32 @f760(i32 %x)
  %b = call i32 @f380(i32 %a)
  %r = xor i32 %b, 761
  ret i32 %r
}
define internal i32 @f762(i32 %x) {
  %a = call i32 @f761(i32 %x)
  %b = call i32 @f381(i32 %a)
  %r = xor i32 %b, 762
  ret i32 %r
}
define internal i32 @f763(i32 %x) {
  %a = call i32 @f762(i32 %x)
  %b = call i32 @f381(i32 %a)
  %r = xor i32 %b, 763
  ret i32 %r
}
define internal i32 @f764(i32 %x) {
  %a = call i32 @f763(i32 %x)
  %b = call i32 @f382(i32 %a)
  %r = xor i32 %b, 764
  ret i32 %r
}
define internal i32 @f765(i32 %x) {
  %a = call i32 @f764(i32 %x)
  %b = call i32 @f382(i32 %a)
  %r = xor i32 %b, 765
  ret i32 %r
}
define internal i32 @f766(i32 %x) {
  %a = call i32 @f765(i32 %x)
  %b = call i32 @f383(i32 %a)
  %r = xor i32 %b, 766
  ret i32 %r
}
define internal i32 @f767(i32 %x) {
  %a = call i32 @f766(i32 %x)
  %b = call i32 @f383(i32 %a)
  %r = xor i32 %b, 767
  ret i32 %r
}
define internal i32 @f768(i32 %x) {
  %a = call i32 @f767(i32 %x)
  %b = call i32 @f384(i32 %a)
  %r = xor i32 %b, 768
  ret i32 %r
}
define internal i32 @f769(i32 %x) {
  %a = call i32 @f768(i32 %x)
  %b = call i32 @f384(i32 %a)
  %r = xor i32 %b, 769
  ret i32 %r
}
define internal i32 @f770(i32 %x) {
  %a = call i32 @f769(i32 %x)
  %b = call i32 @f385(i32 %a)
  %r = xor i32 %b, 770
  ret i32 %r
}
define internal i32 @f771(i32 %x) {
  %a = call i32 @f770(i32 %x)
  %b = call i32 @f385(i32 %a)
  %r = xor i32 %b, 771
  ret i32 %r
}
define internal i32 @f772(i32 %x) {
  %a = call i32 @f771(i32 %x)
  %b = call i32 @f386(i32 %a)
  %r = xor i32 %b, 772
  ret i32 %r
}
define internal i32 @f773(i32 %x) {
  %a = call i32 @f772(i32 %x)
  %b = call i32 @f386(i32 %a)
  %r = xor i32 %b, 773
  ret i32 %r
}
define internal i32 @f774(i32 %x) {
  %a = call i32 @f773(i32 %x)
  %b = call i32 @f387(i32 %a)
  %r = xor i32 %b, 774
  ret i32 %r
}
define internal i32 @f775(i32 %x) {
  %a = call i32 @f774(i32 %x)
  %b = call i32 @f387(i32 %a)
  %r = xor i32 %b, 775
  ret i32 %r
}
define internal i32 @f776(i32 %x) {
  %a = call i32 @f775(i32 %x)
  %b = call i32 @f388(i32 %a)
  %r = xor i32 %b, 776
  ret i32 %r
}
define internal i32 @f777(i32 %x) {
  %a = call i32 @f776(i32 %x)
  %b = call i32 @f388(i32 %a)
  %r = xor i32 %b, 777
  ret i32 %r
}
define internal i32 @f778(i32 %x) {
  %a = call i32 @f777(i32 %x)
  %b = call i32 @f389(i32 %a)
  %r = xor i32 %b, 778
  ret i32 %r
}
define internal i32 @f779(i32 %x) {
  %a = call i32 @f778(i32 %x)
  %b = call i32 @f389(i32 %a)
  %r = xor i32 %b, 779
  ret i32 %r
}
define internal i32 @f780(i32 %x) {
  %a = call i32 @f779(i32 %x)
  %b = call i32 @f390(i32 %a)
  %r = xor i32 %b, 780
  ret i32 %r
}
define internal i32 @f781(i32 %x) {
  %a = call i32 @f780(i32 %x)
  %b = call i32 @f390(i32 %a)
  %r = xor i32 %b, 781
  ret i32 %r
}
define internal i32 @f782(i32 %x) {
  %a = call i32 @f781(i32 %x)
  %b = call i32 @f391(i32 %a)
  %r = xor i32 %b, 782
  ret i32 %r
}
define internal i32 @f783(i32 %x) {
  %a = call i32 @f782(i32 %x)
  %b = call i32 @f391(i32 %a)
  %r = xor i32 %b, 783
  ret i32 %r
}
define internal i32 @f784(i32 %x) {
  %a = call i32 @f783(i32 %x)
  %b = call i32 @f392(i32 %a)
  %r = xor i32 %b, 784
  ret i32 %r
}
define internal i32 @f785(i32 %x) {
  %a = call i32 @f784(i32 %x)
  %b = call i32 @f392(i32 %a)
  %r = xor i32 %b, 785
  ret i32 %r
}
define internal i32 @f786(i32 %x) {
  %a = call i32 @f785(i32 %x)
  %b = call i32 @f393(i32 %a)
  %r = xor i32 %b, 786
  ret i32 %r
}
define internal i32 @f787(i32 %x) {
  %a = call i32 @f786(i32 %x)
  %b = call i32 @f393(i32 %a)
  %r = xor i32 %b, 787
  ret i32 %r
}
define internal i32 @f788(i32 %x) {
  %a = call i32 @f787(i32 %x)
  %b = call i32 @f394(i32 %a)
  %r = xor i32 %b, 788
  ret i32 %r
}
define internal i32 @f789(i32 %x) {
  %a = call i32 @f788(i32 %x)
  %b = call i32 @f394(i32 %a)
  %r = xor i32 %b, 789
  ret i32 %r
}
define internal i32 @f790(i32 %x) {
  %a = call i32 @f789(i32 %x)
  %b = call i32 @f395(i32 %a)
  %r = xor i32 %b, 790
  ret i32 %r
}
define internal i32 @f791(i32 %x) {
  %a = call i32 @f790(i32 %x)
  %b = call i32 @f395(i32 %a)
  %r = xor i32 %b, 791
  ret i32 %r
}
define internal i32 @f792(i32 %x) {
  %a = call i32 @f791(i32 %x)
  %b = call i32 @f396(i32 %a)
  %r = xor i32 %b, 792
  ret i32 %r
}
define internal i32 @f793(i32 %x) {
  %a = call i32 @f792(i32 %x)
  %b = call i32 @f396(i32 %a)
  %r = xor i32 %b, 793
  ret i32 %r
}
define internal i32 @f794(i32 %x) {
  %a = call i32 @f793(i32 %x)
  %b = call i32 @f397(i32 %a)
  %r = xor i32 %b, 794
  ret i32 %r
}
define internal i32 @f795(i32 %x) {
  %a = call i32 @f794(i32 %x)
  %b = call i32 @f397(i32 %a)
  %r = xor i32 %b, 795
  ret i32 %r
}
define internal i32 @f796(i32 %x) {
  %a = call i32 @f795(i32 %x)
  %b = call i32 @f398(i32 %a)
  %r = xor i32 %b, 796
  ret i32 %r
}
define internal i32 @f797(i32 %x) {
  %a = call i32 @f796(i32 %x)
  %b = call i32 @f398(i32 %a)
  %r = xor i32 %b, 797
  ret i32 %r
}
define internal i32 @f798(i32 %x) {
  %a = call i32 @f797(i32 %x)
  %b = call i32 @f399(i32 %a)
  %r = xor i32 %b, 798
  ret i32 %r
}
define internal i32 @f799(i32 %x) {
  %a = call i32 @f798(i32 %x)
  %b = call i32 @f399(i32 %a)
  %r = xor i32 %b, 799
  ret i32 %r
}
define internal i32 @f800(i32 %x) {
  %a = call i32 @f799(i32 %x)
  %b = call i32 @f400(i32 %a)
  %r = xor i32 %b, 800
  ret i32 %r
}
define internal i32 @f801(i32 %x) {
  %a = call i32 @f800(i32 %x)
  %b = call i32 @f400(i32 %a)
  %r = xor i32 %b, 801
  ret i32 %r
}
define internal i32 @f802(i32 %x) {
  %a = call i32 @f801(i32 %x)
  %b = call i32 @f401(i32 %a)
  %r = xor i32 %b, 802
  ret i32 %r
}
define internal i32 @f803(i32 %x) {
  %a = call i32 @f802(i32 %x)
  %b = call i32 @f401(i32 %a)
  %r = xor i32 %b, 803
  ret i32 %r
}
define internal i32 @f804(i32 %x) {
  %a = call i32 @f803(i32 %x)
  %b = call i32 @f402(i32 %a)
  %r = xor i32 %b, 804
  ret i32 %r
}
define internal i32 @f805(i32 %x) {
  %a = call i32 @f804(i32 %x)
  %b = call i32 @f402(i32 %a)
  %r = xor i32 %b, 805
  ret i32 %r
}
define internal i32 @f806(i32 %x) {
  %a = call i32 @f805(i32 %x)
  %b = call i32 @f403(i32 %a)
  %r = xor i32 %b, 806
  ret i32 %r
}
define internal i32 @f807(i32 %x) {
  %a = call i32 @f806(i32 %x)
  %b = call i32 @f403(i32 %a)
  %r = xor i32 %b, 807
  ret i32 %r
}
define internal i32 @f808(i32 %x) {
  %a = call i32 @f807(i32 %x)
  %b = call i32 @f404(i32 %a)
  %r = xor i32 %b, 808
  ret i32 %r
}
define internal i32 @f809(i32 %x) {
  %a = call i32 @f808(i32 %x)
  %b = call i32 @f404(i32 %a)
  %r = xor i32 %b, 809
  ret i32 %r
}
define internal i32 @f810(i32 %x) {
  %a = call i32 @f809(i32 %x)
  %b = call i32 @f405(i32 %a)
  %r = xor i32 %b, 810
  ret i32 %r
}
define internal i32 @f811(i32 %x) {
  %a = call i32 @f810(i32 %x)
  %b = call i32 @f405(i32 %a)
  %r = xor i32 %b, 811
  ret i32 %r
}
define internal i32 @f812(i32 %x) {
  %a = call i32 @f811(i32 %x)
  %b = call i32 @f406(i32 %a)
  %r = xor i32 %b, 812
  ret i32 %r
}
define internal i32 @f813(i32 %x) {
  %a = call i32 @f812(i32 %x)
  %b = call i32 @f406(i32 %a)
  %r = xor i32 %b, 813
  ret i32 %r
}
define internal i32 @f814(i32 %x) {
  %a = call i32 @f813(i32 %x)
  %b = call i32 @f407(i32 %a)
  %r = xor i32 %b, 814
  ret i32 %r
}
define internal i32 @f815(i32 %x) {
  %a = call i32 @f814(i32 %x)
  %b = call i32 @f407(i32 %a)
  %r = xor i32 %b, 815
  ret i32 %r
}
define internal i32 @f816(i32 %x) {
  %a = call i32 @f815(i32 %x)
  %b = call i32 @f408(i32 %a)
  %r = xor i32 %b, 816
  ret i32 %r
}
define internal i32 @f817(i32 %x) {
  %a = call i32 @f816(i32 %x)
  %b = call i32 @f408(i32 %a)
  %r = xor i32 %b, 817
  ret i32 %r
}
define internal i32 @f818(i32 %x) {
  %a = call i32 @f817(i32 %x)
  %b = call i32 @f409(i32 %a)
  %r = xor i32 %b, 818
  ret i32 %r
}
define internal i32 @f819(i32 %x) {
  %a = call i32 @f818(i32 %x)
  %b = call i32 @f409(i32 %a)
  %r = xor i32 %b, 819
  ret i32 %r
}
define internal i32 @f820(i32 %x) {
  %a = call i32 @f819(i32 %x)
  %b = call i32 @f410(i32 %a)
  %r = xor i32 %b, 820
  ret i32 %r
}
define internal i32 @f821(i32 %x) {
  %a = call i32 @f820(i32 %x)
  %b = call i32 @f410(i32 %a)
  %r = xor i32 %b, 821
  ret i32 %r
}
define internal i32 @f822(i32 %x) {
  %a = call i32 @f821(i32 %x)
  %b = call i32 @f411(i32 %a)
  %r = xor i32 %b, 822
  ret i32 %r
}
define internal i32 @f823(i32 %x) {
  %a = call i32 @f822(i32 %x)
  %b = call i32 @f411(i32 %a)
  %r = xor i32 %b, 823
  ret i32 %r
}
define internal i32 @f824(i32 %x) {
  %a = call i32 @f823(i32 %x)
  %b = call i32 @f412(i32 %a)
  %r = xor i32 %b, 824
  ret i32 %r
}
define internal i32 @f825(i32 %x) {
  %a = call i32 @f824(i32 %x)
  %b = call i32 @f412(i32 %a)
  %r = xor i32 %b, 825
  ret i32 %r
}
define internal i32 @f826(i32 %x) {
  %a = call i32 @f825(i32 %x)
  %b = call i32 @f413(i32 %a)
  %r = xor i32 %b, 826
  ret i32 %r
}
define internal i32 @f827(i32 %x) {
  %a = call i32 @f826(i32 %x)
  %b = call i32 @f413(i32 %a)
  %r = xor i32 %b, 827
  ret i32 %r
}
define internal i32 @f828(i32 %x) {
  %a = call i32 @f827(i32 %x)
  %b = call i32 @f414(i32 %a)
  %r = xor i32 %b, 828
  ret i32 %r
}
define internal i32 @f829(i32 %x) {
  %a = call i32 @f828(i32 %x)
  %b = call i32 @f414(i32 %a)
  %r = xor i32 %b, 829
  ret i32 %r
}
define internal i32 @f830(i32 %x) {
  %a = call i32 @f829(i32 %x)
  %b = call i32 @f415(i32 %a)
  %r = xor i32 %b, 830
  ret i32 %r
}
define internal i32 @f831(i32 %x) {
  %a = call i32 @f830(i32 %x)
  %b = call i32 @f415(i32 %a)
  %r = xor i32 %b, 831
  ret i32 %r
}
define internal i32 @f832(i32 %x) {
  %a = call i32 @f831(i32 %x)
  %b = call i32 @f416(i32 %a)
  %r = xor i32 %b, 832
  ret i32 %r
}
define internal i32 @f833(i32 %x) {
  %a = call i32 @f832(i32 %x)
  %b = call i32 @f416(i32 %a)
  %r = xor i32 %b, 833
  ret i32 %r
}
define internal i32 @f834(i32 %x) {
  %a = call i32 @f833(i32 %x)
  %b = call i32 @f417(i32 %a)
  %r = xor i32 %b, 834
  ret i32 %r
}
define internal i32 @f835(i32 %x) {
  %a = call i32 @f834(i32 %x)
  %b = call i32 @f417(i32 %a)
  %r = xor i32 %b, 835
  ret i32 %r
}
define internal i32 @f836(i32 %x) {
  %a = call i32 @f835(i32 %x)
  %b = call i32 @f418(i32 %a)
  %r = xor i32 %b, 836
  ret i32 %r
}
define internal i32 @f837(i32 %x) {
  %a = call i32 @f836(i32 %x)
  %b = call i32 @f418(i32 %a)
  %r = xor i32 %b, 837
  ret i32 %r
}
define internal i32 @f838(i32 %x) {
  %a = call i32 @f837(i32 %x)
  %b = call i32 @f419(i32 %a)
  %r = xor i32 %b, 838
  ret i32 %r
}
define internal i32 @f839(i32 %x) {
  %a = call i32 @f838(i32 %x)
  %b = call i32 @f419(i32 %a)
  %r = xor i32 %b, 839
  ret i32 %r
}
define internal i32 @f840(i32 %x) {
  %a = call i32 @f839(i32 %x)
  %b = call i32 @f420(i32 %a)
  %r = xor i32 %b, 840
  ret i32 %r
}
define internal i32 @f841(i32 %x) {
  %a = call i32 @f840(i32 %x)
  %b = call i32 @f420(i32 %a)
  %r = xor i32 %b, 841
  ret i32 %r
}
define internal i32 @f842(i32 %x) {
  %a = call i32 @f841(i32 %x)
  %b = call i32 @f421(i32 %a)
  %r = xor i32 %b, 842
  ret i32 %r
}
define internal i32 @f843(i32 %x) {
  %a = call i32 @f842(i32 %x)
  %b = call i32 @f421(i32 %a)
  %r = xor i32 %b, 843
  ret i32 %r
}
define internal i32 @f844(i32 %x) {
  %a = call i32 @f843(i32 %x)
  %b = call i32 @f422(i32 %a)
  %r = xor i32 %b, 844
  ret i32 %r
}
define internal i32 @f845(i32 %x) {
  %a = call i32 @f844(i32 %x)
  %b = call i32 @f422(i32 %a)
  %r = xor i32 %b, 845
  ret i32 %r
}
define internal i32 @f846(i32 %x) {
  %a = call i32 @f845(i32 %x)
  %b = call i32 @f423(i32 %a)
  %r = xor i32 %b, 846
  ret i32 %r
}
define internal i32 @f847(i32 %x) {
  %a = call i32 @f846(i32 %x)
  %b = call i32 @f423(i32 %a)
  %r = xor i32 %b, 847
  ret i32 %r
}
define internal i32 @f848(i32 %x) {
  %a = call i32 @f847(i32 %x)
  %b = call i32 @f424(i32 %a)
  %r = xor i32 %b, 848
  ret i32 %r
}
define internal i32 @f849(i32 %x) {
  %a = call i32 @f848(i32 %x)
  %b = call i32 @f424(i32 %a)
  %r = xor i32 %b, 849
  ret i32 %r
}
define internal i32 @f850(i32 %x) {
  %a = call i32 @f849(i32 %x)
  %b = call i32 @f425(i32 %a)
  %r = xor i32 %b, 850
  ret i32 %r
}
define internal i32 @f851(i32 %x) {
  %a = call i32 @f850(i32 %x)
  %b = call i32 @f425(i32 %a)
  %r = xor i32 %b, 851
  ret i32 %r
}
define internal i32 @f852(i32 %x) {
  %a = call i32 @f851(i32 %x)
  %b = call i32 @f426(i32 %a)
  %r = xor i32 %b, 852
  ret i32 %r
}
define internal i32 @f853(i32 %x) {
  %a = call i32 @f852(i32 %x)
  %b = call i32 @f426(i32 %a)
  %r = xor i32 %b, 853
  ret i32 %r
}
define internal i32 @f854(i32 %x) {
  %a = call i32 @f853(i32 %x)
  %b = call i32 @f427(i32 %a)
  %r = xor i32 %b, 854
  ret i32 %r
}
define internal i32 @f855(i32 %x) {
  %a = call i32 @f854(i32 %x)
  %b = call i32 @f427(i32 %a)
  %r = xor i32 %b, 855
  ret i32 %r
}
define internal i32 @f856(i32 %x) {
  %a = call i32 @f855(i32 %x)
  %b = call i32 @f428(i32 %a)
  %r = xor i32 %b, 856
  ret i32 %r
}
define internal i32 @f857(i32 %x) {
  %a = call i32 @f856(i32 %x)
  %b = call i32 @f428(i32 %a)
  %r = xor i32 %b, 857
  ret i32 %r
}
define internal i32 @f858(i32 %x) {
  %a = call i32 @f857(i32 %x)
  %b = call i32 @f429(i32 %a)
  %r = xor i32 %b, 858
  ret i32 %r
}
define internal i32 @f859(i32 %x) {
  %a = call i32 @f858(i32 %x)
  %b = call i32 @f429(i32 %a)
  %r = xor i32 %b, 859
  ret i32 %r
}
define internal i32 @f860(i32 %x) {
  %a = call i32 @f859(i32 %x)
  %b = call i32 @f430(i32 %a)
  %r = xor i32 %b, 860
  ret i32 %r
}
define internal i32 @f861(i32 %x) {
  %a = call i32 @f860(i32 %x)
  %b = call i32 @f430(i32 %a)
  %r = xor i32 %b, 861
  ret i32 %r
}
define internal i32 @f862(i32 %x) {
  %a = call i32 @f861(i32 %x)
  %b = call i32 @f431(i32 %a)
  %r = xor i32 %b, 862
  ret i32 %r
}
define internal i32 @f863(i32 %x) {
  %a = call i32 @f862(i32 %x)
  %b = call i32 @f431(i32 %a)
  %r = xor i32 %b, 863
  ret i32 %r
}
define internal i32 @f864(i32 %x) {
  %a = call i32 @f863(i32 %x)
  %b = call i32 @f432(i32 %a)
  %r = xor i32 %b, 864
  ret i32 %r
}
define internal i32 @f865(i32 %x) {
  %a = call i32 @f864(i32 %x)
  %b = call i32 @f432(i32 %a)
  %r = xor i32 %b, 865
  ret i32 %r
}
define internal i32 @f866(i32 %x) {
  %a = call i32 @f865(i32 %x)
  %b = call i32 @f433(i32 %a)
  %r = xor i32 %b, 866
  ret i32 %r
}
define internal i32 @f867(i32 %x) {
  %a = call i32 @f866(i32 %x)
  %b = call i32 @f433(i32 %a)
  %r = xor i32 %b, 867
  ret i32 %r
}
define internal i32 @f868(i32 %x) {
  %a = call i32 @f867(i32 %x)
  %b = call i32 @f434(i32 %a)
  %r = xor i32 %b, 868
  ret i32 %r
}
define internal i32 @f869(i32 %x) {
  %a = call i32 @f868(i32 %x)
  %b = call i32 @f434(i32 %a)
  %r = xor i32 %b, 869
  ret i32 %r
}
define internal i32 @f870(i32 %x) {
  %a = call i32 @f869(i32 %x)
  %b = call i32 @f435(i32 %a)
  %r = xor i32 %b, 870
  ret i32 %r
}
define internal i32 @f871(i32 %x) {
  %a = call i32 @f870(i32 %x)
  %b = call i32 @f435(i32 %a)
  %r = xor i32 %b, 871
  ret i32 %r
}
define internal i32 @f872(i32 %x) {
  %a = call i32 @f871(i32 %x)
  %b = call i32 @f436(i32 %a)
  %r = xor i32 %b, 872
  ret i32 %r
}
define internal i32 @f873(i32 %x) {
  %a = call i32 @f872(i32 %x)
  %b = call i32 @f436(i32 %a)
  %r = xor i32 %b, 873
  ret i32 %r
}
define internal i32 @f874(i32 %x) {
  %a = call i32 @f873(i32 %x)
  %b = call i32 @f437(i32 %a)
  %r = xor i32 %b, 874
  ret i32 %r
}
define internal i32 @f875(i32 %x) {
  %a = call i32 @f874(i32 %x)
  %b = call i32 @f437(i32 %a)
  %r = xor i32 %b, 875
  ret i32 %r
}
define internal i32 @f876(i32 %x) {
  %a = call i32 @f875(i32 %x)
  %b = call i32 @f438(i32 %a)
  %r = xor i32 %b, 876
  ret i32 %r
}
define internal i32 @f877(i32 %x) {
  %a = call i32 @f876(i32 %x)
  %b = call i32 @f438(i32 %a)
  %r = xor i32 %b, 877
  ret i32 %r
}
define internal i32 @f878(i32 %x) {
  %a = call i32 @f877(i32 %x)
  %b = call i32 @f439(i32 %a)
  %r = xor i32 %b, 878
  ret i32 %r
}
define internal i32 @f879(i32 %x) {
  %a = call i32 @f878(i32 %x)
  %b = call i32 @f439(i32 %a)
  %r = xor i32 %b, 879
  ret i32 %r
}
define internal i32 @f880(i32 %x) {
  %a = call i32 @f879(i32 %x)
  %b = call i32 @f440(i32 %a)
  %r = xor i32 %b, 880
  ret i32 %r
}
define internal i32 @f881(i32 %x) {
  %a = call i32 @f880(i32 %x)
  %b = call i32 @f440(i32 %a)
  %r = xor i32 %b, 881
  ret i32 %r
}
define internal i32 @f882(i32 %x) {
  %a = call i32 @f881(i32 %x)
  %b = call i32 @f441(i32 %a)
  %r = xor i32 %b, 882
  ret i32 %r
}
define internal i32 @f883(i32 %x) {
  %a = call i32 @f882(i32 %x)
  %b = call i32 @f441(i32 %a)
  %r = xor i32 %b, 883
  ret i32 %r
}
define internal i32 @f884(i32 %x) {
  %a = call i32 @f883(i32 %x)
  %b = call i32 @f442(i32 %a)
  %r = xor i32 %b, 884
  ret i32 %r
}
define internal i32 @f885(i32 %x) {
  %a = call i32 @f884(i32 %x)
  %b = call i32 @f442(i32 %a)
  %r = xor i32 %b, 885
  ret i32 %r
}
define internal i32 @f886(i32 %x) {
  %a = call i32 @f885(i32 %x)
  %b = call i32 @f443(i32 %a)
  %r = xor i32 %b, 886
  ret i32 %r
}
define internal i32 @f887(i32 %x) {
  %a = call i32 @f886(i32 %x)
  %b = call i32 @f443(i32 %a)
  %r = xor i32 %b, 887
  ret i32 %r
}
define internal i32 @f888(i32 %x) {
  %a = call i32 @f887(i32 %x)
  %b = call i32 @f444(i32 %a)
  %r = xor i32 %b, 888
  ret i32 %r
}
define internal i32 @f889(i32 %x) {
  %a = call i32 @f888(i32 %x)
  %b = call i32 @f444(i32 %a)
  %r = xor i32 %b, 889
  ret i32 %r
}
define internal i32 @f890(i32 %x) {
  %a = call i32 @f889(i32 %x)
  %b = call i32 @f445(i32 %a)
  %r = xor i32 %b, 890
  ret i32 %r
}
define internal i32 @f891(i32 %x) {
  %a = call i32 @f890(i32 %x)
  %b = call i32 @f445(i32 %a)
  %r = xor i32 %b, 891
  ret i32 %r
}
define internal i32 @f892(i32 %x) {
  %a = call i32 @f891(i32 %x)
  %b = call i32 @f446(i32 %a)
  %r = xor i32 %b, 892
  ret i32 %r
}
define internal i32 @f893(i32 %x) {
  %a = call i32 @f892(i32 %x)
  %b = call i32 @f446(i32 %a)
  %r = xor i32 %b, 893
  ret i32 %r
}
define internal i32 @f894(i32 %x) {
  %a = call i32 @f893(i32 %x)
  %b = call i32 @f447(i32 %a)
  %r = xor i32 %b, 894
  ret i32 %r
}
define internal i32 @f895(i32 %x) {
  %a = call i32 @f894(i32 %x)
  %b = call i32 @f447(i32 %a)
  %r = xor i32 %b, 895
  ret i32 %r
}
define internal i32 @f896(i32 %x) {
  %a = call i32 @f895(i32 %x)
  %b = call i32 @f448(i32 %a)
  %r = xor i32 %b, 896
  ret i32 %r
}
define internal i32 @f897(i32 %x) {
  %a = call i32 @f896(i32 %x)
  %b = call i32 @f448(i32 %a)
  %r = xor i32 %b, 897
  ret i32 %r
}
define internal i32 @f898(i32 %x) {
  %a = call i32 @f897(i32 %x)
  %b = call i32 @f449(i32 %a)
  %r = xor i32 %b, 898
  ret i32 %r
}
define internal i32 @f899(i32 %x) {
  %a = call i32 @f898(i32 %x)
  %b = call i32 @f449(i32 %a)
  %r = xor i32 %b, 899
  ret i32 %r
}
define internal i32 @f900(i32 %x) {
  %a = call i32 @f899(i32 %x)
  %b = call i32 @f450(i32 %a)
  %r = xor i32 %b, 900
  ret i32 %r
}
define internal i32 @f901(i32 %x) {
  %a = call i32 @f900(i32 %x)
  %b = call i32 @f450(i32 %a)
  %r = xor i32 %b, 901
  ret i32 %r
}
define internal i32 @f902(i32 %x) {
  %a = call i32 @f901(i32 %x)
  %b = call i32 @f451(i32 %a)
  %r = xor i32 %b, 902
  ret i32 %r
}
define internal i32 @f903(i32 %x) {
  %a = call i32 @f902(i32 %x)
  %b = call i32 @f451(i32 %a)
  %r = xor i32 %b, 903
  ret i32 %r
}
define internal i32 @f904(i32 %x) {
  %a = call i32 @f903(i32 %x)
  %b = call i32 @f452(i32 %a)
  %r = xor i32 %b, 904
  ret i32 %r
}
define internal i32 @f905(i32 %x) {
  %a = call i32 @f904(i32 %x)
  %b = call i32 @f452(i32 %a)
  %r = xor i32 %b, 905
  ret i32 %r
}
define internal i32 @f906(i32 %x) {
  %a = call i32 @f905(i32 %x)
  %b = call i32 @f453(i32 %a)
  %r = xor i32 %b, 906
  ret i32 %r
}
define internal i32 @f907(i32 %x) {
  %a = call i32 @f906(i32 %x)
  %b = call i32 @f453(i32 %a)
  %r = xor i32 %b, 907
  ret i32 %r
}
define internal i32 @f908(i32 %x) {
  %a = call i32 @f907(i32 %x)
  %b = call i32 @f454(i32 %a)
  %r = xor i32 %b, 908
  ret i32 %r
}
define internal i32 @f909(i32 %x) {
  %a = call i32 @f908(i32 %x)
  %b = call i32 @f454(i32 %a)
  %r = xor i32 %b, 909
  ret i32 %r
}
define internal i32 @f910(i32 %x) {
  %a = call i32 @f909(i32 %x)
  %b = call i32 @f455(i32 %a)
  %r = xor i32 %b, 910
  ret i32 %r
}
define internal i32 @f911(i32 %x) {
  %a = call i32 @f910(i32 %x)
  %b = call i32 @f455(i32 %a)
  %r = xor i32 %b, 911
  ret i32 %r
}
define internal i32 @f912(i32 %x) {
  %a = call i32 @f911(i32 %x)
  %b = call i32 @f456(i32 %a)
  %r = xor i32 %b, 912
  ret i32 %r
}
define internal i32 @f913(i32 %x) {
  %a = call i32 @f912(i32 %x)
  %b = call i32 @f456(i32 %a)
  %r = xor i32 %b, 913
  ret i32 %r
}
define internal i32 @f914(i32 %x) {
  %a = call i32 @f913(i32 %x)
  %b = call i32 @f457(i32 %a)
  %r = xor i32 %b, 914
  ret i32 %r
}
define internal i32 @f915(i32 %x) {
  %a = call i32 @f914(i32 %x)
  %b = call i32 @f457(i32 %a)
  %r = xor i32 %b, 915
  ret i32 %r
}
define internal i32 @f916(i32 %x) {
  %a = call i32 @f915(i32 %x)
  %b = call i32 @f458(i32 %a)
  %r = xor i32 %b, 916
  ret i32 %r
}
define internal i32 @f917(i32 %x) {
  %a = call i32 @f916(i32 %x)
  %b = call i32 @f458(i32 %a)
  %r = xor i32 %b, 917
  ret i32 %r
}
define internal i32 @f918(i32 %x) {
  %a = call i32 @f917(i32 %x)
  %b = call i32 @f459(i32 %a)
  %r = xor i32 %b, 918
  ret i32 %r
}
define internal i32 @f919(i32 %x) {
  %a = call i32 @f918(i32 %x)
  %b = call i32 @f459(i32 %a)
  %r = xor i32 %b, 919
  ret i32 %r
}
define internal i32 @f920(i32 %x) {
  %a = call i32 @f919(i32 %x)
  %b = call i32 @f460(i32 %a)
  %r = xor i32 %b, 920
  ret i32 %r
}
define internal i32 @f921(i32 %x) {
  %a = call i32 @f920(i32 %x)
  %b = call i32 @f460(i32 %a)
  %r = xor i32 %b, 921
  ret i32 %r
}
define internal i32 @f922(i32 %x) {
  %a = call i32 @f921(i32 %x)
  %b = call i32 @f461(i32 %a)
  %r = xor i32 %b, 922
  ret i32 %r
}
define internal i32 @f923(i32 %x) {
  %a = call i32 @f922(i32 %x)
  %b = call i32 @f461(i32 %a)
  %r = xor i32 %b, 923
  ret i32 %r
}
define internal i32 @f924(i32 %x) {
  %a = call i32 @f923(i32 %x)
  %b = call i32 @f462(i32 %a)
  %r = xor i32 %b, 924
  ret i32 %r
}
define internal i32 @f925(i32 %x) {
  %a = call i32 @f924(i32 %x)
  %b = call i32 @f462(i32 %a)
  %r = xor i32 %b, 925
  ret i32 %r
}
define internal i32 @f926(i32 %x) {
  %a = call i32 @f925(i32 %x)
  %b = call i32 @f463(i32 %a)
  %r = xor i32 %b, 926
  ret i32 %r
}
define internal i32 @f927(i32 %x) {
  %a = call i32 @f926(i32 %x)
  %b = call i32 @f463(i32 %a)
  %r = xor i32 %b, 927
  ret i32 %r
}
define internal i32 @f928(i32 %x) {
  %a = call i32 @f927(i32 %x)
  %b = call i32 @f464(i32 %a)
  %r = xor i32 %b, 928
  ret i32 %r
}
define internal i32 @f929(i32 %x) {
  %a = call i32 @f928(i32 %x)
  %b = call i32 @f464(i32 %a)
  %r = xor i32 %b, 929
  ret i32 %r
}
define internal i32 @f930(i32 %x) {
  %a = call i32 @f929(i32 %x)
  %b = call i32 @f465(i32 %a)
  %r = xor i32 %b, 930
  ret i32 %r
}
define internal i32 @f931(i32 %x) {
  %a = call i32 @f930(i32 %x)
  %b = call i32 @f465(i32 %a)
  %r = xor i32 %b, 931
  ret i32 %r
}
define internal i32 @f932(i32 %x) {
  %a = call i32 @f931(i32 %x)
  %b = call i32 @f466(i32 %a)
  %r = xor i32 %b, 932
  ret i32 %r
}
define internal i32 @f933(i32 %x) {
  %a = call i32 @f932(i32 %x)
  %b = call i32 @f466(i32 %a)
  %r = xor i32 %b, 933
  ret i32 %r
}
define internal i32 @f934(i32 %x) {
  %a = call i32 @f933(i32 %x)
  %b = call i32 @f467(i32 %a)
  %r = xor i32 %b, 934
  ret i32 %r
}
define internal i32 @f935(i32 %x) {
  %a = call i32 @f934(i32 %x)
  %b = call i32 @f467(i32 %a)
  %r = xor i32 %b, 935
  ret i32 %r
}
define internal i32 @f936(i32 %x) {
  %a = call i32 @f935(i32 %x)
  %b = call i32 @f468(i32 %a)
  %r = xor i32 %b, 936
  ret i32 %r
}
define internal i32 @f937(i32 %x) {
  %a = call i32 @f936(i32 %x)
  %b = call i32 @f468(i32 %a)
  %r = xor i32 %b, 937
  ret i32 %r
}
define internal i32 @f938(i32 %x) {
  %a = call i32 @f937(i32 %x)
  %b = call i32 @f469(i32 %a)
  %r = xor i32 %b, 938
  ret i32 %r
}
define internal i32 @f939(i32 %x) {
  %a = call i32 @f938(i32 %x)
  %b = call i32 @f469(i32 %a)
  %r = xor i32 %b, 939
  ret i32 %r
}
define internal i32 @f940(i32 %x) {
  %a = call i32 @f939(i32 %x)
  %b = call i32 @f470(i32 %a)
  %r = xor i32 %b, 940
  ret i32 %r
}
define internal i32 @f941(i32 %x) {
  %a = call i32 @f940(i32 %x)
  %b = call i32 @f470(i32 %a)
  %r = xor i32 %b, 941
  ret i32 %r
}
define internal i32 @f942(i32 %x) {
  %a = call i32 @f941(i32 %x)
  %b = call i32 @f471(i32 %a)
  %r = xor i32 %b, 942
  ret i32 %r
}
define internal i32 @f943(i32 %x) {
  %a = call i32 @f942(i32 %x)
  %b = call i32 @f471(i32 %a)
  %r = xor i32 %b, 943
  ret i32 %r
}
define internal i32 @f944(i32 %x) {
  %a = call i32 @f943(i32 %x)
  %b = call i32 @f472(i32 %a)
  %r = xor i32 %b, 944
  ret i32 %r
}
define internal i32 @f945(i32 %x) {
  %a = call i32 @f944(i32 %x)
  %b = call i32 @f472(i32 %a)
  %r = xor i32 %b, 945
  ret i32 %r
}
define internal i32 @f946(i32 %x) {
  %a = call i32 @f945(i32 %x)
  %b = call i32 @f473(i32 %a)
  %r = xor i32 %b, 946
  ret i32 %r
}
define internal i32 @f947(i32 %x) {
  %a = call i32 @f946(i32 %x)
  %b = call i32 @f473(i32 %a)
  %r = xor i32 %b, 947
  ret i32 %r
}
define internal i32 @f948(i32 %x) {
  %a = call i32 @f947(i32 %x)
  %b = call i32 @f474(i32 %a)
  %r = xor i32 %b, 948
  ret i32 %r
}
define internal i32 @f949(i32 %x) {
  %a = call i32 @f948(i32 %x)
  %b = call i32 @f474(i32 %a)
  %r = xor i32 %b, 949
  ret i32 %r
}
define internal i32 @f950(i32 %x) {
  %a = call i32 @f949(i32 %x)
  %b = call i32 @f475(i32 %a)
  %r = xor i32 %b, 950
  ret i32 %r
}
define internal i32 @f951(i32 %x) {
  %a = call i32 @f950(i32 %x)
  %b = call i32 @f475(i32 %a)
  %r = xor i32 %b, 951
  ret i32 %r
}
define internal i32 @f952(i32 %x) {
  %a = call i32 @f951(i32 %x)
  %b = call i32 @f476(i32 %a)
  %r = xor i32 %b, 952
  ret i32 %r
}
define internal i32 @f953(i32 %x) {
  %a = call i32 @f952(i32 %x)
  %b = call i32 @f476(i32 %a)
  %r = xor i32 %b, 953
  ret i32 %r
}
define internal i32 @f954(i32 %x) {
  %a = call i32 @f953(i32 %x)
  %b = call i32 @f477(i32 %a)
  %r = xor i32 %b, 954
  ret i32 %r
}
define internal i32 @f955(i32 %x) {
  %a = call i32 @f954(i32 %x)
  %b = call i32 @f477(i32 %a)
  %r = xor i32 %b, 955
  ret i32 %r
}
define internal i32 @f956(i32 %x) {
  %a = call i32 @f955(i32 %x)
  %b = call i32 @f478(i32 %a)
  %r = xor i32 %b, 956
  ret i32 %r
}
define internal i32 @f957(i32 %x) {
  %a = call i32 @f956(i32 %x)
  %b = call i32 @f478(i32 %a)
  %r = xor i32 %b, 957
  ret i32 %r
}
define internal i32 @f958(i32 %x) {
  %a = call i32 @f957(i32 %x)
  %b = call i32 @f479(i32 %a)
  %r = xor i32 %b, 958
  ret i32 %r
}
define internal i32 @f959(i32 %x) {
  %a = call i32 @f958(i32 %x)
  %b = call i32 @f479(i32 %a)
  %r = xor i32 %b, 959
  ret i32 %r
}
define internal i32 @f960(i32 %x) {
  %a = call i32 @f959(i32 %x)
  %b = call i32 @f480(i32 %a)
  %r = xor i32 %b, 960
  ret i32 %r
}
define internal i32 @f961(i32 %x) {
  %a = call i32 @f960(i32 %x)
  %b = call i32 @f480(i32 %a)
  %r = xor i32 %b, 961
  ret i32 %r
}
define internal i32 @f962(i32 %x) {
  %a = call i32 @f961(i32 %x)
  %b = call i32 @f481(i32 %a)
  %r = xor i32 %b, 962
  ret i32 %r
}
define internal i32 @f963(i32 %x) {
  %a = call i32 @f962(i32 %x)
  %b = call i32 @f481(i32 %a)
  %r = xor i32 %b, 963
  ret i32 %r
}
define internal i32 @f964(i32 %x) {
  %a = call i32 @f963(i32 %x)
  %b = call i32 @f482(i32 %a)
  %r = xor i32 %b, 964
  ret i32 %r
}
define internal i32 @f965(i32 %x) {
  %a = call i32 @f964(i32 %x)
  %b = call i32 @f482(i32 %a)
  %r = xor i32 %b, 965
  ret i32 %r
}
define internal i32 @f966(i32 %x) {
  %a = call i32 @f965(i32 %x)
  %b = call i32 @f483(i32 %a)
  %r = xor i32 %b, 966
  ret i32 %r
}
define internal i32 @f967(i32 %x) {
  %a = call i32 @f966(i32 %x)
  %b = call i32 @f483(i32 %a)
  %r = xor i32 %b, 967
  ret i32 %r
}
define internal i32 @f968(i32 %x) {
  %a = call i32 @f967(i32 %x)
  %b = call i32 @f484(i32 %a)
  %r = xor i32 %b, 968
  ret i32 %r
}
define internal i32 @f969(i32 %x) {
  %a = call i32 @f968(i32 %x)
  %b = call i32 @f484(i32 %a)
  %r = xor i32 %b, 969
  ret i32 %r
}
define internal i32 @f970(i32 %x) {
  %a = call i32 @f969(i32 %x)
  %b = call i32 @f485(i32 %a)
  %r = xor i32 %b, 970
  ret i32 %r
}
define internal i32 @f971(i32 %x) {
  %a = call i32 @f970(i32 %x)
  %b = call i32 @f485(i32 %a)
  %r = xor i32 %b, 971
  ret i32 %r
}
define internal i32 @f972(i32 %x) {
  %a = call i32 @f971(i32 %x)
  %b = call i32 @f486(i32 %a)
  %r = xor i32 %b, 972
  ret i32 %r
}
define internal i32 @f973(i32 %x) {
  %a = call i32 @f972(i32 %x)
  %b = call i32 @f486(i32 %a)
  %r = xor i32 %b, 973
  ret i32 %r
}
define internal i32 @f974(i32 %x) {
  %a = call i32 @f973(i32 %x)
  %b = call i32 @f487(i32 %a)
  %r = xor i32 %b, 974
  ret i32 %r
}
define internal i32 @f975(i32 %x) {
  %a = call i32 @f974(i32 %x)
  %b = call i32 @f487(i32 %a)
  %r = xor i32 %b, 975
  ret i32 %r
}
define internal i32 @f976(i32 %x) {
  %a = call i32 @f975(i32 %x)
  %b = call i32 @f488(i32 %a)
  %r = xor i32 %b, 976
  ret i32 %r
}
define internal i32 @f977(i32 %x) {
  %a = call i32 @f976(i32 %x)
  %b = call i32 @f488(i32 %a)
  %r = xor i32 %b, 977
  ret i32 %r
}
define internal i32 @f978(i32 %x) {
  %a = call i32 @f977(i32 %x)
  %b = call i32 @f489(i32 %a)
  %r = xor i32 %b, 978
  ret i32 %r
}
define internal i32 @f979(i32 %x) {
  %a = call i32 @f978(i32 %x)
  %b = call i32 @f489(i32 %a)
  %r = xor i32 %b, 979
  ret i32 %r
}
define internal i32 @f980(i32 %x) {
  %a = call i32 @f979(i32 %x)
  %b = call i32 @f490(i32 %a)
  %r = xor i32 %b, 980
  ret i32 %r
}
define internal i32 @f981(i32 %x) {
  %a = call i32 @f980(i32 %x)
  %b = call i32 @f490(i32 %a)
  %r = xor i32 %b, 981
  ret i32 %r
}
define internal i32 @f982(i32 %x) {
  %a = call i32 @f981(i32 %x)
  %b = call i32 @f491(i32 %a)
  %r = xor i32 %b, 982
  ret i32 %r
}
define internal i32 @f983(i32 %x) {
  %a = call i32 @f982(i32 %x)
  %b = call i32 @f491(i32 %a)
  %r = xor i32 %b, 983
  ret i32 %r
}
define internal i32 @f984(i32 %x) {
  %a = call i32 @f983(i32 %x)
  %b = call i32 @f492(i32 %a)
  %r = xor i32 %b, 984
  ret i32 %r
}
define internal i32 @f985(i32 %x) {
  %a = call i32 @f984(i32 %x)
  %b = call i32 @f492(i32 %a)
  %r = xor i32 %b, 985
  ret i32 %r
}
define internal i32 @f986(i32 %x) {
  %a = call i32 @f985(i32 %x)
  %b = call i32 @f493(i32 %a)
  %r = xor i32 %b, 986
  ret i32 %r
}
define internal i32 @f987(i32 %x) {
  %a = call i32 @f986(i32 %x)
  %b = call i32 @f493(i32 %a)
  %r = xor i32 %b, 987
  ret i32 %r
}
define internal i32 @f988(i32 %x) {
  %a = call i32 @f987(i32 %x)
  %b = call i32 @f494(i32 %a)
  %r = xor i32 %b, 988
  ret i32 %r
}
define internal i32 @f989(i32 %x) {
  %a = call i32 @f988(i32 %x)
  %b = call i32 @f494(i32 %a)
  %r = xor i32 %b, 989
  ret i32 %r
}
define internal i32 @f990(i32 %x) {
  %a = call i32 @f989(i32 %x)
  %b = call i32 @f495(i32 %a)
  %r = xor i32 %b, 990
  ret i32 %r
}
define internal i32 @f991(i32 %x) {
  %a = call i32 @f990(i32 %x)
  %b = call i32 @f495(i32 %a)
  %r = xor i32 %b, 991
  ret i32 %r
}
define internal i32 @f992(i32 %x) {
  %a = call i32 @f991(i32 %x)
  %b = call i32 @f496(i32 %a)
  %r = xor i32 %b, 992
  ret i32 %r
}
define internal i32 @f993(i32 %x) {
  %a = call i32 @f992(i32 %x)
  %b = call i32 @f496(i32 %a)
  %r = xor i32 %b, 993
  ret i32 %r
}
define internal i32 @f994(i32 %x) {
  %a = call i32 @f993(i32 %x)
  %b = call i32 @f497(i32 %a)
  %r = xor i32 %b, 994
  ret i32 %r
}
define internal i32 @f995(i32 %x) {
  %a = call i32 @f994(i32 %x)
  %b = call i32 @f497(i32 %a)
  %r = xor i32 %b, 995
  ret i32 %r
}
define internal i32 @f996(i32 %x) {
  %a = call i32 @f995(i32 %x)
  %b = call i32 @f498(i32 %a)
  %r = xor i32 %b, 996
  ret i32 %r
}
define internal i32 @f997(i32 %x) {
  %a = call i32 @f996(i32 %x)
  %b = call i32 @f498(i32 %a)
  %r = xor i32 %b, 997
  ret i32 %r
}
define internal i32 @f998(i32 %x) {
  %a = call i32 @f997(i32 %x)
  %b = call i32 @f499(i32 %a)
  %r = xor i32 %b, 998
  ret i32 %r
}
define internal i32 @f999(i32 %x) {
  %a = call i32 @f998(i32 %x)
  %b = call i32 @f499(i32 %a)
  %r = xor i32 %b, 999
  ret i32 %r
}
define internal i32 @f1000(i32 %x) {
  %a = call i32 @f999(i32 %x)
  %b = call i32 @f500(i32 %a)
  %r = xor i32 %b, 1000
  ret i32 %r
}
define internal i32 @f1001(i32 %x) {
  %a = call i32 @f1000(i32 %x)
  %b = call i32 @f500(i32 %a)
  %r = xor i32 %b, 1001
  ret i32 %r
}
define internal i32 @f1002(i32 %x) {
  %a = call i32 @f1001(i32 %x)
  %b = call i32 @f501(i32 %a)
  %r = xor i32 %b, 1002
  ret i32 %r
}
define internal i32 @f1003(i32 %x) {
  %a = call i32 @f1002(i32 %x)
  %b = call i32 @f501(i32 %a)
  %r = xor i32 %b, 1003
  ret i32 %r
}
define internal i32 @f1004(i32 %x) {
  %a = call i32 @f1003(i32 %x)
  %b = call i32 @f502(i32 %a)
  %r = xor i32 %b, 1004
  ret i32 %r
}
define internal i32 @f1005(i32 %x) {
  %a = call i32 @f1004(i32 %x)
  %b = call i32 @f502(i32 %a)
  %r = xor i32 %b, 1005
  ret i32 %r
}
define internal i32 @f1006(i32 %x) {
  %a = call i32 @f1005(i32 %x)
  %b = call i32 @f503(i32 %a)
  %r = xor i32 %b, 1006
  ret i32 %r
}
define internal i32 @f1007(i32 %x) {
  %a = call i32 @f1006(i32 %x)
  %b = call i32 @f503(i32 %a)
  %r = xor i32 %b, 1007
  ret i32 %r
}
define internal i32 @f1008(i32 %x) {
  %a = call i32 @f1007(i32 %x)
  %b = call i32 @f504(i32 %a)
  %r = xor i32 %b, 1008
  ret i32 %r
}
define internal i32 @f1009(i32 %x) {
  %a = call i32 @f1008(i32 %x)
  %b = call i32 @f504(i32 %a)
  %r = xor i32 %b, 1009
  ret i32 %r
}
define internal i32 @f1010(i32 %x) {
  %a = call i32 @f1009(i32 %x)
  %b = call i32 @f505(i32 %a)
  %r = xor i32 %b, 1010
  ret i32 %r
}
define internal i32 @f1011(i32 %x) {
  %a = call i32 @f1010(i32 %x)
  %b = call i32 @f505(i32 %a)
  %r = xor i32 %b, 1011
  ret i32 %r
}
define internal i32 @f1012(i32 %x) {
  %a = call i32 @f1011(i32 %x)
  %b = call i32 @f506(i32 %a)
  %r = xor i32 %b, 1012
  ret i32 %r
}
define internal i32 @f1013(i32 %x) {
  %a = call i32 @f1012(i32 %x)
  %b = call i32 @f506(i32 %a)
  %r = xor i32 %b, 1013
  ret i32 %r
}
define internal i32 @f1014(i32 %x) {
  %a = call i32 @f1013(i32 %x)
  %b = call i32 @f507(i32 %a)
  %r = xor i32 %b, 1014
  ret i32 %r
}
define internal i32 @f1015(i32 %x) {
  %a = call i32 @f1014(i32 %x)
  %b = call i32 @f507(i32 %a)
  %r = xor i32 %b, 1015
  ret i32 %r
}
define internal i32 @f1016(i32 %x) {
  %a = call i32 @f1015(i32 %x)
  %b = call i32 @f508(i32 %a)
  %r = xor i32 %b, 1016
  ret i32 %r
}
define internal i32 @f1017(i32 %x) {
  %a = call i32 @f1016(i32 %x)
  %b = call i32 @f508(i32 %a)
  %r = xor i32 %b, 1017
  ret i32 %r
}
define internal i32 @f1018(i32 %x) {
  %a = call i32 @f1017(i32 %x)
  %b = call i32 @f509(i32 %a)
  %r = xor i32 %b, 1018
  ret i32 %r
}
define internal i32 @f1019(i32 %x) {
  %a = call i32 @f1018(i32 %x)
  %b = call i32 @f509(i32 %a)
  %r = xor i32 %b, 1019
  ret i32 %r
}
define internal i32 @f1020(i32 %x) {
  %a = call i32 @f1019(i32 %x)
  %b = call i32 @f510(i32 %a)
  %r = xor i32 %b, 1020
  ret i32 %r
}
define internal i32 @f1021(i32 %x) {
  %a = call i32 @f1020(i32 %x)
  %b = call i32 @f510(i32 %a)
  %r = xor i32 %b, 1021
  ret i32 %r
}
define internal i32 @f1022(i32 %x) {
  %a = call i32 @f1021(i32 %x)
  %b = call i32 @f511(i32 %a)
  %r = xor i32 %b, 1022
  ret i32 %r
}
define internal i32 @f1023(i32 %x) {
  %a = call i32 @f1022(i32 %x)
  %b = call i32 @f511(i32 %a)
  %r = xor i32 %b, 1023
  ret i32 %r
}
define internal i32 @f1024(i32 %x) {
  %a = call i32 @f1023(i32 %x)
  %b = call i32 @f512(i32 %a)
  %r = xor i32 %b, 1024
  ret i32 %r
}
define internal i32 @f1025(i32 %x) {
  %a = call i32 @f1024(i32 %x)
  %b = call i32 @f512(i32 %a)
  %r = xor i32 %b, 1025
  ret i32 %r
}
define internal i32 @f1026(i32 %x) {
  %a = call i32 @f1025(i32 %x)
  %b = call i32 @f513(i32 %a)
  %r = xor i32 %b, 1026
  ret i32 %r
}
define internal i32 @f1027(i32 %x) {
  %a = call i32 @f1026(i32 %x)
  %b = call i32 @f513(i32 %a)
  %r = xor i32 %b, 1027
  ret i32 %r
}
define internal i32 @f1028(i32 %x) {
  %a = call i32 @f1027(i32 %x)
  %b = call i32 @f514(i32 %a)
  %r = xor i32 %b, 1028
  ret i32 %r
}
define internal i32 @f1029(i32 %x) {
  %a = call i32 @f1028(i32 %x)
  %b = call i32 @f514(i32 %a)
  %r = xor i32 %b, 1029
  ret i32 %r
}
define internal i32 @f1030(i32 %x) {
  %a = call i32 @f1029(i32 %x)
  %b = call i32 @f515(i32 %a)
  %r = xor i32 %b, 1030
  ret i32 %r
}
define internal i32 @f1031(i32 %x) {
  %a = call i32 @f1030(i32 %x)
  %b = call i32 @f515(i32 %a)
  %r = xor i32 %b, 1031
  ret i32 %r
}
define internal i32 @f1032(i32 %x) {
  %a = call i32 @f1031(i32 %x)
  %b = call i32 @f516(i32 %a)
  %r = xor i32 %b, 1032
  ret i32 %r
}
define internal i32 @f1033(i32 %x) {
  %a = call i32 @f1032(i32 %x)
  %b = call i32 @f516(i32 %a)
  %r = xor i32 %b, 1033
  ret i32 %r
}
define internal i32 @f1034(i32 %x) {
  %a = call i32 @f1033(i32 %x)
  %b = call i32 @f517(i32 %a)
  %r = xor i32 %b, 1034
  ret i32 %r
}
define internal i32 @f1035(i32 %x) {
  %a = call i32 @f1034(i32 %x)
  %b = call i32 @f517(i32 %a)
  %r = xor i32 %b, 1035
  ret i32 %r
}
define internal i32 @f1036(i32 %x) {
  %a = call i32 @f1035(i32 %x)
  %b = call i32 @f518(i32 %a)
  %r = xor i32 %b, 1036
  ret i32 %r
}
define internal i32 @f1037(i32 %x) {
  %a = call i32 @f1036(i32 %x)
  %b = call i32 @f518(i32 %a)
  %r = xor i32 %b, 1037
  ret i32 %r
}
define internal i32 @f1038(i32 %x) {
  %a = call i32 @f1037(i32 %x)
  %b = call i32 @f519(i32 %a)
  %r = xor i32 %b, 1038
  ret i32 %r
}
define internal i32 @f1039(i32 %x) {
  %a = call i32 @f1038(i32 %x)
  %b = call i32 @f519(i32 %a)
  %r = xor i32 %b, 1039
  ret i32 %r
}
define internal i32 @f1040(i32 %x) {
  %a = call i32 @f1039(i32 %x)
  %b = call i32 @f520(i32 %a)
  %r = xor i32 %b, 1040
  ret i32 %r
}
define internal i32 @f1041(i32 %x) {
  %a = call i32 @f1040(i32 %x)
  %b = call i32 @f520(i32 %a)
  %r = xor i32 %b, 1041
  ret i32 %r
}
define internal i32 @f1042(i32 %x) {
  %a = call i32 @f1041(i32 %x)
  %b = call i32 @f521(i32 %a)
  %r = xor i32 %b, 1042
  ret i32 %r
}
define internal i32 @f1043(i32 %x) {
  %a = call i32 @f1042(i32 %x)
  %b = call i32 @f521(i32 %a)
  %r = xor i32 %b, 1043
  ret i32 %r
}
define internal i32 @f1044(i32 %x) {
  %a = call i32 @f1043(i32 %x)
  %b = call i32 @f522(i32 %a)
  %r = xor i32 %b, 1044
  ret i32 %r
}
define internal i32 @f1045(i32 %x) {
  %a = call i32 @f1044(i32 %x)
  %b = call i32 @f522(i32 %a)
  %r = xor i32 %b, 1045
  ret i32 %r
}
define internal i32 @f1046(i32 %x) {
  %a = call i32 @f1045(i32 %x)
  %b = call i32 @f523(i32 %a)
  %r = xor i32 %b, 1046
  ret i32 %r
}
define internal i32 @f1047(i32 %x) {
  %a = call i32 @f1046(i32 %x)
  %b = call i32 @f523(i32 %a)
  %r = xor i32 %b, 1047
  ret i32 %r
}
define internal i32 @f1048(i32 %x) {
  %a = call i32 @f1047(i32 %x)
  %b = call i32 @f524(i32 %a)
  %r = xor i32 %b, 1048
  ret i32 %r
}
define internal i32 @f1049(i32 %x) {
  %a = call i32 @f1048(i32 %x)
  %b = call i32 @f524(i32 %a)
  %r = xor i32 %b, 1049
  ret i32 %r
}
define internal i32 @f1050(i32 %x) {
  %a = call i32 @f1049(i32 %x)
  %b = call i32 @f525(i32 %a)
  %r = xor i32 %b, 1050
  ret i32 %r
}
define internal i32 @f1051(i32 %x) {
  %a = call i32 @f1050(i32 %x)
  %b = call i32 @f525(i32 %a)
  %r = xor i32 %b, 1051
  ret i32 %r
}
define internal i32 @f1052(i32 %x) {
  %a = call i32 @f1051(i32 %x)
  %b = call i32 @f526(i32 %a)
  %r = xor i32 %b, 1052
  ret i32 %r
}
define internal i32 @f1053(i32 %x) {
  %a = call i32 @f1052(i32 %x)
  %b = call i32 @f526(i32 %a)
  %r = xor i32 %b, 1053
  ret i32 %r
}
define internal i32 @f1054(i32 %x) {
  %a = call i32 @f1053(i32 %x)
  %b = call i32 @f527(i32 %a)
  %r = xor i32 %b, 1054
  ret i32 %r
}
define internal i32 @f1055(i32 %x) {
  %a = call i32 @f1054(i32 %x)
  %b = call i32 @f527(i32 %a)
  %r = xor i32 %b, 1055
  ret i32 %r
}
define internal i32 @f1056(i32 %x) {
  %a = call i32 @f1055(i32 %x)
  %b = call i32 @f528(i32 %a)
  %r = xor i32 %b, 1056
  ret i32 %r
}
define internal i32 @f1057(i32 %x) {
  %a = call i32 @f1056(i32 %x)
  %b = call i32 @f528(i32 %a)
  %r = xor i32 %b, 1057
  ret i32 %r
}
define internal i32 @f1058(i32 %x) {
  %a = call i32 @f1057(i32 %x)
  %b = call i32 @f529(i32 %a)
  %r = xor i32 %b, 1058
  ret i32 %r
}
define internal i32 @f1059(i32 %x) {
  %a = call i32 @f1058(i32 %x)
  %b = call i32 @f529(i32 %a)
  %r = xor i32 %b, 1059
  ret i32 %r
}
define internal i32 @f1060(i32 %x) {
  %a = call i32 @f1059(i32 %x)
  %b = call i32 @f530(i32 %a)
  %r = xor i32 %b, 1060
  ret i32 %r
}
define internal i32 @f1061(i32 %x) {
  %a = call i32 @f1060(i32 %x)
  %b = call i32 @f530(i32 %a)
  %r = xor i32 %b, 1061
  ret i32 %r
}
define internal i32 @f1062(i32 %x) {
  %a = call i32 @f1061(i32 %x)
  %b = call i32 @f531(i32 %a)
  %r = xor i32 %b, 1062
  ret i32 %r
}
define internal i32 @f1063(i32 %x) {
  %a = call i32 @f1062(i32 %x)
  %b = call i32 @f531(i32 %a)
  %r = xor i32 %b, 1063
  ret i32 %r
}
define internal i32 @f1064(i32 %x) {
  %a = call i32 @f1063(i32 %x)
  %b = call i32 @f532(i32 %a)
  %r = xor i32 %b, 1064
  ret i32 %r
}
define internal i32 @f1065(i32 %x) {
  %a = call i32 @f1064(i32 %x)
  %b = call i32 @f532(i32 %a)
  %r = xor i32 %b, 1065
  ret i32 %r
}
define internal i32 @f1066(i32 %x) {
  %a = call i32 @f1065(i32 %x)
  %b = call i32 @f533(i32 %a)
  %r = xor i32 %b, 1066
  ret i32 %r
}
define internal i32 @f1067(i32 %x) {
  %a = call i32 @f1066(i32 %x)
  %b = call i32 @f533(i32 %a)
  %r = xor i32 %b, 1067
  ret i32 %r
}
define internal i32 @f1068(i32 %x) {
  %a = call i32 @f1067(i32 %x)
  %b = call i32 @f534(i32 %a)
  %r = xor i32 %b, 1068
  ret i32 %r
}
define internal i32 @f1069(i32 %x) {
  %a = call i32 @f1068(i32 %x)
  %b = call i32 @f534(i32 %a)
  %r = xor i32 %b, 1069
  ret i32 %r
}
define internal i32 @f1070(i32 %x) {
  %a = call i32 @f1069(i32 %x)
  %b = call i32 @f535(i32 %a)
  %r = xor i32 %b, 1070
  ret i32 %r
}
define internal i32 @f1071(i32 %x) {
  %a = call i32 @f1070(i32 %x)
  %b = call i32 @f535(i32 %a)
  %r = xor i32 %b, 1071
  ret i32 %r
}
define internal i32 @f1072(i32 %x) {
  %a = call i32 @f1071(i32 %x)
  %b = call i32 @f536(i32 %a)
  %r = xor i32 %b, 1072
  ret i32 %r
}
define internal i32 @f1073(i32 %x) {
  %a = call i32 @f1072(i32 %x)
  %b = call i32 @f536(i32 %a)
  %r = xor i32 %b, 1073
  ret i32 %r
}
define internal i32 @f1074(i32 %x) {
  %a = call i32 @f1073(i32 %x)
  %b = call i32 @f537(i32 %a)
  %r = xor i32 %b, 1074
  ret i32 %r
}
define internal i32 @f1075(i32 %x) {
  %a = call i32 @f1074(i32 %x)
  %b = call i32 @f537(i32 %a)
  %r = xor i32 %b, 1075
  ret i32 %r
}
define internal i32 @f1076(i32 %x) {
  %a = call i32 @f1075(i32 %x)
  %b = call i32 @f538(i32 %a)
  %r = xor i32 %b, 1076
  ret i32 %r
}
define internal i32 @f1077(i32 %x) {
  %a = call i32 @f1076(i32 %x)
  %b = call i32 @f538(i32 %a)
  %r = xor i32 %b, 1077
  ret i32 %r
}
define internal i32 @f1078(i32 %x) {
  %a = call i32 @f1077(i32 %x)
  %b = call i32 @f539(i32 %a)
  %r = xor i32 %b, 1078
  ret i32 %r
}
define internal i32 @f1079(i32 %x) {
  %a = call i32 @f1078(i32 %x)
  %b = call i32 @f539(i32 %a)
  %r = xor i32 %b, 1079
  ret i32 %r
}
define internal i32 @f1080(i32 %x) {
  %a = call i32 @f1079(i32 %x)
  %b = call i32 @f540(i32 %a)
  %r = xor i32 %b, 1080
  ret i32 %r
}
define internal i32 @f1081(i32 %x) {
  %a = call i32 @f1080(i32 %x)
  %b = call i32 @f540(i32 %a)
  %r = xor i32 %b, 1081
  ret i32 %r
}
define internal i32 @f1082(i32 %x) {
  %a = call i32 @f1081(i32 %x)
  %b = call i32 @f541(i32 %a)
  %r = xor i32 %b, 1082
  ret i32 %r
}
define internal i32 @f1083(i32 %x) {
  %a = call i32 @f1082(i32 %x)
  %b = call i32 @f541(i32 %a)
  %r = xor i32 %b, 1083
  ret i32 %r
}
define internal i32 @f1084(i32 %x) {
  %a = call i32 @f1083(i32 %x)
  %b = call i32 @f542(i32 %a)
  %r = xor i32 %b, 1084
  ret i32 %r
}
define internal i32 @f1085(i32 %x) {
  %a = call i32 @f1084(i32 %x)
  %b = call i32 @f542(i32 %a)
  %r = xor i32 %b, 1085
  ret i32 %r
}
define internal i32 @f1086(i32 %x) {
  %a = call i32 @f1085(i32 %x)
  %b = call i32 @f543(i32 %a)
  %r = xor i32 %b, 1086
  ret i32 %r
}
define internal i32 @f1087(i32 %x) {
  %a = call i32 @f1086(i32 %x)
  %b = call i32 @f543(i32 %a)
  %r = xor i32 %b, 1087
  ret i32 %r
}
define internal i32 @f1088(i32 %x) {
  %a = call i32 @f1087(i32 %x)
  %b = call i32 @f544(i32 %a)
  %r = xor i32 %b, 1088
  ret i32 %r
}
define internal i32 @f1089(i32 %x) {
  %a = call i32 @f1088(i32 %x)
  %b = call i32 @f544(i32 %a)
  %r = xor i32 %b, 1089
  ret i32 %r
}
define internal i32 @f1090(i32 %x) {
  %a = call i32 @f1089(i32 %x)
  %b = call i32 @f545(i32 %a)
  %r = xor i32 %b, 1090
  ret i32 %r
}
define internal i32 @f1091(i32 %x) {
  %a = call i32 @f1090(i32 %x)
  %b = call i32 @f545(i32 %a)
  %r = xor i32 %b, 1091
  ret i32 %r
}
define internal i32 @f1092(i32 %x) {
  %a = call i32 @f1091(i32 %x)
  %b = call i32 @f546(i32 %a)
  %r = xor i32 %b, 1092
  ret i32 %r
}
define internal i32 @f1093(i32 %x) {
  %a = call i32 @f1092(i32 %x)
  %b = call i32 @f546(i32 %a)
  %r = xor i32 %b, 1093
  ret i32 %r
}
define internal i32 @f1094(i32 %x) {
  %a = call i32 @f1093(i32 %x)
  %b = call i32 @f547(i32 %a)
  %r = xor i32 %b, 1094
  ret i32 %r
}
define internal i32 @f1095(i32 %x) {
  %a = call i32 @f1094(i32 %x)
  %b = call i32 @f547(i32 %a)
  %r = xor i32 %b, 1095
  ret i32 %r
}
define internal i32 @f1096(i32 %x) {
  %a = call i32 @f1095(i32 %x)
  %b = call i32 @f548(i32 %a)
  %r = xor i32 %b, 1096
  ret i32 %r
}
define internal i32 @f1097(i32 %x) {
  %a = call i32 @f1096(i32 %x)
  %b = call i32 @f548(i32 %a)
  %r = xor i32 %b, 1097
  ret i32 %r
}
define internal i32 @f1098(i32 %x) {
  %a = call i32 @f1097(i32 %x)
  %b = call i32 @f549(i32 %a)
  %r = xor i32 %b, 1098
  ret i32 %r
}
define internal i32 @f1099(i32 %x) {
  %a = call i32 @f1098(i32 %x)
  %b = call i32 @f549(i32 %a)
  %r = xor i32 %b, 1099
  ret i32 %r
}
define internal i32 @f1100(i32 %x) {
  %a = call i32 @f1099(i32 %x)
  %b = call i32 @f550(i32 %a)
  %r = xor i32 %b, 1100
  ret i32 %r
}
define internal i32 @f1101(i32 %x) {
  %a = call i32 @f1100(i32 %x)
  %b = call i32 @f550(i32 %a)
  %r = xor i32 %b, 1101
  ret i32 %r
}
define internal i32 @f1102(i32 %x) {
  %a = call i32 @f1101(i32 %x)
  %b = call i32 @f551(i32 %a)
  %r = xor i32 %b, 1102
  ret i32 %r
}
define internal i32 @f1103(i32 %x) {
  %a = call i32 @f1102(i32 %x)
  %b = call i32 @f551(i32 %a)
  %r = xor i32 %b, 1103
  ret i32 %r
}
define internal i32 @f1104(i32 %x) {
  %a = call i32 @f1103(i32 %x)
  %b = call i32 @f552(i32 %a)
  %r = xor i32 %b, 1104
  ret i32 %r
}
define internal i32 @f1105(i32 %x) {
  %a = call i32 @f1104(i32 %x)
  %b = call i32 @f552(i32 %a)
  %r = xor i32 %b, 1105
  ret i32 %r
}
define internal i32 @f1106(i32 %x) {
  %a = call i32 @f1105(i32 %x)
  %b = call i32 @f553(i32 %a)
  %r = xor i32 %b, 1106
  ret i32 %r
}
define internal i32 @f1107(i32 %x) {
  %a = call i32 @f1106(i32 %x)
  %b = call i32 @f553(i32 %a)
  %r = xor i32 %b, 1107
  ret i32 %r
}
define internal i32 @f1108(i32 %x) {
  %a = call i32 @f1107(i32 %x)
  %b = call i32 @f554(i32 %a)
  %r = xor i32 %b, 1108
  ret i32 %r
}
define internal i32 @f1109(i32 %x) {
  %a = call i32 @f1108(i32 %x)
  %b = call i32 @f554(i32 %a)
  %r = xor i32 %b, 1109
  ret i32 %r
}
define internal i32 @f1110(i32 %x) {
  %a = call i32 @f1109(i32 %x)
  %b = call i32 @f555(i32 %a)
  %r = xor i32 %b, 1110
  ret i32 %r
}
define internal i32 @f1111(i32 %x) {
  %a = call i32 @f1110(i32 %x)
  %b = call i32 @f555(i32 %a)
  %r = xor i32 %b, 1111
  ret i32 %r
}
define internal i32 @f1112(i32 %x) {
  %a = call i32 @f1111(i32 %x)
  %b = call i32 @f556(i32 %a)
  %r = xor i32 %b, 1112
  ret i32 %r
}
define internal i32 @f1113(i32 %x) {
  %a = call i32 @f1112(i32 %x)
  %b = call i32 @f556(i32 %a)
  %r = xor i32 %b, 1113
  ret i32 %r
}
define internal i32 @f1114(i32 %x) {
  %a = call i32 @f1113(i32 %x)
  %b = call i32 @f557(i32 %a)
  %r = xor i32 %b, 1114
  ret i32 %r
}
define internal i32 @f1115(i32 %x) {
  %a = call i32 @f1114(i32 %x)
  %b = call i32 @f557(i32 %a)
  %r = xor i32 %b, 1115
  ret i32 %r
}
define internal i32 @f1116(i32 %x) {
  %a = call i32 @f1115(i32 %x)
  %b = call i32 @f558(i32 %a)
  %r = xor i32 %b, 1116
  ret i32 %r
}
define internal i32 @f1117(i32 %x) {
  %a = call i32 @f1116(i32 %x)
  %b = call i32 @f558(i32 %a)
  %r = xor i32 %b, 1117
  ret i32 %r
}
define internal i32 @f1118(i32 %x) {
  %a = call i32 @f1117(i32 %x)
  %b = call i32 @f559(i32 %a)
  %r = xor i32 %b, 1118
  ret i32 %r
}
define internal i32 @f1119(i32 %x) {
  %a = call i32 @f1118(i32 %x)
  %b = call i32 @f559(i32 %a)
  %r = xor i32 %b, 1119
  ret i32 %r
}
define internal i32 @f1120(i32 %x) {
  %a = call i32 @f1119(i32 %x)
  %b = call i32 @f560(i32 %a)
  %r = xor i32 %b, 1120
  ret i32 %r
}
define internal i32 @f1121(i32 %x) {
  %a = call i32 @f1120(i32 %x)
  %b = call i32 @f560(i32 %a)
  %r = xor i32 %b, 1121
  ret i32 %r
}
define internal i32 @f1122(i32 %x) {
  %a = call i32 @f1121(i32 %x)
  %b = call i32 @f561(i32 %a)
  %r = xor i32 %b, 1122
  ret i32 %r
}
define internal i32 @f1123(i32 %x) {
  %a = call i32 @f1122(i32 %x)
  %b = call i32 @f561(i32 %a)
  %r = xor i32 %b, 1123
  ret i32 %r
}
define internal i32 @f1124(i32 %x) {
  %a = call i32 @f1123(i32 %x)
  %b = call i32 @f562(i32 %a)
  %r = xor i32 %b, 1124
  ret i32 %r
}
define internal i32 @f1125(i32 %x) {
  %a = call i32 @f1124(i32 %x)
  %b = call i32 @f562(i32 %a)
  %r = xor i32 %b, 1125
  ret i32 %r
}
define internal i32 @f1126(i32 %x) {
  %a = call i32 @f1125(i32 %x)
  %b = call i32 @f563(i32 %a)
  %r = xor i32 %b, 1126
  ret i32 %r
}
define internal i32 @f1127(i32 %x) {
  %a = call i32 @f1126(i32 %x)
  %b = call i32 @f563(i32 %a)
  %r = xor i32 %b, 1127
  ret i32 %r
}
define internal i32 @f1128(i32 %x) {
  %a = call i32 @f1127(i32 %x)
  %b = call i32 @f564(i32 %a)
  %r = xor i32 %b, 1128
  ret i32 %r
}
define internal i32 @f1129(i32 %x) {
  %a = call i32 @f1128(i32 %x)
  %b = call i32 @f564(i32 %a)
  %r = xor i32 %b, 1129
  ret i32 %r
}
define internal i32 @f1130(i32 %x) {
  %a = call i32 @f1129(i32 %x)
  %b = call i32 @f565(i32 %a)
  %r = xor i32 %b, 1130
  ret i32 %r
}
define internal i32 @f1131(i32 %x) {
  %a = call i32 @f1130(i32 %x)
  %b = call i32 @f565(i32 %a)
  %r = xor i32 %b, 1131
  ret i32 %r
}
define internal i32 @f1132(i32 %x) {
  %a = call i32 @f1131(i32 %x)
  %b = call i32 @f566(i32 %a)
  %r = xor i32 %b, 1132
  ret i32 %r
}
define internal i32 @f1133(i32 %x) {
  %a = call i32 @f1132(i32 %x)
  %b = call i32 @f566(i32 %a)
  %r = xor i32 %b, 1133
  ret i32 %r
}
define internal i32 @f1134(i32 %x) {
  %a = call i32 @f1133(i32 %x)
  %b = call i32 @f567(i32 %a)
  %r = xor i32 %b, 1134
  ret i32 %r
}
define internal i32 @f1135(i32 %x) {
  %a = call i32 @f1134(i32 %x)
  %b = call i32 @f567(i32 %a)
  %r = xor i32 %b, 1135
  ret i32 %r
}
define internal i32 @f1136(i32 %x) {
  %a = call i32 @f1135(i32 %x)
  %b = call i32 @f568(i32 %a)
  %r = xor i32 %b, 1136
  ret i32 %r
}
define internal i32 @f1137(i32 %x) {
  %a = call i32 @f1136(i32 %x)
  %b = call i32 @f568(i32 %a)
  %r = xor i32 %b, 1137
  ret i32 %r
}
define internal i32 @f1138(i32 %x) {
  %a = call i32 @f1137(i32 %x)
  %b = call i32 @f569(i32 %a)
  %r = xor i32 %b, 1138
  ret i32 %r
}
define internal i32 @f1139(i32 %x) {
  %a = call i32 @f1138(i32 %x)
  %b = call i32 @f569(i32 %a)
  %r = xor i32 %b, 1139
  ret i32 %r
}
define internal i32 @f1140(i32 %x) {
  %a = call i32 @f1139(i32 %x)
  %b = call i32 @f570(i32 %a)
  %r = xor i32 %b, 1140
  ret i32 %r
}
define internal i32 @f1141(i32 %x) {
  %a = call i32 @f1140(i32 %x)
  %b = call i32 @f570(i32 %a)
  %r = xor i32 %b, 1141
  ret i32 %r
}
define internal i32 @f1142(i32 %x) {
  %a = call i32 @f1141(i32 %x)
  %b = call i32 @f571(i32 %a)
  %r = xor i32 %b, 1142
  ret i32 %r
}
define internal i32 @f1143(i32 %x) {
  %a = call i32 @f1142(i32 %x)
  %b = call i32 @f571(i32 %a)
  %r = xor i32 %b, 1143
  ret i32 %r
}
define internal i32 @f1144(i32 %x) {
  %a = call i32 @f1143(i32 %x)
  %b = call i32 @f572(i32 %a)
  %r = xor i32 %b, 1144
  ret i32 %r
}
define internal i32 @f1145(i32 %x) {
  %a = call i32 @f1144(i32 %x)
  %b = call i32 @f572(i32 %a)
  %r = xor i32 %b, 1145
  ret i32 %r
}
define internal i32 @f1146(i32 %x) {
  %a = call i32 @f1145(i32 %x)
  %b = call i32 @f573(i32 %a)
  %r = xor i32 %b, 1146
  ret i32 %r
}
define internal i32 @f1147(i32 %x) {
  %a = call i32 @f1146(i32 %x)
  %b = call i32 @f573(i32 %a)
  %r = xor i32 %b, 1147
  ret i32 %r
}
define internal i32 @f1148(i32 %x) {
  %a = call i32 @f1147(i32 %x)
  %b = call i32 @f574(i32 %a)
  %r = xor i32 %b, 1148
  ret i32 %r
}
define internal i32 @f1149(i32 %x) {
  %a = call i32 @f1148(i32 %x)
  %b = call i32 @f574(i32 %a)
  %r = xor i32 %b, 1149
  ret i32 %r
}
define internal i32 @f1150(i32 %x) {
  %a = call i32 @f1149(i32 %x)
  %b = call i32 @f575(i32 %a)
  %r = xor i32 %b, 1150
  ret i32 %r
}
define internal i32 @f1151(i32 %x) {
  %a = call i32 @f1150(i32 %x)
  %b = call i32 @f575(i32 %a)
  %r = xor i32 %b, 1151
  ret i32 %r
}
define internal i32 @f1152(i32 %x) {
  %a = call i32 @f1151(i32 %x)
  %b = call i32 @f576(i32 %a)
  %r = xor i32 %b, 1152
  ret i32 %r
}
define internal i32 @f1153(i32 %x) {
  %a = call i32 @f1152(i32 %x)
  %b = call i32 @f576(i32 %a)
  %r = xor i32 %b, 1153
  ret i32 %r
}
define internal i32 @f1154(i32 %x) {
  %a = call i32 @f1153(i32 %x)
  %b = call i32 @f577(i32 %a)
  %r = xor i32 %b, 1154
  ret i32 %r
}
define internal i32 @f1155(i32 %x) {
  %a = call i32 @f1154(i32 %x)
  %b = call i32 @f577(i32 %a)
  %r = xor i32 %b, 1155
  ret i32 %r
}
define internal i32 @f1156(i32 %x) {
  %a = call i32 @f1155(i32 %x)
  %b = call i32 @f578(i32 %a)
  %r = xor i32 %b, 1156
  ret i32 %r
}
define internal i32 @f1157(i32 %x) {
  %a = call i32 @f1156(i32 %x)
  %b = call i32 @f578(i32 %a)
  %r = xor i32 %b, 1157
  ret i32 %r
}
define internal i32 @f1158(i32 %x) {
  %a = call i32 @f1157(i32 %x)
  %b = call i32 @f579(i32 %a)
  %r = xor i32 %b, 1158
  ret i32 %r
}
define internal i32 @f1159(i32 %x) {
  %a = call i32 @f1158(i32 %x)
  %b = call i32 @f579(i32 %a)
  %r = xor i32 %b, 1159
  ret i32 %r
}
define internal i32 @f1160(i32 %x) {
  %a = call i32 @f1159(i32 %x)
  %b = call i32 @f580(i32 %a)
  %r = xor i32 %b, 1160
  ret i32 %r
}
define internal i32 @f1161(i32 %x) {
  %a = call i32 @f1160(i32 %x)
  %b = call i32 @f580(i32 %a)
  %r = xor i32 %b, 1161
  ret i32 %r
}
define internal i32 @f1162(i32 %x) {
  %a = call i32 @f1161(i32 %x)
  %b = call i32 @f581(i32 %a)
  %r = xor i32 %b, 1162
  ret i32 %r
}
define internal i32 @f1163(i32 %x) {
  %a = call i32 @f1162(i32 %x)
  %b = call i32 @f581(i32 %a)
  %r = xor i32 %b, 1163
  ret i32 %r
}
define internal i32 @f1164(i32 %x) {
  %a = call i32 @f1163(i32 %x)
  %b = call i32 @f582(i32 %a)
  %r = xor i32 %b, 1164
  ret i32 %r
}
define internal i32 @f1165(i32 %x) {
  %a = call i32 @f1164(i32 %x)
  %b = call i32 @f582(i32 %a)
  %r = xor i32 %b, 1165
  ret i32 %r
}
define internal i32 @f1166(i32 %x) {
  %a = call i32 @f1165(i32 %x)
  %b = call i32 @f583(i32 %a)
  %r = xor i32 %b, 1166
  ret i32 %r
}
define internal i32 @f1167(i32 %x) {
  %a = call i32 @f1166(i32 %x)
  %b = call i32 @f583(i32 %a)
  %r = xor i32 %b, 1167
  ret i32 %r
}
define internal i32 @f1168(i32 %x) {
  %a = call i32 @f1167(i32 %x)
  %b = call i32 @f584(i32 %a)
  %r = xor i32 %b, 1168
  ret i32 %r
}
define internal i32 @f1169(i32 %x) {
  %a = call i32 @f1168(i32 %x)
  %b = call i32 @f584(i32 %a)
  %r = xor i32 %b, 1169
  ret i32 %r
}
define internal i32 @f1170(i32 %x) {
  %a = call i32 @f1169(i32 %x)
  %b = call i32 @f585(i32 %a)
  %r = xor i32 %b, 1170
  ret i32 %r
}
define internal i32 @f1171(i32 %x) {
  %a = call i32 @f1170(i32 %x)
  %b = call i32 @f585(i32 %a)
  %r = xor i32 %b, 1171
  ret i32 %r
}
define internal i32 @f1172(i32 %x) {
  %a = call i32 @f1171(i32 %x)
  %b = call i32 @f586(i32 %a)
  %r = xor i32 %b, 1172
  ret i32 %r
}
define internal i32 @f1173(i32 %x) {
  %a = call i32 @f1172(i32 %x)
  %b = call i32 @f586(i32 %a)
  %r = xor i32 %b, 1173
  ret i32 %r
}
define internal i32 @f1174(i32 %x) {
  %a = call i32 @f1173(i32 %x)
  %b = call i32 @f587(i32 %a)
  %r = xor i32 %b, 1174
  ret i32 %r
}
define internal i32 @f1175(i32 %x) {
  %a = call i32 @f1174(i32 %x)
  %b = call i32 @f587(i32 %a)
  %r = xor i32 %b, 1175
  ret i32 %r
}
define internal i32 @f1176(i32 %x) {
  %a = call i32 @f1175(i32 %x)
  %b = call i32 @f588(i32 %a)
  %r = xor i32 %b, 1176
  ret i32 %r
}
define internal i32 @f1177(i32 %x) {
  %a = call i32 @f1176(i32 %x)
  %b = call i32 @f588(i32 %a)
  %r = xor i32 %b, 1177
  ret i32 %r
}
define internal i32 @f1178(i32 %x) {
  %a = call i32 @f1177(i32 %x)
  %b = call i32 @f589(i32 %a)
  %r = xor i32 %b, 1178
  ret i32 %r
}
define internal i32 @f1179(i32 %x) {
  %a = call i32 @f1178(i32 %x)
  %b = call i32 @f589(i32 %a)
  %r = xor i32 %b, 1179
  ret i32 %r
}
define internal i32 @f1180(i32 %x) {
  %a = call i32 @f1179(i32 %x)
  %b = call i32 @f590(i32 %a)
  %r = xor i32 %b, 1180
  ret i32 %r
}
define internal i32 @f1181(i32 %x) {
  %a = call i32 @f1180(i32 %x)
  %b = call i32 @f590(i32 %a)
  %r = xor i32 %b, 1181
  ret i32 %r
}
define internal i32 @f1182(i32 %x) {
  %a = call i32 @f1181(i32 %x)
  %b = call i32 @f591(i32 %a)
  %r = xor i32 %b, 1182
  ret i32 %r
}
define internal i32 @f1183(i32 %x) {
  %a = call i32 @f1182(i32 %x)
  %b = call i32 @f591(i32 %a)
  %r = xor i32 %b, 1183
  ret i32 %r
}
define internal i32 @f1184(i32 %x) {
  %a = call i32 @f1183(i32 %x)
  %b = call i32 @f592(i32 %a)
  %r = xor i32 %b, 1184
  ret i32 %r
}
define internal i32 @f1185(i32 %x) {
  %a = call i32 @f1184(i32 %x)
  %b = call i32 @f592(i32 %a)
  %r = xor i32 %b, 1185
  ret i32 %r
}
define internal i32 @f1186(i32 %x) {
  %a = call i32 @f1185(i32 %x)
  %b = call i32 @f593(i32 %a)
  %r = xor i32 %b, 1186
  ret i32 %r
}
define internal i32 @f1187(i32 %x) {
  %a = call i32 @f1186(i32 %x)
  %b = call i32 @f593(i32 %a)
  %r = xor i32 %b, 1187
  ret i32 %r
}
define internal i32 @f1188(i32 %x) {
  %a = call i32 @f1187(i32 %x)
  %b = call i32 @f594(i32 %a)
  %r = xor i32 %b, 1188
  ret i32 %r
}
define internal i32 @f1189(i32 %x) {
  %a = call i32 @f1188(i32 %x)
  %b = call i32 @f594(i32 %a)
  %r = xor i32 %b, 1189
  ret i32 %r
}
define internal i32 @f1190(i32 %x) {
  %a = call i32 @f1189(i32 %x)
  %b = call i32 @f595(i32 %a)
  %r = xor i32 %b, 1190
  ret i32 %r
}
define internal i32 @f1191(i32 %x) {
  %a = call i32 @f1190(i32 %x)
  %b = call i32 @f595(i32 %a)
  %r = xor i32 %b, 1191
  ret i32 %r
}
define internal i32 @f1192(i32 %x) {
  %a = call i32 @f1191(i32 %x)
  %b = call i32 @f596(i32 %a)
  %r = xor i32 %b, 1192
  ret i32 %r
}
define internal i32 @f1193(i32 %x) {
  %a = call i32 @f1192(i32 %x)
  %b = call i32 @f596(i32 %a)
  %r = xor i32 %b, 1193
  ret i32 %r
}
define internal i32 @f1194(i32 %x) {
  %a = call i32 @f1193(i32 %x)
  %b = call i32 @f597(i32 %a)
  %r = xor i32 %b, 1194
  ret i32 %r
}
define internal i32 @f1195(i32 %x) {
  %a = call i32 @f1194(i32 %x)
  %b = call i32 @f597(i32 %a)
  %r = xor i32 %b, 1195
  ret i32 %r
}
define internal i32 @f1196(i32 %x) {
  %a = call i32 @f1195(i32 %x)
  %b = call i32 @f598(i32 %a)
  %r = xor i32 %b, 1196
  ret i32 %r
}
define internal i32 @f1197(i32 %x) {
  %a = call i32 @f1196(i32 %x)
  %b = call i32 @f598(i32 %a)
  %r = xor i32 %b, 1197
  ret i32 %r
}
define internal i32 @f1198(i32 %x) {
  %a = call i32 @f1197(i32 %x)
  %b = call i32 @f599(i32 %a)
  %r = xor i32 %b, 1198
  ret i32 %r
}
define internal i32 @f1199(i32 %x) {
  %a = call i32 @f1198(i32 %x)
  %b = call i32 @f599(i32 %a)
  %r = xor i32 %b, 1199
  ret i32 %r
}
define internal i32 @f1200(i32 %x) {
  %a = call i32 @f1199(i32 %x)
  %b = call i32 @f600(i32 %a)
  %r = xor i32 %b, 1200
  ret i32 %r
}
define internal i32 @f1201(i32 %x) {
  %a = call i32 @f1200(i32 %x)
  %b = call i32 @f600(i32 %a)
  %r = xor i32 %b, 1201
  ret i32 %r
}
define internal i32 @f1202(i32 %x) {
  %a = call i32 @f1201(i32 %x)
  %b = call i32 @f601(i32 %a)
  %r = xor i32 %b, 1202
  ret i32 %r
}
define internal i32 @f1203(i32 %x) {
  %a = call i32 @f1202(i32 %x)
  %b = call i32 @f601(i32 %a)
  %r = xor i32 %b, 1203
  ret i32 %r
}
define internal i32 @f1204(i32 %x) {
  %a = call i32 @f1203(i32 %x)
  %b = call i32 @f602(i32 %a)
  %r = xor i32 %b, 1204
  ret i32 %r
}
define internal i32 @f1205(i32 %x) {
  %a = call i32 @f1204(i32 %x)
  %b = call i32 @f602(i32 %a)
  %r = xor i32 %b, 1205
  ret i32 %r
}
define internal i32 @f1206(i32 %x) {
  %a = call i32 @f1205(i32 %x)
  %b = call i32 @f603(i32 %a)
  %r = xor i32 %b, 1206
  ret i32 %r
}
define internal i32 @f1207(i32 %x) {
  %a = call i32 @f1206(i32 %x)
  %b = call i32 @f603(i32 %a)
  %r = xor i32 %b, 1207
  ret i32 %r
}
define internal i32 @f1208(i32 %x) {
  %a = call i32 @f1207(i32 %x)
  %b = call i32 @f604(i32 %a)
  %r = xor i32 %b, 1208
  ret i32 %r
}
define internal i32 @f1209(i32 %x) {
  %a = call i32 @f1208(i32 %x)
  %b = call i32 @f604(i32 %a)
  %r = xor i32 %b, 1209
  ret i32 %r
}
define internal i32 @f1210(i32 %x) {
  %a = call i32 @f1209(i32 %x)
  %b = call i32 @f605(i32 %a)
  %r = xor i32 %b, 1210
  ret i32 %r
}
define internal i32 @f1211(i32 %x) {
  %a = call i32 @f1210(i32 %x)
  %b = call i32 @f605(i32 %a)
  %r = xor i32 %b, 1211
  ret i32 %r
}
define internal i32 @f1212(i32 %x) {
  %a = call i32 @f1211(i32 %x)
  %b = call i32 @f606(i32 %a)
  %r = xor i32 %b, 1212
  ret i32 %r
}
define internal i32 @f1213(i32 %x) {
  %a = call i32 @f1212(i32 %x)
  %b = call i32 @f606(i32 %a)
  %r = xor i32 %b, 1213
  ret i32 %r
}
define internal i32 @f1214(i32 %x) {
  %a = call i32 @f1213(i32 %x)
  %b = call i32 @f607(i32 %a)
  %r = xor i32 %b, 1214
  ret i32 %r
}
define internal i32 @f1215(i32 %x) {
  %a = call i32 @f1214(i32 %x)
  %b = call i32 @f607(i32 %a)
  %r = xor i32 %b, 1215
  ret i32 %r
}
define internal i32 @f1216(i32 %x) {
  %a = call i32 @f1215(i32 %x)
  %b = call i32 @f608(i32 %a)
  %r = xor i32 %b, 1216
  ret i32 %r
}
define internal i32 @f1217(i32 %x) {
  %a = call i32 @f1216(i32 %x)
  %b = call i32 @f608(i32 %a)
  %r = xor i32 %b, 1217
  ret i32 %r
}
define internal i32 @f1218(i32 %x) {
  %a = call i32 @f1217(i32 %x)
  %b = call i32 @f609(i32 %a)
  %r = xor i32 %b, 1218
  ret i32 %r
}
define internal i32 @f1219(i32 %x) {
  %a = call i32 @f1218(i32 %x)
  %b = call i32 @f609(i32 %a)
  %r = xor i32 %b, 1219
  ret i32 %r
}
define internal i32 @f1220(i32 %x) {
  %a = call i32 @f1219(i32 %x)
  %b = call i32 @f610(i32 %a)
  %r = xor i32 %b, 1220
  ret i32 %r
}
define internal i32 @f1221(i32 %x) {
  %a = call i32 @f1220(i32 %x)
  %b = call i32 @f610(i32 %a)
  %r = xor i32 %b, 1221
  ret i32 %r
}
define internal i32 @f1222(i32 %x) {
  %a = call i32 @f1221(i32 %x)
  %b = call i32 @f611(i32 %a)
  %r = xor i32 %b, 1222
  ret i32 %r
}
define internal i32 @f1223(i32 %x) {
  %a = call i32 @f1222(i32 %x)
  %b = call i32 @f611(i32 %a)
  %r = xor i32 %b, 1223
  ret i32 %r
}
define internal i32 @f1224(i32 %x) {
  %a = call i32 @f1223(i32 %x)
  %b = call i32 @f612(i32 %a)
  %r = xor i32 %b, 1224
  ret i32 %r
}
define internal i32 @f1225(i32 %x) {
  %a = call i32 @f1224(i32 %x)
  %b = call i32 @f612(i32 %a)
  %r = xor i32 %b, 1225
  ret i32 %r
}
define internal i32 @f1226(i32 %x) {
  %a = call i32 @f1225(i32 %x)
  %b = call i32 @f613(i32 %a)
  %r = xor i32 %b, 1226
  ret i32 %r
}
define internal i32 @f1227(i32 %x) {
  %a = call i32 @f1226(i32 %x)
  %b = call i32 @f613(i32 %a)
  %r = xor i32 %b, 1227
  ret i32 %r
}
define internal i32 @f1228(i32 %x) {
  %a = call i32 @f1227(i32 %x)
  %b = call i32 @f614(i32 %a)
  %r = xor i32 %b, 1228
  ret i32 %r
}
define internal i32 @f1229(i32 %x) {
  %a = call i32 @f1228(i32 %x)
  %b = call i32 @f614(i32 %a)
  %r = xor i32 %b, 1229
  ret i32 %r
}
define internal i32 @f1230(i32 %x) {
  %a = call i32 @f1229(i32 %x)
  %b = call i32 @f615(i32 %a)
  %r = xor i32 %b, 1230
  ret i32 %r
}
define internal i32 @f1231(i32 %x) {
  %a = call i32 @f1230(i32 %x)
  %b = call i32 @f615(i32 %a)
  %r = xor i32 %b, 1231
  ret i32 %r
}
define internal i32 @f1232(i32 %x) {
  %a = call i32 @f1231(i32 %x)
  %b = call i32 @f616(i32 %a)
  %r = xor i32 %b, 1232
  ret i32 %r
}
define internal i32 @f1233(i32 %x) {
  %a = call i32 @f1232(i32 %x)
  %b = call i32 @f616(i32 %a)
  %r = xor i32 %b, 1233
  ret i32 %r
}
define internal i32 @f1234(i32 %x) {
  %a = call i32 @f1233(i32 %x)
  %b = call i32 @f617(i32 %a)
  %r = xor i32 %b, 1234
  ret i32 %r
}
define internal i32 @f1235(i32 %x) {
  %a = call i32 @f1234(i32 %x)
  %b = call i32 @f617(i32 %a)
  %r = xor i32 %b, 1235
  ret i32 %r
}
define internal i32 @f1236(i32 %x) {
  %a = call i32 @f1235(i32 %x)
  %b = call i32 @f618(i32 %a)
  %r = xor i32 %b, 1236
  ret i32 %r
}
define internal i32 @f1237(i32 %x) {
  %a = call i32 @f1236(i32 %x)
  %b = call i32 @f618(i32 %a)
  %r = xor i32 %b, 1237
  ret i32 %r
}
define internal i32 @f1238(i32 %x) {
  %a = call i32 @f1237(i32 %x)
  %b = call i32 @f619(i32 %a)
  %r = xor i32 %b, 1238
  ret i32 %r
}
define internal i32 @f1239(i32 %x) {
  %a = call i32 @f1238(i32 %x)
  %b = call i32 @f619(i32 %a)
  %r = xor i32 %b, 1239
  ret i32 %r
}
define internal i32 @f1240(i32 %x) {
  %a = call i32 @f1239(i32 %x)
  %b = call i32 @f620(i32 %a)
  %r = xor i32 %b, 1240
  ret i32 %r
}
define internal i32 @f1241(i32 %x) {
  %a = call i32 @f1240(i32 %x)
  %b = call i32 @f620(i32 %a)
  %r = xor i32 %b, 1241
  ret i32 %r
}
define internal i32 @f1242(i32 %x) {
  %a = call i32 @f1241(i32 %x)
  %b = call i32 @f621(i32 %a)
  %r = xor i32 %b, 1242
  ret i32 %r
}
define internal i32 @f1243(i32 %x) {
  %a = call i32 @f1242(i32 %x)
  %b = call i32 @f621(i32 %a)
  %r = xor i32 %b, 1243
  ret i32 %r
}
define internal i32 @f1244(i32 %x) {
  %a = call i32 @f1243(i32 %x)
  %b = call i32 @f622(i32 %a)
  %r = xor i32 %b, 1244
  ret i32 %r
}
define internal i32 @f1245(i32 %x) {
  %a = call i32 @f1244(i32 %x)
  %b = call i32 @f622(i32 %a)
  %r = xor i32 %b, 1245
  ret i32 %r
}
define internal i32 @f1246(i32 %x) {
  %a = call i32 @f1245(i32 %x)
  %b = call i32 @f623(i32 %a)
  %r = xor i32 %b, 1246
  ret i32 %r
}
define internal i32 @f1247(i32 %x) {
  %a = call i32 @f1246(i32 %x)
  %b = call i32 @f623(i32 %a)
  %r = xor i32 %b, 1247
  ret i32 %r
}
define internal i32 @f1248(i32 %x) {
  %a = call i32 @f1247(i32 %x)
  %b = call i32 @f624(i32 %a)
  %r = xor i32 %b, 1248
  ret i32 %r
}
define internal i32 @f1249(i32 %x) {
  %a = call i32 @f1248(i32 %x)
  %b = call i32 @f624(i32 %a)
  %r = xor i32 %b, 1249
  ret i32 %r
}
define internal i32 @f1250(i32 %x) {
  %a = call i32 @f1249(i32 %x)
  %b = call i32 @f625(i32 %a)
  %r = xor i32 %b, 1250
  ret i32 %r
}
define internal i32 @f1251(i32 %x) {
  %a = call i32 @f1250(i32 %x)
  %b = call i32 @f625(i32 %a)
  %r = xor i32 %b, 1251
  ret i32 %r
}
define internal i32 @f1252(i32 %x) {
  %a = call i32 @f1251(i32 %x)
  %b = call i32 @f626(i32 %a)
  %r = xor i32 %b, 1252
  ret i32 %r
}
define internal i32 @f1253(i32 %x) {
  %a = call i32 @f1252(i32 %x)
  %b = call i32 @f626(i32 %a)
  %r = xor i32 %b, 1253
  ret i32 %r
}
define internal i32 @f1254(i32 %x) {
  %a = call i32 @f1253(i32 %x)
  %b = call i32 @f627(i32 %a)
  %r = xor i32 %b, 1254
  ret i32 %r
}
define internal i32 @f1255(i32 %x) {
  %a = call i32 @f1254(i32 %x)
  %b = call i32 @f627(i32 %a)
  %r = xor i32 %b, 1255
  ret i32 %r
}
define internal i32 @f1256(i32 %x) {
  %a = call i32 @f1255(i32 %x)
  %b = call i32 @f628(i32 %a)
  %r = xor i32 %b, 1256
  ret i32 %r
}
define internal i32 @f1257(i32 %x) {
  %a = call i32 @f1256(i32 %x)
  %b = call i32 @f628(i32 %a)
  %r = xor i32 %b, 1257
  ret i32 %r
}
define internal i32 @f1258(i32 %x) {
  %a = call i32 @f1257(i32 %x)
  %b = call i32 @f629(i32 %a)
  %r = xor i32 %b, 1258
  ret i32 %r
}
define internal i32 @f1259(i32 %x) {
  %a = call i32 @f1258(i32 %x)
  %b = call i32 @f629(i32 %a)
  %r = xor i32 %b, 1259
  ret i32 %r
}
define internal i32 @f1260(i32 %x) {
  %a = call i32 @f1259(i32 %x)
  %b = call i32 @f630(i32 %a)
  %r = xor i32 %b, 1260
  ret i32 %r
}
define internal i32 @f1261(i32 %x) {
  %a = call i32 @f1260(i32 %x)
  %b = call i32 @f630(i32 %a)
  %r = xor i32 %b, 1261
  ret i32 %r
}
define internal i32 @f1262(i32 %x) {
  %a = call i32 @f1261(i32 %x)
  %b = call i32 @f631(i32 %a)
  %r = xor i32 %b, 1262
  ret i32 %r
}
define internal i32 @f1263(i32 %x) {
  %a = call i32 @f1262(i32 %x)
  %b = call i32 @f631(i32 %a)
  %r = xor i32 %b, 1263
  ret i32 %r
}
define internal i32 @f1264(i32 %x) {
  %a = call i32 @f1263(i32 %x)
  %b = call i32 @f632(i32 %a)
  %r = xor i32 %b, 1264
  ret i32 %r
}
define internal i32 @f1265(i32 %x) {
  %a = call i32 @f1264(i32 %x)
  %b = call i32 @f632(i32 %a)
  %r = xor i32 %b, 1265
  ret i32 %r
}
define internal i32 @f1266(i32 %x) {
  %a = call i32 @f1265(i32 %x)
  %b = call i32 @f633(i32 %a)
  %r = xor i32 %b, 1266
  ret i32 %r
}
define internal i32 @f1267(i32 %x) {
  %a = call i32 @f1266(i32 %x)
  %b = call i32 @f633(i32 %a)
  %r = xor i32 %b, 1267
  ret i32 %r
}
define internal i32 @f1268(i32 %x) {
  %a = call i32 @f1267(i32 %x)
  %b = call i32 @f634(i32 %a)
  %r = xor i32 %b, 1268
  ret i32 %r
}
define internal i32 @f1269(i32 %x) {
  %a = call i32 @f1268(i32 %x)
  %b = call i32 @f634(i32 %a)
  %r = xor i32 %b, 1269
  ret i32 %r
}
define internal i32 @f1270(i32 %x) {
  %a = call i32 @f1269(i32 %x)
  %b = call i32 @f635(i32 %a)
  %r = xor i32 %b, 1270
  ret i32 %r
}
define internal i32 @f1271(i32 %x) {
  %a = call i32 @f1270(i32 %x)
  %b = call i32 @f635(i32 %a)
  %r = xor i32 %b, 1271
  ret i32 %r
}
define internal i32 @f1272(i32 %x) {
  %a = call i32 @f1271(i32 %x)
  %b = call i32 @f636(i32 %a)
  %r = xor i32 %b, 1272
  ret i32 %r
}
define internal i32 @f1273(i32 %x) {
  %a = call i32 @f1272(i32 %x)
  %b = call i32 @f636(i32 %a)
  %r = xor i32 %b, 1273
  ret i32 %r
}
define internal i32 @f1274(i32 %x) {
  %a = call i32 @f1273(i32 %x)
  %b = call i32 @f637(i32 %a)
  %r = xor i32 %b, 1274
  ret i32 %r
}
define internal i32 @f1275(i32 %x) {
  %a = call i32 @f1274(i32 %x)
  %b = call i32 @f637(i32 %a)
  %r = xor i32 %b, 1275
  ret i32 %r
}
define internal i32 @f1276(i32 %x) {
  %a = call i32 @f1275(i32 %x)
  %b = call i32 @f638(i32 %a)
  %r = xor i32 %b, 1276
  ret i32 %r
}
define internal i32 @f1277(i32 %x) {
  %a = call i32 @f1276(i32 %x)
  %b = call i32 @f638(i32 %a)
  %r = xor i32 %b, 1277
  ret i32 %r
}
define internal i32 @f1278(i32 %x) {
  %a = call i32 @f1277(i32 %x)
  %b = call i32 @f639(i32 %a)
  %r = xor i32 %b, 1278
  ret i32 %r
}
define internal i32 @f1279(i32 %x) {
  %a = call i32 @f1278(i32 %x)
  %b = call i32 @f639(i32 %a)
  %r = xor i32 %b, 1279
  ret i32 %r
}
define internal i32 @f1280(i32 %x) {
  %a = call i32 @f1279(i32 %x)
  %b = call i32 @f640(i32 %a)
  %r = xor i32 %b, 1280
  ret i32 %r
}
define internal i32 @f1281(i32 %x) {
  %a = call i32 @f1280(i32 %x)
  %b = call i32 @f640(i32 %a)
  %r = xor i32 %b, 1281
  ret i32 %r
}
define internal i32 @f1282(i32 %x) {
  %a = call i32 @f1281(i32 %x)
  %b = call i32 @f641(i32 %a)
  %r = xor i32 %b, 1282
  ret i32 %r
}
define internal i32 @f1283(i32 %x) {
  %a = call i32 @f1282(i32 %x)
  %b = call i32 @f641(i32 %a)
  %r = xor i32 %b, 1283
  ret i32 %r
}
define internal i32 @f1284(i32 %x) {
  %a = call i32 @f1283(i32 %x)
  %b = call i32 @f642(i32 %a)
  %r = xor i32 %b, 1284
  ret i32 %r
}
define internal i32 @f1285(i32 %x) {
  %a = call i32 @f1284(i32 %x)
  %b = call i32 @f642(i32 %a)
  %r = xor i32 %b, 1285
  ret i32 %r
}
define internal i32 @f1286(i32 %x) {
  %a = call i32 @f1285(i32 %x)
  %b = call i32 @f643(i32 %a)
  %r = xor i32 %b, 1286
  ret i32 %r
}
define internal i32 @f1287(i32 %x) {
  %a = call i32 @f1286(i32 %x)
  %b = call i32 @f643(i32 %a)
  %r = xor i32 %b, 1287
  ret i32 %r
}
define internal i32 @f1288(i32 %x) {
  %a = call i32 @f1287(i32 %x)
  %b = call i32 @f644(i32 %a)
  %r = xor i32 %b, 1288
  ret i32 %r
}
define internal i32 @f1289(i32 %x) {
  %a = call i32 @f1288(i32 %x)
  %b = call i32 @f644(i32 %a)
  %r = xor i32 %b, 1289
  ret i32 %r
}
define internal i32 @f1290(i32 %x) {
  %a = call i32 @f1289(i32 %x)
  %b = call i32 @f645(i32 %a)
  %r = xor i32 %b, 1290
  ret i32 %r
}
define internal i32 @f1291(i32 %x) {
  %a = call i32 @f1290(i32 %x)
  %b = call i32 @f645(i32 %a)
  %r = xor i32 %b, 1291
  ret i32 %r
}
define internal i32 @f1292(i32 %x) {
  %a = call i32 @f1291(i32 %x)
  %b = call i32 @f646(i32 %a)
  %r = xor i32 %b, 1292
  ret i32 %r
}
define internal i32 @f1293(i32 %x) {
  %a = call i32 @f1292(i32 %x)
  %b = call i32 @f646(i32 %a)
  %r = xor i32 %b, 1293
  ret i32 %r
}
define internal i32 @f1294(i32 %x) {
  %a = call i32 @f1293(i32 %x)
  %b = call i32 @f647(i32 %a)
  %r = xor i32 %b, 1294
  ret i32 %r
}
define internal i32 @f1295(i32 %x) {
  %a = call i32 @f1294(i32 %x)
  %b = call i32 @f647(i32 %a)
  %r = xor i32 %b, 1295
  ret i32 %r
}
define internal i32 @f1296(i32 %x) {
  %a = call i32 @f1295(i32 %x)
  %b = call i32 @f648(i32 %a)
  %r = xor i32 %b, 1296
  ret i32 %r
}
define internal i32 @f1297(i32 %x) {
  %a = call i32 @f1296(i32 %x)
  %b = call i32 @f648(i32 %a)
  %r = xor i32 %b, 1297
  ret i32 %r
}
define internal i32 @f1298(i32 %x) {
  %a = call i32 @f1297(i32 %x)
  %b = call i32 @f649(i32 %a)
  %r = xor i32 %b, 1298
  ret i32 %r
}
define internal i32 @f1299(i32 %x) {
  %a = call i32 @f1298(i32 %x)
  %b = call i32 @f649(i32 %a)
  %r = xor i32 %b, 1299
  ret i32 %r
}
define internal i32 @f1300(i32 %x) {
  %a = call i32 @f1299(i32 %x)
  %b = call i32 @f650(i32 %a)
  %r = xor i32 %b, 1300
  ret i32 %r
}
define internal i32 @f1301(i32 %x) {
  %a = call i32 @f1300(i32 %x)
  %b = call i32 @f650(i32 %a)
  %r = xor i32 %b, 1301
  ret i32 %r
}
define internal i32 @f1302(i32 %x) {
  %a = call i32 @f1301(i32 %x)
  %b = call i32 @f651(i32 %a)
  %r = xor i32 %b, 1302
  ret i32 %r
}
define internal i32 @f1303(i32 %x) {
  %a = call i32 @f1302(i32 %x)
  %b = call i32 @f651(i32 %a)
  %r = xor i32 %b, 1303
  ret i32 %r
}
define internal i32 @f1304(i32 %x) {
  %a = call i32 @f1303(i32 %x)
  %b = call i32 @f652(i32 %a)
  %r = xor i32 %b, 1304
  ret i32 %r
}
define internal i32 @f1305(i32 %x) {
  %a = call i32 @f1304(i32 %x)
  %b = call i32 @f652(i32 %a)
  %r = xor i32 %b, 1305
  ret i32 %r
}
define internal i32 @f1306(i32 %x) {
  %a = call i32 @f1305(i32 %x)
  %b = call i32 @f653(i32 %a)
  %r = xor i32 %b, 1306
  ret i32 %r
}
define internal i32 @f1307(i32 %x) {
  %a = call i32 @f1306(i32 %x)
  %b = call i32 @f653(i32 %a)
  %r = xor i32 %b, 1307
  ret i32 %r
}
define internal i32 @f1308(i32 %x) {
  %a = call i32 @f1307(i32 %x)
  %b = call i32 @f654(i32 %a)
  %r = xor i32 %b, 1308
  ret i32 %r
}
define internal i32 @f1309(i32 %x) {
  %a = call i32 @f1308(i32 %x)
  %b = call i32 @f654(i32 %a)
  %r = xor i32 %b, 1309
  ret i32 %r
}
define internal i32 @f1310(i32 %x) {
  %a = call i32 @f1309(i32 %x)
  %b = call i32 @f655(i32 %a)
  %r = xor i32 %b, 1310
  ret i32 %r
}
define internal i32 @f1311(i32 %x) {
  %a = call i32 @f1310(i32 %x)
  %b = call i32 @f655(i32 %a)
  %r = xor i32 %b, 1311
  ret i32 %r
}
define internal i32 @f1312(i32 %x) {
  %a = call i32 @f1311(i32 %x)
  %b = call i32 @f656(i32 %a)
  %r = xor i32 %b, 1312
  ret i32 %r
}
define internal i32 @f1313(i32 %x) {
  %a = call i32 @f1312(i32 %x)
  %b = call i32 @f656(i32 %a)
  %r = xor i32 %b, 1313
  ret i32 %r
}
define internal i32 @f1314(i32 %x) {
  %a = call i32 @f1313(i32 %x)
  %b = call i32 @f657(i32 %a)
  %r = xor i32 %b, 1314
  ret i32 %r
}
define internal i32 @f1315(i32 %x) {
  %a = call i32 @f1314(i32 %x)
  %b = call i32 @f657(i32 %a)
  %r = xor i32 %b, 1315
  ret i32 %r
}
define internal i32 @f1316(i32 %x) {
  %a = call i32 @f1315(i32 %x)
  %b = call i32 @f658(i32 %a)
  %r = xor i32 %b, 1316
  ret i32 %r
}
define internal i32 @f1317(i32 %x) {
  %a = call i32 @f1316(i32 %x)
  %b = call i32 @f658(i32 %a)
  %r = xor i32 %b, 1317
  ret i32 %r
}
define internal i32 @f1318(i32 %x) {
  %a = call i32 @f1317(i32 %x)
  %b = call i32 @f659(i32 %a)
  %r = xor i32 %b, 1318
  ret i32 %r
}
define internal i32 @f1319(i32 %x) {
  %a = call i32 @f1318(i32 %x)
  %b = call i32 @f659(i32 %a)
  %r = xor i32 %b, 1319
  ret i32 %r
}
define internal i32 @f1320(i32 %x) {
  %a = call i32 @f1319(i32 %x)
  %b = call i32 @f660(i32 %a)
  %r = xor i32 %b, 1320
  ret i32 %r
}
define internal i32 @f1321(i32 %x) {
  %a = call i32 @f1320(i32 %x)
  %b = call i32 @f660(i32 %a)
  %r = xor i32 %b, 1321
  ret i32 %r
}
define internal i32 @f1322(i32 %x) {
  %a = call i32 @f1321(i32 %x)
  %b = call i32 @f661(i32 %a)
  %r = xor i32 %b, 1322
  ret i32 %r
}
define internal i32 @f1323(i32 %x) {
  %a = call i32 @f1322(i32 %x)
  %b = call i32 @f661(i32 %a)
  %r = xor i32 %b, 1323
  ret i32 %r
}
define internal i32 @f1324(i32 %x) {
  %a = call i32 @f1323(i32 %x)
  %b = call i32 @f662(i32 %a)
  %r = xor i32 %b, 1324
  ret i32 %r
}
define internal i32 @f1325(i32 %x) {
  %a = call i32 @f1324(i32 %x)
  %b = call i32 @f662(i32 %a)
  %r = xor i32 %b, 1325
  ret i32 %r
}
define internal i32 @f1326(i32 %x) {
  %a = call i32 @f1325(i32 %x)
  %b = call i32 @f663(i32 %a)
  %r = xor i32 %b, 1326
  ret i32 %r
}
define internal i32 @f1327(i32 %x) {
  %a = call i32 @f1326(i32 %x)
  %b = call i32 @f663(i32 %a)
  %r = xor i32 %b, 1327
  ret i32 %r
}
define internal i32 @f1328(i32 %x) {
  %a = call i32 @f1327(i32 %x)
  %b = call i32 @f664(i32 %a)
  %r = xor i32 %b, 1328
  ret i32 %r
}
define internal i32 @f1329(i32 %x) {
  %a = call i32 @f1328(i32 %x)
  %b = call i32 @f664(i32 %a)
  %r = xor i32 %b, 1329
  ret i32 %r
}
define internal i32 @f1330(i32 %x) {
  %a = call i32 @f1329(i32 %x)
  %b = call i32 @f665(i32 %a)
  %r = xor i32 %b, 1330
  ret i32 %r
}
define internal i32 @f1331(i32 %x) {
  %a = call i32 @f1330(i32 %x)
  %b = call i32 @f665(i32 %a)
  %r = xor i32 %b, 1331
  ret i32 %r
}
define internal i32 @f1332(i32 %x) {
  %a = call i32 @f1331(i32 %x)
  %b = call i32 @f666(i32 %a)
  %r = xor i32 %b, 1332
  ret i32 %r
}
define internal i32 @f1333(i32 %x) {
  %a = call i32 @f1332(i32 %x)
  %b = call i32 @f666(i32 %a)
  %r = xor i32 %b, 1333
  ret i32 %r
}
define internal i32 @f1334(i32 %x) {
  %a = call i32 @f1333(i32 %x)
  %b = call i32 @f667(i32 %a)
  %r = xor i32 %b, 1334
  ret i32 %r
}
define internal i32 @f1335(i32 %x) {
  %a = call i32 @f1334(i32 %x)
  %b = call i32 @f667(i32 %a)
  %r = xor i32 %b, 1335
  ret i32 %r
}
define internal i32 @f1336(i32 %x) {
  %a = call i32 @f1335(i32 %x)
  %b = call i32 @f668(i32 %a)
  %r = xor i32 %b, 1336
  ret i32 %r
}
define internal i32 @f1337(i32 %x) {
  %a = call i32 @f1336(i32 %x)
  %b = call i32 @f668(i32 %a)
  %r = xor i32 %b, 1337
  ret i32 %r
}
define internal i32 @f1338(i32 %x) {
  %a = call i32 @f1337(i32 %x)
  %b = call i32 @f669(i32 %a)
  %r = xor i32 %b, 1338
  ret i32 %r
}
define internal i32 @f1339(i32 %x) {
  %a = call i32 @f1338(i32 %x)
  %b = call i32 @f669(i32 %a)
  %r = xor i32 %b, 1339
  ret i32 %r
}
define internal i32 @f1340(i32 %x) {
  %a = call i32 @f1339(i32 %x)
  %b = call i32 @f670(i32 %a)
  %r = xor i32 %b, 1340
  ret i32 %r
}
define internal i32 @f1341(i32 %x) {
  %a = call i32 @f1340(i32 %x)
  %b = call i32 @f670(i32 %a)
  %r = xor i32 %b, 1341
  ret i32 %r
}
define internal i32 @f1342(i32 %x) {
  %a = call i32 @f1341(i32 %x)
  %b = call i32 @f671(i32 %a)
  %r = xor i32 %b, 1342
  ret i32 %r
}
define internal i32 @f1343(i32 %x) {
  %a = call i32 @f1342(i32 %x)
  %b = call i32 @f671(i32 %a)
  %r = xor i32 %b, 1343
  ret i32 %r
}
define internal i32 @f1344(i32 %x) {
  %a = call i32 @f1343(i32 %x)
  %b = call i32 @f672(i32 %a)
  %r = xor i32 %b, 1344
  ret i32 %r
}
define internal i32 @f1345(i32 %x) {
  %a = call i32 @f1344(i32 %x)
  %b = call i32 @f672(i32 %a)
  %r = xor i32 %b, 1345
  ret i32 %r
}
define internal i32 @f1346(i32 %x) {
  %a = call i32 @f1345(i32 %x)
  %b = call i32 @f673(i32 %a)
  %r = xor i32 %b, 1346
  ret i32 %r
}
define internal i32 @f1347(i32 %x) {
  %a = call i32 @f1346(i32 %x)
  %b = call i32 @f673(i32 %a)
  %r = xor i32 %b, 1347
  ret i32 %r
}
define internal i32 @f1348(i32 %x) {
  %a = call i32 @f1347(i32 %x)
  %b = call i32 @f674(i32 %a)
  %r = xor i32 %b, 1348
  ret i32 %r
}
define internal i32 @f1349(i32 %x) {
  %a = call i32 @f1348(i32 %x)
  %b = call i32 @f674(i32 %a)
  %r = xor i32 %b, 1349
  ret i32 %r
}
define internal i32 @f1350(i32 %x) {
  %a = call i32 @f1349(i32 %x)
  %b = call i32 @f675(i32 %a)
  %r = xor i32 %b, 1350
  ret i32 %r
}
define internal i32 @f1351(i32 %x) {
  %a = call i32 @f1350(i32 %x)
  %b = call i32 @f675(i32 %a)
  %r = xor i32 %b, 1351
  ret i32 %r
}
define internal i32 @f1352(i32 %x) {
  %a = call i32 @f1351(i32 %x)
  %b = call i32 @f676(i32 %a)
  %r = xor i32 %b, 1352
  ret i32 %r
}
define internal i32 @f1353(i32 %x) {
  %a = call i32 @f1352(i32 %x)
  %b = call i32 @f676(i32 %a)
  %r = xor i32 %b, 1353
  ret i32 %r
}
define internal i32 @f1354(i32 %x) {
  %a = call i32 @f1353(i32 %x)
  %b = call i32 @f677(i32 %a)
  %r = xor i32 %b, 1354
  ret i32 %r
}
define internal i32 @f1355(i32 %x) {
  %a = call i32 @f1354(i32 %x)
  %b = call i32 @f677(i32 %a)
  %r = xor i32 %b, 1355
  ret i32 %r
}
define internal i32 @f1356(i32 %x) {
  %a = call i32 @f1355(i32 %x)
  %b = call i32 @f678(i32 %a)
  %r = xor i32 %b, 1356
  ret i32 %r
}
define internal i32 @f1357(i32 %x) {
  %a = call i32 @f1356(i32 %x)
  %b = call i32 @f678(i32 %a)
  %r = xor i32 %b, 1357
  ret i32 %r
}
define internal i32 @f1358(i32 %x) {
  %a = call i32 @f1357(i32 %x)
  %b = call i32 @f679(i32 %a)
  %r = xor i32 %b, 1358
  ret i32 %r
}
define internal i32 @f1359(i32 %x) {
  %a = call i32 @f1358(i32 %x)
  %b = call i32 @f679(i32 %a)
  %r = xor i32 %b, 1359
  ret i32 %r
}
define internal i32 @f1360(i32 %x) {
  %a = call i32 @f1359(i32 %x)
  %b = call i32 @f680(i32 %a)
  %r = xor i32 %b, 1360
  ret i32 %r
}
define internal i32 @f1361(i32 %x) {
  %a = call i32 @f1360(i32 %x)
  %b = call i32 @f680(i32 %a)
  %r = xor i32 %b, 1361
  ret i32 %r
}
define internal i32 @f1362(i32 %x) {
  %a = call i32 @f1361(i32 %x)
  %b = call i32 @f681(i32 %a)
  %r = xor i32 %b, 1362
  ret i32 %r
}
define internal i32 @f1363(i32 %x) {
  %a = call i32 @f1362(i32 %x)
  %b = call i32 @f681(i32 %a)
  %r = xor i32 %b, 1363
  ret i32 %r
}
define internal i32 @f1364(i32 %x) {
  %a = call i32 @f1363(i32 %x)
  %b = call i32 @f682(i32 %a)
  %r = xor i32 %b, 1364
  ret i32 %r
}
define internal i32 @f1365(i32 %x) {
  %a = call i32 @f1364(i32 %x)
  %b = call i32 @f682(i32 %a)
  %r = xor i32 %b, 1365
  ret i32 %r
}
define internal i32 @f1366(i32 %x) {
  %a = call i32 @f1365(i32 %x)
  %b = call i32 @f683(i32 %a)
  %r = xor i32 %b, 1366
  ret i32 %r
}
define internal i32 @f1367(i32 %x) {
  %a = call i32 @f1366(i32 %x)
  %b = call i32 @f683(i32 %a)
  %r = xor i32 %b, 1367
  ret i32 %r
}
define internal i32 @f1368(i32 %x) {
  %a = call i32 @f1367(i32 %x)
  %b = call i32 @f684(i32 %a)
  %r = xor i32 %b, 1368
  ret i32 %r
}
define internal i32 @f1369(i32 %x) {
  %a = call i32 @f1368(i32 %x)
  %b = call i32 @f684(i32 %a)
  %r = xor i32 %b, 1369
  ret i32 %r
}
define internal i32 @f1370(i32 %x) {
  %a = call i32 @f1369(i32 %x)
  %b = call i32 @f685(i32 %a)
  %r = xor i32 %b, 1370
  ret i32 %r
}
define internal i32 @f1371(i32 %x) {
  %a = call i32 @f1370(i32 %x)
  %b = call i32 @f685(i32 %a)
  %r = xor i32 %b, 1371
  ret i32 %r
}
define internal i32 @f1372(i32 %x) {
  %a = call i32 @f1371(i32 %x)
  %b = call i32 @f686(i32 %a)
  %r = xor i32 %b, 1372
  ret i32 %r
}
define internal i32 @f1373(i32 %x) {
  %a = call i32 @f1372(i32 %x)
  %b = call i32 @f686(i32 %a)
  %r = xor i32 %b, 1373
  ret i32 %r
}
define internal i32 @f1374(i32 %x) {
  %a = call i32 @f1373(i32 %x)
  %b = call i32 @f687(i32 %a)
  %r = xor i32 %b, 1374
  ret i32 %r
}
define internal i32 @f1375(i32 %x) {
  %a = call i32 @f1374(i32 %x)
  %b = call i32 @f687(i32 %a)
  %r = xor i32 %b, 1375
  ret i32 %r
}
define internal i32 @f1376(i32 %x) {
  %a = call i32 @f1375(i32 %x)
  %b = call i32 @f688(i32 %a)
  %r = xor i32 %b, 1376
  ret i32 %r
}
define internal i32 @f1377(i32 %x) {
  %a = call i32 @f1376(i32 %x)
  %b = call i32 @f688(i32 %a)
  %r = xor i32 %b, 1377
  ret i32 %r
}
define internal i32 @f1378(i32 %x) {
  %a = call i32 @f1377(i32 %x)
  %b = call i32 @f689(i32 %a)
  %r = xor i32 %b, 1378
  ret i32 %r
}
define internal i32 @f1379(i32 %x) {
  %a = call i32 @f1378(i32 %x)
  %b = call i32 @f689(i32 %a)
  %r = xor i32 %b, 1379
  ret i32 %r
}
define internal i32 @f1380(i32 %x) {
  %a = call i32 @f1379(i32 %x)
  %b = call i32 @f690(i32 %a)
  %r = xor i32 %b, 1380
  ret i32 %r
}
define internal i32 @f1381(i32 %x) {
  %a = call i32 @f1380(i32 %x)
  %b = call i32 @f690(i32 %a)
  %r = xor i32 %b, 1381
  ret i32 %r
}
define internal i32 @f1382(i32 %x) {
  %a = call i32 @f1381(i32 %x)
  %b = call i32 @f691(i32 %a)
  %r = xor i32 %b, 1382
  ret i32 %r
}
define internal i32 @f1383(i32 %x) {
  %a = call i32 @f1382(i32 %x)
  %b = call i32 @f691(i32 %a)
  %r = xor i32 %b, 1383
  ret i32 %r
}
define internal i32 @f1384(i32 %x) {
  %a = call i32 @f1383(i32 %x)
  %b = call i32 @f692(i32 %a)
  %r = xor i32 %b, 1384
  ret i32 %r
}
define internal i32 @f1385(i32 %x) {
  %a = call i32 @f1384(i32 %x)
  %b = call i32 @f692(i32 %a)
  %r = xor i32 %b, 1385
  ret i32 %r
}
define internal i32 @f1386(i32 %x) {
  %a = call i32 @f1385(i32 %x)
  %b = call i32 @f693(i32 %a)
  %r = xor i32 %b, 1386
  ret i32 %r
}
define internal i32 @f1387(i32 %x) {
  %a = call i32 @f1386(i32 %x)
  %b = call i32 @f693(i32 %a)
  %r = xor i32 %b, 1387
  ret i32 %r
}
define internal i32 @f1388(i32 %x) {
  %a = call i32 @f1387(i32 %x)
  %b = call i32 @f694(i32 %a)
  %r = xor i32 %b, 1388
  ret i32 %r
}
define internal i32 @f1389(i32 %x) {
  %a = call i32 @f1388(i32 %x)
  %b = call i32 @f694(i32 %a)
  %r = xor i32 %b, 1389
  ret i32 %r
}
define internal i32 @f1390(i32 %x) {
  %a = call i32 @f1389(i32 %x)
  %b = call i32 @f695(i32 %a)
  %r = xor i32 %b, 1390
  ret i32 %r
}
define internal i32 @f1391(i32 %x) {
  %a = call i32 @f1390(i32 %x)
  %b = call i32 @f695(i32 %a)
  %r = xor i32 %b, 1391
  ret i32 %r
}
define internal i32 @f1392(i32 %x) {
  %a = call i32 @f1391(i32 %x)
  %b = call i32 @f696(i32 %a)
  %r = xor i32 %b, 1392
  ret i32 %r
}
define internal i32 @f1393(i32 %x) {
  %a = call i32 @f1392(i32 %x)
  %b = call i32 @f696(i32 %a)
  %r = xor i32 %b, 1393
  ret i32 %r
}
define internal i32 @f1394(i32 %x) {
  %a = call i32 @f1393(i32 %x)
  %b = call i32 @f697(i32 %a)
  %r = xor i32 %b, 1394
  ret i32 %r
}
define internal i32 @f1395(i32 %x) {
  %a = call i32 @f1394(i32 %x)
  %b = call i32 @f697(i32 %a)
  %r = xor i32 %b, 1395
  ret i32 %r
}
define internal i32 @f1396(i32 %x) {
  %a = call i32 @f1395(i32 %x)
  %b = call i32 @f698(i32 %a)
  %r = xor i32 %b, 1396
  ret i32 %r
}
define internal i32 @f1397(i32 %x) {
  %a = call i32 @f1396(i32 %x)
  %b = call i32 @f698(i32 %a)
  %r = xor i32 %b, 1397
  ret i32 %r
}
define internal i32 @f1398(i32 %x) {
  %a = call i32 @f1397(i32 %x)
  %b = call i32 @f699(i32 %a)
  %r = xor i32 %b, 1398
  ret i32 %r
}
define internal i32 @f1399(i32 %x) {
  %a = call i32 @f1398(i32 %x)
  %b = call i32 @f699(i32 %a)
  %r = xor i32 %b, 1399
  ret i32 %r
}
define internal i32 @f1400(i32 %x) {
  %a = call i32 @f1399(i32 %x)
  %b = call i32 @f700(i32 %a)
  %r = xor i32 %b, 1400
  ret i32 %r
}
define internal i32 @f1401(i32 %x) {
  %a = call i32 @f1400(i32 %x)
  %b = call i32 @f700(i32 %a)
  %r = xor i32 %b, 1401
  ret i32 %r
}
define internal i32 @f1402(i32 %x) {
  %a = call i32 @f1401(i32 %x)
  %b = call i32 @f701(i32 %a)
  %r = xor i32 %b, 1402
  ret i32 %r
}
define internal i32 @f1403(i32 %x) {
  %a = call i32 @f1402(i32 %x)
  %b = call i32 @f701(i32 %a)
  %r = xor i32 %b, 1403
  ret i32 %r
}
define internal i32 @f1404(i32 %x) {
  %a = call i32 @f1403(i32 %x)
  %b = call i32 @f702(i32 %a)
  %r = xor i32 %b, 1404
  ret i32 %r
}
define internal i32 @f1405(i32 %x) {
  %a = call i32 @f1404(i32 %x)
  %b = call i32 @f702(i32 %a)
  %r = xor i32 %b, 1405
  ret i32 %r
}
define internal i32 @f1406(i32 %x) {
  %a = call i32 @f1405(i32 %x)
  %b = call i32 @f703(i32 %a)
  %r = xor i32 %b, 1406
  ret i32 %r
}
define internal i32 @f1407(i32 %x) {
  %a = call i32 @f1406(i32 %x)
  %b = call i32 @f703(i32 %a)
  %r = xor i32 %b, 1407
  ret i32 %r
}
define internal i32 @f1408(i32 %x) {
  %a = call i32 @f1407(i32 %x)
  %b = call i32 @f704(i32 %a)
  %r = xor i32 %b, 1408
  ret i32 %r
}
define internal i32 @f1409(i32 %x) {
  %a = call i32 @f1408(i32 %x)
  %b = call i32 @f704(i32 %a)
  %r = xor i32 %b, 1409
  ret i32 %r
}
define internal i32 @f1410(i32 %x) {
  %a = call i32 @f1409(i32 %x)
  %b = call i32 @f705(i32 %a)
  %r = xor i32 %b, 1410
  ret i32 %r
}
define internal i32 @f1411(i32 %x) {
  %a = call i32 @f1410(i32 %x)
  %b = call i32 @f705(i32 %a)
  %r = xor i32 %b, 1411
  ret i32 %r
}
define internal i32 @f1412(i32 %x) {
  %a = call i32 @f1411(i32 %x)
  %b = call i32 @f706(i32 %a)
  %r = xor i32 %b, 1412
  ret i32 %r
}
define internal i32 @f1413(i32 %x) {
  %a = call i32 @f1412(i32 %x)
  %b = call i32 @f706(i32 %a)
  %r = xor i32 %b, 1413
  ret i32 %r
}
define internal i32 @f1414(i32 %x) {
  %a = call i32 @f1413(i32 %x)
  %b = call i32 @f707(i32 %a)
  %r = xor i32 %b, 1414
  ret i32 %r
}
define internal i32 @f1415(i32 %x) {
  %a = call i32 @f1414(i32 %x)
  %b = call i32 @f707(i32 %a)
  %r = xor i32 %b, 1415
  ret i32 %r
}
define internal i32 @f1416(i32 %x) {
  %a = call i32 @f1415(i32 %x)
  %b = call i32 @f708(i32 %a)
  %r = xor i32 %b, 1416
  ret i32 %r
}
define internal i32 @f1417(i32 %x) {
  %a = call i32 @f1416(i32 %x)
  %b = call i32 @f708(i32 %a)
  %r = xor i32 %b, 1417
  ret i32 %r
}
define internal i32 @f1418(i32 %x) {
  %a = call i32 @f1417(i32 %x)
  %b = call i32 @f709(i32 %a)
  %r = xor i32 %b, 1418
  ret i32 %r
}
define internal i32 @f1419(i32 %x) {
  %a = call i32 @f1418(i32 %x)
  %b = call i32 @f709(i32 %a)
  %r = xor i32 %b, 1419
  ret i32 %r
}
define internal i32 @f1420(i32 %x) {
  %a = call i32 @f1419(i32 %x)
  %b = call i32 @f710(i32 %a)
  %r = xor i32 %b, 1420
  ret i32 %r
}
define internal i32 @f1421(i32 %x) {
  %a = call i32 @f1420(i32 %x)
  %b = call i32 @f710(i32 %a)
  %r = xor i32 %b, 1421
  ret i32 %r
}
define internal i32 @f1422(i32 %x) {
  %a = call i32 @f1421(i32 %x)
  %b = call i32 @f711(i32 %a)
  %r = xor i32 %b, 1422
  ret i32 %r
}
define internal i32 @f1423(i32 %x) {
  %a = call i32 @f1422(i32 %x)
  %b = call i32 @f711(i32 %a)
  %r = xor i32 %b, 1423
  ret i32 %r
}
define internal i32 @f1424(i32 %x) {
  %a = call i32 @f1423(i32 %x)
  %b = call i32 @f712(i32 %a)
  %r = xor i32 %b, 1424
  ret i32 %r
}
define internal i32 @f1425(i32 %x) {
  %a = call i32 @f1424(i32 %x)
  %b = call i32 @f712(i32 %a)
  %r = xor i32 %b, 1425
  ret i32 %r
}
define internal i32 @f1426(i32 %x) {
  %a = call i32 @f1425(i32 %x)
  %b = call i32 @f713(i32 %a)
  %r = xor i32 %b, 1426
  ret i32 %r
}
define internal i32 @f1427(i32 %x) {
  %a = call i32 @f1426(i32 %x)
  %b = call i32 @f713(i32 %a)
  %r = xor i32 %b, 1427
  ret i32 %r
}
define internal i32 @f1428(i32 %x) {
  %a = call i32 @f1427(i32 %x)
  %b = call i32 @f714(i32 %a)
  %r = xor i32 %b, 1428
  ret i32 %r
}
define internal i32 @f1429(i32 %x) {
  %a = call i32 @f1428(i32 %x)
  %b = call i32 @f714(i32 %a)
  %r = xor i32 %b, 1429
  ret i32 %r
}
define internal i32 @f1430(i32 %x) {
  %a = call i32 @f1429(i32 %x)
  %b = call i32 @f715(i32 %a)
  %r = xor i32 %b, 1430
  ret i32 %r
}
define internal i32 @f1431(i32 %x) {
  %a = call i32 @f1430(i32 %x)
  %b = call i32 @f715(i32 %a)
  %r = xor i32 %b, 1431
  ret i32 %r
}
define internal i32 @f1432(i32 %x) {
  %a = call i32 @f1431(i32 %x)
  %b = call i32 @f716(i32 %a)
  %r = xor i32 %b, 1432
  ret i32 %r
}
define internal i32 @f1433(i32 %x) {
  %a = call i32 @f1432(i32 %x)
  %b = call i32 @f716(i32 %a)
  %r = xor i32 %b, 1433
  ret i32 %r
}
define internal i32 @f1434(i32 %x) {
  %a = call i32 @f1433(i32 %x)
  %b = call i32 @f717(i32 %a)
  %r = xor i32 %b, 1434
  ret i32 %r
}
define internal i32 @f1435(i32 %x) {
  %a = call i32 @f1434(i32 %x)
  %b = call i32 @f717(i32 %a)
  %r = xor i32 %b, 1435
  ret i32 %r
}
define internal i32 @f1436(i32 %x) {
  %a = call i32 @f1435(i32 %x)
  %b = call i32 @f718(i32 %a)
  %r = xor i32 %b, 1436
  ret i32 %r
}
define internal i32 @f1437(i32 %x) {
  %a = call i32 @f1436(i32 %x)
  %b = call i32 @f718(i32 %a)
  %r = xor i32 %b, 1437
  ret i32 %r
}
define internal i32 @f1438(i32 %x) {
  %a = call i32 @f1437(i32 %x)
  %b = call i32 @f719(i32 %a)
  %r = xor i32 %b, 1438
  ret i32 %r
}
define internal i32 @f1439(i32 %x) {
  %a = call i32 @f1438(i32 %x)
  %b = call i32 @f719(i32 %a)
  %r = xor i32 %b, 1439
  ret i32 %r
}
define internal i32 @f1440(i32 %x) {
  %a = call i32 @f1439(i32 %x)
  %b = call i32 @f720(i32 %a)
  %r = xor i32 %b, 1440
  ret i32 %r
}
define internal i32 @f1441(i32 %x) {
  %a = call i32 @f1440(i32 %x)
  %b = call i32 @f720(i32 %a)
  %r = xor i32 %b, 1441
  ret i32 %r
}
define internal i32 @f1442(i32 %x) {
  %a = call i32 @f1441(i32 %x)
  %b = call i32 @f721(i32 %a)
  %r = xor i32 %b, 1442
  ret i32 %r
}
define internal i32 @f1443(i32 %x) {
  %a = call i32 @f1442(i32 %x)
  %b = call i32 @f721(i32 %a)
  %r = xor i32 %b, 1443
  ret i32 %r
}
define internal i32 @f1444(i32 %x) {
  %a = call i32 @f1443(i32 %x)
  %b = call i32 @f722(i32 %a)
  %r = xor i32 %b, 1444
  ret i32 %r
}
define internal i32 @f1445(i32 %x) {
  %a = call i32 @f1444(i32 %x)
  %b = call i32 @f722(i32 %a)
  %r = xor i32 %b, 1445
  ret i32 %r
}
define internal i32 @f1446(i32 %x) {
  %a = call i32 @f1445(i32 %x)
  %b = call i32 @f723(i32 %a)
  %r = xor i32 %b, 1446
  ret i32 %r
}
define internal i32 @f1447(i32 %x) {
  %a = call i32 @f1446(i32 %x)
  %b = call i32 @f723(i32 %a)
  %r = xor i32 %b, 1447
  ret i32 %r
}
define internal i32 @f1448(i32 %x) {
  %a = call i32 @f1447(i32 %x)
  %b = call i32 @f724(i32 %a)
  %r = xor i32 %b, 1448
  ret i32 %r
}
define internal i32 @f1449(i32 %x) {
  %a = call i32 @f1448(i32 %x)
  %b = call i32 @f724(i32 %a)
  %r = xor i32 %b, 1449
  ret i32 %r
}
define internal i32 @f1450(i32 %x) {
  %a = call i32 @f1449(i32 %x)
  %b = call i32 @f725(i32 %a)
  %r = xor i32 %b, 1450
  ret i32 %r
}
define internal i32 @f1451(i32 %x) {
  %a = call i32 @f1450(i32 %x)
  %b = call i32 @f725(i32 %a)
  %r = xor i32 %b, 1451
  ret i32 %r
}
define internal i32 @f1452(i32 %x) {
  %a = call i32 @f1451(i32 %x)
  %b = call i32 @f726(i32 %a)
  %r = xor i32 %b, 1452
  ret i32 %r
}
define internal i32 @f1453(i32 %x) {
  %a = call i32 @f1452(i32 %x)
  %b = call i32 @f726(i32 %a)
  %r = xor i32 %b, 1453
  ret i32 %r
}
define internal i32 @f1454(i32 %x) {
  %a = call i32 @f1453(i32 %x)
  %b = call i32 @f727(i32 %a)
  %r = xor i32 %b, 1454
  ret i32 %r
}
define internal i32 @f1455(i32 %x) {
  %a = call i32 @f1454(i32 %x)
  %b = call i32 @f727(i32 %a)
  %r = xor i32 %b, 1455
  ret i32 %r
}
define internal i32 @f1456(i32 %x) {
  %a = call i32 @f1455(i32 %x)
  %b = call i32 @f728(i32 %a)
  %r = xor i32 %b, 1456
  ret i32 %r
}
define internal i32 @f1457(i32 %x) {
  %a = call i32 @f1456(i32 %x)
  %b = call i32 @f728(i32 %a)
  %r = xor i32 %b, 1457
  ret i32 %r
}
define internal i32 @f1458(i32 %x) {
  %a = call i32 @f1457(i32 %x)
  %b = call i32 @f729(i32 %a)
  %r = xor i32 %b, 1458
  ret i32 %r
}
define internal i32 @f1459(i32 %x) {
  %a = call i32 @f1458(i32 %x)
  %b = call i32 @f729(i32 %a)
  %r = xor i32 %b, 1459
  ret i32 %r
}
define internal i32 @f1460(i32 %x) {
  %a = call i32 @f1459(i32 %x)
  %b = call i32 @f730(i32 %a)
  %r = xor i32 %b, 1460
  ret i32 %r
}
define internal i32 @f1461(i32 %x) {
  %a = call i32 @f1460(i32 %x)
  %b = call i32 @f730(i32 %a)
  %r = xor i32 %b, 1461
  ret i32 %r
}
define internal i32 @f1462(i32 %x) {
  %a = call i32 @f1461(i32 %x)
  %b = call i32 @f731(i32 %a)
  %r = xor i32 %b, 1462
  ret i32 %r
}
define internal i32 @f1463(i32 %x) {
  %a = call i32 @f1462(i32 %x)
  %b = call i32 @f731(i32 %a)
  %r = xor i32 %b, 1463
  ret i32 %r
}
define internal i32 @f1464(i32 %x) {
  %a = call i32 @f1463(i32 %x)
  %b = call i32 @f732(i32 %a)
  %r = xor i32 %b, 1464
  ret i32 %r
}
define internal i32 @f1465(i32 %x) {
  %a = call i32 @f1464(i32 %x)
  %b = call i32 @f732(i32 %a)
  %r = xor i32 %b, 1465
  ret i32 %r
}
define internal i32 @f1466(i32 %x) {
  %a = call i32 @f1465(i32 %x)
  %b = call i32 @f733(i32 %a)
  %r = xor i32 %b, 1466
  ret i32 %r
}
define internal i32 @f1467(i32 %x) {
  %a = call i32 @f1466(i32 %x)
  %b = call i32 @f733(i32 %a)
  %r = xor i32 %b, 1467
  ret i32 %r
}
define internal i32 @f1468(i32 %x) {
  %a = call i32 @f1467(i32 %x)
  %b = call i32 @f734(i32 %a)
  %r = xor i32 %b, 1468
  ret i32 %r
}
define internal i32 @f1469(i32 %x) {
  %a = call i32 @f1468(i32 %x)
  %b = call i32 @f734(i32 %a)
  %r = xor i32 %b, 1469
  ret i32 %r
}
define internal i32 @f1470(i32 %x) {
  %a = call i32 @f1469(i32 %x)
  %b = call i32 @f735(i32 %a)
  %r = xor i32 %b, 1470
  ret i32 %r
}
define internal i32 @f1471(i32 %x) {
  %a = call i32 @f1470(i32 %x)
  %b = call i32 @f735(i32 %a)
  %r = xor i32 %b, 1471
  ret i32 %r
}
define internal i32 @f1472(i32 %x) {
  %a = call i32 @f1471(i32 %x)
  %b = call i32 @f736(i32 %a)
  %r = xor i32 %b, 1472
  ret i32 %r
}
define internal i32 @f1473(i32 %x) {
  %a = call i32 @f1472(i32 %x)
  %b = call i32 @f736(i32 %a)
  %r = xor i32 %b, 1473
  ret i32 %r
}
define internal i32 @f1474(i32 %x) {
  %a = call i32 @f1473(i32 %x)
  %b = call i32 @f737(i32 %a)
  %r = xor i32 %b, 1474
  ret i32 %r
}
define internal i32 @f1475(i32 %x) {
  %a = call i32 @f1474(i32 %x)
  %b = call i32 @f737(i32 %a)
  %r = xor i32 %b, 1475
  ret i32 %r
}
define internal i32 @f1476(i32 %x) {
  %a = call i32 @f1475(i32 %x)
  %b = call i32 @f738(i32 %a)
  %r = xor i32 %b, 1476
  ret i32 %r
}
define internal i32 @f1477(i32 %x) {
  %a = call i32 @f1476(i32 %x)
  %b = call i32 @f738(i32 %a)
  %r = xor i32 %b, 1477
  ret i32 %r
}
define internal i32 @f1478(i32 %x) {
  %a = call i32 @f1477(i32 %x)
  %b = call i32 @f739(i32 %a)
  %r = xor i32 %b, 1478
  ret i32 %r
}
define internal i32 @f1479(i32 %x) {
  %a = call i32 @f1478(i32 %x)
  %b = call i32 @f739(i32 %a)
  %r = xor i32 %b, 1479
  ret i32 %r
}
define internal i32 @f1480(i32 %x) {
  %a = call i32 @f1479(i32 %x)
  %b = call i32 @f740(i32 %a)
  %r = xor i32 %b, 1480
  ret i32 %r
}
define internal i32 @f1481(i32 %x) {
  %a = call i32 @f1480(i32 %x)
  %b = call i32 @f740(i32 %a)
  %r = xor i32 %b, 1481
  ret i32 %r
}
define internal i32 @f1482(i32 %x) {
  %a = call i32 @f1481(i32 %x)
  %b = call i32 @f741(i32 %a)
  %r = xor i32 %b, 1482
  ret i32 %r
}
define internal i32 @f1483(i32 %x) {
  %a = call i32 @f1482(i32 %x)
  %b = call i32 @f741(i32 %a)
  %r = xor i32 %b, 1483
  ret i32 %r
}
define internal i32 @f1484(i32 %x) {
  %a = call i32 @f1483(i32 %x)
  %b = call i32 @f742(i32 %a)
  %r = xor i32 %b, 1484
  ret i32 %r
}
define internal i32 @f1485(i32 %x) {
  %a = call i32 @f1484(i32 %x)
  %b = call i32 @f742(i32 %a)
  %r = xor i32 %b, 1485
  ret i32 %r
}
define internal i32 @f1486(i32 %x) {
  %a = call i32 @f1485(i32 %x)
  %b = call i32 @f743(i32 %a)
  %r = xor i32 %b, 1486
  ret i32 %r
}
define internal i32 @f1487(i32 %x) {
  %a = call i32 @f1486(i32 %x)
  %b = call i32 @f743(i32 %a)
  %r = xor i32 %b, 1487
  ret i32 %r
}
define internal i32 @f1488(i32 %x) {
  %a = call i32 @f1487(i32 %x)
  %b = call i32 @f744(i32 %a)
  %r = xor i32 %b, 1488
  ret i32 %r
}
define internal i32 @f1489(i32 %x) {
  %a = call i32 @f1488(i32 %x)
  %b = call i32 @f744(i32 %a)
  %r = xor i32 %b, 1489
  ret i32 %r
}
define internal i32 @f1490(i32 %x) {
  %a = call i32 @f1489(i32 %x)
  %b = call i32 @f745(i32 %a)
  %r = xor i32 %b, 1490
  ret i32 %r
}
define internal i32 @f1491(i32 %x) {
  %a = call i32 @f1490(i32 %x)
  %b = call i32 @f745(i32 %a)
  %r = xor i32 %b, 1491
  ret i32 %r
}
define internal i32 @f1492(i32 %x) {
  %a = call i32 @f1491(i32 %x)
  %b = call i32 @f746(i32 %a)
  %r = xor i32 %b, 1492
  ret i32 %r
}
define internal i32 @f1493(i32 %x) {
  %a = call i32 @f1492(i32 %x)
  %b = call i32 @f746(i32 %a)
  %r = xor i32 %b, 1493
  ret i32 %r
}
define internal i32 @f1494(i32 %x) {
  %a = call i32 @f1493(i32 %x)
  %b = call i32 @f747(i32 %a)
  %r = xor i32 %b, 1494
  ret i32 %r
}
define internal i32 @f1495(i32 %x) {
  %a = call i32 @f1494(i32 %x)
  %b = call i32 @f747(i32 %a)
  %r = xor i32 %b, 1495
  ret i32 %r
}
define internal i32 @f1496(i32 %x) {
  %a = call i32 @f1495(i32 %x)
  %b = call i32 @f748(i32 %a)
  %r = xor i32 %b, 1496
  ret i32 %r
}
define internal i32 @f1497(i32 %x) {
  %a = call i32 @f1496(i32 %x)
  %b = call i32 @f748(i32 %a)
  %r = xor i32 %b, 1497
  ret i32 %r
}
define internal i32 @f1498(i32 %x) {
  %a = call i32 @f1497(i32 %x)
  %b = call i32 @f749(i32 %a)
  %r = xor i32 %b, 1498
  ret i32 %r
}
define internal i32 @f1499(i32 %x) {
  %a = call i32 @f1498(i32 %x)
  %b = call i32 @f749(i32 %a)
  %r = xor i32 %b, 1499
  ret i32 %r
}
define internal i32 @f1500(i32 %x) {
  %a = call i32 @f1499(i32 %x)
  %b = call i32 @f750(i32 %a)
  %r = xor i32 %b, 1500
  ret i32 %r
}
define internal i32 @f1501(i32 %x) {
  %a = call i32 @f1500(i32 %x)
  %b = call i32 @f750(i32 %a)
  %r = xor i32 %b, 1501
  ret i32 %r
}
define internal i32 @f1502(i32 %x) {
  %a = call i32 @f1501(i32 %x)
  %b = call i32 @f751(i32 %a)
  %r = xor i32 %b, 1502
  ret i32 %r
}
define internal i32 @f1503(i32 %x) {
  %a = call i32 @f1502(i32 %x)
  %b = call i32 @f751(i32 %a)
  %r = xor i32 %b, 1503
  ret i32 %r
}
define internal i32 @f1504(i32 %x) {
  %a = call i32 @f1503(i32 %x)
  %b = call i32 @f752(i32 %a)
  %r = xor i32 %b, 1504
  ret i32 %r
}
define internal i32 @f1505(i32 %x) {
  %a = call i32 @f1504(i32 %x)
  %b = call i32 @f752(i32 %a)
  %r = xor i32 %b, 1505
  ret i32 %r
}
define internal i32 @f1506(i32 %x) {
  %a = call i32 @f1505(i32 %x)
  %b = call i32 @f753(i32 %a)
  %r = xor i32 %b, 1506
  ret i32 %r
}
define internal i32 @f1507(i32 %x) {
  %a = call i32 @f1506(i32 %x)
  %b = call i32 @f753(i32 %a)
  %r = xor i32 %b, 1507
  ret i32 %r
}
define internal i32 @f1508(i32 %x) {
  %a = call i32 @f1507(i32 %x)
  %b = call i32 @f754(i32 %a)
  %r = xor i32 %b, 1508
  ret i32 %r
}
define internal i32 @f1509(i32 %x) {
  %a = call i32 @f1508(i32 %x)
  %b = call i32 @f754(i32 %a)
  %r = xor i32 %b, 1509
  ret i32 %r
}
define internal i32 @f1510(i32 %x) {
  %a = call i32 @f1509(i32 %x)
  %b = call i32 @f755(i32 %a)
  %r = xor i32 %b, 1510
  ret i32 %r
}
define internal i32 @f1511(i32 %x) {
  %a = call i32 @f1510(i32 %x)
  %b = call i32 @f755(i32 %a)
  %r = xor i32 %b, 1511
  ret i32 %r
}
define internal i32 @f1512(i32 %x) {
  %a = call i32 @f1511(i32 %x)
  %b = call i32 @f756(i32 %a)
  %r = xor i32 %b, 1512
  ret i32 %r
}
define internal i32 @f1513(i32 %x) {
  %a = call i32 @f1512(i32 %x)
  %b = call i32 @f756(i32 %a)
  %r = xor i32 %b, 1513
  ret i32 %r
}
define internal i32 @f1514(i32 %x) {
  %a = call i32 @f1513(i32 %x)
  %b = call i32 @f757(i32 %a)
  %r = xor i32 %b, 1514
  ret i32 %r
}
define internal i32 @f1515(i32 %x) {
  %a = call i32 @f1514(i32 %x)
  %b = call i32 @f757(i32 %a)
  %r = xor i32 %b, 1515
  ret i32 %r
}
define internal i32 @f1516(i32 %x) {
  %a = call i32 @f1515(i32 %x)
  %b = call i32 @f758(i32 %a)
  %r = xor i32 %b, 1516
  ret i32 %r
}
define internal i32 @f1517(i32 %x) {
  %a = call i32 @f1516(i32 %x)
  %b = call i32 @f758(i32 %a)
  %r = xor i32 %b, 1517
  ret i32 %r
}
define internal i32 @f1518(i32 %x) {
  %a = call i32 @f1517(i32 %x)
  %b = call i32 @f759(i32 %a)
  %r = xor i32 %b, 1518
  ret i32 %r
}
define internal i32 @f1519(i32 %x) {
  %a = call i32 @f1518(i32 %x)
  %b = call i32 @f759(i32 %a)
  %r = xor i32 %b, 1519
  ret i32 %r
}
define internal i32 @f1520(i32 %x) {
  %a = call i32 @f1519(i32 %x)
  %b = call i32 @f760(i32 %a)
  %r = xor i32 %b, 1520
  ret i32 %r
}
define internal i32 @f1521(i32 %x) {
  %a = call i32 @f1520(i32 %x)
  %b = call i32 @f760(i32 %a)
  %r = xor i32 %b, 1521
  ret i32 %r
}
define internal i32 @f1522(i32 %x) {
  %a = call i32 @f1521(i32 %x)
  %b = call i32 @f761(i32 %a)
  %r = xor i32 %b, 1522
  ret i32 %r
}
define internal i32 @f1523(i32 %x) {
  %a = call i32 @f1522(i32 %x)
  %b = call i32 @f761(i32 %a)
  %r = xor i32 %b, 1523
  ret i32 %r
}
define internal i32 @f1524(i32 %x) {
  %a = call i32 @f1523(i32 %x)
  %b = call i32 @f762(i32 %a)
  %r = xor i32 %b, 1524
  ret i32 %r
}
define internal i32 @f1525(i32 %x) {
  %a = call i32 @f1524(i32 %x)
  %b = call i32 @f762(i32 %a)
  %r = xor i32 %b, 1525
  ret i32 %r
}
define internal i32 @f1526(i32 %x) {
  %a = call i32 @f1525(i32 %x)
  %b = call i32 @f763(i32 %a)
  %r = xor i32 %b, 1526
  ret i32 %r
}
define internal i32 @f1527(i32 %x) {
  %a = call i32 @f1526(i32 %x)
  %b = call i32 @f763(i32 %a)
  %r = xor i32 %b, 1527
  ret i32 %r
}
define internal i32 @f1528(i32 %x) {
  %a = call i32 @f1527(i32 %x)
  %b = call i32 @f764(i32 %a)
  %r = xor i32 %b, 1528
  ret i32 %r
}
define internal i32 @f1529(i32 %x) {
  %a = call i32 @f1528(i32 %x)
  %b = call i32 @f764(i32 %a)
  %r = xor i32 %b, 1529
  ret i32 %r
}
define internal i32 @f1530(i32 %x) {
  %a = call i32 @f1529(i32 %x)
  %b = call i32 @f765(i32 %a)
  %r = xor i32 %b, 1530
  ret i32 %r
}
define internal i32 @f1531(i32 %x) {
  %a = call i32 @f1530(i32 %x)
  %b = call i32 @f765(i32 %a)
  %r = xor i32 %b, 1531
  ret i32 %r
}
define internal i32 @f1532(i32 %x) {
  %a = call i32 @f1531(i32 %x)
  %b = call i32 @f766(i32 %a)
  %r = xor i32 %b, 1532
  ret i32 %r
}
define internal i32 @f1533(i32 %x) {
  %a = call i32 @f1532(i32 %x)
  %b = call i32 @f766(i32 %a)
  %r = xor i32 %b, 1533
  ret i32 %r
}
define internal i32 @f1534(i32 %x) {
  %a = call i32 @f1533(i32 %x)
  %b = call i32 @f767(i32 %a)
  %r = xor i32 %b, 1534
  ret i32 %r
}
define internal i32 @f1535(i32 %x) {
  %a = call i32 @f1534(i32 %x)
  %b = call i32 @f767(i32 %a)
  %r = xor i32 %b, 1535
  ret i32 %r
}
define internal i32 @f1536(i32 %x) {
  %a = call i32 @f1535(i32 %x)
  %b = call i32 @f768(i32 %a)
  %r = xor i32 %b, 1536
  ret i32 %r
}
define internal i32 @f1537(i32 %x) {
  %a = call i32 @f1536(i32 %x)
  %b = call i32 @f768(i32 %a)
  %r = xor i32 %b, 1537
  ret i32 %r
}
define internal i32 @f1538(i32 %x) {
  %a = call i32 @f1537(i32 %x)
  %b = call i32 @f769(i32 %a)
  %r = xor i32 %b, 1538
  ret i32 %r
}
define internal i32 @f1539(i32 %x) {
  %a = call i32 @f1538(i32 %x)
  %b = call i32 @f769(i32 %a)
  %r = xor i32 %b, 1539
  ret i32 %r
}
define internal i32 @f1540(i32 %x) {
  %a = call i32 @f1539(i32 %x)
  %b = call i32 @f770(i32 %a)
  %r = xor i32 %b, 1540
  ret i32 %r
}
define internal i32 @f1541(i32 %x) {
  %a = call i32 @f1540(i32 %x)
  %b = call i32 @f770(i32 %a)
  %r = xor i32 %b, 1541
  ret i32 %r
}
define internal i32 @f1542(i32 %x) {
  %a = call i32 @f1541(i32 %x)
  %b = call i32 @f771(i32 %a)
  %r = xor i32 %b, 1542
  ret i32 %r
}
define internal i32 @f1543(i32 %x) {
  %a = call i32 @f1542(i32 %x)
  %b = call i32 @f771(i32 %a)
  %r = xor i32 %b, 1543
  ret i32 %r
}
define internal i32 @f1544(i32 %x) {
  %a = call i32 @f1543(i32 %x)
  %b = call i32 @f772(i32 %a)
  %r = xor i32 %b, 1544
  ret i32 %r
}
define internal i32 @f1545(i32 %x) {
  %a = call i32 @f1544(i32 %x)
  %b = call i32 @f772(i32 %a)
  %r = xor i32 %b, 1545
  ret i32 %r
}
define internal i32 @f1546(i32 %x) {
  %a = call i32 @f1545(i32 %x)
  %b = call i32 @f773(i32 %a)
  %r = xor i32 %b, 1546
  ret i32 %r
}
define internal i32 @f1547(i32 %x) {
  %a = call i32 @f1546(i32 %x)
  %b = call i32 @f773(i32 %a)
  %r = xor i32 %b, 1547
  ret i32 %r
}
define internal i32 @f1548(i32 %x) {
  %a = call i32 @f1547(i32 %x)
  %b = call i32 @f774(i32 %a)
  %r = xor i32 %b, 1548
  ret i32 %r
}
define internal i32 @f1549(i32 %x) {
  %a = call i32 @f1548(i32 %x)
  %b = call i32 @f774(i32 %a)
  %r = xor i32 %b, 1549
  ret i32 %r
}
define internal i32 @f1550(i32 %x) {
  %a = call i32 @f1549(i32 %x)
  %b = call i32 @f775(i32 %a)
  %r = xor i32 %b, 1550
  ret i32 %r
}
define internal i32 @f1551(i32 %x) {
  %a = call i32 @f1550(i32 %x)
  %b = call i32 @f775(i32 %a)
  %r = xor i32 %b, 1551
  ret i32 %r
}
define internal i32 @f1552(i32 %x) {
  %a = call i32 @f1551(i32 %x)
  %b = call i32 @f776(i32 %a)
  %r = xor i32 %b, 1552
  ret i32 %r
}
define internal i32 @f1553(i32 %x) {
  %a = call i32 @f1552(i32 %x)
  %b = call i32 @f776(i32 %a)
  %r = xor i32 %b, 1553
  ret i32 %r
}
define internal i32 @f1554(i32 %x) {
  %a = call i32 @f1553(i32 %x)
  %b = call i32 @f777(i32 %a)
  %r = xor i32 %b, 1554
  ret i32 %r
}
define internal i32 @f1555(i32 %x) {
  %a = call i32 @f1554(i32 %x)
  %b = call i32 @f777(i32 %a)
  %r = xor i32 %b, 1555
  ret i32 %r
}
define internal i32 @f1556(i32 %x) {
  %a = call i32 @f1555(i32 %x)
  %b = call i32 @f778(i32 %a)
  %r = xor i32 %b, 1556
  ret i32 %r
}
define internal i32 @f1557(i32 %x) {
  %a = call i32 @f1556(i32 %x)
  %b = call i32 @f778(i32 %a)
  %r = xor i32 %b, 1557
  ret i32 %r
}
define internal i32 @f1558(i32 %x) {
  %a = call i32 @f1557(i32 %x)
  %b = call i32 @f779(i32 %a)
  %r = xor i32 %b, 1558
  ret i32 %r
}
define internal i32 @f1559(i32 %x) {
  %a = call i32 @f1558(i32 %x)
  %b = call i32 @f779(i32 %a)
  %r = xor i32 %b, 1559
  ret i32 %r
}
define internal i32 @f1560(i32 %x) {
  %a = call i32 @f1559(i32 %x)
  %b = call i32 @f780(i32 %a)
  %r = xor i32 %b, 1560
  ret i32 %r
}
define internal i32 @f1561(i32 %x) {
  %a = call i32 @f1560(i32 %x)
  %b = call i32 @f780(i32 %a)
  %r = xor i32 %b, 1561
  ret i32 %r
}
define internal i32 @f1562(i32 %x) {
  %a = call i32 @f1561(i32 %x)
  %b = call i32 @f781(i32 %a)
  %r = xor i32 %b, 1562
  ret i32 %r
}
define internal i32 @f1563(i32 %x) {
  %a = call i32 @f1562(i32 %x)
  %b = call i32 @f781(i32 %a)
  %r = xor i32 %b, 1563
  ret i32 %r
}
define internal i32 @f1564(i32 %x) {
  %a = call i32 @f1563(i32 %x)
  %b = call i32 @f782(i32 %a)
  %r = xor i32 %b, 1564
  ret i32 %r
}
define internal i32 @f1565(i32 %x) {
  %a = call i32 @f1564(i32 %x)
  %b = call i32 @f782(i32 %a)
  %r = xor i32 %b, 1565
  ret i32 %r
}
define internal i32 @f1566(i32 %x) {
  %a = call i32 @f1565(i32 %x)
  %b = call i32 @f783(i32 %a)
  %r = xor i32 %b, 1566
  ret i32 %r
}
define internal i32 @f1567(i32 %x) {
  %a = call i32 @f1566(i32 %x)
  %b = call i32 @f783(i32 %a)
  %r = xor i32 %b, 1567
  ret i32 %r
}
define internal i32 @f1568(i32 %x) {
  %a = call i32 @f1567(i32 %x)
  %b = call i32 @f784(i32 %a)
  %r = xor i32 %b, 1568
  ret i32 %r
}
define internal i32 @f1569(i32 %x) {
  %a = call i32 @f1568(i32 %x)
  %b = call i32 @f784(i32 %a)
  %r = xor i32 %b, 1569
  ret i32 %r
}
define internal i32 @f1570(i32 %x) {
  %a = call i32 @f1569(i32 %x)
  %b = call i32 @f785(i32 %a)
  %r = xor i32 %b, 1570
  ret i32 %r
}
define internal i32 @f1571(i32 %x) {
  %a = call i32 @f1570(i32 %x)
  %b = call i32 @f785(i32 %a)
  %r = xor i32 %b, 1571
  ret i32 %r
}
define internal i32 @f1572(i32 %x) {
  %a = call i32 @f1571(i32 %x)
  %b = call i32 @f786(i32 %a)
  %r = xor i32 %b, 1572
  ret i32 %r
}
define internal i32 @f1573(i32 %x) {
  %a = call i32 @f1572(i32 %x)
  %b = call i32 @f786(i32 %a)
  %r = xor i32 %b, 1573
  ret i32 %r
}
define internal i32 @f1574(i32 %x) {
  %a = call i32 @f1573(i32 %x)
  %b = call i32 @f787(i32 %a)
  %r = xor i32 %b, 1574
  ret i32 %r
}
define internal i32 @f1575(i32 %x) {
  %a = call i32 @f1574(i32 %x)
  %b = call i32 @f787(i32 %a)
  %r = xor i32 %b, 1575
  ret i32 %r
}
define internal i32 @f1576(i32 %x) {
  %a = call i32 @f1575(i32 %x)
  %b = call i32 @f788(i32 %a)
  %r = xor i32 %b, 1576
  ret i32 %r
}
define internal i32 @f1577(i32 %x) {
  %a = call i32 @f1576(i32 %x)
  %b = call i32 @f788(i32 %a)
  %r = xor i32 %b, 1577
  ret i32 %r
}
define internal i32 @f1578(i32 %x) {
  %a = call i32 @f1577(i32 %x)
  %b = call i32 @f789(i32 %a)
  %r = xor i32 %b, 1578
  ret i32 %r
}
define internal i32 @f1579(i32 %x) {
  %a = call i32 @f1578(i32 %x)
  %b = call i32 @f789(i32 %a)
  %r = xor i32 %b, 1579
  ret i32 %r
}
define internal i32 @f1580(i32 %x) {
  %a = call i32 @f1579(i32 %x)
  %b = call i32 @f790(i32 %a)
  %r = xor i32 %b, 1580
  ret i32 %r
}
define internal i32 @f1581(i32 %x) {
  %a = call i32 @f1580(i32 %x)
  %b = call i32 @f790(i32 %a)
  %r = xor i32 %b, 1581
  ret i32 %r
}
define internal i32 @f1582(i32 %x) {
  %a = call i32 @f1581(i32 %x)
  %b = call i32 @f791(i32 %a)
  %r = xor i32 %b, 1582
  ret i32 %r
}
define internal i32 @f1583(i32 %x) {
  %a = call i32 @f1582(i32 %x)
  %b = call i32 @f791(i32 %a)
  %r = xor i32 %b, 1583
  ret i32 %r
}
define internal i32 @f1584(i32 %x) {
  %a = call i32 @f1583(i32 %x)
  %b = call i32 @f792(i32 %a)
  %r = xor i32 %b, 1584
  ret i32 %r
}
define internal i32 @f1585(i32 %x) {
  %a = call i32 @f1584(i32 %x)
  %b = call i32 @f792(i32 %a)
  %r = xor i32 %b, 1585
  ret i32 %r
}
define internal i32 @f1586(i32 %x) {
  %a = call i32 @f1585(i32 %x)
  %b = call i32 @f793(i32 %a)
  %r = xor i32 %b, 1586
  ret i32 %r
}
define internal i32 @f1587(i32 %x) {
  %a = call i32 @f1586(i32 %x)
  %b = call i32 @f793(i32 %a)
  %r = xor i32 %b, 1587
  ret i32 %r
}
define internal i32 @f1588(i32 %x) {
  %a = call i32 @f1587(i32 %x)
  %b = call i32 @f794(i32 %a)
  %r = xor i32 %b, 1588
  ret i32 %r
}
define internal i32 @f1589(i32 %x) {
  %a = call i32 @f1588(i32 %x)
  %b = call i32 @f794(i32 %a)
  %r = xor i32 %b, 1589
  ret i32 %r
}
define internal i32 @f1590(i32 %x) {
  %a = call i32 @f1589(i32 %x)
  %b = call i32 @f795(i32 %a)
  %r = xor i32 %b, 1590
  ret i32 %r
}
define internal i32 @f1591(i32 %x) {
  %a = call i32 @f1590(i32 %x)
  %b = call i32 @f795(i32 %a)
  %r = xor i32 %b, 1591
  ret i32 %r
}
define internal i32 @f1592(i32 %x) {
  %a = call i32 @f1591(i32 %x)
  %b = call i32 @f796(i32 %a)
  %r = xor i32 %b, 1592
  ret i32 %r
}
define internal i32 @f1593(i32 %x) {
  %a = call i32 @f1592(i32 %x)
  %b = call i32 @f796(i32 %a)
  %r = xor i32 %b, 1593
  ret i32 %r
}
define internal i32 @f1594(i32 %x) {
  %a = call i32 @f1593(i32 %x)
  %b = call i32 @f797(i32 %a)
  %r = xor i32 %b, 1594
  ret i32 %r
}
define internal i32 @f1595(i32 %x) {
  %a = call i32 @f1594(i32 %x)
  %b = call i32 @f797(i32 %a)
  %r = xor i32 %b, 1595
  ret i32 %r
}
define internal i32 @f1596(i32 %x) {
  %a = call i32 @f1595(i32 %x)
  %b = call i32 @f798(i32 %a)
  %r = xor i32 %b, 1596
  ret i32 %r
}
define internal i32 @f1597(i32 %x) {
  %a = call i32 @f1596(i32 %x)
  %b = call i32 @f798(i32 %a)
  %r = xor i32 %b, 1597
  ret i32 %r
}
define internal i32 @f1598(i32 %x) {
  %a = call i32 @f1597(i32 %x)
  %b = call i32 @f799(i32 %a)
  %r = xor i32 %b, 1598
  ret i32 %r
}
define internal i32 @f1599(i32 %x) {
  %a = call i32 @f1598(i32 %x)
  %b = call i32 @f799(i32 %a)
  %r = xor i32 %b, 1599
  ret i32 %r
}
define internal i32 @f1600(i32 %x) {
  %a = call i32 @f1599(i32 %x)
  %b = call i32 @f800(i32 %a)
  %r = xor i32 %b, 1600
  ret i32 %r
}
define internal i32 @f1601(i32 %x) {
  %a = call i32 @f1600(i32 %x)
  %b = call i32 @f800(i32 %a)
  %r = xor i32 %b, 1601
  ret i32 %r
}
define internal i32 @f1602(i32 %x) {
  %a = call i32 @f1601(i32 %x)
  %b = call i32 @f801(i32 %a)
  %r = xor i32 %b, 1602
  ret i32 %r
}
define internal i32 @f1603(i32 %x) {
  %a = call i32 @f1602(i32 %x)
  %b = call i32 @f801(i32 %a)
  %r = xor i32 %b, 1603
  ret i32 %r
}
define internal i32 @f1604(i32 %x) {
  %a = call i32 @f1603(i32 %x)
  %b = call i32 @f802(i32 %a)
  %r = xor i32 %b, 1604
  ret i32 %r
}
define internal i32 @f1605(i32 %x) {
  %a = call i32 @f1604(i32 %x)
  %b = call i32 @f802(i32 %a)
  %r = xor i32 %b, 1605
  ret i32 %r
}
define internal i32 @f1606(i32 %x) {
  %a = call i32 @f1605(i32 %x)
  %b = call i32 @f803(i32 %a)
  %r = xor i32 %b, 1606
  ret i32 %r
}
define internal i32 @f1607(i32 %x) {
  %a = call i32 @f1606(i32 %x)
  %b = call i32 @f803(i32 %a)
  %r = xor i32 %b, 1607
  ret i32 %r
}
define internal i32 @f1608(i32 %x) {
  %a = call i32 @f1607(i32 %x)
  %b = call i32 @f804(i32 %a)
  %r = xor i32 %b, 1608
  ret i32 %r
}
define internal i32 @f1609(i32 %x) {
  %a = call i32 @f1608(i32 %x)
  %b = call i32 @f804(i32 %a)
  %r = xor i32 %b, 1609
  ret i32 %r
}
define internal i32 @f1610(i32 %x) {
  %a = call i32 @f1609(i32 %x)
  %b = call i32 @f805(i32 %a)
  %r = xor i32 %b, 1610
  ret i32 %r
}
define internal i32 @f1611(i32 %x) {
  %a = call i32 @f1610(i32 %x)
  %b = call i32 @f805(i32 %a)
  %r = xor i32 %b, 1611
  ret i32 %r
}
define internal i32 @f1612(i32 %x) {
  %a = call i32 @f1611(i32 %x)
  %b = call i32 @f806(i32 %a)
  %r = xor i32 %b, 1612
  ret i32 %r
}
define internal i32 @f1613(i32 %x) {
  %a = call i32 @f1612(i32 %x)
  %b = call i32 @f806(i32 %a)
  %r = xor i32 %b, 1613
  ret i32 %r
}
define internal i32 @f1614(i32 %x) {
  %a = call i32 @f1613(i32 %x)
  %b = call i32 @f807(i32 %a)
  %r = xor i32 %b, 1614
  ret i32 %r
}
define internal i32 @f1615(i32 %x) {
  %a = call i32 @f1614(i32 %x)
  %b = call i32 @f807(i32 %a)
  %r = xor i32 %b, 1615
  ret i32 %r
}
define internal i32 @f1616(i32 %x) {
  %a = call i32 @f1615(i32 %x)
  %b = call i32 @f808(i32 %a)
  %r = xor i32 %b, 1616
  ret i32 %r
}
define internal i32 @f1617(i32 %x) {
  %a = call i32 @f1616(i32 %x)
  %b = call i32 @f808(i32 %a)
  %r = xor i32 %b, 1617
  ret i32 %r
}
define internal i32 @f1618(i32 %x) {
  %a = call i32 @f1617(i32 %x)
  %b = call i32 @f809(i32 %a)
  %r = xor i32 %b, 1618
  ret i32 %r
}
define internal i32 @f1619(i32 %x) {
  %a = call i32 @f1618(i32 %x)
  %b = call i32 @f809(i32 %a)
  %r = xor i32 %b, 1619
  ret i32 %r
}
define internal i32 @f1620(i32 %x) {
  %a = call i32 @f1619(i32 %x)
  %b = call i32 @f810(i32 %a)
  %r = xor i32 %b, 1620
  ret i32 %r
}
define internal i32 @f1621(i32 %x) {
  %a = call i32 @f1620(i32 %x)
  %b = call i32 @f810(i32 %a)
  %r = xor i32 %b, 1621
  ret i32 %r
}
define internal i32 @f1622(i32 %x) {
  %a = call i32 @f1621(i32 %x)
  %b = call i32 @f811(i32 %a)
  %r = xor i32 %b, 1622
  ret i32 %r
}
define internal i32 @f1623(i32 %x) {
  %a = call i32 @f1622(i32 %x)
  %b = call i32 @f811(i32 %a)
  %r = xor i32 %b, 1623
  ret i32 %r
}
define internal i32 @f1624(i32 %x) {
  %a = call i32 @f1623(i32 %x)
  %b = call i32 @f812(i32 %a)
  %r = xor i32 %b, 1624
  ret i32 %r
}
define internal i32 @f1625(i32 %x) {
  %a = call i32 @f1624(i32 %x)
  %b = call i32 @f812(i32 %a)
  %r = xor i32 %b, 1625
  ret i32 %r
}
define internal i32 @f1626(i32 %x) {
  %a = call i32 @f1625(i32 %x)
  %b = call i32 @f813(i32 %a)
  %r = xor i32 %b, 1626
  ret i32 %r
}
define internal i32 @f1627(i32 %x) {
  %a = call i32 @f1626(i32 %x)
  %b = call i32 @f813(i32 %a)
  %r = xor i32 %b, 1627
  ret i32 %r
}
define internal i32 @f1628(i32 %x) {
  %a = call i32 @f1627(i32 %x)
  %b = call i32 @f814(i32 %a)
  %r = xor i32 %b, 1628
  ret i32 %r
}
define internal i32 @f1629(i32 %x) {
  %a = call i32 @f1628(i32 %x)
  %b = call i32 @f814(i32 %a)
  %r = xor i32 %b, 1629
  ret i32 %r
}
define internal i32 @f1630(i32 %x) {
  %a = call i32 @f1629(i32 %x)
  %b = call i32 @f815(i32 %a)
  %r = xor i32 %b, 1630
  ret i32 %r
}
define internal i32 @f1631(i32 %x) {
  %a = call i32 @f1630(i32 %x)
  %b = call i32 @f815(i32 %a)
  %r = xor i32 %b, 1631
  ret i32 %r
}
define internal i32 @f1632(i32 %x) {
  %a = call i32 @f1631(i32 %x)
  %b = call i32 @f816(i32 %a)
  %r = xor i32 %b, 1632
  ret i32 %r
}
define internal i32 @f1633(i32 %x) {
  %a = call i32 @f1632(i32 %x)
  %b = call i32 @f816(i32 %a)
  %r = xor i32 %b, 1633
  ret i32 %r
}
define internal i32 @f1634(i32 %x) {
  %a = call i32 @f1633(i32 %x)
  %b = call i32 @f817(i32 %a)
  %r = xor i32 %b, 1634
  ret i32 %r
}
define internal i32 @f1635(i32 %x) {
  %a = call i32 @f1634(i32 %x)
  %b = call i32 @f817(i32 %a)
  %r = xor i32 %b, 1635
  ret i32 %r
}
define internal i32 @f1636(i32 %x) {
  %a = call i32 @f1635(i32 %x)
  %b = call i32 @f818(i32 %a)
  %r = xor i32 %b, 1636
  ret i32 %r
}
define internal i32 @f1637(i32 %x) {
  %a = call i32 @f1636(i32 %x)
  %b = call i32 @f818(i32 %a)
  %r = xor i32 %b, 1637
  ret i32 %r
}
define internal i32 @f1638(i32 %x) {
  %a = call i32 @f1637(i32 %x)
  %b = call i32 @f819(i32 %a)
  %r = xor i32 %b, 1638
  ret i32 %r
}
define internal i32 @f1639(i32 %x) {
  %a = call i32 @f1638(i32 %x)
  %b = call i32 @f819(i32 %a)
  %r = xor i32 %b, 1639
  ret i32 %r
}
define internal i32 @f1640(i32 %x) {
  %a = call i32 @f1639(i32 %x)
  %b = call i32 @f820(i32 %a)
  %r = xor i32 %b, 1640
  ret i32 %r
}
define internal i32 @f1641(i32 %x) {
  %a = call i32 @f1640(i32 %x)
  %b = call i32 @f820(i32 %a)
  %r = xor i32 %b, 1641
  ret i32 %r
}
define internal i32 @f1642(i32 %x) {
  %a = call i32 @f1641(i32 %x)
  %b = call i32 @f821(i32 %a)
  %r = xor i32 %b, 1642
  ret i32 %r
}
define internal i32 @f1643(i32 %x) {
  %a = call i32 @f1642(i32 %x)
  %b = call i32 @f821(i32 %a)
  %r = xor i32 %b, 1643
  ret i32 %r
}
define internal i32 @f1644(i32 %x) {
  %a = call i32 @f1643(i32 %x)
  %b = call i32 @f822(i32 %a)
  %r = xor i32 %b, 1644
  ret i32 %r
}
define internal i32 @f1645(i32 %x) {
  %a = call i32 @f1644(i32 %x)
  %b = call i32 @f822(i32 %a)
  %r = xor i32 %b, 1645
  ret i32 %r
}
define internal i32 @f1646(i32 %x) {
  %a = call i32 @f1645(i32 %x)
  %b = call i32 @f823(i32 %a)
  %r = xor i32 %b, 1646
  ret i32 %r
}
define internal i32 @f1647(i32 %x) {
  %a = call i32 @f1646(i32 %x)
  %b = call i32 @f823(i32 %a)
  %r = xor i32 %b, 1647
  ret i32 %r
}
define internal i32 @f1648(i32 %x) {
  %a = call i32 @f1647(i32 %x)
  %b = call i32 @f824(i32 %a)
  %r = xor i32 %b, 1648
  ret i32 %r
}
define internal i32 @f1649(i32 %x) {
  %a = call i32 @f1648(i32 %x)
  %b = call i32 @f824(i32 %a)
  %r = xor i32 %b, 1649
  ret i32 %r
}
define internal i32 @f1650(i32 %x) {
  %a = call i32 @f1649(i32 %x)
  %b = call i32 @f825(i32 %a)
  %r = xor i32 %b, 1650
  ret i32 %r
}
define internal i32 @f1651(i32 %x) {
  %a = call i32 @f1650(i32 %x)
  %b = call i32 @f825(i32 %a)
  %r = xor i32 %b, 1651
  ret i32 %r
}
define internal i32 @f1652(i32 %x) {
  %a = call i32 @f1651(i32 %x)
  %b = call i32 @f826(i32 %a)
  %r = xor i32 %b, 1652
  ret i32 %r
}
define internal i32 @f1653(i32 %x) {
  %a = call i32 @f1652(i32 %x)
  %b = call i32 @f826(i32 %a)
  %r = xor i32 %b, 1653
  ret i32 %r
}
define internal i32 @f1654(i32 %x) {
  %a = call i32 @f1653(i32 %x)
  %b = call i32 @f827(i32 %a)
  %r = xor i32 %b, 1654
  ret i32 %r
}
define internal i32 @f1655(i32 %x) {
  %a = call i32 @f1654(i32 %x)
  %b = call i32 @f827(i32 %a)
  %r = xor i32 %b, 1655
  ret i32 %r
}
define internal i32 @f1656(i32 %x) {
  %a = call i32 @f1655(i32 %x)
  %b = call i32 @f828(i32 %a)
  %r = xor i32 %b, 1656
  ret i32 %r
}
define internal i32 @f1657(i32 %x) {
  %a = call i32 @f1656(i32 %x)
  %b = call i32 @f828(i32 %a)
  %r = xor i32 %b, 1657
  ret i32 %r
}
define internal i32 @f1658(i32 %x) {
  %a = call i32 @f1657(i32 %x)
  %b = call i32 @f829(i32 %a)
  %r = xor i32 %b, 1658
  ret i32 %r
}
define internal i32 @f1659(i32 %x) {
  %a = call i32 @f1658(i32 %x)
  %b = call i32 @f829(i32 %a)
  %r = xor i32 %b, 1659
  ret i32 %r
}
define internal i32 @f1660(i32 %x) {
  %a = call i32 @f1659(i32 %x)
  %b = call i32 @f830(i32 %a)
  %r = xor i32 %b, 1660
  ret i32 %r
}
define internal i32 @f1661(i32 %x) {
  %a = call i32 @f1660(i32 %x)
  %b = call i32 @f830(i32 %a)
  %r = xor i32 %b, 1661
  ret i32 %r
}
define internal i32 @f1662(i32 %x) {
  %a = call i32 @f1661(i32 %x)
  %b = call i32 @f831(i32 %a)
  %r = xor i32 %b, 1662
  ret i32 %r
}
define internal i32 @f1663(i32 %x) {
  %a = call i32 @f1662(i32 %x)
  %b = call i32 @f831(i32 %a)
  %r = xor i32 %b, 1663
  ret i32 %r
}
define internal i32 @f1664(i32 %x) {
  %a = call i32 @f1663(i32 %x)
  %b = call i32 @f832(i32 %a)
  %r = xor i32 %b, 1664
  ret i32 %r
}
define internal i32 @f1665(i32 %x) {
  %a = call i32 @f1664(i32 %x)
  %b = call i32 @f832(i32 %a)
  %r = xor i32 %b, 1665
  ret i32 %r
}
define internal i32 @f1666(i32 %x) {
  %a = call i32 @f1665(i32 %x)
  %b = call i32 @f833(i32 %a)
  %r = xor i32 %b, 1666
  ret i32 %r
}
define internal i32 @f1667(i32 %x) {
  %a = call i32 @f1666(i32 %x)
  %b = call i32 @f833(i32 %a)
  %r = xor i32 %b, 1667
  ret i32 %r
}
define internal i32 @f1668(i32 %x) {
  %a = call i32 @f1667(i32 %x)
  %b = call i32 @f834(i32 %a)
  %r = xor i32 %b, 1668
  ret i32 %r
}
define internal i32 @f1669(i32 %x) {
  %a = call i32 @f1668(i32 %x)
  %b = call i32 @f834(i32 %a)
  %r = xor i32 %b, 1669
  ret i32 %r
}
define internal i32 @f1670(i32 %x) {
  %a = call i32 @f1669(i32 %x)
  %b = call i32 @f835(i32 %a)
  %r = xor i32 %b, 1670
  ret i32 %r
}
define internal i32 @f1671(i32 %x) {
  %a = call i32 @f1670(i32 %x)
  %b = call i32 @f835(i32 %a)
  %r = xor i32 %b, 1671
  ret i32 %r
}
define internal i32 @f1672(i32 %x) {
  %a = call i32 @f1671(i32 %x)
  %b = call i32 @f836(i32 %a)
  %r = xor i32 %b, 1672
  ret i32 %r
}
define internal i32 @f1673(i32 %x) {
  %a = call i32 @f1672(i32 %x)
  %b = call i32 @f836(i32 %a)
  %r = xor i32 %b, 1673
  ret i32 %r
}
define internal i32 @f1674(i32 %x) {
  %a = call i32 @f1673(i32 %x)
  %b = call i32 @f837(i32 %a)
  %r = xor i32 %b, 1674
  ret i32 %r
}
define internal i32 @f1675(i32 %x) {
  %a = call i32 @f1674(i32 %x)
  %b = call i32 @f837(i32 %a)
  %r = xor i32 %b, 1675
  ret i32 %r
}
define internal i32 @f1676(i32 %x) {
  %a = call i32 @f1675(i32 %x)
  %b = call i32 @f838(i32 %a)
  %r = xor i32 %b, 1676
  ret i32 %r
}
define internal i32 @f1677(i32 %x) {
  %a = call i32 @f1676(i32 %x)
  %b = call i32 @f838(i32 %a)
  %r = xor i32 %b, 1677
  ret i32 %r
}
define internal i32 @f1678(i32 %x) {
  %a = call i32 @f1677(i32 %x)
  %b = call i32 @f839(i32 %a)
  %r = xor i32 %b, 1678
  ret i32 %r
}
define internal i32 @f1679(i32 %x) {
  %a = call i32 @f1678(i32 %x)
  %b = call i32 @f839(i32 %a)
  %r = xor i32 %b, 1679
  ret i32 %r
}
define internal i32 @f1680(i32 %x) {
  %a = call i32 @f1679(i32 %x)
  %b = call i32 @f840(i32 %a)
  %r = xor i32 %b, 1680
  ret i32 %r
}
define internal i32 @f1681(i32 %x) {
  %a = call i32 @f1680(i32 %x)
  %b = call i32 @f840(i32 %a)
  %r = xor i32 %b, 1681
  ret i32 %r
}
define internal i32 @f1682(i32 %x) {
  %a = call i32 @f1681(i32 %x)
  %b = call i32 @f841(i32 %a)
  %r = xor i32 %b, 1682
  ret i32 %r
}
define internal i32 @f1683(i32 %x) {
  %a = call i32 @f1682(i32 %x)
  %b = call i32 @f841(i32 %a)
  %r = xor i32 %b, 1683
  ret i32 %r
}
define internal i32 @f1684(i32 %x) {
  %a = call i32 @f1683(i32 %x)
  %b = call i32 @f842(i32 %a)
  %r = xor i32 %b, 1684
  ret i32 %r
}
define internal i32 @f1685(i32 %x) {
  %a = call i32 @f1684(i32 %x)
  %b = call i32 @f842(i32 %a)
  %r = xor i32 %b, 1685
  ret i32 %r
}
define internal i32 @f1686(i32 %x) {
  %a = call i32 @f1685(i32 %x)
  %b = call i32 @f843(i32 %a)
  %r = xor i32 %b, 1686
  ret i32 %r
}
define internal i32 @f1687(i32 %x) {
  %a = call i32 @f1686(i32 %x)
  %b = call i32 @f843(i32 %a)
  %r = xor i32 %b, 1687
  ret i32 %r
}
define internal i32 @f1688(i32 %x) {
  %a = call i32 @f1687(i32 %x)
  %b = call i32 @f844(i32 %a)
  %r = xor i32 %b, 1688
  ret i32 %r
}
define internal i32 @f1689(i32 %x) {
  %a = call i32 @f1688(i32 %x)
  %b = call i32 @f844(i32 %a)
  %r = xor i32 %b, 1689
  ret i32 %r
}
define internal i32 @f1690(i32 %x) {
  %a = call i32 @f1689(i32 %x)
  %b = call i32 @f845(i32 %a)
  %r = xor i32 %b, 1690
  ret i32 %r
}
define internal i32 @f1691(i32 %x) {
  %a = call i32 @f1690(i32 %x)
  %b = call i32 @f845(i32 %a)
  %r = xor i32 %b, 1691
  ret i32 %r
}
define internal i32 @f1692(i32 %x) {
  %a = call i32 @f1691(i32 %x)
  %b = call i32 @f846(i32 %a)
  %r = xor i32 %b, 1692
  ret i32 %r
}
define internal i32 @f1693(i32 %x) {
  %a = call i32 @f1692(i32 %x)
  %b = call i32 @f846(i32 %a)
  %r = xor i32 %b, 1693
  ret i32 %r
}
define internal i32 @f1694(i32 %x) {
  %a = call i32 @f1693(i32 %x)
  %b = call i32 @f847(i32 %a)
  %r = xor i32 %b, 1694
  ret i32 %r
}
define internal i32 @f1695(i32 %x) {
  %a = call i32 @f1694(i32 %x)
  %b = call i32 @f847(i32 %a)
  %r = xor i32 %b, 1695
  ret i32 %r
}
define internal i32 @f1696(i32 %x) {
  %a = call i32 @f1695(i32 %x)
  %b = call i32 @f848(i32 %a)
  %r = xor i32 %b, 1696
  ret i32 %r
}
define internal i32 @f1697(i32 %x) {
  %a = call i32 @f1696(i32 %x)
  %b = call i32 @f848(i32 %a)
  %r = xor i32 %b, 1697
  ret i32 %r
}
define internal i32 @f1698(i32 %x) {
  %a = call i32 @f1697(i32 %x)
  %b = call i32 @f849(i32 %a)
  %r = xor i32 %b, 1698
  ret i32 %r
}
define internal i32 @f1699(i32 %x) {
  %a = call i32 @f1698(i32 %x)
  %b = call i32 @f849(i32 %a)
  %r = xor i32 %b, 1699
  ret i32 %r
}
define internal i32 @f1700(i32 %x) {
  %a = call i32 @f1699(i32 %x)
  %b = call i32 @f850(i32 %a)
  %r = xor i32 %b, 1700
  ret i32 %r
}
define internal i32 @f1701(i32 %x) {
  %a = call i32 @f1700(i32 %x)
  %b = call i32 @f850(i32 %a)
  %r = xor i32 %b, 1701
  ret i32 %r
}
define internal i32 @f1702(i32 %x) {
  %a = call i32 @f1701(i32 %x)
  %b = call i32 @f851(i32 %a)
  %r = xor i32 %b, 1702
  ret i32 %r
}
define internal i32 @f1703(i32 %x) {
  %a = call i32 @f1702(i32 %x)
  %b = call i32 @f851(i32 %a)
  %r = xor i32 %b, 1703
  ret i32 %r
}
define internal i32 @f1704(i32 %x) {
  %a = call i32 @f1703(i32 %x)
  %b = call i32 @f852(i32 %a)
  %r = xor i32 %b, 1704
  ret i32 %r
}
define internal i32 @f1705(i32 %x) {
  %a = call i32 @f1704(i32 %x)
  %b = call i32 @f852(i32 %a)
  %r = xor i32 %b, 1705
  ret i32 %r
}
define internal i32 @f1706(i32 %x) {
  %a = call i32 @f1705(i32 %x)
  %b = call i32 @f853(i32 %a)
  %r = xor i32 %b, 1706
  ret i32 %r
}
define internal i32 @f1707(i32 %x) {
  %a = call i32 @f1706(i32 %x)
  %b = call i32 @f853(i32 %a)
  %r = xor i32 %b, 1707
  ret i32 %r
}
define internal i32 @f1708(i32 %x) {
  %a = call i32 @f1707(i32 %x)
  %b = call i32 @f854(i32 %a)
  %r = xor i32 %b, 1708
  ret i32 %r
}
define internal i32 @f1709(i32 %x) {
  %a = call i32 @f1708(i32 %x)
  %b = call i32 @f854(i32 %a)
  %r = xor i32 %b, 1709
  ret i32 %r
}
define internal i32 @f1710(i32 %x) {
  %a = call i32 @f1709(i32 %x)
  %b = call i32 @f855(i32 %a)
  %r = xor i32 %b, 1710
  ret i32 %r
}
define internal i32 @f1711(i32 %x) {
  %a = call i32 @f1710(i32 %x)
  %b = call i32 @f855(i32 %a)
  %r = xor i32 %b, 1711
  ret i32 %r
}
define internal i32 @f1712(i32 %x) {
  %a = call i32 @f1711(i32 %x)
  %b = call i32 @f856(i32 %a)
  %r = xor i32 %b, 1712
  ret i32 %r
}
define internal i32 @f1713(i32 %x) {
  %a = call i32 @f1712(i32 %x)
  %b = call i32 @f856(i32 %a)
  %r = xor i32 %b, 1713
  ret i32 %r
}
define internal i32 @f1714(i32 %x) {
  %a = call i32 @f1713(i32 %x)
  %b = call i32 @f857(i32 %a)
  %r = xor i32 %b, 1714
  ret i32 %r
}
define internal i32 @f1715(i32 %x) {
  %a = call i32 @f1714(i32 %x)
  %b = call i32 @f857(i32 %a)
  %r = xor i32 %b, 1715
  ret i32 %r
}
define internal i32 @f1716(i32 %x) {
  %a = call i32 @f1715(i32 %x)
  %b = call i32 @f858(i32 %a)
  %r = xor i32 %b, 1716
  ret i32 %r
}
define internal i32 @f1717(i32 %x) {
  %a = call i32 @f1716(i32 %x)
  %b = call i32 @f858(i32 %a)
  %r = xor i32 %b, 1717
  ret i32 %r
}
define internal i32 @f1718(i32 %x) {
  %a = call i32 @f1717(i32 %x)
  %b = call i32 @f859(i32 %a)
  %r = xor i32 %b, 1718
  ret i32 %r
}
define internal i32 @f1719(i32 %x) {
  %a = call i32 @f1718(i32 %x)
  %b = call i32 @f859(i32 %a)
  %r = xor i32 %b, 1719
  ret i32 %r
}
define internal i32 @f1720(i32 %x) {
  %a = call i32 @f1719(i32 %x)
  %b = call i32 @f860(i32 %a)
  %r = xor i32 %b, 1720
  ret i32 %r
}
define internal i32 @f1721(i32 %x) {
  %a = call i32 @f1720(i32 %x)
  %b = call i32 @f860(i32 %a)
  %r = xor i32 %b, 1721
  ret i32 %r
}
define internal i32 @f1722(i32 %x) {
  %a = call i32 @f1721(i32 %x)
  %b = call i32 @f861(i32 %a)
  %r = xor i32 %b, 1722
  ret i32 %r
}
define internal i32 @f1723(i32 %x) {
  %a = call i32 @f1722(i32 %x)
  %b = call i32 @f861(i32 %a)
  %r = xor i32 %b, 1723
  ret i32 %r
}
define internal i32 @f1724(i32 %x) {
  %a = call i32 @f1723(i32 %x)
  %b = call i32 @f862(i32 %a)
  %r = xor i32 %b, 1724
  ret i32 %r
}
define internal i32 @f1725(i32 %x) {
  %a = call i32 @f1724(i32 %x)
  %b = call i32 @f862(i32 %a)
  %r = xor i32 %b, 1725
  ret i32 %r
}
define internal i32 @f1726(i32 %x) {
  %a = call i32 @f1725(i32 %x)
  %b = call i32 @f863(i32 %a)
  %r = xor i32 %b, 1726
  ret i32 %r
}
define internal i32 @f1727(i32 %x) {
  %a = call i32 @f1726(i32 %x)
  %b = call i32 @f863(i32 %a)
  %r = xor i32 %b, 1727
  ret i32 %r
}
define internal i32 @f1728(i32 %x) {
  %a = call i32 @f1727(i32 %x)
  %b = call i32 @f864(i32 %a)
  %r = xor i32 %b, 1728
  ret i32 %r
}
define internal i32 @f1729(i32 %x) {
  %a = call i32 @f1728(i32 %x)
  %b = call i32 @f864(i32 %a)
  %r = xor i32 %b, 1729
  ret i32 %r
}
define internal i32 @f1730(i32 %x) {
  %a = call i32 @f1729(i32 %x)
  %b = call i32 @f865(i32 %a)
  %r = xor i32 %b, 1730
  ret i32 %r
}
define internal i32 @f1731(i32 %x) {
  %a = call i32 @f1730(i32 %x)
  %b = call i32 @f865(i32 %a)
  %r = xor i32 %b, 1731
  ret i32 %r
}
define internal i32 @f1732(i32 %x) {
  %a = call i32 @f1731(i32 %x)
  %b = call i32 @f866(i32 %a)
  %r = xor i32 %b, 1732
  ret i32 %r
}
define internal i32 @f1733(i32 %x) {
  %a = call i32 @f1732(i32 %x)
  %b = call i32 @f866(i32 %a)
  %r = xor i32 %b, 1733
  ret i32 %r
}
define internal i32 @f1734(i32 %x) {
  %a = call i32 @f1733(i32 %x)
  %b = call i32 @f867(i32 %a)
  %r = xor i32 %b, 1734
  ret i32 %r
}
define internal i32 @f1735(i32 %x) {
  %a = call i32 @f1734(i32 %x)
  %b = call i32 @f867(i32 %a)
  %r = xor i32 %b, 1735
  ret i32 %r
}
define internal i32 @f1736(i32 %x) {
  %a = call i32 @f1735(i32 %x)
  %b = call i32 @f868(i32 %a)
  %r = xor i32 %b, 1736
  ret i32 %r
}
define internal i32 @f1737(i32 %x) {
  %a = call i32 @f1736(i32 %x)
  %b = call i32 @f868(i32 %a)
  %r = xor i32 %b, 1737
  ret i32 %r
}
define internal i32 @f1738(i32 %x) {
  %a = call i32 @f1737(i32 %x)
  %b = call i32 @f869(i32 %a)
  %r = xor i32 %b, 1738
  ret i32 %r
}
define internal i32 @f1739(i32 %x) {
  %a = call i32 @f1738(i32 %x)
  %b = call i32 @f869(i32 %a)
  %r = xor i32 %b, 1739
  ret i32 %r
}
define internal i32 @f1740(i32 %x) {
  %a = call i32 @f1739(i32 %x)
  %b = call i32 @f870(i32 %a)
  %r = xor i32 %b, 1740
  ret i32 %r
}
define internal i32 @f1741(i32 %x) {
  %a = call i32 @f1740(i32 %x)
  %b = call i32 @f870(i32 %a)
  %r = xor i32 %b, 1741
  ret i32 %r
}
define internal i32 @f1742(i32 %x) {
  %a = call i32 @f1741(i32 %x)
  %b = call i32 @f871(i32 %a)
  %r = xor i32 %b, 1742
  ret i32 %r
}
define internal i32 @f1743(i32 %x) {
  %a = call i32 @f1742(i32 %x)
  %b = call i32 @f871(i32 %a)
  %r = xor i32 %b, 1743
  ret i32 %r
}
define internal i32 @f1744(i32 %x) {
  %a = call i32 @f1743(i32 %x)
  %b = call i32 @f872(i32 %a)
  %r = xor i32 %b, 1744
  ret i32 %r
}
define internal i32 @f1745(i32 %x) {
  %a = call i32 @f1744(i32 %x)
  %b = call i32 @f872(i32 %a)
  %r = xor i32 %b, 1745
  ret i32 %r
}
define internal i32 @f1746(i32 %x) {
  %a = call i32 @f1745(i32 %x)
  %b = call i32 @f873(i32 %a)
  %r = xor i32 %b, 1746
  ret i32 %r
}
define internal i32 @f1747(i32 %x) {
  %a = call i32 @f1746(i32 %x)
  %b = call i32 @f873(i32 %a)
  %r = xor i32 %b, 1747
  ret i32 %r
}
define internal i32 @f1748(i32 %x) {
  %a = call i32 @f1747(i32 %x)
  %b = call i32 @f874(i32 %a)
  %r = xor i32 %b, 1748
  ret i32 %r
}
define internal i32 @f1749(i32 %x) {
  %a = call i32 @f1748(i32 %x)
  %b = call i32 @f874(i32 %a)
  %r = xor i32 %b, 1749
  ret i32 %r
}
define internal i32 @f1750(i32 %x) {
  %a = call i32 @f1749(i32 %x)
  %b = call i32 @f875(i32 %a)
  %r = xor i32 %b, 1750
  ret i32 %r
}
define internal i32 @f1751(i32 %x) {
  %a = call i32 @f1750(i32 %x)
  %b = call i32 @f875(i32 %a)
  %r = xor i32 %b, 1751
  ret i32 %r
}
define internal i32 @f1752(i32 %x) {
  %a = call i32 @f1751(i32 %x)
  %b = call i32 @f876(i32 %a)
  %r = xor i32 %b, 1752
  ret i32 %r
}
define internal i32 @f1753(i32 %x) {
  %a = call i32 @f1752(i32 %x)
  %b = call i32 @f876(i32 %a)
  %r = xor i32 %b, 1753
  ret i32 %r
}
define internal i32 @f1754(i32 %x) {
  %a = call i32 @f1753(i32 %x)
  %b = call i32 @f877(i32 %a)
  %r = xor i32 %b, 1754
  ret i32 %r
}
define internal i32 @f1755(i32 %x) {
  %a = call i32 @f1754(i32 %x)
  %b = call i32 @f877(i32 %a)
  %r = xor i32 %b, 1755
  ret i32 %r
}
define internal i32 @f1756(i32 %x) {
  %a = call i32 @f1755(i32 %x)
  %b = call i32 @f878(i32 %a)
  %r = xor i32 %b, 1756
  ret i32 %r
}
define internal i32 @f1757(i32 %x) {
  %a = call i32 @f1756(i32 %x)
  %b = call i32 @f878(i32 %a)
  %r = xor i32 %b, 1757
  ret i32 %r
}
define internal i32 @f1758(i32 %x) {
  %a = call i32 @f1757(i32 %x)
  %b = call i32 @f879(i32 %a)
  %r = xor i32 %b, 1758
  ret i32 %r
}
define internal i32 @f1759(i32 %x) {
  %a = call i32 @f1758(i32 %x)
  %b = call i32 @f879(i32 %a)
  %r = xor i32 %b, 1759
  ret i32 %r
}
define internal i32 @f1760(i32 %x) {
  %a = call i32 @f1759(i32 %x)
  %b = call i32 @f880(i32 %a)
  %r = xor i32 %b, 1760
  ret i32 %r
}
define internal i32 @f1761(i32 %x) {
  %a = call i32 @f1760(i32 %x)
  %b = call i32 @f880(i32 %a)
  %r = xor i32 %b, 1761
  ret i32 %r
}
define internal i32 @f1762(i32 %x) {
  %a = call i32 @f1761(i32 %x)
  %b = call i32 @f881(i32 %a)
  %r = xor i32 %b, 1762
  ret i32 %r
}
define internal i32 @f1763(i32 %x) {
  %a = call i32 @f1762(i32 %x)
  %b = call i32 @f881(i32 %a)
  %r = xor i32 %b, 1763
  ret i32 %r
}
define internal i32 @f1764(i32 %x) {
  %a = call i32 @f1763(i32 %x)
  %b = call i32 @f882(i32 %a)
  %r = xor i32 %b, 1764
  ret i32 %r
}
define internal i32 @f1765(i32 %x) {
  %a = call i32 @f1764(i32 %x)
  %b = call i32 @f882(i32 %a)
  %r = xor i32 %b, 1765
  ret i32 %r
}
define internal i32 @f1766(i32 %x) {
  %a = call i32 @f1765(i32 %x)
  %b = call i32 @f883(i32 %a)
  %r = xor i32 %b, 1766
  ret i32 %r
}
define internal i32 @f1767(i32 %x) {
  %a = call i32 @f1766(i32 %x)
  %b = call i32 @f883(i32 %a)
  %r = xor i32 %b, 1767
  ret i32 %r
}
define internal i32 @f1768(i32 %x) {
  %a = call i32 @f1767(i32 %x)
  %b = call i32 @f884(i32 %a)
  %r = xor i32 %b, 1768
  ret i32 %r
}
define internal i32 @f1769(i32 %x) {
  %a = call i32 @f1768(i32 %x)
  %b = call i32 @f884(i32 %a)
  %r = xor i32 %b, 1769
  ret i32 %r
}
define internal i32 @f1770(i32 %x) {
  %a = call i32 @f1769(i32 %x)
  %b = call i32 @f885(i32 %a)
  %r = xor i32 %b, 1770
  ret i32 %r
}
define internal i32 @f1771(i32 %x) {
  %a = call i32 @f1770(i32 %x)
  %b = call i32 @f885(i32 %a)
  %r = xor i32 %b, 1771
  ret i32 %r
}
define internal i32 @f1772(i32 %x) {
  %a = call i32 @f1771(i32 %x)
  %b = call i32 @f886(i32 %a)
  %r = xor i32 %b, 1772
  ret i32 %r
}
define internal i32 @f1773(i32 %x) {
  %a = call i32 @f1772(i32 %x)
  %b = call i32 @f886(i32 %a)
  %r = xor i32 %b, 1773
  ret i32 %r
}
define internal i32 @f1774(i32 %x) {
  %a = call i32 @f1773(i32 %x)
  %b = call i32 @f887(i32 %a)
  %r = xor i32 %b, 1774
  ret i32 %r
}
define internal i32 @f1775(i32 %x) {
  %a = call i32 @f1774(i32 %x)
  %b = call i32 @f887(i32 %a)
  %r = xor i32 %b, 1775
  ret i32 %r
}
define internal i32 @f1776(i32 %x) {
  %a = call i32 @f1775(i32 %x)
  %b = call i32 @f888(i32 %a)
  %r = xor i32 %b, 1776
  ret i32 %r
}
define internal i32 @f1777(i32 %x) {
  %a = call i32 @f1776(i32 %x)
  %b = call i32 @f888(i32 %a)
  %r = xor i32 %b, 1777
  ret i32 %r
}
define internal i32 @f1778(i32 %x) {
  %a = call i32 @f1777(i32 %x)
  %b = call i32 @f889(i32 %a)
  %r = xor i32 %b, 1778
  ret i32 %r
}
define internal i32 @f1779(i32 %x) {
  %a = call i32 @f1778(i32 %x)
  %b = call i32 @f889(i32 %a)
  %r = xor i32 %b, 1779
  ret i32 %r
}
define internal i32 @f1780(i32 %x) {
  %a = call i32 @f1779(i32 %x)
  %b = call i32 @f890(i32 %a)
  %r = xor i32 %b, 1780
  ret i32 %r
}
define internal i32 @f1781(i32 %x) {
  %a = call i32 @f1780(i32 %x)
  %b = call i32 @f890(i32 %a)
  %r = xor i32 %b, 1781
  ret i32 %r
}
define internal i32 @f1782(i32 %x) {
  %a = call i32 @f1781(i32 %x)
  %b = call i32 @f891(i32 %a)
  %r = xor i32 %b, 1782
  ret i32 %r
}
define internal i32 @f1783(i32 %x) {
  %a = call i32 @f1782(i32 %x)
  %b = call i32 @f891(i32 %a)
  %r = xor i32 %b, 1783
  ret i32 %r
}
define internal i32 @f1784(i32 %x) {
  %a = call i32 @f1783(i32 %x)
  %b = call i32 @f892(i32 %a)
  %r = xor i32 %b, 1784
  ret i32 %r
}
define internal i32 @f1785(i32 %x) {
  %a = call i32 @f1784(i32 %x)
  %b = call i32 @f892(i32 %a)
  %r = xor i32 %b, 1785
  ret i32 %r
}
define internal i32 @f1786(i32 %x) {
  %a = call i32 @f1785(i32 %x)
  %b = call i32 @f893(i32 %a)
  %r = xor i32 %b, 1786
  ret i32 %r
}
define internal i32 @f1787(i32 %x) {
  %a = call i32 @f1786(i32 %x)
  %b = call i32 @f893(i32 %a)
  %r = xor i32 %b, 1787
  ret i32 %r
}
define internal i32 @f1788(i32 %x) {
  %a = call i32 @f1787(i32 %x)
  %b = call i32 @f894(i32 %a)
  %r = xor i32 %b, 1788
  ret i32 %r
}
define internal i32 @f1789(i32 %x) {
  %a = call i32 @f1788(i32 %x)
  %b = call i32 @f894(i32 %a)
  %r = xor i32 %b, 1789
  ret i32 %r
}
define internal i32 @f1790(i32 %x) {
  %a = call i32 @f1789(i32 %x)
  %b = call i32 @f895(i32 %a)
  %r = xor i32 %b, 1790
  ret i32 %r
}
define internal i32 @f1791(i32 %x) {
  %a = call i32 @f1790(i32 %x)
  %b = call i32 @f895(i32 %a)
  %r = xor i32 %b, 1791
  ret i32 %r
}
define internal i32 @f1792(i32 %x) {
  %a = call i32 @f1791(i32 %x)
  %b = call i32 @f896(i32 %a)
  %r = xor i32 %b, 1792
  ret i32 %r
}
define internal i32 @f1793(i32 %x) {
  %a = call i32 @f1792(i32 %x)
  %b = call i32 @f896(i32 %a)
  %r = xor i32 %b, 1793
  ret i32 %r
}
define internal i32 @f1794(i32 %x) {
  %a = call i32 @f1793(i32 %x)
  %b = call i32 @f897(i32 %a)
  %r = xor i32 %b, 1794
  ret i32 %r
}
define internal i32 @f1795(i32 %x) {
  %a = call i32 @f1794(i32 %x)
  %b = call i32 @f897(i32 %a)
  %r = xor i32 %b, 1795
  ret i32 %r
}
define internal i32 @f1796(i32 %x) {
  %a = call i32 @f1795(i32 %x)
  %b = call i32 @f898(i32 %a)
  %r = xor i32 %b, 1796
  ret i32 %r
}
define internal i32 @f1797(i32 %x) {
  %a = call i32 @f1796(i32 %x)
  %b = call i32 @f898(i32 %a)
  %r = xor i32 %b, 1797
  ret i32 %r
}
define internal i32 @f1798(i32 %x) {
  %a = call i32 @f1797(i32 %x)
  %b = call i32 @f899(i32 %a)
  %r = xor i32 %b, 1798
  ret i32 %r
}
define internal i32 @f1799(i32 %x) {
  %a = call i32 @f1798(i32 %x)
  %b = call i32 @f899(i32 %a)
  %r = xor i32 %b, 1799
  ret i32 %r
}
define internal i32 @f1800(i32 %x) {
  %a = call i32 @f1799(i32 %x)
  %b = call i32 @f900(i32 %a)
  %r = xor i32 %b, 1800
  ret i32 %r
}
define internal i32 @f1801(i32 %x) {
  %a = call i32 @f1800(i32 %x)
  %b = call i32 @f900(i32 %a)
  %r = xor i32 %b, 1801
  ret i32 %r
}
define internal i32 @f1802(i32 %x) {
  %a = call i32 @f1801(i32 %x)
  %b = call i32 @f901(i32 %a)
  %r = xor i32 %b, 1802
  ret i32 %r
}
define internal i32 @f1803(i32 %x) {
  %a = call i32 @f1802(i32 %x)
  %b = call i32 @f901(i32 %a)
  %r = xor i32 %b, 1803
  ret i32 %r
}
define internal i32 @f1804(i32 %x) {
  %a = call i32 @f1803(i32 %x)
  %b = call i32 @f902(i32 %a)
  %r = xor i32 %b, 1804
  ret i32 %r
}
define internal i32 @f1805(i32 %x) {
  %a = call i32 @f1804(i32 %x)
  %b = call i32 @f902(i32 %a)
  %r = xor i32 %b, 1805
  ret i32 %r
}
define internal i32 @f1806(i32 %x) {
  %a = call i32 @f1805(i32 %x)
  %b = call i32 @f903(i32 %a)
  %r = xor i32 %b, 1806
  ret i32 %r
}
define internal i32 @f1807(i32 %x) {
  %a = call i32 @f1806(i32 %x)
  %b = call i32 @f903(i32 %a)
  %r = xor i32 %b, 1807
  ret i32 %r
}
define internal i32 @f1808(i32 %x) {
  %a = call i32 @f1807(i32 %x)
  %b = call i32 @f904(i32 %a)
  %r = xor i32 %b, 1808
  ret i32 %r
}
define internal i32 @f1809(i32 %x) {
  %a = call i32 @f1808(i32 %x)
  %b = call i32 @f904(i32 %a)
  %r = xor i32 %b, 1809
  ret i32 %r
}
define internal i32 @f1810(i32 %x) {
  %a = call i32 @f1809(i32 %x)
  %b = call i32 @f905(i32 %a)
  %r = xor i32 %b, 1810
  ret i32 %r
}
define internal i32 @f1811(i32 %x) {
  %a = call i32 @f1810(i32 %x)
  %b = call i32 @f905(i32 %a)
  %r = xor i32 %b, 1811
  ret i32 %r
}
define internal i32 @f1812(i32 %x) {
  %a = call i32 @f1811(i32 %x)
  %b = call i32 @f906(i32 %a)
  %r = xor i32 %b, 1812
  ret i32 %r
}
define internal i32 @f1813(i32 %x) {
  %a = call i32 @f1812(i32 %x)
  %b = call i32 @f906(i32 %a)
  %r = xor i32 %b, 1813
  ret i32 %r
}
define internal i32 @f1814(i32 %x) {
  %a = call i32 @f1813(i32 %x)
  %b = call i32 @f907(i32 %a)
  %r = xor i32 %b, 1814
  ret i32 %r
}
define internal i32 @f1815(i32 %x) {
  %a = call i32 @f1814(i32 %x)
  %b = call i32 @f907(i32 %a)
  %r = xor i32 %b, 1815
  ret i32 %r
}
define internal i32 @f1816(i32 %x) {
  %a = call i32 @f1815(i32 %x)
  %b = call i32 @f908(i32 %a)
  %r = xor i32 %b, 1816
  ret i32 %r
}
define internal i32 @f1817(i32 %x) {
  %a = call i32 @f1816(i32 %x)
  %b = call i32 @f908(i32 %a)
  %r = xor i32 %b, 1817
  ret i32 %r
}
define internal i32 @f1818(i32 %x) {
  %a = call i32 @f1817(i32 %x)
  %b = call i32 @f909(i32 %a)
  %r = xor i32 %b, 1818
  ret i32 %r
}
define internal i32 @f1819(i32 %x) {
  %a = call i32 @f1818(i32 %x)
  %b = call i32 @f909(i32 %a)
  %r = xor i32 %b, 1819
  ret i32 %r
}
define internal i32 @f1820(i32 %x) {
  %a = call i32 @f1819(i32 %x)
  %b = call i32 @f910(i32 %a)
  %r = xor i32 %b, 1820
  ret i32 %r
}
define internal i32 @f1821(i32 %x) {
  %a = call i32 @f1820(i32 %x)
  %b = call i32 @f910(i32 %a)
  %r = xor i32 %b, 1821
  ret i32 %r
}
define internal i32 @f1822(i32 %x) {
  %a = call i32 @f1821(i32 %x)
  %b = call i32 @f911(i32 %a)
  %r = xor i32 %b, 1822
  ret i32 %r
}
define internal i32 @f1823(i32 %x) {
  %a = call i32 @f1822(i32 %x)
  %b = call i32 @f911(i32 %a)
  %r = xor i32 %b, 1823
  ret i32 %r
}
define internal i32 @f1824(i32 %x) {
  %a = call i32 @f1823(i32 %x)
  %b = call i32 @f912(i32 %a)
  %r = xor i32 %b, 1824
  ret i32 %r
}
define internal i32 @f1825(i32 %x) {
  %a = call i32 @f1824(i32 %x)
  %b = call i32 @f912(i32 %a)
  %r = xor i32 %b, 1825
  ret i32 %r
}
define internal i32 @f1826(i32 %x) {
  %a = call i32 @f1825(i32 %x)
  %b = call i32 @f913(i32 %a)
  %r = xor i32 %b, 1826
  ret i32 %r
}
define internal i32 @f1827(i32 %x) {
  %a = call i32 @f1826(i32 %x)
  %b = call i32 @f913(i32 %a)
  %r = xor i32 %b, 1827
  ret i32 %r
}
define internal i32 @f1828(i32 %x) {
  %a = call i32 @f1827(i32 %x)
  %b = call i32 @f914(i32 %a)
  %r = xor i32 %b, 1828
  ret i32 %r
}
define internal i32 @f1829(i32 %x) {
  %a = call i32 @f1828(i32 %x)
  %b = call i32 @f914(i32 %a)
  %r = xor i32 %b, 1829
  ret i32 %r
}
define internal i32 @f1830(i32 %x) {
  %a = call i32 @f1829(i32 %x)
  %b = call i32 @f915(i32 %a)
  %r = xor i32 %b, 1830
  ret i32 %r
}
define internal i32 @f1831(i32 %x) {
  %a = call i32 @f1830(i32 %x)
  %b = call i32 @f915(i32 %a)
  %r = xor i32 %b, 1831
  ret i32 %r
}
define internal i32 @f1832(i32 %x) {
  %a = call i32 @f1831(i32 %x)
  %b = call i32 @f916(i32 %a)
  %r = xor i32 %b, 1832
  ret i32 %r
}
define internal i32 @f1833(i32 %x) {
  %a = call i32 @f1832(i32 %x)
  %b = call i32 @f916(i32 %a)
  %r = xor i32 %b, 1833
  ret i32 %r
}
define internal i32 @f1834(i32 %x) {
  %a = call i32 @f1833(i32 %x)
  %b = call i32 @f917(i32 %a)
  %r = xor i32 %b, 1834
  ret i32 %r
}
define internal i32 @f1835(i32 %x) {
  %a = call i32 @f1834(i32 %x)
  %b = call i32 @f917(i32 %a)
  %r = xor i32 %b, 1835
  ret i32 %r
}
define internal i32 @f1836(i32 %x) {
  %a = call i32 @f1835(i32 %x)
  %b = call i32 @f918(i32 %a)
  %r = xor i32 %b, 1836
  ret i32 %r
}
define internal i32 @f1837(i32 %x) {
  %a = call i32 @f1836(i32 %x)
  %b = call i32 @f918(i32 %a)
  %r = xor i32 %b, 1837
  ret i32 %r
}
define internal i32 @f1838(i32 %x) {
  %a = call i32 @f1837(i32 %x)
  %b = call i32 @f919(i32 %a)
  %r = xor i32 %b, 1838
  ret i32 %r
}
define internal i32 @f1839(i32 %x) {
  %a = call i32 @f1838(i32 %x)
  %b = call i32 @f919(i32 %a)
  %r = xor i32 %b, 1839
  ret i32 %r
}
define internal i32 @f1840(i32 %x) {
  %a = call i32 @f1839(i32 %x)
  %b = call i32 @f920(i32 %a)
  %r = xor i32 %b, 1840
  ret i32 %r
}
define internal i32 @f1841(i32 %x) {
  %a = call i32 @f1840(i32 %x)
  %b = call i32 @f920(i32 %a)
  %r = xor i32 %b, 1841
  ret i32 %r
}
define internal i32 @f1842(i32 %x) {
  %a = call i32 @f1841(i32 %x)
  %b = call i32 @f921(i32 %a)
  %r = xor i32 %b, 1842
  ret i32 %r
}
define internal i32 @f1843(i32 %x) {
  %a = call i32 @f1842(i32 %x)
  %b = call i32 @f921(i32 %a)
  %r = xor i32 %b, 1843
  ret i32 %r
}
define internal i32 @f1844(i32 %x) {
  %a = call i32 @f1843(i32 %x)
  %b = call i32 @f922(i32 %a)
  %r = xor i32 %b, 1844
  ret i32 %r
}
define internal i32 @f1845(i32 %x) {
  %a = call i32 @f1844(i32 %x)
  %b = call i32 @f922(i32 %a)
  %r = xor i32 %b, 1845
  ret i32 %r
}
define internal i32 @f1846(i32 %x) {
  %a = call i32 @f1845(i32 %x)
  %b = call i32 @f923(i32 %a)
  %r = xor i32 %b, 1846
  ret i32 %r
}
define internal i32 @f1847(i32 %x) {
  %a = call i32 @f1846(i32 %x)
  %b = call i32 @f923(i32 %a)
  %r = xor i32 %b, 1847
  ret i32 %r
}
define internal i32 @f1848(i32 %x) {
  %a = call i32 @f1847(i32 %x)
  %b = call i32 @f924(i32 %a)
  %r = xor i32 %b, 1848
  ret i32 %r
}
define internal i32 @f1849(i32 %x) {
  %a = call i32 @f1848(i32 %x)
  %b = call i32 @f924(i32 %a)
  %r = xor i32 %b, 1849
  ret i32 %r
}
define internal i32 @f1850(i32 %x) {
  %a = call i32 @f1849(i32 %x)
  %b = call i32 @f925(i32 %a)
  %r = xor i32 %b, 1850
  ret i32 %r
}
define internal i32 @f1851(i32 %x) {
  %a = call i32 @f1850(i32 %x)
  %b = call i32 @f925(i32 %a)
  %r = xor i32 %b, 1851
  ret i32 %r
}
define internal i32 @f1852(i32 %x) {
  %a = call i32 @f1851(i32 %x)
  %b = call i32 @f926(i32 %a)
  %r = xor i32 %b, 1852
  ret i32 %r
}
define internal i32 @f1853(i32 %x) {
  %a = call i32 @f1852(i32 %x)
  %b = call i32 @f926(i32 %a)
  %r = xor i32 %b, 1853
  ret i32 %r
}
define internal i32 @f1854(i32 %x) {
  %a = call i32 @f1853(i32 %x)
  %b = call i32 @f927(i32 %a)
  %r = xor i32 %b, 1854
  ret i32 %r
}
define internal i32 @f1855(i32 %x) {
  %a = call i32 @f1854(i32 %x)
  %b = call i32 @f927(i32 %a)
  %r = xor i32 %b, 1855
  ret i32 %r
}
define internal i32 @f1856(i32 %x) {
  %a = call i32 @f1855(i32 %x)
  %b = call i32 @f928(i32 %a)
  %r = xor i32 %b, 1856
  ret i32 %r
}
define internal i32 @f1857(i32 %x) {
  %a = call i32 @f1856(i32 %x)
  %b = call i32 @f928(i32 %a)
  %r = xor i32 %b, 1857
  ret i32 %r
}
define internal i32 @f1858(i32 %x) {
  %a = call i32 @f1857(i32 %x)
  %b = call i32 @f929(i32 %a)
  %r = xor i32 %b, 1858
  ret i32 %r
}
define internal i32 @f1859(i32 %x) {
  %a = call i32 @f1858(i32 %x)
  %b = call i32 @f929(i32 %a)
  %r = xor i32 %b, 1859
  ret i32 %r
}
define internal i32 @f1860(i32 %x) {
  %a = call i32 @f1859(i32 %x)
  %b = call i32 @f930(i32 %a)
  %r = xor i32 %b, 1860
  ret i32 %r
}
define internal i32 @f1861(i32 %x) {
  %a = call i32 @f1860(i32 %x)
  %b = call i32 @f930(i32 %a)
  %r = xor i32 %b, 1861
  ret i32 %r
}
define internal i32 @f1862(i32 %x) {
  %a = call i32 @f1861(i32 %x)
  %b = call i32 @f931(i32 %a)
  %r = xor i32 %b, 1862
  ret i32 %r
}
define internal i32 @f1863(i32 %x) {
  %a = call i32 @f1862(i32 %x)
  %b = call i32 @f931(i32 %a)
  %r = xor i32 %b, 1863
  ret i32 %r
}
define internal i32 @f1864(i32 %x) {
  %a = call i32 @f1863(i32 %x)
  %b = call i32 @f932(i32 %a)
  %r = xor i32 %b, 1864
  ret i32 %r
}
define internal i32 @f1865(i32 %x) {
  %a = call i32 @f1864(i32 %x)
  %b = call i32 @f932(i32 %a)
  %r = xor i32 %b, 1865
  ret i32 %r
}
define internal i32 @f1866(i32 %x) {
  %a = call i32 @f1865(i32 %x)
  %b = call i32 @f933(i32 %a)
  %r = xor i32 %b, 1866
  ret i32 %r
}
define internal i32 @f1867(i32 %x) {
  %a = call i32 @f1866(i32 %x)
  %b = call i32 @f933(i32 %a)
  %r = xor i32 %b, 1867
  ret i32 %r
}
define internal i32 @f1868(i32 %x) {
  %a = call i32 @f1867(i32 %x)
  %b = call i32 @f934(i32 %a)
  %r = xor i32 %b, 1868
  ret i32 %r
}
define internal i32 @f1869(i32 %x) {
  %a = call i32 @f1868(i32 %x)
  %b = call i32 @f934(i32 %a)
  %r = xor i32 %b, 1869
  ret i32 %r
}
define internal i32 @f1870(i32 %x) {
  %a = call i32 @f1869(i32 %x)
  %b = call i32 @f935(i32 %a)
  %r = xor i32 %b, 1870
  ret i32 %r
}
define internal i32 @f1871(i32 %x) {
  %a = call i32 @f1870(i32 %x)
  %b = call i32 @f935(i32 %a)
  %r = xor i32 %b, 1871
  ret i32 %r
}
define internal i32 @f1872(i32 %x) {
  %a = call i32 @f1871(i32 %x)
  %b = call i32 @f936(i32 %a)
  %r = xor i32 %b, 1872
  ret i32 %r
}
define internal i32 @f1873(i32 %x) {
  %a = call i32 @f1872(i32 %x)
  %b = call i32 @f936(i32 %a)
  %r = xor i32 %b, 1873
  ret i32 %r
}
define internal i32 @f1874(i32 %x) {
  %a = call i32 @f1873(i32 %x)
  %b = call i32 @f937(i32 %a)
  %r = xor i32 %b, 1874
  ret i32 %r
}
define internal i32 @f1875(i32 %x) {
  %a = call i32 @f1874(i32 %x)
  %b = call i32 @f937(i32 %a)
  %r = xor i32 %b, 1875
  ret i32 %r
}
define internal i32 @f1876(i32 %x) {
  %a = call i32 @f1875(i32 %x)
  %b = call i32 @f938(i32 %a)
  %r = xor i32 %b, 1876
  ret i32 %r
}
define internal i32 @f1877(i32 %x) {
  %a = call i32 @f1876(i32 %x)
  %b = call i32 @f938(i32 %a)
  %r = xor i32 %b, 1877
  ret i32 %r
}
define internal i32 @f1878(i32 %x) {
  %a = call i32 @f1877(i32 %x)
  %b = call i32 @f939(i32 %a)
  %r = xor i32 %b, 1878
  ret i32 %r
}
define internal i32 @f1879(i32 %x) {
  %a = call i32 @f1878(i32 %x)
  %b = call i32 @f939(i32 %a)
  %r = xor i32 %b, 1879
  ret i32 %r
}
define internal i32 @f1880(i32 %x) {
  %a = call i32 @f1879(i32 %x)
  %b = call i32 @f940(i32 %a)
  %r = xor i32 %b, 1880
  ret i32 %r
}
define internal i32 @f1881(i32 %x) {
  %a = call i32 @f1880(i32 %x)
  %b = call i32 @f940(i32 %a)
  %r = xor i32 %b, 1881
  ret i32 %r
}
define internal i32 @f1882(i32 %x) {
  %a = call i32 @f1881(i32 %x)
  %b = call i32 @f941(i32 %a)
  %r = xor i32 %b, 1882
  ret i32 %r
}
define internal i32 @f1883(i32 %x) {
  %a = call i32 @f1882(i32 %x)
  %b = call i32 @f941(i32 %a)
  %r = xor i32 %b, 1883
  ret i32 %r
}
define internal i32 @f1884(i32 %x) {
  %a = call i32 @f1883(i32 %x)
  %b = call i32 @f942(i32 %a)
  %r = xor i32 %b, 1884
  ret i32 %r
}
define internal i32 @f1885(i32 %x) {
  %a = call i32 @f1884(i32 %x)
  %b = call i32 @f942(i32 %a)
  %r = xor i32 %b, 1885
  ret i32 %r
}
define internal i32 @f1886(i32 %x) {
  %a = call i32 @f1885(i32 %x)
  %b = call i32 @f943(i32 %a)
  %r = xor i32 %b, 1886
  ret i32 %r
}
define internal i32 @f1887(i32 %x) {
  %a = call i32 @f1886(i32 %x)
  %b = call i32 @f943(i32 %a)
  %r = xor i32 %b, 1887
  ret i32 %r
}
define internal i32 @f1888(i32 %x) {
  %a = call i32 @f1887(i32 %x)
  %b = call i32 @f944(i32 %a)
  %r = xor i32 %b, 1888
  ret i32 %r
}
define internal i32 @f1889(i32 %x) {
  %a = call i32 @f1888(i32 %x)
  %b = call i32 @f944(i32 %a)
  %r = xor i32 %b, 1889
  ret i32 %r
}
define internal i32 @f1890(i32 %x) {
  %a = call i32 @f1889(i32 %x)
  %b = call i32 @f945(i32 %a)
  %r = xor i32 %b, 1890
  ret i32 %r
}
define internal i32 @f1891(i32 %x) {
  %a = call i32 @f1890(i32 %x)
  %b = call i32 @f945(i32 %a)
  %r = xor i32 %b, 1891
  ret i32 %r
}
define internal i32 @f1892(i32 %x) {
  %a = call i32 @f1891(i32 %x)
  %b = call i32 @f946(i32 %a)
  %r = xor i32 %b, 1892
  ret i32 %r
}
define internal i32 @f1893(i32 %x) {
  %a = call i32 @f1892(i32 %x)
  %b = call i32 @f946(i32 %a)
  %r = xor i32 %b, 1893
  ret i32 %r
}
define internal i32 @f1894(i32 %x) {
  %a = call i32 @f1893(i32 %x)
  %b = call i32 @f947(i32 %a)
  %r = xor i32 %b, 1894
  ret i32 %r
}
define internal i32 @f1895(i32 %x) {
  %a = call i32 @f1894(i32 %x)
  %b = call i32 @f947(i32 %a)
  %r = xor i32 %b, 1895
  ret i32 %r
}
define internal i32 @f1896(i32 %x) {
  %a = call i32 @f1895(i32 %x)
  %b = call i32 @f948(i32 %a)
  %r = xor i32 %b, 1896
  ret i32 %r
}
define internal i32 @f1897(i32 %x) {
  %a = call i32 @f1896(i32 %x)
  %b = call i32 @f948(i32 %a)
  %r = xor i32 %b, 1897
  ret i32 %r
}
define internal i32 @f1898(i32 %x) {
  %a = call i32 @f1897(i32 %x)
  %b = call i32 @f949(i32 %a)
  %r = xor i32 %b, 1898
  ret i32 %r
}
define internal i32 @f1899(i32 %x) {
  %a = call i32 @f1898(i32 %x)
  %b = call i32 @f949(i32 %a)
  %r = xor i32 %b, 1899
  ret i32 %r
}
define internal i32 @f1900(i32 %x) {
  %a = call i32 @f1899(i32 %x)
  %b = call i32 @f950(i32 %a)
  %r = xor i32 %b, 1900
  ret i32 %r
}
define internal i32 @f1901(i32 %x) {
  %a = call i32 @f1900(i32 %x)
  %b = call i32 @f950(i32 %a)
  %r = xor i32 %b, 1901
  ret i32 %r
}
define internal i32 @f1902(i32 %x) {
  %a = call i32 @f1901(i32 %x)
  %b = call i32 @f951(i32 %a)
  %r = xor i32 %b, 1902
  ret i32 %r
}
define internal i32 @f1903(i32 %x) {
  %a = call i32 @f1902(i32 %x)
  %b = call i32 @f951(i32 %a)
  %r = xor i32 %b, 1903
  ret i32 %r
}
define internal i32 @f1904(i32 %x) {
  %a = call i32 @f1903(i32 %x)
  %b = call i32 @f952(i32 %a)
  %r = xor i32 %b, 1904
  ret i32 %r
}
define internal i32 @f1905(i32 %x) {
  %a = call i32 @f1904(i32 %x)
  %b = call i32 @f952(i32 %a)
  %r = xor i32 %b, 1905
  ret i32 %r
}
define internal i32 @f1906(i32 %x) {
  %a = call i32 @f1905(i32 %x)
  %b = call i32 @f953(i32 %a)
  %r = xor i32 %b, 1906
  ret i32 %r
}
define internal i32 @f1907(i32 %x) {
  %a = call i32 @f1906(i32 %x)
  %b = call i32 @f953(i32 %a)
  %r = xor i32 %b, 1907
  ret i32 %r
}
define internal i32 @f1908(i32 %x) {
  %a = call i32 @f1907(i32 %x)
  %b = call i32 @f954(i32 %a)
  %r = xor i32 %b, 1908
  ret i32 %r
}
define internal i32 @f1909(i32 %x) {
  %a = call i32 @f1908(i32 %x)
  %b = call i32 @f954(i32 %a)
  %r = xor i32 %b, 1909
  ret i32 %r
}
define internal i32 @f1910(i32 %x) {
  %a = call i32 @f1909(i32 %x)
  %b = call i32 @f955(i32 %a)
  %r = xor i32 %b, 1910
  ret i32 %r
}
define internal i32 @f1911(i32 %x) {
  %a = call i32 @f1910(i32 %x)
  %b = call i32 @f955(i32 %a)
  %r = xor i32 %b, 1911
  ret i32 %r
}
define internal i32 @f1912(i32 %x) {
  %a = call i32 @f1911(i32 %x)
  %b = call i32 @f956(i32 %a)
  %r = xor i32 %b, 1912
  ret i32 %r
}
define internal i32 @f1913(i32 %x) {
  %a = call i32 @f1912(i32 %x)
  %b = call i32 @f956(i32 %a)
  %r = xor i32 %b, 1913
  ret i32 %r
}
define internal i32 @f1914(i32 %x) {
  %a = call i32 @f1913(i32 %x)
  %b = call i32 @f957(i32 %a)
  %r = xor i32 %b, 1914
  ret i32 %r
}
define internal i32 @f1915(i32 %x) {
  %a = call i32 @f1914(i32 %x)
  %b = call i32 @f957(i32 %a)
  %r = xor i32 %b, 1915
  ret i32 %r
}
define internal i32 @f1916(i32 %x) {
  %a = call i32 @f1915(i32 %x)
  %b = call i32 @f958(i32 %a)
  %r = xor i32 %b, 1916
  ret i32 %r
}
define internal i32 @f1917(i32 %x) {
  %a = call i32 @f1916(i32 %x)
  %b = call i32 @f958(i32 %a)
  %r = xor i32 %b, 1917
  ret i32 %r
}
define internal i32 @f1918(i32 %x) {
  %a = call i32 @f1917(i32 %x)
  %b = call i32 @f959(i32 %a)
  %r = xor i32 %b, 1918
  ret i32 %r
}
define internal i32 @f1919(i32 %x) {
  %a = call i32 @f1918(i32 %x)
  %b = call i32 @f959(i32 %a)
  %r = xor i32 %b, 1919
  ret i32 %r
}
define internal i32 @f1920(i32 %x) {
  %a = call i32 @f1919(i32 %x)
  %b = call i32 @f960(i32 %a)
  %r = xor i32 %b, 1920
  ret i32 %r
}
define internal i32 @f1921(i32 %x) {
  %a = call i32 @f1920(i32 %x)
  %b = call i32 @f960(i32 %a)
  %r = xor i32 %b, 1921
  ret i32 %r
}
define internal i32 @f1922(i32 %x) {
  %a = call i32 @f1921(i32 %x)
  %b = call i32 @f961(i32 %a)
  %r = xor i32 %b, 1922
  ret i32 %r
}
define internal i32 @f1923(i32 %x) {
  %a = call i32 @f1922(i32 %x)
  %b = call i32 @f961(i32 %a)
  %r = xor i32 %b, 1923
  ret i32 %r
}
define internal i32 @f1924(i32 %x) {
  %a = call i32 @f1923(i32 %x)
  %b = call i32 @f962(i32 %a)
  %r = xor i32 %b, 1924
  ret i32 %r
}
define internal i32 @f1925(i32 %x) {
  %a = call i32 @f1924(i32 %x)
  %b = call i32 @f962(i32 %a)
  %r = xor i32 %b, 1925
  ret i32 %r
}
define internal i32 @f1926(i32 %x) {
  %a = call i32 @f1925(i32 %x)
  %b = call i32 @f963(i32 %a)
  %r = xor i32 %b, 1926
  ret i32 %r
}
define internal i32 @f1927(i32 %x) {
  %a = call i32 @f1926(i32 %x)
  %b = call i32 @f963(i32 %a)
  %r = xor i32 %b, 1927
  ret i32 %r
}
define internal i32 @f1928(i32 %x) {
  %a = call i32 @f1927(i32 %x)
  %b = call i32 @f964(i32 %a)
  %r = xor i32 %b, 1928
  ret i32 %r
}
define internal i32 @f1929(i32 %x) {
  %a = call i32 @f1928(i32 %x)
  %b = call i32 @f964(i32 %a)
  %r = xor i32 %b, 1929
  ret i32 %r
}
define internal i32 @f1930(i32 %x) {
  %a = call i32 @f1929(i32 %x)
  %b = call i32 @f965(i32 %a)
  %r = xor i32 %b, 1930
  ret i32 %r
}
define internal i32 @f1931(i32 %x) {
  %a = call i32 @f1930(i32 %x)
  %b = call i32 @f965(i32 %a)
  %r = xor i32 %b, 1931
  ret i32 %r
}
define internal i32 @f1932(i32 %x) {
  %a = call i32 @f1931(i32 %x)
  %b = call i32 @f966(i32 %a)
  %r = xor i32 %b, 1932
  ret i32 %r
}
define internal i32 @f1933(i32 %x) {
  %a = call i32 @f1932(i32 %x)
  %b = call i32 @f966(i32 %a)
  %r = xor i32 %b, 1933
  ret i32 %r
}
define internal i32 @f1934(i32 %x) {
  %a = call i32 @f1933(i32 %x)
  %b = call i32 @f967(i32 %a)
  %r = xor i32 %b, 1934
  ret i32 %r
}
define internal i32 @f1935(i32 %x) {
  %a = call i32 @f1934(i32 %x)
  %b = call i32 @f967(i32 %a)
  %r = xor i32 %b, 1935
  ret i32 %r
}
define internal i32 @f1936(i32 %x) {
  %a = call i32 @f1935(i32 %x)
  %b = call i32 @f968(i32 %a)
  %r = xor i32 %b, 1936
  ret i32 %r
}
define internal i32 @f1937(i32 %x) {
  %a = call i32 @f1936(i32 %x)
  %b = call i32 @f968(i32 %a)
  %r = xor i32 %b, 1937
  ret i32 %r
}
define internal i32 @f1938(i32 %x) {
  %a = call i32 @f1937(i32 %x)
  %b = call i32 @f969(i32 %a)
  %r = xor i32 %b, 1938
  ret i32 %r
}
define internal i32 @f1939(i32 %x) {
  %a = call i32 @f1938(i32 %x)
  %b = call i32 @f969(i32 %a)
  %r = xor i32 %b, 1939
  ret i32 %r
}
define internal i32 @f1940(i32 %x) {
  %a = call i32 @f1939(i32 %x)
  %b = call i32 @f970(i32 %a)
  %r = xor i32 %b, 1940
  ret i32 %r
}
define internal i32 @f1941(i32 %x) {
  %a = call i32 @f1940(i32 %x)
  %b = call i32 @f970(i32 %a)
  %r = xor i32 %b, 1941
  ret i32 %r
}
define internal i32 @f1942(i32 %x) {
  %a = call i32 @f1941(i32 %x)
  %b = call i32 @f971(i32 %a)
  %r = xor i32 %b, 1942
  ret i32 %r
}
define internal i32 @f1943(i32 %x) {
  %a = call i32 @f1942(i32 %x)
  %b = call i32 @f971(i32 %a)
  %r = xor i32 %b, 1943
  ret i32 %r
}
define internal i32 @f1944(i32 %x) {
  %a = call i32 @f1943(i32 %x)
  %b = call i32 @f972(i32 %a)
  %r = xor i32 %b, 1944
  ret i32 %r
}
define internal i32 @f1945(i32 %x) {
  %a = call i32 @f1944(i32 %x)
  %b = call i32 @f972(i32 %a)
  %r = xor i32 %b, 1945
  ret i32 %r
}
define internal i32 @f1946(i32 %x) {
  %a = call i32 @f1945(i32 %x)
  %b = call i32 @f973(i32 %a)
  %r = xor i32 %b, 1946
  ret i32 %r
}
define internal i32 @f1947(i32 %x) {
  %a = call i32 @f1946(i32 %x)
  %b = call i32 @f973(i32 %a)
  %r = xor i32 %b, 1947
  ret i32 %r
}
define internal i32 @f1948(i32 %x) {
  %a = call i32 @f1947(i32 %x)
  %b = call i32 @f974(i32 %a)
  %r = xor i32 %b, 1948
  ret i32 %r
}
define internal i32 @f1949(i32 %x) {
  %a = call i32 @f1948(i32 %x)
  %b = call i32 @f974(i32 %a)
  %r = xor i32 %b, 1949
  ret i32 %r
}
define internal i32 @f1950(i32 %x) {
  %a = call i32 @f1949(i32 %x)
  %b = call i32 @f975(i32 %a)
  %r = xor i32 %b, 1950
  ret i32 %r
}
define internal i32 @f1951(i32 %x) {
  %a = call i32 @f1950(i32 %x)
  %b = call i32 @f975(i32 %a)
  %r = xor i32 %b, 1951
  ret i32 %r
}
define internal i32 @f1952(i32 %x) {
  %a = call i32 @f1951(i32 %x)
  %b = call i32 @f976(i32 %a)
  %r = xor i32 %b, 1952
  ret i32 %r
}
define internal i32 @f1953(i32 %x) {
  %a = call i32 @f1952(i32 %x)
  %b = call i32 @f976(i32 %a)
  %r = xor i32 %b, 1953
  ret i32 %r
}
define internal i32 @f1954(i32 %x) {
  %a = call i32 @f1953(i32 %x)
  %b = call i32 @f977(i32 %a)
  %r = xor i32 %b, 1954
  ret i32 %r
}
define internal i32 @f1955(i32 %x) {
  %a = call i32 @f1954(i32 %x)
  %b = call i32 @f977(i32 %a)
  %r = xor i32 %b, 1955
  ret i32 %r
}
define internal i32 @f1956(i32 %x) {
  %a = call i32 @f1955(i32 %x)
  %b = call i32 @f978(i32 %a)
  %r = xor i32 %b, 1956
  ret i32 %r
}
define internal i32 @f1957(i32 %x) {
  %a = call i32 @f1956(i32 %x)
  %b = call i32 @f978(i32 %a)
  %r = xor i32 %b, 1957
  ret i32 %r
}
define internal i32 @f1958(i32 %x) {
  %a = call i32 @f1957(i32 %x)
  %b = call i32 @f979(i32 %a)
  %r = xor i32 %b, 1958
  ret i32 %r
}
define internal i32 @f1959(i32 %x) {
  %a = call i32 @f1958(i32 %x)
  %b = call i32 @f979(i32 %a)
  %r = xor i32 %b, 1959
  ret i32 %r
}
define internal i32 @f1960(i32 %x) {
  %a = call i32 @f1959(i32 %x)
  %b = call i32 @f980(i32 %a)
  %r = xor i32 %b, 1960
  ret i32 %r
}
define internal i32 @f1961(i32 %x) {
  %a = call i32 @f1960(i32 %x)
  %b = call i32 @f980(i32 %a)
  %r = xor i32 %b, 1961
  ret i32 %r
}
define internal i32 @f1962(i32 %x) {
  %a = call i32 @f1961(i32 %x)
  %b = call i32 @f981(i32 %a)
  %r = xor i32 %b, 1962
  ret i32 %r
}
define internal i32 @f1963(i32 %x) {
  %a = call i32 @f1962(i32 %x)
  %b = call i32 @f981(i32 %a)
  %r = xor i32 %b, 1963
  ret i32 %r
}
define internal i32 @f1964(i32 %x) {
  %a = call i32 @f1963(i32 %x)
  %b = call i32 @f982(i32 %a)
  %r = xor i32 %b, 1964
  ret i32 %r
}
define internal i32 @f1965(i32 %x) {
  %a = call i32 @f1964(i32 %x)
  %b = call i32 @f982(i32 %a)
  %r = xor i32 %b, 1965
  ret i32 %r
}
define internal i32 @f1966(i32 %x) {
  %a = call i32 @f1965(i32 %x)
  %b = call i32 @f983(i32 %a)
  %r = xor i32 %b, 1966
  ret i32 %r
}
define internal i32 @f1967(i32 %x) {
  %a = call i32 @f1966(i32 %x)
  %b = call i32 @f983(i32 %a)
  %r = xor i32 %b, 1967
  ret i32 %r
}
define internal i32 @f1968(i32 %x) {
  %a = call i32 @f1967(i32 %x)
  %b = call i32 @f984(i32 %a)
  %r = xor i32 %b, 1968
  ret i32 %r
}
define internal i32 @f1969(i32 %x) {
  %a = call i32 @f1968(i32 %x)
  %b = call i32 @f984(i32 %a)
  %r = xor i32 %b, 1969
  ret i32 %r
}
define internal i32 @f1970(i32 %x) {
  %a = call i32 @f1969(i32 %x)
  %b = call i32 @f985(i32 %a)
  %r = xor i32 %b, 1970
  ret i32 %r
}
define internal i32 @f1971(i32 %x) {
  %a = call i32 @f1970(i32 %x)
  %b = call i32 @f985(i32 %a)
  %r = xor i32 %b, 1971
  ret i32 %r
}
define internal i32 @f1972(i32 %x) {
  %a = call i32 @f1971(i32 %x)
  %b = call i32 @f986(i32 %a)
  %r = xor i32 %b, 1972
  ret i32 %r
}
define internal i32 @f1973(i32 %x) {
  %a = call i32 @f1972(i32 %x)
  %b = call i32 @f986(i32 %a)
  %r = xor i32 %b, 1973
  ret i32 %r
}
define internal i32 @f1974(i32 %x) {
  %a = call i32 @f1973(i32 %x)
  %b = call i32 @f987(i32 %a)
  %r = xor i32 %b, 1974
  ret i32 %r
}
define internal i32 @f1975(i32 %x) {
  %a = call i32 @f1974(i32 %x)
  %b = call i32 @f987(i32 %a)
  %r = xor i32 %b, 1975
  ret i32 %r
}
define internal i32 @f1976(i32 %x) {
  %a = call i32 @f1975(i32 %x)
  %b = call i32 @f988(i32 %a)
  %r = xor i32 %b, 1976
  ret i32 %r
}
define internal i32 @f1977(i32 %x) {
  %a = call i32 @f1976(i32 %x)
  %b = call i32 @f988(i32 %a)
  %r = xor i32 %b, 1977
  ret i32 %r
}
define internal i32 @f1978(i32 %x) {
  %a = call i32 @f1977(i32 %x)
  %b = call i32 @f989(i32 %a)
  %r = xor i32 %b, 1978
  ret i32 %r
}
define internal i32 @f1979(i32 %x) {
  %a = call i32 @f1978(i32 %x)
  %b = call i32 @f989(i32 %a)
  %r = xor i32 %b, 1979
  ret i32 %r
}
define internal i32 @f1980(i32 %x) {
  %a = call i32 @f1979(i32 %x)
  %b = call i32 @f990(i32 %a)
  %r = xor i32 %b, 1980
  ret i32 %r
}
define internal i32 @f1981(i32 %x) {
  %a = call i32 @f1980(i32 %x)
  %b = call i32 @f990(i32 %a)
  %r = xor i32 %b, 1981
  ret i32 %r
}
define internal i32 @f1982(i32 %x) {
  %a = call i32 @f1981(i32 %x)
  %b = call i32 @f991(i32 %a)
  %r = xor i32 %b, 1982
  ret i32 %r
}
define internal i32 @f1983(i32 %x) {
  %a = call i32 @f1982(i32 %x)
  %b = call i32 @f991(i32 %a)
  %r = xor i32 %b, 1983
  ret i32 %r
}
define internal i32 @f1984(i32 %x) {
  %a = call i32 @f1983(i32 %x)
  %b = call i32 @f992(i32 %a)
  %r = xor i32 %b, 1984
  ret i32 %r
}
define internal i32 @f1985(i32 %x) {
  %a = call i32 @f1984(i32 %x)
  %b = call i32 @f992(i32 %a)
  %r = xor i32 %b, 1985
  ret i32 %r
}
define internal i32 @f1986(i32 %x) {
  %a = call i32 @f1985(i32 %x)
  %b = call i32 @f993(i32 %a)
  %r = xor i32 %b, 1986
  ret i32 %r
}
define internal i32 @f1987(i32 %x) {
  %a = call i32 @f1986(i32 %x)
  %b = call i32 @f993(i32 %a)
  %r = xor i32 %b, 1987
  ret i32 %r
}
define internal i32 @f1988(i32 %x) {
  %a = call i32 @f1987(i32 %x)
  %b = call i32 @f994(i32 %a)
  %r = xor i32 %b, 1988
  ret i32 %r
}
define internal i32 @f1989(i32 %x) {
  %a = call i32 @f1988(i32 %x)
  %b = call i32 @f994(i32 %a)
  %r = xor i32 %b, 1989
  ret i32 %r
}
define internal i32 @f1990(i32 %x) {
  %a = call i32 @f1989(i32 %x)
  %b = call i32 @f995(i32 %a)
  %r = xor i32 %b, 1990
  ret i32 %r
}
define internal i32 @f1991(i32 %x) {
  %a = call i32 @f1990(i32 %x)
  %b = call i32 @f995(i32 %a)
  %r = xor i32 %b, 1991
  ret i32 %r
}
define internal i32 @f1992(i32 %x) {
  %a = call i32 @f1991(i32 %x)
  %b = call i32 @f996(i32 %a)
  %r = xor i32 %b, 1992
  ret i32 %r
}
define internal i32 @f1993(i32 %x) {
  %a = call i32 @f1992(i32 %x)
  %b = call i32 @f996(i32 %a)
  %r = xor i32 %b, 1993
  ret i32 %r
}
define internal i32 @f1994(i32 %x) {
  %a = call i32 @f1993(i32 %x)
  %b = call i32 @f997(i32 %a)
  %r = xor i32 %b, 1994
  ret i32 %r
}
define internal i32 @f1995(i32 %x) {
  %a = call i32 @f1994(i32 %x)
  %b = call i32 @f997(i32 %a)
  %r = xor i32 %b, 1995
  ret i32 %r
}
define internal i32 @f1996(i32 %x) {
  %a = call i32 @f1995(i32 %x)
  %b = call i32 @f998(i32 %a)
  %r = xor i32 %b, 1996
  ret i32 %r
}
define internal i32 @f1997(i32 %x) {
  %a = call i32 @f1996(i32 %x)
  %b = call i32 @f998(i32 %a)
  %r = xor i32 %b, 1997
  ret i32 %r
}
define internal i32 @f1998(i32 %x) {
  %a = call i32 @f1997(i32 %x)
  %b = call i32 @f999(i32 %a)
  %r = xor i32 %b, 1998
  ret i32 %r
}
define internal i32 @f1999(i32 %x) {
  %a = call i32 @f1998(i32 %x)
  %b = call i32 @f999(i32 %a)
  %r = xor i32 %b, 1999
  ret i32 %r
}
define i32 @entry(i32 %x) {
  %r = call i32 @f1999(i32 %x)
  ret i32 %r
}
